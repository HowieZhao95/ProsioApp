import Foundation
import ProsioCore

/// Fake `CloudBatchTranscribing` for `CloudBatchTranscriptionEngine` tests: returns a fixed
/// `CloudTranscript` or throws a fixed error, records every call (including the WAV bytes and
/// options it was given) and whether/how many times `prewarm()` was called.
final class FakeCloudBatchTranscribing: CloudBatchTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _transcribeCallCount = 0
    private var _prewarmCallCount = 0
    private var _lastWAV: Data?
    private var _lastOptions: TranscriptionOptions?

    private let result: CloudTranscript?
    private let error: Error?
    /// Optional delay before `transcribe` returns/throws — lets tests exercise cancellation
    /// while a "network" call is in flight.
    private let transcribeDelay: Duration?

    var transcribeCallCount: Int { lock.withLock { _transcribeCallCount } }
    var prewarmCallCount: Int { lock.withLock { _prewarmCallCount } }
    var lastWAV: Data? { lock.withLock { _lastWAV } }
    var lastOptions: TranscriptionOptions? { lock.withLock { _lastOptions } }

    init(result: CloudTranscript, transcribeDelay: Duration? = nil) {
        self.result = result
        self.error = nil
        self.transcribeDelay = transcribeDelay
    }

    init(error: Error, transcribeDelay: Duration? = nil) {
        self.result = nil
        self.error = error
        self.transcribeDelay = transcribeDelay
    }

    func transcribe(wav: Data, options: TranscriptionOptions) async throws -> CloudTranscript {
        lock.withLock {
            _transcribeCallCount += 1
            _lastWAV = wav
            _lastOptions = options
        }
        if let transcribeDelay {
            try await Task.sleep(for: transcribeDelay)
        }
        if let error { throw error }
        guard let result else { throw ProsioError.network("FakeCloudBatchTranscribing misconfigured") }
        return result
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
