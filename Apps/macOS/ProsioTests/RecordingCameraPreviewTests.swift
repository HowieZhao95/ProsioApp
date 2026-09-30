import AVFoundation
import XCTest

nonisolated final class RecordingCameraPreviewTests: XCTestCase {
    @MainActor func testDiscoveryAndEmptySelectionNeverAuthorizeOrCreateSessions() async throws {
        let backend = PreviewTestBackend()
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        XCTAssertEqual(backend.authorizationRequests, 0)
        try await preview.update(sources: [])
        XCTAssertEqual(backend.authorizationRequests, 0)
        XCTAssertTrue(backend.created.isEmpty)
        await preview.stopAll()
    }

    @MainActor func testLimitAndDuplicatePhysicalDeviceRejectedBeforePermission() async {
        let backend = PreviewTestBackend()
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        do { try await preview.update(sources: [camera("a"), camera("b"), camera("c")]); XCTFail() } catch {}
        var duplicate = camera("a"); duplicate.id = "another-id"
        do { try await preview.update(sources: [camera("a"), duplicate]); XCTFail() } catch {}
        XCTAssertEqual(backend.authorizationRequests, 0)
        XCTAssertTrue(backend.created.isEmpty)
    }

    @MainActor func testTwoSessionsAreRetainedAndStopReleasesBoth() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: backend.available)
        let a = try XCTUnwrap(preview.session(for: "a"))
        XCTAssertTrue(a === backend.created[0].session)
        XCTAssertEqual(preview.statuses["b"], .live)
        try await preview.update(sources: backend.available)
        XCTAssertEqual(backend.created.count, 2)
        XCTAssertTrue(preview.session(for: "a") === a)
        await preview.stopAll()
        XCTAssertTrue(backend.created.allSatisfy { $0.stopCount == 1 })
        XCTAssertNil(preview.session(for: "a"))
        XCTAssertEqual(preview.statuses["b"], .idle)
    }

    @MainActor func testDeniedPermissionDoesNotCreateSource() async {
        let backend = PreviewTestBackend()
        backend.authorized = false
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        do { try await preview.update(sources: [camera("a")]); XCTFail() } catch {}
        XCTAssertEqual(backend.authorizationRequests, 1)
        XCTAssertTrue(backend.created.isEmpty)
        XCTAssertEqual(preview.statuses["a"], .failed("denied"))
        await preview.stopAll()
    }

    @MainActor func testDisconnectedSourceReconnectsSameDeviceAndStaleCallbackCannotHideNewSession() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: backend.available)
        let original = backend.created[0]
        let otherSession = preview.session(for: "b")
        original.failure()
        XCTAssertNil(preview.session(for: "a"))
        XCTAssertEqual(preview.statuses["a"], .disconnected)
        backend.available = [camera("b")]
        await preview.refresh()
        XCTAssertTrue(preview.session(for: "b") === otherSession)
        XCTAssertEqual(original.stopCount, 1)
        XCTAssertEqual(backend.created.count, 2)
        backend.available.append(camera("a"))
        await preview.refresh()
        let restored = try XCTUnwrap(preview.session(for: "a"))
        XCTAssertFalse(restored === original.session)
        XCTAssertEqual(backend.created.last?.deviceID, "a")
        original.failure()
        XCTAssertTrue(preview.session(for: "a") === restored)
        XCTAssertEqual(preview.statuses["a"], .live)
        await preview.stopAll()
    }

    @MainActor func testRevokedPermissionDoesNotPromptDuringRetry() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: backend.available)
        backend.authorized = false
        await preview.refresh()
        await preview.refresh()
        XCTAssertNil(preview.session(for: "a"))
        XCTAssertEqual(backend.authorizationRequests, 1)
        XCTAssertEqual(backend.created.count, 1)
        await preview.stopAll()
    }

    @MainActor func testStopWaitsForInFlightSetupAndOldCallbackCannotReviveIt() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        backend.blockNext = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let start = Task { try await preview.update(sources: backend.available) }
        await wait { backend.created.first?.started == true }
        let source = try XCTUnwrap(backend.created.first)
        var stopped = false
        let stop = Task { await preview.stopAll(); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        source.release()
        _ = await start.result
        await stop.value
        XCTAssertEqual(source.stopCount, 1)
        source.failure()
        XCTAssertNil(preview.session(for: "a"))
        XCTAssertEqual(preview.statuses["a"], .idle)
    }

    @MainActor func testStopWaitsForReconnectSetup() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: backend.available)
        backend.created[0].failure()
        backend.blockNext = true
        let reconnect = Task { await preview.refresh() }
        await wait { backend.created.count == 2 && backend.created[1].started }
        let source = backend.created[1]
        var stopped = false
        let stop = Task { await preview.stopAll(); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        source.release()
        await reconnect.value
        await stop.value
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(preview.session(for: "a"))
    }

    @MainActor func testStoppedSetupReturningDeviceErrorStillReportsCancellation() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        backend.blockNext = true
        backend.failNext = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let start = Task { try await preview.update(sources: backend.available) }
        await wait { backend.created.first?.started == true }
        let source = try XCTUnwrap(backend.created.first)
        let stop = Task { await preview.stopAll() }
        await Task.yield()
        source.release()
        switch await start.result {
        case .success: XCTFail("Stopped setup must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        await stop.value
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(preview.session(for: "a"))
    }

    @MainActor func testCancellingUpdateAwaitsSourceRelease() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        backend.blockNext = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let start = Task { try await preview.update(sources: backend.available) }
        await wait { backend.created.first?.started == true }
        let source = try XCTUnwrap(backend.created.first)
        start.cancel()
        source.release()
        if case .success = await start.result { XCTFail("Cancelled setup returned success") }
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(preview.session(for: "a"))
        await preview.stopAll()
    }

    @MainActor func testChangingSelectionWaitsForOldSetupBeforeNewDeviceStarts() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        backend.blockNext = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let first = Task { try await preview.update(sources: [self.camera("a")]) }
        await wait { backend.created.first?.started == true }
        let second = Task { try await preview.update(sources: [self.camera("b")]) }
        await Task.yield()
        XCTAssertEqual(backend.created.count, 1)
        backend.created[0].release()
        _ = await first.result
        try await second.value
        XCTAssertEqual(backend.created[0].stopCount, 1)
        XCTAssertNil(preview.session(for: "a"))
        XCTAssertEqual(preview.statuses["b"], .live)
        await preview.stopAll()
    }

    @MainActor func testRecordingEngineExposesExactExistingCameraSessionOnly() async throws {
        let backend = PreviewEngineTestBackend()
        let engine = RecordingEngine(backend: backend, monitoringInterval: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingPreviewEngine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await engine.start(configuration: RecordingConfiguration(screenTarget: .window(1), cameras: [camera("a")]), directory: directory)
        XCTAssertTrue(engine.previewSession(for: "a") === backend.cameraSession)
        XCTAssertNil(engine.previewSession(for: "screen"))
        try await engine.stop()
        XCTAssertNil(engine.previewSession(for: "a"))
    }

    @MainActor func testAlreadyCancelledSelectionCannotClearLiveNewerSelection() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: [camera("b")])
        let liveSession = preview.session(for: "b")
        let stale = Task {
            while !Task.isCancelled { await Task.yield() }
            try await preview.update(sources: [self.camera("a")])
        }
        stale.cancel()
        assertCancellation(await stale.result)
        XCTAssertTrue(preview.session(for: "b") === liveSession)
        XCTAssertEqual(backend.created.count, 1)
        await preview.stopAll()
    }

    @MainActor func testCancelledSelectionWaitingForStopCannotOverrideFreshSelection() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: [camera("a")])
        let original = backend.created[0]
        original.blockStop = true
        let stop = Task { await preview.stopAll() }
        await wait { original.stopping }
        var staleEntered = false
        let stale = Task { staleEntered = true; try await preview.update(sources: [self.camera("a")]) }
        await wait { staleEntered }
        var freshEntered = false
        let fresh = Task { freshEntered = true; try await preview.update(sources: [self.camera("b")]) }
        await wait { freshEntered }
        stale.cancel()
        original.releaseStop()
        await stop.value
        assertCancellation(await stale.result)
        try await fresh.value
        XCTAssertEqual(preview.statuses["b"], .live)
        XCTAssertNil(preview.session(for: "a"))
        XCTAssertEqual(backend.created.count, 2)
        await preview.stopAll()
    }

    @MainActor func testStopWaitsForPendingPermissionAndNeverCreatesDeviceAfterApproval() async {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        backend.blockAuthorization = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let start = Task { try await preview.update(sources: backend.available) }
        await wait { backend.authorizationRequests == 1 }
        var didStop = false
        let stop = Task { await preview.stopAll(); didStop = true }
        await Task.yield()
        XCTAssertFalse(didStop)
        XCTAssertTrue(backend.created.isEmpty)
        backend.releaseAuthorization()
        assertCancellation(await start.result)
        await stop.value
        XCTAssertTrue(didStop)
        XCTAssertTrue(backend.created.isEmpty)
        XCTAssertNil(preview.session(for: "a"))
    }

    @MainActor func testSelectionResumingAfterStopRemainsTrackedThroughAnotherStop() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: [camera("a")])
        let original = backend.created[0]
        original.blockStop = true
        let firstStop = Task { await preview.stopAll() }
        await wait { original.stopping }
        backend.blockNext = true
        var newSelectionEntered = false
        let next = Task { newSelectionEntered = true; try await preview.update(sources: [self.camera("b")]) }
        await wait { newSelectionEntered }
        original.releaseStop()
        await firstStop.value
        await wait { backend.created.count == 2 && backend.created[1].started }
        let pending = backend.created[1]
        var finalStopCompleted = false
        let finalStop = Task { await preview.stopAll(); finalStopCompleted = true }
        await Task.yield()
        XCTAssertFalse(finalStopCompleted)
        pending.release()
        assertCancellation(await next.result)
        await finalStop.value
        XCTAssertTrue(finalStopCompleted)
        XCTAssertEqual(pending.stopCount, 1)
        XCTAssertNil(preview.session(for: "b"))
    }

    @MainActor func testSupersededPermissionFailureDuringDeviceReleaseCannotOverrideLatestSelection() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        try await preview.update(sources: [camera("a")])
        let original = backend.created[0]
        original.blockStop = true
        backend.authorized = false
        let denied = Task { try await preview.update(sources: [self.camera("b")]) }
        await wait { original.stopping }
        backend.authorized = true
        var latestEntered = false
        let latest = Task { latestEntered = true; try await preview.update(sources: [self.camera("b")]) }
        await wait { latestEntered }
        original.releaseStop()
        assertCancellation(await denied.result)
        try await latest.value
        XCTAssertEqual(preview.statuses["b"], .live)
        XCTAssertNotNil(preview.session(for: "b"))
        XCTAssertEqual(backend.created.count, 2)
        await preview.stopAll()
    }

    @MainActor func testCancelledPermissionDenialReturnsCancellationRatherThanStaleFailure() async {
        let backend = PreviewTestBackend()
        backend.available = [camera("a")]
        backend.blockAuthorization = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let start = Task { try await preview.update(sources: backend.available) }
        await wait { backend.authorizationRequests == 1 }
        start.cancel()
        backend.authorized = false
        backend.releaseAuthorization()
        assertCancellation(await start.result)
        XCTAssertTrue(backend.created.isEmpty)
        XCTAssertEqual(preview.statuses["a"], .idle)
        await preview.stopAll()
    }

    @MainActor func testRapidSelectionDuringPermissionWaitSerializesAuthorizationAndStartsOnlyLatest() async throws {
        let backend = PreviewTestBackend()
        backend.available = [camera("a"), camera("b")]
        backend.blockAuthorization = true
        let preview = RecordingCameraPreviewController(backend: backend, monitoringInterval: nil)
        let first = Task { try await preview.update(sources: [self.camera("a")]) }
        await wait { backend.authorizationRequests == 1 }
        var secondEntered = false
        let second = Task { secondEntered = true; try await preview.update(sources: [self.camera("b")]) }
        await wait { secondEntered }
        XCTAssertEqual(backend.authorizationRequests, 1)
        backend.releaseAuthorization()
        assertCancellation(await first.result)
        try await second.value
        XCTAssertEqual(backend.maxConcurrentAuthorization, 1)
        XCTAssertEqual(backend.created.map(\.deviceID), ["b"])
        XCTAssertEqual(preview.statuses["b"], .live)
        await preview.stopAll()
    }

    @MainActor private func assertCancellation(_ result: Result<Void, any Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("Cancelled operation returned success", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }

    @MainActor func testTemporaryMicrophoneFilterRetainsNormalUSBAndVirtualDevices() {
        XCTAssertTrue(RecordingEngine.isTemporaryAggregateMicrophone(id: "CADefaultDeviceAggregate-86652-0", name: "Input"))
        XCTAssertTrue(RecordingEngine.isTemporaryAggregateMicrophone(id: "input", name: "CADefaultDeviceAggregate-86652-0"))
        XCTAssertFalse(RecordingEngine.isTemporaryAggregateMicrophone(id: "usb-device", name: "USB microphone"))
        XCTAssertFalse(RecordingEngine.isTemporaryAggregateMicrophone(id: "virtual-device", name: "BlackHole 2ch"))
    }

    nonisolated private func camera(_ id: String) -> RecordingSource { RecordingSource(id: id, kind: .camera, name: id, deviceID: id) }
    @MainActor private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 { if predicate() { return }; await Task.yield() }
        XCTFail("Lifecycle operation did not reach the deterministic gate")
    }
}

