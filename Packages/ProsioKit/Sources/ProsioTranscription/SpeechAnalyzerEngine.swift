import AVFoundation
import Foundation
import ProsioCore
import Speech
import os

/// On-device live-preview transcription with Apple SpeechAnalyzer + `DictationTranscriber`
/// (macOS/iOS 26). The final, SMART-cleaned text now comes from the cloud batch engine
/// (`CloudBatchTranscriptionEngine`); this engine's job is the fastest reasonable preview.
/// PUBLIC API FROZEN — implementation owned by speech agent.
///
/// `DictationTranscriber` (not `SpeechTranscriber`) was chosen after an empirical A/B against a
/// live 4 s clip: `SpeechTranscriber` (with `.volatileResults`, with and without `.fastResults`)
/// produced **zero** results — not even a final one — for that short utterance, while
/// `DictationTranscriber` (`.volatileResults` + `.frequentFinalization`) produced a volatile
/// result at ~1.6 s and a correct final at audio end. `DictationTranscriber.supportedLocales`
/// (43) is also a strict superset of `SpeechTranscriber.supportedLocales` (30, confirmed live).
/// See the final report for the full comparison.
public struct SpeechAnalyzerEngine: TranscriptionEngine {
    /// Preferred locale; used when no usable hint is found in `TranscriptionOptions.languageHints`.
    public let locale: Locale

    private static let logger = Logger(subsystem: "app.prosio.mac", category: "speech")

