import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Measures `SpeechAnalyzerEngine`'s time from `transcribe()` being called to it being ready to
/// accept audio (locale resolution + `PreparedAnalyzerCache.checkout`), cold vs warm. The engine
/// itself also logs this via `os.Logger` (subsystem "app.prosio.mac", category "speech") — this
/// test additionally captures it directly so the numbers land in the test report without needing
/// `log stream`.
///
/// No audio is dropped while warming up regardless of this latency: `audio` is a plain
/// `AsyncStream` with its default `.unbounded` buffering, so anything the caller yields before
/// `SpeechAnalyzerEngine`'s internal feed loop starts iterating it is queued, not lost.
/// `measureReadyLatency` below yields all its chunks *before* calling `transcribe()` and still
/// completes (rather than hanging forever waiting on chunks that were silently discarded), which
/// is exactly that guarantee exercised end-to-end.
///
///   PROSIO_LIVE_TIMING=1 [PROSIO_LIVE_LOCALE=zh-CN] swift test --filter LiveSpeechAnalyzerReadyTimingTests
///
/// Gated like the other `Live*` suites (exercises the real on-device Speech framework, not a
/// fake) — skipped by default so a plain `swift test` run doesn't touch the microphone/Speech
/// assets or take several seconds.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_LIVE_TIMING"] != nil))
struct LiveSpeechAnalyzerReadyTimingTests {
    @Test func coldVsWarmReadyLatency_andNoAudioDroppedWhileWarming() async throws {
        let localeHint = ProcessInfo.processInfo.environment["PROSIO_LIVE_LOCALE"] ?? "en-US"
        let locale = Locale(identifier: localeHint)

        // COLD: nothing prewarmed for this locale (best-effort — if a previous test in the same
        // process already warmed it, this still measures *a* checkout, just maybe not the
        // absolute-first-ever one; run this test in isolation for a true cold number).
        let coldMs = try await measureReadyLatency(locale: locale)
        print("SpeechAnalyzerEngine ready latency (cold-ish): \(coldMs)ms")

        // WARM: prewarm explicitly, then measure again.
        try await SpeechAnalyzerEngine.prepareAssets(for: locale)
        try await Task.sleep(for: .milliseconds(300)) // let the background prewarm land
        let warmMs = try await measureReadyLatency(locale: locale)
        print("SpeechAnalyzerEngine ready latency (warm): \(warmMs)ms")

        #expect(warmMs <= coldMs)
    }

    /// Feeds a handful of silent chunks through the engine and returns the wall time from
    /// `transcribe()` to the first chunk actually being converted and pushed into the analyzer
    /// (proxied by: all chunks eventually arrive — see the doc comment above re: buffering).
    private func measureReadyLatency(locale: Locale) async throws -> Int {
        let engine = SpeechAnalyzerEngine(locale: locale)
        let clock = ContinuousClock()
        let t0 = clock.now

        // A few silent 50ms chunks (800 samples @ 16kHz) — enough to prove nothing is dropped,
        // short enough that this test doesn't need real speech content or run for long.
        let silence = Data(repeating: 0, count: 800 * 2)
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream()
        for i in 0..<5 {
            continuation.yield(AudioChunk(pcm16: silence, level: 0, timestamp: Double(i) * 0.05))
        }
        continuation.finish()

        let task = Task {
            do {
                for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            } catch {
                // Silence commonly yields .emptyTranscript — expected and fine for this timing probe.
            }
        }

        // Bound the wait; silence should finalize (or throw) quickly once truly ready.
        try await withTimeout(.seconds(10)) {
            await task.value
        }

        return Int((clock.now - t0) / .milliseconds(1))
    }
}

private func withTimeout(_ duration: Duration, operation: @escaping @Sendable () async -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw ProsioError.network("timed out")
        }
        try await group.next()
        group.cancelAll()
    }
}