@MainActor private final class PreviewTestBackend: RecordingCameraPreviewBackend {
    var available: [RecordingSource] = []
    var authorized = true
    var blockNext = false
    var failNext = false
    var authorizationRequests = 0
    var blockAuthorization = false
    var maxConcurrentAuthorization = 0
    private var concurrentAuthorization = 0
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    var created: [PreviewTestSource] = []
    var isAuthorized: Bool { authorized }
    func authorize() async throws {
        authorizationRequests += 1
        concurrentAuthorization += 1
        maxConcurrentAuthorization = max(maxConcurrentAuthorization, concurrentAuthorization)
        defer { concurrentAuthorization -= 1 }
        if blockAuthorization {
            blockAuthorization = false
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        if !authorized { throw NSError(domain: "PreviewTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"]) }
    }
    func releaseAuthorization() { authorizationContinuation?.resume(); authorizationContinuation = nil }
    func availableSources() -> [RecordingSource] { available }
    func makeSource(_ source: RecordingSource, onFailure: @escaping @MainActor @Sendable () -> Void) -> any RecordingCameraPreviewSource {
        let capture = PreviewTestSource(deviceID: source.deviceID!, blocked: blockNext, failsStart: failNext, failure: onFailure)
        blockNext = false
        failNext = false
        created.append(capture)
        return capture
    }
}