    /// Source PCM format for everything this engine receives, per contract.
    private static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AudioFormat.pcm16Mono16k.sampleRate,
        channels: 1,
        interleaved: true
    )!

    public init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
    }

    public var id: String { "apple.speechanalyzer" }
    public var isOnDevice: Bool { true }

    /// Whether assets for `locale` are installed / installable.
    public static func isAvailable(for locale: Locale) async -> Bool {
        guard let resolved = await resolveLocale(languageHints: [], fallback: locale) else { return false }
        let transcriber = DictationTranscriber(locale: resolved, preset: .shortDictation)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed, .supported, .downloading:
            return true
        case .unsupported:
            return false
        @unknown default:
            return false
        }
    }

    /// Downloads/installs the on-device assets for `locale` (mapped through the same
    /// hint-resolution as `transcribe`) if needed, and pre-warms a ready-to-use analyzer for it
    /// so the next `transcribe` call's first volatile result arrives fast. Additive API — call
    /// once at app launch (and again if the user changes their preferred language).
    public static func prepareAssets(for locale: Locale) async throws {
        guard let resolved = await resolveLocale(languageHints: [], fallback: locale) else {
            throw ProsioError.engineUnavailable("no supported DictationTranscriber locale for \(locale.identifier(.bcp47))")
        }
        let transcriber = DictationTranscriber(locale: resolved, preset: .shortDictation)
        try await ensureAssetsInstalled(modules: [transcriber])
        await PreparedAnalyzerCache.shared.prewarm(locale: resolved)
    }

    public func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(audio: audio, options: options, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProsioError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Flow

    private func run(
        audio: AsyncStream<AudioChunk>,
        options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        let clock = ContinuousClock()
        let t0 = clock.now

        guard let resolvedLocale = await Self.resolveLocale(languageHints: options.languageHints, fallback: locale) else {
            throw ProsioError.engineUnavailable("no supported DictationTranscriber locale for hints \(options.languageHints) / \(locale.identifier(.bcp47))")
        }
        let tLocaleResolved = clock.now

        // A prepared analyzer (assets installed, `prepareToAnalyze` already done) if one was
        // pre-warmed via `prepareAssets(for:)` or a prior session's background prewarm; otherwise
        // built fresh here (same cost as before, just not overlapped with anything).
        let prepared = try await PreparedAnalyzerCache.shared.checkout(locale: resolvedLocale)
        let analyzer = prepared.analyzer
        let transcriber = prepared.transcriber
        let analyzerFormat = prepared.format
        let tCheckedOut = clock.now

        // Biases recognition toward the user's personal dictionary (e.g. "Prosio", "PR") via
        // `AnalysisContext.contextualStrings` — the only documented tag is `.general`. This plus
        // `.etiquetteReplacements` above are the two-pronged fix for a live bug where the zh-CN
        // preview phonetically mangled "PR" into a vulgar Chinese phrase: biasing makes the
        // correct term more likely to win, and etiquette replacements masks it if it doesn't.
        // Best-effort: a failure to set context should degrade to no bias, not break the preview.
        if !options.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = options.vocabulary
            try? await analyzer.setContext(context)
        }

        guard let converter = AVAudioConverter(from: Self.sourceFormat, to: analyzerFormat) else {
            throw ProsioError.engineUnavailable("failed to construct audio converter for SpeechAnalyzer")
        }

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)

        let tReady = clock.now
        Self.logger.notice(
            "transcribe(): localeResolve=\(Self.ms(t0, tLocaleResolved), privacy: .public)ms checkout=\(Self.ms(tLocaleResolved, tCheckedOut), privacy: .public)ms readyToAcceptAudio total=\(Self.ms(t0, tReady), privacy: .public)ms"
        )

        // `audio` is an `AsyncStream` (default `.unbounded` buffering): any chunks the caller
        // yielded before this loop starts iterating are queued, not dropped, so the setup time
        // logged above costs latency (later first partial) but never loses audio.
        let feedTask = Task<Void, Never> {
            for await chunk in audio {
                if Task.isCancelled { break }
                if let buffer = Self.makePCMBuffer(from: chunk, targetFormat: analyzerFormat, converter: converter) {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
            inputContinuation.finish()
        }
        defer { feedTask.cancel() }

        // An actor, not local `var`s, holds the running finalized/volatile text: the three
        // child tasks below (feeder-driven finalize, input pump, results consumer) all run
        // concurrently, and only the results consumer touches this state, but Swift 6's
        // `sending`-closure check can't see that from a plain captured `var`.
        let accumulator = TranscriptAccumulator()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await analyzer.start(inputSequence: inputSequence)
            }
            group.addTask {
                // Once our own audio feed is exhausted, tell the analyzer to flush any
                // remaining volatile results into final ones and end the `results` sequence.
                await feedTask.value
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            group.addTask {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let combined = result.isFinal
                        ? await accumulator.applyFinal(text)
                        : await accumulator.applyVolatile(text)
                    continuation.yield(.partial(Self.redactProfanity(combined)))
                }
            }
            try await group.waitForAll()
        }

        let finalText = await accumulator.combined
        guard !finalText.isEmpty else { throw ProsioError.emptyTranscript }
        continuation.yield(.final(Self.redactProfanity(finalText)))
    }

    // MARK: - Preview profanity backstop

    /// Small, explicit backstop redaction for the live preview. `.etiquetteReplacements` (enabled
    /// in `buildPrepared`) is the primary defense and does activate — confirmed live, a volatile
    /// result briefly rendered "****" — but was observed to be inconsistent across later
    /// revisions of the same still-volatile segment (a later partial re-guessed the word without
    /// the replacement re-applying, live-reproduced with "PR" -> a vulgar Chinese phrase in the
    /// zh-CN preview). Since the preview must never show an offensive word even transiently, this
    /// is a last-resort net, not a general-purpose profanity filter — extend the list if more
    /// live cases turn up.
    static let previewProfanityBlocklist = ["屁眼儿", "屁眼"]

    static func redactProfanity(_ text: String) -> String {
        guard !previewProfanityBlocklist.isEmpty else { return text }
        var result = text
        for term in previewProfanityBlocklist where !term.isEmpty {
            result = result.replacingOccurrences(of: term, with: String(repeating: "*", count: term.count))
        }
        return result
    }

    // MARK: - Locale resolution

    /// Resolution order: the first `languageHints` entry `DictationTranscriber` supports (`zh` /
    /// `zh-Hans*` are normalized to `zh-CN` first), else `fallback` (the engine's init locale),
    /// else `en-US`. Each candidate is tried both as an exact supported-locale match and via
    /// `DictationTranscriber.supportedLocale(equivalentTo:)` (handles e.g. `zh-Hans` -> `zh-CN`
    /// even without the manual normalization, confirmed live — the manual step just covers bare
    /// `"zh"`, which `equivalentTo` does not reliably resolve).
    private static func resolveLocale(languageHints: [String], fallback: Locale) async -> Locale? {
        let supported = await DictationTranscriber.supportedLocales
        var candidates = languageHints.map(normalizedCandidate(for:))
        candidates.append(fallback)
        candidates.append(Locale(identifier: "en-US"))

        for candidate in candidates {
            if let resolved = await resolveSingle(candidate, supported: supported) {
                return resolved
            }
        }
        return nil
    }

    private static func normalizedCandidate(for identifier: String) -> Locale {
        let lower = identifier.lowercased()
        if lower == "zh" || lower.hasPrefix("zh-hans") {
            return Locale(identifier: "zh-CN")
        }
        return Locale(identifier: identifier)
    }

    private static func resolveSingle(_ candidate: Locale, supported: [Locale]) async -> Locale? {
        if supported.contains(where: { sameLocale($0, candidate) }) { return candidate }
        if let equivalent = await DictationTranscriber.supportedLocale(equivalentTo: candidate) { return equivalent }
        return nil
    }

    private static func sameLocale(_ a: Locale, _ b: Locale) -> Bool {
        a.identifier(.bcp47).caseInsensitiveCompare(b.identifier(.bcp47)) == .orderedSame
    }

    // MARK: - Asset installation

    fileprivate static func ensureAssetsInstalled(modules: [any SpeechModule]) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
            do {
                try await request.downloadAndInstall()
            } catch {
                throw ProsioError.engineUnavailable("failed to install SpeechAnalyzer assets: \(String(describing: error))")
            }
        case .unsupported:
            throw ProsioError.engineUnavailable("locale not supported by DictationTranscriber")
        @unknown default:
            throw ProsioError.engineUnavailable("unknown SpeechAnalyzer asset status")
        }
    }

    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
        Int((end - start) / .milliseconds(1))
    }

    // MARK: - Audio conversion

    /// Converts one contract-format (16 kHz Int16 mono) chunk into an `AVAudioPCMBuffer` in
    /// `targetFormat` (whatever `SpeechAnalyzer.bestAvailableAudioFormat` reports — typically not
    /// Int16, so a real conversion, not just a reinterpret, is required).
    private static func makePCMBuffer(
        from chunk: AudioChunk,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let samples = int16SamplesFromLittleEndianData(chunk.pcm16)
        guard !samples.isEmpty else { return nil }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let sourceChannelData = sourceBuffer.int16ChannelData else { return nil }
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            sourceChannelData[0].update(from: base, count: samples.count)
        }

        let capacityEstimate = Int((Double(samples.count) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(max(1, capacityEstimate))) else {
            return nil
        }

        // See the equivalent comment in `GatewayTranscriptionEngine`/`AudioCapture`: this block
        // is called synchronously within `convert(to:error:withInputFrom:)`, so boxing non-Sendable
        // captures is a strict-concurrency formality, not a real data race.
        let suppliedBox = UncheckedBox(false)
        let sourceBox = UncheckedBox(sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedBox.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedBox.value = true
            inputStatus.pointee = .haveData
            return sourceBox.value
        }

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }
}

