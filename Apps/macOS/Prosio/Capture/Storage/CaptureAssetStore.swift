import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation

nonisolated struct CaptureAsset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let version: Int
    let createdAt: Date
    let kind: CaptureKind
    let sourceName: String
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let savedAt: Date?
    init(id: UUID, version: Int, createdAt: Date, kind: CaptureKind, sourceName: String,
         sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int, savedAt: Date? = nil) {
        self.id=id;self.version=version;self.createdAt=createdAt;self.kind=kind
        self.sourceName=sourceName;self.sourceRect=sourceRect
        self.pixelWidth=pixelWidth;self.pixelHeight=pixelHeight;self.savedAt=savedAt
    }
}
nonisolated enum CaptureStoreError: LocalizedError {
    case unsupportedVersion, invalidAsset, imageEncodingFailed
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This screenshot was saved by a newer version of Prosio."
        case .invalidAsset: "The saved screenshot is missing or damaged."
        case .imageEncodingFailed: "The screenshot could not be saved as PNG."
        }
    }
}

/// Each asset commits as a complete directory. The directory manifests ARE the index:
/// no separate index write can orphan a successfully persisted PNG.
@Observable @MainActor
final class CaptureAssetStore {
    let rootURL: URL
    @ObservationIgnored private let afterPNGWritten: (@Sendable (URL) throws -> Void)?
    private(set) var assets: [CaptureAsset] = []
    private(set) var recoveryWarnings: [String] = []
    init(rootURL: URL, afterPNGWritten: (@Sendable (URL) throws -> Void)? = nil) {
        self.rootURL = rootURL; self.afterPNGWritten = afterPNGWritten; reload()
    }

    func reload() {
        assets = []; recoveryWarnings = []
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let directories = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for directory in directories where directory.pathExtension == "prosiocapture" {
                do {
                    let asset = try JSONDecoder().decode(CaptureAsset.self, from: Data(contentsOf: directory.appendingPathComponent("asset.json")))
                    guard [1, 2, 3].contains(asset.version) else { throw CaptureStoreError.unsupportedVersion }
                    guard directory.lastPathComponent == asset.id.uuidString + ".prosiocapture", FileManager.default.fileExists(atPath: directory.appendingPathComponent("image.png").path) else { throw CaptureStoreError.invalidAsset }
                    guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent("image.png") as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == asset.pixelWidth,
                          (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == asset.pixelHeight else { throw CaptureStoreError.invalidAsset }
                    if asset.version >= 2 { _ = try loadDocument(asset) }
                    assets.append(asset)
                } catch { recoveryWarnings.append("\(directory.lastPathComponent): \(error.localizedDescription)") }
            }
            assets.sort { ($0.savedAt ?? $0.createdAt) > ($1.savedAt ?? $1.createdAt) }
        } catch { recoveryWarnings.append(error.localizedDescription) }
    }

