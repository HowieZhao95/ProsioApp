import AVFoundation
import CoreMedia
import Foundation

/// All mutable encoder state lives on one queue; delegate admission is bounded before enqueueing.
nonisolated final class RecordingMediaWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.prosio.recording.media", qos: .userInitiated)
    private let admission = NSLock()
    private var enqueued = 0
    private var peakEnqueued = 0
    private var admissionDrops = 0
    private var encoderDrops = 0
    private var captureDrops = 0
    private var writtenSamples = 0
    private var finishedSegments = 0
    private var recentLosses: [RecordingSampleLoss] = [] // Retain metadata only, bounded independently of media.
    private var lossCounts: [String: [String: Int]] = [:]
    private var lastLossWarning: [String: TimeInterval] = [:]
    private var lastAdmissionWarning = Date.distantPast
    private var timeline: RecordingTimeline
    private let directory: URL
    private let interval: Double
    private let names: [String: String]
    private let frameDuration: CMTime
    private let originMicroseconds: Int64
    private let testingInputReadiness: (@Sendable (String, CMTime) -> Bool)?
    private let onSegment: @Sendable (RecordingSegment) async -> Void
    private let onWarning: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var active: [String: Chunk] = [:]
    private var audioLastAcceptedEnd: [String: CMTime] = [:]
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
         onFailure: @escaping @Sendable (String) -> Void,
         testingInputReadiness: (@Sendable (String, CMTime) -> Bool)? = nil) throws {
        self.directory = directory
        var names = ["screen": "屏幕", "systemAudio": "系统声音", "microphone": "麦克风"]
        for source in configuration.cameras { names[source.id] = source.name }
        if let microphone = configuration.microphone { names[microphone.id] = microphone.name }
        self.names = names
        interval = min(60, configuration.segmentDurationSeconds)
        frameDuration = CMTime(value: 1, timescale: Int32(configuration.framesPerSecond))
        originMicroseconds = CMTimeConvertScale(origin, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
        self.testingInputReadiness = testingInputReadiness
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
        if !enqueue({ [self] in consume(retained.buffer, sourceID: sourceID, kind: kind) }) {
            recordLoss(sample, sourceID: sourceID, kind: kind, reason: .admission)
        }
    }

    @discardableResult private func enqueue(_ work: @escaping @Sendable () -> Void) -> Bool {
        admission.lock()
        guard enqueued < 16 else {
            admissionDrops += 1
            let warn = Date().timeIntervalSince(lastAdmissionWarning) > 2
            if warn { lastAdmissionWarning = .now }
            admission.unlock()
            if warn { onWarning("媒体写入暂时跟不上采集速度，已跳过部分帧；请降低来源数量或画面尺寸。") }
            return false
        }
        enqueued += 1
        peakEnqueued = max(peakEnqueued, enqueued)
        admission.unlock()
        queue.async { [self] in
            defer { admission.lock(); enqueued -= 1; admission.unlock() }
            work()
        }
        return true
    }

    func pause(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                timeline.pause(at: time)
                closeAll(endingAt: time)
                audioLastAcceptedEnd.removeAll()
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
                audioLastAcceptedEnd[id] = nil
                if let chunk = active.removeValue(forKey: id) { finish(chunk) }
            }
        }
    }

    func reportDroppedFrame(_ sourceID: String) {
        enqueue { [self] in captureDrops += 1; warn("capture-drop-\(sourceID)", "\(names[sourceID] ?? "来源") 采集速度超过处理速度，部分帧被跳过。") }
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
                do { try persistLosses() } catch { fail(error.localizedDescription) }
                completions.append(continuation)
                closeAll()
                resolveStopIfFinished()
            }
        }
    }

    func statistics() async -> RecordingWriterStatistics {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                admission.lock()
                let drops = admissionDrops
                let peak = peakEnqueued
                let losses = recentLosses
                let counts = lossCounts
                admission.unlock()
                continuation.resume(returning: RecordingWriterStatistics(writtenSamples: writtenSamples,
                    droppedAdmissionEvents: drops, droppedEncoderSamples: encoderDrops,
                    droppedCaptureFrames: captureDrops, peakQueuedEvents: peak, finalizedSegments: finishedSegments,
                    recentLosses: losses, lossCountsBySourceAndReason: counts))
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
        if let current = active[sourceID], current.sampleCount > 0, let rate = current.nativeSampleRate,
           (kind == .microphone || kind == .systemAudio),
           pts > current.end + CMTime(value: 1, timescale: Int32(rate)) {
            // AAC packs submitted PCM densely even when its input PTS skips samples. A new file
            // anchors subsequent audio to its original host time instead of moving the hole to EOF.
            active.removeValue(forKey: sourceID)
            finish(current, endingAt: pts)
        }
        if let current = active[sourceID],
           CMTimeGetSeconds(pts - current.start) >= interval || !current.matches(sample) {
            active.removeValue(forKey: sourceID)
            finish(current, endingAt: pts)
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
            guard current.input.isReadyForMoreMediaData, testingInputReadiness?(sourceID, pts) != false else {
                encoderDrops += 1
                recordLoss(sample, sourceID: sourceID, kind: kind, reason: .encoderBackpressure)
                warn("backpressure-\(sourceID)", "\(names[sourceID] ?? "来源") 写入繁忙，部分帧被跳过。")
                // Never anchor an audio chunk to a sample that was not accepted by its encoder.
                if current.sampleCount == 0, current.nativeSampleRate != nil {
                    active.removeValue(forKey: sourceID)
                    finish(current)
                }
                return
            }
            guard current.input.append(sample) else {
                throw RecordingPlatformError.encoding(current.writer.error?.localizedDescription ?? "媒体编码失败。")
            }
            current.sampleCount += 1
            writtenSamples += 1
            current.lastPTS = pts
            let duration = CMSampleBufferGetDuration(sample)
            let fallback: CMTime
            if kind == .screen || kind == .camera { fallback = frameDuration }
            else if let rate = current.nativeSampleRate { fallback = CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: Int32(rate)) }
            else { fallback = CMTime(value: 1, timescale: 100) }
            current.end = max(current.end, pts + (duration.isNumeric && duration > .zero ? duration : fallback))
            if kind == .microphone || kind == .systemAudio {
                if let previousEnd = audioLastAcceptedEnd[sourceID], let rate = current.nativeSampleRate,
                   pts > previousEnd + CMTime(value: 1, timescale: Int32(rate)) {
                    // Report the full missing interval only once a later sample is actually accepted.
                    recordLoss(RecordingSampleLoss(sourceID: sourceID, kind: kind, reason: .timestampGap,
                        hostStartMicroseconds: Self.microseconds(previousEnd),
                        durationMicroseconds: Self.microseconds(pts - previousEnd)))
                }
                audioLastAcceptedEnd[sourceID] = current.end
            }
        } catch { fail(error.localizedDescription) }
    }

    private func closeAll(endingAt boundary: CMTime? = nil) {
        let chunks = Array(active.values)
        active.removeAll()
        for chunk in chunks { finish(chunk, endingAt: boundary) }
    }

    private func recordLoss(_ sample: CMSampleBuffer, sourceID: String, kind: RecordingSourceKind, reason: RecordingSampleLossReason) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return }
        var duration = CMSampleBufferGetDuration(sample)
        if (kind == .microphone || kind == .systemAudio), (!duration.isNumeric || duration <= .zero),
           let format = CMSampleBufferGetFormatDescription(sample),
           let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           audio.mSampleRate > 0 {
            duration = CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: Int32(audio.mSampleRate))
        }
        recordLoss(RecordingSampleLoss(sourceID: sourceID, kind: kind, reason: reason,
            hostStartMicroseconds: Self.microseconds(pts),
            durationMicroseconds: duration.isNumeric ? max(0, Self.microseconds(duration)) : 0))
    }

    private func recordLoss(_ loss: RecordingSampleLoss) {
        admission.lock()
        recentLosses.append(loss)
        if recentLosses.count > 64 { recentLosses.removeFirst(recentLosses.count - 64) }
        let key = names[loss.sourceID] == nil ? "unconfigured" : loss.sourceID
        lossCounts[key, default: [:]][loss.reason.rawValue, default: 0] += 1
        let warningKey = key + "/" + loss.reason.rawValue
        let now = ProcessInfo.processInfo.systemUptime
        let shouldWarn = now - (lastLossWarning[warningKey] ?? -.infinity) > 2
        if shouldWarn { lastLossWarning[warningKey] = now }
        admission.unlock()
        if shouldWarn {
            let audio = loss.kind == .microphone || loss.kind == .systemAudio
            let description = loss.reason == .timestampGap ? "音频出现间隙" : "写入繁忙，部分采样丢失"
            let policy = loss.reason == .timestampGap ? "已从下一真实时间建立新原片，时间线保留间隙。"
                : audio ? "已记录丢失；音频恢复时会保留原始时间间隙。" : "已记录丢失，其他来源继续写盘。"
            onWarning("来源“\(names[loss.sourceID] ?? loss.sourceID)”\(description)。\(policy)")
        }
    }

    private func persistLosses() throws {
        admission.lock()
        let report = RecordingSampleLossReport(originHostMicroseconds: originMicroseconds,
            countsBySourceAndReason: lossCounts, recentLosses: recentLosses)
        admission.unlock()
        guard !report.recentLosses.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("recording-losses.json"), options: .atomic)
    }

    private static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }

    private func finish(_ chunk: Chunk, endingAt boundary: CMTime? = nil) {
        // A final video frame can extend past the pause instant. Clip the file at the
        // shared boundary so resumed sources retain their host-clock alignment.
        let end = min(chunk.end, chunk.start + CMTime(seconds: interval, preferredTimescale: 1_000_000), boundary ?? chunk.end)
        guard chunk.sampleCount > 0, end > chunk.start else {
            chunk.writer.cancelWriting()
            try? FileManager.default.removeItem(at: chunk.temporaryURL)
            return
        }
        pending[chunk.sourceID, default: 0] += 1
        chunk.writer.endSession(atSourceTime: end)
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
                    if chunk.writer.status == .completed, FileManager.default.fileExists(atPath: chunk.finalURL.path) { finishedSegments += 1 }
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

/// Diagnostics for synthetic soak tests; no media or personal data is exposed.
nonisolated struct RecordingWriterStatistics: Codable, Sendable {
    let writtenSamples: Int
    let droppedAdmissionEvents: Int
    let droppedEncoderSamples: Int
    let droppedCaptureFrames: Int
    let peakQueuedEvents: Int
    let finalizedSegments: Int
    let recentLosses: [RecordingSampleLoss]?
    let lossCountsBySourceAndReason: [String: [String: Int]]?
}

nonisolated enum RecordingSampleLossReason: String, Codable, Sendable { case admission, encoderBackpressure, timestampGap }

nonisolated struct RecordingSampleLoss: Codable, Equatable, Sendable {
    let sourceID: String
    let kind: RecordingSourceKind
    let reason: RecordingSampleLossReason
    let hostStartMicroseconds: Int64
    let durationMicroseconds: Int64
}

/// Counts cover the session; the latest 64 metadata records are retained to keep memory bounded.
/// A timestampGap describes the same missing interval as its admission/encoder cause; do not sum both.
nonisolated struct RecordingSampleLossReport: Codable, Sendable {
    let originHostMicroseconds: Int64
    let countsBySourceAndReason: [String: [String: Int]]
    let recentLosses: [RecordingSampleLoss]
}
