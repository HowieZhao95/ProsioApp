import AVFoundation
import CoreMedia
import XCTest

nonisolated final class RecordingPlatformTests: XCTestCase {
    nonisolated func testTimelineExcludesPausesButKeepsSourceGaps() {
        var clock = RecordingTimeline(origin: CMTime(seconds: 100, preferredTimescale: 1_000_000))
        XCTAssertEqual(clock.offset(for: CMTime(seconds: 104, preferredTimescale: 1_000_000)), 4_000_000)
        clock.pause(at: CMTime(seconds: 105, preferredTimescale: 1_000_000))
        XCTAssertNil(clock.offset(for: CMTime(seconds: 106, preferredTimescale: 1_000_000)))
        clock.resume(at: CMTime(seconds: 115, preferredTimescale: 1_000_000))
        XCTAssertNil(clock.offset(for: CMTime(seconds: 114, preferredTimescale: 1_000_000)))
        XCTAssertEqual(clock.offset(for: CMTime(seconds: 117, preferredTimescale: 1_000_000)), 7_000_000)
        XCTAssertEqual(clock.offset(for: CMTime(seconds: 125, preferredTimescale: 1_000_000)), 15_000_000)
    }

    nonisolated func testRealVideoEncoderRollsPlayableChunksAndWaitsForCallbacks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected, interval: 5)
        for index in 0..<181 {
            writer.append(try video(at: Double(index) / 30), sourceID: "screen", kind: .screen)
            await drain(writer)
            if index.isMultiple(of: 4) { try await Task.sleep(for: .milliseconds(2)) }
        }
        try await writer.stop()
        let segments = collected.segments
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: "; "))
        XCTAssertEqual(segments.count, 2)
        for segment in segments {
            let asset = AVURLAsset(url: directory.appendingPathComponent(segment.relativePath))
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            XCTAssertNotNil(output.copyNextSampleBuffer()) // Verify actual decoding, not only a recognized file header.
            reader.cancelReading()
            let sidecarURL = directory.appendingPathComponent("media/\(segment.id.uuidString).segment.json")
            XCTAssertEqual(try JSONDecoder().decode(RecordingSegment.self, from: Data(contentsOf: sidecarURL)), segment)
            XCTAssertLessThanOrEqual(segment.durationMicroseconds, 5_000_001)
            XCTAssertEqual(segment.width, 64)
            XCTAssertFalse(segment.relativePath.contains("partial"))
        }
        XCTAssertEqual(segments.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }.last?.timelineStartMicroseconds, 5_000_000)
        try await writer.stop() // Idempotent and immediately completes after all callbacks.
    }

    nonisolated func testSeparateAudioFilesAreEncodedAndRemainAligned() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        for index in 0..<50 {
            let time = Double(index) / 100
            writer.append(try audio(at: time), sourceID: "microphone", kind: .microphone)
            writer.append(try audio(at: time + 0.02), sourceID: "systemAudio", kind: .systemAudio)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.stop()
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: "; "))
        XCTAssertEqual(Set(collected.segments.map(\.sourceID)), ["microphone", "systemAudio"])
        for segment in collected.segments {
            let asset = AVURLAsset(url: directory.appendingPathComponent(segment.relativePath))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1)
            XCTAssertEqual(segment.sampleRate, 48_000)
            XCTAssertEqual(segment.channelCount, 2)
            XCTAssertEqual(segment.timelineStartMicroseconds, segment.sourceID == "microphone" ? 0 : 20_000)
        }
    }

    nonisolated func testPauseAndDisconnectProduceAlignedNewFilesAndRejectStaleSamples() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        writer.append(try video(at: 0), sourceID: "camera-1", kind: .camera)
        await drain(writer)
        writer.setSourceAvailable("camera-1", false)
        writer.append(try video(at: 1), sourceID: "camera-1", kind: .camera)
        await drain(writer)
        await writer.pause(at: CMTime(seconds: 2, preferredTimescale: 1_000_000))
        await writer.resume(at: CMTime(seconds: 7, preferredTimescale: 1_000_000))
        writer.setSourceAvailable("camera-1", true)
        writer.append(try video(at: 6), sourceID: "camera-1", kind: .camera) // Captured before resume: must be discarded.
        writer.append(try video(at: 8), sourceID: "camera-1", kind: .camera)
        await drain(writer)
        try await writer.stop()
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: "; "))
        XCTAssertEqual(collected.segments.map(\.timelineStartMicroseconds).sorted(), [0, 3_000_000])
    }

    nonisolated func testStaticScreenIdleFramesStillCreateDurableChunks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected, interval: 5)
        writer.append(try video(at: 0), sourceID: "screen", kind: .screen)
        await drain(writer)
        for index in 1...180 {
            writer.advanceScreen(at: CMTime(value: Int64(index), timescale: 30))
            await drain(writer)
            if index.isMultiple(of: 4) { try await Task.sleep(for: .milliseconds(2)) }
        }
        try await writer.stop()
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: "; "))
        XCTAssertEqual(collected.segments.count, 2)
        XCTAssertEqual(collected.segments.map(\.timelineStartMicroseconds).sorted(), [0, 5_000_000])
    }

    nonisolated func testAudioChunkBoundaryDoesNotAddAACPrimingToTimeline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected, interval: 5)
        for index in 0..<510 {
            writer.append(try audio(at: Double(index) / 100), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            if index.isMultiple(of: 5) { try await Task.sleep(for: .milliseconds(2)) }
        }
        try await writer.stop()
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: "; "))
        let ordered = collected.segments.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
        XCTAssertEqual(ordered.count, 2)
        let first = try XCTUnwrap(ordered.first)
        let last = try XCTUnwrap(ordered.last)
        XCTAssertEqual(first.durationMicroseconds, 5_000_000)
        XCTAssertEqual(last.timelineStartMicroseconds, 5_000_000)
        XCTAssertLessThanOrEqual(first.timelineEndMicroseconds ?? .max, last.timelineStartMicroseconds)
    }

    nonisolated func testWriterFailureIsReportedAndStopThrowsAfterDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("media"))
        writer.append(try video(at: 0), sourceID: "screen", kind: .screen)
        await drain(writer)
        do {
            try await writer.stop()
            XCTFail("Encoder/file creation failure must propagate to the coordinator.")
        } catch {
            XCTAssertFalse(collected.failures.isEmpty)
            XCTAssertTrue(collected.segments.isEmpty)
        }
    }

    nonisolated func testRealAudioPTSGapPreservesMarkerTimeAndEditorOffsets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        for tick in 0..<100 {
            if tick != 10 && tick != 11 {
                writer.append(try audio(at: Double(tick) / 100, markerStart: 0.4), sourceID: "microphone", kind: .microphone)
            }
            writer.append(try audio(at: Double(tick) / 100), sourceID: "systemAudio", kind: .systemAudio)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        try await writer.stop()
        let microphone = collected.segments.filter { $0.sourceID == "microphone" }.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: ";"))
        XCTAssertEqual(microphone.map(\.timelineStartMicroseconds), [0, 120_000])
        XCTAssertEqual(microphone.first?.durationMicroseconds, 100_000)
        XCTAssertEqual(collected.segments.filter { $0.sourceID == "systemAudio" }.count, 1)
        try await assertMarker(in: microphone, directory: directory, expectedTime: 0.4, scenario: "real-PTS-gap")
        let stats = await writer.statistics()
        XCTAssertEqual(stats.recentLosses?.filter { $0.reason == .timestampGap }.first?.durationMicroseconds, 20_000)
        let session = RecordingSessionManifest(title: "Actual AAC gap", phase: .ready,
            sources: [RecordingSource(id: "microphone", kind: .microphone, name: "Marker")], segments: microphone)
        let result = try await RecordingProjectExporter().export(session: session, sourceDirectory: directory,
            destination: directory.appendingPathComponent("handoff"), editor: .finalCutPro)
        let document = try XMLDocument(contentsOf: result)
        let offsets = try document.nodes(forXPath: "//asset-clip/@offset").compactMap(\.stringValue)
        let seconds = offsets.compactMap { value -> Double? in
            let components = value.dropLast().split(separator: "/")
            guard let numerator = components.first.flatMap({ Double($0) }) else { return nil }
            if components.count == 1 { return numerator }
            guard components.count == 2, let denominator = Double(components[1]), denominator != 0 else { return nil }
            return numerator / denominator
        }
        XCTAssertTrue(seconds.contains { abs($0 - 0.12) < 0.000_001 }, "Original source gap must survive XML export: \(offsets)")
    }

    nonisolated func testEncoderRejecting20msOfAudioDoesNotCompactMarker() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try RecordingMediaWriter(directory: directory,
            configuration: RecordingConfiguration(screenTarget: .display(1)), origin: .zero,
            onSegment: { collected.add($0) }, onWarning: { collected.warn($0) }, onFailure: { collected.fail($0) },
            testingInputReadiness: { sourceID, pts in
                let time = CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
                return sourceID != "microphone" || time < 100_000 || time >= 120_000
            })
        for tick in 0..<100 {
            writer.append(try audio(at: Double(tick) / 100, markerStart: 0.4), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        try await writer.stop()
        let ordered = collected.segments.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: ";"))
        XCTAssertEqual(ordered.map(\.timelineStartMicroseconds), [0, 120_000])
        XCTAssertEqual(ordered.first?.durationMicroseconds, 100_000)
        try await assertMarker(in: ordered, directory: directory, expectedTime: 0.4, scenario: "encoder-drop-20ms")
        let stats = await writer.statistics()
        XCTAssertEqual(stats.droppedEncoderSamples, 2)
        XCTAssertEqual(stats.lossCountsBySourceAndReason?["microphone"]?["encoderBackpressure"], 2)
        let report = try JSONDecoder().decode(RecordingSampleLossReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("recording-losses.json")))
        XCTAssertEqual(report.countsBySourceAndReason["microphone"]?["encoderBackpressure"], 2)
        XCTAssertTrue(report.recentLosses.contains {
            $0.reason == .timestampGap && $0.hostStartMicroseconds == 100_000 && $0.durationMicroseconds == 20_000
        })
    }

    nonisolated func testAdmissionDropping20msOfAudioDoesNotCompactMarkerAndStopJoins() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        for tick in 0..<10 {
            writer.append(try audio(at: Double(tick) / 100), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        let gate = await blockQueue(writer)
        // Duplicate old samples occupy the fixed admission slots without adding media or encoder work.
        for _ in 0..<16 { writer.append(try audio(at: 0.09), sourceID: "microphone", kind: .microphone) }
        writer.append(try audio(at: 0.1), sourceID: "microphone", kind: .microphone)
        writer.append(try audio(at: 0.11), sourceID: "microphone", kind: .microphone)
        gate.signal()
        await drain(writer)
        for tick in 12..<100 {
            writer.append(try audio(at: Double(tick) / 100, markerStart: 0.4), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        async let one: Void = writer.stop()
        async let two: Void = writer.stop()
        try await one
        try await two
        let ordered = collected.segments.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: ";"))
        XCTAssertEqual(ordered.map(\.timelineStartMicroseconds), [0, 120_000])
        try await assertMarker(in: ordered, directory: directory, expectedTime: 0.4, scenario: "admission-drop-20ms")
        let stats = await writer.statistics()
        XCTAssertEqual(stats.droppedAdmissionEvents, 2)
        XCTAssertEqual(stats.peakQueuedEvents, 16)
        XCTAssertEqual(stats.lossCountsBySourceAndReason?["microphone"]?["admission"], 2)
    }

    nonisolated func testAudioPauseExcludesOnlyPauseAndPreservesPostResumeMarker() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        for tick in 0..<10 {
            writer.append(try audio(at: Double(tick) / 100), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        await writer.pause(at: CMTime(seconds: 0.1, preferredTimescale: 1_000_000))
        await writer.resume(at: CMTime(seconds: 5.1, preferredTimescale: 1_000_000))
        writer.append(try audio(at: 5.0, markerStart: 5.0), sourceID: "microphone", kind: .microphone) // Stale, must not become media.
        for tick in 0..<90 {
            writer.append(try audio(at: 5.1 + Double(tick) / 100, markerStart: 5.4), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        try await writer.stop()
        let ordered = collected.segments.sorted { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: ";"))
        XCTAssertEqual(ordered.map(\.timelineStartMicroseconds), [0, 100_000])
        try await assertMarker(in: ordered, directory: directory, expectedTime: 0.4, scenario: "pause-resume")
        let stats = await writer.statistics()
        XCTAssertTrue(stats.recentLosses?.isEmpty == true)
    }

    nonisolated func testLossDiagnosticsStayBoundedWhileCountsCoverEveryRejectedSample() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        for tick in 0..<10 {
            writer.append(try audio(at: Double(tick) / 100), sourceID: "microphone", kind: .microphone)
            await drain(writer)
            try await Task.sleep(for: .milliseconds(2))
        }
        let gate = await blockQueue(writer)
        for _ in 0..<16 { writer.append(try audio(at: 0.09), sourceID: "microphone", kind: .microphone) }
        for tick in 10..<110 { writer.append(try audio(at: Double(tick) / 100), sourceID: "microphone", kind: .microphone) }
        gate.signal()
        try await writer.stop()
        let stats = await writer.statistics()
        XCTAssertEqual(stats.recentLosses?.count, 64)
        XCTAssertEqual(stats.droppedAdmissionEvents, 100)
        XCTAssertEqual(stats.lossCountsBySourceAndReason?["microphone"]?["admission"], 100)
        let report = try JSONDecoder().decode(RecordingSampleLossReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("recording-losses.json")))
        XCTAssertEqual(report.recentLosses.count, 64)
        XCTAssertEqual(report.countsBySourceAndReason["microphone"]?["admission"], 100)
        XCTAssertTrue(collected.failures.isEmpty, collected.failures.joined(separator: ";"))
    }

    nonisolated func testDroppedVideoWithInvalidDurationDoesNotInspectAudioFormat() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collected = Collected()
        let writer = try makeWriter(directory, collected: collected)
        let original = try video(at: 0.1)
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original), decodeTimeStamp: .invalid)
        var invalidDuration: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: original,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &invalidDuration), noErr)
        let dropped = try XCTUnwrap(invalidDuration)
        let gate = await blockQueue(writer)
        // No previous image exists: these fill admission slots without allocating an encoder.
        for _ in 0..<16 { writer.advanceScreen(at: .zero) }
        writer.append(dropped, sourceID: "screen", kind: .screen)
        gate.signal()
        try await writer.stop()
        let stats = await writer.statistics()
        XCTAssertEqual(stats.droppedAdmissionEvents, 1)
        XCTAssertEqual(stats.recentLosses?.first?.kind, .screen)
        XCTAssertEqual(stats.recentLosses?.first?.durationMicroseconds, 0)
        XCTAssertTrue(collected.failures.isEmpty)
    }

    nonisolated private func blockQueue(_ writer: RecordingMediaWriter) async -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.queue.async { continuation.resume(); release.wait() }
        }
        return release
    }

    nonisolated private func assertMarker(in segments: [RecordingSegment], directory: URL, expectedTime: Double, scenario: String) async throws {
        var firstMarker: Double?
        for segment in segments.sorted(by: { $0.timelineStartMicroseconds < $1.timelineStartMicroseconds }) {
            let asset = AVURLAsset(url: directory.appendingPathComponent(segment.relativePath))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            while let sample = output.copyNextSampleBuffer() {
                let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
                var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                let status = values.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                XCTAssertEqual(status, noErr)
                if let index = values.firstIndex(where: { abs($0) > 0.2 }) {
                    let time = Double(segment.timelineStartMicroseconds) / 1_000_000
                        + CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(index / 2) / 48_000
                    firstMarker = firstMarker.map { min($0, time) } ?? time
                    break
                }
            }
            reader.cancelReading()
        }
        let decodedTime = try XCTUnwrap(firstMarker)
        print("AAC_MARKER scenario=\(scenario) expectedTimelineSeconds=\(expectedTime) decodedTimelineSeconds=\(decodedTime) errorMicroseconds=\((decodedTime - expectedTime) * 1_000_000)")
        XCTAssertEqual(decodedTime, expectedTime, accuracy: 0.003,
            "Decoded marker must retain its original time; a 20ms compaction would fail this check")
    }

    nonisolated private func makeWriter(_ directory: URL, collected: Collected, interval: Double = 60) throws -> RecordingMediaWriter {
        try RecordingMediaWriter(directory: directory,
            configuration: RecordingConfiguration(screenTarget: .display(1), segmentDurationSeconds: interval), origin: .zero,
            onSegment: { collected.add($0) }, onWarning: { collected.warn($0) }, onFailure: { collected.fail($0) })
    }

    nonisolated private func drain(_ writer: RecordingMediaWriter) async {
        await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
    }

    nonisolated private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioRecordingMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private func video(at seconds: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 128, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    nonisolated private func audio(at seconds: Double, markerStart: Double? = nil) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 480 * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 480 * 8, flags: 0, blockBufferOut: &block), noErr)
        let storage = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: storage, offsetIntoDestination: 0, dataLength: 480 * 8), noErr)
        if let markerStart {
            let values = (0..<480).flatMap { index -> [Float] in
                let time = seconds + Double(index) / 48_000
                let value: Float = time >= markerStart && time < markerStart + 0.08 ? Float(sin(2 * .pi * 1_000 * time) * 0.6) : 0
                return [value, value]
            }
            let status = values.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: storage, offsetIntoDestination: 0, dataLength: bytes.count)
            }
            XCTAssertEqual(status, noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sampleSize = 8
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: storage, formatDescription: try XCTUnwrap(format), sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

nonisolated private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [RecordingSegment] = []
    private var errors: [String] = []
    private var notices: [String] = []
    var segments: [RecordingSegment] { lock.lock(); defer { lock.unlock() }; return saved }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func add(_ segment: RecordingSegment) { lock.lock(); defer { lock.unlock() }; saved.append(segment) }
    func fail(_ message: String) { lock.lock(); defer { lock.unlock() }; errors.append(message) }
    func warn(_ message: String) { lock.lock(); defer { lock.unlock() }; notices.append(message) }
}
