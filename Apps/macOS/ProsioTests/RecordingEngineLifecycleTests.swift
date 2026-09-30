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

    @MainActor private func makeFixture(cameraCount: Int = 0, microphone: Bool = false) throws -> LifecycleFixture {
        let cameras = (0..<cameraCount).map { RecordingSource(id: "camera-\($0)", kind: .camera, name: "Camera \($0)", deviceID: "device-\($0)") }
        let mic = microphone ? RecordingSource(id: "microphone-device", kind: .microphone, name: "Microphone", deviceID: "microphone-device") : nil
        let backend = LifecycleBackend()
        backend.available = cameras + (mic.map { [$0] } ?? [])
        let engine = RecordingEngine(backend: backend, monitoringInterval: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioEngineLifecycle-\(UUID().uuidString)")
        return LifecycleFixture(engine: engine, backend: backend, directory: directory,
            configuration: RecordingConfiguration(screenTarget: .display(1), cameras: cameras, microphone: mic))
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
        running = true
    }
    func stop() async { stopCount += 1; running = false }
}

@MainActor private final class LifecycleBackend: RecordingCaptureBackend {
    var preparationGate: LifecycleGate?
    var nextDeviceStartGate: LifecycleGate?
    var failDeviceCreationNumber: Int?
    var available: [RecordingSource] = []
    var screens: [LifecycleSource] = []
    var devices: [LifecycleSource] = []
    var writer: RecordingMediaWriter?
    func makeScreen(configuration: RecordingConfiguration, writer: RecordingMediaWriter, callbacks: RecordingCaptureCallbacks) async throws -> any RecordingCaptureSource {
        self.writer = writer
        let screen = LifecycleSource(source: nil, callbacks: callbacks, startGate: nil)
        screens.append(screen)
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
