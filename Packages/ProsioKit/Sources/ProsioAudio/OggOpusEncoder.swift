import AVFoundation
import Foundation
import os

/// Errors specific to Opus encoding. Not part of the frozen `ProsioError` contract — callers that
/// need a uniform error type should map these to `ProsioError.audioUnavailable`/`.transcriptionFailed`
/// (see final report, "uncertain items").
public enum OggOpusEncoderError: Error, Sendable, Equatable {
    case emptyInput
    case converterUnavailable
    case conversionFailed(String)
    case noPacketsProduced
}

/// Encodes 16 kHz mono PCM16 to an Ogg/Opus file, using Apple's Opus encoder
/// (`AVAudioConverter` -> `kAudioFormatOpus`, 20 ms frames, ~20 kbps) and a minimal, hand-rolled
/// RFC 7845 Ogg muxer (`OggOpusMuxer`). PUBLIC API — owned by the speech agent.
/// See docs/P1.2-AUDIO-ROUTING.md §1.
///
/// Throws `OggOpusEncoderError` on failure so callers can fall back to WAV upload, per spec.
public struct OggOpusEncoder: Sendable {
    /// 20 ms frames, per docs/P1.2-AUDIO-ROUTING.md §1.
    public static let frameDurationSeconds: Double = 0.02
    /// ~20 kbps: the sweet spot measured for SMART transcription quality vs. upload size
    /// (docs/P1.2-AUDIO-ROUTING.md's "Measured" table — 16 kbps VoIP was used there; 20 kbps
    /// gives a bit of headroom while staying far below the WAV/FLAC/AAC sizes).
    public static let bitRate: Int = 20_000

    private static let logger = Logger(subsystem: "app.prosio.mac", category: "audio.opus")

    public init() {}

    /// Encodes `samples` (mono PCM16 at `sampleRate`, default 16 kHz) to a complete Ogg/Opus file.
    public func encode(pcm16 samples: [Int16], sampleRate: Double = 16_000) throws -> Data {
        guard !samples.isEmpty else { throw OggOpusEncoderError.emptyInput }
        guard sampleRate > 0 else { throw OggOpusEncoderError.converterUnavailable }

        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw OggOpusEncoderError.converterUnavailable
        }

        let framesPerPacket = UInt32((sampleRate * Self.frameDurationSeconds).rounded())
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &outputDescription) else {
            throw OggOpusEncoderError.converterUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw OggOpusEncoderError.converterUnavailable
        }
        converter.bitRate = Self.bitRate

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw OggOpusEncoderError.converterUnavailable
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = pcmBuffer.int16ChannelData else {
            throw OggOpusEncoderError.converterUnavailable
        }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }

        let maxPacketSize = converter.maximumOutputPacketSize > 0 ? converter.maximumOutputPacketSize : 4_000
        var packets: [Data] = []
        var finished = false

        // `AVAudioConverterInputBlock` is imported as `@Sendable`, but `convert(to:error:withInputFromBlock:)`
        // calls it synchronously on the current thread — box the non-Sendable buffer and the mutable
        // "have we handed over our one input buffer yet" flag to satisfy strict concurrency checking
        // without changing behavior (same pattern as `AudioCapture.handleInputBuffer`).
        let suppliedInputBox = UncheckedBox(false)
        let pcmBufferBox = UncheckedBox(pcmBuffer)

        while !finished {
            let outputBuffer = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: maxPacketSize)

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInputBox.value {
                    inputStatus.pointee = .endOfStream
                    return nil
                } else {
                    suppliedInputBox.value = true
                    inputStatus.pointee = .haveData
                    return pcmBufferBox.value
                }
            }

            if let conversionError {
                throw OggOpusEncoderError.conversionFailed(conversionError.localizedDescription)
            }

            switch status {
            case .haveData:
                let length = Int(outputBuffer.byteLength)
                if length > 0 {
                    packets.append(Data(bytes: outputBuffer.data, count: length))
                }
            case .endOfStream:
                finished = true
            case .inputRanDry:
                // We hand over all of our input on the very first callback; if the converter is
                // still hungry after that, there is nothing more to give it.
                if suppliedInputBox.value { finished = true }
            case .error:
                throw OggOpusEncoderError.conversionFailed("AVAudioConverter returned .error with no NSError")
            @unknown default:
                throw OggOpusEncoderError.conversionFailed("unexpected AVAudioConverterOutputStatus")
            }
        }

        guard !packets.isEmpty else { throw OggOpusEncoderError.noPacketsProduced }

        // RFC 7845 pre-skip is always expressed in 48 kHz-equivalent samples, regardless of the
        // actual encode sample rate. `primeInfo.leadingFrames` (in output-format, i.e. `sampleRate`,
        // frames) is the best signal AVAudioConverter exposes for the encoder's algorithmic
        // look-ahead/priming; converted to 48 kHz units. If the converter reports 0 (observed to
        // happen for some encode paths), fall back to libopus's well-known default encoder
        // look-ahead of 312 samples @ 48 kHz (6.5 ms) so decoders still trim a sane amount.
        let leadingFrames48k = Int(converter.primeInfo.leadingFrames) * Int(OggOpusMuxer.granuleRate) / Int(sampleRate)
        let preSkip = UInt16(clamping: leadingFrames48k > 0 ? leadingFrames48k : 312)

        Self.logger.debug("encode: packets=\(packets.count, privacy: .public) preSkip48k=\(preSkip, privacy: .public) primeLeadingFrames=\(converter.primeInfo.leadingFrames, privacy: .public)")

        let frameDuration48k = Int64((Self.frameDurationSeconds * Double(OggOpusMuxer.granuleRate)).rounded())
        let muxer = OggOpusMuxer(channelCount: 1, preSkip: preSkip, inputSampleRate: UInt32(sampleRate))
        return muxer.mux(packets: packets, frameDuration48k: frameDuration48k)
    }

    /// `Data`-based convenience: little-endian PCM16 mono in, complete Ogg/Opus file out.
    public func encode(pcm16 data: Data, sampleRate: Double = 16_000) throws -> Data {
        try encode(pcm16: int16Samples(fromLittleEndianData: data), sampleRate: sampleRate)
    }
}
