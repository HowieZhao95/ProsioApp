import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Live end-to-end test for the cloud batch final-transcript engine against the real dev backend
/// `POST /api/transcribe`. Skipped unless PROSIO_LIVE_WAV is set.
///
///   PROSIO_LIVE_WAV=/path/to/16k-mono-pcm16.wav PROSIO_BACKEND=http://localhost:3123 \
///     swift test --filter LiveCloudBatchTests
///
/// Requires the Prosio dev server running with PROSIO_DEV_AUTH=1 and AI_GATEWAY_API_KEY set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_LIVE_WAV"] != nil))
struct LiveCloudBatchTests {
    @Test func transcribesWavThroughCloudBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        let wavURL = URL(fileURLWithPath: env["PROSIO_LIVE_WAV"]!)
        let backend = URL(string: env["PROSIO_BACKEND"] ?? "http://localhost:3123")!
        let vocabulary = env["PROSIO_LIVE_VOCAB"].map { $0.split(separator: ",").map(String.init) } ?? []
        let languageHints = env["PROSIO_LIVE_LOCALE"].map { [$0] } ?? []

        let pcm = try LiveAudioFixtures.pcmData(fromWAV: Data(contentsOf: wavURL))
        let transcriber = DevBackendCloudBatchTranscribing(baseURL: backend)
        let engine = CloudBatchTranscriptionEngine(transcriber: transcriber)

        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> Int { Int((clock.now - start) / .milliseconds(1)) }

        // Real-time paced 50 ms chunks (800 samples @ 16 kHz), like the microphone would deliver.
        let chunkBytes = 800 * 2
        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream()
        let feeder = Task {
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkBytes, pcm.count)
                continuation.yield(AudioChunk(pcm16: pcm.subdata(in: offset..<end), level: 0.5, timestamp: Double(offset) / 32_000))
                offset = end
                try? await Task.sleep(for: .milliseconds(50))
            }
            continuation.finish()
        }
        await feeder.value
        let audioEndMs = ms()

        var final: String?
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions(mode: .smart, vocabulary: vocabulary, languageHints: languageHints)) {
            switch event {
            case .partial:
                Issue.record("CloudBatchTranscriptionEngine must not yield .partial")
            case .final(let text):
                final = text
            }
        }
        let doneMs = ms()
        print("LIVE CLOUD BATCH: audio=\(Double(pcm.count) / 32_000)s audioSentAt=\(audioEndMs)ms latencyAfterAudioEnd=\(doneMs - audioEndMs)ms")
        print("LIVE CLOUD BATCH FINAL: \(final ?? "<nil>")")
        #expect(final?.isEmpty == false)
    }
}

/// Mints tokens via the dev backend without touching the Keychain, then calls `/api/transcribe`.
/// Mirrors `DevTokenProvider` in `LiveGatewayTests.swift`.
private struct DevBackendCloudBatchTranscribing: CloudBatchTranscribing {
    let baseURL: URL

    func prewarm() async {
        var request = URLRequest(url: baseURL.appending(path: "api/transcribe"))
        request.httpMethod = "HEAD"
        _ = try? await URLSession.shared.data(for: request)
    }

    func transcribe(wav: Data, options: TranscriptionOptions) async throws -> CloudTranscript {
        let sessionToken = try await devSessionToken()

        var request = URLRequest(url: baseURL.appending(path: "api/transcribe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "audio": wav.base64EncodedString(),
            "mode": options.mode.rawValue,
            "vocabulary": options.vocabulary,
            "languageHints": options.languageHints,
            "sessionID": UUID().uuidString,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProsioError.network(String(decoding: data, as: UTF8.self))
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return CloudTranscript(
            text: json["text"] as! String,
            language: json["language"] as? String,
            durationSeconds: json["durationSeconds"] as? Double
        )
    }

    private func devSessionToken() async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/auth/dev"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": "live-test@prosio.app"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProsioError.network(String(decoding: data, as: UTF8.self))
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["sessionToken"] as! String
    }
}
