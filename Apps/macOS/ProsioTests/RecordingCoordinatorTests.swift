import AppKit
import Foundation
import Testing

@Suite("Recording coordinator lifecycle")
@MainActor
struct RecordingCoordinatorTests {
    @Test
    @MainActor
    func testStartupFailureStopsEngineReleasesReservationAndKeepsFinalizedRawMedia() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        engine.emitOnStart = true
        engine.emitOnStop = true
        engine.startError = FakeEngineError.startup

        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)

        #expect(engine.startCalls == 1)
        #expect(engine.stopCalls == 1)
        #expect(harness.activityValues == [true, false])
        #expect(harness.coordinator.activeSession == nil)
        #expect(harness.coordinator.phase == .failed)
        let failed = try #require(harness.coordinator.store.sessions.first)
        #expect(failed.phase == .interrupted)
        #expect(failed.segments.count >= 1)
        for segment in failed.segments {
            #expect(FileManager.default.fileExists(atPath: harness.coordinator.store.directory(for: failed.id).appendingPathComponent(segment.relativePath).path))
        }
    }

    @Test
    @MainActor
    func testPauseResumePersistsTransitionsAndStopWaitsForFinalizedSegmentCallbacks() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)

        await harness.coordinator.togglePause()
        #expect(harness.coordinator.phase == .paused)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == sessionID })?.phase == .paused)
        #expect(engine.pauseCalls == 1)

        await harness.coordinator.togglePause()
        #expect(harness.coordinator.phase == .recording)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == sessionID })?.phase == .recording)
        #expect(engine.resumeCalls == 1)

        engine.holdStop = true
        engine.emitOnStop = true
        let stopTask = Task { await harness.coordinator.stop() }
        await waitUntil { engine.stopEntered }
        #expect(harness.coordinator.phase == .finalizing)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == sessionID })?.phase == .finalizing)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == sessionID })?.segments.isEmpty == true)

        // Finalized media arrives while stop is still pending. The coordinator persists it before ready.
        engine.releaseStop()
        await stopTask.value
        let finished = try #require(harness.coordinator.store.sessions.first(where: { $0.id == sessionID }))
        #expect(harness.coordinator.phase == .ready)
        #expect(finished.phase == .ready)
        #expect(finished.segments.count == 1)
        #expect(FileManager.default.fileExists(atPath: harness.coordinator.store.directory(for: sessionID).appendingPathComponent(finished.segments[0].relativePath).path))
    }

    @Test
    @MainActor
    func testConcurrentStopRequestsShareOneUnderlyingFinalization() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)
        engine.holdStop = true

        let first = Task { await harness.coordinator.stop() }
        await waitUntil { engine.stopEntered }
        await harness.coordinator.stop()
        #expect(engine.stopCalls == 1)

        engine.releaseStop()
        await first.value
        #expect(engine.stopCalls == 1)
        #expect(harness.coordinator.phase == .failed) // No finalized segment was produced.
    }

    @Test
    @MainActor
    func testCallbacksFromFinishedSessionCannotChangeNextSession() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let firstEngine = harness.engines.next
        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)
        firstEngine.emitOnStop = true
        let firstID = try #require(harness.coordinator.activeSession?.id)
        let staleCallback = try #require(firstEngine.onSegment)
        await harness.coordinator.stop()
        let firstCount = try #require(harness.coordinator.store.sessions.first(where: { $0.id == firstID })).segments.count

        let secondEngine = harness.engines.next
        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)
        let secondID = try #require(harness.coordinator.activeSession?.id)
        #expect(firstID != secondID)

        let staleSegment = try firstEngine.makeSegment(sourceID: "screen", index: 99)
        staleCallback(staleSegment)
        #expect(harness.coordinator.activeSession?.id == secondID)
        #expect(harness.coordinator.activeSession?.segments.isEmpty == true)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == firstID })?.segments.count == firstCount)

        secondEngine.emitOnStop = true
        await harness.coordinator.stop()
    }

    @Test
    @MainActor
    func testFatalEngineFailureEndsAsInterruptedAndPreservesCompletedSegment() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)
        engine.emitOnStop = true
        engine.onFailure?("屏幕来源断开")
        await waitUntil { harness.coordinator.phase == .interrupted }

        let recovered = try #require(harness.coordinator.store.sessions.first(where: { $0.id == sessionID }))
        #expect(harness.coordinator.phase == .interrupted)
        #expect(recovered.phase == .interrupted)
        #expect(recovered.segments.count == 1)
        #expect(recovered.warnings.contains { $0.contains("屏幕来源断开") })
        #expect(engine.stopCalls == 1)
    }

    @Test
    @MainActor
    func testCountdownCancellationDoesNotCreateReadySessionAndReleasesReservation() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        let preparation = Task {
            await harness.coordinator.start(configuration: configuration(), countdownSeconds: 30, requestPermissions: false)
        }
        await waitUntil { harness.coordinator.countdown != nil }
        #expect(harness.coordinator.phase == .preparing)
        preparation.cancel()
        await preparation.value

        #expect(harness.coordinator.phase == .failed)
        #expect(harness.coordinator.activeSession == nil)
        #expect(harness.coordinator.store.sessions.isEmpty)
        #expect(harness.activityValues == [true, false])
        #expect(engine.startCalls == 0)
        #expect(engine.stopCalls == 0)
    }

    @Test
    @MainActor
    func testCameraDisconnectChangesOnlyThatSourceAvailability() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        let cameraID = "camera-usb"
        await harness.coordinator.start(
            configuration: RecordingConfiguration(
                screenTarget: .display(1),
                cameras: [RecordingSource(id: cameraID, kind: .camera, name: "USB Camera")]
            ),
            countdownSeconds: 0,
            requestPermissions: false
        )
        #expect(harness.coordinator.sourceAvailability["screen"] == true)
        #expect(harness.coordinator.sourceAvailability[cameraID] == true)

        engine.onSourceStatus?(cameraID, false)
        #expect(harness.coordinator.sourceAvailability[cameraID] == false)
        #expect(harness.coordinator.sourceAvailability["screen"] == true)
        #expect(harness.coordinator.phase == .recording)

        engine.emitOnStop = true
        await harness.coordinator.stop()
    }

    @Test
    @MainActor
    func testManifestWriteFailureStillStopsCaptureAndDrainsFinalizedMediaCallbacks() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let engine = harness.engines.next
        await harness.coordinator.start(configuration: configuration(), countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)
        let manifestURL = harness.coordinator.store.directory(for: sessionID).appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        engine.emitOnStop = true

        _ = try engine.makeSegment(sourceID: "screen")
        await waitUntil { engine.stopEntered }
        await waitUntil { harness.coordinator.phase == .interrupted }

        #expect(engine.stopCalls == 1)
        #expect(engine.emittedSegments == 2) // In-flight plus stop-finalized callback both reached the coordinator.
        #expect(harness.activityValues == [true, false])
        #expect(harness.coordinator.activeSession == nil)
        #expect(harness.coordinator.phase == .interrupted)
        let sessionDirectory = harness.coordinator.store.directory(for: sessionID)
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("fake-screen-0.mov").path))
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("fake-screen-1.mov").path))
    }

    @MainActor
    private func configuration() -> RecordingConfiguration {
        RecordingConfiguration(screenTarget: .display(1), capturesSystemAudio: false)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < timeout {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), "Timed out waiting for coordinator lifecycle transition.")
    }
}

