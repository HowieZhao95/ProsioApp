import Foundation

public protocol MeetingCloudEnhancing: Sendable {
    func submitMeeting(id: UUID, file: URL, durationSeconds: Double, languageHints: [String]) async throws -> MeetingCloudTranscript
}

/// Uploads meeting audio to Soniox with the user's key. No Prosio storage is involved.
public final class SonioxClient: MeetingCloudEnhancing, @unchecked Sendable {
    public static let consoleURL = URL(string: "https://console.soniox.com")!

    private let transport: any HTTPTransport
    private let key: @Sendable () async -> String?
    private let baseURL: URL

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        key: @escaping @Sendable () async -> String? = { KeychainStore.load(.soniox) },
        baseURL: URL = URL(string: "https://api.soniox.com/v1")!
    ) {
        self.transport = transport
        self.key = key
        self.baseURL = baseURL
    }

    public func submitMeeting(id: UUID, file: URL, durationSeconds: Double, languageHints: [String]) async throws -> MeetingCloudTranscript {
        _ = durationSeconds
        guard let secret = await key(), !secret.isEmpty else { throw ProsioError.notSignedIn }
        let audio = try Data(contentsOf: file)
        guard !audio.isEmpty else { throw ProsioError.network("meeting audio is empty") }
        guard audio.count <= 200_000_000 else { throw ProsioError.network("meeting audio is too large to upload") }

        let fileID = try await upload(audio, key: secret)
        let hints = languageHints.map { $0.split(separator: "-").first.map(String.init) ?? $0 }.filter { !$0.isEmpty }.prefix(5)
        let jobID = try await createJob(fileID: fileID, meetingID: id, hints: Array(hints), key: secret)
        let transcript = try await poll(jobID, key: secret)
        await delete(jobID, key: secret)
        return transcript
    }

    public func testKey(_ secret: String) async -> String {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        do {
            let response = try await transport.send(request)
            if response.status == 401 || response.status == 403 { return "Soniox Key 无效，或缺少转写权限。" }
            if (200..<300).contains(response.status) { return "Soniox Key 可用。" }
            return "Soniox 没有接受这把 Key（HTTP \(response.status)）。"
        } catch {
            return "无法连接 Soniox。"
        }
    }

    private func upload(_ audio: Data, key: String) async throws -> String {
        let boundary = "Prosio\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        body.append(utf8: "--\(boundary)\r\n")
        body.append(utf8: "Content-Disposition: form-data; name=\"file\"; filename=\"meeting.m4a\"\r\n")
        body.append(utf8: "Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append(utf8: "\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: baseURL.appending(path: "files"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response = try await transport.send(request)
        if response.status == 404 || response.status == 405 {
            throw ProsioError.network("Soniox file upload is unavailable")
        }
        guard (200..<300).contains(response.status),
              let id = (try? JSONDecoder().decode(IDBody.self, from: response.body).id), !id.isEmpty else {
            throw ProsioError.network("Soniox HTTP \(response.status)")
        }
        return id
    }

    private func createJob(fileID: String, meetingID: UUID, hints: [String], key: String) async throws -> String {
        let body: [String: Any] = [
            "model": "stt-async-v5",
            "file_id": fileID,
            "enable_speaker_diarization": true,
            "enable_language_identification": true,
            "language_hints": hints,
            "client_reference_id": meetingID.uuidString,
        ]
        var request = URLRequest(url: baseURL.appending(path: "transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status),
              let id = (try? JSONDecoder().decode(IDBody.self, from: response.body).id), !id.isEmpty else {
            throw ProsioError.network("Soniox HTTP \(response.status)")
        }
        return id
    }

    private func poll(_ id: String, key: String) async throws -> MeetingCloudTranscript {
        let deadline = Date().addingTimeInterval(2 * 60 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: baseURL.appending(path: "transcriptions").appending(path: id))
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let response = try await transport.send(request)
            guard (200..<300).contains(response.status),
                  let status = try? JSONDecoder().decode(StatusBody.self, from: response.body) else {
                throw ProsioError.network("Soniox HTTP \(response.status)")
            }
            switch status.status {
            case "completed":
                return try await transcript(id, key: key)
            case "error", "failed", "canceled", "cancelled":
                throw ProsioError.network("meeting cloud \(status.error_message ?? status.status)")
            default:
                try await Task.sleep(for: .seconds(4))
            }
        }
        throw ProsioError.network("meeting cloud is still processing; check again later")
    }

    private func transcript(_ id: String, key: String) async throws -> MeetingCloudTranscript {
        var request = URLRequest(url: baseURL.appending(path: "transcriptions").appending(path: id).appending(path: "transcript"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status),
              let decoded = try? JSONDecoder().decode(MeetingCloudTranscript.self, from: response.body) else {
            throw ProsioError.network("Soniox HTTP \(response.status)")
        }
        return decoded
    }

    private func delete(_ id: String, key: String) async {
        var request = URLRequest(url: baseURL.appending(path: "transcriptions").appending(path: id))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        _ = try? await transport.send(request)
    }
}

private struct IDBody: Decodable { var id: String? }
private struct StatusBody: Decodable {
    var status: String
    var error_message: String?
}

private extension Data {
    mutating func append(utf8 text: String) {
        append(Data(text.utf8))
    }
}
