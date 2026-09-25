import Foundation
import ProsioCore

/// Fake `CloudBatchTranscribing` for `CloudBatchTranscriptionEngine` tests: returns a fixed
/// `CloudTranscript` (or throws a fixed error) for every call by default, or — via the
/// closure-based initializer — arbitrary per-call behavior (different result/error/delay per
/// call, needed for speculative-finalization tests where a session can make several calls).
/// Records every call (WAV bytes + options, in order) and whether/how many times `prewarm()` was
/// called.
final class FakeCloudBatchTranscribing: CloudBatchTranscribing, @unchecked Sendable {
    struct Call: Sendable {
        let wav: Data
        let options: TranscriptionOptions
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _prewarmCallCount = 0

    private let handler: @Sendable (Data, TranscriptionOptions, Int) async throws -> CloudTranscript

    var transcribeCallCount: Int { lock.withLock { _calls.count } }
    var prewarmCallCount: Int { lock.withLock { _prewarmCallCount } }
    var calls: [Call] { lock.withLock { _calls } }
    var lastWAV: Data? { lock.withLock { _calls.last?.wav } }
    var lastOptions: TranscriptionOptions? { lock.withLock { _calls.last?.options } }

    /// `handler` receives the 0-based index of this call (in call order) alongside the wav/options,
    /// so tests can vary behavior per call (e.g. "first call is slow and speculative, second call
    /// is the fast real final").
    init(handler: @escaping @Sendable (Data, TranscriptionOptions, Int) async throws -> CloudTranscript) {
        self.handler = handler
    }

    init(result: CloudTranscript, transcribeDelay: Duration? = nil) {
        self.handler = { _, _, _ in
            if let transcribeDelay { try await Task.sleep(for: transcribeDelay) }
            return result
        }
    }

    init(error: Error, transcribeDelay: Duration? = nil) {
        self.handler = { _, _, _ in
            if let transcribeDelay { try await Task.sleep(for: transcribeDelay) }
            throw error
        }
    }

    func transcribe(wav: Data, options: TranscriptionOptions) async throws -> CloudTranscript {
        let index = lock.withLock {
            _calls.append(Call(wav: wav, options: options))
            return _calls.count - 1
        }
        return try await handler(wav, options, index)
    }

    func prewarm() async {
        lock.withLock { _prewarmCallCount += 1 }
    }
}

/// Minimal RIFF/WAVE header reader for asserting `CloudBatchTranscriptionEngine.makeWAV`'s output
/// shape in tests (deliberately independent of the production encoder).
struct ParsedWAVHeader {
    let numChannels: UInt16
    let sampleRate: UInt32
    let bitsPerSample: UInt16
    let dataSize: UInt32
    let dataOffset: Int

    init?(_ data: Data) {
        guard data.count >= 44 else { return nil }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF" else { return nil }
        guard String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        guard String(decoding: bytes[12..<16], as: UTF8.self) == "fmt " else { return nil }
        numChannels = u16(22)
        sampleRate = u32(24)
        bitsPerSample = u16(34)
        guard String(decoding: bytes[36..<40], as: UTF8.self) == "data" else { return nil }
        dataSize = u32(40)
        dataOffset = 44
    }
}