/// See `WebSocketConnection.swift` / `AudioCapture.swift` for the identical pattern elsewhere.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Running finalized/volatile transcript text, accumulated across `DictationTranscriber.Result`s.
/// See `TranscriptEvent.partial`'s contract: cumulative, not a delta.
actor TranscriptAccumulator {
    private var finalizedText = ""
    private var volatileText = ""

    /// Appends a finalized segment (no longer subject to revision) and clears the current
    /// volatile text (a fresh volatile result covering the next range will replace it).
    func applyFinal(_ text: String) -> String {
        finalizedText = Self.joinCollapsingDuplicateTerminalPunctuation(finalizedText, text)
        volatileText = ""
        return combined
    }

    /// Replaces the current volatile (interim, revisable) text.
    func applyVolatile(_ text: String) -> String {
        volatileText = text
        return combined
    }

    var combined: String { Self.joinCollapsingDuplicateTerminalPunctuation(finalizedText, volatileText) }

    /// Sentence-final punctuation, CJK and Latin. Segment boundaries from `DictationTranscriber`
    /// can each carry their own trailing/leading terminal mark (e.g. one segment ends "...怎么样？"
    /// and the next starts "？Is cloud..."), which plain concatenation renders as a doubled mark
    /// ("怎么样？？"). Collapses a run of *identical* adjacent terminal marks at the join into one;
    /// does not touch punctuation that isn't duplicated at the boundary (so a genuine "?!" written
    /// within a single segment, or two different marks meeting at a join, are left alone).
    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？"]

    private static func joinCollapsingDuplicateTerminalPunctuation(_ a: String, _ b: String) -> String {
        guard !a.isEmpty, !b.isEmpty else { return a + b }
        guard let lastA = a.last, terminalPunctuation.contains(lastA) else { return a + b }
        var bTail = Substring(b)
        while let firstB = bTail.first, firstB == lastA {
            bTail.removeFirst()
        }
        return a + bTail
    }
}

