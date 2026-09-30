import AVFoundation
import CoreMedia
import Foundation

@main struct RecordingUIFixtureSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/tmp/prosio-recording-complete-ui-media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cameras: [RecordingSource] = (1...2).map { .init(id: "ui-camera-\($0)", kind: .camera, name: "合成机位 \($0)", deviceID: "ui-cam-\($0)") }
        let mic = RecordingSource(id: "ui-microphone", kind: .microphone, name: "合成测试麦克风", deviceID: "ui-mic")
        let config = RecordingConfiguration(screenTarget: .display(1), cameras: cameras, microphone: mic)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = FixtureRecordingEngine()
        var segments: [RecordingSegment] = []
        engine.onSegment = { segments.append($0) }
        try await engine.start(configuration: config, directory: folder)
        guard let session = engine.previewSession(for: cameras[0].id), session.inputs.isEmpty, !session.isRunning,
              engine.previewSession(for: cameras[0].id) === session else { throw failure("Empty preview session identity") }
        try await engine.pause(); try await engine.resume()
        let first = Task { try await engine.stop() }
        let second = Task { try await engine.stop() }
        try await first.value; try await second.value
        guard segments.count == 5, engine.eventLog.filter({ $0.hasPrefix("stop: generating") }).count == 1,
              engine.previewSession(for: cameras[0].id) == nil else { throw failure("Five sources and one joined finalization required") }
        let kinds: [String: RecordingSourceKind] = ["screen": .screen, "ui-camera-1": .camera, "ui-camera-2": .camera, "ui-microphone": .microphone, "systemAudio": .systemAudio]
        var media: [[String: Any]] = []
        for segment in segments {
            guard let kind = kinds[segment.sourceID] else { throw failure("Unknown source") }
            let asset = AVURLAsset(url: folder.appendingPathComponent(segment.relativePath))
            guard try await asset.load(.isPlayable) else { throw failure("Unplayable generated media") }
            let type: AVMediaType = kind == .camera || kind == .screen ? .video : .audio
            guard let track = try await asset.loadTracks(withMediaType: type).first else { throw failure("Missing media track") }
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = type == .video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            guard reader.startReading() else { throw failure("Decode start failed") }
            var decoded = 0
            while let sample = output.copyNextSampleBuffer() { decoded += type == .video ? 1 : CMSampleBufferGetNumSamples(sample) }
            guard reader.status == .completed, decoded > 0 else { throw failure("Complete decode failed") }
            media.append(["sourceID": segment.sourceID, "kind": kind.rawValue, "decodedSamples": decoded,
                          "durationMicroseconds": segment.durationMicroseconds, "startMicroseconds": segment.timelineStartMicroseconds,
                          "relativePath": segment.relativePath, "fullDecode": true])
        }
        let report: [String: Any] = ["passed": true, "physicalCapture": false, "permissionsRequested": false,
            "syntheticVideoSources": 3, "syntheticAudioSources": 2, "concurrentStopJoined": true,
            "previewWasEmptyAndStable": true, "directory": folder.path, "media": media, "events": engine.eventLog]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "RecordingUIFixtureSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
