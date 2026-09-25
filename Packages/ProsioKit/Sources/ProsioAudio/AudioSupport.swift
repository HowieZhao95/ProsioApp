import Foundation

// Pure, side-effect-free helpers factored out of `AudioCapture` so they can be unit tested in
// isolation from AVAudioEngine. Kept internal: no public contract depends on these shapes.
//
// NOTE for the architect: these are currently untestable from `Tests/ProsioTranscriptionTests`
// because that test target does not depend on the `ProsioAudio` product (see Package.swift,
// which is frozen / architect-owned). See the speech agent's final report, "Contract change
// request", for the one-line dependency addition that would unblock this.

/// Converts PCM16 samples to little-endian `Data`, explicitly (not relying on host endianness).
func int16SamplesToLittleEndianData(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let unsigned = UInt16(bitPattern: sample)
        data.append(UInt8(truncatingIfNeeded: unsigned))
        data.append(UInt8(truncatingIfNeeded: unsigned >> 8))
    }
    return data
}

/// Normalized RMS (0...1, where 1 == full-scale Int16) for a block of PCM16 samples.
func rms(ofInt16Samples samples: [Int16]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sumSquares: Double = 0
    for sample in samples {
        let normalized = Double(sample) / Double(Int16.max)
        sumSquares += normalized * normalized
    }
    return Float(sqrt(sumSquares / Double(samples.count)))
}

/// Maps a normalized RMS value to a 0...1 metering level using a -55...0 dBFS window, clamped.
/// `rms <= 0` (silence) maps to `0` rather than `-infinity` dB.
func meteringLevel(forRMS rmsValue: Float, minDB: Float = -55, maxDB: Float = 0) -> Float {
    guard rmsValue > 0 else { return 0 }
    let db = 20 * log10(rmsValue)
    let clamped = min(max(db, minDB), maxDB)
    guard maxDB > minDB else { return 0 }
    return (clamped - minDB) / (maxDB - minDB)
}

/// Convenience: RMS-based metering level directly from PCM16 samples.
func meteringLevel(forInt16Samples samples: [Int16]) -> Float {
    meteringLevel(forRMS: rms(ofInt16Samples: samples))
}

/// Accumulates converted Int16 mono samples into fixed-size chunks (default ~50 ms @ 16 kHz),
/// producing `(samples, timestamp)` pairs. Timestamps are derived from the sample count already
/// emitted (not wall-clock), so they are deterministic and drift-free relative to the audio
/// itself.
struct PCMChunkAccumulator {
    let chunkSampleCount: Int
    let sampleRate: Double

    private var buffer: [Int16] = []
    private var emittedSampleCount: Int = 0

    init(chunkSampleCount: Int = 800, sampleRate: Double = 16_000) {
        precondition(chunkSampleCount > 0)
        self.chunkSampleCount = chunkSampleCount
        self.sampleRate = sampleRate
    }

    /// Appends new samples and returns zero or more complete chunks.
    mutating func append(_ samples: [Int16]) -> [(samples: [Int16], timestamp: TimeInterval)] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)

        var results: [(samples: [Int16], timestamp: TimeInterval)] = []
        while buffer.count >= chunkSampleCount {
            let slice = Array(buffer.prefix(chunkSampleCount))
            buffer.removeFirst(chunkSampleCount)
            let timestamp = Double(emittedSampleCount) / sampleRate
            emittedSampleCount += chunkSampleCount
            results.append((slice, timestamp))
        }
        return results
    }

    /// Flushes any partial trailing chunk (called on `stop()`).
    mutating func flush() -> (samples: [Int16], timestamp: TimeInterval)? {
        guard !buffer.isEmpty else { return nil }
        let slice = buffer
        buffer.removeAll()
        let timestamp = Double(emittedSampleCount) / sampleRate
        emittedSampleCount += slice.count
        return (slice, timestamp)
    }

    mutating func reset() {
        buffer.removeAll()
        emittedSampleCount = 0
    }
}

/// Trivial reference box used to smuggle non-Sendable values (e.g. `AVAudioPCMBuffer`) through
/// an `@Sendable`-annotated ObjC callback that is actually invoked synchronously on the calling
/// thread. Not a general-purpose concurrency primitive — only use where the synchronous-call
/// invariant is independently guaranteed by the API contract.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Computes the output frame capacity needed to hold a full conversion of `inputFrames` samples
/// from `inputRate` to `outputRate`, with a small safety margin for rounding.
func convertedFrameCapacity(inputFrames: Int, inputRate: Double, outputRate: Double) -> Int {
    guard inputRate > 0 else { return inputFrames }
    let ratio = outputRate / inputRate
    return Int((Double(inputFrames) * ratio).rounded(.up)) + 16
}
