import AppKit
import Foundation
import SwiftUI
import Testing

@Suite("Recording native views", .serialized)
@MainActor
struct RecordingNativeViewTests {
    @Test func sourceSetupInLightDarkAndSmallWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingSnapshotEngine()
        let inventory = RecordingSourceInventory(
            displays: [.init(id: 9001, name: "内建 Retina 显示器", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), width: 2880, height: 1800)],
            windows: [.init(id: 9002, name: "演示文稿", frame: CGRect(x: 100, y: 100, width: 800, height: 600), width: 800, height: 600)],
            cameras: [.init(id: "camera-one", kind: .camera, name: "FaceTime 高清相机", deviceID: "one"),
                      .init(id: "camera-two", kind: .camera, name: "iPhone 连续互通相机", deviceID: "two")],
            microphones: [.init(id: "microphone-one", kind: .microphone, name: "内建麦克风", deviceID: "microphone-one")])
        let coordinator = RecordingCoordinator(root: root, permissions: PermissionsManager(),
                                               makeEngine: { engine }, inventory: inventory)
        coordinator.displayID = 9001
        coordinator.cameraOneID = "camera-one"
        coordinator.cameraTwoID = "camera-two"
        coordinator.microphoneID = "microphone-one"
        coordinator.includeMicrophone = true
        coordinator.includeSystemAudio = true
        for (name, theme, size) in [
            ("setup-light", NSAppearance.Name.aqua, CGSize(width: 900, height: 640)),
            ("setup-dark", .darkAqua, CGSize(width: 900, height: 640)),
            ("setup-small", .aqua, CGSize(width: 760, height: 560))
        ] {
            try await render(RecordingWorkspaceView(coordinator: coordinator), theme: theme, size: size, name: name)
        }
        // The same production control view used in the menu/HUD is rendered with a fake engine.
        // This never requests permissions, discovers real sources, or captures system content.
        await coordinator.start(configuration: try coordinator.configuration(), countdownSeconds: 0, requestPermissions: false)
        #expect(coordinator.phase == .recording)
        try await render(RecordingControlView(coordinator: coordinator, compact: true),
                         theme: .aqua, size: CGSize(width: 380, height: 120), name: "control-recording")
        await coordinator.togglePause()
        #expect(coordinator.phase == .paused)
        try await render(RecordingControlView(coordinator: coordinator, compact: true),
                         theme: .darkAqua, size: CGSize(width: 380, height: 120), name: "control-paused")
        await coordinator.stop()
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
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: Int(size.width * 8), bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        try #require(host.layer).render(in: context)
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bytes.count > 1_000)
        let path = URL(fileURLWithPath: "/tmp/prosio-recording-native-evidence-20260930", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try bytes.write(to: path.appendingPathComponent(name + ".png"), options: .atomic)
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class RecordingSnapshotEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    func start(configuration: RecordingConfiguration, directory: URL) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws {}
}
