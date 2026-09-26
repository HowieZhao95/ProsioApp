import Foundation
import Observation

/// The engines a controller chooses from according to `AppSettings.enginePreference`.
///
/// `local` is the on-device engine (SpeechAnalyzer): used for the live preview in every mode, and
/// as the sole engine (preview + final) in `.local` mode.
/// `cloud` is the final-quality engine (cloud batch SMART transcription): used for the final text
/// in `.auto`/`.cloud` mode. It's expected to yield only a single `.final` after audio ends, but
/// the controller also copes if it yields `.partial`s along the way.
public struct EngineSet: Sendable {
    public var cloud: any TranscriptionEngine
    public var local: any TranscriptionEngine

    public init(cloud: any TranscriptionEngine, local: any TranscriptionEngine) {
        self.cloud = cloud
        self.local = local
    }
}

/// Orchestrates one dictation at a time: audio -> engine(s) -> insertion -> history.
///
/// `.auto`/`.cloud`: audio is teed to both `local` (preview only) and `cloud` (the
/// final-determining engine) concurrently. `.local`: `local` alone drives both preview and final.
/// PUBLIC API FROZEN — implementation owned by core agent.
@MainActor
@Observable
public final class DictationController {
    public private(set) var phase: DictationPhase = .idle
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

    /// How long `stop()` waits for the final-determining engine's `.final` before falling back
    /// (to local's final in `.auto`, or to the last preview / failure otherwise). 10s in
    /// production — cloud batch transcription can take ~4s on a cold connection — overridable
    /// (via `@testable import`) so tests don't have to sleep for real.
    var finalTimeout: Duration = .seconds(10)
    /// Bound on how long `resolveStop()` waits for `local` to finish when it needs local's final
    /// text as a fallback (cloud failed/timed out in `.auto`). Local is on-device and expected to
    /// finish quickly once audio ends; this just prevents a stuck local engine from blocking the
    /// fallback indefinitely. Overridable via `@testable import`.
    var localFallbackTimeout: Duration = .seconds(3)
    /// Overrides where debug recordings are written (see `AppSettings.saveDebugRecordings`).
    /// `nil` (production default) means `~/Library/Application Support/Prosio/debug`.
    /// Internal test seam — not part of the public API.
    var debugRecordingsRootOverride: URL?
    /// How long `stop()` waits for local's final before deciding routing needs cloud regardless
    /// (empty/unavailable local -> cloud). `.auto`-with-`router` only. Overridable via `@testable import`.
    var routingLocalFinalTimeout: Duration = .seconds(1.5)
    /// Client-side cap on `router.decide(...)` — any error or overrun is treated as "needs cloud"
    /// per contract. `.auto`-with-`router` only. Overridable via `@testable import`.
    var routerDecisionTimeout: Duration = .seconds(0.8)
    /// How long rewrite/translate/edit compose calls wait before giving up (rewrite falls back to
    /// the untransformed transcript; translate/edit fail). 12s per spec. Overridable via `@testable import`.
    var composeTimeout: Duration = .seconds(12)
    /// Client-side cap on `intentClassifier.classify(...)` — error/timeout/`intent: nil` all
    /// degrade to `IntentRules`. 1.5s per spec. Overridable via `@testable import`.
    var classifyIntentTimeout: Duration = .milliseconds(1500)

    private let audio: any AudioCapturing
    private let engines: EngineSet
    private let inserter: any TextInserting
    private let contextProvider: any FocusContextProviding
    private let history: HistoryStore
    private let dictionary: DictionaryStore
    private let settings: AppSettings
    /// `.auto` mode only: decides whether local's transcript is clean enough to skip the cloud
    /// pass. `nil` (default) means `.auto` behaves exactly as before — always runs cloud.
    private let router: (any RouteDeciding)?
    /// Fired (best-effort, off the main actor) at the start of every session to warm the cloud
    /// HTTPS connection ahead of when it might actually be needed.
    private let prewarmCloud: (@Sendable () async -> Void)?
    /// P1: transforms text with an LLM (rewrite/translate/edit/ask). `nil` (default) turns every
    /// P1 feature off — sessions behave exactly as before (today's fast path).
    private let composer: (any Composing)?
    /// P1: decides dictate/edit/ask/translate for a finished (non-follow-up) session. `nil` means
    /// only `IntentRules` (client-side bilingual cues) ever runs — no server round-trip.
    private let intentClassifier: (any IntentClassifying)?

    private var meterTask: Task<Void, Never>?
    /// Consumes the final-determining engine (`local` in `.local` mode, `cloud` otherwise) and
    /// drives `finalOutcome`.
    private var engineTask: Task<Void, Never>?
    /// Only set in `.auto`/`.cloud` mode: consumes `local` purely for the live preview and as a
    /// fallback final. Never touches `finalOutcome` — a local failure must never fail the session.
    private var previewTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private var totalAudioDuration: TimeInterval = 0

