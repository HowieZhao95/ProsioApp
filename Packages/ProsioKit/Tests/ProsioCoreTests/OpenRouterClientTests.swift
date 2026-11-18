import Foundation
import Testing
@testable import ProsioCore

private final class DoneThenHangTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse { HTTPResponse(status: 200, body: Data()) }
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"巴黎\"}}]}".utf8))
            continuation.yield(Data("data: [DONE]".utf8))
        }
    }
}

private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var responses: [HTTPResponse]
    var streamed: [Data] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if responses.isEmpty { return HTTPResponse(status: 500, body: Data()) }
        return responses.removeFirst()
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        requests.append(request)
        let lines = streamed
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

@Suite struct OpenRouterClientTests {
    @Test func missingKeyDoesNotSend() async {
        let transport = ScriptedTransport([])
        let client = OpenRouterClient(transport: transport, key: { nil })
        await #expect(throws: ProsioError.notSignedIn) {
            try await client.transcribe(wav: Data("RIFF".utf8), options: TranscriptionOptions())
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func longRecordingDoesNotSend() async {
        let transport = ScriptedTransport([])
        let client = OpenRouterClient(transport: transport, key: { "sk-test-secret" })
        let request = CloudTranscribeRequest(audioData: Data("audio".utf8), options: TranscriptionOptions(), durationSeconds: 80)
        await #expect(throws: ProsioError.transcriptionFailed("too-long")) {
            try await client.transcribe(request)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func transcriptionUsesAudioEndpoint() async throws {
        let body = Data("{\"text\":\"你好\"}".utf8)
        let transport = ScriptedTransport([HTTPResponse(status: 200, body: body)])
        let client = OpenRouterClient(
            transport: transport,
            key: { "sk-test-secret" },
            models: { OpenRouterModels() }
        )
        let transcript = try await client.transcribe(wav: Data([0, 1, 2]), options: TranscriptionOptions(languageHints: ["zh-CN"]))
        #expect(transcript.text == "你好")
        #expect(transcript.intent == nil)
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-secret")
        let json = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["model"] as? String == "google/gemini-3.5-transcribe")
        let audio = try #require(json["input_audio"] as? [String: Any])
        #expect(audio["format"] as? String == "wav")
        #expect(json["language"] as? String == "zh")
    }

    @Test func cleanLocalTranscriptSkipsGemini() async throws {
        let jev = Data(#"{"answers":{"clean":{"noul":0.95},"recognized":{"noul":0.96},"intent":{"choice":"dictate","probabilities":{"dictate":0.91}}}}"#.utf8)
        let transport = ScriptedTransport([HTTPResponse(status: 200, body: jev)])
        let client = OpenRouterClient(transport: transport, key: { "sk-test-secret" })
        let transcript = try await client.transcribe(CloudTranscribeRequest(
            audioData: Data([1]), options: TranscriptionOptions(), localTranscript: "我们明天下午开会。"
        ))
        #expect(transcript.source == "local")
        #expect(transcript.text == "我们明天下午开会。")
        #expect(transcript.intent?.intent == .dictate)
        #expect(transport.requests.map { $0.url?.path } == ["/api/alpha/decisions"])
    }

    @Test func rejectedKeyErrorOmitsSecret() async {
        let transport = ScriptedTransport([HTTPResponse(status: 401, body: Data("sk-test-secret".utf8))])
        let client = OpenRouterClient(transport: transport, key: { "sk-test-secret" })
        await #expect(throws: ProsioError.network("OpenRouter HTTP 401")) {
            try await client.transcribe(wav: Data([1]), options: TranscriptionOptions())
        }
    }

    @Test func askStopsWhenTheStreamSaysDone() async throws {
        let transport = DoneThenHangTransport()
        let client = OpenRouterClient(transport: transport, key: { "sk-test-secret" }, models: { OpenRouterModels() })
        var output = ""
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for try await delta in client.compose(ComposeRequest(mode: .ask, text: "法国的首都是哪里")) {
                    text += delta
                }
                return text
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw ProsioError.transcriptionFailed("timeout")
            }
            output = try await group.next()!
            group.cancelAll()
        }
        #expect(output == "巴黎")
    }

    @Test func composeUsesChatEndpoint() async throws {
        let body = Data("{\"choices\":[{\"message\":{\"content\":\"\\\"Hello there.\\\"\"}}]}".utf8)
        let transport = ScriptedTransport([HTTPResponse(status: 200, body: body)])
        let client = OpenRouterClient(transport: transport, key: { "sk-test-secret" }, models: { OpenRouterModels() })
        var output = ""
        for try await delta in client.compose(ComposeRequest(mode: .rewrite, text: "hello there", scene: .chat)) {
            output += delta
        }
        #expect(output == "Hello there.")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/v1/chat/completions")
        let json = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["model"] as? String == "meta/muse-ember")
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "minimal")
    }

    @Test func composeFallbackUsesHaikuWithoutTemperature() async throws {
        let empty = Data("{\"choices\":[{\"message\":{\"content\":\"\"}}]}".utf8)
        let repaired = Data("{\"choices\":[{\"message\":{\"content\":\"修好了\"}}]}".utf8)
        let transport = ScriptedTransport([
            HTTPResponse(status: 200, body: empty),
            HTTPResponse(status: 200, body: repaired),
        ])
        let client = OpenRouterClient(transport: transport, key: { "sk-test-secret" }, models: { OpenRouterModels() })
        var output = ""
        for try await delta in client.compose(ComposeRequest(mode: .rewrite, text: "hello there", scene: .chat)) {
            output += delta
        }
        #expect(output == "修好了")
        #expect(transport.requests.count == 2)
        let retry = try #require(transport.requests.last)
        let json = try #require(retry.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["model"] as? String == "anthropic/claude-haiku-5.5")
        #expect(json["temperature"] == nil)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
    }

    @Test func sanitizeDoesNotCrashOnPlainText() {
        #expect(ComposeOutput.sanitize("\"Hello there.\"") == "Hello there.")
        #expect(ComposeOutput.editDrift(output: "Revenue grew.\n```\nchart\n```", selection: "Revenue grew.", instruction: "add a chart"))
    }

    @Test func emptyVocabularyOmitsTheLine() {
        let prompt = ComposePrompts.rewrite(transcript: "Hello", scene: .general, app: nil, vocabulary: [])
        #expect(!prompt.system.contains("Keep these terms exactly"))
        #expect(prompt.system.contains("Where: this app. Scene: general."))
    }

    @Test func vocabularyLineIsPresent() {
        let prompt = ComposePrompts.rewrite(transcript: "Hello", scene: .email, app: AppContext(appName: "Mail", windowTitle: "Inbox"), vocabulary: ["Prosio"])
        #expect(prompt.system.contains("Keep these terms exactly as written: Prosio."))
        #expect(prompt.system.contains("Where: Mail — Inbox. Scene: email."))
    }

    @Test func listRepairKeepsContent() {
        let original = "以下几点：新版本上线，客服培训，加监控"
        #expect(ListFormatting.needsRepair(original))
        let repaired = "以下几点：\n- 新版本上线\n- 客服培训\n- 加监控"
        #expect(ListFormatting.passesSafetyCheck(original: original, repaired: repaired))
        #expect(!ListFormatting.passesSafetyCheck(original: original, repaired: repaired + "额外"))
    }
}

