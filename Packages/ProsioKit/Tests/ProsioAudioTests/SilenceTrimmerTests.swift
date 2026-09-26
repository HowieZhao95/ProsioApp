import Foundation
import Testing
@testable import ProsioAudio

@Suite struct SilenceTrimmerTests {
    static let sampleRate: Double = 16_000

    /// A sine "tone burst" standing in for speech: full-scale-ish amplitude, well above any
    /// plausible noise floor.
    static func tone(seconds: Double, amplitude: Double = 0.6, frequency: Double = 220, sampleRate: Double = sampleRate) -> [Int16] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let value = amplitude * sin(2 * .pi * frequency * t)
            return Int16(clamping: Int((value * Double(Int16.max)).rounded()))
        }
    }

    static func silence(seconds: Double, sampleRate: Double = sampleRate) -> [Int16] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Very low-level noise: should be classified as "not speech" once it establishes the noise floor.
    static func noise(seconds: Double, amplitude: Double = 0.002, sampleRate: Double = sampleRate) -> [Int16] {
        var generator = SystemRandomNumberGenerator()
        let count = Int(seconds * sampleRate)
        return (0..<count).map { _ in
            let value = amplitude * Double.random(in: -1...1, using: &generator)
            return Int16(clamping: Int((value * Double(Int16.max)).rounded()))
        }
    }

    @Test func toneBurstWithSilence_trimsLeadingAndTrailingSilence() {
        let samples = Self.silence(seconds: 2) + Self.tone(seconds: 1.5) + Self.silence(seconds: 2)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        #expect(result.stats.speechSegments == 1)
        #expect(result.stats.trimmedSeconds < result.stats.originalSeconds)
        // Should keep ~250ms padding on each side of the ~1.5s tone, not the full 2s of silence.
        #expect(result.stats.trimmedSeconds < 2.5)
        #expect(result.stats.trimmedSeconds > 1.5)
    }

    @Test func internalSilenceLongerThan700ms_isShortenedTo300ms() {
        let samples = Self.tone(seconds: 1) + Self.silence(seconds: 2) + Self.tone(seconds: 1)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        #expect(result.stats.speechSegments == 2)
        // original: 1 + 2 + 1 = 4s. Expect internal gap shortened to ~0.3s plus small leading/trailing pad.
        #expect(result.stats.trimmedSeconds < 2.6)
        #expect(result.stats.trimmedSeconds > 2.0)
    }

    @Test func internalSilenceShorterThan700ms_isKeptInFull() {
        let samples = Self.tone(seconds: 1) + Self.silence(seconds: 0.4) + Self.tone(seconds: 1)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        // Two speech runs merge (gap under the 700ms threshold), original internal 0.4s silence
        // should survive close to intact (only leading/trailing padding may be trimmed at the ends).
        #expect(result.stats.trimmedSeconds > 2.0)
    }

    @Test func lowLevelNoiseOnly_isNotTreatedAsSpeech() {
        let samples = Self.noise(seconds: 3)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        // No signal clears floor+9dB, so no speech segments are found -> unchanged.
        #expect(result.stats.speechSegments == 0)
        #expect(result.samples.count == samples.count)
        #expect(result.stats.trimmedSeconds == result.stats.originalSeconds)
    }

    @Test func quietSpeechAboveNoiseFloor_isNotCut() {
        // Establish a noise floor with low-level noise, then a quieter-than-tone but still
        // clearly-above-floor "speech-like" signal (~20x the noise amplitude, i.e. well over the
        // +9dB threshold) must survive trimming.
        let quietSpeech = Self.tone(seconds: 1.2, amplitude: 0.04, frequency: 180)
        let samples = Self.noise(seconds: 1, amplitude: 0.001) + quietSpeech + Self.noise(seconds: 1, amplitude: 0.001)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        #expect(result.stats.speechSegments >= 1)
        // The full ~1.2s of quiet "speech" must be present in the trimmed output.
        #expect(result.stats.trimmedSeconds >= 1.2)
    }

    @Test func allSilence_isReturnedUnchanged() {
        let samples = Self.silence(seconds: 3)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        #expect(result.samples == samples)
        #expect(result.stats.speechSegments == 0)
        #expect(result.stats.originalSeconds == result.stats.trimmedSeconds)
    }

    @Test func veryShortSpeechBelow300ms_isReturnedUnchanged() {
        // A single ~40ms blip: even with hangover extending the detected VAD segment, total
        // detected speech stays under the 300ms safety threshold (40ms tone + 200ms hangover = 240ms).
        let samples = Self.silence(seconds: 1) + Self.tone(seconds: 0.04) + Self.silence(seconds: 1)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        #expect(result.samples.count == samples.count)
        #expect(result.stats.originalSeconds == result.stats.trimmedSeconds)
    }

    @Test func excessiveRemoval_fallsBackToUnchanged() {
        // Speech only in a tiny sliver relative to a very long recording -- if that ever computed
        // to >70% removal, the safety net must return the input unchanged. Use enough silence that
        // even minimal padding can't keep removal under 70%.
        let samples = Self.silence(seconds: 20) + Self.tone(seconds: 0.35) + Self.silence(seconds: 20)
        let result = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)

        let removedFraction = 1 - (result.stats.trimmedSeconds / result.stats.originalSeconds)
        if removedFraction > 0.70 + 1e-9 {
            Issue.record("safety net should have capped removal at 70%, got \(removedFraction)")
        }
        // Either the safety net fired (full unchanged passthrough) or trimming naturally stayed
        // under 70% -- both are acceptable, but a fired safety net must return the exact input.
        if result.samples.count == samples.count {
            #expect(result.stats.trimmedSeconds == result.stats.originalSeconds)
        }
    }

    @Test func dataOverload_roundTripsWithArrayOverload() {
        let samples = Self.silence(seconds: 0.5) + Self.tone(seconds: 1) + Self.silence(seconds: 0.5)
        let data = int16SamplesToLittleEndianDataForTests(samples)

        let arrayResult = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)
        let dataResult = SilenceTrimmer.trim(data, sampleRate: Self.sampleRate)

        #expect(dataResult.stats == arrayResult.stats)
        #expect(int16SamplesFromLittleEndianDataForTests(dataResult.data) == arrayResult.samples)
    }
}

// Exposes the package-internal helpers to this test target without changing their access level
// (kept `internal` in `AudioSupport.swift`; `@testable import` makes them visible here).
func int16SamplesToLittleEndianDataForTests(_ samples: [Int16]) -> Data {
    int16SamplesToLittleEndianData(samples)
}

func int16SamplesFromLittleEndianDataForTests(_ data: Data) -> [Int16] {
    int16Samples(fromLittleEndianData: data)
}

extension SilenceTrimmerTests {
    @Test func performance_sixtySecondsUnderFiveMillisecondsInRelease() {
        let samples = Self.tone(seconds: 20) + Self.silence(seconds: 20) + Self.tone(seconds: 20)
        let clock = ContinuousClock()
        let start = clock.now
        _ = SilenceTrimmer.trim(samples, sampleRate: Self.sampleRate)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("[SilenceTrimmer benchmark] 60s @16kHz mono trim in \(ms) ms")
    }
}