@MainActor
private final class Harness {
    let coordinator: RecordingCoordinator
    let engines = FakeEngineFactory()
    private let root: URL
    private(set) var activityValues: [Bool] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        coordinator = RecordingCoordinator(root: root, permissions: PermissionsManager(), makeEngine: { [engines] in engines.make() })
        coordinator.onActivity = { [weak self] active in self?.activityValues.append(active) }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class FakeEngineFactory {
    private(set) var created: [FakeRecordingEngine] = []
    private var queued: [FakeRecordingEngine] = []
    var next: FakeRecordingEngine {
        if queued.isEmpty {
            let engine = FakeRecordingEngine()
            created.append(engine)
            queued.append(engine)
        }
        return queued[0]
    }

    func make() -> FakeRecordingEngine {
        if !queued.isEmpty { return queued.removeFirst() }
        let engine = FakeRecordingEngine()
        created.append(engine)
        return engine
    }
}

@MainActor
private final class FakeRecordingEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var stopEntered = false
    var holdStop = false
    var emitOnStart = false
    var emitOnStop = false
    var startError: FakeEngineError?
    private(set) var directory: URL?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var nextSegmentIndex = 0
    private(set) var emittedSegments = 0

    func start(configuration: RecordingConfiguration, directory: URL) async throws {
        startCalls += 1
        self.directory = directory
        if emitOnStart { _ = try makeSegment(sourceID: "screen") }
        if let startError { throw startError }
    }

    func pause() async throws { pauseCalls += 1 }
    func resume() async throws { resumeCalls += 1 }

    func stop() async throws {
        stopCalls += 1
        stopEntered = true
        if holdStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        if emitOnStop { _ = try makeSegment(sourceID: "screen") }
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    @discardableResult
    func makeSegment(sourceID: String, index: Int? = nil) throws -> RecordingSegment {
        guard let directory else { throw FakeEngineError.noDirectory }
        let ordinal = index ?? nextSegmentIndex
        nextSegmentIndex = max(nextSegmentIndex, ordinal + 1)
        let relativePath = "fake-\(sourceID)-\(ordinal).mov"
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: directory.appendingPathComponent(relativePath))
        let segment = RecordingSegment(
            sourceID: sourceID,
            relativePath: relativePath,
            timelineStartMicroseconds: Int64(ordinal) * 1_000_000,
            durationMicroseconds: 1_000_000,
            width: 1920,
            height: 1080
        )
        onSegment?(segment)
        emittedSegments += 1
        return segment
    }
}

private enum FakeEngineError: LocalizedError {
    case startup
    case noDirectory

    var errorDescription: String? {
        switch self {
        case .startup: "假引擎启动失败"
        case .noDirectory: "假引擎尚无输出目录"
        }
    }
}
