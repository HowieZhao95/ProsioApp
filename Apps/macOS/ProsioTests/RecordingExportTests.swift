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

    @Test func audioOnlyRecoveredSessionExportsWithoutInventingMulticamOrVideo() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try await fixture(in: root)
        session.phase = .interrupted
        session.segments.removeAll { $0.sourceID == "screen" || $0.sourceID == "camera" }
        session.segments.append(RecordingSegment(sourceID: "mic", relativePath: "audio.caf", timelineStartMicroseconds: 3_503_501, mediaStartMicroseconds: 133_333, durationMicroseconds: 1_000_000))
        try FileManager.default.removeItem(at: root.appendingPathComponent("video.mov"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        func expectAudioFCPXML(_ document: XMLDocument) throws {
            #expect(try document.nodes(forXPath: "//multicam | //mc-angle | //mc-clip | //*[@ref='multicam']").isEmpty)
            #expect(try document.nodes(forXPath: "/fcpxml/resources/media").isEmpty)
            #expect(try document.nodes(forXPath: "//spine/gap/asset-clip").count == 3)
            #expect(try document.nodes(forXPath: "//spine/gap/asset-clip[@audioRole='dialogue']").count == 2)
            #expect(try document.nodes(forXPath: "//spine/gap/asset-clip[@audioRole='effects']").count == 1)
            let recovered = try #require(try document.nodes(forXPath: "//spine/gap/asset-clip[@audioRole='dialogue']").last as? XMLElement)
            #expect(recovered.attribute(forName: "offset")?.stringValue == "3503501/1000000s")
            #expect(recovered.attribute(forName: "start")?.stringValue == "133333/1000000s")
            #expect(try document.nodes(forXPath: "/fcpxml/resources/asset[@hasVideo='1']").isEmpty)
        }

        for editor in RecordingEditor.allCases {
            let destination = root.appendingPathComponent("Recovered-\(editor.rawValue)")
            let result = try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: destination, editor: editor)
            let packaged = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: destination.appendingPathComponent("recording.json")))
            #expect(packaged.segments.map(\.timelineStartMicroseconds) == session.segments.map(\.timelineStartMicroseconds))
            #expect(packaged.segments.map(\.mediaStartMicroseconds) == session.segments.map(\.mediaStartMicroseconds))
            #expect(packaged.durationMicroseconds == 4_503_501)
            for (original, copied) in zip(session.segments, packaged.segments) {
                #expect(try Data(contentsOf: root.appendingPathComponent(original.relativePath)) == Data(contentsOf: destination.appendingPathComponent(copied.relativePath)))
            }
            let note = try String(contentsOf: destination.appendingPathComponent("导入说明.txt"), encoding: .utf8)
            #expect(note.contains("本次恢复仅保留音频"))
            #expect(!note.contains("时间线中为原生多机位"))
            if editor == .jianying {
                let draft = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
                let tracks = try #require(draft["tracks"] as? [[String: Any]])
                #expect(tracks.count == 2)
                #expect(tracks.allSatisfy { ($0["type"] as? String) == "audio" })
                let segments = try #require(tracks.first?["segments"] as? [[String: Any]])
                let range = try #require(segments.last?["target_timerange"] as? [String: Int64])
                #expect(range["start"] == 3_503_501)
                let materials = try #require(draft["materials"] as? [String: Any])
                #expect((materials["videos"] as? [[String: Any]])?.isEmpty == true)
            } else if editor == .finalCutPro {
                try expectAudioFCPXML(XMLDocument(contentsOf: result))
            } else {
                let xml = try XMLDocument(contentsOf: result)
                #expect(try xml.nodes(forXPath: "/xmeml/sequence/media/video/track | //multiclip").isEmpty)
                #expect(try xml.nodes(forXPath: "/xmeml/sequence/media/audio/track").count == 3)
                #expect(try xml.nodes(forXPath: "/xmeml/sequence/media/audio/track[1]/clipitem[2]/start").first?.stringValue == "105")
                #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Multicam.premiere.experimental.xml").path))
                if editor == .resolve { try expectAudioFCPXML(XMLDocument(contentsOf: destination.appendingPathComponent("Multicam.fcpxml"))) }
            }
        }
        let movie = root.appendingPathComponent("invented.mp4")
        do {
            _ = try await RecordingVideoExporter.exportMP4(session: session, sourceDirectory: root, videoSourceID: "screen", destination: movie)
            Issue.record("Audio-only recovery must not produce a synthetic video")
        } catch RecordingExportError.noVideo {
            // Expected: originals can be handed off without pretending video survived recovery.
        }
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.caf").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("system.caf").path))
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

    @Test func writerAACDropSurvivesIndependentCompositionMixedMP4TrimAndHandoff() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let collected = RecordingExportWriterCollection()
        let microphone = RecordingSource(id: "microphone", kind: .microphone, name: "麦克风")
        let system = RecordingSource(id: "systemAudio", kind: .systemAudio, name: "系统声音")
        let screen = RecordingSource(id: "screen", kind: .screen, name: "屏幕")
        let writer = try RecordingMediaWriter(directory: root,
            configuration: RecordingConfiguration(screenTarget: .display(1), microphone: microphone), origin: .zero,
            onSegment: { collected.add($0) }, onWarning: { _ in }, onFailure: { collected.fail($0) },
            testingInputReadiness: { sourceID, pts in
                let time = CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
                return sourceID != "microphone" || time < 100_000 || time >= 120_000
            })
        var frame = 0
        for tick in 0..<120 {
            let time = CMTime(value: Int64(tick), timescale: 100)
            writer.append(try writerPCM(at: time, markerStart: 0.4, frequency: 1_000), sourceID: microphone.id, kind: .microphone)
            writer.append(try writerPCM(at: time, markerStart: 0.8, frequency: 2_000), sourceID: system.id, kind: .systemAudio)
            while CMTime(value: Int64(frame), timescale: 30) <= time {
                writer.append(try writerVideo(at: CMTime(value: Int64(frame), timescale: 30)), sourceID: screen.id, kind: .screen)
                frame += 1
            }
            await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await writer.stop()
        let segments = collected.segments.sorted {
            $0.sourceID == $1.sourceID ? $0.timelineStartMicroseconds < $1.timelineStartMicroseconds : $0.sourceID < $1.sourceID
        }
        #expect(collected.failures.isEmpty)
        let stats = await writer.statistics()
        #expect(stats.droppedAdmissionEvents == 0)
        #expect(stats.droppedEncoderSamples == 2)
        #expect(stats.finalizedSegments == 4)
        let micSegments = segments.filter { $0.sourceID == microphone.id }
        #expect(micSegments.map(\.timelineStartMicroseconds) == [0, 120_000])
        #expect(micSegments.map(\.durationMicroseconds) == [100_000, 1_080_000])
        #expect(segments.filter { $0.sourceID == system.id }.count == 1)
        let session = RecordingSessionManifest(title: "AAC 丢帧混音裁剪回归", phase: .ready,
                                              sources: [screen, microphone, system], segments: segments)
        let originals = try segments.map { try Data(contentsOf: root.appendingPathComponent($0.relativePath)) }

        let micOriginal = AVURLAsset(url: root.appendingPathComponent(try #require(micSegments.last).relativePath))
        let rawTrack = try #require(try await micOriginal.loadTracks(withMediaType: .audio).first)
        let rawMarkers = try await decodedMarkers(in: micOriginal, track: rawTrack, windows: [0.20...0.36])
        let rawMicTime = try #require(rawMarkers.first) + 0.12
        #expect(abs(rawMicTime - 0.4) < 0.003)

        let composition = try await RecordingVideoExporter.composition(session: session, sourceDirectory: root, videoSourceID: screen.id)
        let audio = composition.tracks.filter { $0.mediaType == .audio }
        #expect(audio.count == 2)
        let micTrack = try #require(audio.first)
        let systemTrack = try #require(audio.last)
        let micMapping = try #require(micTrack.segments)
        #expect(micMapping.filter { !$0.isEmpty }.count == 2)
        let holes = micMapping.filter(\.isEmpty)
        #expect(holes.count == 1)
        let hole = try #require(holes.first)
        #expect(abs(hole.timeMapping.target.start.seconds - 0.1) < 0.000_001)
        #expect(abs(hole.timeMapping.target.duration.seconds - 0.02) < 0.000_001)
        #expect(try #require(systemTrack.segments).filter(\.isEmpty).isEmpty)
        let compositionMic = try #require(try await decodedMarkers(in: composition, track: micTrack, windows: [0.30...0.49]).first)
        let compositionSystem = try #require(try await decodedMarkers(in: composition, track: systemTrack, windows: [0.70...0.89]).first)
        #expect(abs(compositionMic - 0.4) < 0.003)
        #expect(abs(compositionSystem - 0.8) < 0.003)

        let movieURL = root.appendingPathComponent("mixed-trimmed.mp4")
        _ = try await RecordingVideoExporter.exportMP4(session: session, sourceDirectory: root, videoSourceID: screen.id,
                                                       destination: movieURL, trimStart: 0.2, trimEnd: 1.1)
        let movie = AVURLAsset(url: movieURL)
        #expect(abs(try await movie.load(.duration).seconds - 0.9) < 0.005)
        let mixedTracks = try await movie.loadTracks(withMediaType: .audio)
        #expect(mixedTracks.count == 1)
        let mixed = try await decodedMarkers(in: movie, track: try #require(mixedTracks.first), windows: [0.10...0.29, 0.50...0.69])
        let trimmedMic = try #require(mixed.first)
        let trimmedSystem = try #require(mixed.last)
        #expect(abs(trimmedMic - 0.2) < 0.003, "A compacted 20 ms drop would put the decoded mic marker near 0.18 s")
        #expect(abs(trimmedSystem - 0.6) < 0.003, "The second independently recorded source must be audible in the actual mixed output")
        print("AAC_EXPORT_MARKER rawMicSeconds=\(rawMicTime) compositionMicSeconds=\(compositionMic) compositionSystemSeconds=\(compositionSystem) trimmedMicSeconds=\(trimmedMic) trimmedSystemSeconds=\(trimmedSystem) micErrorMicroseconds=\((trimmedMic - 0.2) * 1_000_000) systemErrorMicroseconds=\((trimmedSystem - 0.6) * 1_000_000)")

        let package = root.appendingPathComponent("handoff")
        let xmlURL = try await RecordingProjectExporter().export(session: session, sourceDirectory: root, destination: package, editor: .finalCutPro)
        let xml = try XMLDocument(contentsOf: xmlURL)
        #expect(try xml.nodes(forXPath: "//mc-clip/asset-clip[@audioRole='dialogue']").count == 2)
        #expect(try xml.nodes(forXPath: "//mc-clip/asset-clip[@audioRole='effects']").count == 1)
        #expect(try xml.nodes(forXPath: "//mc-clip/asset-clip[@audioRole='dialogue']/@offset").contains {
            $0.stringValue == RecordingProjectExporter.micros(120_000)
        })
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let packaged = try decoder.decode(RecordingSessionManifest.self, from: Data(contentsOf: package.appendingPathComponent("recording.json")))
        #expect(packaged.segments.map(\.timelineStartMicroseconds) == segments.map(\.timelineStartMicroseconds))
        for (index, segment) in segments.enumerated() {
            #expect(try Data(contentsOf: root.appendingPathComponent(segment.relativePath)) == originals[index])
            #expect(try Data(contentsOf: package.appendingPathComponent(packaged.segments[index].relativePath)) == originals[index])
        }
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

    /// Decode the full track and identify each nonoverlapping marker window in PCM, including sample PTS.
    private func decodedMarkers(in asset: AVAsset, track: AVAssetTrack, windows: [ClosedRange<Double>]) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        #expect(reader.startReading())
        defer { reader.cancelReading() }
        var markers = [Double?](repeating: nil, count: windows.count)
        var decodedFrames = 0
        while let sample = output.copyNextSampleBuffer() {
            let format = try #require(CMSampleBufferGetFormatDescription(sample))
            let description = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
            #expect(description.mChannelsPerFrame == 2)
            #expect(description.mSampleRate == 48_000)
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            #expect(status == noErr)
            let frames = values.count / 2
            decodedFrames += frames
            for frame in 0..<frames where max(abs(values[frame * 2]), abs(values[frame * 2 + 1])) > 0.1 {
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(frame) / description.mSampleRate
                for index in windows.indices where markers[index] == nil && windows[index].contains(time) { markers[index] = time }
            }
        }
        #expect(reader.status == .completed, "PCM decode must finish, not merely find a playable audio track: \(reader.error?.localizedDescription ?? "")")
        #expect(decodedFrames > 0)
        return try markers.map { try #require($0, "Expected an audible decoded marker in each requested time window") }
    }

    private func writerPCM(at time: CMTime, markerStart: Double, frequency: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 480 * 8,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 480 * 8,
            flags: 0, blockBufferOut: &block) == noErr)
        let storage = try #require(block)
        let values = (0..<480).flatMap { index -> [Float] in
            let seconds = time.seconds + Double(index) / 48_000
            let value: Float = seconds >= markerStart && seconds < markerStart + 0.08 ? Float(sin(2 * .pi * frequency * seconds) * 0.6) : 0
            return [value, value]
        }
        #expect(values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: storage, offsetIntoDestination: 0, dataLength: $0.count)
        } == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = 8
        var sample: CMSampleBuffer?
        let audioFormat = try #require(format)
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: storage, formatDescription: audioFormat,
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func writerVideo(at time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 128, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let videoFormat = try #require(format)
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: videoFormat, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

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

nonisolated private final class RecordingExportWriterCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [RecordingSegment] = []
    private var errors: [String] = []
    var segments: [RecordingSegment] { lock.lock(); defer { lock.unlock() }; return saved }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func add(_ segment: RecordingSegment) { lock.lock(); defer { lock.unlock() }; saved.append(segment) }
    func fail(_ message: String) { lock.lock(); defer { lock.unlock() }; errors.append(message) }
}
