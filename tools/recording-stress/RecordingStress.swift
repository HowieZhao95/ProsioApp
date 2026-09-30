import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// Synthetic media only. This executable cannot enumerate/capture a display, camera or microphone.
@main struct RecordingStress {
    static func main() async throws {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let duration = Double(value("--duration") ?? "120") ?? 120
        let width = Int(value("--width") ?? "1920") ?? 1920
        let height = Int(value("--height") ?? "1080") ?? 1080
        let fps = Int(value("--fps") ?? "30") ?? 30
        let chunk = Double(value("--segment") ?? "60") ?? 60
        guard duration >= 1, duration <= 172_800, width >= 64, height >= 64,
              width <= 1920, height <= 1920, width % 2 == 0, height % 2 == 0,
              (15...60).contains(fps), (5...60).contains(chunk) else {
            throw RecordingPlatformError.invalidState
        }
        let output = URL(fileURLWithPath: value("--output") ?? "/tmp/ProsioRecordingStress-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: output.path),
           !(try FileManager.default.contentsOfDirectory(atPath: output.path)).isEmpty {
            throw RecordingPlatformError.storage("Stress output directory must be empty.")
        }
        let collector = StressCollector()
        let configuration = RecordingConfiguration(screenTarget: .display(1),
            cameras: [RecordingSource(id: "camera-1", kind: .camera, name: "Synthetic camera 1"),
                      RecordingSource(id: "camera-2", kind: .camera, name: "Synthetic camera 2")],
            microphone: RecordingSource(id: "microphone", kind: .microphone, name: "Synthetic microphone"),
            framesPerSecond: fps, segmentDurationSeconds: chunk)
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        let writer = try RecordingMediaWriter(directory: output, configuration: configuration, origin: origin,
            onSegment: { collector.segment($0) }, onWarning: { collector.warning($0) }, onFailure: { collector.failure($0) })
        let factories = try (0..<3).map { try StressVideoFactory(width: width, height: height, angle: $0) }
        let start = ContinuousClock.now
        var videoIndex = 0
        var audioIndex = 0
        var factorySkippedFrames = 0
        var nextReport = 0.0
        var snapshots: [StressSnapshot] = []
        while true {
            let videoTime = Double(videoIndex) / Double(fps)
            let audioTime = Double(audioIndex) / 100
            let nextTime = min(videoTime, audioTime)
            if nextTime >= duration || !collector.failures.isEmpty { break }
            try await ContinuousClock().sleep(until: start.advanced(by: .seconds(nextTime)))
            let timestamp = origin + CMTime(seconds: nextTime, preferredTimescale: 1_000_000)
            if videoTime <= nextTime + 0.000_001 {
                for angle in 0..<3 {
                    if let sample = try factories[angle].sample(at: timestamp, index: videoIndex, fps: fps) {
                        writer.append(sample, sourceID: angle == 0 ? "screen" : "camera-\(angle)", kind: angle == 0 ? .screen : .camera)
                    } else { factorySkippedFrames += 1 }
                }
                videoIndex += 1
            }
            if audioTime <= nextTime + 0.000_001 {
                let sample = try StressAudio.sample(at: timestamp)
                writer.append(sample, sourceID: "microphone", kind: .microphone)
                writer.append(sample, sourceID: "systemAudio", kind: .systemAudio)
                audioIndex += 1
            }
            if nextTime >= nextReport {
                nextReport += 5
                snapshots.append(StressSnapshot(elapsedSeconds: nextTime, residentBytes: residentBytes(), diskBytes: diskBytes(output), statistics: await writer.statistics()))
                try write(StressReport(mode: "synthetic H264/AAC; no screen/camera/microphone access", completed: false,
                    durationSeconds: duration, width: width, height: height, fps: fps, segmentSeconds: chunk,
                    videoFramesPerSource: videoIndex, audioBuffersPerSource: audioIndex, fixtureSkippedFrames: factorySkippedFrames,
                    snapshots: snapshots, segments: collector.segments, warnings: collector.warnings,
                    failures: collector.failures), to: output.appendingPathComponent("progress.json"))
            }
        }
        do { try await writer.stop() } catch { collector.failure(error.localizedDescription) }
        snapshots.append(StressSnapshot(elapsedSeconds: duration, residentBytes: residentBytes(), diskBytes: diskBytes(output), statistics: await writer.statistics()))
        for segment in collector.segments {
            let asset = AVURLAsset(url: output.appendingPathComponent(segment.relativePath))
            if (try? await asset.load(.isPlayable)) != true { collector.failure("Unplayable finalized segment: \(segment.relativePath)") }
        }
        let report = StressReport(mode: "synthetic H264/AAC; no screen/camera/microphone access", completed: collector.failures.isEmpty,
            durationSeconds: duration, width: width, height: height, fps: fps, segmentSeconds: chunk,
            videoFramesPerSource: videoIndex, audioBuffersPerSource: audioIndex, fixtureSkippedFrames: factorySkippedFrames,
            snapshots: snapshots, segments: collector.segments, warnings: collector.warnings, failures: collector.failures)
        try write(report, to: output.appendingPathComponent("report.json"))
        print("Report: \(output.appendingPathComponent("report.json").path)")
        if !report.completed { exit(1) }
    }

    private static func write(_ report: StressReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func diskBytes(_ directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory.appendingPathComponent("media"), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

nonisolated private struct StressSnapshot: Codable {
    let elapsedSeconds: Double
    let residentBytes: UInt64
    let diskBytes: Int64
    let statistics: RecordingWriterStatistics
}

nonisolated private struct StressReport: Codable {
    let mode: String
    let completed: Bool
    let durationSeconds: Double
    let width: Int
    let height: Int
    let fps: Int
    let segmentSeconds: Double
    let videoFramesPerSource: Int
    let audioBuffersPerSource: Int
    let fixtureSkippedFrames: Int
    let snapshots: [StressSnapshot]
    let segments: [RecordingSegment]
    let warnings: [String]
    let failures: [String]
}

nonisolated private final class StressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [RecordingSegment] = []
    private var notices: [String] = []
    private var errors: [String] = []
    var segments: [RecordingSegment] { lock.lock(); defer { lock.unlock() }; return saved }
    var warnings: [String] { lock.lock(); defer { lock.unlock() }; return notices }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func segment(_ segment: RecordingSegment) { lock.lock(); defer { lock.unlock() }; saved.append(segment) }
    func warning(_ message: String) { lock.lock(); defer { lock.unlock() }; notices.append(message) }
    func failure(_ message: String) { lock.lock(); defer { lock.unlock() }; errors.append(message) }
}

/// Single producer, fixed bounded pixel-buffer pool; each published image stays immutable.
nonisolated private final class StressVideoFactory {
    private let pool: CVPixelBufferPool
    private let pattern: Data
    private let height: Int
    private let width: Int
    init(width: Int, height: Int, angle: Int) throws {
        self.width = width
        self.height = height
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw RecordingPlatformError.encoding("Synthetic pixel pool creation failed") }
        self.pool = pool
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            arc4random_buf(base, buffer.count)
        }
        pattern = bytes
    }

    func sample(at timestamp: CMTime, index: Int, fps: Int) throws -> CMSampleBuffer? {
        var pixel: CVPixelBuffer?
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxiliary, &pixel)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let image = pixel else { throw RecordingPlatformError.encoding("Synthetic pixel buffer failed") }
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            let stride = CVPixelBufferGetBytesPerRow(image)
            pattern.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else { return }
                for row in 0..<height { memcpy(base.advanced(by: row * stride), source.advanced(by: row * width * 4), width * 4) }
            }
            let row = index % height
            memset(base.advanced(by: row * stride), Int32(index % 255), min(20, height - row) * stride)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr,
              let format else { throw RecordingPlatformError.encoding("Synthetic video format failed") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw RecordingPlatformError.encoding("Synthetic video sample failed") }
        return sample
    }
}

nonisolated private enum StressAudio {
    static func sample(at timestamp: CMTime) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
            throw RecordingPlatformError.encoding("Synthetic audio format failed")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 480 * 8,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 480 * 8,
            flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw RecordingPlatformError.encoding("Synthetic audio memory failed")
        }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 480 * 8)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var size = 8
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
            throw RecordingPlatformError.encoding("Synthetic audio sample failed")
        }
        return sample
    }
}
