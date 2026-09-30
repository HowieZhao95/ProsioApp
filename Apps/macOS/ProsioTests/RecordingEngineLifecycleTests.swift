import AVFoundation
import CoreMedia
import XCTest

nonisolated final class RecordingEngineLifecycleTests: XCTestCase {
    @MainActor func testStopAwaitsScreenPreparationAndPreventsLateStart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preparation = LifecycleGate()
        fixture.backend.preparationGate = preparation
        let start = Task { try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory) }
        await waitUntil { fixture.backend.screens.count == 1 }
        var stopped = false
        let stop = Task { try await fixture.engine.stop(); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        preparation.release()
        do { try await start.value; XCTFail("Cancelled preparation must not report a started recording.") } catch {}
        try await stop.value
        XCTAssertEqual(fixture.backend.screens.first?.startCount, 0)
        XCTAssertEqual(fixture.backend.screens.first?.stopCount, 1)
        XCTAssertTrue(fixture.backend.devices.isEmpty)
    }

    @MainActor func testStopAwaitsInitialDeviceSetupAndDoesNotStartSecondDevice() async throws {
        let fixture = try makeFixture(cameraCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let setup = LifecycleGate()
        fixture.backend.nextDeviceStartGate = setup
        let start = Task { try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory) }
        await waitUntil { fixture.backend.devices.first?.startCount == 1 }
        var stopped = false
        let stop = Task { try await fixture.engine.stop(); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        setup.release()
        do { try await start.value; XCTFail("Stopped setup must fail start.") } catch {}
        try await stop.value
        XCTAssertEqual(fixture.backend.devices.count, 1)
        XCTAssertEqual(fixture.backend.devices.first?.stopCount, 1)
        XCTAssertEqual(fixture.backend.screens.first?.startCount, 0)
    }

    @MainActor func testStopOwnsAndAwaitsInFlightReconnect() async throws {
        let fixture = try makeFixture(cameraCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let original = try XCTUnwrap(fixture.backend.devices.first)
        original.callbacks.failed("runtime error")
        await waitUntil { original.stopCount == 1 }
        await settle()
        let reconnect = LifecycleGate()
        fixture.backend.nextDeviceStartGate = reconnect
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.devices.count == 2 && fixture.backend.devices.last?.startCount == 1 }
        var stopped = false
        let stop = Task { try await fixture.engine.stop(); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        reconnect.release()
        try await stop.value
        XCTAssertGreaterThanOrEqual(fixture.backend.devices.last?.stopCount ?? 0, 1)
        XCTAssertFalse(fixture.backend.devices.last?.running ?? true)
        XCTAssertEqual(fixture.backend.screens.first?.stopCount, 1)
    }

    @MainActor func testOldCallbacksCannotMutateReusedEngineOrCurrentDeviceAttempt() async throws {
        let fixture = try makeFixture(cameraCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var statuses: [(String, Bool)] = []
        var failures: [String] = []
        fixture.engine.onSourceStatus = { statuses.append(($0, $1)) }
        fixture.engine.onFailure = { failures.append($0) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let oldScreen = try XCTUnwrap(fixture.backend.screens.first)
        let oldCamera = try XCTUnwrap(fixture.backend.devices.first)
        try await fixture.engine.stop()
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        statuses.removeAll()
        oldScreen.callbacks.failed("late screen failure")
        oldScreen.callbacks.availabilityChanged(false)
        oldCamera.callbacks.failed("late device failure")
        fixture.engine.monitorSources()
        await settle()
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.backend.devices.count, 2)
        let current = try XCTUnwrap(fixture.backend.devices.last)
        current.callbacks.failed("current error")
        await waitUntil { current.stopCount == 1 }
        await settle()
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.devices.count == 3 && fixture.backend.devices.last?.running == true }
        statuses.removeAll()
        current.callbacks.failed("late failure from replaced source in same recording")
        await settle()
        XCTAssertTrue(statuses.isEmpty)
        try await fixture.engine.stop()
    }

    @MainActor func testRuntimeFailureReconnectsEvenWhileDeviceStillEnumerated() async throws {
        let fixture = try makeFixture(cameraCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var statuses: [(String, Bool)] = []
        fixture.engine.onSourceStatus = { statuses.append(($0, $1)) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let camera = try XCTUnwrap(fixture.backend.devices.first)
        camera.callbacks.failed("runtime error with connected device")
        await waitUntil { camera.stopCount == 1 }
        await settle()
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.devices.count == 2 && fixture.backend.devices.last?.running == true }
        XCTAssertEqual(fixture.backend.devices.last?.source?.deviceID, camera.source?.deviceID)
        XCTAssertTrue(statuses.contains { $0.0 == camera.source?.id && !$0.1 })
        XCTAssertTrue(statuses.contains { $0.0 == camera.source?.id && $0.1 })
        XCTAssertEqual(fixture.backend.screens.first?.stopCount, 0)
        try await fixture.engine.stop()
    }

    @MainActor func testMicrophoneRemovalLeavesScreenAndOtherCameraRunningAndRestoresExactDevice() async throws {
        let fixture = try makeFixture(cameraCount: 1, microphone: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var failures: [String] = []
        fixture.engine.onFailure = { failures.append($0) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let microphone = try XCTUnwrap(fixture.backend.devices.first { $0.source?.kind == .microphone })
        fixture.backend.available.removeAll { $0.kind == .microphone }
        fixture.engine.monitorSources()
        await waitUntil { microphone.stopCount == 1 }
        await settle()
        XCTAssertEqual(fixture.backend.screens.first?.stopCount, 0)
        XCTAssertTrue(fixture.backend.devices.first { $0.source?.kind == .camera }?.running ?? false)
        XCTAssertTrue(failures.isEmpty)
        fixture.backend.available.append(try XCTUnwrap(microphone.source))
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.devices.count == 3 && fixture.backend.devices.last?.running == true }
        XCTAssertEqual(fixture.backend.devices.last?.source?.deviceID, microphone.source?.deviceID)
        try await fixture.engine.stop()
    }

    @MainActor func testFailedStartupRollsBackEveryOwnedSourceAndCanRetry() async throws {
        let fixture = try makeFixture(cameraCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.backend.failDeviceCreationNumber = 2
        do {
            try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
            XCTFail("Device failure must fail startup.")
        } catch {}
        XCTAssertEqual(fixture.backend.devices.count, 2)
        XCTAssertTrue(fixture.backend.devices.allSatisfy { !$0.running && $0.stopCount == 1 })
        XCTAssertEqual(fixture.backend.screens.first?.stopCount, 1)
        fixture.backend.failDeviceCreationNumber = nil
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        XCTAssertTrue(fixture.backend.screens.last?.running ?? false)
        try await fixture.engine.stop()
        try await fixture.engine.stop()
        XCTAssertEqual(fixture.backend.screens.last?.stopCount, 1)
    }

    @MainActor func testConcurrentPauseResumePauseKeepsLastIntentAndDropsPausedSamples() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var segments: [RecordingSegment] = []
        fixture.engine.onSegment = { segments.append($0) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let writer = try XCTUnwrap(fixture.backend.writer)
        let queueGate = DispatchSemaphore(value: 0)
        writer.queue.async { _ = queueGate.wait(timeout: .now() + 5) }
        let firstPause = Task { try await fixture.engine.pause() }
        await settle()
        let resume = Task { try await fixture.engine.resume() }
        await settle()
        let lastPause = Task { try await fixture.engine.pause() }
        await settle()
        queueGate.signal()
        try await firstPause.value
        try await resume.value
        try await lastPause.value
        writer.append(try frameNow(), sourceID: "screen", kind: .screen)
        await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
        try await fixture.engine.resume()
        writer.append(try frameNow(), sourceID: "screen", kind: .screen)
        await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
        try await fixture.engine.stop()
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments.first?.durationMicroseconds ?? .max, 34_000)
    }

    @MainActor func testRuntimeScreenLossKeepsDevicesRunningAndRecoversOriginalTargetWithGap() async throws {
        let target = RecordingScreenTarget.region(displayID: 7, rect: RecordingRegion(x: 20, y: 30, width: 640, height: 480))
        let fixture = try makeFixture(cameraCount: 1, microphone: true, screenTarget: target)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var segments: [RecordingSegment] = []
        var failures: [String] = []
        var statuses: [(String, Bool)] = []
        fixture.engine.onSegment = { segments.append($0) }
        fixture.engine.onFailure = { failures.append($0) }
        fixture.engine.onSourceStatus = { statuses.append(($0, $1)) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let writer = try XCTUnwrap(fixture.backend.writer)
        let firstFrame = try frameNow()
        writer.append(firstFrame, sourceID: "screen", kind: .screen)
        await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
        let old = try XCTUnwrap(fixture.backend.screens.first)
        old.callbacks.failed("selected display disappeared")
        await waitUntil { old.stopCount == 1 }
        await settle()
        XCTAssertTrue(fixture.backend.devices.allSatisfy(\.running))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(statuses.contains { $0.0 == "screen" && !$0.1 })
        XCTAssertTrue(statuses.contains { $0.0 == "systemAudio" && !$0.1 })
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screens.count == 2 && fixture.backend.screens.last?.running == true }
        await settle()
        XCTAssertEqual(fixture.backend.screenRequests.map(\.target), [target, target])
        XCTAssertEqual(fixture.backend.screenRequests.map(\.isRetry), [false, true])
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(firstFrame) + CMTime(seconds: 1, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var later: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: firstFrame,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &later), noErr)
        writer.append(try XCTUnwrap(later), sourceID: "screen", kind: .screen)
        await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
        try await fixture.engine.stop()
        let ordered = segments.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
        XCTAssertEqual(ordered.count, 2)
        if ordered.count == 2 {
            XCTAssertEqual(ordered[1].timelineStartMicroseconds - ordered[0].timelineStartMicroseconds, 1_000_000)
            XCTAssertLessThan(ordered[0].timelineEndMicroseconds ?? .max, ordered[1].timelineStartMicroseconds)
        }
    }

    @MainActor func testOldScreenCallbacksCannotReviveFailedOrReplacedAttempt() async throws {
        let fixture = try makeFixture(cameraCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var statuses: [(String, Bool)] = []
        var failures: [String] = []
        fixture.engine.onSourceStatus = { statuses.append(($0, $1)) }
        fixture.engine.onFailure = { failures.append($0) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let old = try XCTUnwrap(fixture.backend.screens.first)
        old.callbacks.failed("runtime loss")
        statuses.removeAll()
        old.callbacks.availabilityChanged(true) // Same attempt, already failed: cannot revive status.
        XCTAssertTrue(statuses.isEmpty)
        await waitUntil { old.stopCount == 1 }
        await settle()
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screens.count == 2 && fixture.backend.screens.last?.running == true }
        await settle()
        statuses.removeAll()
        old.callbacks.failed("late repeated failure")
        old.callbacks.availabilityChanged(false)
        fixture.engine.monitorSources()
        await settle()
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.backend.screens.count, 2)
        XCTAssertTrue(fixture.backend.devices.allSatisfy(\.running))
        try await fixture.engine.stop()
    }

    @MainActor func testStopWaitsForScreenReconnectPreparation() async throws {
        let fixture = try makeFixture(cameraCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let old = try XCTUnwrap(fixture.backend.screens.first)
        old.callbacks.failed("runtime loss")
        await waitUntil { old.stopCount == 1 }
        await settle()
        let preparation = LifecycleGate()
        fixture.backend.preparationGate = preparation
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screens.count == 2 }
        var stopped = false
        let stop = Task { try await fixture.engine.stop(); stopped = true }
        await settle()
        XCTAssertFalse(stopped)
        preparation.release()
        try await stop.value
        XCTAssertEqual(fixture.backend.screens.last?.startCount, 0)
        XCTAssertGreaterThanOrEqual(fixture.backend.screens.last?.stopCount ?? 0, 1)
        XCTAssertFalse(fixture.backend.screens.last?.running ?? true)
        XCTAssertTrue(fixture.backend.devices.allSatisfy { !$0.running })
    }

    @MainActor func testStopWaitsForScreenReconnectStart() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let old = try XCTUnwrap(fixture.backend.screens.first)
        old.callbacks.failed("runtime loss")
        await waitUntil { old.stopCount == 1 }
        await settle()
        let setup = LifecycleGate()
        fixture.backend.nextScreenStartGate = setup
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screens.count == 2 && fixture.backend.screens.last?.startCount == 1 }
        var stopped = false
        let stop = Task { try await fixture.engine.stop(); stopped = true }
        await settle()
        XCTAssertFalse(stopped)
        setup.release()
        try await stop.value
        XCTAssertGreaterThanOrEqual(fixture.backend.screens.last?.stopCount ?? 0, 1)
        XCTAssertFalse(fixture.backend.screens.last?.running ?? true)
    }

    @MainActor func testScreenPermissionAndUnavailableTargetRetriesStayIsolatedAndNeverSubstitute() async throws {
        let target = RecordingScreenTarget.window(44)
        let fixture = try makeFixture(cameraCount: 1, microphone: true, screenTarget: target)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var failures: [String] = []
        var warnings: [String] = []
        fixture.engine.onFailure = { failures.append($0) }
        fixture.engine.onWarning = { warnings.append($0) }
        try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
        let old = try XCTUnwrap(fixture.backend.screens.first)
        old.callbacks.failed("runtime loss")
        await waitUntil { old.stopCount == 1 }
        await settle()
        fixture.backend.screenPermissionAvailable = false
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screenRequests.count == 2 }
        await settle()
        XCTAssertEqual(fixture.backend.screenContentLookups, 1) // No discovery/TCC path after denied preflight.
        XCTAssertEqual(fixture.backend.screens.count, 1)
        XCTAssertTrue(fixture.backend.devices.allSatisfy(\.running))
        let warningCount = warnings.count
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screenRequests.count == 3 }
        await settle()
        XCTAssertEqual(warnings.count, warningCount) // A stable outage does not spam the user.
        fixture.backend.screenPermissionAvailable = true
        fixture.backend.screenTargetAvailable = false
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screenRequests.count == 4 }
        await settle()
        XCTAssertEqual(fixture.backend.screens.count, 1)
        XCTAssertTrue(failures.isEmpty)
        fixture.backend.screenTargetAvailable = true
        fixture.engine.monitorSources()
        await waitUntil { fixture.backend.screens.count == 2 && fixture.backend.screens.last?.running == true }
        XCTAssertTrue(fixture.backend.screenRequests.allSatisfy { $0.target == target })
        XCTAssertTrue(fixture.backend.devices.allSatisfy(\.running))
        try await fixture.engine.stop()
    }

    @MainActor func testScreenStartupDelegateFailureRollsBackDevices() async throws {
        let fixture = try makeFixture(cameraCount: 1, microphone: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.backend.failScreenCallbackCreationNumber = 1
        do {
            try await fixture.engine.start(configuration: fixture.configuration, directory: fixture.directory)
            XCTFail("A screen delegate failure during startup must fail and roll back the session.")
        } catch {}
        XCTAssertTrue(fixture.backend.devices.allSatisfy { !$0.running && $0.stopCount >= 1 })
        XCTAssertFalse(fixture.backend.screens.first?.running ?? true)
        XCTAssertGreaterThanOrEqual(fixture.backend.screens.first?.stopCount ?? 0, 1)
    }

    nonisolated func testFreshScreenReceiverCannotReuseOldStreamFrameBeforeOwnComplete() throws {
        let previous = try frameNow()
        var oldRelay = RecordingScreenFrameRelay()
        oldRelay.acceptComplete(previous)
        let timestamp = CMSampleBufferGetPresentationTimeStamp(previous) + CMTime(seconds: 1, preferredTimescale: 1_000_000)
        XCTAssertNotNil(oldRelay.idleFrame(at: timestamp))
        var replacement = RecordingScreenFrameRelay()
        XCTAssertNil(replacement.idleFrame(at: timestamp))
        let fresh = try frameNow()
        replacement.acceptComplete(fresh)
        let frame = try XCTUnwrap(replacement.idleFrame(at: timestamp))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(frame), timestamp)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(frame) === CMSampleBufferGetImageBuffer(fresh))
        XCTAssertNil(replacement.idleFrame(at: .zero))
    }

    @MainActor private func makeFixture(cameraCount: Int = 0, microphone: Bool = false, screenTarget: RecordingScreenTarget = .display(1)) throws -> LifecycleFixture {
        let cameras = (0..<cameraCount).map { RecordingSource(id: "camera-\($0)", kind: .camera, name: "Camera \($0)", deviceID: "device-\($0)") }
        let mic = microphone ? RecordingSource(id: "microphone-device", kind: .microphone, name: "Microphone", deviceID: "microphone-device") : nil
        let backend = LifecycleBackend()
        backend.available = cameras + (mic.map { [$0] } ?? [])
        let engine = RecordingEngine(backend: backend, monitoringInterval: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioEngineLifecycle-\(UUID().uuidString)")
        return LifecycleFixture(engine: engine, backend: backend, directory: directory,
            configuration: RecordingConfiguration(screenTarget: screenTarget, cameras: cameras, microphone: mic))
    }

    @MainActor private func settle() async { for _ in 0..<12 { await Task.yield() } }
    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 { if condition() { return }; await Task.yield() }
        XCTFail("Lifecycle transition did not occur.")
    }

    nonisolated private func frameNow() throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base, 70, CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

