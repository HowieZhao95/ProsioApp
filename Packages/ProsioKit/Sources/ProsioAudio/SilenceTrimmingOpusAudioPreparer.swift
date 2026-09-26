import Foundation
import ProsioCore

/// P1.2's real `AudioPreparing`: silence-trims (`SilenceTrimmer`) then compresses to Ogg/Opus
/// (`OggOpusEncoder`). `ProsioCore` can't depend on `ProsioAudio` (dependency graph runs the other
/// way — see `Package.swift`), so `AudioPreparing`/`WAVAudioPreparer` (the default, used until this
/// type is wired in) live in `ProsioCore`, and this real implementation lives here instead,
/// injected at the composition root.
///
/// Order (docs/P1.2-AUDIO-ROUTING.md §1-2): trim -> encode Opus off the main actor (encoding takes
/// ~150ms per 20s of audio; a detached task started immediately keeps `stop()` from blocking on it
/// any longer than the `await` already implies) -> on encoder error, fall back to WAV of the
/// *trimmed* audio (still gets the trim's benefit, just skips compression). The debug recording
/// always keeps the full untrimmed WAV — this type never touches that, `DictationController` writes
/// it separately from the raw captured PCM.
public struct SilenceTrimmingOpusAudioPreparer: AudioPreparing {
    public init() {}

    public func prepare(pcm16: Data, sampleRate: Double) async -> PreparedAudio {
        let (trimmedData, stats) = SilenceTrimmer.trim(pcm16, sampleRate: sampleRate)

        let encoded = await Task.detached(priority: .utility) {
            try? OggOpusEncoder().encode(pcm16: trimmedData, sampleRate: sampleRate)
        }.value

        if let encoded {
            return PreparedAudio(data: encoded, format: .oggOpus, originalSeconds: stats.originalSeconds, trimmedSeconds: stats.trimmedSeconds)
        }

        // Opus encoding failed -> WAV of the trimmed audio, per docs/P1.2-AUDIO-ROUTING.md §1's
        // "Fallback: if encoding fails, upload WAV".
        let wav = WAVFile.make(pcm16: trimmedData, sampleRate: sampleRate)
        return PreparedAudio(data: wav, format: .wav, originalSeconds: stats.originalSeconds, trimmedSeconds: stats.trimmedSeconds)
    }
}
