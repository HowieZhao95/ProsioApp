import AVFoundation
import Foundation

@MainActor
enum RecordingVideoExporter {
    static func composition(session: RecordingSessionManifest, sourceDirectory: URL, videoSourceID: String) async throws -> AVMutableComposition {
        try RecordingExportSupport.validate(session)
        guard let video = session.sources.first(where: { $0.id == videoSourceID && ($0.kind == .screen || $0.kind == .camera) }),
              session.segments.contains(where: { $0.sourceID == video.id }) else { throw RecordingExportError.noVideo }
        let composition = AVMutableComposition()
        let sources = [video] + session.sources.filter { $0.kind == .microphone || $0.kind == .systemAudio }
        for source in sources {
            let mediaType: AVMediaType = source.id == videoSourceID ? .video : .audio
            guard let output = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecordingExportError.exportFailed("无法创建媒体轨道")
            }
            for segment in session.segments.filter({ $0.sourceID == source.id }).sorted(by: { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }) {
                try Task.checkCancellation()
                let info = try await RecordingExportSupport.inspectedMedia(segment, source: source, directory: sourceDirectory)
                let asset = AVURLAsset(url: info.url)
                guard let input = try await asset.loadTracks(withMediaType: mediaType).first else { throw RecordingExportError.missingMedia(segment.relativePath) }
                let start = RecordingExportSupport.time(segment.timelineStartMicroseconds)
                if CMTimeCompare(output.timeRange.end, start) < 0 {
                    output.insertEmptyTimeRange(CMTimeRange(start: output.timeRange.end, end: start))
                }
                try output.insertTimeRange(CMTimeRange(start: RecordingExportSupport.time(segment.mediaStartMicroseconds), duration: RecordingExportSupport.time(segment.durationMicroseconds)), of: input, at: start)
                if mediaType == .video { output.preferredTransform = try await input.load(.preferredTransform) }
            }
            let end = RecordingExportSupport.time(session.durationMicroseconds)
            if CMTimeCompare(output.timeRange.end, end) < 0 {
                output.insertEmptyTimeRange(CMTimeRange(start: output.timeRange.end, end: end))
            }
        }
        return composition
    }

    static func exportMP4(session: RecordingSessionManifest, sourceDirectory: URL, videoSourceID: String, destination: URL, trimStart: Double = 0, trimEnd: Double? = nil) async throws -> URL {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RecordingExportError.destinationExists }
        let media = try await composition(session: session, sourceDirectory: sourceDirectory, videoSourceID: videoSourceID)
        let end = trimEnd ?? media.duration.seconds
        guard trimStart.isFinite, end.isFinite, trimStart >= 0, end > trimStart, end <= media.duration.seconds + 0.000001 else { throw RecordingExportError.invalidTrim }
        guard let exporter = AVAssetExportSession(asset: media, presetName: AVAssetExportPresetHighestQuality) else { throw RecordingExportError.exportFailed("无法创建 MP4 导出器") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".prosio-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 1_000_000), duration: CMTime(seconds: end - trimStart, preferredTimescale: 1_000_000))
        exporter.shouldOptimizeForNetworkUse = true
        let audioTracks = media.tracks.filter { $0.mediaType == .audio }
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(1 / Float(audioTracks.count), at: .zero)
                return parameters
            }
            exporter.audioMix = mix
        }
        let cancellation = RecordingExportCancellation(exporter)
        try await withTaskCancellationHandler {
            try await exporter.export(to: temporary, as: .mp4)
        } onCancel: { Task { @MainActor in cancellation.cancel() } }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

@MainActor
private final class RecordingExportCancellation {
    private let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func cancel() { exporter.cancelExport() }
}
