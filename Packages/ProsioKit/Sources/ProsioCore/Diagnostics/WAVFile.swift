import Foundation

/// Builds a minimal RIFF/WAVE container around raw little-endian PCM16 mono samples. Originally
/// debug-recordings-only; made `public` for P1.2 so `AudioPreparing` conformers outside ProsioCore
/// (e.g. ProsioAudio's real trim+encode implementation) can build the WAV fallback used when Opus
/// encoding fails, without duplicating this format logic.
public enum WAVFile {
    public static func make(pcm16: Data, sampleRate: Double, channelCount: Int = 1) -> Data {
        let bitsPerSample: UInt16 = 16
        let numChannels = UInt16(channelCount)
        let sampleRateInt = UInt32(sampleRate)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sampleRateInt * UInt32(blockAlign)
        let dataSize = UInt32(pcm16.count)
        let riffChunkSize = 36 + dataSize

        var data = Data(capacity: 44 + pcm16.count)
        data.append(ascii: "RIFF")
        data.appendLittleEndian(riffChunkSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.appendLittleEndian(UInt32(16)) // fmt chunk size (PCM)
        data.appendLittleEndian(UInt16(1)) // audio format: PCM
        data.appendLittleEndian(numChannels)
        data.appendLittleEndian(sampleRateInt)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(ascii: "data")
        data.appendLittleEndian(dataSize)
        data.append(pcm16)
        return data
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
