import AVFoundation
import Foundation
import ProsioCore

/// AVAudioEngine microphone capture, resampled to `AudioFormat.pcm16Mono16k`.
/// PUBLIC API FROZEN — implementation owned by speech agent.
public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    /// Target wire format: 16 kHz, mono, Int16.
    private static let targetSampleRate: Double = AudioFormat.pcm16Mono16k.sampleRate
    /// ~50 ms per chunk at 16 kHz (800 samples).
    private static let chunkSampleCount = 800

    // All mutable state below is protected by `lock`. AVAudioEngine callbacks arrive on an
    // internal Core Audio thread, `start()`/`stop()` can be called from any thread, and the
    // configuration-change notification arrives on its own queue — so everything is guarded.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var accumulator = PCMChunkAccumulator(chunkSampleCount: AudioCapture.chunkSampleCount, sampleRate: AudioCapture.targetSampleRate)
    private var configChangeObserver: NSObjectProtocol?
    private var isStopped = true
    private var tapInstalled = false

    public init() {}

    public func start() throws -> AsyncStream<AudioChunk> {
        try Self.checkMicrophonePermission()

        // Idempotent-ish: if already running, tear down the previous session first.
        stop()

        let engine = AVAudioEngine()

        lock.lock()
        self.engine = engine
        self.isStopped = false
        self.accumulator.reset()
        lock.unlock()

        let stream = AsyncStream<AudioChunk> { [weak self] continuation in
            self?.lock.lock()
            self?.continuation = continuation
            self?.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }

        do {
            try installTap(on: engine)
        } catch {
            teardownEngine()
            throw ProsioError.audioUnavailable("failed to configure input tap: \(error.localizedDescription)")
        }

        registerConfigurationChangeObserver(for: engine)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardownEngine()
            throw ProsioError.audioUnavailable("failed to start audio engine: \(error.localizedDescription)")
        }

        return stream
    }

    public func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let pendingChunk = accumulator.flush()
        let cont = continuation
        continuation = nil
        lock.unlock()

        if let pendingChunk {
            emit(samples: pendingChunk.samples, timestamp: pendingChunk.timestamp, to: cont)
        }

        teardownEngine()
        cont?.finish()
    }

    // MARK: - Permission

    private static func checkMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted, .notDetermined:
            throw ProsioError.microphonePermissionDenied
        @unknown default:
            throw ProsioError.microphonePermissionDenied
        }
    }

    // MARK: - Engine wiring

    private func installTap(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw ProsioError.audioUnavailable("no input device available")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw ProsioError.audioUnavailable("failed to construct target audio format")
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw ProsioError.audioUnavailable("failed to construct audio converter")
        }

        lock.lock()
        self.converter = converter
        self.targetFormat = targetFormat
        lock.unlock()

        // Tap buffer size: ~50 ms of hardware-rate audio per callback.
        let tapBufferSize = AVAudioFrameCount(max(1, hardwareFormat.sampleRate * 0.05))

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }
        tapInstalled = true
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !isStopped, let converter, let targetFormat, let continuation else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(convertedFrameCapacity(
                inputFrames: Int(buffer.frameLength),
                inputRate: buffer.format.sampleRate,
                outputRate: targetFormat.sampleRate
            ))
        ) else { return }

        // `convert(to:error:withInputFrom:)` calls this block synchronously on the current
        // thread while it runs — it is not truly concurrent — but the imported ObjC signature
        // is `@Sendable`, so non-Sendable captures (`AVAudioPCMBuffer`, `Bool`) are boxed to
        // satisfy strict concurrency checking without changing behavior.
        let suppliedBox = UncheckedBox(false)
        let bufferBox = UncheckedBox(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedBox.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedBox.value = true
            inputStatus.pointee = .haveData
            return bufferBox.value
        }

        guard status != .error, conversionError == nil else { return }
        guard outputBuffer.frameLength > 0, let int16Data = outputBuffer.int16ChannelData else { return }

        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: int16Data[0], count: frameCount))

        lock.lock()
        let readyChunks = accumulator.append(samples)
        lock.unlock()

        for chunk in readyChunks {
            emit(samples: chunk.samples, timestamp: chunk.timestamp, to: continuation)
        }
    }

    private func emit(samples: [Int16], timestamp: TimeInterval, to continuation: AsyncStream<AudioChunk>.Continuation?) {
        guard let continuation, !samples.isEmpty else { return }
        let data = int16SamplesToLittleEndianData(samples)
        let level = meteringLevel(forInt16Samples: samples)
        continuation.yield(AudioChunk(pcm16: data, level: level, timestamp: timestamp))
    }

    // MARK: - Device configuration changes (e.g. AirPods connect/disconnect)

    private func registerConfigurationChangeObserver(for engine: AVAudioEngine) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        lock.lock()
        configChangeObserver = observer
        lock.unlock()
    }

    private func handleConfigurationChange() {
        lock.lock()
        guard !isStopped, let engine else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Rebuild the tap/converter against the (possibly new) hardware format and keep the
        // same stream going, per contract. Best-effort: AsyncStream has no error channel, so an
        // unrecoverable failure here ends the stream rather than surfacing a typed error.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        do {
            try installTap(on: engine)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            stop()
        }
    }

    private func teardownEngine() {
        lock.lock()
        let engine = self.engine
        let observer = configChangeObserver
        let hadTap = tapInstalled
        self.engine = nil
        self.converter = nil
        self.targetFormat = nil
        self.configChangeObserver = nil
        self.tapInstalled = false
        lock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if hadTap {
            engine?.inputNode.removeTap(onBus: 0)
        }
        engine?.stop()
    }
}
