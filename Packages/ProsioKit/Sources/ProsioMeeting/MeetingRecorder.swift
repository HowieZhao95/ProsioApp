import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct MeetingAudioFiles: Sendable {
    public let microphone: URL
    public let system: URL?
    public let microphoneOffset: TimeInterval
    public let systemOffset: TimeInterval?
    public let warning: String?
    public init(microphone: URL, system: URL?, microphoneOffset: TimeInterval,
                systemOffset: TimeInterval?, warning: String?) {
        self.microphone = microphone
        self.system = system
        self.microphoneOffset = microphoneOffset
        self.systemOffset = systemOffset
        self.warning = warning
    }
}

public enum MeetingError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

/// Owns a pair of disk-backed audio tracks. Screen audio is optional: mic recording
/// continues when screen permission or the display stream is unavailable.
public final class MeetingRecorder: @unchecked Sendable {
    public var onMicrophoneFrame: (@Sendable (MeetingAudioFrame) -> Void)?
    public var onSystemFrame: (@Sendable (MeetingAudioFrame) -> Void)?
    private let engine = AVAudioEngine()
    private var microphoneFile: AVAudioFile?
    private var microphoneURL: URL?
    private var system: MeetingSystemRecorder?
    private var microphoneStartedAt: Date?
    private var systemStartedAt: Date?
    private var warning: String?
    private let microphoneFault = MeetingRecordingFault()
    private var recording = false

    public init() {}

    public func start(in directory: URL, includeSystemAudio: Bool = true) async throws {
        guard !recording else { throw MeetingError.unavailable("A recording is already active") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MeetingError.unavailable("Microphone permission is required")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = directory.appending(path: "microphone.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        microphoneFile = file
        microphoneURL = url
        let onMicrophoneFrame = self.onMicrophoneFrame
        let microphoneFault = self.microphoneFault
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [file] buffer, _ in
            do { try file.write(from: buffer) }
            catch { microphoneFault.set(error.localizedDescription) }
            if let onMicrophoneFrame, let copied = copyMeetingAudioBuffer(buffer) {
                onMicrophoneFrame(MeetingAudioFrame(copied))
            }
        }
        do {
            try engine.start()
            microphoneStartedAt = .now
            recording = true
        } catch {
            input.removeTap(onBus: 0)
            microphoneFile = nil
            throw error
        }
        if includeSystemAudio {
            do {
                let recorder = try MeetingSystemRecorder(output: directory.appending(path: "system.m4a"), onFrame: onSystemFrame)
                try await recorder.start()
                system = recorder
                systemStartedAt = .now
            } catch {
                warning = "系统声音未录入：\(error.localizedDescription)"
            }
        }
    }

    public func stop() async throws -> MeetingAudioFiles {
        guard recording, let microphoneURL, let microphoneStartedAt else {
            throw MeetingError.unavailable("No recording is active")
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        microphoneFile = nil
        recording = false
        if let error = microphoneFault.value { warning = "麦克风录音写入失败：\(error)" }
        var systemURL: URL?
        if let system {
            do {
                let finished = try await system.stop()
                systemURL = finished.url
                if finished.droppedBuffers > 0 {
                    warning = [warning, "系统声音有 \(finished.droppedBuffers) 个缓冲区未能写入。"].compactMap { $0 }.joined(separator: "\n")
                }
                if systemURL == nil {
                    warning = [warning, "未检测到系统声音；已保留麦克风录音。"].compactMap { $0 }.joined(separator: "\n")
                }
            }
            catch {
                let detail = "系统声音未保存：\(error.localizedDescription)"
                warning = [warning, detail].compactMap { $0 }.joined(separator: "\n")
            }
        }
        let result = MeetingAudioFiles(
            microphone: microphoneURL,
            system: systemURL,
            microphoneOffset: 0,
            systemOffset: systemURL == nil ? nil : systemStartedAt?.timeIntervalSince(microphoneStartedAt),
            warning: warning
        )
        self.system = nil
        self.warning = nil
        return result
    }
}

private final class MeetingRecordingFault: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    var value: String? { lock.withLock { error } }
    func set(_ value: String) { lock.withLock { if error == nil { error = value } } }
}

private func copyMeetingAudioBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
    copy.frameLength = source.frameLength
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
    let targetBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceBuffers.count == targetBuffers.count else { return nil }
    for index in 0..<sourceBuffers.count {
        guard let from = sourceBuffers[index].mData, let to = targetBuffers[index].mData else { return nil }
        memcpy(to, from, min(Int(sourceBuffers[index].mDataByteSize), Int(targetBuffers[index].mDataByteSize)))
    }
    return copy
}

private final class MeetingSystemRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let output: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "app.prosio.meeting.system-audio")
    private var stream: SCStream?
    private var started = false
    private var buffers = 0
    private var droppedBuffers = 0
    private var appendError: String?
    private let onFrame: (@Sendable (MeetingAudioFrame) -> Void)?

    init(output: URL, onFrame: (@Sendable (MeetingAudioFrame) -> Void)?) throws {
        self.output = output
        self.onFrame = onFrame
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MeetingError.unavailable("No display available") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async throws -> (url: URL?, droppedBuffers: Int) {
        if let stream { try await stream.stopCapture() }
        queue.sync { if started { input.markAsFinished() } }
        guard started else { try? FileManager.default.removeItem(at: output); return (nil, droppedBuffers) }
        await writer.finishWriting()
        if let error = appendError ?? writer.error?.localizedDescription {
            throw MeetingError.unavailable(error)
        }
        return (buffers > 0 ? output : nil, droppedBuffers)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        if !started {
            guard writer.startWriting() else {
                appendError = writer.error?.localizedDescription ?? "Audio writer failed to start"
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) { buffers += 1 }
            else { appendError = writer.error?.localizedDescription ?? "Audio writer failed" }
        } else { droppedBuffers += 1 }
        if let onFrame {
            try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                      let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate,
                                                 channels: description.mChannelsPerFrame),
                      let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer),
                      let copied = copyMeetingAudioBuffer(borrowed) else { return }
                onFrame(MeetingAudioFrame(copied))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { appendError = error.localizedDescription }
}