    /// The engine preference this session started with (captured once so a mid-session settings
    /// change can't change how we resolve `stop()`).
    private var activeMode: EnginePreference = .auto
    /// Local's own final text in `.auto`/`.cloud` mode — the fallback used if cloud fails/times out.
    private var localFinalText: String?
    /// True once local has produced at least one partial — after that, local partials always win
    /// over cloud partials for `previewText`.
    private var localHasPartial = false
    /// True once `previewTask` has finished (success or failure) — lets `resolveStop` wait a
    /// bounded amount of time for `localFinalText` to actually be populated before giving up on
    /// the local fallback, instead of racing it.
    private var localOutcomeReady = false
    private var localReadyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Bumped by every `start()`/`cancel()`. Async work (insertion, stop-resolution) captures the
    /// generation it started with and checks it after each `await`; a mismatch means the session
    /// was cancelled (or superseded) in the meantime, so the stale result must not resurrect
    /// `phase`/history/`onSessionCompleted`.
    private var sessionGeneration = 0

    private enum FinalOutcome {
        case success(String)
        case failure(Error)
        case timeout
    }
    private var finalOutcome: FinalOutcome?
    private var finalReadyWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Debug recording (AppSettings.saveDebugRecordings)

    private var sessionID = UUID()
    private var sessionCreatedAt = Date()
    /// Raw little-endian PCM16 mono samples, in order, sent to the engines this session. Only
    /// accumulated while `settings.saveDebugRecordings` is on.
    private var capturedAudioChunks: [Data] = []
    /// Cloud's own final text in `.auto`/`.cloud` mode (distinct from `localFinalText`), captured
    /// purely for the debug recording — `nil` in `.local` mode, where cloud never runs.
    private var cloudFinalTextForDebug: String?

    private var tStart: Date?
    private var tMicOpen: Date?
    private var tFirstAudioChunk: Date?
    private var tFirstLocalPartial: Date?
    private var tStopCalled: Date?
    /// When the final-determining engine's `.final` arrived (cloud in `.auto`/`.cloud`, local in `.local`).
    private var tFinalReceived: Date?
    private var tInsertionDone: Date?
    private var routeDecisionForDebug: RouteDecision?
    private var routeLatencyMsForDebug: Double?
    private var composeModeForDebug: String?
    private var composeLatencyMsForDebug: Double?
    private var composeOutputForDebug: String?
    private var intentDecisionClassifiedForDebug: String?
    private var intentDecisionSourceForDebug: String?
    private var intentDecisionConfidenceForDebug: Double?
    private var intentDecisionLatencyMsForDebug: Double?
    /// "local" | "final" — which transcript's decision was actually used to route this session.
    private var intentDecisionClassifiedOnForDebug: String?
    /// The stop()-time speculative decision (on the local preview), if one ran, kept separately
    /// from the "winning" fields above even when it was later superseded by a final-transcript
    /// reclassification — see `handleFinalTranscript`.
    private var intentDecisionLocalClassifiedForDebug: String?
    private var intentDecisionLocalSourceForDebug: String?
    private var intentDecisionLocalConfidenceForDebug: Double?
    private var intentDecisionLocalLatencyMsForDebug: Double?
    /// The final-transcript (re)classification, if one ran (local was empty/too short, its leading
    /// text diverged from the final transcript, or the local decision was a rules fallback, which
    /// always reclassifies on the final).
    private var intentDecisionFinalClassifiedForDebug: String?
    private var intentDecisionFinalSourceForDebug: String?
    private var intentDecisionFinalConfidenceForDebug: Double?
    private var intentDecisionFinalLatencyMsForDebug: Double?

    // MARK: - P1: intent classification

    /// True when this session is a follow-up while the answer card is showing (started with
    /// `phase == .answering`) — always `.ask`, no classification needed.
    private var isFollowUpAsk = false
    /// Set when `start(trigger:intent:)` was given an explicit intent (tests/explicit callers) —
    /// skips classification entirely and is used as the final word.
    private var explicitIntent: DictationIntent?
    /// Kicked off in `stop()` for non-follow-up sessions; `handleFinalTranscript` awaits it.
    private var classifyIntentTask: Task<Void, Never>?
    private var resolvedIntentDecision: IntentResolution?
    /// The (trimmed) local-preview text the stop()-time speculative classification ran on, if any —
    /// `nil` when it never started (preview too short/empty). Compared against the eventual final
    /// transcript's leading text in `handleFinalTranscript` to decide whether to reclassify: cloud
    /// SMART transcription can normalize a cue word away (observed: "提问" -> "请问") or the local
    /// preview can clip a leading word, either of which would silently turn a command into a plain
    /// dictation if the stale local-preview decision were kept.
    private var classifyIntentSourceText: String?

    private struct IntentResolution {
        var intent: ClassifiedIntent
        var source: String
        var confidence: Double?
        /// Only for a rule-matched `.translate` — the parsed target + cue-stripped body, sent to
        /// `compose(.translate)`. A classifier-matched `.translate` sends the whole utterance to
        /// `compose(.translateCommand)` instead (nil here).
        var ruleTranslateTarget: String?
        var ruleTranslateBody: String?
    }

    // MARK: - Routing (`.auto` mode with `router` set)

