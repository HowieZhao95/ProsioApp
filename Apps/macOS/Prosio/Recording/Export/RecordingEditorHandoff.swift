import AppKit
import Foundation

nonisolated struct RecordingEditorApplication: Identifiable, Hashable, Sendable {
    let editor: RecordingEditor
    let url: URL
    let bundleIdentifier: String
    let version: String?
    var id: String { url.path }
}

nonisolated enum RecordingEditorHandoffError: LocalizedError, Equatable {
    case editorNotInstalled(RecordingEditor), invalidApplication, invalidInterchange, incompatibleFormat, unverifiedJianyingVersion(String?), unverifiedMulticamRequiresExplicitChoice
    var errorDescription: String? {
        switch self {
        case let .editorNotInstalled(editor): "没有找到已安装的 \(editor.title)。原片与交接文件已保留，可稍后导入。"
        case .invalidApplication: "所选应用与剪辑软件不匹配。"
        case .invalidInterchange: "交接文件不存在、不可读取或格式不正确。"
        case .incompatibleFormat: "所选软件不接受这个交接格式。"
        case let .unverifiedJianyingVersion(version): "剪映 \(version ?? "当前版本") 的 macOS 草稿导入尚未验证。请按交接包说明手动导入实验性草稿。"
        case .unverifiedMulticamRequiresExplicitChoice: "原生多机位兼容文件仍待当前 Premiere 版本验收，请明确选择实验性导入。"
        }
    }
}

nonisolated struct RecordingEditorOpenReceipt: Sendable {
    let editor: RecordingEditor
    let applicationVersion: String?
    let file: URL
    let message: String
    // A launch-services request is not proof that an editor imported or accepted it.
    var importVerified: Bool { false }
}

nonisolated struct RecordingEditorHandoffAvailability: Sendable {
    let application: RecordingEditorApplication?
    let canRequestOpen: Bool
    let note: String
}

@MainActor
protocol RecordingEditorApplicationDiscovering {
    func installedApplications() -> [RecordingEditorApplication]
}

@MainActor
protocol RecordingEditorApplicationOpening {
    func open(document: URL, in application: RecordingEditorApplication) async throws
}

@MainActor
final class RecordingEditorHandoff {
    private let discovery: any RecordingEditorApplicationDiscovering
    private let opener: any RecordingEditorApplicationOpening

    init(discovery: any RecordingEditorApplicationDiscovering = RecordingWorkspaceEditorDiscovery(), opener: any RecordingEditorApplicationOpening = RecordingWorkspaceEditorOpener()) {
        self.discovery = discovery
        self.opener = opener
    }

    func applications(for editor: RecordingEditor) -> [RecordingEditorApplication] {
        discovery.installedApplications().filter { $0.editor == editor && RecordingWorkspaceEditorDiscovery.editor(forBundleIdentifier: $0.bundleIdentifier) == editor }
    }

    func availability(for editor: RecordingEditor) -> RecordingEditorHandoffAvailability {
        guard let installed = applications(for: editor).first else {
            return RecordingEditorHandoffAvailability(application: nil, canRequestOpen: false, note: "尚未安装 \(editor.title)，可以保留交接包后再导入。")
        }
        if editor == .jianying {
            return RecordingEditorHandoffAvailability(application: installed, canRequestOpen: false, note: "剪映 \(installed.version ?? "当前版本") 的 macOS 草稿导入尚未验证；可导出实验性草稿并按说明手动导入。")
        }
        return RecordingEditorHandoffAvailability(application: installed, canRequestOpen: true, note: "可在 \(editor.title) 中请求打开；请在软件内确认导入与同步。")
    }

