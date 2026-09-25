import Foundation
@testable import ProsioCore

// MARK: - FakeAudio

/// Scripted `AudioCapturing`: the test drives it by calling `push(_:)` after `start()`.
final class FakeAudio: AudioCapturing, @unchecked Sendable {
    enum StartBehavior {
        case succeed
        case throwError(ProsioError)
    }

    var startBehavior: StartBehavior = .succeed
    /// Called synchronously at the top of `start()` — lets tests assert call order against other
    /// fakes (e.g. that the mic opens before focus context is read).
    var onStart: (() -> Void)?

    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var _startCallCount = 0
    private var _stopCallCount = 0

    var startCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startCallCount
    }

    var stopCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopCallCount
    }

    func start() throws -> AsyncStream<AudioChunk> {
        lock.lock()
        _startCallCount += 1
        let behavior = startBehavior
        lock.unlock()

        onStart?()

        if case .throwError(let error) = behavior {
            throw error
        }

        return AsyncStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        _stopCallCount += 1
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }

    func push(_ chunk: AudioChunk) {
        lock.lock()
        let cont = continuation
        lock.unlock()
        cont?.yield(chunk)
    }
}

// MARK: - FakeEngine

actor FakeEngineRecorder {
    private(set) var callCount = 0
    private(set) var receivedChunks: [AudioChunk] = []

    func recordCall() { callCount += 1 }
    func record(_ chunk: AudioChunk) { receivedChunks.append(chunk) }
}

/// Scripted `TranscriptionEngine`. `.final` waits for the input audio stream to actually finish
/// before yielding, mirroring real engines ("consumes audio until it finishes, then flushes and
/// yields exactly one `.final`") so tests aren't racing engine output against audio delivery.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    enum Step: Sendable {
        case partial(String)
        case final(String)
        case fail(ProsioError)
        /// Never completes on its own (until cancelled) — used to simulate a stuck engine for
        /// timeout / cancellation tests.
        case hang
        /// Sleeps before moving to the next step — lets a test deterministically stagger which of
        /// two concurrently-running fake engines finishes first.
        case delay(Duration)
    }

    let id: String
    let isOnDevice: Bool
    let steps: [Step]
    let recorder = FakeEngineRecorder()

    init(id: String, isOnDevice: Bool = false, steps: [Step]) {
        self.id = id
        self.isOnDevice = isOnDevice
        self.steps = steps
    }

    func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let steps = steps
        let recorder = recorder
        return AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.recordCall()
                let consumeTask = Task<Void, Never> {
                    for await chunk in audio {
                        await recorder.record(chunk)
                    }
                }

                for step in steps {
                    if Task.isCancelled {
                        consumeTask.cancel()
                        continuation.finish(throwing: ProsioError.cancelled)
                        return
                    }
                    switch step {
                    case .partial(let text):
                        continuation.yield(.partial(text))
                    case .final(let text):
                        // Mirror real engines: only flush a final after audio input ends.
                        _ = await consumeTask.value
                        continuation.yield(.final(text))
                        continuation.finish()
                        return
                    case .fail(let error):
                        consumeTask.cancel()
                        continuation.finish(throwing: error)
                        return
                    case .hang:
                        try? await Task.sleep(for: .seconds(3600))
                    case .delay(let duration):
                        try? await Task.sleep(for: duration)
                    }
                }
                consumeTask.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - FakeInserter

@MainActor
final class FakeInserter: TextInserting {
    var outcomeToReturn: InsertionOutcome = .pasted
    private(set) var insertedTexts: [String] = []
    private(set) var insertedContexts: [FocusContext?] = []

    /// When true, `insert` suspends after recording the call until `release()` is invoked — lets
    /// a test interleave `cancel()` with an in-flight insertion.
    var holdUntilReleased = false
    private var gate: CheckedContinuation<Void, Never>?

    func insert(_ text: String, into context: FocusContext?) async -> InsertionOutcome {
        insertedTexts.append(text)
        insertedContexts.append(context)
        if holdUntilReleased {
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        return outcomeToReturn
    }

    /// Resumes an `insert` call suspended because `holdUntilReleased` was set.
    func release() {
        gate?.resume()
        gate = nil
    }
}

// MARK: - FakeContextProvider

@MainActor
final class FakeContextProvider: FocusContextProviding {
    var contextToReturn = FocusContext(bundleID: "com.prosio.testhost", appName: "TestHost")
    /// Called synchronously from `currentContext()` — lets tests assert call order against other
    /// fakes (e.g. that the mic opens before focus context is read).
    var onCurrentContext: (() -> Void)?

    func currentContext() -> FocusContext {
        onCurrentContext?()
        return contextToReturn
    }
}

// MARK: - Helpers

func makeAudioChunk(level: Float = 0.5, timestamp: TimeInterval) -> AudioChunk {
    AudioChunk(pcm16: Data([0, 0]), level: level, timestamp: timestamp)
}

@MainActor
func makeTestSettings() -> AppSettings {
    let suiteName = "prosio.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return AppSettings(defaults: defaults)
}

/// Polls `condition` on the main actor until it's true or `timeout` elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func makeTempFileURL(_ name: String = "store.json") -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prosio-tests-\(UUID().uuidString)")
    return dir.appendingPathComponent(name)
}
