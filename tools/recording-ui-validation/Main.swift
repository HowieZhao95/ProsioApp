import AppKit
import AVFoundation
import CoreGraphics
import Observation
import SwiftUI

/// Independent UI runner. All device/source/permission dependencies are synthetic.
@main struct RecordingUIValidationMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = UIValidationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor @Observable final class UIValidationState {
    var failsDiscovery = false
    var failsStart = false
    var events: [String] = []
    var coordinator: RecordingCoordinator!
    var engine: FixtureRecordingEngine?
    let output: URL
    var fixtureProcess: Process?
    private var reportTimer: Timer?
    let previewBackend = UIValidationPreviewBackend()

    init() {
        output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROSIO_UI_VALIDATION_OUTPUT"] ?? "/tmp/prosio-recording-complete-ui", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        coordinator = RecordingCoordinator(root: output.appendingPathComponent("sessions"), permissions: PermissionsManager(),
            makeEngine: { [weak self] in
                if self?.failsStart == true { self?.failsStart = false; return UIValidationFailingEngine() }
                let engine = FixtureRecordingEngine()
                engine.onEvent = { [weak self] in self?.log($0) }
                self?.engine = engine
                return engine
            },
            sourceDiscovery: { [weak self] in
                guard let self else { throw CancellationError() }
                if self.failsDiscovery { self.failsDiscovery = false; throw RecordingWorkflowError.message("合成来源发现失败，可点重试。") }
                return self.inventory()
            },
            cameraPreview: RecordingCameraPreviewController(backend: previewBackend, monitoringInterval: .milliseconds(200)),
            authorization: { [weak self] _ in self?.log("syntheticAuthorization: no permission requested") })
        coordinator.cameraOneID = ""; coordinator.cameraTwoID = ""
        coordinator.microphoneID = "ui-microphone"
        coordinator.includeMicrophone = true; coordinator.includeSystemAudio = true
        coordinator.screenMode = "display"; coordinator.region = nil
        coordinator.onActivity = { [weak self] in self?.log("reservation:\($0)") }
        reportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeState() }
        }
    }

    func launchFixture() {
        let path = ProcessInfo.processInfo.environment["PROSIO_UI_FIXTURE_BINARY"]
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RecordingValidationFixture.app/Contents/MacOS/RecordingValidationFixture").path
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--handshake", output.appendingPathComponent("fixture-handshake.json").path,
                             "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        do { try process.run(); fixtureProcess = process }
        catch { log("fixture launch failed: \(error.localizedDescription)") }
    }
    func inventory() -> RecordingSourceInventory {
        let displays = NSScreen.screens.compactMap { screen -> RecordingDisplayChoice? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return RecordingDisplayChoice(id: id, name: screen.localizedName, frame: CGDisplayBounds(id),
                                           width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
        }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = rows.compactMap { row -> RecordingWindowChoice? in
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value == fixtureProcess?.processIdentifier,
                  let id = row[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary), (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return RecordingWindowChoice(id: id.uint32Value, name: "动态测试窗口（未捕获）", frame: frame, width: Int(frame.width), height: Int(frame.height))
        }
        return RecordingSourceInventory(displays: displays, windows: windows, cameras: previewBackend.all,
            microphones: [.init(id: "ui-microphone", kind: .microphone, name: "合成测试麦克风", deviceID: "ui-mic")])
    }
    func log(_ event: String) {
        events.append(event)
        guard let bytes = try? JSONSerialization.data(withJSONObject: ["hostUptime": ProcessInfo.processInfo.systemUptime, "event": event]) else { return }
        let path = output.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: path) { try? handle.seekToEnd(); try? handle.write(contentsOf: bytes + Data([10])); try? handle.close() }
        writeState()
    }
    func writeState() {
        guard let coordinator else { return }
        var state: [String: Any] = ["phase": coordinator.phase.rawValue, "selectionActive": coordinator.selectionActive,
            "selectionReady": coordinator.selectionTargetReady, "closingSelection": coordinator.closingSelection,
            "blocksOtherCapture": coordinator.blocksOtherCapture, "completionAvailable": coordinator.completionAvailable,
            "screenMode": coordinator.screenMode, "displayID": coordinator.displayID, "windowID": coordinator.windowID,
            "selectedCameras": coordinator.selectedCameraIDs, "microphone": coordinator.includeMicrophone,
            "systemAudio": coordinator.includeSystemAudio, "elapsed": coordinator.elapsedSeconds,
            "sessions": coordinator.store.sessions.count, "events": events, "previewStarted": previewBackend.startCount,
            "previewStopped": previewBackend.stopCount, "permissionsRequested": false, "physicalCapturesStarted": false]
        if let region = coordinator.region { state["region"] = ["x": region.x, "y": region.y, "width": region.width, "height": region.height] }
        if let message = coordinator.message { state["message"] = message }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("state.json"), options: .atomic) }
    }
    func shutdown() async {
        await coordinator.flushForTermination()
        coordinator.closeCompletion()
        reportTimer?.invalidate()
        if let fixtureProcess, fixtureProcess.isRunning { fixtureProcess.terminate() }
        writeState()
    }
}

