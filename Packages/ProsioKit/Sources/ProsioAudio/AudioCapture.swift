import AVFoundation
import Foundation
import ProsioCore
import os

/// AVAudioEngine microphone capture, resampled to `AudioFormat.pcm16Mono16k`.
/// PUBLIC API FROZEN — implementation owned by speech agent.
///
/// Latency: the graph (`AVAudioEngine` + input tap + `AVAudioConverter`) is expensive to build
/// (tens of ms) and is the dominant cost of a cold `start()`. Call `prewarm()` ahead of time (e.g.
/// at app launch) to pay that cost off the hotkey-press critical path — it builds and
/// `engine.prepare()`s the graph WITHOUT starting audio I/O, so the mic indicator stays off. A
/// subsequent `start()` then only needs `engine.start()` (resume), and `stop()` only needs
/// `engine.stop()` (pause) — the graph itself stays allocated between sessions (not torn down)
/// so every `start()` after the first is "warm" this way, not just the one right after
/// `prewarm()`. See `docs/` (final report) for measured before/after numbers.
public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    /// Target wire format: 16 kHz, mono, Int16.
    private static let targetSampleRate: Double = AudioFormat.pcm16Mono16k.sampleRate
    /// ~50 ms per chunk at 16 kHz (800 samples).
    private static let chunkSampleCount = 800

    private static let logger = Logger(subsystem: "app.prosio.mac", category: "audio")

    // All mutable state below is protected by `lock`. AVAudioEngine callbacks arrive on an
    // internal Core Audio thread, `start()`/`stop()`/`prewarm()` can be called from any thread,
    // and the configuration-change notification arrives on its own queue — so everything is
    // guarded.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var accumulator = PCMChunkAccumulator(chunkSampleCount: AudioCapture.chunkSampleCount, sampleRate: AudioCapture.targetSampleRate)
    private var configChangeObserver: NSObjectProtocol?
    /// Graph exists and `engine.prepare()` has been called, but audio I/O is not running (mic
    /// indicator off). True right after `prewarm()` or `stop()`; false once `start()` has called
    /// `engine.start()`, and false again if the graph doesn't exist yet at all.
    private var isPrepared = false
    /// True only while audio I/O is actually running (between a successful `start()` and `stop()`).
    private var isRunning = false
    private var tapInstalled = false
    /// First-chunk timing: set when `start()` begins, cleared after the first chunk of the
    /// session is emitted (or on `stop()`), so only one measurement is logged per session.
    private var sessionStartInstant: ContinuousClock.Instant?

    public init() {}

    /// Builds the audio graph (input tap + converter) and calls `engine.prepare()` ahead of time,
    /// WITHOUT starting audio capture — the mic indicator stays off. Call once at app launch (and
    /// it's safe to call again any time the capture isn't currently running; a no-op if a graph is
    /// already built). Best-effort: if this fails (e.g. no input device yet), it silently leaves
    /// nothing prepared and `start()` falls back to building fresh, surfacing the real error there.
    public func prewarm() {
        lock.lock()
        guard engine == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let clock = ContinuousClock()
        let t0 = clock.now
        let engine = AVAudioEngine()
        do {
            try installTap(on: engine)
        } catch {
            Self.logger.error("prewarm: failed to install tap: \(error.localizedDescription, privacy: .public)")
            return
        }
        registerConfigurationChangeObserver(for: engine)
        let tPreTapInstall = clock.now
        engine.prepare()
        let tPrepared = clock.now

        lock.lock()
        self.engine = engine
        self.isPrepared = true
        lock.unlock()

        Self.logger.notice(
            "prewarm: tap+converter=\(Self.ms(t0, tPreTapInstall), privacy: .public)ms engine.prepare()=\(Self.ms(tPreTapInstall, tPrepared), privacy: .public)ms total=\(Self.ms(t0, tPrepared), privacy: .public)ms"
        )
    }

    public func start() throws -> AsyncStream<AudioChunk> {
        let clock = ContinuousClock()
        let t0 = clock.now
        try Self.checkMicrophonePermission()

        // Idempotent-ish: if already running, stop first. `stop()` keeps the graph allocated, so
        // this is still a warm restart afterward, not a full rebuild.
        stop()

        lock.lock()
        let existingEngine = engine
        lock.unlock()

        let engine: AVAudioEngine
        let cold: Bool
        if let existingEngine {
            // Reuse the prewarmed (or previously-stopped, still-allocated) graph: warm path.
            engine = existingEngine
            cold = false
        } else {
            // No usable graph yet (never prewarmed, and this is the first `start()` ever): build
            // one now — same work `prewarm()` would have done, just on the critical path instead
            // of ahead of it.
            cold = true
            engine = AVAudioEngine()
            do {
                try installTap(on: engine)
            } catch {
                throw ProsioError.audioUnavailable("failed to configure input tap: \(error.localizedDescription)")
            }
            registerConfigurationChangeObserver(for: engine)
            engine.prepare()
            lock.lock()
            self.engine = engine
            lock.unlock()
        }
        let tGraphReady = clock.now

        lock.lock()
        self.isPrepared = false
        self.accumulator.reset()
        self.sessionStartInstant = t0
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
            try engine.start()
        } catch {
            teardownEngine()
            throw ProsioError.audioUnavailable("failed to start audio engine: \(error.localizedDescription)")
        }
        let tEngineStarted = clock.now

        lock.lock()
        isRunning = true
        lock.unlock()

        Self.logger.notice(
            "start(): cold=\(cold, privacy: .public) graphReady=\(Self.ms(t0, tGraphReady), privacy: .public)ms engine.start()=\(Self.ms(tGraphReady, tEngineStarted), privacy: .public)ms total=\(Self.ms(t0, tEngineStarted), privacy: .public)ms"
        )

        return stream
    }

    public func stop() {
        lock.lock()
        guard isRunning || continuation != nil else {
            lock.unlock()
            return
        }
        isRunning = false
        isPrepared = true // graph stays allocated, ready for a fast warm start next time
        sessionStartInstant = nil
        let pendingChunk = accumulator.flush()
        let cont = continuation
        continuation = nil
        let engine = engine
        lock.unlock()

        if let pendingChunk {
            emit(samples: pendingChunk.samples, timestamp: pendingChunk.timestamp, to: cont)
        }

        // Halts audio I/O (mic indicator off) but deliberately does NOT tear down the graph
        // (engine/tap/converter) — that's what makes the *next* `start()` warm. Full teardown
        // only happens on an unrecoverable failure (`teardownEngine()`, called from `start()`'s
        // catch blocks).
        engine?.stop()
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
        guard isRunning, let converter, let targetFormat, let continuation else {
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

        lock.lock()
        let firstChunkStart = sessionStartInstant
        sessionStartInstant = nil
        lock.unlock()

        if let firstChunkStart {
            let elapsedMs = Self.ms(firstChunkStart, ContinuousClock.now)
            Self.logger.notice("time-to-first-chunk=\(elapsedMs, privacy: .public)ms")
        }

        let data = int16SamplesToLittleEndianData(samples)
        let level = meteringLevel(forInt16Samples: samples)
        continuation.yield(AudioChunk(pcm16: data, level: level, timestamp: timestamp))
    }

    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
        Int((end - start) / .milliseconds(1))
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
        guard isRunning, let engine else {
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

    /// Full, unrecoverable teardown — unlike `stop()`, this discards the graph entirely (only
    /// used when the graph itself failed to start and can't safely be reused).
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
        self.isPrepared = false
        self.isRunning = false
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
