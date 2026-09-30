import AppKit
import Foundation
import Testing

@Suite("Recording immersive workflow")
@MainActor
struct RecordingImmersiveWorkflowTests {
    @Test
    func targetReadinessTracksSelectionAndModeChanges() throws {
        let harness = try RecordingImmersiveWorkflowHarness()
        defer { harness.cleanup() }
        let coordinator = harness.coordinator

        #expect(!coordinator.selectionActive)
        let selectionReadyBefore = coordinator.selectionTargetReady
        coordinator.updateSelectionTarget(.display(9001))
        #expect(coordinator.selectionTargetReady)
        #expect(coordinator.displayID == 9001)
        #expect(coordinator.screenMode == "display")

        coordinator.updateSelectionTarget(nil)
        #expect(coordinator.selectionTargetReady == selectionReadyBefore)

        coordinator.updateSelectionTarget(.region(displayID: 9001, rect: RecordingRegion(x: 12, y: 20, width: 320, height: 180)))
        #expect(coordinator.selectionTargetReady)
        #expect(coordinator.region?.width == 320)
        coordinator.setSelectionMode(.display)
        #expect(!coordinator.selectionTargetReady)
        #expect(coordinator.region == nil)
        #expect(!coordinator.selectionActive)
    }

    @Test
    func cameraSelectionEnforcesTwoUniqueSourcesAndCompactsOnRemoval() throws {
        let harness = try RecordingImmersiveWorkflowHarness()
        defer { harness.cleanup() }
        let coordinator = harness.coordinator

        coordinator.toggleCamera("camera-one")
        coordinator.toggleCamera("camera-two")
        coordinator.toggleCamera("camera-three")
        #expect(coordinator.selectedCameraSources.map(\.id) == ["camera-one", "camera-two"])
        #expect(coordinator.isCameraSelected("camera-one"))
        #expect(coordinator.isCameraSelected("camera-two"))
        #expect(!coordinator.isCameraSelected("camera-three"))

        coordinator.toggleCamera("camera-one")
        #expect(coordinator.selectedCameraSources.map(\.id) == ["camera-two"])
        #expect(coordinator.cameraOneID == "camera-two")
        #expect(coordinator.cameraTwoID.isEmpty)
        #expect(coordinator.cameraPreviewStatuses.isEmpty)
        #expect(coordinator.cameraPreviewSession(for: "camera-two") == nil)
        #expect(!coordinator.selectionActive)
    }

    @Test
    func busyRecordingDoesNotMutateSelectionOrCameraAssignments() async throws {
        let harness = try RecordingImmersiveWorkflowHarness()
        defer { harness.cleanup() }
        let coordinator = harness.coordinator
        coordinator.updateSelectionTarget(.display(9001))
        coordinator.toggleCamera("camera-one")
        coordinator.toggleCamera("camera-two")
        coordinator.includeMicrophone = false
        coordinator.includeSystemAudio = false
        await coordinator.start(
            configuration: try coordinator.configuration(),
            countdownSeconds: 0,
            requestPermissions: false
        )
        #expect(coordinator.phase == .recording)
        #expect(!coordinator.selectionTargetReady)
        let cameraIDsBefore = coordinator.selectedCameraSources.map(\.id)
        let modeBefore = coordinator.screenMode

        coordinator.toggleCamera("camera-three")
        coordinator.clearCameras()
        coordinator.setSelectionMode(.window)
        coordinator.updateSelectionTarget(.window(9002))
        #expect(coordinator.selectedCameraSources.map(\.id) == cameraIDsBefore)
        #expect(coordinator.screenMode == modeBefore)
        #expect(!coordinator.selectionTargetReady)
        #expect(coordinator.phase == .recording)

        await coordinator.stop()
        #expect(harness.engine.stopCalls == 1)
        #expect(coordinator.phase == .failed) // Fake writer intentionally creates no media.
    }
}

@MainActor
private final class RecordingImmersiveWorkflowHarness {
    let coordinator: RecordingCoordinator
    let engine = RecordingImmersiveWorkflowEngine()
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-immersive-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = self.engine
        let inventory = RecordingSourceInventory(
            displays: [.init(id: 9001, name: "测试显示器", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), width: 2880, height: 1800)],
            windows: [.init(id: 9002, name: "测试窗口", frame: CGRect(x: 100, y: 100, width: 800, height: 600), width: 800, height: 600)],
            cameras: [
                .init(id: "camera-one", kind: .camera, name: "相机一", deviceID: "one"),
                .init(id: "camera-two", kind: .camera, name: "相机二", deviceID: "two"),
                .init(id: "camera-three", kind: .camera, name: "相机三", deviceID: "three")
            ],
            microphones: [.init(id: "microphone-one", kind: .microphone, name: "测试麦克风", deviceID: "microphone-one")]
        )
        coordinator = RecordingCoordinator(root: root, permissions: PermissionsManager(), makeEngine: { engine }, inventory: inventory)
        coordinator.clearCameras() // Ignore per-user camera choices so assignments are deterministic.
        coordinator.cameraOneID = ""
        coordinator.cameraTwoID = ""
        coordinator.displayID = 9001
        coordinator.microphoneID = "microphone-one"
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class RecordingImmersiveWorkflowEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var stopCalls = 0

    func start(configuration: RecordingConfiguration, directory: URL) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws { stopCalls += 1 }
}
