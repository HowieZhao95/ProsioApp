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

    private let audio: any AudioCapturing
    private let engines: EngineSet
    private let inserter: any TextInserting
    private let contextProvider: any FocusContextProviding
    private let history: HistoryStore
    private let dictionary: DictionaryStore
    private let settings: AppSettings

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

    public init(
        audio: any AudioCapturing,
        engines: EngineSet,
        inserter: any TextInserting,
        contextProvider: any FocusContextProviding,
        history: HistoryStore,
        dictionary: DictionaryStore,
        settings: AppSettings
    ) {
        self.audio = audio
        self.engines = engines
        self.inserter = inserter
        self.contextProvider = contextProvider
        self.history = history
        self.dictionary = dictionary
        self.settings = settings
    }

    /// True while listening/finalizing/inserting.
    public var isBusy: Bool {
        switch phase {
        case .listening, .finalizing, .inserting: true
        default: false
        }
    }

    /// Opens the mic and starts streaming, then captures focus context. No-op if busy.
    public func start(trigger: DictationTrigger) {
        guard !isBusy else { return }

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
        phase = .listening

        context = contextProvider.currentContext()

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

        let options = TranscriptionOptions(mode: .smart, vocabulary: dictionary.vocabulary, languageHints: settings.languageHints)
        let finalEvents = finalEngine.transcribe(audio: finalAudio, options: options)
        let previewEvents = previewAudioStream.map { engines.local.transcribe(audio: $0, options: options) }

        let meterTask = Task { @MainActor [weak self] in
            guard let self else {
                finalContinuation.finish()
                previewAudioContinuation?.finish()
                return
            }
            for await chunk in audioStream {
                self.updateLevel(with: chunk.level)
                self.totalAudioDuration = max(self.totalAudioDuration, TimeInterval(chunk.timestamp))
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
                        if mode == .local || !self.localHasPartial {
                            self.previewText = text
                        }
                    case .final(let text):
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
        audio.stop()
        phase = .finalizing
        finalOutcome = nil

        let timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.finalTimeout)
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
        localFinalText = nil
        localHasPartial = false
        localOutcomeReady = false
        localReadyWaiters = []
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
                await insertAndRecord(final: trimmed, generation: generation)
            }

        case .failure(let error):
            await waitForLocalReadyBounded()
            guard generation == sessionGeneration else { return } // cancel() could race in above

            if let fallback = usableAutoLocalFallback() {
                activeEngineID = engines.local.id
                await insertAndRecord(final: fallback, generation: generation)
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
                await insertAndRecord(final: fallback, generation: generation)
            } else if activeMode != .cloud {
                // `.local`: this IS the original single-engine "timeout -> last preview" fallback.
                // `.auto`: tertiary fallback once local's own final isn't available either —
                // whatever's currently on screen (a local or cloud partial) beats nothing.
                let fallback = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fallback.isEmpty {
                    await insertAndRecord(final: fallback, generation: generation)
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

    private func insertAndRecord(final: String, generation: Int) async {
        phase = .inserting
        let outcome = await inserter.insert(final, into: context)

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
            insertion: outcome
        )

        if settings.historyEnabled {
            try? history.append(item)
        }
        if outcome == .pasted || outcome == .accessibility || outcome == .copiedToClipboard {
            onSessionCompleted?(item)
        }

        finishSession()
    }

    private func finishSession() {
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
    }
}
