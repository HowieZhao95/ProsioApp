import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// GUI acceptance fixture only: no real device, screen, microphone, permission or playback APIs.
/// Empty preview sessions exercise layer binding; all files are generated only during stop.
@MainActor final class FixtureRecordingEngine: RecordingEngineControlling, RecordingCameraPreviewProviding {
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    private(set) var eventLog: [String] = []
    private(set) var configuration: RecordingConfiguration?
    private(set) var directory: URL?
    private enum State { case idle, active, stopping, stopped }
    private var state = State.idle
    private var generation: UUID?
    private var previewSessions: [String: AVCaptureSession] = [:]
    private var stopTask: Task<Void, any Error>?
    private var lastFailure: String?

    func start(configuration: RecordingConfiguration, directory: URL) async throws {
        try Task.checkCancellation()
        guard state == .idle || state == .stopped else { throw RecordingPlatformError.invalidState }
        try configuration.validate()
        self.configuration = configuration
        self.directory = directory
        generation = UUID()
        state = .active
        stopTask = nil
        lastFailure = nil
        eventLog.removeAll()
        // Constructing an input-free session does not discover/open devices or start capture.
        previewSessions = Dictionary(uniqueKeysWithValues: configuration.cameras.map { ($0.id, AVCaptureSession()) })
        event("start: SYNTHETIC fixture only; no inputs, device capture or permissions; directory=\(directory.path)")
        for (id, _) in Self.sources(configuration) { onSourceStatus?(id, true) }
    }

    func previewSession(for sourceID: String) -> AVCaptureSession? { previewSessions[sourceID] }

    func pause() async throws {
        guard state == .active else { throw RecordingPlatformError.invalidState }
        event("pause: SYNTHETIC UI state only; no capture")
    }

    func resume() async throws {
        guard state == .active else { throw RecordingPlatformError.invalidState }
        event("resume: SYNTHETIC UI state only; no capture")
    }

    func stop() async throws {
        if let stopTask { try await stopTask.value; return }
        guard state == .active, let configuration, let directory, let token = generation else { return }
        state = .stopping
        event("stop: generating 2 seconds of SYNTHETIC 640x360 video / 48k stereo audio using production writer")
        let task = Task { @MainActor in
            do {
                try await self.writeSyntheticMedia(configuration: configuration, directory: directory, token: token)
                self.event("stop.completed: all SYNTHETIC files finished; not evidence of real capture or AV sync")
            } catch {
                self.reportFailure(error.localizedDescription)
                self.event("stop.failed: SYNTHETIC encoding error: \(error.localizedDescription)")
                self.finish(configuration)
                throw error
            }
            self.finish(configuration)
        }
        stopTask = task
        // Joiners receive the same completion/error; caller cancellation cannot abandon media finalization.
        try await task.value
    }

    private func finish(_ configuration: RecordingConfiguration) {
        previewSessions.removeAll()
        generation = nil
        state = .stopped
        for (id, _) in Self.sources(configuration) { onSourceStatus?(id, false) }
    }