@MainActor private struct LifecycleFixture {
    let engine: RecordingEngine
    let backend: LifecycleBackend
    let directory: URL
    let configuration: RecordingConfiguration
}

@MainActor private final class LifecycleGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

@MainActor private final class LifecycleSource: RecordingCaptureSource {
    let callbacks: RecordingCaptureCallbacks
    let source: RecordingSource?
    let startGate: LifecycleGate?
    var throwsOnStart = false
    var emitsFailureOnStart = false
    var startCount = 0
    var stopCount = 0
    var running = false
    init(source: RecordingSource?, callbacks: RecordingCaptureCallbacks, startGate: LifecycleGate?) {
        self.source = source; self.callbacks = callbacks; self.startGate = startGate
    }
    func start() async throws {
        startCount += 1
        await startGate?.wait()
        if throwsOnStart { throw RecordingPlatformError.unavailable("Injected startup failure") }
        if emitsFailureOnStart { callbacks.failed("Injected screen delegate startup failure") }
        running = true
    }
    func stop() async { stopCount += 1; running = false }
}

@MainActor private final class LifecycleBackend: RecordingCaptureBackend {
    var preparationGate: LifecycleGate?
    var nextDeviceStartGate: LifecycleGate?
    var nextScreenStartGate: LifecycleGate?
    var failScreenCallbackCreationNumber: Int?
    var screenPermissionAvailable = true
    var screenTargetAvailable = true
    var screenContentLookups = 0
    var screenRequests: [(target: RecordingScreenTarget, isRetry: Bool)] = []
    var failDeviceCreationNumber: Int?
    var available: [RecordingSource] = []
    var screens: [LifecycleSource] = []
    var devices: [LifecycleSource] = []
    var writer: RecordingMediaWriter?
    func makeScreen(configuration: RecordingConfiguration, isRetry: Bool, writer: RecordingMediaWriter, callbacks: RecordingCaptureCallbacks) async throws -> any RecordingCaptureSource {
        self.writer = writer
        screenRequests.append((configuration.screenTarget, isRetry))
        if isRetry, !screenPermissionAvailable { throw RecordingPlatformError.unavailable("screen permission unavailable") }
        screenContentLookups += 1
        if !screenTargetAvailable { throw RecordingPlatformError.unavailable("selected target unavailable") }
        let screen = LifecycleSource(source: nil, callbacks: callbacks, startGate: nextScreenStartGate)
        nextScreenStartGate = nil
        screens.append(screen)
        screen.emitsFailureOnStart = screens.count == failScreenCallbackCreationNumber
        await preparationGate?.wait()
        return screen
    }
    func makeDevice(source: RecordingSource, framesPerSecond: Int, writer: RecordingMediaWriter, callbacks: RecordingCaptureCallbacks) -> any RecordingCaptureSource {
        let device = LifecycleSource(source: source, callbacks: callbacks, startGate: nextDeviceStartGate)
        nextDeviceStartGate = nil
        devices.append(device)
        device.throwsOnStart = devices.count == failDeviceCreationNumber
        return device
    }
    func availableDevices(kind: RecordingSourceKind) -> [RecordingSource] { available.filter { $0.kind == kind } }
}
