import AppKit
import Foundation
import SwiftUI
import Testing

@Suite("Recording immersive native views", .serialized)
@MainActor
struct RecordingNativeViewTests {
    @Test
    func selectionToolbarRendersAtLightDarkAndCompactSizes() async throws {
        _ = NSApplication.shared
        let harness = try RecordingImmersiveViewHarness()
        defer { harness.cleanup() }
        harness.coordinator.updateSelectionTarget(.display(9001))
        harness.coordinator.toggleCamera("camera-one")
        harness.coordinator.toggleCamera("camera-two")
        #expect(harness.coordinator.selectionTargetReady)
        #expect(harness.coordinator.selectedCameraSources.count == 2)

        for (name, theme, size) in [
            ("toolbar-light", NSAppearance.Name.aqua, CGSize(width: 620, height: 80)),
            ("toolbar-dark", .darkAqua, CGSize(width: 620, height: 80)),
            ("toolbar-small", .aqua, CGSize(width: 520, height: 80))
        ] {
            try await render(RecordingSelectionToolbarView(coordinator: harness.coordinator),
                             theme: theme, size: size, name: name)
        }
    }

    @Test
    func compactControlRendersRecordingPausedAndFinalizing() async throws {
        _ = NSApplication.shared
        let harness = try RecordingImmersiveViewHarness()
        defer {
            harness.engine.releaseStop()
            harness.cleanup()
        }
        harness.coordinator.includeMicrophone = false
        harness.coordinator.includeSystemAudio = false
        await harness.coordinator.start(
            configuration: RecordingConfiguration(screenTarget: .display(9001), capturesSystemAudio: false),
            countdownSeconds: 0,
            requestPermissions: false
        )
        #expect(harness.coordinator.phase == .recording)
        try await render(RecordingCompactControlView(coordinator: harness.coordinator),
                         theme: .aqua, size: CGSize(width: 220, height: 64), name: "control-recording")

        await harness.coordinator.togglePause()
        #expect(harness.coordinator.phase == .paused)
        try await render(RecordingCompactControlView(coordinator: harness.coordinator),
                         theme: .darkAqua, size: CGSize(width: 220, height: 64), name: "control-paused")

        harness.engine.holdStop = true
        let stop = Task { @MainActor in await harness.coordinator.stop() }
        await harness.engine.waitUntilStopEntered()
        #expect(harness.coordinator.phase == .finalizing)
        try await render(RecordingCompactControlView(coordinator: harness.coordinator),
                         theme: .aqua, size: CGSize(width: 220, height: 64), name: "control-finalizing")
        harness.engine.releaseStop()
        await stop.value
    }

    private func render<V: View>(_ view: V, theme: NSAppearance.Name, size: CGSize, name: String) async throws {
        let themed = view.environment(\.colorScheme, theme == .darkAqua ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(theme == .darkAqua ? Color(nsColor: .darkGray) : Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: themed)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.wantsLayer = true
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let fit = host.fittingSize
        #expect(fit.width <= size.width + 1, "\(name) intrinsic width \(fit.width) exceeds viewport \(size.width)")
        #expect(fit.height <= size.height + 1, "\(name) intrinsic height \(fit.height) exceeds viewport \(size.height)")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: Int(size.width * 8), bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        try #require(host.layer).render(in: context)
        #expect(bitmap.pixelsWide == Int(size.width * 2))
        #expect(bitmap.pixelsHigh == Int(size.height * 2))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bytes.count > 1_000)
        let directory = URL(fileURLWithPath: "/tmp/prosio-recording-immersive-native-evidence-20260930", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class RecordingImmersiveViewHarness {
    let coordinator: RecordingCoordinator
    let engine = RecordingImmersiveViewEngine()
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-immersive-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = self.engine
        let inventory = RecordingSourceInventory(
            displays: [.init(id: 9001, name: "内建 Retina 显示器", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), width: 2880, height: 1800)],
            windows: [.init(id: 9002, name: "演示文稿", frame: CGRect(x: 100, y: 100, width: 800, height: 600), width: 800, height: 600)],
            cameras: [
                .init(id: "camera-one", kind: .camera, name: "FaceTime 高清相机", deviceID: "one"),
                .init(id: "camera-two", kind: .camera, name: "iPhone 连续互通相机", deviceID: "two"),
                .init(id: "camera-three", kind: .camera, name: "USB 摄像头", deviceID: "three")
            ],
            microphones: [.init(id: "microphone-one", kind: .microphone, name: "内建麦克风", deviceID: "microphone-one")]
        )
        coordinator = RecordingCoordinator(root: root, permissions: PermissionsManager(), makeEngine: { engine }, inventory: inventory)
        coordinator.clearCameras() // Isolate the screenshot from persisted camera preferences.
        coordinator.cameraOneID = ""
        coordinator.cameraTwoID = ""
        coordinator.displayID = 9001
        coordinator.microphoneID = "microphone-one"
        coordinator.includeMicrophone = true
        coordinator.includeSystemAudio = true
        coordinator.showsCursor = true
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class RecordingImmersiveViewEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var holdStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopHasEntered = false

    func start(configuration: RecordingConfiguration, directory: URL) async throws {}
    func pause() async throws {}
    func resume() async throws {}

    func stop() async throws {
        stopHasEntered = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
    }

    func waitUntilStopEntered() async {
        guard !stopHasEntered else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}
