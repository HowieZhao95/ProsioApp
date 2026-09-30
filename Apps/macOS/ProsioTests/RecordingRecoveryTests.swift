import AVFoundation
import CoreMedia
import XCTest

nonisolated final class RecordingRecoveryTests: XCTestCase {
    @MainActor func testFinalizedOrphanReceiptAdoptsOffsetAndDoesNotDuplicate() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recovered = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
        XCTAssertEqual(recovered.segments, [fixture.segment])
        XCTAssertEqual(recovered.segments.first?.timelineStartMicroseconds, 4_250_000)
        XCTAssertEqual(recovered.phase, .interrupted)
        XCTAssertFalse(recovered.warnings.isEmpty)
        let repeated = await RecordingRecovery.recover(recovered, in: fixture.directory)
        XCTAssertEqual(repeated.segments, [fixture.segment])
        XCTAssertEqual(repeated.warnings, recovered.warnings)
    }

    @MainActor func testVerifiedPartialIsRenamedAndAdopted() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let final = fixture.directory.appendingPathComponent(fixture.segment.relativePath)
        let partial = fixture.directory.appendingPathComponent("media/\(fixture.segment.id.uuidString).partial.mov")
        try FileManager.default.moveItem(at: final, to: partial)
        let recovered = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
        XCTAssertEqual(recovered.segments, [fixture.segment])
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let asset = AVURLAsset(url: final)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
    }

    @MainActor func testCorruptReceiptAndCorruptPartialAreRetainedWithoutFalseRecovery() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let final = fixture.directory.appendingPathComponent(fixture.segment.relativePath)
        let partial = fixture.directory.appendingPathComponent("media/\(fixture.segment.id.uuidString).partial.mov")
        try FileManager.default.removeItem(at: final)
        let corruptData = Data("broken MOV, not a video".utf8)
        try corruptData.write(to: partial)
        let malformedReceipt = fixture.directory.appendingPathComponent("media/invalid.segment.json")
        try Data("{ not JSON".utf8).write(to: malformedReceipt)
        let recovered = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
        XCTAssertTrue(recovered.segments.isEmpty)
        XCTAssertGreaterThanOrEqual(recovered.warnings.count, 2)
        XCTAssertEqual(try Data(contentsOf: partial), corruptData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedReceipt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    }

    @MainActor func testMissingOriginalWarnsAndCorruptListedOriginalIsRemovedButPreserved() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let final = fixture.directory.appendingPathComponent(fixture.segment.relativePath)
        try FileManager.default.removeItem(at: final)
        let missing = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
        XCTAssertTrue(missing.segments.isEmpty)
        XCTAssertFalse(missing.warnings.isEmpty)
        let corrupt = Data([0x00, 0x01, 0x02, 0x03])
        try corrupt.write(to: final)
        var listed = fixture.manifest
        listed.segments = [fixture.segment]
        listed.phase = .ready
        let recovered = await RecordingRecovery.recover(listed, in: fixture.directory)
        XCTAssertTrue(recovered.segments.isEmpty)
        XCTAssertEqual(recovered.phase, .interrupted)
        XCTAssertFalse(recovered.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: final), corrupt)
    }

    @MainActor func testUnsafeReceiptAndSymlinkCannotEscapeSession() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let outside = fixture.directory.deletingLastPathComponent().appendingPathComponent("ProsioOutside-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = Data("outside data must survive".utf8)
        try sentinel.write(to: outside)
        var unsafe = fixture.segment
        unsafe.relativePath = "../" + outside.lastPathComponent
        try JSONEncoder().encode(unsafe).write(to: receiptURL(fixture))
        let final = fixture.directory.appendingPathComponent(fixture.segment.relativePath)
        try FileManager.default.removeItem(at: final)
        let rejected = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
        XCTAssertTrue(rejected.segments.isEmpty)
        XCTAssertFalse(rejected.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        try JSONEncoder().encode(fixture.segment).write(to: receiptURL(fixture))
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: outside)
        let symlinkRejected = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
        XCTAssertTrue(symlinkRejected.segments.isEmpty)
        XCTAssertFalse(symlinkRejected.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    @MainActor func testExtremeAndNegativeReceiptTimesDoNotTrapOrLoseOriginal() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let final = fixture.directory.appendingPathComponent(fixture.segment.relativePath)
        let original = try Data(contentsOf: final)
        var overflowMedia = fixture.segment
        overflowMedia.mediaStartMicroseconds = .max
        var overflowTimeline = fixture.segment
        overflowTimeline.timelineStartMicroseconds = .max
        var negativeDuration = fixture.segment
        negativeDuration.durationMicroseconds = -1
        for invalid in [overflowMedia, overflowTimeline, negativeDuration] {
            try JSONEncoder().encode(invalid).write(to: receiptURL(fixture))
            let recovered = await RecordingRecovery.recover(fixture.manifest, in: fixture.directory)
            XCTAssertTrue(recovered.segments.isEmpty)
            XCTAssertFalse(recovered.warnings.isEmpty)
            XCTAssertEqual(try Data(contentsOf: final), original)
        }
    }

    @MainActor private func makeFixture() async throws -> RecoveryFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProsioRecordingRecoveryTests-\(UUID().uuidString)")
        let collector = RecoveryCollector()
        let writer = try RecordingMediaWriter(directory: directory,
            configuration: RecordingConfiguration(screenTarget: .display(1)), origin: .zero,
            onSegment: { collector.save($0) }, onWarning: { _ in }, onFailure: { collector.fail($0) })
        for index in 0..<12 {
            writer.append(try frame(at: 4.25 + Double(index) / 30), sourceID: "screen", kind: .screen)
            await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(2))
        }
        try await writer.stop()
        XCTAssertTrue(collector.failures.isEmpty, collector.failures.joined(separator: "; "))
        let segment = try XCTUnwrap(collector.segments.first)
        XCTAssertEqual(segment.timelineStartMicroseconds, 4_250_000)
        let manifest = RecordingSessionManifest(title: "Interrupted capture", phase: .interrupted,
            sources: [RecordingSource(id: "screen", kind: .screen, name: "Screen")])
        return RecoveryFixture(directory: directory, segment: segment, manifest: manifest)
    }

    nonisolated private func receiptURL(_ fixture: RecoveryFixture) -> URL {
        fixture.directory.appendingPathComponent("media/\(fixture.segment.id.uuidString).segment.json")
    }

    nonisolated private func frame(at seconds: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base, 70, CVPixelBufferGetDataSize(image)) }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

nonisolated private struct RecoveryFixture: Sendable {
    let directory: URL
    let segment: RecordingSegment
    let manifest: RecordingSessionManifest
}

nonisolated private final class RecoveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RecordingSegment] = []
    private var errors: [String] = []
    var segments: [RecordingSegment] { lock.lock(); defer { lock.unlock() }; return stored }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func save(_ segment: RecordingSegment) { lock.lock(); defer { lock.unlock() }; stored.append(segment) }
    func fail(_ message: String) { lock.lock(); defer { lock.unlock() }; errors.append(message) }
}
