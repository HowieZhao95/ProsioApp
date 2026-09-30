import AVFoundation
import Foundation
import Testing

@Suite("Recording media handoff")
@MainActor
struct RecordingExportTests {
    @Test func allEditorsPreserveSegmentsAndIndependentAudio() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await fixture(in: root)
        for editor in RecordingEditor.allCases {
            let destination = root.appendingPathComponent("交接 & \(editor.rawValue)")
            let result = try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: destination, editor: editor)
            #expect(FileManager.default.fileExists(atPath: result.path))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let packaged = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: destination.appendingPathComponent("recording.json")))
            #expect(packaged.segments.map(\.timelineStartMicroseconds) == session.segments.map(\.timelineStartMicroseconds))
            #expect(packaged.segments.map(\.mediaStartMicroseconds) == session.segments.map(\.mediaStartMicroseconds))
            for segment in packaged.segments { #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(segment.relativePath).path)) }
            if editor == .jianying {
                let draft = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
                let tracks = try #require(draft["tracks"] as? [[String: Any]])
                #expect(tracks.count == 4)
                #expect(tracks.filter { ($0["type"] as? String) == "audio" }.count == 2)
                let videoSegments = try #require(tracks.first?["segments"] as? [[String: Any]])
                let recovered = try #require(videoSegments.last?["target_timerange"] as? [String: Int64])
                #expect(recovered["start"] == 3_503_501)
            } else {
                let document = try XMLDocument(contentsOf: result)
                if editor == .finalCutPro {
                    #expect(try document.nodes(forXPath: "//mc-angle").count == 2)
                    #expect(try document.nodes(forXPath: "//mc-clip/mc-source[@srcEnable='video']").count == 1)
                    #expect(try document.nodes(forXPath: "//mc-clip/asset-clip[@audioRole='dialogue']").count == 1)
                    #expect(try document.nodes(forXPath: "//mc-clip/asset-clip[@audioRole='effects']").count == 1)
                    let angles = try document.nodes(forXPath: "//mc-angle")
                    #expect(try angles[0].nodes(forXPath: "gap").count == 2)
                    let recovered = try #require(try angles[0].nodes(forXPath: "asset-clip").last as? XMLElement)
                    #expect(recovered.attribute(forName: "offset")?.stringValue == "3503501/1000000s")
                    #expect(try document.nodes(forXPath: "//media-rep").count == session.segments.count)
                    let selectedFormats = try document.nodes(forXPath: "//format/@frameDuration")
                    #expect(selectedFormats.contains { $0.stringValue == "1001/30000s" })
                } else {
                    #expect(try document.nodes(forXPath: "//sequence/media/video/track").count == 2)
                    #expect(try document.nodes(forXPath: "//sequence/media/audio/track").count == 3)
                    #expect(try document.nodes(forXPath: "//clipitem").count == 6)
                    #expect(try document.nodes(forXPath: "//sequence/rate/ntsc").first?.stringValue == "TRUE")
                    #expect(try document.nodes(forXPath: "//sequence/media/audio/track[3]/clipitem/sourcetrack/trackindex").first?.stringValue == "2")
                    #expect(try document.nodes(forXPath: "//sequence/media/audio/track[3]/clipitem/link").count == 2)
                    #expect(try document.nodes(forXPath: "//sequence/media/video/track[1]/clipitem[2]/start").first?.stringValue == "105")
                }
                let text = String(data: try Data(contentsOf: result), encoding: .utf8) ?? ""
                #expect(text.contains("&amp;"))
                #expect(text.contains("%20"))
            }
        }
    }

    @Test func compositionAndTrimmedMP4PreserveLeadingAndRecoveredGaps() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await fixture(in: root)
        let composition = try await RecordingVideoExporter.composition(session: session, sourceDirectory: root, videoSourceID: "screen")
        let tracks = composition.tracks.filter { $0.mediaType == .video }
        let video = try #require(tracks.first)
        let segments = try #require(video.segments)
        #expect(segments.filter(\.isEmpty).count >= 2)
        let filled = segments.filter { !$0.isEmpty }
        #expect(abs(filled[0].timeMapping.target.start.seconds - 0.100_100) < 0.000_001)
        #expect(abs(filled[1].timeMapping.target.start.seconds - 3.503_501) < 0.000_001)
        #expect(composition.tracks.filter { $0.mediaType == .audio }.count == 2)
        let destination = root.appendingPathComponent("trimmed.mp4")
        _ = try await RecordingVideoExporter.exportMP4(session: session, sourceDirectory: root, videoSourceID: "screen", destination: destination, trimStart: 0.2, trimEnd: 4.2)
        let asset = AVURLAsset(url: destination)
        #expect(abs(try await asset.load(.duration).seconds - 4) < 0.05)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("video.mov").path))
    }

    @Test func pathTraversalSymlinksOverlapAndMissingMediaAreRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try await fixture(in: root)
        for path in ["../escape.mov", "/tmp/escape.mov", "Media//escape.mov", "\\escape.mov"] {
            session.segments[0].relativePath = path
            await #expect(throws: (any Error).self) {
                try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: root.appendingPathComponent(UUID().uuidString), editor: .finalCutPro)
            }
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.mov"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside.mov"))
        session.segments[0].relativePath = "escape.mov"
        await #expect(throws: (any Error).self) { try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: root.appendingPathComponent("escape"), editor: .finalCutPro) }
        session.segments[0].relativePath = "missing.mov"
        await #expect(throws: (any Error).self) { try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: root.appendingPathComponent("missing"), editor: .finalCutPro) }
        session.segments[0].relativePath = "video.mov"
        session.segments[1].timelineStartMicroseconds = 0
        #expect(throws: (any Error).self) { try RecordingExportSupport.validate(session) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".prosio-handoff-") })
    }

    @Test func cancellationAndCollisionPreserveExistingDestination() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await fixture(in: root)
        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        await #expect(throws: (any Error).self) { try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: destination, editor: .premiere) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        let cancelledDestination = root.appendingPathComponent("cancelled")
        let job = Task { @MainActor in
            try Task.checkCancellation()
            return try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: cancelledDestination, editor: .finalCutPro)
        }
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(!FileManager.default.fileExists(atPath: cancelledDestination.path))
    }

    @Test func boundedCopyCanCancelAndInvalidTrimCannotPublish() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try await fixture(in: root)
        let sparse = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let source = try FileHandle(forWritingTo: sparse)
        try source.truncate(atOffset: 1_073_741_824)
        try source.close()
        let copied = root.appendingPathComponent("copied.bin")
        let job = Task { try await RecordingExportSupport.copyMedia(from: sparse, to: copied) }
        try await Task.sleep(for: .milliseconds(5))
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        let destination = root.appendingPathComponent("invalid.mp4")
        await #expect(throws: (any Error).self) {
            try await RecordingVideoExporter.exportMP4(session: session, sourceDirectory: root, videoSourceID: "screen", destination: destination, trimStart: 5, trimEnd: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        session.segments[0].durationMicroseconds = 9_000_000
        // Keep manifest structurally valid so AVFoundation duration validation is exercised.
        session.segments[1].timelineStartMicroseconds = 10_000_000
        await #expect(throws: (any Error).self) {
            try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: root.appendingPathComponent("oversized"), editor: .premiere)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("oversized").path))
    }

    @Test func longSegmentedTimelinePreservesExactRationalOffsets() throws {
        let source = RecordingSource(id: "video", kind: .screen, name: "屏幕")
        let segments = (0..<120).map { index in RecordingSegment(sourceID: source.id, relativePath: "\(index).mov", timelineStartMicroseconds: Int64(index) * 61_000_000 + 123_456, durationMicroseconds: 60_000_000) }
        let session = RecordingSessionManifest(title: "两小时", sources: [source], segments: segments)
        try RecordingExportSupport.validate(session)
        let media = segments.map { RecordingMediaInfo(segment: $0, source: source, url: URL(fileURLWithPath: "/tmp/\($0.relativePath)"), duration: CMTime(value: 60, timescale: 1), width: 1280, height: 720, frameDuration: CMTime(value: 1, timescale: 25), sampleRate: nil, channels: nil) }
        let doc = try XMLDocument(data: RecordingProjectExporter.fcpxml(session: session, media: media))
        #expect(try doc.nodes(forXPath: "//mc-angle/asset-clip").count == 120)
        #expect(try doc.nodes(forXPath: "//mc-angle/gap").count == 120)
        let last = try #require(try doc.nodes(forXPath: "//mc-angle/asset-clip").last as? XMLElement)
        #expect(last.attribute(forName: "offset")?.stringValue == RecordingProjectExporter.micros(7_259_123_456))
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("prosio-export-\(UUID())") }

    private func fixture(in root: URL) async throws -> RecordingSessionManifest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await writeVideo(to: root.appendingPathComponent("video.mov"))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("audio.caf"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        if let samples = buffer.floatChannelData?.pointee { for index in 0..<144_000 { samples[index] = sin(Float(index) * .pi * 2 * 440 / 48_000) * 0.1 } }
        try file.write(from: buffer)
        let stereoFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let stereoFile = try AVAudioFile(forWriting: root.appendingPathComponent("system.caf"), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        let stereo = try #require(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 144_000))
        stereo.frameLength = 144_000
        if let channels = stereo.floatChannelData {
            for index in 0..<144_000 {
                channels[0][index] = sin(Float(index) * .pi * 2 * 220 / 48_000) * 0.1
                channels[1][index] = sin(Float(index) * .pi * 2 * 880 / 48_000) * 0.1
            }
        }
        try stereoFile.write(from: stereo)
        let sources = [RecordingSource(id: "screen", kind: .screen, name: "屏幕 & 窗口"), RecordingSource(id: "camera", kind: .camera, name: "机位"), RecordingSource(id: "mic", kind: .microphone, name: "麦克风"), RecordingSource(id: "system", kind: .systemAudio, name: "系统声音")]
        return RecordingSessionManifest(title: "口播 & 演示", phase: .ready, sources: sources, segments: [
            RecordingSegment(sourceID: "screen", relativePath: "video.mov", timelineStartMicroseconds: 100_100, mediaStartMicroseconds: 100_100, durationMicroseconds: 2_000_000),
            RecordingSegment(sourceID: "screen", relativePath: "video.mov", timelineStartMicroseconds: 3_503_501, durationMicroseconds: 1_000_000),
            RecordingSegment(sourceID: "camera", relativePath: "video.mov", timelineStartMicroseconds: 0, durationMicroseconds: 3_000_000),
            RecordingSegment(sourceID: "mic", relativePath: "audio.caf", timelineStartMicroseconds: 50_000, durationMicroseconds: 2_950_000),
            RecordingSegment(sourceID: "system", relativePath: "system.caf", timelineStartMicroseconds: 0, durationMicroseconds: 3_000_000)
        ])
    }

    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.mediaTimeScale = 30_000
        writer.movieTimeScale = 30_000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(frame), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame) * 1001, timescale: 30_000)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
