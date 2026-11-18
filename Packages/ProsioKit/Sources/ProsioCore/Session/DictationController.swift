import Foundation
import Observation

/// Orchestrates one dictation at a time: on-device preview -> one cloud batch request at `stop()`
/// -> insertion -> history.
///
/// P1.2: there is no more engine-mode setting (`AppSettings.enginePreference` removed) — every
/// session runs the same flow. `localEngine` streams a live preview the whole time; at `stop()`,
/// the finished recording (prepared for upload via `AudioPreparing`) plus the local transcript are
/// sent to `cloudTranscriber` in a SINGLE request. The server decides whether the local transcript
/// is already clean enough to skip Gemini (`response.source == "local"`) and returns the session's
/// intent inline (replacing the old separate `/api/route` + `/api/intent` calls). Offline/
/// unreachable falls back to the local transcript, classified client-side via `IntentRules`.
/// See docs/P1.2-AUDIO-ROUTING.md. PUBLIC API FROZEN — implementation owned by core agent.
@MainActor
@Observable
public final class DictationController {
    public private(set) var phase: DictationPhase = .idle
    /// Shown when cloud transcription is skipped because the recording is too long for one request.
    public private(set) var notice: String?
    /// Live preview (cumulative) while listening/finalizing; final text afterwards.
    public private(set) var previewText: String = ""
    /// Smoothed level 0...1.
    public private(set) var level: Float = 0
    /// Most recent levels (oldest first, fixed length `levelHistoryLength`) for waveform drawing.
    public private(set) var levelHistory: [Float] = Array(repeating: 0, count: 48)
    public private(set) var context: FocusContext?
    public private(set) var activeEngineID: String?
    public private(set) var trigger: DictationTrigger?
    /// P1: what this session is for. Resolved at `start()` — explicit if given, else `.edit` when
    /// text is selected (and not secure input), else `.dictate`.
    public private(set) var intent: DictationIntent?
    /// P1: the focused app's writing scene, resolved at `start()` via `SceneResolver`.
    public private(set) var scene: WritingScene = .general
    /// P1 Ask mode: the answer card's state (streaming or done). `nil` outside `.answering`
    /// (and briefly after `insertAnswer()`/`dismissAnswer()`).
    public private(set) var answer: AnswerState?
    /// Short label for the HUD while `phase == .composing`, e.g. "Translating…", "Editing…", "Polishing…".
    public private(set) var composeLabel: String?
    /// P1: BCP-47 target language for *this session's* translate (persistent toggle, or a
    /// one-off classifier/rules decision), for a HUD chip independent of `AppSettings.translateEnabled`.
    /// `nil` outside a translate session.
    public private(set) var sessionTranslateTarget: String?

    public static let levelHistoryLength = 48

    /// Called on the main actor after every completed (inserted or copied) dictation, e.g. to report usage.
    public var onSessionCompleted: ((HistoryItem) -> Void)?

    /// Immediate feedback for accepted microphone transitions, delivered on the main actor.
    public var onRecordingStarted: (() -> Void)?
    public var onRecordingStopped: (() -> Void)?

    /// How long `stop()` waits for `localEngine`'s own `.final` before proceeding with whatever's
    /// on screen (its last partial) as the local transcript sent to the server. Local is on-device
    /// and expected to finish quickly once audio ends. Overridable via `@testable import`.
    var localFinalTimeout: Duration = .seconds(2)
    /// How long `stop()` waits for the single `/api/transcribe` request (including one 415->WAV
    /// retry) before giving up and falling back to the local transcript, same as an offline/network
    /// failure. Overridable via `@testable import`.
    var cloudRequestTimeout: Duration = .seconds(15)
    /// How long rewrite/translate/edit compose calls wait before giving up (rewrite falls back to
    /// the untransformed transcript; translate/edit fail). 12s per spec. Overridable via `@testable import`.
    var composeTimeout: Duration = .seconds(12)
    /// Overrides where debug recordings are written (see `AppSettings.saveDebugRecordings`).
    /// `nil` (production default) means `~/Library/Application Support/Prosio/debug`.
    /// Internal test seam — not part of the public API.
    var debugRecordingsRootOverride: URL?
    /// The debug-recording root this controller would actually write to right now — mirrors exactly
    /// what `writeDebugRecording()` resolves. Test-only seam (see `TestIsolationGuardTests`) so a
    /// `@testable` test can assert a test-constructed controller isn't one accidental
    /// `saveDebugRecordings = true` away from writing into the user's real
    /// `~/Library/Application Support/Prosio/debug` — the isolation bug this seam guards against.
    var resolvedDebugRecordingsRootForTesting: URL {
        debugRecordingsRootOverride ?? Self.defaultDebugRecordingsRoot()
    }

    /// Stable identifier recorded as `activeEngineID`/`HistoryItem.engineID` when the server actually
    /// ran Gemini (`response.source == "cloud"`) — there's no longer a `TranscriptionEngine` object
    /// for the cloud pass to ask for its own `id` (P1.2: one-shot `CloudBatchTranscribing`, not a
    /// streaming engine).
    static let cloudEngineID = "cloud.gemini-3.5-transcribe"

    private let audio: any AudioCapturing
    /// On-device engine: drives the live preview and produces the local transcript sent to the
    /// server with every `/api/transcribe` request. Never itself "final" for insertion purposes
    /// anymore — see the type doc comment.
    private let localEngine: any TranscriptionEngine
    private let cloudTranscriber: any CloudBatchTranscribing
    /// P1.2: trims/encodes the finished recording for upload. Defaults to `WAVAudioPreparer`
    /// (untrimmed WAV) until speech's `SilenceTrimmer`/`OggOpusEncoder` land — see docs/P1.2-AUDIO-ROUTING.md.
    private let audioPreparer: any AudioPreparing
    private let inserter: any TextInserting
    private let contextProvider: any FocusContextProviding
    private let history: HistoryStore
    private let dictionary: DictionaryStore
    private let settings: AppSettings
    /// Fired (best-effort, off the main actor) at the start of every session to warm the cloud
    /// HTTPS connection ahead of when it might actually be needed.
    private let prewarmCloud: (@Sendable () async -> Void)?
    /// P1: transforms text with an LLM (rewrite/translate/edit/ask). `nil` (default) turns every
    /// P1 feature off — sessions behave exactly as before (today's fast path).
    private let composer: (any Composing)?
    /// Kept for compatibility (e.g. a follow-up ask never needs it, since it's always `.ask`
    /// unconditionally). P1.2: UNUSED in the main dictation path — the server now returns the
    /// session's intent inline with `/api/transcribe`, so there's no separate `/api/intent` call to
    /// make there anymore. Retained only so existing callers/tests that configure one don't break.
    private let intentClassifier: (any IntentClassifying)?