/// Caches a ready-to-use (assets installed, `prepareToAnalyze` already awaited) analyzer +
/// transcriber pair per resolved locale, so a session can start transcribing without paying that
/// setup cost on the critical path.
///
/// Each `SpeechAnalyzer`/`DictationTranscriber` pair is used for exactly one dictation session
/// (checked out once, never returned to the cache) — reusing the same instance across two live
/// sessions is not something the SDK surface documents as supported (`results` is a one-shot
/// `AsyncSequence` that ends when `finalizeAndFinishThroughEndOfInput` completes), so this cache
/// gets the prewarm latency win by always preparing the *next* instance in the background instead
/// of gambling on restarting a finished one.
actor PreparedAnalyzerCache {
    static let shared = PreparedAnalyzerCache()

    struct Prepared: Sendable {
        let analyzer: SpeechAnalyzer
        let transcriber: DictationTranscriber
        let format: AVAudioFormat
    }

    private var cache: [String: Prepared] = [:]
    private var preparingTasks: [String: Task<Void, Never>] = [:]

    /// Returns a ready pair for `locale`, using a pre-warmed one if available (and kicking off
    /// preparing the next one in the background either way).
    ///
    /// If a prewarm for this locale is still in flight (e.g. `prepareAssets(for:)` was called at
    /// app launch and the user starts dictating before it finished), this **awaits it** instead
    /// of racing ahead with a redundant fresh build — without this, a first session that starts
    /// shortly after launch would silently fall through to the slow path even though a prewarm
    /// was already requested, defeating the whole point of calling `prepareAssets` early.
    func checkout(locale: Locale) async throws -> Prepared {
        let key = locale.identifier(.bcp47)

        if let inFlight = preparingTasks[key] {
            await inFlight.value
        }

        if let existing = cache.removeValue(forKey: key) {
            prepareInBackground(locale: locale, key: key)
            return existing
        }
        let fresh = try await Self.buildPrepared(locale: locale)
        prepareInBackground(locale: locale, key: key)
        return fresh
    }

    /// Ensures a ready pair for `locale` is cached (or already being prepared) for the next
    /// `checkout`. Safe to call any time; a cheap no-op if one is already cached/in flight.
    func prewarm(locale: Locale) {
        prepareInBackground(locale: locale, key: locale.identifier(.bcp47))
    }

    private func prepareInBackground(locale: Locale, key: String) {
        guard cache[key] == nil, preparingTasks[key] == nil else { return }
        preparingTasks[key] = Task {
            if let prepared = try? await Self.buildPrepared(locale: locale) {
                await self.store(prepared, forKey: key)
            }
            await self.clearPreparing(forKey: key)
        }
    }

    private func store(_ prepared: Prepared, forKey key: String) {
        cache[key] = prepared
    }

    private func clearPreparing(forKey key: String) {
        preparingTasks[key] = nil
    }

    private static func buildPrepared(locale: Locale) async throws -> Prepared {
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm],
            // `.etiquetteReplacements` masks profanity in the preview — a live run rendered "PR"
            // as a vulgar Chinese phrase in the zh-CN preview HUD; the final text (cloud) was
            // fine, but the on-device preview must never show offensive words on its own.
            transcriptionOptions: [.punctuation, .etiquetteReplacements],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )
        try await SpeechAnalyzerEngine.ensureAssetsInstalled(modules: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProsioError.engineUnavailable("no compatible audio format for DictationTranscriber")
        }
        try await analyzer.prepareToAnalyze(in: format)
        return Prepared(analyzer: analyzer, transcriber: transcriber, format: format)
    }
}