@MainActor private final class UIValidationDelegate: NSObject, NSApplicationDelegate {
    private var model: UIValidationState?
    private var window: NSWindow?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = UIValidationState(); self.model = model
        model.launchFixture()
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "验收工具", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "验收工具")
        appMenu.addItem(withTitle: "退出验收", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let focusItem = NSMenuItem(title: "测试窗口", action: nil, keyEquivalent: "")
        let focusMenu = NSMenu(title: "测试窗口")
        for (title, tag) in [("桌面选择浮层", 1), ("底部工具栏", 2), ("机位一预览", 3), ("录制控制", 4), ("保存提示", 5)] {
            let item = NSMenuItem(title: title, action: #selector(focusTestWindow(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; focusMenu.addItem(item)
        }
        focusItem.submenu = focusMenu; mainMenu.addItem(focusItem)
        NSApp.mainMenu = mainMenu
        let window = NSWindow(contentViewController: NSHostingController(rootView: UIValidationStation(model: model)))
        window.title = "Prosio · 原生录制交互验收（合成来源）"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 230))
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Focus existing production windows for AX automation; never changes their views or actions.
    @objc private func focusTestWindow(_ sender: NSMenuItem) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0 is NSPanel }
        let target = candidates.first {
            let viewType = $0.contentView.map { String(reflecting: type(of: $0)) } ?? ""
            switch sender.tag {
            case 1: return viewType.contains("RecordingDesktopSelectionView")
            case 2: return viewType.contains("RecordingSelectionToolbarView")
            case 3: return viewType.contains("RecordingCameraPreviewCard")
            case 4: return viewType.contains("RecordingCompactControlView")
            case 5: return viewType.contains("RecordingCompletionView")
            default: return false
            }
        }
        target?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
private struct UIValidationStation: View {
    @Bindable var model: UIValidationState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("原生交互验收").font(.title3.weight(.semibold))
            Text("使用真实工具栏和桌面选择浮层。摄像头、声音与输出全为合成测试数据；不会请求权限或捕获设备。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("进入桌面录制") { model.coordinator.showSelection() }.buttonStyle(.borderedProminent)
                Button("模拟发现失败") { model.failsDiscovery = true; model.coordinator.showSelection() }
                Button("模拟启动失败") { model.failsStart = true; model.coordinator.showSelection() }
            }.disabled(model.coordinator.blocksOtherCapture)
            Text("\(model.coordinator.phase.displayName) · \(model.coordinator.selectedCameraIDs.count) 个模拟机位")
                .font(.caption).monospacedDigit()
            HStack {
                Button("查看素材") { model.coordinator.showWindow() }
                Button("退出验收") { NSApp.terminate(nil) }
            }
        }.padding(24).frame(width: 520, height: 230)
    }
}

@MainActor final class UIValidationPreviewBackend: RecordingCameraPreviewBackend {
    let all: [RecordingSource] = (1...3).map { .init(id: "ui-camera-\($0)", kind: .camera, name: "合成机位 \($0)", deviceID: "ui-cam-\($0)") }
    var isAuthorized: Bool { true }
    var startCount = 0, stopCount = 0
    func authorize() async throws { try Task.checkCancellation() }
    func availableSources() -> [RecordingSource] { all }
    func makeSource(_ source: RecordingSource, onFailure: @escaping @MainActor @Sendable () -> Void) -> any RecordingCameraPreviewSource {
        UIValidationPreviewSource(backend: self)
    }
}
@MainActor private final class UIValidationPreviewSource: RecordingCameraPreviewSource {
    let session = AVCaptureSession() // Empty: never adds an input or starts AV capture.
    let backend: UIValidationPreviewBackend
    init(backend: UIValidationPreviewBackend) { self.backend = backend }
    func start() async throws { try Task.checkCancellation(); backend.startCount += 1 }
    func stop() async { backend.stopCount += 1 }
}
@MainActor private final class UIValidationFailingEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    func start(configuration: RecordingConfiguration, directory: URL) async throws { throw RecordingWorkflowError.message("合成启动失败，请再次录制。") }
    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws {}
}
