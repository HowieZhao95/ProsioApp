import AppKit
import AVFoundation
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
    func selectionReservationRemainsUntilPendingPreviewHasStopped() async throws {
        let previewBackend = RecordingImmersivePreviewBackend()
        previewBackend.holdStart = true
        let harness = try RecordingImmersiveWorkflowHarness(previewBackend: previewBackend)
        defer { harness.cleanup() }
        let coordinator = harness.coordinator
        coordinator.canBegin = { [weak coordinator] in coordinator?.blocksOtherCapture == false }
        coordinator.cameraOneID = "camera-one"

        coordinator.showSelection()
        await waitUntil { previewBackend.source?.startEntered == true }
        #expect(coordinator.selectionActive)
        #expect(coordinator.blocksOtherCapture)
        #expect(harness.activityValues == [true])

        coordinator.dismissSelection()
        #expect(!coordinator.selectionActive)
        #expect(coordinator.closingSelection)
        #expect(coordinator.blocksOtherCapture)
        await coordinator.start(configuration: Self.configuration, countdownSeconds: 0, requestPermissions: false)
        #expect(harness.engine.startCalls == 0)

        previewBackend.source?.releaseStart()
        await waitUntil { !coordinator.closingSelection }
        #expect(previewBackend.source?.stopCalls == 1)
        #expect(!coordinator.blocksOtherCapture)
        #expect(harness.activityValues == [true, false])

        await coordinator.start(configuration: Self.configuration, countdownSeconds: 0, requestPermissions: false)
        #expect(harness.engine.startCalls == 1)
        await coordinator.stop()
    }

    @Test
    func sourceDiscoveryFailureCanRetryWithoutLosingSelection() async throws {
        let counter = RecordingImmersiveCallCounter()
        let inventory = RecordingImmersiveWorkflowHarness.fixtureInventory
        let harness = try RecordingImmersiveWorkflowHarness(discovery: {
            counter.calls += 1
            if counter.calls == 1 { throw RecordingImmersiveWorkflowError.discovery }
            return inventory
        }, initialInventory: false)
        defer { harness.cleanup() }
        let coordinator = harness.coordinator
        coordinator.showSelection()
        await waitUntil { !coordinator.loadingSources && coordinator.message != nil }
        #expect(coordinator.selectionActive)
        #expect(coordinator.blocksOtherCapture)
        #expect(coordinator.inventory.map { _ in true } == nil)
        #expect(harness.engine.startCalls == 0)

        await coordinator.refreshSelectionSources()
        #expect(counter.calls == 2)
        #expect(coordinator.inventory?.displays.first?.id == 9001)
        #expect(coordinator.selectionActive)
        #expect(coordinator.message == nil)
        coordinator.updateSelectionTarget(.display(9001))
        #expect(coordinator.selectionTargetReady)
        coordinator.dismissSelection()
        await waitUntil { !coordinator.closingSelection }
    }

    @Test
    func dismissedSelectionIgnoresLateSourceDiscoveryResult() async throws {
        let gate = RecordingImmersiveDiscoveryGate(result: RecordingImmersiveWorkflowHarness.fixtureInventory)
        let harness = try RecordingImmersiveWorkflowHarness(
            discovery: { await gate.waitForResult() },
            initialInventory: false
        )
        defer { harness.cleanup() }
        let coordinator = harness.coordinator
        coordinator.showSelection()
        await gate.waitUntilEntered()
        #expect(coordinator.loadingSources)

        coordinator.dismissSelection()
        await waitUntil { !coordinator.closingSelection }
        gate.release()
        await waitUntil { !coordinator.loadingSources }

        #expect(!coordinator.selectionActive)
        #expect(coordinator.inventory.map { _ in true } == nil)
        #expect(!coordinator.selectionTargetReady)
        #expect(harness.engine.startCalls == 0)
        #expect(harness.activityValues == [true, false])
    }

    @Test
    func immersiveStartupFailureKeepsSelectionReadyForRetryThenShowsCompletion() async throws {
        let harness = try RecordingImmersiveWorkflowHarness(authorization: { _ in })
        defer { harness.cleanup() }
        let coordinator = harness.coordinator
        coordinator.showSelection()
        await waitUntil { coordinator.inventory != nil }
        coordinator.updateSelectionTarget(.display(9001))
        coordinator.toggleCamera("camera-one")
        coordinator.includeMicrophone = false
        coordinator.includeSystemAudio = false
        let selectedCameras = coordinator.selectedCameraSources.map(\.id)
        let configuration = try coordinator.configuration()
        harness.engine.startError = RecordingImmersiveWorkflowError.startup
        harness.engine.emitSegmentOnStop = true

        await coordinator.start(configuration: configuration, countdownSeconds: 0, requestPermissions: true)

        #expect(coordinator.phase == .failed)
        #expect(coordinator.selectionActive)
        #expect(coordinator.selectionTargetReady)
        #expect(coordinator.displayID == 9001)
        #expect(coordinator.selectedCameraSources.map(\.id) == selectedCameras)
        #expect(harness.engine.stopCalls == 1)
        #expect(coordinator.store.sessions.first?.phase == .interrupted)
        #expect(coordinator.store.sessions.first?.segments.count == 1)
        #expect(!coordinator.completionAvailable)

        harness.engine.startError = nil
        await coordinator.start(configuration: configuration, countdownSeconds: 0, requestPermissions: true)
        #expect(coordinator.phase == .recording)
        #expect(!coordinator.selectionActive)
        #expect(!coordinator.selectionTargetReady)
        await coordinator.stop()
        #expect(coordinator.phase == .ready)
        #expect(coordinator.completionAvailable)
        #expect(harness.engine.stopCalls == 2)
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
    let previewBackend: RecordingImmersivePreviewBackend
    private let root: URL
    private(set) var activityValues: [Bool] = []

    static var fixtureInventory: RecordingSourceInventory {
        RecordingSourceInventory(
            displays: [.init(id: 9001, name: "测试显示器", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), width: 2880, height: 1800)],
            windows: [.init(id: 9002, name: "测试窗口", frame: CGRect(x: 100, y: 100, width: 800, height: 600), width: 800, height: 600)],
            cameras: [
                .init(id: "camera-one", kind: .camera, name: "相机一", deviceID: "one"),
                .init(id: "camera-two", kind: .camera, name: "相机二", deviceID: "two"),
                .init(id: "camera-three", kind: .camera, name: "相机三", deviceID: "three")
            ],
            microphones: [.init(id: "microphone-one", kind: .microphone, name: "测试麦克风", deviceID: "microphone-one")]
        )
    }

    init(
        discovery: (() async throws -> RecordingSourceInventory)? = nil,
        previewBackend: RecordingImmersivePreviewBackend? = nil,
        authorization: ((RecordingConfiguration) async throws -> Void)? = nil,
        initialInventory: Bool = true
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-immersive-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = self.engine
        let inventory = Self.fixtureInventory
        self.previewBackend = previewBackend ?? RecordingImmersivePreviewBackend(sources: inventory.cameras)
        let preview = RecordingCameraPreviewController(backend: self.previewBackend, monitoringInterval: nil)
        coordinator = RecordingCoordinator(
            root: root,
            permissions: PermissionsManager(),
            makeEngine: { engine },
            inventory: initialInventory ? inventory : nil,
            sourceDiscovery: discovery ?? { inventory },
            cameraPreview: preview,
            authorization: authorization,
            presentsUI: false
        )
        coordinator.onActivity = { [weak self] active in self?.activityValues.append(active) }
        coordinator.clearCameras() // Ignore per-user camera choices so assignments are deterministic.
        coordinator.cameraOneID = ""
        coordinator.cameraTwoID = ""
        coordinator.displayID = 9001
        coordinator.microphoneID = "microphone-one"
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private extension RecordingImmersiveWorkflowTests {
    static var configuration: RecordingConfiguration {
        RecordingConfiguration(screenTarget: .display(9001), capturesSystemAudio: false)
    }
}

@MainActor
private final class RecordingImmersivePreviewBackend: RecordingCameraPreviewBackend {
    var isAuthorized = true
    var holdStart = false
    private(set) var source: RecordingImmersivePreviewSource?
    private let sources: [RecordingSource]

    init(sources: [RecordingSource] = RecordingImmersiveWorkflowHarness.fixtureInventory.cameras) {
        self.sources = sources
    }

    func authorize() async throws {}
    func availableSources() -> [RecordingSource] { sources }
    func makeSource(_ source: RecordingSource, onFailure: @escaping @MainActor @Sendable () -> Void) -> any RecordingCameraPreviewSource {
        let capture = RecordingImmersivePreviewSource(holdStart: holdStart)
        self.source = capture
        return capture
    }
}

@MainActor
private final class RecordingImmersivePreviewSource: RecordingCameraPreviewSource {
    let session = AVCaptureSession()
    private let holdStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startEntered = false
    private(set) var stopCalls = 0

    init(holdStart: Bool) { self.holdStart = holdStart }

    func start() async throws {
        startEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
    }

    func stop() async { stopCalls += 1 }
    func deactivate() {}

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

@MainActor
private final class RecordingImmersiveCallCounter { var calls = 0 }

@MainActor
private final class RecordingImmersiveDiscoveryGate {
    private let result: RecordingSourceInventory
    private var continuation: CheckedContinuation<RecordingSourceInventory, Never>?
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: RecordingSourceInventory) { self.result = result }

    func waitForResult() async -> RecordingSourceInventory {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private enum RecordingImmersiveWorkflowError: Error {
    case discovery
    case startup
}

@MainActor
private final class RecordingImmersiveWorkflowEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var stopCalls = 0
    private(set) var startCalls = 0
    var startError: RecordingImmersiveWorkflowError?
    var emitSegmentOnStop = false
    private var directory: URL?

    func start(configuration: RecordingConfiguration, directory: URL) async throws {
        startCalls += 1
        self.directory = directory
        if let startError { throw startError }
    }
    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws {
        stopCalls += 1
        if emitSegmentOnStop, let directory {
            let path = "workflow-screen-\(stopCalls).mov"
            try Data([0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d]).write(to: directory.appendingPathComponent(path))
            onSegment?(RecordingSegment(sourceID: "screen", relativePath: path,
                                        timelineStartMicroseconds: 0, durationMicroseconds: 1_000_000,
                                        width: 1920, height: 1080))
        }
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
) async {
    let start = ContinuousClock.now
    while !condition(), ContinuousClock.now - start < timeout { await Task.yield() }
    #expect(condition(), "Timed out waiting for controlled recording workflow event.")
}
