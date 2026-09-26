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

    private let lock = NSLock()
    private var _lastOptions: TranscriptionOptions?

    /// The `options` most recently passed to `transcribe(audio:options:)` — lets a test assert on
    /// what vocabulary/languageHints/mode the controller actually sent this engine.
    var lastOptions: TranscriptionOptions? {
        lock.lock(); defer { lock.unlock() }
        return _lastOptions
    }

    init(id: String, isOnDevice: Bool = false, steps: [Step]) {
        self.id = id
        self.isOnDevice = isOnDevice
        self.steps = steps
    }

    func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error> {
        lock.lock()
        _lastOptions = options
        lock.unlock()

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

// MARK: - FakeIntentClassifier

/// Scripted `IntentClassifying`.
final class FakeIntentClassifier: IntentClassifying, @unchecked Sendable {
    enum Behavior: Sendable {
        case decision(IntentDecision)
        case fail(ProsioError)
        /// Never completes on its own (until cancelled) — used for timeout tests.
        case hang
        case delayThenDecision(Duration, IntentDecision)
    }

    var behavior: Behavior = .decision(IntentDecision(intent: .dictate, confidence: 0.95, source: "jev"))

    private let lock = NSLock()
    private var _callCount = 0
    private var _lastTranscript: String?
    private var _lastHasSelection: Bool?

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var lastTranscript: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastTranscript
    }

    var lastHasSelection: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _lastHasSelection
    }

    func classify(transcript: String, hasSelection: Bool, app: AppContext?) async throws -> IntentDecision {
        recordCall(transcript, hasSelection)
        switch behavior {
        case .decision(let decision):
            return decision
        case .fail(let error):
            throw error
        case .hang:
            try? await Task.sleep(for: .seconds(3600))
            throw ProsioError.cancelled
        case .delayThenDecision(let duration, let decision):
            try? await Task.sleep(for: duration)
            return decision
        }
    }

    private func recordCall(_ transcript: String, _ hasSelection: Bool) {
        lock.lock()
        _callCount += 1
        _lastTranscript = transcript
        _lastHasSelection = hasSelection
        lock.unlock()
    }
}

// MARK: - FakeComposer

/// Scripted `Composing`.
final class FakeComposer: Composing, @unchecked Sendable {
    enum Behavior: Sendable {
        case deltas([String])
        case fail(ProsioError)
        /// Never completes on its own (until cancelled) — used for timeout tests.
        case hang
        /// Sleeps before yielding the deltas — lets a test observe an intermediate phase (e.g.
        /// `.composing`) that would otherwise resolve too fast to catch by polling.
        case delayThenDeltas(Duration, [String])
    }

    var behavior: Behavior = .deltas([""])

    private let lock = NSLock()
    private var _callCount = 0
    private var _lastRequest: ComposeRequest?

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var lastRequest: ComposeRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequest
    }

    func compose(_ request: ComposeRequest) -> AsyncThrowingStream<String, Error> {
        recordCall(request)
        let behavior = behavior
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .deltas(let deltas):
                    for delta in deltas {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                case .fail(let error):
                    continuation.finish(throwing: error)
                case .hang:
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish(throwing: ProsioError.cancelled)
                case .delayThenDeltas(let duration, let deltas):
                    try? await Task.sleep(for: duration)
                    for delta in deltas {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordCall(_ request: ComposeRequest) {
        lock.lock()
        _callCount += 1
        _lastRequest = request
        lock.unlock()
    }
}

// MARK: - FakeRouter

/// Scripted `RouteDeciding`.
final class FakeRouter: RouteDeciding, @unchecked Sendable {
    enum Behavior: Sendable {
        case decision(RouteDecision)
        case fail(ProsioError)
        /// Never completes on its own (until cancelled) — used for timeout/cancellation tests.
        case hang
    }

    var behavior: Behavior = .decision(RouteDecision(needsCloud: false, cleanProbability: 0.95, reason: "clean"))

    private let lock = NSLock()
    private var _callCount = 0
    private var _lastLocalTranscript: String?

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var lastLocalTranscript: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastLocalTranscript
    }

    func decide(localTranscript: String, options: TranscriptionOptions) async throws -> RouteDecision {
        recordCall(localTranscript)

        switch behavior {
        case .decision(let decision):
            return decision
        case .fail(let error):
            throw error
        case .hang:
            try? await Task.sleep(for: .seconds(3600))
            throw ProsioError.cancelled
        }
    }

    /// Synchronous (non-`async`) so the lock/unlock pair can be used directly — `NSLock` methods
    /// are unavailable from `async` function bodies.
    private func recordCall(_ localTranscript: String) {
        lock.lock()
        _callCount += 1
        _lastLocalTranscript = localTranscript
        lock.unlock()
    }
}

// MARK: - CallCounter

/// Thread-safe call counter, e.g. for a `prewarmCloud` closure passed to `DictationController`.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
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
    let settings = AppSettings(defaults: defaults)
    // `AppSettings.saveDebugRecordings` defaults to `true`, and `DictationController` falls back to
    // the REAL `~/Library/Application Support/Prosio/debug` whenever a test doesn't set
    // `debugRecordingsRootOverride` — which is nearly every test in this package. Disable it here so
    // that only tests which explicitly opt back in (and, doing so, must also point
    // `debugRecordingsRootOverride` at a temp directory — see `DictationControllerDebugRecordingTests`
    // and `IntentReclassificationDebugRecordingTests`) ever write a debug recording at all. See the
    // test-isolation bug this fixes: ordinary test runs were evicting the user's real recordings
    // (capped at the last 30) with test fixture data.
    settings.saveDebugRecordings = false
    return settings
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
