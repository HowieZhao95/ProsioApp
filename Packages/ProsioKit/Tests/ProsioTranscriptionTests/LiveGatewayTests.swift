import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Live end-to-end test against the real Vercel AI Gateway. Skipped unless PROSIO_LIVE_WAV is set.
///
///   PROSIO_LIVE_WAV=/path/to/24k-mono-pcm16.wav PROSIO_BACKEND=http://localhost:3123 \
///     swift test --filter LiveGatewayTests
///
/// Requires the Prosio dev server running with PROSIO_DEV_AUTH=1 and AI_GATEWAY_API_KEY set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_LIVE_WAV"] != nil))
struct LiveGatewayTests {
    @Test func streamsWavThroughGateway() async throws {
        let env = ProcessInfo.processInfo.environment
        let wavURL = URL(fileURLWithPath: env["PROSIO_LIVE_WAV"]!)
        let backend = URL(string: env["PROSIO_BACKEND"] ?? "http://localhost:3123")!
        let vocabulary = env["PROSIO_LIVE_VOCAB"].map { $0.split(separator: ",").map(String.init) } ?? []

        let pcm = try Self.pcmData(fromWAV: Data(contentsOf: wavURL))
        let engine = GatewayTranscriptionEngine(tokenProvider: DevTokenProvider(baseURL: backend))
        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> Int { Int((clock.now - start) / .milliseconds(1)) }

        // Real-time paced 50 ms chunks, like the microphone would deliver.
        let chunkBytes = 1200 * 2
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream()
        let audioEnd = LockedValue(0)
        let feeder = Task {
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkBytes, pcm.count)
                continuation.yield(AudioChunk(pcm16: pcm.subdata(in: offset..<end), level: 0.5, timestamp: Double(offset) / 48_000))
                offset = end
                try? await Task.sleep(for: .milliseconds(50))
            }
            audioEnd.set(ms())
            continuation.finish()
        }

        var final: String?
        var firstPartial: Int?
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions(mode: .smart, vocabulary: vocabulary)) {
            switch event {
            case .partial(let text):
                firstPartial = firstPartial ?? ms()
                print("LIVE \(ms())ms partial: \(text)")
            case .final(let text):
                print("LIVE \(ms())ms FINAL: \(text)")
                final = text
            }
        }
        await feeder.value
        print("LIVE summary: audio=\(Double(pcm.count) / 48_000)s firstPartial=\(firstPartial ?? -1)ms finalAfterRelease=\(ms() - audioEnd.get())ms")
        #expect(final?.isEmpty == false)
    }

    /// Returns the payload of the WAV `data` chunk.
    static func pcmData(fromWAV wav: Data) throws -> Data {
        guard let range = wav.range(of: Data("data".utf8)) else { throw ProsioError.audioUnavailable("no data chunk") }
        return wav.subdata(in: (range.upperBound + 4)..<wav.endIndex)
    }
}

/// Mints tokens via the dev backend without touching the Keychain.
private struct DevTokenProvider: GatewayTokenProviding {
    let baseURL: URL

    func token(for model: String) async throws -> GatewayToken {
        let session = try await post("api/auth/dev", body: ["email": "live-test@prosio.app"], bearer: nil)
        let sessionToken = session["sessionToken"] as! String
        let json = try await post("api/transcribe/token", body: ["model": model], bearer: sessionToken)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return GatewayToken(
            token: json["token"] as! String,
            url: URL(string: json["url"] as! String)!,
            model: json["model"] as! String,
            expiresAt: formatter.date(from: json["expiresAt"] as! String) ?? .now.addingTimeInterval(60)
        )
    }

    private func post(_ path: String, body: [String: String], bearer: String?) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProsioError.network(String(decoding: data, as: UTF8.self))
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}
