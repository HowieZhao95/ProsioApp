import AVFoundation
import CoreMedia
import ScreenCaptureKit

nonisolated final class RecordingScreenReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: RecordingMediaWriter
    let microphoneID: String
    let onFailure: @Sendable (String) -> Void
    let onScreenAvailability: @Sendable (Bool) -> Void
    private var screenAvailable = true
    private var screenFrames = RecordingScreenFrameRelay()
    private let lock = NSLock()
    private var stopping = false

    init(writer: RecordingMediaWriter, microphoneID: String, onFailure: @escaping @Sendable (String) -> Void, onScreenAvailability: @escaping @Sendable (Bool) -> Void) {
        self.writer = writer
        self.microphoneID = microphoneID
        self.onFailure = onFailure
        self.onScreenAvailability = onScreenAvailability
    }

    func beginStopping() { lock.lock(); stopping = true; lock.unlock() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); let inactive = stopping; lock.unlock()
        guard !inactive else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int else { return }
            if status == SCFrameStatus.complete.rawValue {
                changeAvailability(true)
                screenFrames.acceptComplete(sampleBuffer)
                writer.append(sampleBuffer, sourceID: "screen", kind: .screen)
            } else if status == SCFrameStatus.idle.rawValue,
                      let frame = screenFrames.idleFrame(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) {
                // Each receiver owns its last complete frame. A fresh receiver never reuses a failed stream's image.
                writer.append(frame, sourceID: "screen", kind: .screen)
            } else if status == SCFrameStatus.suspended.rawValue || status == SCFrameStatus.blank.rawValue {
                changeAvailability(false)
            } else if status == SCFrameStatus.stopped.rawValue {
                lock.lock(); let expected = stopping; lock.unlock()
                if !expected { onFailure("屏幕来源已停止，已完成的原片仍可使用。") }
            }
        case .audio: writer.append(sampleBuffer, sourceID: "systemAudio", kind: .systemAudio)
        case .microphone: writer.append(sampleBuffer, sourceID: microphoneID, kind: .microphone)
        @unknown default: break
        }
    }

    private func changeAvailability(_ available: Bool) {
        lock.lock()
        let changed = screenAvailable != available
        screenAvailable = available
        lock.unlock()
        if changed {
            writer.setSourceAvailable("screen", available)
            onScreenAvailability(available)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); let expected = stopping; lock.unlock()
        if !expected { onFailure("屏幕来源已停止：\(error.localizedDescription)") }
    }
}

/// A camera has its own session so a disconnected device cannot stop the other angle.
nonisolated final class RecordingDeviceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let sampleQueue: DispatchQueue
    let session = AVCaptureSession()
    private let clockRelay = RecordingCaptureClockRelay()
    private let source: RecordingSource
    private let writer: RecordingMediaWriter
    private let framesPerSecond: Int
    private let onDisconnect: @Sendable (String) -> Void
    private var observers: [NSObjectProtocol] = []

    init(source: RecordingSource, framesPerSecond: Int, writer: RecordingMediaWriter,
         onDisconnect: @escaping @Sendable (String) -> Void) {
        self.source = source
        self.framesPerSecond = framesPerSecond
        self.writer = writer
        self.onDisconnect = onDisconnect
        queue = DispatchQueue(label: "app.prosio.recording.device.\(source.id)")
        sampleQueue = DispatchQueue(label: "app.prosio.recording.device.frames.\(source.id)", qos: .userInitiated)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let device = try configure()
                    let center = NotificationCenter.default
                    observers = [
                        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                            guard let self else { return }; onDisconnect(source.id)
                        },
                        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                            guard let self else { return }; onDisconnect(source.id)
                        },
                        center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                            guard let self else { return }; onDisconnect(source.id)
                        }
                    ]
                    session.startRunning()
                    clockRelay.set(session.synchronizationClock)
                    guard session.isRunning else { throw RecordingPlatformError.unavailable("来源“\(source.name)”未能启动。") }
                    continuation.resume()
                } catch {
                    session.stopRunning()
                    clockRelay.set(nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure() throws -> AVCaptureDevice {
        let video = source.kind == .camera
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external], mediaType: video ? .video : .audio, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == source.deviceID && $0.isConnected }) else {
            throw RecordingPlatformError.unavailable("来源“\(source.name)”当前不可用。")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingPlatformError.unavailable("无法连接来源“\(source.name)”。") }
        session.addInput(input)
        if !video {
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(output) else { throw RecordingPlatformError.unavailable("无法读取麦克风“\(source.name)”。") }
            session.addOutput(output)
            return device
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw RecordingPlatformError.unavailable("无法读取摄像头“\(source.name)”。") }
        session.addOutput(output)
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return max(dimensions.width, dimensions.height) <= 1920 && min(dimensions.width, dimensions.height) <= 1080 &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(framesPerSecond) && $0.maxFrameRate >= Double(framesPerSecond) }
        }
        guard let selected = formats.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }) else {
            throw RecordingPlatformError.unavailable("摄像头“\(source.name)”不支持 1080p 以内的所选帧率。")
        }
        device.activeFormat = selected
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(framesPerSecond))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(framesPerSecond))
        return device
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers.removeAll()
                session.stopRunning()
                clockRelay.set(nil)
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Apple's synchronizationClock defines every capture-output timestamp for this session.
        guard let clock = clockRelay.get() else { return }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        let status = timing.withUnsafeMutableBufferPointer { CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: $0.baseAddress, entriesNeededOut: &count) }
        guard status == noErr else { return }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMSyncConvertTime(timing[index].presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMSyncConvertTime(timing[index].decodeTimeStamp, from: clock, to: CMClockGetHostTimeClock())
            }
        }
        var converted: CMSampleBuffer?
        let copied = timing.withUnsafeBufferPointer { CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress!, sampleBufferOut: &converted) }
        if copied == noErr, let converted { writer.append(converted, sourceID: source.id, kind: source.kind) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.reportDroppedFrame(source.id)
    }
}

/// CMClock is retained as an immutable reference under a lock; delegates never read session state.
nonisolated private final class RecordingCaptureClockRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: CMClock?
    func set(_ clock: CMClock?) { lock.lock(); self.clock = clock; lock.unlock() }
    func get() -> CMClock? { lock.lock(); defer { lock.unlock() }; return clock }
}

/// Accessed only on the SCStream output queue, and discarded with that stream's receiver.
nonisolated struct RecordingScreenFrameRelay {
    private var latestComplete: CMSampleBuffer?
    mutating func acceptComplete(_ sample: CMSampleBuffer) { latestComplete = sample }
    func idleFrame(at timestamp: CMTime) -> CMSampleBuffer? {
        guard let latestComplete, timestamp.isNumeric,
              timestamp >= CMSampleBufferGetPresentationTimeStamp(latestComplete) else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(latestComplete),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var frame: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: latestComplete,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &frame) == noErr else { return nil }
        return frame
    }
}
