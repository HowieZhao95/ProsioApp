import Foundation

// PCM16LE helpers for local speech analysis and batch audio. Deliberately not shared with `ProsioAudio`
// (wrong dependency direction: ProsioTranscription -> ProsioAudio is not in Package.swift, and
// ProsioAudio must stay independent of the transcription engines) — the duplication is a handful
// of lines and both copies are owned by this agent.

/// Unpacks little-endian PCM16 `Data` into `[Int16]`.
func int16SamplesFromLittleEndianData(_ data: Data) -> [Int16] {
    let count = data.count / 2
    guard count > 0 else { return [] }
    var samples = [Int16](repeating: 0, count: count)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<count {
            let lo = UInt16(raw[i * 2])
            let hi = UInt16(raw[i * 2 + 1])
            samples[i] = Int16(bitPattern: lo | (hi << 8))
        }
    }
    return samples
}

/// Packs `[Int16]` into little-endian PCM16 `Data`, explicitly (not relying on host endianness).
func int16SamplesToLittleEndianData(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let unsigned = UInt16(bitPattern: sample)
        data.append(UInt8(truncatingIfNeeded: unsigned))
        data.append(UInt8(truncatingIfNeeded: unsigned >> 8))
    }
    return data
}