    private var meterTask: Task<Void, Never>?
    /// Consumes `localEngine` for the live preview; also what `stop()` awaits (bounded) to get the
    /// best-available local transcript before building the `/api/transcribe` request.
    private var previewTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    private var totalAudioDuration: TimeInterval = 0
    /// Raw little-endian PCM16 mono samples, in order, captured this session — always accumulated
    /// (P1.2: needed for every upload, not just debug recordings).
    private var capturedPCM = Data()
    /// `localEngine`'s own final text, if it produced one before `stop()`'s bounded wait elapsed.
    private var localFinalText: String?
    /// True once `previewTask` has finished (success or failure) — lets `stop()` wait a bounded
    /// amount of time for `localFinalText` to actually be populated before giving up and using
    /// whatever's currently in `previewText` (a partial) instead.
    private var localOutcomeReady = false
    private var localReadyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Bumped by every `start()`/`cancel()`. Async work (insertion, stop-resolution) captures the
    /// generation it started with and checks it after each `await`; a mismatch means the session
    /// was cancelled (or superseded) in the meantime, so the stale result must not resurrect
    /// `phase`/history/`onSessionCompleted`.
    private var sessionGeneration = 0

    // MARK: - Debug recording (AppSettings.saveDebugRecordings)

    private var sessionID = UUID()
    private var sessionCreatedAt = Date()
    /// Cloud's own returned text, captured purely for the debug recording's `suspectedDrop` check
    /// — `nil` when the server returned `source == "local"` (no Gemini pass ran) or on failure.
    private var cloudFinalTextForDebug: String?

    private var tStart: Date?
    private var tMicOpen: Date?
    private var tFirstAudioChunk: Date?
    private var tFirstLocalPartial: Date?
    private var tStopCalled: Date?
    /// P1.2: `AudioPreparing.prepare` (trim + Opus encode) finished.
    private var tAudioPrepared: Date?
    /// P1.2: the single `/api/transcribe` response received (success or failure/timeout treated as
    /// the offline fallback) — replaces the old (mislabelled, pre-P1.2) "final received" timestamp,
    /// which was actually stamped when the *local* engine's own `.final` arrived, not when the
    /// server responded.
    private var tResponseReceived: Date?
    private var tInsertionDone: Date?
    private var composeModeForDebug: String?
    private var composeLatencyMsForDebug: Double?
    private var composeOutputForDebug: String?
    private var intentDecisionClassifiedForDebug: String?
    private var intentDecisionSourceForDebug: String?
    private var intentDecisionConfidenceForDebug: Double?
    /// P1.2 debug fields per docs/P1.2-AUDIO-ROUTING.md §3: `response.source`/`route.*` and the
    /// upload's shape (`AudioPreparing`'s output).
    private var routeSourceForDebug: String?
    private var routeCleanProbabilityForDebug: Double?
    private var routeReasonForDebug: String?
    private var originalSecondsForDebug: Double?
    private var trimmedSecondsForDebug: Double?
    private var uploadBytesForDebug: Int?
    private var audioFormatForDebug: String?

    // MARK: - P1: intent (dictate/edit/ask/translate)

    /// True when this session is a follow-up while the answer card is showing (started with
    /// `phase == .answering`) — always `.ask`, no classification needed.
    private var isFollowUpAsk = false
    /// Set when `start(trigger:intent:)` was given an explicit intent (tests/explicit callers) —
    /// skips classification entirely and is used as the final word.
    private var explicitIntent: DictationIntent?

    private struct IntentResolution {
        var intent: ClassifiedIntent
        var source: String
        var confidence: Double?
        /// Only for a rule-matched `.translate` — the parsed target + cue-stripped body, sent to
        /// `compose(.translate)`. A server/classifier-matched `.translate` sends the whole
        /// utterance to `compose(.translateCommand)` instead (nil here).
        var ruleTranslateTarget: String?
        var ruleTranslateBody: String?
    }

    /// The user's personal dictionary plus fixed command-cue words (`IntentRules.vocabularyHints`)
    /// biasing every transcription pass (cloud SMART + on-device SpeechAnalyzer) so intent cues
    /// like "提问"/"翻译" survive verbatim instead of being normalized away or clipped — see the
    /// live-acceptance fix where cloud SMART silently turned a spoken "提问" into "请问". Deduped,
    /// cues first so they win ties with `NSOrderedSet`-style biasing in the engines.
    private var transcriptionVocabulary: [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for term in IntentRules.vocabularyHints + dictionary.vocabulary where seen.insert(term).inserted {
            merged.append(term)
        }
        return merged
    }

    public init(
        audio: any AudioCapturing,
        localEngine: any TranscriptionEngine,
        cloudTranscriber: any CloudBatchTranscribing,
        inserter: any TextInserting,
        contextProvider: any FocusContextProviding,
        history: HistoryStore,
        dictionary: DictionaryStore,
        settings: AppSettings,
        audioPreparer: any AudioPreparing = WAVAudioPreparer(),
        prewarmCloud: (@Sendable () async -> Void)? = nil,
        composer: (any Composing)? = nil,
        intentClassifier: (any IntentClassifying)? = nil
    ) {
        self.audio = audio
        self.localEngine = localEngine
        self.cloudTranscriber = cloudTranscriber
        self.audioPreparer = audioPreparer
        self.inserter = inserter
        self.contextProvider = contextProvider
        self.history = history
        self.dictionary = dictionary
        self.settings = settings
        self.prewarmCloud = prewarmCloud
        self.composer = composer
        self.intentClassifier = intentClassifier
    }

    /// True while listening/finalizing/inserting.
    public var isBusy: Bool {
        switch phase {
        case .listening, .finalizing, .inserting: true
        default: false
        }
    }

