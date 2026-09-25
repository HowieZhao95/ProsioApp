import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Live end-to-end test for the on-device live-preview engine. Skipped unless PROSIO_LIVE_WAV is
/// set. No backend/network involved — this only exercises Apple's on-device Speech framework.
///
///   PROSIO_LIVE_WAV=/path/to/16k-mono-pcm16.wav [PROSIO_LIVE_LOCALE=zh-CN] \
///     [PROSIO_LIVE_VOCAB=Prosio,PR] [PROSIO_LIVE_PREPARE=1] \
///     swift test --filter LiveSpeechAnalyzerTests
///
/// `PROSIO_LIVE_PREPARE=1` calls `SpeechAnalyzerEngine.prepareAssets(for:)` before starting the
/// (single) session in this process, to measure a warm first-session time-to-first-partial. Since
/// this is meant to model a genuinely fresh process (app launch), compare it against a separate
/// `swift test` invocation *without* the flag, rather than two sessions in one process — the
/// latter would benefit from unrelated warm-up (framework/JIT) either way and not isolate the
/// prewarm's actual effect.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_LIVE_WAV"] != nil))
struct LiveSpeechAnalyzerTests {
    @Test func streamsWavThroughSpeechAnalyzer() async throws {
        let env = ProcessInfo.processInfo.environment
        let wavURL = URL(fileURLWithPath: env["PROSIO_LIVE_WAV"]!)
        let localeHint = env["PROSIO_LIVE_LOCALE"] ?? "en-US"
        let vocabulary = env["PROSIO_LIVE_VOCAB"].map { $0.split(separator: ",").map(String.init) } ?? []

        if env["PROSIO_LIVE_PREPARE"] == "1" {
            try await SpeechAnalyzerEngine.prepareAssets(for: Locale(identifier: localeHint))
        }

        let result = try await Self.run(wavURL: wavURL, localeHint: localeHint, vocabulary: vocabulary)
        #expect(result.final?.isEmpty == false)
    }

    struct Result {
        var firstPartial: Int?
        var final: String?
        var lastPartial: String?
        var partialCount: Int
        var audioSeconds: Double
        var finalAfterAudioEndMs: Int
    }

    @discardableResult
    static func run(wavURL: URL, localeHint: String, vocabulary: [String]) async throws -> Result {
        let pcm = try pcmData(fromWAV: Data(contentsOf: wavURL))
        let engine = SpeechAnalyzerEngine(locale: Locale(identifier: "en-US"))
        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> Int { Int((clock.now - start) / .milliseconds(1)) }

        // Real-time paced 50 ms chunks (800 samples @ 16 kHz), like the microphone would deliver.
        let chunkBytes = 800 * 2
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream()
        let audioEnd = LockedValue(0)
        let feeder = Task {
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkBytes, pcm.count)
                continuation.yield(AudioChunk(pcm16: pcm.subdata(in: offset..<end), level: 0.5, timestamp: Double(offset) / 32_000))
                offset = end
                try? await Task.sleep(for: .milliseconds(50))
            }
            audioEnd.set(ms())
            continuation.finish()
        }

        var final: String?
        var lastPartial: String?
        var firstPartial: Int?
        var partialCount = 0
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions(mode: .smart, vocabulary: vocabulary, languageHints: [localeHint])) {
            switch event {
            case .partial(let text):
                firstPartial = firstPartial ?? ms()
                partialCount += 1
                lastPartial = text
                print("LIVE \(ms())ms partial: \(text)")
            case .final(let text):
                print("LIVE \(ms())ms FINAL: \(text)")
                final = text
            }
        }
        await feeder.value
        let finalAfterAudioEndMs = ms() - audioEnd.get()
        print("LIVE summary: audio=\(Double(pcm.count) / 32_000)s firstPartial=\(firstPartial ?? -1)ms partials=\(partialCount) finalAfterAudioEnd=\(finalAfterAudioEndMs)ms")
        return Result(
            firstPartial: firstPartial,
            final: final,
            lastPartial: lastPartial,
            partialCount: partialCount,
            audioSeconds: Double(pcm.count) / 32_000,
            finalAfterAudioEndMs: finalAfterAudioEndMs
        )
    }

    /// Returns the payload of the WAV `data` chunk.
    static func pcmData(fromWAV wav: Data) throws -> Data {
        guard let range = wav.range(of: Data("data".utf8)) else { throw ProsioError.audioUnavailable("no data chunk") }
        return wav.subdata(in: (range.upperBound + 4)..<wav.endIndex)
    }
}

private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}

/// Isolates `PreparedAnalyzerCache.checkout`'s setup cost from `DictationTranscriber`'s own
/// recognition latency (which dominates end-to-end first-partial timing and isn't something
/// `prepareAssets` can affect). Regression guard for the `prepareAssets(for:)` cold-start fix:
/// without it, `checkout` costs ~450-500ms (asset status check + `SpeechAnalyzer` construction +
/// `prepareToAnalyze`); with `prepareAssets` called ahead of time (plus a brief grace period for
/// the background prewarm to land), `checkout` should be ~0ms.
///
///   PROSIO_LIVE_WAV=<any wav, unused> PROSIO_LIVE_LOCALE=zh-CN [PROSIO_LIVE_PREPARE=1] \
///     swift test --filter CheckoutTimingProbe
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_LIVE_WAV"] != nil))
struct CheckoutTimingProbe {
    @Test func measureCheckoutCost() async throws {
        let localeHint = ProcessInfo.processInfo.environment["PROSIO_LIVE_LOCALE"] ?? "en-US"
        let locale = Locale(identifier: localeHint)
        let clock = ContinuousClock()

        if ProcessInfo.processInfo.environment["PROSIO_LIVE_PREPARE"] == "1" {
            let t0 = clock.now
            try await SpeechAnalyzerEngine.prepareAssets(for: locale)
            print("PROBE prepareAssets took \(Int((clock.now - t0) / .milliseconds(1)))ms")
            // Give the background prewarm a moment's head start, like a real app would (launch
            // finishes, user looks around before pressing the hotkey).
            try await Task.sleep(for: .milliseconds(300))
        }

        let t1 = clock.now
        let prepared = try await PreparedAnalyzerCache.shared.checkout(locale: locale)
        let checkoutMs = Int((clock.now - t1) / .milliseconds(1))
        print("PROBE checkout took \(checkoutMs)ms (format=\(prepared.format))")
    }
}