@Suite struct SonioxClientTests {
    @Test func uploadsFileThenReadsTranscript() async throws {
        let transport = ScriptedTransport([
            HTTPResponse(status: 200, body: Data("{\"id\":\"file-1\"}".utf8)),
            HTTPResponse(status: 200, body: Data("{\"id\":\"job-1\"}".utf8)),
            HTTPResponse(status: 200, body: Data("{\"status\":\"completed\"}".utf8)),
            HTTPResponse(status: 200, body: Data("{\"text\":\"会议内容\",\"tokens\":[{\"text\":\"会议内容\"}]}".utf8)),
            HTTPResponse(status: 204, body: Data()),
        ])
        let client = SonioxClient(transport: transport, key: { "soniox-secret" }, baseURL: URL(string: "https://api.soniox.com/v1")!)
        let file = FileManager.default.temporaryDirectory.appending(path: "prosio-soniox-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = try await client.submitMeeting(id: UUID(), file: file, durationSeconds: 3, languageHints: ["zh-CN"])
        #expect(transcript.text == "会议内容")
        #expect(transport.requests.map { $0.url?.path } == [
            "/v1/files", "/v1/transcriptions", "/v1/transcriptions/job-1", "/v1/transcriptions/job-1/transcript", "/v1/transcriptions/job-1",
        ])
        let create = try #require(transport.requests.dropFirst().first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: create) as? [String: Any])
        #expect(json["model"] as? String == "stt-async-v5")
        #expect(json["file_id"] as? String == "file-1")
        #expect(json["enable_speaker_diarization"] as? Bool == true)
        #expect(transport.requests.contains { $0.url?.host?.contains("amazonaws") == true } == false)
    }

    @Test func missingUploadEndpointStaysUnavailable() async {
        let transport = ScriptedTransport([HTTPResponse(status: 404, body: Data())])
        let client = SonioxClient(transport: transport, key: { "soniox-secret" })
        let file = FileManager.default.temporaryDirectory.appending(path: "prosio-soniox-\(UUID().uuidString).m4a")
        try? Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: ProsioError.network("Soniox file upload is unavailable")) {
            try await client.submitMeeting(id: UUID(), file: file, durationSeconds: 1, languageHints: [])
        }
    }
}

@Suite struct KeychainStoreTests {
    @Test func roundTripDoesNotUseTheAppService() {
        let service = "app.prosio.tests.\(UUID().uuidString)"
        defer { KeychainStore.delete(.openRouter, service: service) }
        #expect(KeychainStore.save("secret-value", account: .openRouter, service: service))
        #expect(KeychainStore.load(.openRouter, service: service) == "secret-value")
        KeychainStore.delete(.openRouter, service: service)
        #expect(KeychainStore.load(.openRouter, service: service) == nil)
    }
}
