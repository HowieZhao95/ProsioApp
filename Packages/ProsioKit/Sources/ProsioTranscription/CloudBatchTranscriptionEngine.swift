import Foundation
import ProsioCore

/// Batches a complete recording and sends it to the cloud for one final, SMART-cleaned transcript
/// (`POST /api/transcribe` -> Gateway `google/gemini-3.5-transcribe`, non-streaming). Pairs with
/// `SpeechAnalyzerEngine` as the live on-device preview: this engine only ever yields one
/// `.final`, no `.partial`s.
///
/// Speculative finalization: release->insert latency is dominated by the cloud request only
/// starting once audio ends (~1.8-2.3s warm, backend overhead ~100ms — Gemini processing
/// dominates). While audio is still streaming, a pause (`speculativePauseThreshold` of
/// below-`speculativeLevelThreshold` chunk levels, using `AudioChunk.level`/`timestamp` — no
/// separate VAD) fires a speculative transcription of all audio captured so far, overlapping most
/// of that latency with the tail of the recording instead of starting cold at release. At most
/// one speculative request is in flight at a time, capped at `maxSpeculativeRequests` per
/// session. If the user keeps talking after a speculative snapshot, that request is cancelled
/// (best-effort) and ignored — trailing silence at audio end never triggers a fresh request when
/// a still-valid speculative result already covers everything.
/// PUBLIC API — implementation owned by speech agent.
public struct CloudBatchTranscriptionEngine: TranscriptionEngine {
    public let transcriber: any CloudBatchTranscribing
    public let model: String

    /// Internal tunables (no public API surface) — see the type doc comment.
    let maxSpeculativeRequests: Int
    /// Seconds of continuous below-`speculativeLevelThreshold` `AudioChunk.level` (measured via
    /// `AudioChunk.timestamp` deltas, not wall-clock — deterministic and testable with synthetic
    /// chunks) before a pause fires a speculative request.
    let speculativePauseThreshold: TimeInterval
    let speculativeLevelThreshold: Float

    /// - Parameter speculativeFinalization: fire speculative requests at pauses to cut release→insert
    ///   latency (~0.7–1.3 s in testing). Off by default: a speculative snapshot transcribed a proper
    ///   noun differently than the full recording ("brochure" vs "Prosio"); re-evaluate on real
    ///   recordings before enabling.
    public init(transcriber: any CloudBatchTranscribing, model: String = "google/gemini-3.5-transcribe", speculativeFinalization: Bool = false) {
        self.init(
            transcriber: transcriber,
            model: model,
            maxSpeculativeRequests: speculativeFinalization ? 3 : 0,
            speculativePauseThreshold: 0.6,
            speculativeLevelThreshold: 0.08
        )
    }

    /// Test seam for tunables (shorter pause threshold, smaller cap) — the public initializer
    /// above is unchanged and uses the production defaults.
    init(
        transcriber: any CloudBatchTranscribing,
        model: String = "google/gemini-3.5-transcribe",
        maxSpeculativeRequests: Int,
        speculativePauseThreshold: TimeInterval,
        speculativeLevelThreshold: Float
    ) {
        self.transcriber = transcriber
        self.model = model
        self.maxSpeculativeRequests = maxSpeculativeRequests
        self.speculativePauseThreshold = speculativePauseThreshold
        self.speculativeLevelThreshold = speculativeLevelThreshold
    }

    public var id: String { "cloud.gemini-3.5-transcribe" }
    public var isOnDevice: Bool { false }

    public func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(audio: audio, options: options, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProsioError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        audio: AsyncStream<AudioChunk>,
        options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        // Fire-and-forget: opens/refreshes the HTTPS connection ahead of time so the real
        // request (sent once audio ends) doesn't pay connection-setup latency.
        Task { await transcriber.prewarm() }

        let speculation = SpeculativeFinalizer(
            transcriber: transcriber,
            options: options,
            maxRequests: maxSpeculativeRequests,
            pauseThreshold: speculativePauseThreshold,
            levelThreshold: speculativeLevelThreshold
        )

        var pcm16 = Data()
        for await chunk in audio {
            if Task.isCancelled {
                speculation.cancelInFlight()
                throw CancellationError()
            }
            pcm16.append(chunk.pcm16)
            speculation.noteChunk(chunk, pcmSoFar: pcm16)
        }
        try Task.checkCancellation()

        guard !pcm16.isEmpty else {
            speculation.cancelInFlight()
            throw ProsioError.emptyTranscript
        }

        let transcript: CloudTranscript
        if let speculative = await speculation.resultIfStillValid() {
            transcript = speculative
        } else {
            speculation.cancelInFlight()
            // If we got here because awaiting the speculative result was itself cancelled (not
            // because it was stale/failed for another reason), don't waste a doomed fresh network
            // call — surface cancellation immediately.
            try Task.checkCancellation()
            let wav = Self.makeWAV(pcm16: pcm16, sampleRate: AudioFormat.pcm16Mono16k.sampleRate, channelCount: 1)
            do {
                transcript = try await transcriber.transcribe(wav: wav, options: options)
            } catch let error as ProsioError {
                throw error
            } catch is CancellationError {
                throw ProsioError.cancelled
            } catch {
                throw ProsioError.network(String(describing: error))
            }
        }

        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProsioError.emptyTranscript }
        continuation.yield(.final(text))
    }

    // MARK: - WAV encoding

    /// Builds a minimal canonical RIFF/WAVE file (44-byte header, no extra chunks) wrapping
    /// `pcm16` as 16-bit signed little-endian PCM. Matches what `docs/API.md`'s `/api/transcribe`
    /// expects (base64 of a RIFF/WAVE file, 16 kHz mono PCM16).
    static func makeWAV(pcm16: Data, sampleRate: Double, channelCount: Int) -> Data {
        let bitsPerSample: UInt32 = 16
        let numChannels = UInt32(channelCount)
        let sampleRateInt = UInt32(sampleRate)
        let byteRate = sampleRateInt * numChannels * bitsPerSample / 8
        let blockAlign = UInt16(numChannels * bitsPerSample / 8)
        let dataSize = UInt32(pcm16.count)
        let riffChunkSize = 36 + dataSize

        var data = Data(capacity: 44 + pcm16.count)
        data.append(ascii: "RIFF")
        data.appendLE(riffChunkSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.appendLE(UInt32(16)) // Subchunk1Size (PCM)
        data.appendLE(UInt16(1)) // AudioFormat: 1 = PCM
        data.appendLE(UInt16(numChannels))
        data.appendLE(sampleRateInt)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(UInt16(bitsPerSample))
        data.append(ascii: "data")
        data.appendLE(dataSize)
        data.append(pcm16)
        return data
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
}
