import Foundation
import ProsioCore

/// Tracks audio levels during a `CloudBatchTranscriptionEngine` session to opportunistically fire
/// a speculative transcription request during a detected pause, so most of the cloud round-trip
/// overlaps with the tail of the recording instead of starting cold at release. See
/// `CloudBatchTranscriptionEngine`'s doc comment for the overall design.
///
/// Driven serially from the single task that consumes the audio stream: call `noteChunk` for
/// every chunk, in arrival order, then `resultIfStillValid()` once at audio end. Not an actor —
/// there is exactly one writer (that task); `cancelInFlight()` is safe to call from elsewhere
/// only because `Task.cancel()` itself is.
final class SpeculativeFinalizer: @unchecked Sendable {
    private let transcriber: any CloudBatchTranscribing
    private let options: TranscriptionOptions
    private let maxRequests: Int
    private let pauseThreshold: TimeInterval
    private let levelThreshold: Float

    private(set) var requestsFired = 0
    private var firedForCurrentPause = false
    private var pauseStartTimestamp: TimeInterval?
    /// True whenever the audio captured so far includes speech the most recent speculative
    /// snapshot (if any) doesn't cover — i.e. that snapshot is stale. Starts `true`: with no
    /// snapshot yet, there is nothing valid to use.
    private var hasSpeechSinceLastSnapshot = true

    private(set) var inFlightTask: Task<CloudTranscript, Error>?

    init(
        transcriber: any CloudBatchTranscribing,
        options: TranscriptionOptions,
        maxRequests: Int,
        pauseThreshold: TimeInterval,
        levelThreshold: Float
    ) {
        self.transcriber = transcriber
        self.options = options
        self.maxRequests = maxRequests
        self.pauseThreshold = pauseThreshold
        self.levelThreshold = levelThreshold
    }

    /// Call for every audio chunk, in arrival order. `pcmSoFar` must be the full accumulated PCM
    /// including this chunk (used as the speculative snapshot if this chunk triggers a fire).
    func noteChunk(_ chunk: AudioChunk, pcmSoFar: Data) {
        guard chunk.level < levelThreshold else {
            // Speech (or at least above-threshold audio): any in-flight speculative request now
            // covers stale audio (it predates this speech) — cancel it and free the "one in
            // flight" slot. A later pause, if the cap allows, can fire a fresh one that does
            // cover this speech.
            if !hasSpeechSinceLastSnapshot {
                inFlightTask?.cancel()
                inFlightTask = nil
            }
            hasSpeechSinceLastSnapshot = true
            firedForCurrentPause = false
            pauseStartTimestamp = nil
            return
        }

        // Below-threshold ("pause") chunk: extend the current pause streak.
        let pauseStart = pauseStartTimestamp ?? chunk.timestamp
        pauseStartTimestamp = pauseStart
        guard !firedForCurrentPause, requestsFired < maxRequests, inFlightTask == nil else { return }
        guard chunk.timestamp - pauseStart >= pauseThreshold else { return }

        fire(pcm16: pcmSoFar)
    }

    /// At audio end: a usable speculative result — covers all audio, nothing spoken since its
    /// snapshot — awaiting it if still in flight; or `nil` if the caller should do a fresh full
    /// transcription instead (no speculative request was ever fired, the last one is stale
    /// because the user kept talking, or it failed).
    ///
    /// `inFlightTask` is an independent, unstructured `Task` (started from `fire`, not a child of
    /// the caller), so awaiting its `.value` would NOT by itself observe the caller being
    /// cancelled — `withTaskCancellationHandler` propagates that explicitly so cancelling the
    /// session doesn't hang until the speculative request's own delay/timeout elapses.
    func resultIfStillValid() async -> CloudTranscript? {
        let debugLogging = ProcessInfo.processInfo.environment["PROSIO_SPECULATIVE_DEBUG"] == "1"
        guard !hasSpeechSinceLastSnapshot, let task = inFlightTask else {
            if debugLogging {
                FileHandle.standardError.write(Data("[speculative] not usable at audio end (requestsFired=\(requestsFired))\n".utf8))
            }
            return nil
        }
        let result = await withTaskCancellationHandler {
            try? await task.value
        } onCancel: {
            task.cancel()
        }
        if debugLogging {
            FileHandle.standardError.write(Data("[speculative] used at audio end: \(result != nil) (requestsFired=\(requestsFired))\n".utf8))
        }
        return result
    }

    /// Best-effort cancellation of a stale/unneeded in-flight speculative request (e.g. the
    /// caller is about to fire a fresh full-audio request instead, or the session is being
    /// cancelled/ended with no audio).
    func cancelInFlight() {
        inFlightTask?.cancel()
    }

    private func fire(pcm16: Data) {
        firedForCurrentPause = true
        hasSpeechSinceLastSnapshot = false
        requestsFired += 1
        if ProcessInfo.processInfo.environment["PROSIO_SPECULATIVE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[speculative] fired #\(requestsFired), snapshot \(pcm16.count) bytes\n".utf8))
        }
        let wav = CloudBatchTranscriptionEngine.makeWAV(pcm16: pcm16, sampleRate: AudioFormat.pcm16Mono16k.sampleRate, channelCount: 1)
        let transcriber = transcriber
        let options = options
        inFlightTask = Task {
            try await transcriber.transcribe(wav: wav, options: options)
        }
    }
}