@MainActor private final class PreviewTestSource: RecordingCameraPreviewSource, RecordingCameraPreviewProviding {
    let session = AVCaptureSession() // No inputs, device setup or startRunning in tests.
    let deviceID: String
    let blocked: Bool
    let failsStart: Bool
    let failure: @MainActor @Sendable () -> Void
    var started = false
    var stopCount = 0
    var blockStop = false
    var stopping = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    init(deviceID: String, blocked: Bool, failsStart: Bool, failure: @escaping @MainActor @Sendable () -> Void) {
        self.deviceID = deviceID; self.blocked = blocked; self.failsStart = failsStart; self.failure = failure
    }
    func start() async throws {
        started = true
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if failsStart { throw RecordingPlatformError.unavailable("Device failed during start") }
    }
    func release() { continuation?.resume(); continuation = nil }
    func stop() async {
        stopCount += 1
        stopping = true
        if blockStop { await withCheckedContinuation { stopContinuation = $0 } }
    }
    func releaseStop() { stopContinuation?.resume(); stopContinuation = nil }
    func previewSession(for sourceID: String) -> AVCaptureSession? { session }
}

@MainActor private final class PreviewEngineTestBackend: RecordingCaptureBackend {
    let cameraSession = AVCaptureSession()
    func makeScreen(configuration: RecordingConfiguration, isRetry: Bool, writer: RecordingMediaWriter,
                    callbacks: RecordingCaptureCallbacks) async throws -> any RecordingCaptureSource {
        PreviewEngineTestSource(session: AVCaptureSession())
    }
    func makeDevice(source: RecordingSource, framesPerSecond: Int, writer: RecordingMediaWriter,
                    callbacks: RecordingCaptureCallbacks) -> any RecordingCaptureSource {
        PreviewEngineTestSource(session: cameraSession)
    }
    func availableDevices(kind: RecordingSourceKind) -> [RecordingSource] { [] }
}

@MainActor private final class PreviewEngineTestSource: RecordingCaptureSource, RecordingCameraPreviewProviding {
    let session: AVCaptureSession
    init(session: AVCaptureSession) { self.session = session }
    func start() async throws {}
    func stop() async {}
    func previewSession(for sourceID: String) -> AVCaptureSession? { session }
}
