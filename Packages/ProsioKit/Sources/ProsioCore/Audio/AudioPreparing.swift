import Foundation

/// P1.2: prepares a finished session's raw audio for upload — silence-trimmed and compressed once
/// speech's `SilenceTrimmer`/`OggOpusEncoder` land in `ProsioAudio`; WAV-untrimmed until then (see
/// `WAVAudioPreparer`, the default). Injectable so `DictationController` never has to depend on
/// `ProsioAudio` directly — the real implementation is wired in at the composition root once its
/// API lands. See docs/P1.2-AUDIO-ROUTING.md §1-2.
public protocol AudioPreparing: Sendable {
    /// - Parameters:
    ///   - pcm16: the full session's raw little-endian PCM16 mono samples, in order.
    ///   - sampleRate: `pcm16`'s sample rate (`AudioFormat.pcm16Mono16k.sampleRate` today).
    func prepare(pcm16: Data, sampleRate: Double) async -> PreparedAudio
}

/// The result of `AudioPreparing.prepare` — ready to hand to `CloudTranscribeRequest`.
public struct PreparedAudio: Sendable {
    public var data: Data
    public var format: UploadAudioFormat
    /// Duration of `pcm16` as given (before any trimming).
    public var originalSeconds: Double
    /// Duration actually represented by `data` after trimming (equal to `originalSeconds` when
    /// untrimmed, e.g. `WAVAudioPreparer`, or when trimming was skipped as a safety fallback).
    public var trimmedSeconds: Double

    public init(data: Data, format: UploadAudioFormat, originalSeconds: Double, trimmedSeconds: Double) {
        self.data = data
        self.format = format
        self.originalSeconds = originalSeconds
        self.trimmedSeconds = trimmedSeconds
    }
}

/// Default `AudioPreparing`: wraps the raw PCM16 as an untrimmed WAV file, no compression — used
/// until speech's `SilenceTrimmer` + `OggOpusEncoder` land in `ProsioAudio` and get wired in as the
/// real implementation at the composition root (`DictationController` itself never changes).
public struct WAVAudioPreparer: AudioPreparing {
    public init() {}

    public func prepare(pcm16: Data, sampleRate: Double) async -> PreparedAudio {
        let seconds = sampleRate > 0 ? Double(pcm16.count / 2) / sampleRate : 0
        let wav = WAVFile.make(pcm16: pcm16, sampleRate: sampleRate)
        return PreparedAudio(data: wav, format: .wav, originalSeconds: seconds, trimmedSeconds: seconds)
    }
}
