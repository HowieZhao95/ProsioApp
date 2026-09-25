import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Live end-to-end test for the on-device live-preview engine. Skipped unless PROSIO_LIVE_WAV is
/// set. No backend/network involved — this only exercises Apple's on-device Speech framework.
///
///   PROSIO_LIVE_WAV=/path/to/16k-mono-pcm16.wav swift test --filter LiveSpeechAnalyzerTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_LIVE_WAV"] != nil))
struct LiveSpeechAnalyzerTests {
    @Test func streamsWavThroughSpeechAnalyzer() async throws {
        let env = ProcessInfo.processInfo.environment
        let wavURL = URL(fileURLWithPath: env["PROSIO_LIVE_WAV"]!)
        let pcm = try Self.pcmData(fromWAV: Data(contentsOf: wavURL))

        let localeHint = env["PROSIO_LIVE_LOCALE"] ?? "en-US"
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
        var firstPartial: Int?
        var partialCount = 0
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions(mode: .smart, languageHints: [localeHint])) {
            switch event {
            case .partial(let text):
                firstPartial = firstPartial ?? ms()
                partialCount += 1
                print("LIVE \(ms())ms partial: \(text)")
            case .final(let text):
                print("LIVE \(ms())ms FINAL: \(text)")
                final = text
            }
        }
        await feeder.value
        print("LIVE summary: audio=\(Double(pcm.count) / 32_000)s firstPartial=\(firstPartial ?? -1)ms partials=\(partialCount) finalAfterAudioEnd=\(ms() - audioEnd.get())ms")
        #expect(final?.isEmpty == false)
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
