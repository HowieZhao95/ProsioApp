import AppKit
import Foundation
import Testing

@Suite("Recording termination flush")
@MainActor
struct RecordingTerminationTests {
    @Test
    func testTerminationWaitsForStopAndPersistsFinalSegmentCallback() async throws {
        let harness = try TerminationHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        engine.holdStop = true
        engine.emitFinalSegment = true

        await harness.coordinator.start(configuration: Self.configuration, countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)
        var flushReturned = false
        let entered = FlushEntryBarrier()
        let flush = Task { @MainActor in
            entered.markEntered()
            await harness.coordinator.flushForTermination()
            flushReturned = true
        }

        await entered.waitUntilEntered()
        await engine.waitUntilStopEntered()
        #expect(!flushReturned)
        #expect(engine.stopCalls == 1)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == sessionID })?.segments.isEmpty == true)

        engine.releaseStop()
        await flush.value

        let finished = try #require(harness.reloadStore().sessions.first(where: { $0.id == sessionID }))
        #expect(flushReturned)
        #expect(harness.coordinator.phase == .ready)
        #expect(finished.phase == .ready)
        #expect(finished.segments.count == 1)
        #expect(finished.segments[0].sourceID == "screen")
        #expect(finished.segments[0].durationMicroseconds == 1_000_000)
        #expect(finished.segments[0].width == 1920)
        #expect(finished.segments[0].height == 1080)
        let media = harness.coordinator.store.directory(for: sessionID).appendingPathComponent(finished.segments[0].relativePath)
        #expect((try Data(contentsOf: media)).count > 0)
        #expect(engine.stopCalls == 1)
    }

    @Test
    func testTerminationJoinsAnAlreadyRunningStopInsteadOfReturningEarly() async throws {
        let harness = try TerminationHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        engine.holdStop = true
        engine.emitFinalSegment = true

        await harness.coordinator.start(configuration: Self.configuration, countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)
        let stop = Task { @MainActor in await harness.coordinator.stop() }
        await engine.waitUntilStopEntered()

        var flushReturned = false
        let entered = FlushEntryBarrier()
        let flush = Task { @MainActor in
            entered.markEntered()
            await harness.coordinator.flushForTermination()
            flushReturned = true
        }
        await entered.waitUntilEntered()
        #expect(!flushReturned)
        #expect(engine.stopCalls == 1)

        engine.releaseStop()
        await stop.value
        await flush.value

        let finished = try #require(harness.reloadStore().sessions.first(where: { $0.id == sessionID }))
        #expect(flushReturned)
        #expect(harness.coordinator.phase == .ready)
        #expect(finished.phase == .ready)
        #expect(finished.segments.count == 1)
        #expect(engine.stopCalls == 1)
    }

    @Test
    func testTerminationStopsAndFinalizesPausedRecording() async throws {
        let harness = try TerminationHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        engine.holdStop = true
        engine.emitFinalSegment = true

        await harness.coordinator.start(configuration: Self.configuration, countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)
        await harness.coordinator.togglePause()
        #expect(harness.coordinator.phase == .paused)
        #expect(harness.coordinator.store.sessions.first(where: { $0.id == sessionID })?.phase == .paused)

        let flush = Task { @MainActor in await harness.coordinator.flushForTermination() }
        await engine.waitUntilStopEntered()
        #expect(engine.stopCalls == 1)
        engine.releaseStop()
        await flush.value

        let finished = try #require(harness.reloadStore().sessions.first(where: { $0.id == sessionID }))
        #expect(harness.coordinator.phase == .ready)
        #expect(finished.phase == .ready)
        #expect(finished.segments.count == 1)
        #expect(engine.pauseCalls == 1)
        #expect(engine.resumeCalls == 0)
        #expect(engine.stopCalls == 1)
    }

    @Test
    func testConcurrentTerminationWaitersShareOneUnderlyingStop() async throws {
        let harness = try TerminationHarness()
        defer { harness.cleanup() }
        let engine = harness.engine
        engine.holdStop = true
        engine.emitFinalSegment = true

        await harness.coordinator.start(configuration: Self.configuration, countdownSeconds: 0, requestPermissions: false)
        let sessionID = try #require(harness.coordinator.activeSession?.id)
        var firstReturned = false
        var secondReturned = false
        let firstEntered = FlushEntryBarrier()
        let secondEntered = FlushEntryBarrier()
        let first = Task { @MainActor in
            firstEntered.markEntered()
            await harness.coordinator.flushForTermination()
            firstReturned = true
        }
        await engine.waitUntilStopEntered()
        let second = Task { @MainActor in
            secondEntered.markEntered()
            await harness.coordinator.flushForTermination()
            secondReturned = true
        }
        await firstEntered.waitUntilEntered()
        await secondEntered.waitUntilEntered()
        #expect(!firstReturned)
        #expect(!secondReturned)
        #expect(engine.stopCalls == 1)

        engine.releaseStop()
        await first.value
        await second.value

        let finished = try #require(harness.reloadStore().sessions.first(where: { $0.id == sessionID }))
        #expect(firstReturned)
        #expect(secondReturned)
        #expect(engine.stopCalls == 1)
        #expect(harness.coordinator.phase == .ready)
        #expect(finished.phase == .ready)
        #expect(finished.segments.count == 1)
    }

    private static var configuration: RecordingConfiguration {
        // Exercise the opt-out path with sources that would normally prompt for TCC.
        // The injected engine is fake and requestPermissions:false skips authorization entirely.
        RecordingConfiguration(
            screenTarget: .display(1),
            cameras: [RecordingSource(id: "camera-fake", kind: .camera, name: "Fake Camera")],
            microphone: RecordingSource(id: "microphone-fake", kind: .microphone, name: "Fake Microphone"),
            capturesSystemAudio: false
        )
    }
}

@MainActor
private final class TerminationHarness {
    let coordinator: RecordingCoordinator
    let engine = TerminationFakeEngine()
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-termination-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = self.engine
        coordinator = RecordingCoordinator(
            root: root,
            permissions: PermissionsManager(),
            makeEngine: { engine }
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func reloadStore() -> RecordingStore { RecordingStore(root: root) }
}

@MainActor
private final class FlushEntryBarrier {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class TerminationFakeEngine: RecordingEngineControlling {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0
    var holdStop = false
    var emitFinalSegment = false

    private var directory: URL?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopHasEntered = false

    func start(configuration: RecordingConfiguration, directory: URL) async throws {
        startCalls += 1
        self.directory = directory
    }

    func pause() async throws { pauseCalls += 1 }
    func resume() async throws { resumeCalls += 1 }

    func stop() async throws {
        stopCalls += 1
        stopHasEntered = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if holdStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        if emitFinalSegment { try emitSegment() }
    }

    func waitUntilStopEntered() async {
        guard !stopHasEntered else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func emitSegment() throws {
        guard let directory else { throw TerminationFakeEngineError.noDirectory }
        let path = "termination-screen.mov"
        try Data([0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d]).write(to: directory.appendingPathComponent(path))
        onSegment?(RecordingSegment(
            sourceID: "screen",
            relativePath: path,
            timelineStartMicroseconds: 0,
            durationMicroseconds: 1_000_000,
            width: 1920,
            height: 1080
        ))
    }
}

private enum TerminationFakeEngineError: Error {
    case noDirectory
}
