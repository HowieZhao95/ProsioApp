import AVFoundation
import Foundation

public enum MeetingCloudAudio {
    /// Produces one compressed file for Soniox while preserving the two raw tracks.
    /// The stored track offsets keep the cloud timeline aligned with the local draft.
    public static func export(_ files: MeetingAudioFiles, to output: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let entries: [(URL, Double)] = [(files.microphone, files.microphoneOffset)] +
            (files.system.map { [($0, files.systemOffset ?? 0)] } ?? [])
        let origin = min(0, entries.map(\.1).min() ?? 0)
        for (url, offset) in entries {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            let duration = try await asset.load(.duration)
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track,
                                            at: CMTime(seconds: offset - origin, preferredTimescale: 48_000))
        }
        guard !composition.tracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.unavailable("No audio track available for cloud transcription")
        }
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .m4a)
        return output
    }
}
