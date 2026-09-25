import Foundation
import ProsioCore

/// Batches a complete recording and sends it to the cloud for one final, SMART-cleaned transcript
/// (`POST /api/transcribe` -> Gateway `google/gemini-3.5-transcribe`, non-streaming). Pairs with
/// `SpeechAnalyzerEngine` as the live on-device preview: this engine only ever yields one
/// `.final`, no `.partial`s.
/// PUBLIC API — implementation owned by speech agent.
public struct CloudBatchTranscriptionEngine: TranscriptionEngine {
    public let transcriber: any CloudBatchTranscribing
    public let model: String

    public init(transcriber: any CloudBatchTranscribing, model: String = "google/gemini-3.5-transcribe") {
        self.transcriber = transcriber
        self.model = model
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

        var pcm16 = Data()
        for await chunk in audio {
            if Task.isCancelled { throw CancellationError() }
            pcm16.append(chunk.pcm16)
        }
        try Task.checkCancellation()

        guard !pcm16.isEmpty else { throw ProsioError.emptyTranscript }

        let wav = Self.makeWAV(pcm16: pcm16, sampleRate: AudioFormat.pcm16Mono16k.sampleRate, channelCount: 1)

        let transcript: CloudTranscript
        do {
            transcript = try await transcriber.transcribe(wav: wav, options: options)
        } catch let error as ProsioError {
            throw error
        } catch is CancellationError {
            throw ProsioError.cancelled
        } catch {
            throw ProsioError.network(String(describing: error))
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