    func imageURL(for asset: CaptureAsset) -> URL { directory(for: asset.id).appendingPathComponent("image.png") }
    private func directory(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString + ".prosiocapture", isDirectory: true) }

    func save(_ screenshot: CapturedScreenshot) async throws -> CaptureAsset {
        try Task.checkCancellation()
        let asset = CaptureAsset(id: UUID(), version: 1, createdAt: screenshot.capturedAt, kind: screenshot.kind, sourceName: screenshot.sourceName,
                                 sourceRect: screenshot.sourceRect, pixelWidth: screenshot.image.width, pixelHeight: screenshot.image.height)
        let root = rootURL
        let checkpoint = afterPNGWritten
        // Image encoding and disk I/O do not block selection or the voice UI.
        let writer = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent(".pending-" + asset.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            let png = temporary.appendingPathComponent("image.png")
            guard let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CaptureStoreError.imageEncodingFailed }
            CGImageDestinationAddImage(destination, screenshot.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CaptureStoreError.imageEncodingFailed }
            try checkpoint?(temporary)
            try Task.checkCancellation()
            try JSONEncoder().encode(asset).write(to: temporary.appendingPathComponent("asset.json"), options: .atomic)
            try Task.checkCancellation()
            try fm.moveItem(at: temporary, to: root.appendingPathComponent(asset.id.uuidString + ".prosiocapture", isDirectory: true))
        }
        try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
        assets.append(asset)
        assets.sort { ($0.savedAt ?? $0.createdAt) > ($1.savedAt ?? $1.createdAt) }
        return asset
    }

    func loadDocument(_ asset: CaptureAsset) throws -> EditableCaptureDocument {
        let folder = directory(for: asset.id)
        let originalURL = asset.version >= 2 ? folder.appendingPathComponent("source.png") : imageURL(for: asset)
        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureStoreError.invalidAsset }
        let snapshot: EditorSnapshot
        if asset.version >= 2 {
            let manifest = try JSONDecoder().decode(EditableCaptureManifest.self, from: Data(contentsOf: folder.appendingPathComponent("document.json")))
            guard manifest.version == asset.version else { throw CaptureStoreError.unsupportedVersion }
            let crop = manifest.snapshot.cropRect
            if asset.version == 2 {
                guard image.width == asset.pixelWidth,image.height == asset.pixelHeight,
                      crop == CGRect(x:0,y:0,width:image.width,height:image.height) else { throw CaptureStoreError.invalidAsset }
            } else {
                guard crop == crop.standardized.integral,
                      Int(crop.width) == asset.pixelWidth,Int(crop.height) == asset.pixelHeight else { throw CaptureStoreError.invalidAsset }
            }
            snapshot = manifest.snapshot
        } else { snapshot = EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: image.width, height: image.height)) }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard bounds.contains(snapshot.cropRect), snapshot.cropRect.width > 0, snapshot.cropRect.height > 0 else { throw CaptureStoreError.invalidAsset }
        return EditableCaptureDocument(baseImage: image, snapshot: snapshot, kind: asset.kind, sourceName: asset.sourceName, sourceRect: asset.sourceRect, capturedAt: asset.createdAt)
    }

    /// Completed history retains the whole frozen screen. Drafts can still use the cropped source.
    func saveDocument(_ document: EditableCaptureDocument, preserveFullSource: Bool = false) async throws -> CaptureAsset {
        try Task.checkCancellation()
        let root = rootURL, checkpoint = afterPNGWritten
        let writer = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let savedDocument = preserveFullSource ? document : try document.restrictedToSelection()
            let flattened = try EditorRenderer.render(baseImage: savedDocument.baseImage, snapshot: savedDocument.snapshot)
            let version = preserveFullSource ? 3 : 2
            let asset = CaptureAsset(id: UUID(), version: version, createdAt: savedDocument.capturedAt, kind: savedDocument.kind, sourceName: savedDocument.sourceName,
                                     sourceRect: savedDocument.sourceRect, pixelWidth: flattened.width, pixelHeight: flattened.height,
                                     savedAt: preserveFullSource ? .now : nil)
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent(".pending-" + asset.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            try Self.writePNG(flattened, to: temporary.appendingPathComponent("image.png"))
            try checkpoint?(temporary)
            try Task.checkCancellation()
            try Self.writePNG(savedDocument.baseImage, to: temporary.appendingPathComponent("source.png"))
            try JSONEncoder().encode(EditableCaptureManifest(version: version, snapshot: savedDocument.snapshot)).write(to: temporary.appendingPathComponent("document.json"), options: .atomic)
            try JSONEncoder().encode(asset).write(to: temporary.appendingPathComponent("asset.json"), options: .atomic)
            try Task.checkCancellation()
            try fm.moveItem(at: temporary, to: root.appendingPathComponent(asset.id.uuidString + ".prosiocapture", isDirectory: true))
            return asset
        }
        let asset = try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
        assets.append(asset); assets.sort { ($0.savedAt ?? $0.createdAt) > ($1.savedAt ?? $1.createdAt) }
        return asset
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CaptureStoreError.imageEncodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureStoreError.imageEncodingFailed }
    }

    func delete(_ asset: CaptureAsset) throws {
        guard assets.contains(where: { $0.id == asset.id }) else { throw CaptureStoreError.invalidAsset }
        try FileManager.default.removeItem(at: directory(for: asset.id))
        assets.removeAll { $0.id == asset.id }
    }

    /// Called only after external output succeeds, so a failed export cannot evict older history.
    func pruneHistory(keeping limit: Int) {
        for asset in Array(assets.dropFirst(max(0, limit))) {
            do { try delete(asset) }
            catch { recoveryWarnings.append("Could not remove old screenshot: \(error.localizedDescription)") }
        }
    }
}