    private func writeSyntheticMedia(configuration: RecordingConfiguration, directory: URL, token: UUID) async throws {
        var settings = configuration
        // The production writer accepts this internal interval; client configuration remains unchanged.
        settings.framesPerSecond = 30
        settings.segmentDurationSeconds = 2
        let writer = try RecordingMediaWriter(directory: directory, configuration: settings, origin: .zero,
            onSegment: { [weak self] segment in
                await MainActor.run {
                    guard let self, self.generation == token else { return }
                    self.event("segment: SYNTHETIC source=\(segment.sourceID) path=\(segment.relativePath) startUs=\(segment.timelineStartMicroseconds) durationUs=\(segment.durationMicroseconds)")
                    self.onSegment?(segment)
                }
            }, onWarning: { [weak self] warning in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.event("writer.warning: \(warning)")
                    self.onWarning?(warning)
                }
            }, onFailure: { [weak self] failure in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.reportFailure(failure)
                }
            })
        do {
            // This tracked background job only generates pixels/PCM; it cannot touch native devices.
            try await Task.detached(priority: .userInitiated) {
                try await Self.generate(configuration: configuration, writer: writer)
            }.value
            try await writer.stop()
            let stats = await writer.statistics()
            event("writer.stats: written=\(stats.writtenSamples) segments=\(stats.finalizedSegments) admissionDrops=\(stats.droppedAdmissionEvents) encoderDrops=\(stats.droppedEncoderSamples)")
            guard stats.droppedAdmissionEvents == 0, stats.droppedEncoderSamples == 0 else {
                throw Self.error("合成 fixture 写盘发生丢帧，本次不能作为完整媒体证据。")
            }
            guard stats.finalizedSegments == Self.sources(configuration).count else {
                throw Self.error("合成 fixture 有来源没有完成片段。")
            }
        } catch {
            // Preserve playable completed files even when sample construction/encoding fails.
            try? await writer.stop()
            throw error
        }
    }

    private func event(_ message: String) { eventLog.append(message); onEvent?(message) }
    private func reportFailure(_ message: String) {
        guard lastFailure != message else { return }
        lastFailure = message
        onFailure?(message)
    }
    private static func sources(_ configuration: RecordingConfiguration) -> [(String, RecordingSourceKind)] {
        var result: [(String, RecordingSourceKind)] = [("screen", .screen)] + configuration.cameras.map { ($0.id, .camera) }
        if let mic = configuration.microphone { result.append((mic.id, .microphone)) }
        if configuration.capturesSystemAudio { result.append(("systemAudio", .systemAudio)) }
        return result
    }
    nonisolated private static func drain(_ writer: RecordingMediaWriter) async {
        await withCheckedContinuation { continuation in writer.queue.async { continuation.resume() } }
    }
    nonisolated private static func generate(configuration: RecordingConfiguration, writer: RecordingMediaWriter) async throws {
        let videos: [(String, RecordingSourceKind)] = [("screen", .screen)] + configuration.cameras.map { ($0.id, .camera) }
        var audioSources: [(String, RecordingSourceKind)] = []
        if let mic = configuration.microphone { audioSources.append((mic.id, .microphone)) }
        if configuration.capturesSystemAudio { audioSources.append(("systemAudio", .systemAudio)) }
        var nextVideo = 0
        // At most three video and two audio samples per batch, below the writer's bounded queue.
        for tick in 0..<200 {
            while nextVideo < 60, Double(nextVideo) / 30 <= Double(tick) / 100 {
                for (index, source) in videos.enumerated() {
                    writer.append(try video(frame: nextVideo, colorIndex: index), sourceID: source.0, kind: source.1)
                }
                nextVideo += 1
            }
            for source in audioSources { writer.append(try audio(tick: tick), sourceID: source.0, kind: source.1) }
            await drain(writer)
            // Backoff avoids encoder saturation; this is never a real capture clock.
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    nonisolated private static func video(frame: Int, colorIndex: Int) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), "create synthetic pixels")
        guard let pixel else { throw error("Missing synthetic pixels") }
        try check(CVPixelBufferLockBaseAddress(pixel, []), "lock synthetic pixels")
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let barX = (frame * 10) % 640
            for y in 0..<360 { for x in 0..<640 {
                let offset = y * stride + x * 4
                let bar = abs(x - barX) < 8 || y < 20
                bytes[offset] = bar ? 240 : UInt8(40 + colorIndex * 30)
                bytes[offset + 1] = bar ? 240 : UInt8(50 + (y / 40 % 2) * 30)
                bytes[offset + 2] = bar ? 240 : UInt8(90 + colorIndex * 50)
                bytes[offset + 3] = 255
            } }
        }
        try check(CVPixelBufferUnlockBaseAddress(pixel, []), "unlock synthetic pixels")
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescriptionOut: &format), "create synthetic video format")
        guard let format else { throw error("Missing synthetic video format") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample), "create synthetic video sample")
        guard let sample else { throw error("Missing synthetic video sample") }
        return sample
    }
    nonisolated private static func audio(tick: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), "create synthetic audio format")
        guard let format else { throw error("Missing synthetic audio format") }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 480 * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 480 * 8, flags: 0, blockBufferOut: &block), "create synthetic audio buffer")
        guard let block else { throw error("Missing synthetic audio buffer") }
        let values = (0..<480).flatMap { index -> [Float] in
            let value = Float(sin(2 * .pi * 440 * Double(tick * 480 + index) / 48_000) * 0.03)
            return [value, value]
        }
        let status = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count)
        }
        try check(status, "fill synthetic audio buffer")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(tick * 480), timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 8
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "create synthetic audio sample")
        guard let sample else { throw error("Missing synthetic audio sample") }
        return sample
    }
    nonisolated private static func check(_ status: Int32, _ operation: String) throws {
        guard status == 0 else { throw NSError(domain: "ProsioSyntheticUIFixture", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (\(status))"]) }
    }
    nonisolated private static func error(_ message: String) -> NSError {
        NSError(domain: "ProsioSyntheticUIFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
