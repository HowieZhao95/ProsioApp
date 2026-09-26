import Foundation

/// Pure, deterministic silence trimmer for 16 kHz mono PCM16 audio.
/// PUBLIC API — owned by the speech agent. See docs/P1.2-AUDIO-ROUTING.md §2.
///
/// Algorithm: energy VAD on 20 ms frames with an adaptive noise floor (10th-percentile frame RMS,
/// floored at -60 dBFS), a speech threshold of floor + ~9 dB, and hangover to avoid choppy
/// on/off decisions. Leading/trailing silence beyond 250 ms is dropped; internal silences longer
/// than 700 ms are shortened to 300 ms (150 ms kept on each side of the surrounding speech, which
/// also satisfies the "keep ±150 ms around every speech run" rule). Speech itself is never cut.
///
/// Safety: if trimming would remove more than 70% of the audio, or total detected speech is under
/// 300 ms, the input is returned unchanged (still reported via `Stats`).
public enum SilenceTrimmer {

    public struct Stats: Sendable, Equatable, Hashable {
        public let originalSeconds: Double
        public let trimmedSeconds: Double
        public let speechSegments: Int

        public init(originalSeconds: Double, trimmedSeconds: Double, speechSegments: Int) {
            self.originalSeconds = originalSeconds
            self.trimmedSeconds = trimmedSeconds
            self.speechSegments = speechSegments
        }
    }

    public struct Result: Sendable {
        public let samples: [Int16]
        public let stats: Stats

        public init(samples: [Int16], stats: Stats) {
            self.samples = samples
            self.stats = stats
        }
    }

    // MARK: - Tunables (see docs/P1.2-AUDIO-ROUTING.md §2)

    private static let frameSeconds: Double = 0.02
    private static let noiseFloorPercentile: Double = 0.10
    private static let noiseFloorMinDB: Float = -60
    private static let speechThresholdOffsetDB: Float = 9
    /// Hangover after a speech frame ends, to avoid choppy VAD flicker at the edge of a word.
    private static let hangoverSeconds: Double = 0.2
    private static let leadingTrailingPadSeconds: Double = 0.25
    private static let internalPadSeconds: Double = 0.15
    private static let internalGapShortenThresholdSeconds: Double = 0.7
    private static let maxRemovedFraction: Double = 0.7
    private static let minSpeechSecondsToTrim: Double = 0.3

    /// Trims silence from `samples` (mono PCM16 at `sampleRate`, default 16 kHz).
    public static func trim(_ samples: [Int16], sampleRate: Double = 16_000) -> Result {
        let originalSeconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        let unchanged = Result(samples: samples, stats: Stats(originalSeconds: originalSeconds, trimmedSeconds: originalSeconds, speechSegments: 0))

        let frameSize = max(1, Int((sampleRate * frameSeconds).rounded()))
        guard sampleRate > 0, samples.count >= frameSize else { return unchanged }

        let frameRanges = makeFrameRanges(count: samples.count, frameSize: frameSize)
        guard !frameRanges.isEmpty else { return unchanged }

        let frameDb: [Float] = frameRanges.map { range in
            dBFS(rms(ofInt16Samples: Array(samples[range])))
        }

        let sortedDb = frameDb.sorted()
        let percentileIndex = max(0, min(sortedDb.count - 1, Int((Double(sortedDb.count - 1) * noiseFloorPercentile).rounded())))
        let percentile10 = sortedDb.isEmpty ? noiseFloorMinDB : sortedDb[percentileIndex]
        let noiseFloor = max(percentile10, noiseFloorMinDB)
        let threshold = noiseFloor + speechThresholdOffsetDB

        var isSpeech = frameDb.map { $0 > threshold }

        // Hangover: keep frames flagged as speech for a while after energy drops back down.
        let hangoverFrames = max(0, Int((hangoverSeconds / frameSeconds).rounded()))
        var hangCounter = 0
        for i in 0..<isSpeech.count {
            if isSpeech[i] {
                hangCounter = hangoverFrames
            } else if hangCounter > 0 {
                isSpeech[i] = true
                hangCounter -= 1
            }
        }

        // Collapse speech frames into sample-index segments.
        var segments: [(start: Int, end: Int)] = []
        var currentStart: Int?
        for i in 0..<isSpeech.count {
            if isSpeech[i] {
                if currentStart == nil { currentStart = frameRanges[i].lowerBound }
            } else if let start = currentStart {
                segments.append((start, frameRanges[i - 1].upperBound))
                currentStart = nil
            }
        }
        if let start = currentStart {
            segments.append((start, samples.count))
        }

        guard !segments.isEmpty else { return unchanged }

        let totalSpeechSeconds = segments.reduce(0.0) { $0 + Double($1.end - $1.start) / sampleRate }
        guard totalSpeechSeconds >= minSpeechSecondsToTrim else {
            return Result(samples: samples, stats: Stats(originalSeconds: originalSeconds, trimmedSeconds: originalSeconds, speechSegments: segments.count))
        }

        let leadTrailPad = Int((leadingTrailingPadSeconds * sampleRate).rounded())
        let internalPad = Int((internalPadSeconds * sampleRate).rounded())
        let internalGapThreshold = Int((internalGapShortenThresholdSeconds * sampleRate).rounded())

        var keepRanges: [(start: Int, end: Int)] = []
        var keepStart = max(0, segments[0].start - leadTrailPad)
        var keepEnd = segments[0].end

        for i in 1..<segments.count {
            let gap = segments[i].start - segments[i - 1].end
            if gap <= internalGapThreshold {
                // Short enough to keep in full.
                keepEnd = segments[i].end
            } else {
                let closeEnd = min(samples.count, segments[i - 1].end + internalPad)
                keepRanges.append((keepStart, closeEnd))
                keepStart = max(0, segments[i].start - internalPad)
                keepEnd = segments[i].end
            }
        }
        keepEnd = min(samples.count, keepEnd + leadTrailPad)
        keepRanges.append((keepStart, keepEnd))

        var output: [Int16] = []
        output.reserveCapacity(samples.count)
        for range in keepRanges where range.end > range.start {
            output.append(contentsOf: samples[range.start..<range.end])
        }

        let trimmedSeconds = Double(output.count) / sampleRate
        let removedFraction = originalSeconds > 0 ? 1 - (trimmedSeconds / originalSeconds) : 0
        guard removedFraction <= maxRemovedFraction else {
            return Result(samples: samples, stats: Stats(originalSeconds: originalSeconds, trimmedSeconds: originalSeconds, speechSegments: segments.count))
        }

        return Result(samples: output, stats: Stats(originalSeconds: originalSeconds, trimmedSeconds: trimmedSeconds, speechSegments: segments.count))
    }

    /// `Data`-based convenience: little-endian PCM16 mono in, little-endian PCM16 mono out.
    public static func trim(_ data: Data, sampleRate: Double = 16_000) -> (data: Data, stats: Stats) {
        let samples = int16Samples(fromLittleEndianData: data)
        let result = trim(samples, sampleRate: sampleRate)
        return (int16SamplesToLittleEndianData(result.samples), result.stats)
    }

    // MARK: - Helpers

    private static func makeFrameRanges(count: Int, frameSize: Int) -> [Range<Int>] {
        guard count > 0, frameSize > 0 else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(start + frameSize, count)
            // Absorb a too-small trailing remainder into the final frame instead of leaving a tiny one.
            if count - end < frameSize && end < count {
                ranges.append(start..<count)
                break
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private static func dBFS(_ rmsValue: Float) -> Float {
        guard rmsValue > 0 else { return -120 }
        return 20 * log10(rmsValue)
    }
}