    /// Opens the mic and starts streaming, then captures focus context. No-op if busy.
    ///
    /// - Parameter intent: kept for tests/explicit callers. The real (single, fn) hotkey always
    ///   passes `nil`: a fn press while the answer card is showing (`phase == .answering`) is a
    ///   follow-up `.ask` (no classification, existing turns kept); otherwise the session's real
    ///   intent (dictate/edit/ask/translate) is decided by the server's `/api/transcribe` response
    ///   (with `IntentRules` as a client-side fallback when unavailable/offline) — `intent` here is
    ///   only an optimistic placeholder for the HUD until that response arrives. An explicit
    ///   `intent` skips classification entirely and is used as-is (existing test/caller behavior).
    public func start(trigger: DictationTrigger, intent requestedIntent: DictationIntent? = nil) {
        guard !isBusy else { return }

        // A fn press while the answer card is showing is always a follow-up — never dismissed by
        // starting a new session; the previous turns carry forward and no classification runs.
        let isFollowUp: Bool
        if case .answering = phase {
            isFollowUp = requestedIntent == nil || requestedIntent == .ask
        } else {
            isFollowUp = false
        }
        if !isFollowUp {
            answer = nil
            notice = nil
        }
        isFollowUpAsk = isFollowUp

        sessionGeneration += 1

        previewText = ""
        level = 0
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        self.trigger = trigger
        totalAudioDuration = 0
        capturedPCM = Data()
        localFinalText = nil
        localOutcomeReady = false
        localReadyWaiters = []

        sessionID = UUID()
        sessionCreatedAt = Date()
        cloudFinalTextForDebug = nil
        tStart = sessionCreatedAt
        tMicOpen = nil
        tFirstAudioChunk = nil
        tFirstLocalPartial = nil
        tStopCalled = nil
        tAudioPrepared = nil
        tResponseReceived = nil
        tInsertionDone = nil
        composeLabel = nil
        composeModeForDebug = nil
        composeLatencyMsForDebug = nil
        composeOutputForDebug = nil
        intentDecisionClassifiedForDebug = nil
        intentDecisionSourceForDebug = nil
        intentDecisionConfidenceForDebug = nil
        routeSourceForDebug = nil
        routeCleanProbabilityForDebug = nil
        routeReasonForDebug = nil
        originalSecondsForDebug = nil
        trimmedSecondsForDebug = nil
        uploadBytesForDebug = nil
        audioFormatForDebug = nil
        explicitIntent = isFollowUpAsk ? nil : requestedIntent
        sessionTranslateTarget = nil

        activeEngineID = localEngine.id

        // Open the mic (and flip to `.listening`) before doing anything else, in particular
        // before reading focus context: `currentContext()` does synchronous Accessibility IPC
        // that can take up to ~100ms, and we must never delay capture start and risk losing the
        // first syllable.
        let audioStream: AsyncStream<AudioChunk>
        do {
            audioStream = try audio.start()
        } catch {
            phase = .failed((error as? ProsioError) ?? .audioUnavailable("\(error)"))
            return
        }
        tMicOpen = Date()
        phase = .listening
        onRecordingStarted?()

        let capturedContext = contextProvider.currentContext()
        context = capturedContext
        let hasSelection = capturedContext.selectedText?.isEmpty == false && !capturedContext.isSecureInput
        if isFollowUpAsk {
            intent = .ask
        } else {
            // Optimistic placeholder for the HUD until the server's response resolves (or, with an
            // explicit `requestedIntent`, the final word — classification is skipped entirely).
            intent = requestedIntent ?? (hasSelection ? .edit : .dictate)
        }
        scene = SceneResolver.scene(for: capturedContext, overrides: settings.sceneOverrides)

        if let prewarmCloud {
            Task.detached(priority: .utility) {
                await prewarmCloud()
            }
        }

        let (localAudio, localContinuation) = AsyncStream<AudioChunk>.makeStream()
        let options = TranscriptionOptions(mode: .smart, vocabulary: transcriptionVocabulary, languageHints: settings.languageHints)
        let localEvents = localEngine.transcribe(audio: localAudio, options: options)

        let meterTask = Task { @MainActor [weak self] in
            guard let self else {
                localContinuation.finish()
                return
            }
            for await chunk in audioStream {
                if self.tFirstAudioChunk == nil {
                    self.tFirstAudioChunk = Date()
                }
                self.updateLevel(with: chunk.level)
                self.totalAudioDuration = max(self.totalAudioDuration, TimeInterval(chunk.timestamp))
                self.capturedPCM.append(chunk.pcm16)
                localContinuation.yield(chunk)
            }
            localContinuation.finish()
        }
        self.meterTask = meterTask

        let previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in localEvents {
                    switch event {
                    case .partial(let text):
                        if self.tFirstLocalPartial == nil {
                            self.tFirstLocalPartial = Date()
                        }
                        self.previewText = text
                    case .final(let text):
                        self.localFinalText = text
                        self.previewText = text
                    }
                }
            } catch {
                // A local failure must never fail the session — the cloud request still runs off
                // whatever's in `previewText`, and `localFinalText` simply stays nil.
            }
            self.markLocalReady()
        }
        self.previewTask = previewTask
    }

    /// Closes the mic, waits for the local transcript, sends the single `/api/transcribe` request,
    /// inserts the result, records history.
    public func stop() {
        guard case .listening = phase else { return }
        let generation = sessionGeneration
        tStopCalled = Date()
        audio.stop()
        phase = .finalizing
        onRecordingStopped?()

        stopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resolveStop(generation: generation)
        }
    }

    /// Aborts without inserting.
    public func cancel() {
        sessionGeneration += 1
        audio.stop()
        meterTask?.cancel()
        previewTask?.cancel()
        stopTask?.cancel()
        meterTask = nil
        previewTask = nil
        stopTask = nil
        sessionTranslateTarget = nil
        localFinalText = nil
        localOutcomeReady = false
        localReadyWaiters = []
        // Unblock anything still suspended in `waitForLocalReady()`.
        markLocalReady()
        previewText = ""
        phase = .idle
    }

    // MARK: - Level metering

    private func updateLevel(with newLevel: Float) {
        let clamped = max(0, min(1, newLevel))
        // Attack (rising level) is fast so the meter feels responsive; release (falling level) is
        // slow so it doesn't flicker between words.
        let attack: Float = 0.6
        let release: Float = 0.15
        let coefficient = clamped > level ? attack : release
        level += (clamped - level) * coefficient
        if !levelHistory.isEmpty {
            levelHistory.removeFirst()
        }
        levelHistory.append(level)
    }

    // MARK: - Local-readiness signalling

    private func markLocalReady() {
        guard !localOutcomeReady else { return }
        localOutcomeReady = true
        let waiters = localReadyWaiters
        localReadyWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForLocalReady() async {
        if localOutcomeReady { return }
        await withCheckedContinuation { continuation in
            localReadyWaiters.append(continuation)
        }
    }

    /// Waits (up to `localFinalTimeout`) for `previewTask` to finish, so `localFinalText` is
    /// populated (if it's going to be) before we read it for the `/api/transcribe` request.
    private func waitForLocalFinalBounded() async {
        guard !localOutcomeReady else { return }
        let localTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.localFinalTimeout)
            guard !Task.isCancelled else { return }
            self.markLocalReady()
        }
        await waitForLocalReady()
        localTimeoutTask.cancel()
    }

    // MARK: - Stop resolution

    private func resolveStop(generation: Int) async {
        await waitForLocalFinalBounded()
        guard generation == sessionGeneration else { return } // cancel() could race in above

        let hasSelection = context?.selectedText?.isEmpty == false && !(context?.isSecureInput ?? false)
        let localCandidate = (localFinalText ?? previewText).trimmingCharacters(in: .whitespacesAndNewlines)
        let localTranscript: String? = localCandidate.isEmpty ? nil : localCandidate

        guard localTranscript != nil || !capturedPCM.isEmpty else {
            handleEmptyFinal()
            return
        }

        let prepared = await audioPreparer.prepare(pcm16: capturedPCM, sampleRate: AudioFormat.pcm16Mono16k.sampleRate)
        guard generation == sessionGeneration else { return } // cancel() could race in above (prepare is async)
        tAudioPrepared = Date()
        originalSecondsForDebug = prepared.originalSeconds
        trimmedSecondsForDebug = prepared.trimmedSeconds
        uploadBytesForDebug = prepared.data.count
        audioFormatForDebug = prepared.format.rawValue

        let request = CloudTranscribeRequest(
            audioData: prepared.data,
            audioFormat: prepared.format,
            options: TranscriptionOptions(mode: .smart, vocabulary: transcriptionVocabulary, languageHints: settings.languageHints),
            localTranscript: localTranscript,
            hasSelection: hasSelection,
            app: makeAppContext(),
            sessionID: sessionID,
            durationSeconds: prepared.trimmedSeconds
        )

        do {
            let response = try await requestTranscription(request, rawPCM: capturedPCM, sampleRate: AudioFormat.pcm16Mono16k.sampleRate)
            tResponseReceived = Date()
            guard generation == sessionGeneration else { return }
            await handleCloudResponse(response, localFallback: localTranscript, hasSelection: hasSelection, generation: generation)
        } catch {
            tResponseReceived = Date()
            guard generation == sessionGeneration else { return }
            if let prosio = error as? ProsioError, case .transcriptionFailed(let message) = prosio, message == "too-long" {
                notice = "这次较长，已使用本机听写结果。"
            }
            // Offline/unreachable/timed-out/no key -> fall back to the local transcript.
            guard let localTranscript else {
                handleEmptyFinal()
                return
            }
            activeEngineID = localEngine.id
            routeSourceForDebug = "offline-fallback"
            await dispatchIntent(text: localTranscript, serverIntent: nil, hasSelection: hasSelection, generation: generation)
        }
    }

    /// Races `cloudTranscriber.transcribe(_:)` against `cloudRequestTimeout`; on HTTP 415
    /// ("unsupported audio format" — `ProsioError.network("unsupported-audio-format")`, see
    /// `BackendClient`) retries once as WAV, per docs/P1.2-AUDIO-ROUTING.md §1.
    private func requestTranscription(_ request: CloudTranscribeRequest, rawPCM: Data, sampleRate: Double) async throws -> CloudTranscript {
        do {
            return try await withTimeout(cloudRequestTimeout) { try await self.cloudTranscriber.transcribe(request) }
        } catch let error as ProsioError where Self.isUnsupportedAudioFormat(error) && request.audioFormat != .wav {
            let wavData = WAVFile.make(pcm16: rawPCM, sampleRate: sampleRate)
            let wavRequest = CloudTranscribeRequest(
                audioData: wavData,
                audioFormat: .wav,
                options: request.options,
                localTranscript: request.localTranscript,
                hasSelection: request.hasSelection,
                app: request.app,
                sessionID: request.sessionID
            )
            audioFormatForDebug = wavRequest.audioFormat.rawValue
            uploadBytesForDebug = wavRequest.audioData.count
            return try await withTimeout(cloudRequestTimeout) { try await self.cloudTranscriber.transcribe(wavRequest) }
        }
    }

    private static func isUnsupportedAudioFormat(_ error: ProsioError) -> Bool {
        if case .network(let message) = error { return message == "unsupported-audio-format" }
        return false
    }

    /// Races `operation` against `duration`, cancelling whichever loses. Throws
    /// `ProsioError.transcriptionFailed("timeout")` if `operation` doesn't win in time.
    private func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw ProsioError.transcriptionFailed("timeout")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Handles a successful `/api/transcribe` v2 response: `source == "local"` is a direct-insert
    /// fast path (the server already decided the local transcript needs no further processing);
    /// otherwise routes through the normal dictate/edit/ask/translate dispatch using the server's
    /// inline intent decision (falling back to `IntentRules` when it's `nil`/unavailable).
    private func handleCloudResponse(_ response: CloudTranscript, localFallback: String?, hasSelection: Bool, generation: Int) async {
        routeSourceForDebug = response.source
        routeCleanProbabilityForDebug = response.route?.cleanProbability
        routeReasonForDebug = response.route?.reason
        if response.source == "cloud" {
            cloudFinalTextForDebug = response.text
        }

        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let localFallback {
                activeEngineID = localEngine.id
                await dispatchIntent(text: localFallback, serverIntent: response.intent, hasSelection: hasSelection, generation: generation)
            } else {
                handleEmptyFinal()
            }
            return
        }

        // The "server says it's clean, just insert it" fast path only applies when the server's
        // intent decision is actually what determines this session's routing — a follow-up ask
        // (always `.ask`, existing turns kept) or an explicit intent (test/caller-supplied) must
        // still go through `dispatchIntent`, which honors those regardless of `response.source`.
        if response.source == "local", !isFollowUpAsk, explicitIntent == nil {
            activeEngineID = localEngine.id
            let resolution = resolveMainPathIntent(serverIntent: response.intent, text: text, hasSelection: hasSelection)
            applyIntentDecision(resolution)
            await insertAndRecord(final: text, generation: generation)
            return
        }

        activeEngineID = Self.cloudEngineID
        await dispatchIntent(text: text, serverIntent: response.intent, hasSelection: hasSelection, generation: generation)
    }

    private func handleEmptyFinal() {
        let duration = totalAudioDuration
        finishSession()
        if duration < 0.4 {
            // Accidental tap: go back to idle silently rather than surfacing an error.
            phase = .idle
            previewText = ""
        } else {
            phase = .failed(.emptyTranscript)
        }
    }

    private func insertAndRecord(final: String, generation: Int, transcriptForHistory: String? = nil) async {
        phase = .inserting
        let outcome = await inserter.insert(final, into: context)
        tInsertionDone = Date()

        // `cancel()` (or a brand new `start()`) may have happened while we were awaiting
        // insertion. That result is stale — the session it belongs to is no longer current — so
        // we must not resurrect `phase`, append to history, or fire `onSessionCompleted`.
        guard generation == sessionGeneration else { return }

        phase = .finished(outcome)
        previewText = final

        let engineIDUsed = activeEngineID ?? "unknown"
        let item = HistoryItem(
            text: final,
            appBundleID: context?.bundleID,
            appName: context?.appName,
            engineID: engineIDUsed,
            durationSeconds: totalAudioDuration,
            insertion: outcome,
            intent: intent,
            transcript: transcriptForHistory
        )

        if settings.historyEnabled {
            try? history.append(item)
        }
        if outcome == .pasted || outcome == .accessibility || outcome == .copiedToClipboard {
            onSessionCompleted?(item)
        }

        finishSession(insertedText: final, outcome: outcome)
    }

    // MARK: - P1: intent dispatch (rewrite / translate / edit / ask)

    /// Every "we have the final transcript" path (cloud, local-fallback, or offline) routes through
    /// here so compose (rewrite/translate/edit/ask) applies uniformly regardless of source.
    private func dispatchIntent(text: String, serverIntent: IntentDecision?, hasSelection: Bool, generation: Int) async {
        if isFollowUpAsk {
            await runAsk(question: text, generation: generation)
            return
        }
        if let explicitIntent {
            // Caller (test or explicit code path) gave the answer directly — classification never ran.
            switch explicitIntent {
            case .edit: await runEdit(instruction: text, generation: generation)
            case .ask: await runAsk(question: text, generation: generation)
            case .write: await runWrite(instruction: text, hasSelection: hasSelection, generation: generation)
            case .dictate: await runDictateDefault(transcript: text, generation: generation)
            }
            return
        }

        let resolution = resolveMainPathIntent(serverIntent: serverIntent, text: text, hasSelection: hasSelection)
        applyIntentDecision(resolution)

        switch resolution.intent {
        case .dictate:
            await runDictateDefault(transcript: text, generation: generation)
        case .edit:
            await runEdit(instruction: text, generation: generation)
        case .ask:
            await runAsk(question: text, generation: generation)
        case .write:
            await runWrite(instruction: text, hasSelection: hasSelection, generation: generation)
        case .translate:
            if resolution.source == "rules", let target = resolution.ruleTranslateTarget, let body = resolution.ruleTranslateBody {
                await runTranslate(mode: .translate, text: body, target: target, generation: generation, transcriptForHistory: text)
            } else {
                await runTranslate(mode: .translateCommand, text: text, target: settings.translateTarget, generation: generation, transcriptForHistory: text)
            }
        }
    }

    /// `.dictate`-classified (or explicit `.dictate`) sessions: the persistent Translate toggle,
    /// then scene adaptation, then the fast path — unchanged since before P1.2.
    private func runDictateDefault(transcript: String, generation: Int) async {
        if settings.translateEnabled {
            sessionTranslateTarget = settings.translateTarget
            await runTranslate(mode: .translate, text: transcript, target: settings.translateTarget, generation: generation, transcriptForHistory: transcript)
        } else if settings.adaptToApp, scene != .general {
            await runRewrite(transcript: transcript, generation: generation)
        } else {
            // Today's fast path: no compose involved, insert exactly what was transcribed.
            await insertAndRecord(final: transcript, generation: generation)
        }
    }

    /// P1.2: the server's inline intent decision (`/api/transcribe` response) -> `IntentRules`
    /// fallback -> default (dictate, or edit with a selection). Never fails to produce a result.
    /// Unlike the pre-P1.2 flow, this never calls `intentClassifier` — the main dictation path no
    /// longer makes a separate `/api/intent` request (see the type doc comment on `intentClassifier`).
    private func resolveMainPathIntent(serverIntent: IntentDecision?, text: String, hasSelection: Bool) -> IntentResolution {
        if let serverIntent, let classified = serverIntent.intent {
            return IntentResolution(intent: classified, source: serverIntent.source, confidence: serverIntent.confidence)
        }
        // Server intent unavailable (no response at all, e.g. offline; or `intent: null` because
        // Jev was down server-side) -> degrade to client-side rules.
        let rules = IntentRules.classify(text, hasSelection: hasSelection, defaultTranslateTarget: settings.translateTarget)
        return IntentResolution(
            intent: rules.intent,
            source: "rules",
            confidence: nil,
            ruleTranslateTarget: rules.translateTarget,
            ruleTranslateBody: rules.translateBody
        )
    }

    private func applyIntentDecision(_ resolution: IntentResolution) {
        // `ClassifiedIntent.translate` has no `DictationIntent` equivalent — publish `.dictate`
        // (a translate-classified session is still, structurally, a dictation).
        intent = {
            switch resolution.intent {
            case .dictate, .translate: return .dictate
            case .edit: return .edit
            case .ask: return .ask
            case .write: return .write
            }
        }()
        sessionTranslateTarget = (resolution.intent == .translate) ? (resolution.ruleTranslateTarget ?? settings.translateTarget) : nil

        intentDecisionClassifiedForDebug = resolution.intent.rawValue
        intentDecisionSourceForDebug = resolution.source
        intentDecisionConfidenceForDebug = resolution.confidence

        ProsioLog.intent.info("intent decision=\(resolution.intent.rawValue, privacy: .public) source=\(resolution.source, privacy: .public) confidence=\(resolution.confidence.map { String(format: "%.2f", $0) } ?? "n/a", privacy: .public)")
    }

    private func runRewrite(transcript: String, generation: Int) async {
        guard let composer else {
            // No composer configured -> P1 off, behave exactly as before.
            await insertAndRecord(final: transcript, generation: generation)
            return
        }

        phase = .composing
        previewText = transcript
        composeLabel = "Polishing…"
        composeModeForDebug = "rewrite"

        let request = ComposeRequest(mode: .rewrite, text: transcript, scene: scene, app: makeAppContext(), vocabulary: dictionary.vocabulary)
        let result = await collectCompose(composer, request)
        guard generation == sessionGeneration else { return }

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            composeOutputForDebug = trimmed
            let final = trimmed.isEmpty ? transcript : trimmed
            await insertAndRecord(final: final, generation: generation, transcriptForHistory: transcript)
        case .failure, .timeout:
            // Graceful degradation: insert the untransformed transcript rather than fail.
            await insertAndRecord(final: transcript, generation: generation, transcriptForHistory: transcript)
        }
    }

    /// - Parameter mode: `.translate` (rule-matched or persistent-toggle: cue already stripped
    ///   client-side, `text` is the content) or `.translateCommand` (server/classifier-matched:
    ///   `text` is the whole utterance, the server extracts the content and target itself).
    private func runTranslate(mode: ComposeRequest.Mode, text: String, target: String, generation: Int, transcriptForHistory: String) async {
        guard let composer else {
            await failTranslate(transcript: transcriptForHistory, generation: generation, error: .engineUnavailable("compose disabled"))
            return
        }

        phase = .composing
        previewText = transcriptForHistory
        composeLabel = "Translating…"
        composeModeForDebug = mode.rawValue

        let request = ComposeRequest(mode: mode, text: text, scene: scene, targetLanguage: target, app: makeAppContext(), vocabulary: dictionary.vocabulary)
        let result = await collectCompose(composer, request)
        guard generation == sessionGeneration else { return }

        switch result {
        case .success(let translated):
            let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            composeOutputForDebug = trimmed
            if trimmed.isEmpty {
                await failTranslate(transcript: transcriptForHistory, generation: generation, error: .emptyTranscript)
            } else {
                await insertAndRecord(final: trimmed, generation: generation, transcriptForHistory: transcriptForHistory)
            }
        case .failure(let error):
            await failTranslate(transcript: transcriptForHistory, generation: generation, error: error)
        case .timeout:
            await failTranslate(transcript: transcriptForHistory, generation: generation, error: .transcriptionFailed("translate timeout"))
        }
    }

    /// Translate failed (or a composer isn't configured): never insert untranslated text
    /// silently. Copy the transcript out via the inserter's own clipboard-fallback semantics
    /// (`into: nil` — it can't paste anywhere specific) and record `.copiedToClipboard` regardless
    /// of what the inserter itself reports, then fail the session.
    private func failTranslate(transcript: String, generation: Int, error: ProsioError) async {
        _ = await inserter.insert(transcript, into: nil)
        tInsertionDone = Date()
        guard generation == sessionGeneration else { return }

        phase = .failed(error)
        previewText = transcript

        let item = HistoryItem(
            text: transcript,
            appBundleID: context?.bundleID,
            appName: context?.appName,
            engineID: activeEngineID ?? "unknown",
            durationSeconds: totalAudioDuration,
            insertion: .copiedToClipboard,
            intent: intent,
            transcript: transcript
        )
        if settings.historyEnabled {
            try? history.append(item)
        }
        onSessionCompleted?(item)

        finishSession(insertedText: transcript, outcome: .copiedToClipboard)
    }

    private func runEdit(instruction: String, generation: Int) async {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            // Empty instruction -> cancel silently, selection untouched.
            finishSession()
            phase = .idle
            previewText = ""
            return
        }
        guard let composer, let selection = context?.selectedText, !selection.isEmpty else {
            phase = .failed(.engineUnavailable("edit unavailable"))
            finishSession()
            return
        }

        phase = .composing
        previewText = trimmedInstruction
        composeLabel = "Editing…"
        composeModeForDebug = "edit"

        let request = ComposeRequest(mode: .edit, text: trimmedInstruction, selection: selection, scene: scene, app: makeAppContext(), vocabulary: dictionary.vocabulary)
        let result = await collectCompose(composer, request)
        guard generation == sessionGeneration else { return }

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            composeOutputForDebug = trimmed
            guard !trimmed.isEmpty else {
                phase = .failed(.emptyTranscript)
                finishSession()
                return
            }
            await insertAndRecord(final: trimmed, generation: generation, transcriptForHistory: trimmedInstruction)
        case .failure(let error):
            phase = .failed(error)
            finishSession()
        case .timeout:
            phase = .failed(.transcriptionFailed("edit timeout"))
            finishSession()
        }
    }

    /// "Help me write" (docs/PROMPTS.md §4b). No selection: composes and inserts at the cursor,
    /// like `.dictate`/`.edit`. With a selection: the selection is context (never rewritten) — the
    /// result streams into the answer card instead, same UI as `.ask`, so Insert/Copy decide.
    /// Any failure (composer unavailable, compose error/timeout, or an empty result) is uniform
    /// regardless of path: nothing is inserted, the instruction goes to the clipboard, and the
    /// session fails with a message telling the user their words are safe there.
    private func runWrite(instruction: String, hasSelection: Bool, generation: Int) async {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            finishSession()
            phase = .idle
            previewText = ""
            return
        }
        guard let composer else {
            await failWrite(instruction: trimmedInstruction, generation: generation)
            return
        }

        let selectedText = hasSelection ? context?.selectedText : nil
        let selection = selectedText?.isEmpty == false ? selectedText : nil

        if let selection {
            await runWriteAnswerCard(instruction: trimmedInstruction, selection: selection, composer: composer, generation: generation)
            return
        }

        phase = .composing
        previewText = trimmedInstruction
        composeLabel = "Writing…"
        composeModeForDebug = "write"

        let request = ComposeRequest(mode: .write, text: trimmedInstruction, scene: scene, app: makeAppContext(), vocabulary: dictionary.vocabulary)
        let result = await collectCompose(composer, request)
        guard generation == sessionGeneration else { return }

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            composeOutputForDebug = trimmed
            guard !trimmed.isEmpty else {
                await failWrite(instruction: trimmedInstruction, generation: generation)
                return
            }
            await insertAndRecord(final: trimmed, generation: generation, transcriptForHistory: trimmedInstruction)
        case .failure, .timeout:
            await failWrite(instruction: trimmedInstruction, generation: generation)
        }
    }

    /// The with-selection "Help me write" path: streams like `.ask`, but any error/empty result
    /// falls through to the uniform `failWrite` treatment (clipboard + HUD error) instead of an
    /// in-card error, since there's no partial "answer" worth keeping around here.
    private func runWriteAnswerCard(instruction: String, selection: String, composer: any Composing, generation: Int) async {
        var liveAnswer = AnswerState(question: instruction, text: "", isStreaming: true, error: nil, turns: [])
        answer = liveAnswer
        phase = .answering
        composeModeForDebug = "write"

        let request = ComposeRequest(mode: .write, text: instruction, selection: selection, scene: scene, app: makeAppContext(), vocabulary: dictionary.vocabulary)
        let startedAt = Date()

        do {
            for try await delta in composer.compose(request) {
                guard generation == sessionGeneration else { return }
                liveAnswer.text += delta
                answer = liveAnswer
            }
            guard generation == sessionGeneration else { return }
            composeLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000

            let trimmedAnswer = liveAnswer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAnswer.isEmpty else {
                await failWrite(instruction: instruction, generation: generation)
                return
            }
            liveAnswer.isStreaming = false
            liveAnswer.turns = [ComposeTurn(role: .user, text: instruction), ComposeTurn(role: .assistant, text: liveAnswer.text)]
            answer = liveAnswer
            composeOutputForDebug = liveAnswer.text
            // Stays in `.answering`: the user Inserts, Copies, or dismisses explicitly.
        } catch {
            guard generation == sessionGeneration else { return }
            composeLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000
            await failWrite(instruction: instruction, generation: generation)
        }
    }

    /// Uniform "Help me write" failure: never insert anything or leave a half-drafted answer card
    /// up — copy the user's own instruction out via the inserter's clipboard-fallback semantics
    /// (`into: nil`, same trick as `failTranslate`) so their dictated words are recoverable, and
    /// fail the session with a message that says exactly that.
    private func failWrite(instruction: String, generation: Int) async {
        _ = await inserter.insert(instruction, into: nil)
        tInsertionDone = Date()
        guard generation == sessionGeneration else { return }

        answer = nil
        phase = .failed(.transcriptionFailed("Couldn't write that — your words are on the clipboard"))
        previewText = instruction

        let item = HistoryItem(
            text: instruction,
            appBundleID: context?.bundleID,
            appName: context?.appName,
            engineID: activeEngineID ?? "unknown",
            durationSeconds: totalAudioDuration,
            insertion: .copiedToClipboard,
            intent: intent,
            transcript: instruction
        )
        if settings.historyEnabled {
            try? history.append(item)
        }
        onSessionCompleted?(item)

        finishSession(insertedText: instruction, outcome: .copiedToClipboard)
    }

    private func runAsk(question: String, generation: Int) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            finishSession()
            phase = .idle
            previewText = ""
            return
        }
        guard let composer else {
            phase = .failed(.engineUnavailable("ask unavailable"))
            finishSession()
            return
        }

        // Starting another `.ask` while a card is already showing is a follow-up: keep the turns.
        let previousTurns = answer?.turns ?? []
        var liveAnswer = AnswerState(question: trimmedQuestion, text: "", isStreaming: true, error: nil, turns: previousTurns)
        answer = liveAnswer
        phase = .answering
        composeModeForDebug = "ask"

        let request = ComposeRequest(mode: .ask, text: trimmedQuestion, selection: context?.selectedText, scene: scene, app: makeAppContext(), vocabulary: dictionary.vocabulary, history: previousTurns)
        let startedAt = Date()

        do {
            for try await delta in composer.compose(request) {
                guard generation == sessionGeneration else { return }
                liveAnswer.text += delta
                answer = liveAnswer
            }
            guard generation == sessionGeneration else { return }
            composeLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000

            let trimmedAnswer = liveAnswer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAnswer.isEmpty {
                // The stream completed without error but produced nothing usable — surface this
                // as an error rather than leaving the card silently blank.
                liveAnswer.isStreaming = false
                liveAnswer.error = .network("empty answer")
                answer = liveAnswer
                composeOutputForDebug = nil
            } else {
                liveAnswer.isStreaming = false
                liveAnswer.turns = previousTurns + [ComposeTurn(role: .user, text: trimmedQuestion), ComposeTurn(role: .assistant, text: liveAnswer.text)]
                answer = liveAnswer
                composeOutputForDebug = liveAnswer.text
            }
            // Stays in `.answering`: the user dismisses or inserts explicitly.
        } catch {
            guard generation == sessionGeneration else { return }
            composeLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000
            liveAnswer.isStreaming = false
            liveAnswer.error = (error as? ProsioError) ?? .transcriptionFailed("\(error)")
            answer = liveAnswer
        }
    }

    /// Dismisses the answer card without inserting anything.
    public func dismissAnswer() {
        answer = nil
        if case .answering = phase {
            phase = .idle
            previewText = ""
            finishSession()
        }
    }

    /// Inserts the current answer's text into the focused app.
    public func insertAnswer() async {
        guard case .answering = phase, let currentAnswer = answer,
              !currentAnswer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = sessionGeneration

        phase = .inserting
        let outcome = await inserter.insert(currentAnswer.text, into: context)
        tInsertionDone = Date()
        guard generation == sessionGeneration else { return }

        phase = .finished(outcome)
        previewText = currentAnswer.text
        answer = nil

        let item = HistoryItem(
            text: currentAnswer.text,
            appBundleID: context?.bundleID,
            appName: context?.appName,
            engineID: activeEngineID ?? "unknown",
            durationSeconds: totalAudioDuration,
            insertion: outcome,
            // `intent` already reflects which mode produced this card — `.ask` for a question,
            // `.write` for a with-selection "Help me write" (docs/PROMPTS.md §4b). Falls back to
            // `.ask` only as a defensive default; it should always be set by the time a card exists.
            intent: intent ?? .ask,
            transcript: currentAnswer.question
        )
        if settings.historyEnabled {
            try? history.append(item)
        }
        if outcome == .pasted || outcome == .accessibility || outcome == .copiedToClipboard {
            onSessionCompleted?(item)
        }

        finishSession(insertedText: currentAnswer.text, outcome: outcome)
    }

    private enum ComposeOutcome {
        case success(String)
        case failure(ProsioError)
        case timeout
    }

    /// Fully collects `composer.compose(request)`'s deltas, racing it against `composeTimeout`.
    private func collectCompose(_ composer: any Composing, _ request: ComposeRequest) async -> ComposeOutcome {
        let startedAt = Date()
        let timeout = composeTimeout

        let outcome = await withTaskGroup(of: ComposeOutcome?.self) { group -> ComposeOutcome? in
            group.addTask {
                do {
                    var collected = ""
                    for try await delta in composer.compose(request) {
                        collected += delta
                    }
                    return .success(collected)
                } catch {
                    return .failure((error as? ProsioError) ?? .transcriptionFailed("\(error)"))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timeout
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }

        composeLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000
        return outcome ?? .timeout
    }

    private func makeAppContext() -> AppContext {
        AppContext(bundleID: context?.bundleID, appName: context?.appName, windowTitle: context?.windowTitle, url: context?.url?.absoluteString)
    }

    private func finishSession(insertedText: String? = nil, outcome: InsertionOutcome? = nil) {
        if settings.saveDebugRecordings {
            writeDebugRecording(insertedText: insertedText, outcome: outcome)
        }
        meterTask?.cancel()
        previewTask?.cancel()
        meterTask = nil
        previewTask = nil
        stopTask = nil
        sessionTranslateTarget = nil
    }

    // MARK: - Debug recording

    private func writeDebugRecording(insertedText: String?, outcome: InsertionOutcome?) {
        let localText = localFinalText
        let cloudText = cloudFinalTextForDebug
        let suspectedDrop = DropDetection.isSuspectedDrop(localText: localText, cloudText: cloudText)
        if suspectedDrop {
            DictationLog.logger.warning("suspected dropped content: cloud transcript much shorter than local (session \(self.sessionID.uuidString, privacy: .public))")
        }

        let failureDescription: String? = {
            if case .failed(let error) = phase { return String(describing: error) }
            return nil
        }()

        let timings = buildTimings()
        logTimings(timings)

        let record = DebugSessionRecord(
            sessionID: sessionID.uuidString,
            createdAt: sessionCreatedAt,
            mode: "auto",
            localEngineID: localEngine.id,
            cloudEngineID: Self.cloudEngineID,
            engineIDUsed: activeEngineID,
            localFinalText: localText,
            cloudFinalText: cloudText,
            insertedText: insertedText,
            outcome: outcome?.rawValue ?? failureDescription,
            audioDurationSeconds: totalAudioDuration,
            suspectedDrop: suspectedDrop,
            timings: timings,
            routeSource: routeSourceForDebug,
            routeCleanProbability: routeCleanProbabilityForDebug,
            routeReason: routeReasonForDebug,
            originalSeconds: originalSecondsForDebug,
            trimmedSeconds: trimmedSecondsForDebug,
            uploadBytes: uploadBytesForDebug,
            audioFormat: audioFormatForDebug,
            intent: intent?.rawValue,
            scene: scene.rawValue,
            composeMode: composeModeForDebug,
            composeLatencyMs: composeLatencyMsForDebug,
            composeOutput: composeOutputForDebug,
            intentDecisionClassified: intentDecisionClassifiedForDebug,
            intentDecisionSource: intentDecisionSourceForDebug,
            intentDecisionConfidence: intentDecisionConfidenceForDebug
        )

        let audioData = capturedPCM
        let root = debugRecordingsRootOverride ?? Self.defaultDebugRecordingsRoot()
        let sessionIDForWrite = sessionID
        let sampleRate = AudioFormat.pcm16Mono16k.sampleRate
        Task.detached(priority: .utility) {
            DebugRecordingWriter.write(root: root, sessionID: sessionIDForWrite, record: record, pcm16: audioData, sampleRate: sampleRate)
        }
    }

    private func buildTimings() -> DebugSessionRecord.Timings {
        func deltaMs(_ from: Date?, _ to: Date?) -> Double? {
            guard let from, let to else { return nil }
            return to.timeIntervalSince(from) * 1000
        }
        return DebugSessionRecord.Timings(
            startToMicOpenMs: deltaMs(tStart, tMicOpen),
            micOpenToFirstChunkMs: deltaMs(tMicOpen, tFirstAudioChunk),
            firstChunkToFirstLocalPartialMs: deltaMs(tFirstAudioChunk, tFirstLocalPartial),
            stopToAudioPreparedMs: deltaMs(tStopCalled, tAudioPrepared),
            audioPreparedToResponseReceivedMs: deltaMs(tAudioPrepared, tResponseReceived),
            responseReceivedToInsertionDoneMs: deltaMs(tResponseReceived, tInsertionDone)
        )
    }

    private func logTimings(_ timings: DebugSessionRecord.Timings) {
        func fmt(_ ms: Double?) -> String {
            ms.map { String(format: "%.0f", $0) } ?? "n/a"
        }
        DictationLog.logger.info("timings(ms) start->micOpen=\(fmt(timings.startToMicOpenMs), privacy: .public) micOpen->firstChunk=\(fmt(timings.micOpenToFirstChunkMs), privacy: .public) firstChunk->firstLocalPartial=\(fmt(timings.firstChunkToFirstLocalPartialMs), privacy: .public) stop->audioPrepared=\(fmt(timings.stopToAudioPreparedMs), privacy: .public) audioPrepared->responseReceived=\(fmt(timings.audioPreparedToResponseReceivedMs), privacy: .public) responseReceived->insertionDone=\(fmt(timings.responseReceivedToInsertionDoneMs), privacy: .public)")
    }

    private static func defaultDebugRecordingsRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "Prosio/debug", directoryHint: .isDirectory)
    }
}
