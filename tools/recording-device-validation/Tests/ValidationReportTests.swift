import AVFoundation
import CoreMedia
import XCTest

nonisolated final class ValidationReportTests: XCTestCase {
    @MainActor func testRealSyntheticMediaInspectionAndMissingSourceAreDistinct() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioValidationReportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = ValidationMediaCollector()
        let writer = try RecordingMediaWriter(directory: directory,
            configuration: RecordingConfiguration(screenTarget: .window(10)), origin: .zero,
            onSegment: { collector.add($0) }, onWarning: { _ in }, onFailure: { collector.fail($0) })
        for frame in 0..<12 {
            writer.append(try video(at: 0.5 + Double(frame) / 30), sourceID: "screen", kind: .screen)
            await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(2))
        }
        try await writer.stop()
        XCTAssertTrue(collector.failures.isEmpty)
        let session = RecordingSessionManifest(title: "Synthetic", sources: [
            RecordingSource(id: "screen", kind: .screen, name: "Fixture"),
            RecordingSource(id: "camera-selected", kind: .camera, name: "Selected but no frames", deviceID: "test")],
            segments: collector.segments)
        let evidence = await ValidationReportInspector.inspect(session, in: directory)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.actualWidth, 64)
        XCTAssertEqual(evidence.first?.actualHeight, 64)
        XCTAssertTrue(evidence.first?.playable ?? false)
        XCTAssertGreaterThan(evidence.first?.bytes ?? 0, 100)
        let sources = ValidationReportInspector.sources(session, media: evidence)
        XCTAssertEqual(sources.first?.status, "mediaMetadataVerified")
        XCTAssertEqual(sources.last?.status, "missing")
        XCTAssertEqual(sources.last?.completedSegments, 0)
        XCTAssertNil(sources.last?.firstTimelineStartMicroseconds)
        let gaps = ValidationReportInspector.gaps(session)
        XCTAssertEqual(gaps.first?.startMicroseconds, 0)
        XCTAssertEqual(gaps.first?.endMicroseconds, 500_000)
        var report = preparationReport()
        report.media = evidence
        report.sourceEvidence = sources
        report.failures = ["Selected camera has no frames"]
        let finished = ValidationReportFinalizer.finish(report, elapsedActiveSeconds: 0.4, endedAt: .now,
            permissions: report.permissions)
        XCTAssertEqual(finished.completion, "failed")
        XCTAssertEqual(finished.media.count, 1)
        XCTAssertEqual(finished.sourceEvidence.last?.status, "missing")
    }

    @MainActor func testPCMInspectionMeasuresDecodedAudioRatherThanSignalSchedule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioValidationAudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = ValidationMediaCollector()
        let writer = try RecordingMediaWriter(directory: directory,
            configuration: RecordingConfiguration(screenTarget: .window(10)), origin: .zero,
            onSegment: { collector.add($0) }, onWarning: { _ in }, onFailure: { collector.fail($0) })
        for frame in 0..<30 {
            writer.append(try audio(at: Double(frame) / 100), sourceID: "systemAudio", kind: .systemAudio)
            await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(2))
        }
        try await writer.stop()
        let session = RecordingSessionManifest(title: "Synthetic audio", sources: [
            RecordingSource(id: "systemAudio", kind: .systemAudio, name: "Test audio")], segments: collector.segments)
        let evidence = await ValidationReportInspector.inspect(session, in: directory)
        let signal = try XCTUnwrap(evidence.first?.audioSignal)
        XCTAssertGreaterThan(signal.decodedSamples, 0)
        XCTAssertGreaterThan(signal.peakAmplitude, 0.01)
        XCTAssertGreaterThan(signal.rmsAmplitude, 0.005)
        XCTAssertEqual(evidence.first?.actualChannels, 1)
        XCTAssertEqual(evidence.first?.actualSampleRate, 48_000)
        XCTAssertTrue(signal.interpretation.contains("不证明音画同步"))
    }

    @MainActor func testMissingOrCorruptMediaCannotBecomeVerifiedEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioValidationMissingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0, 1, 2]).write(to: directory.appendingPathComponent("broken.mov"))
        let session = RecordingSessionManifest(title: "Broken", sources: [RecordingSource(id: "screen", kind: .screen, name: "Fixture")], segments: [
            RecordingSegment(sourceID: "screen", relativePath: "broken.mov", timelineStartMicroseconds: 0, durationMicroseconds: 30_000),
            RecordingSegment(sourceID: "screen", relativePath: "missing.mov", timelineStartMicroseconds: 100_000, durationMicroseconds: 30_000)])
        let evidence = await ValidationReportInspector.inspect(session, in: directory)
        XCTAssertEqual(evidence.count, 2)
        XCTAssertTrue(evidence.allSatisfy { !$0.playable && $0.error != nil })
        XCTAssertEqual(ValidationReportInspector.sources(session, media: evidence).first?.status, "notVerified")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.mov").path))
    }

    nonisolated func testFixtureHandshakeRejectsOtherProcessBundleOrZeroWindow() throws {
        let accepted = ValidationFixtureHandshake(processID: 10, windowID: 22, bundleID: "fixture", createdAt: .now, hostTimeMicroseconds: 1)
        XCTAssertNoThrow(try accepted.validate(expectedPID: 10, expectedBundleID: "fixture"))
        XCTAssertThrowsError(try accepted.validate(expectedPID: 11, expectedBundleID: "fixture"))
        XCTAssertThrowsError(try accepted.validate(expectedPID: 10, expectedBundleID: "other"))
        let zero = ValidationFixtureHandshake(processID: 10, windowID: 0, bundleID: "fixture", createdAt: .now, hostTimeMicroseconds: 1)
        XCTAssertThrowsError(try zero.validate(expectedPID: 10, expectedBundleID: "fixture"))
    }

    nonisolated func testFixtureSelfExitDecisionOnlyChecksOwnedParentIdentity() {
        XCTAssertTrue(ValidationFixtureOwner.parentIsPresent(expectedParentPID: 42, currentParentPID: 42))
        XCTAssertFalse(ValidationFixtureOwner.parentIsPresent(expectedParentPID: 42, currentParentPID: 1))
        XCTAssertFalse(ValidationFixtureOwner.parentIsPresent(expectedParentPID: 42, currentParentPID: 43))
        XCTAssertFalse(ValidationFixtureOwner.parentIsPresent(expectedParentPID: 0, currentParentPID: 0))
    }

    nonisolated func testRequiredBuildEvidenceRejectsMissingCorruptAndIncompleteIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ValidationBuildEvidence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ValidationBuildEvidence.load(from: nil))
        XCTAssertThrowsError(try ValidationBuildEvidence.load(from: url))
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try ValidationBuildEvidence.load(from: url))
        let incomplete = ValidationBuildEvidence(revision: "revision", workingTreeDirty: true,
            builtAtUTC: "2026-09-30", sourceSHA256: [:])
        try JSONEncoder().encode(incomplete).write(to: url)
        XCTAssertThrowsError(try ValidationBuildEvidence.load(from: url))
        let hashes = Dictionary(uniqueKeysWithValues: (0..<14).map { ("source\($0).swift", String(repeating: "a", count: 64)) })
        let valid = ValidationBuildEvidence(revision: "revision", workingTreeDirty: true,
            builtAtUTC: "2026-09-30", sourceSHA256: hashes)
        try JSONEncoder().encode(valid).write(to: url)
        XCTAssertEqual(try ValidationBuildEvidence.load(from: url).sourceSHA256, hashes)
    }

    nonisolated func testPermissionFailureFinalizesOptionalReportWithoutOverlappingAccess() throws {
        var storedReport: ValidationReport? = preparationReport()
        storedReport?.failures = ["屏幕录制权限尚未可用"]
        let endedAt = Date(timeIntervalSince1970: 100)
        for _ in 0..<1_000 {
            let snapshot = try XCTUnwrap(storedReport)
            let finalized = ValidationReportFinalizer.finish(snapshot, elapsedActiveSeconds: 0,
                endedAt: endedAt, permissions: snapshot.permissions)
            storedReport = finalized
        }
        let result = try XCTUnwrap(storedReport)
        XCTAssertEqual(result.completion, "failed")
        XCTAssertNil(result.fixture)
        XCTAssertNil(result.session)
        XCTAssertTrue(result.media.isEmpty)
        XCTAssertEqual(result.failures, ["屏幕录制权限尚未可用"])
        XCTAssertEqual(result.elapsedActiveSeconds, 0)
        XCTAssertEqual(result.endedAt, endedAt)
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(ValidationReport.self, from: data).completion, "failed")
    }

    nonisolated func testCancelledPreparationFinalizesWithoutClaimingMediaVerified() {
        let report = preparationReport()
        let finished = ValidationReportFinalizer.finish(report, elapsedActiveSeconds: 0, endedAt: .now,
            permissions: report.permissions)
        XCTAssertEqual(finished.completion, "cancelledBeforeCapture")
        XCTAssertNil(finished.fixture)
        XCTAssertTrue(finished.media.isEmpty)
    }

    nonisolated private func preparationReport() -> ValidationReport {
        ValidationReport(attemptID: UUID(), startedAt: .now, operatingSystem: "Test",
            validationBundleID: "test", fixtureBundleID: "fixture", build: nil,
            requestedDurationSeconds: 30, selectedCameras: [], selectedMicrophone: nil,
            requestedSystemAudio: false, permissions: ValidationPermissionSnapshot(screen: false,
                camera: "未请求", microphone: "未请求"))
    }

    nonisolated private func video(at seconds: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base, 120, CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    nonisolated private func audio(at seconds: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 480 * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 480 * 4, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        let values = (0..<480).map { Float(sin(2 * .pi * 440 * (Double($0) / 48_000 + seconds)) * 0.03) }
        let copied = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: 480 * 4) }
        XCTAssertEqual(copied, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleCount: 480, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

nonisolated private final class ValidationMediaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [RecordingSegment] = []
    private var errors: [String] = []
    var segments: [RecordingSegment] { lock.lock(); defer { lock.unlock() }; return saved }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func add(_ segment: RecordingSegment) { lock.lock(); defer { lock.unlock() }; saved.append(segment) }
    func fail(_ error: String) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
}