    // Called only by an explicit user action after an export. No default XML handler is used.
    func open(exportedFile: URL, editor: RecordingEditor, application: RecordingEditorApplication? = nil, allowExperimentalMulticam: Bool = false) async throws -> RecordingEditorOpenReceipt {
        let installed = applications(for: editor)
        guard let selected = application ?? installed.first else { throw RecordingEditorHandoffError.editorNotInstalled(editor) }
        guard selected.editor == editor, installed.contains(selected) else { throw RecordingEditorHandoffError.invalidApplication }
        if editor == .jianying { throw RecordingEditorHandoffError.unverifiedJianyingVersion(selected.version) }
        let descriptor = try await Self.inspectInterchange(exportedFile)
        switch editor {
        case .finalCutPro:
            guard exportedFile.pathExtension.lowercased() == "fcpxml", descriptor.root == "fcpxml" else { throw RecordingEditorHandoffError.incompatibleFormat }
        case .resolve:
            guard (descriptor.root == "xmeml" && exportedFile.pathExtension.lowercased() == "xml") || (descriptor.root == "fcpxml" && exportedFile.pathExtension.lowercased() == "fcpxml") else { throw RecordingEditorHandoffError.incompatibleFormat }
        case .premiere:
            guard descriptor.root == "xmeml", exportedFile.pathExtension.lowercased() == "xml" else { throw RecordingEditorHandoffError.incompatibleFormat }
            if descriptor.hasMulticlip && !allowExperimentalMulticam { throw RecordingEditorHandoffError.unverifiedMulticamRequiresExplicitChoice }
        case .jianying: break
        }
        try Task.checkCancellation()
        try await opener.open(document: exportedFile, in: selected)
        return RecordingEditorOpenReceipt(editor: editor, applicationVersion: selected.version, file: exportedFile, message: "已向 \(editor.title) 发送交接文件。请在软件中确认导入、素材链接与音画同步。")
    }

    private nonisolated static func inspectInterchange(_ file: URL) async throws -> RecordingInterchangeDescriptor {
        let job = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard file.isFileURL,
                  let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]), attributes.isRegularFile == true, attributes.isReadable == true, (attributes.fileSize ?? Int.max) <= 32_000_000,
                  let data = try? Data(contentsOf: file), data.count <= 32_000_000,
                  let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]), let root = xml.rootElement()?.name else { throw RecordingEditorHandoffError.invalidInterchange }
            let hasMulticlip = !(try xml.nodes(forXPath: "//multiclip")).isEmpty
            try Task.checkCancellation()
            return RecordingInterchangeDescriptor(root: root, hasMulticlip: hasMulticlip)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}

private nonisolated struct RecordingInterchangeDescriptor: Sendable {
    let root: String
    let hasMulticlip: Bool
}

@MainActor
struct RecordingWorkspaceEditorDiscovery: RecordingEditorApplicationDiscovering {
    private let roots: [URL]
    init(roots: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]) { self.roots = roots }

    nonisolated static func editor(forBundleIdentifier identifier: String) -> RecordingEditor? {
        switch identifier {
        case "com.apple.FinalCut": return .finalCutPro
        case "com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite", "com.blackmagic-design.DaVinciResolveAppStore": return .resolve
        case "com.lemon.lvpro": return .jianying
        default:
            if identifier == "com.adobe.PremierePro" || identifier.hasPrefix("com.adobe.PremierePro.") { return .premiere }
            return nil
        }
    }

    func installedApplications() -> [RecordingEditorApplication] {
        var found: [RecordingEditorApplication] = []
        var seen = Set<String>()
        for root in roots {
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = iterator.nextObject() as? URL {
                if iterator.level > 2 { iterator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                iterator.skipDescendants()
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, let editor = Self.editor(forBundleIdentifier: identifier), seen.insert(url.standardizedFileURL.path).inserted else { continue }
                found.append(RecordingEditorApplication(editor: editor, url: url, bundleIdentifier: identifier, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))
            }
        }
        return found.sorted {
            if $0.editor == $1.editor, $0.version != $1.version {
                return ($0.version ?? "0").compare($1.version ?? "0", options: .numeric) == .orderedDescending
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}

@MainActor
struct RecordingWorkspaceEditorOpener: RecordingEditorApplicationOpening {
    func open(document: URL, in application: RecordingEditorApplication) async throws {
        // Re-check the installed bundle immediately before launch. Tests inject another opener.
        guard Bundle(url: application.url)?.bundleIdentifier == application.bundleIdentifier,
              RecordingWorkspaceEditorDiscovery.editor(forBundleIdentifier: application.bundleIdentifier) == application.editor else { throw RecordingEditorHandoffError.invalidApplication }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try await NSWorkspace.shared.open([document], withApplicationAt: application.url, configuration: configuration)
    }
}
