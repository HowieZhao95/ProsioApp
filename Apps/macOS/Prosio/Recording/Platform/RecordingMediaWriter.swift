import AVFoundation
import CoreMedia
import Foundation

/// All mutable encoder state lives on one queue; delegate admission is bounded before enqueueing.
nonisolated final class RecordingMediaWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.prosio.recording.media", qos: .userInitiated)
    private let admission = NSLock()
    private var enqueued = 0
    private var lastAdmissionWarning = Date.distantPast
    private var timeline: RecordingTimeline
    private let directory: URL
    private let interval: Double
    private let names: [String: String]
    private let frameDuration: CMTime
    private let onSegment: @Sendable (RecordingSegment) async -> Void
    private let onWarning: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var active: [String: Chunk] = [:]
    private var pending: [String: Int] = [:]
    private var completions: [CheckedContinuation<Void, any Error>] = []
    private var unavailable = Set<String>()
    private var latestScreenFrame: CMSampleBuffer?
    private var stopping = false
    private var failed = false
    private var failureMessage: String?
    private var lastWarning: [String: Date] = [:]
    private var lastDiskCheck = Date.distantPast

    init(directory: URL, configuration: RecordingConfiguration, origin: CMTime,
         onSegment: @escaping @Sendable (RecordingSegment) async -> Void,
         onWarning: @escaping @Sendable (String) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.directory = directory
        var names = ["screen": "屏幕", "systemAudio": "系统声音", "microphone": "麦克风"]
        for source in configuration.cameras { names[source.id] = source.name }
        if let microphone = configuration.microphone { names[microphone.id] = microphone.name }
        self.names = names
        interval = min(60, configuration.segmentDurationSeconds)
        frameDuration = CMTime(value: 1, timescale: Int32(configuration.framesPerSecond))
        timeline = RecordingTimeline(origin: origin)
        self.onSegment = onSegment
        self.onWarning = onWarning
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Self.checkCapacity(directory)
    }

    static func checkCapacity(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
        if let available, available < 2_000_000_000 {
            throw RecordingPlatformError.storage("磁盘剩余空间不足 2 GB，已安全结束录制。")
        }
    }

    func append(_ sample: CMSampleBuffer, sourceID: String, kind: RecordingSourceKind) {
        // CMSampleBuffer is retained until this queue consumes it; it is not mutated by its producer.
        let retained = Sample(sample)
        enqueue { [self] in consume(retained.buffer, sourceID: sourceID, kind: kind) }
    }

    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        admission.lock()
        guard enqueued < 16 else {
            let warn = Date().timeIntervalSince(lastAdmissionWarning) > 2
            if warn { lastAdmissionWarning = .now }
            admission.unlock()
            if warn { onWarning("媒体写入暂时跟不上采集速度，已跳过部分帧；请降低来源数量或画面尺寸。") }
            return
        }
        enqueued += 1
        admission.unlock()
        queue.async { [self] in
            defer { admission.lock(); enqueued -= 1; admission.unlock() }
            work()
        }
    }

    func pause(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                timeline.pause(at: time)
                closeAll()
                continuation.resume()
            }
        }
    }

    func resume(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in timeline.resume(at: time); continuation.resume() }
        }
    }

    func setSourceAvailable(_ id: String, _ available: Bool) {
        queue.async { [self] in
            if available { unavailable.remove(id) }
            else {
                unavailable.insert(id)
                if let chunk = active.removeValue(forKey: id) { finish(chunk) }
            }
        }
    }

    func reportDroppedFrame(_ sourceID: String) {
        enqueue { [self] in warn("capture-drop-\(sourceID)", "\(names[sourceID] ?? "来源") 采集速度超过处理速度，部分帧被跳过。") }
    }

    /// SCStream emits idle buffers for unchanged displays. Retiming the previous complete image
    /// preserves a continuous screen track and rolls durable chunks even on a static desktop.
    func advanceScreen(at timestamp: CMTime) {
        enqueue { [self] in
            guard !stopping, !failed, timeline.offset(for: timestamp) != nil,
                  let previous = latestScreenFrame else { return }
            var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: previous,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                  let copy else { return }
            consume(copy, sourceID: "screen", kind: .screen)
        }
    }

    func checkDisk() {
        queue.async { [self] in
            guard !stopping && !failed else { return }
            do { try Self.checkCapacity(directory) } catch { fail(error.localizedDescription) }
        }
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                stopping = true
                completions.append(continuation)
                closeAll()
                resolveStopIfFinished()
            }
        }
    }

    private func consume(_ sample: CMSampleBuffer, sourceID: String, kind: RecordingSourceKind) {
        guard !stopping, !failed, !unavailable.contains(sourceID), CMSampleBufferDataIsReady(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if kind == .screen { latestScreenFrame = sample }
        guard let offset = timeline.offset(for: pts) else { return }
        if Date().timeIntervalSince(lastDiskCheck) > 2 {
            lastDiskCheck = .now
            do { try Self.checkCapacity(directory) } catch { fail(error.localizedDescription); return }
        }
        if let current = active[sourceID],
           CMTimeGetSeconds(pts - current.start) >= interval || !current.matches(sample) {
            active.removeValue(forKey: sourceID)
            finish(current)
        }
        do {
            if active[sourceID] == nil {
                guard (pending[sourceID] ?? 0) < 2 else {
                    fail("媒体分段写入持续积压，已安全结束录制，已保存片段仍可使用。")
                    return
                }
                active[sourceID] = try Chunk(sample: sample, kind: kind, sourceID: sourceID,
                                              directory: directory, offset: offset, frameDuration: frameDuration)
            }
            guard let current = active[sourceID] else { return }
            guard pts > current.lastPTS || current.sampleCount == 0 else { return }
            guard current.input.isReadyForMoreMediaData else {
                warn("backpressure-\(sourceID)", "\(names[sourceID] ?? "来源") 写入繁忙，部分帧被跳过。")
                return
            }
            guard current.input.append(sample) else {
                throw RecordingPlatformError.encoding(current.writer.error?.localizedDescription ?? "媒体编码失败。")
            }
            current.sampleCount += 1
            current.lastPTS = pts
            let duration = CMSampleBufferGetDuration(sample)
            let fallback: CMTime
            if kind == .screen || kind == .camera { fallback = frameDuration }
            else if let rate = current.nativeSampleRate { fallback = CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: Int32(rate)) }
            else { fallback = CMTime(value: 1, timescale: 100) }
            current.end = max(current.end, pts + (duration.isNumeric && duration > .zero ? duration : fallback))
        } catch { fail(error.localizedDescription) }
    }

    private func closeAll() {
        let chunks = Array(active.values)
        active.removeAll()
        for chunk in chunks { finish(chunk) }
    }

    private func finish(_ chunk: Chunk) {
        guard chunk.sampleCount > 0 else {
            chunk.writer.cancelWriting()
            try? FileManager.default.removeItem(at: chunk.temporaryURL)
            return
        }
        pending[chunk.sourceID, default: 0] += 1
        chunk.writer.endSession(atSourceTime: min(chunk.end, chunk.start + CMTime(seconds: interval, preferredTimescale: 1_000_000)))
        chunk.input.markAsFinished()
        chunk.writer.finishWriting { [self, chunk] in
            Task {
                do {
                    guard chunk.writer.status == .completed else {
                        throw RecordingPlatformError.encoding(chunk.writer.error?.localizedDescription ?? "媒体片段未能完成写入。")
                    }
                    let asset = AVURLAsset(url: chunk.temporaryURL)
                    let playable = try await asset.load(.isPlayable)
                    let duration = try await asset.load(.duration)
                    guard playable, duration.isNumeric, duration > .zero else {
                        throw RecordingPlatformError.encoding("媒体片段无法播放，已保留临时文件以便恢复。")
                    }
                    let microseconds = CMTimeConvertScale(duration, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
                    let segment = RecordingSegment(id: chunk.id, sourceID: chunk.sourceID, relativePath: chunk.relativePath,
                        timelineStartMicroseconds: chunk.offset, durationMicroseconds: microseconds,
                        width: chunk.width, height: chunk.height, sampleRate: chunk.sampleRate, channelCount: chunk.channelCount)
                    let sidecar = directory.appendingPathComponent("media/\(chunk.id.uuidString).segment.json")
                    try JSONEncoder().encode(segment).write(to: sidecar, options: .atomic)
                    try FileManager.default.moveItem(at: chunk.temporaryURL, to: chunk.finalURL)
                    await onSegment(segment)
                } catch {
                    let message = error.localizedDescription
                    queue.async { [self] in fail(message) }
                }
                queue.async { [self] in
                    pending[chunk.sourceID, default: 1] -= 1
                    resolveStopIfFinished()
                }
            }
        }
    }

    private func resolveStopIfFinished() {
        guard stopping, pending.values.allSatisfy({ $0 == 0 }) else { return }
        let waiting = completions
        completions.removeAll()
        for completion in waiting {
            if let failureMessage { completion.resume(throwing: RecordingPlatformError.encoding(failureMessage)) }
            else { completion.resume() }
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        failureMessage = message
        onFailure(message)
    }

    private func warn(_ key: String, _ message: String) {
        guard Date().timeIntervalSince(lastWarning[key] ?? .distantPast) > 2 else { return }
        lastWarning[key] = .now
        onWarning(message)
    }

    private final class Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    private final class Chunk: @unchecked Sendable {
        let id = UUID()
        let sourceID: String
        let offset: Int64
        let start: CMTime
        var lastPTS: CMTime
        var end: CMTime
        var sampleCount = 0
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let temporaryURL: URL
        let finalURL: URL
        let relativePath: String
        let width: Int?
        let height: Int?
        let nativeSampleRate: Int?
        let sampleRate: Int?
        let channelCount: Int?
        let format: CMFormatDescription

        init(sample: CMSampleBuffer, kind: RecordingSourceKind, sourceID: String, directory: URL,
             offset: Int64, frameDuration: CMTime) throws {
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                throw RecordingPlatformError.encoding("来源没有提供有效的媒体格式。")
            }
            self.format = format
            self.sourceID = sourceID
            self.offset = offset
            start = CMSampleBufferGetPresentationTimeStamp(sample)
            lastPTS = start
            end = start
            let video = kind == .screen || kind == .camera
            let fileExtension = video ? "mov" : "m4a"
            relativePath = "media/\(id.uuidString).\(fileExtension)"
            finalURL = directory.appendingPathComponent(relativePath)
            temporaryURL = directory.appendingPathComponent("media/\(id.uuidString).partial.\(fileExtension)")
            writer = try AVAssetWriter(outputURL: temporaryURL, fileType: video ? .mov : .m4a)
            let settings: [String: Any]
            if video {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                width = Int(dimensions.width)
                height = Int(dimensions.height)
                nativeSampleRate = nil
                sampleRate = nil
                channelCount = nil
                settings = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(dimensions.width),
                            AVVideoHeightKey: Int(dimensions.height), AVVideoCompressionPropertiesKey: [
                                AVVideoAverageBitRateKey: max(2_000_000, Int(dimensions.width * dimensions.height) * 4),
                                AVVideoExpectedSourceFrameRateKey: Int(1 / CMTimeGetSeconds(frameDuration)),
                                AVVideoMaxKeyFrameIntervalDurationKey: 2]]
                input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: format)
            } else {
                guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                    throw RecordingPlatformError.encoding("音频来源格式不可用。")
                }
                width = nil
                height = nil
                nativeSampleRate = Int(description.mSampleRate)
                sampleRate = description.mSampleRate == 44_100 ? 44_100 : 48_000
                channelCount = min(2, Int(description.mChannelsPerFrame))
                settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate!,
                            AVNumberOfChannelsKey: channelCount!, AVEncoderBitRateKey: channelCount == 1 ? 96_000 : 192_000]
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            }
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingPlatformError.encoding("无法创建媒体编码器。") }
            writer.add(input)
            guard writer.startWriting() else { throw RecordingPlatformError.encoding(writer.error?.localizedDescription ?? "无法开始媒体写入。") }
            writer.startSession(atSourceTime: start)
        }

        func matches(_ sample: CMSampleBuffer) -> Bool {
            guard let incoming = CMSampleBufferGetFormatDescription(sample) else { return false }
            return CMFormatDescriptionEqual(format, otherFormatDescription: incoming)
        }
    }
}