    /// Every chunk sent to `local` this session, buffered so it can be replayed to `cloud` in one
    /// shot if the router decides cloud is needed (cloud never sees live audio in routed mode).
    private var bufferedChunksForReplay: [AudioChunk] = []
    private var usesRouting: Bool { activeMode == .auto && router != nil }

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
        engines: EngineSet,
        inserter: any TextInserting,
        contextProvider: any FocusContextProviding,
        history: HistoryStore,
        dictionary: DictionaryStore,
        settings: AppSettings,
        router: (any RouteDeciding)? = nil,
        prewarmCloud: (@Sendable () async -> Void)? = nil,
        composer: (any Composing)? = nil,
        intentClassifier: (any IntentClassifying)? = nil
    ) {
        self.audio = audio
        self.engines = engines
        self.inserter = inserter
        self.contextProvider = contextProvider
        self.history = history
        self.dictionary = dictionary
        self.settings = settings
        self.router = router
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
    ///   intent (dictate/edit/ask/translate) is decided after `stop()` by `intentClassifier` (with
    ///   `IntentRules` as a client-side fallback) — `intent` here is only an optimistic placeholder
    ///   for the HUD until that decision arrives. An explicit `intent` skips classification
    ///   entirely and is used as-is (existing test/caller behavior).
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
        }
        isFollowUpAsk = isFollowUp

        sessionGeneration += 1

        previewText = ""
        level = 0
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        self.trigger = trigger
        totalAudioDuration = 0
        finalOutcome = nil
        finalReadyWaiters = []
        localFinalText = nil
        localHasPartial = false
        localOutcomeReady = false
        localReadyWaiters = []

        sessionID = UUID()
        sessionCreatedAt = Date()
        capturedAudioChunks = []
        cloudFinalTextForDebug = nil
        tStart = sessionCreatedAt
        tMicOpen = nil
        tFirstAudioChunk = nil
        tFirstLocalPartial = nil
        tStopCalled = nil
        tFinalReceived = nil
        tInsertionDone = nil
        routeDecisionForDebug = nil
        routeLatencyMsForDebug = nil
        bufferedChunksForReplay = []
        composeLabel = nil
        composeModeForDebug = nil
        composeLatencyMsForDebug = nil
        composeOutputForDebug = nil
        intentDecisionClassifiedForDebug = nil
        intentDecisionSourceForDebug = nil
        intentDecisionConfidenceForDebug = nil
        intentDecisionLatencyMsForDebug = nil
        intentDecisionClassifiedOnForDebug = nil
        intentDecisionLocalClassifiedForDebug = nil
        intentDecisionLocalSourceForDebug = nil
        intentDecisionLocalConfidenceForDebug = nil
        intentDecisionLocalLatencyMsForDebug = nil
        intentDecisionFinalClassifiedForDebug = nil
        intentDecisionFinalSourceForDebug = nil
        intentDecisionFinalConfidenceForDebug = nil
        intentDecisionFinalLatencyMsForDebug = nil
        classifyIntentTask = nil
        resolvedIntentDecision = nil
        classifyIntentSourceText = nil
        explicitIntent = isFollowUpAsk ? nil : requestedIntent
        sessionTranslateTarget = nil

        let mode = settings.enginePreference
        activeMode = mode
        activeEngineID = (mode == .local) ? engines.local.id : engines.cloud.id

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

        let capturedContext = contextProvider.currentContext()
        context = capturedContext
        let hasSelection = capturedContext.selectedText?.isEmpty == false && !capturedContext.isSecureInput
        if isFollowUpAsk {
            intent = .ask
        } else {
            // Optimistic placeholder for the HUD until classification resolves (or, with an
            // explicit `requestedIntent`, the final word — classification is skipped entirely).
            intent = requestedIntent ?? (hasSelection ? .edit : .dictate)
        }
        scene = SceneResolver.scene(for: capturedContext, overrides: settings.sceneOverrides)

        if let prewarmCloud {
            Task.detached(priority: .utility) {
                await prewarmCloud()
            }
        }

        if usesRouting {
            startRoutedAutoSession(audioStream: audioStream)
            return
        }

        // The final-determining engine always gets its own audio feed. In `.auto`/`.cloud` mode,
        // `local` (preview-only) gets a second, independent feed of the very same chunks.
        let finalEngine: any TranscriptionEngine = (mode == .local) ? engines.local : engines.cloud
        let (finalAudio, finalContinuation) = AsyncStream<AudioChunk>.makeStream()

        var previewAudioContinuation: AsyncStream<AudioChunk>.Continuation?
        var previewAudioStream: AsyncStream<AudioChunk>?
        if mode != .local {
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
            previewAudioStream = stream
            previewAudioContinuation = continuation
        }

        let options = TranscriptionOptions(mode: .smart, vocabulary: transcriptionVocabulary, languageHints: settings.languageHints)
        let finalEvents = finalEngine.transcribe(audio: finalAudio, options: options)
        let previewEvents = previewAudioStream.map { engines.local.transcribe(audio: $0, options: options) }

        let meterTask = Task { @MainActor [weak self] in
            guard let self else {
                finalContinuation.finish()
                previewAudioContinuation?.finish()
                return
            }
            for await chunk in audioStream {
                if self.tFirstAudioChunk == nil {
                    self.tFirstAudioChunk = Date()
                }
                self.updateLevel(with: chunk.level)
                self.totalAudioDuration = max(self.totalAudioDuration, TimeInterval(chunk.timestamp))
                if self.settings.saveDebugRecordings {
                    self.capturedAudioChunks.append(chunk.pcm16)
                }
                finalContinuation.yield(chunk)
                previewAudioContinuation?.yield(chunk)
            }
            finalContinuation.finish()
            previewAudioContinuation?.finish()
        }
        self.meterTask = meterTask

        let engineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in finalEvents {
                    switch event {
                    case .partial(let text):
                        // In `.local` mode local IS the only source of preview. In `.auto`/
                        // `.cloud` mode, cloud partials only show while local hasn't produced any
                        // of its own yet (local, once it starts, always wins).
                        if mode == .local {
                            if self.tFirstLocalPartial == nil {
                                self.tFirstLocalPartial = Date()
                            }
                            self.previewText = text
                        } else if !self.localHasPartial {
                            self.previewText = text
                        }
                    case .final(let text):
                        if self.tFinalReceived == nil {
                            self.tFinalReceived = Date()
                        }
                        if mode == .local {
                            self.localFinalText = text
                        } else {
                            self.cloudFinalTextForDebug = text
                        }
                        self.resolveFinal(.success(text))
                    }
                }
            } catch {
                let mapped = (error as? ProsioError) ?? .transcriptionFailed("\(error)")
                // Only `.local` mode has no fallback engine to lean on, so only there do we abort
                // immediately; `.auto`/`.cloud` let `stop()`'s fallback logic decide once called.
                if mode == .local, case .listening = self.phase {
                    self.audio.stop()
                    self.meterTask?.cancel()
                    self.phase = .failed(mapped)
                }
                self.resolveFinal(.failure(mapped))
            }
        }
        self.engineTask = engineTask

        if let previewEvents {
            let previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await event in previewEvents {
                        switch event {
                        case .partial(let text):
                            if self.tFirstLocalPartial == nil {
                                self.tFirstLocalPartial = Date()
                            }
                            self.localHasPartial = true
                            self.previewText = text
                        case .final(let text):
                            self.localFinalText = text
                            // Keep showing local's final text as the preview while cloud is
                            // still pending.
                            self.previewText = text
                        }
                    }
                } catch {
                    // A local failure must never fail the session — cloud continues unaffected,
                    // and `localFinalText` simply stays nil (no fallback value available).
                }
                self.markLocalReady()
            }
            self.previewTask = previewTask
        }
    }

    /// Closes the mic, waits for final text, inserts it, records history.
    public func stop() {
        guard case .listening = phase else { return }
        let generation = sessionGeneration
        tStopCalled = Date()
        audio.stop()
        phase = .finalizing
        finalOutcome = nil

        // Classify concurrently with transcript finalization — never awaited here, so it adds no
        // latency when it resolves before the transcript does. Skipped for follow-ups (always
        // `.ask`) and when the caller gave an explicit intent (used as-is).
        if !isFollowUpAsk, explicitIntent == nil {
            let candidate = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSelection = context?.selectedText?.isEmpty == false && !(context?.isSecureInput ?? false)
            if candidate.count >= 2 {
                classifyIntentSourceText = candidate
                classifyIntentTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let resolution = await self.resolveIntentDecision(transcript: candidate, hasSelection: hasSelection)
                    guard generation == self.sessionGeneration else { return }
                    self.applyIntentDecision(resolution, classifiedOn: "local")
                }
            }
            // Else: local preview too short (or empty) to classify usefully — `handleFinalTranscript`
            // classifies the real final transcript instead once it's available (adds latency).
        }

        if usesRouting {
            stopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.resolveRoutedStop(generation: generation)
            }
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.finalTimeout)
            guard !Task.isCancelled else { return }
            self.resolveFinal(.timeout)
        }
        self.timeoutTask = timeoutTask

        stopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForFinalOutcome()
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            await self.resolveStop(generation: generation)
        }
    }

    /// Aborts without inserting.
    public func cancel() {
        sessionGeneration += 1
        audio.stop()
        // Unblock anything still suspended in `waitForFinalOutcome()` (e.g. `stop()` was called
        // and we're mid-`.finalizing`) so that task doesn't leak forever waiting on a continuation
        // nobody will ever resume. Its generation is already stale, so `resolveStop` will bail.
        resolveFinal(.failure(ProsioError.cancelled))
        classifyIntentTask?.cancel()
        classifyIntentTask = nil
        classifyIntentSourceText = nil
        meterTask?.cancel()
        engineTask?.cancel()
        previewTask?.cancel()
        stopTask?.cancel()
        timeoutTask?.cancel()
        meterTask = nil
        engineTask = nil
        previewTask = nil
        stopTask = nil
        timeoutTask = nil
        finalOutcome = nil
        finalReadyWaiters = []
        sessionTranslateTarget = nil
        localFinalText = nil
        localHasPartial = false
        localOutcomeReady = false
        localReadyWaiters = []
        bufferedChunksForReplay = []
        routeDecisionForDebug = nil
        routeLatencyMsForDebug = nil
        previewText = ""
        phase = .idle
    }

    // MARK: - Routed `.auto` session (router set)

    /// Runs ONLY `local` during listening (cloud only ever needs the audio at the end), while
    /// buffering every chunk so it can be replayed to `cloud` in one shot if routing decides
    /// cloud is needed.
    private func startRoutedAutoSession(audioStream: AsyncStream<AudioChunk>) {
        let (localAudio, localContinuation) = AsyncStream<AudioChunk>.makeStream()
        let options = TranscriptionOptions(mode: .smart, vocabulary: transcriptionVocabulary, languageHints: settings.languageHints)
        let localEvents = engines.local.transcribe(audio: localAudio, options: options)

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
                self.bufferedChunksForReplay.append(chunk)
                if self.settings.saveDebugRecordings {
                    self.capturedAudioChunks.append(chunk.pcm16)
                }
                localContinuation.yield(chunk)
            }
            localContinuation.finish()
        }
        self.meterTask = meterTask

        let engineTask = Task { @MainActor [weak self] in
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
                        if self.tFinalReceived == nil {
                            self.tFinalReceived = Date()
                        }
                        self.localFinalText = text
                        self.resolveFinal(.success(text))
                    }
                }
            } catch {
                // A local failure here just means routing has no local transcript to work with —
                // `resolveRoutedStop` treats that the same as "empty" and goes straight to cloud,
                // it must not fail the session outright.
                let mapped = (error as? ProsioError) ?? .transcriptionFailed("\(error)")
                self.resolveFinal(.failure(mapped))
            }
        }
        self.engineTask = engineTask
    }

    /// `stop()` resolution for a routed `.auto` session: wait (bounded) for local's final, ask
    /// the router if it's usable, then either insert it directly or replay the buffered audio to
    /// cloud and continue exactly like the non-routed `.auto` flow (cloud final -> insert; cloud
    /// failure -> local fallback).
    private func resolveRoutedStop(generation: Int) async {
        let localTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.routingLocalFinalTimeout)
            // `try?` swallows the `CancellationError` from a cancelled sleep, so without this
            // check a *stale* timeout — cancelled while asleep, but already past the checkpoint
            // by the time it gets a MainActor turn — would still fire `resolveFinal(.timeout)`.
            // That's especially dangerous here because `runCloudReplay` deliberately resets
            // `finalOutcome` to reuse this same signalling for cloud's phase: a late local
            // timeout landing after that reset would corrupt cloud's outcome.
            guard !Task.isCancelled else { return }
            self.resolveFinal(.timeout)
        }
        await waitForFinalOutcome()
        localTimeoutTask.cancel()

        guard generation == sessionGeneration else { return } // cancel() could race in above

        let localText: String? = {
            guard case .success(let text) = finalOutcome else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        guard let localText else {
            // Local final empty/unavailable/failed/timed out -> needs cloud, no point asking the router.
            routeDecisionForDebug = RouteDecision(needsCloud: true, cleanProbability: nil, reason: "local-unavailable")
            await runCloudReplay(generation: generation, localFallback: nil)
            return
        }

        let decision = await decideRoute(localText: localText)
        routeDecisionForDebug = decision
        guard generation == sessionGeneration else { return } // cancel() could race in above (router call awaited)

        if !decision.needsCloud {
            activeEngineID = engines.local.id
            await handleFinalTranscript(localText, generation: generation)
        } else {
            await runCloudReplay(generation: generation, localFallback: localText)
        }
    }

    /// Calls `router.decide(...)`, capped client-side at `routerDecisionTimeout`. Any error or
    /// overrun maps to `needsCloud: true` (never blocks dictation), per contract.
    private func decideRoute(localText: String) async -> RouteDecision {
        guard let router else {
            return RouteDecision(needsCloud: true, cleanProbability: nil, reason: "no-router")
        }
        let options = TranscriptionOptions(mode: .smart, vocabulary: transcriptionVocabulary, languageHints: settings.languageHints)
        let startedAt = Date()

        let outcome = await withTaskGroup(of: RouteDecision?.self) { group -> RouteDecision? in
            group.addTask {
                try? await router.decide(localTranscript: localText, options: options)
            }
            group.addTask {
                try? await Task.sleep(for: self.routerDecisionTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }

        routeLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000
        return outcome ?? RouteDecision(needsCloud: true, cleanProbability: nil, reason: "router-error")
    }

    /// Replays every buffered chunk to `cloud` (which never saw live audio in routed mode) and
    /// resolves exactly like the non-routed `.auto` flow: cloud final wins; on cloud failure or
    /// timeout, fall back to `localFallback` (already in hand — no extra wait needed) if any.
    private func runCloudReplay(generation: Int, localFallback: String?) async {
        guard generation == sessionGeneration else { return }
        activeEngineID = engines.cloud.id

        let chunks = bufferedChunksForReplay
        let replayStream = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        let options = TranscriptionOptions(mode: .smart, vocabulary: transcriptionVocabulary, languageHints: settings.languageHints)
        let cloudEvents = engines.cloud.transcribe(audio: replayStream, options: options)

        finalOutcome = nil
        finalReadyWaiters = []

        let cloudTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.finalTimeout)
            guard !Task.isCancelled else { return }
            self.resolveFinal(.timeout)
        }
        self.timeoutTask = cloudTimeoutTask

        let cloudTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in cloudEvents {
                    switch event {
                    case .partial(let text):
                        self.previewText = text
                    case .final(let text):
                        // Overwrite: this is the terminal final that actually determines the
                        // outcome, superseding local's earlier timestamp.
                        self.tFinalReceived = Date()
                        self.cloudFinalTextForDebug = text
                        self.resolveFinal(.success(text))
                    }
                }
            } catch {
                let mapped = (error as? ProsioError) ?? .transcriptionFailed("\(error)")
                self.resolveFinal(.failure(mapped))
            }
        }
        self.engineTask = cloudTask

        await waitForFinalOutcome()
        cloudTimeoutTask.cancel()
        self.timeoutTask = nil
        guard generation == sessionGeneration else { return } // cancel() could race in above

        switch finalOutcome {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                activeEngineID = engines.cloud.id
                await handleFinalTranscript(trimmed, generation: generation)
            } else if let localFallback {
                activeEngineID = engines.local.id
                await handleFinalTranscript(localFallback, generation: generation)
            } else {
                handleEmptyFinal()
            }

        case .failure(let error):
            if let localFallback {
                activeEngineID = engines.local.id
                await handleFinalTranscript(localFallback, generation: generation)
            } else {
                let mapped = (error as? ProsioError) ?? .transcriptionFailed("\(error)")
                phase = .failed(mapped)
                finishSession()
            }

        case .timeout, .none:
            if let localFallback {
                activeEngineID = engines.local.id
                await handleFinalTranscript(localFallback, generation: generation)
            } else {
                phase = .failed(.transcriptionFailed("timeout"))
                finishSession()
            }
        }
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

    // MARK: - Final-outcome signalling

    private func resolveFinal(_ outcome: FinalOutcome) {
        guard finalOutcome == nil else { return }
        finalOutcome = outcome
        let waiters = finalReadyWaiters
        finalReadyWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForFinalOutcome() async {
        if finalOutcome != nil { return }
        await withCheckedContinuation { continuation in
            finalReadyWaiters.append(continuation)
        }
    }

    // MARK: - Local-readiness signalling (for the `.auto` cloud-failed/timed-out fallback)

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

    /// Waits (up to `localFallbackTimeout`) for `previewTask` to finish, so `localFinalText` is
    /// actually populated (if it ever will be) before we check it — otherwise a fast cloud
    /// failure could race ahead of a still-processing local engine and we'd wrongly conclude
    /// there's no usable fallback. No-op outside `.auto` mode or once already ready.
    private func waitForLocalReadyBounded() async {
        guard activeMode == .auto, previewTask != nil, !localOutcomeReady else { return }
        let localTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.localFallbackTimeout)
            guard !Task.isCancelled else { return }
            self.markLocalReady()
        }
        await waitForLocalReady()
        localTimeoutTask.cancel()
    }

    // MARK: - Stop resolution

    private func resolveStop(generation: Int) async {
        // `cancel()` may have run (and bumped the generation) while we were suspended waiting for
        // the final outcome; if so this session is no longer current and must not touch phase.
        guard generation == sessionGeneration else { return }

        switch finalOutcome {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                handleEmptyFinal()
            } else {
                await handleFinalTranscript(trimmed, generation: generation)
            }

        case .failure(let error):
            await waitForLocalReadyBounded()
            guard generation == sessionGeneration else { return } // cancel() could race in above

            if let fallback = usableAutoLocalFallback() {
                activeEngineID = engines.local.id
                await handleFinalTranscript(fallback, generation: generation)
            } else {
                let mapped = (error as? ProsioError) ?? .transcriptionFailed("\(error)")
                phase = .failed(mapped)
                finishSession()
            }

        case .timeout, .none:
            await waitForLocalReadyBounded()
            guard generation == sessionGeneration else { return } // cancel() could race in above

            if let fallback = usableAutoLocalFallback() {
                activeEngineID = engines.local.id
                await handleFinalTranscript(fallback, generation: generation)
            } else if activeMode != .cloud {
                // `.local`: this IS the original single-engine "timeout -> last preview" fallback.
                // `.auto`: tertiary fallback once local's own final isn't available either —
                // whatever's currently on screen (a local or cloud partial) beats nothing.
                let fallback = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fallback.isEmpty {
                    await handleFinalTranscript(fallback, generation: generation)
                } else {
                    phase = .failed(.transcriptionFailed("timeout"))
                    finishSession()
                }
            } else {
                // `.cloud`: no fallback engine at all.
                phase = .failed(.transcriptionFailed("timeout"))
                finishSession()
            }
        }
    }

    /// Non-nil only in `.auto` mode, when local produced usable (non-empty, trimmed) final text —
    /// the fallback used when cloud fails or times out. `.cloud` mode never falls back.
    private func usableAutoLocalFallback() -> String? {
        guard activeMode == .auto, let localFinalText else { return nil }
        let trimmed = localFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// Every "we have the final transcript" path (whichever engine/fallback produced it) routes
    /// through here so compose (rewrite/translate/edit/ask) applies uniformly regardless of source.
    private func handleFinalTranscript(_ transcript: String, generation: Int) async {
        if isFollowUpAsk {
            await runAsk(question: transcript, generation: generation)
            return
        }
        if let explicitIntent {
            // Caller (test or explicit code path) gave the answer directly — classification never ran.
            switch explicitIntent {
            case .edit: await runEdit(instruction: transcript, generation: generation)
            case .ask: await runAsk(question: transcript, generation: generation)
            case .dictate: await runDictateDefault(transcript: transcript, generation: generation)
            }
            return
        }

        // Wait for the early (stop()-time) classification attempt, if one was started.
        await classifyIntentTask?.value
        guard generation == sessionGeneration else { return }

        let hasSelection = context?.selectedText?.isEmpty == false && !(context?.isSecureInput ?? false)
        let resolution: IntentResolution

        if let resolvedIntentDecision,
           let localCandidate = classifyIntentSourceText,
           Self.normalizedLeadingText(localCandidate) == Self.normalizedLeadingText(transcript) {
            // The early (stop()-time) decision's leading text still matches the final transcript.
            if resolvedIntentDecision.source == "rules" {
                // Rules fallback must always run on the best available transcript (here: the
                // actual final) even when the leading text happens to match — a mismatch further
                // into the utterance (target/body parsing) is still possible, and there's no
                // benefit to keeping a rules decision computed on a possibly-stale preview. No
                // point retrying the classifier again immediately, though — it was already
                // unavailable/timed out/nil moments ago.
                let rules = IntentRules.classify(transcript, hasSelection: hasSelection, defaultTranslateTarget: settings.translateTarget)
                resolution = IntentResolution(
                    intent: rules.intent,
                    source: "rules",
                    confidence: nil,
                    ruleTranslateTarget: rules.translateTarget,
                    ruleTranslateBody: rules.translateBody
                )
                intentDecisionLatencyMsForDebug = nil // no classifier round-trip this time
                applyIntentDecision(resolution, classifiedOn: "final")
            } else {
                resolution = resolvedIntentDecision
            }
        } else {
            // Local preview was too short to classify (`resolvedIntentDecision == nil`), or its
            // leading text diverged from the final transcript — e.g. cloud SMART normalizing a cue
            // word away (observed: "提问" -> "请问") or a clipped leading word in the local preview.
            // Discard the early attempt (if any) and (re)classify on the actual final transcript.
            // Adds latency; correctness wins here since a missed cue silently turns a command into
            // plain dictation.
            resolution = await resolveIntentDecision(transcript: transcript, hasSelection: hasSelection)
            guard generation == sessionGeneration else { return }
            applyIntentDecision(resolution, classifiedOn: "final")
        }

        switch resolution.intent {
        case .dictate:
            await runDictateDefault(transcript: transcript, generation: generation)
        case .edit:
            await runEdit(instruction: transcript, generation: generation)
        case .ask:
            await runAsk(question: transcript, generation: generation)
        case .translate:
            if resolution.source == "rules", let target = resolution.ruleTranslateTarget, let body = resolution.ruleTranslateBody {
                await runTranslate(mode: .translate, text: body, target: target, generation: generation, transcriptForHistory: transcript)
            } else {
                await runTranslate(mode: .translateCommand, text: transcript, target: settings.translateTarget, generation: generation, transcriptForHistory: transcript)
            }
        }
    }

    /// `.dictate`-classified (or classifier-less, or explicit `.dictate`) sessions: the persistent
    /// Translate toggle, then scene adaptation, then the fast path — all unchanged from before P1.1.
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

    /// Classifier (`intentClassifier`, capped at `classifyIntentTimeout`) -> `IntentRules` fallback
    /// -> default (dictate, or edit with a selection). Never fails to produce a result.
    private func resolveIntentDecision(transcript: String, hasSelection: Bool) async -> IntentResolution {
        if let intentClassifier {
            let startedAt = Date()
            let decision = await withTaskGroup(of: IntentDecision?.self) { group -> IntentDecision? in
                group.addTask { [makeAppContext] in
                    guard let decision = try? await intentClassifier.classify(transcript: transcript, hasSelection: hasSelection, app: makeAppContext()),
                          decision.intent != nil else { return nil }
                    return decision
                }
                group.addTask {
                    try? await Task.sleep(for: self.classifyIntentTimeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? nil
            }
            intentDecisionLatencyMsForDebug = Date().timeIntervalSince(startedAt) * 1000

            if let decision, let classified = decision.intent {
                return IntentResolution(intent: classified, source: decision.source, confidence: decision.confidence)
            }
            // Classifier threw, timed out, or explicitly returned `intent: nil` ("unavailable") ->
            // degrade to client-side rules.
        }

        let rules = IntentRules.classify(transcript, hasSelection: hasSelection, defaultTranslateTarget: settings.translateTarget)
        return IntentResolution(
            intent: rules.intent,
            source: "rules",
            confidence: nil,
            ruleTranslateTarget: rules.translateTarget,
            ruleTranslateBody: rules.translateBody
        )
    }

    /// - Parameter classifiedOn: "local" (stop()-time speculative decision on the local preview) or
    ///   "final" (decided/redecided on the actual final transcript) — recorded separately in the
    ///   debug recording (`intentDecisionLocal*`/`intentDecisionFinal*`) alongside the "winning"
    ///   flat fields (`intentDecisionClassified`/etc.), which always reflect whichever call this was
    ///   invoked with most recently.
    private func applyIntentDecision(_ resolution: IntentResolution, classifiedOn: String) {
        resolvedIntentDecision = resolution
        // `ClassifiedIntent.translate` has no `DictationIntent` equivalent — publish `.dictate`
        // (a translate-classified session is still, structurally, a dictation).
        intent = {
            switch resolution.intent {
            case .dictate, .translate: return .dictate
            case .edit: return .edit
            case .ask: return .ask
            }
        }()
        sessionTranslateTarget = (resolution.intent == .translate) ? (resolution.ruleTranslateTarget ?? settings.translateTarget) : nil

        intentDecisionClassifiedForDebug = resolution.intent.rawValue
        intentDecisionSourceForDebug = resolution.source
        intentDecisionConfidenceForDebug = resolution.confidence
        intentDecisionClassifiedOnForDebug = classifiedOn

        let latencyMs = self.intentDecisionLatencyMsForDebug
        switch classifiedOn {
        case "local":
            intentDecisionLocalClassifiedForDebug = resolution.intent.rawValue
            intentDecisionLocalSourceForDebug = resolution.source
            intentDecisionLocalConfidenceForDebug = resolution.confidence
            intentDecisionLocalLatencyMsForDebug = latencyMs
        case "final":
            intentDecisionFinalClassifiedForDebug = resolution.intent.rawValue
            intentDecisionFinalSourceForDebug = resolution.source
            intentDecisionFinalConfidenceForDebug = resolution.confidence
            intentDecisionFinalLatencyMsForDebug = latencyMs
        default:
            break
        }

        ProsioLog.intent.info("intent decision=\(resolution.intent.rawValue, privacy: .public) source=\(resolution.source, privacy: .public) confidence=\(resolution.confidence.map { String(format: "%.2f", $0) } ?? "n/a", privacy: .public) classifiedOn=\(classifiedOn, privacy: .public) latencyMs=\(latencyMs.map { String(format: "%.0f", $0) } ?? "n/a", privacy: .public)")
    }

    /// Strips whitespace/punctuation and keeps the first `count` characters — used to compare a
    /// stop()-time local-preview candidate against the eventual final transcript. Insensitive to a
    /// cue-word normalization or a clipped leading word only if it happens to fall entirely outside
    /// this window; see `handleFinalTranscript`.
    private static func normalizedLeadingText(_ text: String, count: Int = 6) -> String {
        var result = ""
        for character in text where !(character.isWhitespace || character.isPunctuation) {
            result.append(character)
            if result.count >= count { break }
        }
        return result
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
    ///   client-side, `text` is the content) or `.translateCommand` (classifier-matched: `text` is
    ///   the whole utterance, the server extracts the content and target itself).
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
            intent: .ask,
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
        classifyIntentTask?.cancel()
        classifyIntentTask = nil
        meterTask?.cancel()
        engineTask?.cancel()
        previewTask?.cancel()
        meterTask = nil
        engineTask = nil
        previewTask = nil
        stopTask = nil
        timeoutTask = nil
        finalOutcome = nil
        finalReadyWaiters = []
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
            mode: activeMode.rawValue,
            localEngineID: engines.local.id,
            cloudEngineID: engines.cloud.id,
            engineIDUsed: activeEngineID,
            localFinalText: localText,
            cloudFinalText: cloudText,
            insertedText: insertedText,
            outcome: outcome?.rawValue ?? failureDescription,
            audioDurationSeconds: totalAudioDuration,
            suspectedDrop: suspectedDrop,
            timings: timings,
            routeNeedsCloud: routeDecisionForDebug?.needsCloud,
            routeCleanProbability: routeDecisionForDebug?.cleanProbability,
            routeReason: routeDecisionForDebug?.reason,
            routeLatencyMs: routeLatencyMsForDebug,
            intent: intent?.rawValue,
            scene: scene.rawValue,
            composeMode: composeModeForDebug,
            composeLatencyMs: composeLatencyMsForDebug,
            composeOutput: composeOutputForDebug,
            intentDecisionClassified: intentDecisionClassifiedForDebug,
            intentDecisionSource: intentDecisionSourceForDebug,
            intentDecisionConfidence: intentDecisionConfidenceForDebug,
            intentDecisionLatencyMs: intentDecisionLatencyMsForDebug,
            intentDecisionClassifiedOn: intentDecisionClassifiedOnForDebug,
            intentDecisionLocalClassified: intentDecisionLocalClassifiedForDebug,
            intentDecisionLocalSource: intentDecisionLocalSourceForDebug,
            intentDecisionLocalConfidence: intentDecisionLocalConfidenceForDebug,
            intentDecisionLocalLatencyMs: intentDecisionLocalLatencyMsForDebug,
            intentDecisionFinalClassified: intentDecisionFinalClassifiedForDebug,
            intentDecisionFinalSource: intentDecisionFinalSourceForDebug,
            intentDecisionFinalConfidence: intentDecisionFinalConfidenceForDebug,
            intentDecisionFinalLatencyMs: intentDecisionFinalLatencyMsForDebug
        )

        var audioData = Data()
        audioData.reserveCapacity(capturedAudioChunks.reduce(0) { $0 + $1.count })
        for chunk in capturedAudioChunks {
            audioData.append(chunk)
        }

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
            stopToFinalReceivedMs: deltaMs(tStopCalled, tFinalReceived),
            finalReceivedToInsertionDoneMs: deltaMs(tFinalReceived, tInsertionDone)
        )
    }

    private func logTimings(_ timings: DebugSessionRecord.Timings) {
        func fmt(_ ms: Double?) -> String {
            ms.map { String(format: "%.0f", $0) } ?? "n/a"
        }
        DictationLog.logger.info("timings(ms) start->micOpen=\(fmt(timings.startToMicOpenMs), privacy: .public) micOpen->firstChunk=\(fmt(timings.micOpenToFirstChunkMs), privacy: .public) firstChunk->firstLocalPartial=\(fmt(timings.firstChunkToFirstLocalPartialMs), privacy: .public) stop->finalReceived=\(fmt(timings.stopToFinalReceivedMs), privacy: .public) finalReceived->insertionDone=\(fmt(timings.finalReceivedToInsertionDoneMs), privacy: .public)")
    }

    private static func defaultDebugRecordingsRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "Prosio/debug", directoryHint: .isDirectory)
    }
}
