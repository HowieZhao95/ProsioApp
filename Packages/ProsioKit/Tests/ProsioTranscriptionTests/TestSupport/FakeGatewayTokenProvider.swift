import Foundation
import ProsioCore

/// Fake `GatewayTokenProviding` for engine-flow tests: either returns a fixed token or throws a
/// fixed error, and records every call.
final class FakeGatewayTokenProvider: GatewayTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastModel: String?

    private let token: GatewayToken?
    private let error: Error?
    private let delay: Duration?

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    var lastModel: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastModel
    }

    init(token: GatewayToken, delay: Duration? = nil) {
        self.token = token
        self.error = nil
        self.delay = delay
    }

    init(error: Error) {
        self.token = nil
        self.error = error
        self.delay = nil
    }

    func token(for model: String) async throws -> GatewayToken {
        lock.withLock {
            _callCount += 1
            _lastModel = model
        }

        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error {
            throw error
        }
        guard let token else {
            throw ProsioError.network("FakeGatewayTokenProvider misconfigured")
        }
        return token
    }
}

/// Thread-safe accumulator for events collected from a background consumer `Task` in tests.
actor CollectedEvents {
    private(set) var values: [TranscriptEvent] = []
    func append(_ event: TranscriptEvent) { values.append(event) }
}

enum TestFixtures {
    static let gatewayToken = GatewayToken(
        token: "vcst_test_token",
        url: URL(string: "wss://ai-gateway.vercel.sh/v4/ai/transcription-model?ai-model-id=google%2Fgemini-3.5-transcribe-live")!,
        model: ModelID.cloudTranscribe,
        expiresAt: Date(timeIntervalSinceNow: 60)
    )

    static func audioChunk(pcm16 samples: [Int16] = [1, 2, 3, 4], level: Float = 0.5, timestamp: TimeInterval = 0) -> AudioChunk {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let unsigned = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: unsigned))
            data.append(UInt8(truncatingIfNeeded: unsigned >> 8))
        }
        return AudioChunk(pcm16: data, level: level, timestamp: timestamp)
    }
}
