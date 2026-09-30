import Foundation
import Testing
@testable import ProsioCore

/// Routes every request through a test-supplied handler instead of hitting the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Thread-safe capture of every request the stub protocol saw, for post-hoc assertions
/// (asserting from inside the protocol's own callback would run off the test's task).
final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock(); requests.append(request); lock.unlock()
    }

    func all() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

/// Polls a non-actor-isolated condition (e.g. `BackendClient.isSignedIn`, loaded off the main
/// actor in the background) until it's true or `timeout` elapses.
/// Thread-safe recorder for `BackendClient.onSignInStateChange`, which fires off the main actor.
private final class CapturedBools: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []

    var values: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: Bool) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

/// Thread-safe recorder for values observed inside `BackendClient.onSignInStateChange`.
private final class CapturedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func append(_ value: String) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

private func waitUntilTrue(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func jsonResponse(_ url: URL, status: Int, body: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    return (response, Data(body.utf8))
}

/// `URLSession` moves a request's body into `httpBodyStream` before handing it to a custom
/// `URLProtocol`, so `request.httpBody` alone is usually nil there — read the stream instead.
private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return data
}

@Suite(.serialized)
struct BackendClientTests {

    @Test func devSignInStoresTokenInInMemoryKeychain() async throws {
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)
        #expect(client.isSignedIn == false)

        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            return jsonResponse(request.url!, status: 200, body: #"{"sessionToken":"tok_abc","user":{"id":"u1","email":"a@b.com"}}"#)
        }
        defer { StubURLProtocol.handler = nil }

        try await client.devSignIn(email: "a@b.com")

        #expect(client.isSignedIn == true)
        let stored = keychain.read(service: "svc", account: "session")
        #expect(stored.flatMap { String(data: $0, encoding: .utf8) } == "tok_abc")
        #expect(capture.all().first?.url?.path == "/api/auth/dev")
    }

    @Test func devSignInPersistsEmailAlongsideTokenAndSignOutClearsBoth() async throws {
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)
        #expect(client.signedInEmail == nil)

        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: #"{"sessionToken":"tok_abc","user":{"id":"u1","email":"a@b.com"}}"#)
        }
        defer { StubURLProtocol.handler = nil }
        try await client.devSignIn(email: "a@b.com")

        #expect(client.signedInEmail == "a@b.com")
        let storedEmail = keychain.read(service: "svc", account: "session-email")
        #expect(storedEmail.flatMap { String(data: $0, encoding: .utf8) } == "a@b.com")

        // Persists across a relaunch (a fresh client reading the same store).
        let relaunched = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)
        let relaunchedEmail = await { () -> String? in
            _ = await relaunched.loadedIsSignedIn()
            return relaunched.signedInEmail
        }()
        #expect(relaunchedEmail == "a@b.com")

        client.signOut()
        #expect(client.signedInEmail == nil)
        #expect(keychain.read(service: "svc", account: "session-email") == nil)
    }

    @Test func signOutClearsKeychainAndIsSignedIn() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        // The session token is loaded from the Keychain on a background task (never synchronously
        // at init, so app launch can't block on a Keychain prompt) — poll until it lands.
        await waitUntilTrue { client.isSignedIn }
        #expect(client.isSignedIn == true)
        client.signOut()
        #expect(client.isSignedIn == false)
        #expect(keychain.read(service: "svc", account: "session") == nil)
    }

    @Test func isSignedInLoadsAsynchronouslyWithoutBlocking() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        // Constructing the client must never synchronously touch the Keychain — this call
        // returning at all (rather than hanging) is itself part of the assertion.
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        await waitUntilTrue { client.isSignedIn }
        #expect(client.isSignedIn == true)
    }

    // MARK: - loadedIsSignedIn / onSignInStateChange (fixes the "Not signed in" launch-race bug)

    @Test func loadedIsSignedInAwaitsInitialLoadWithoutPolling() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        // No `waitUntilTrue` polling here — `loadedIsSignedIn()` itself must await the initial
        // background load, which is exactly the fix for a caller reading `isSignedIn` too early.
        let signedIn = await client.loadedIsSignedIn()
        #expect(signedIn == true)
    }

    @Test func loadedIsSignedInReturnsFalseWhenNoStoredToken() async throws {
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let signedIn = await client.loadedIsSignedIn()
        #expect(signedIn == false)
    }

    @Test func onSignInStateChangeFiresAfterInitialLoadCompletes() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let received = CapturedBools()
        // Set immediately after construction — deliberately racing the initial background load, to
        // prove the callback still fires once it finishes rather than being silently missed.
        client.onSignInStateChange = { value in received.append(value) }

        await waitUntilTrue { !received.values.isEmpty }
        #expect(received.values == [true])
    }

    @Test func onSignInStateChangeReplaysImmediatelyWhenSetAfterLoadAlreadyCompleted() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        _ = await client.loadedIsSignedIn() // ensure the initial load has already finished

        let received = CapturedBools()
        client.onSignInStateChange = { value in received.append(value) }

        // No polling: a caller that registers after the load already landed must be replayed to
        // synchronously (or as good as), never left waiting for a change that already happened.
        #expect(received.values == [true])
    }

    @Test func onSignInStateChangeFiresOnDevSignInAndSignOut() async throws {
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)
        _ = await client.loadedIsSignedIn() // past the initial (signed-out) load

        let received = CapturedBools()
        client.onSignInStateChange = { value in received.append(value) }
        #expect(received.values == [false]) // replayed immediately: already-loaded, signed out

        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: #"{"sessionToken":"tok_abc","user":{"id":"u1","email":"a@b.com"}}"#)
        }
        defer { StubURLProtocol.handler = nil }
        try await client.devSignIn(email: "a@b.com")
        #expect(received.values == [false, true])

        client.signOut()
        #expect(received.values == [false, true, false])
    }

    @Test func signedInEmailIsCurrentByTheTimeOnSignInStateChangeFires() async throws {
        // "included in onSignInStateChange timing": a listener reading `signedInEmail` from inside
        // the callback must already see the new value, not the pre-transition one.
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)
        _ = await client.loadedIsSignedIn()

        let observedEmails = CapturedStrings()
        client.onSignInStateChange = { [weak client] signedIn in
            observedEmails.append(client?.signedInEmail ?? (signedIn ? "MISSING" : "nil"))
        }
        #expect(observedEmails.values == ["nil"])

        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: #"{"sessionToken":"tok_abc","user":{"id":"u1","email":"a@b.com"}}"#)
        }
        defer { StubURLProtocol.handler = nil }
        try await client.devSignIn(email: "a@b.com")
        #expect(observedEmails.values == ["nil", "a@b.com"])

        client.signOut()
        #expect(observedEmails.values == ["nil", "a@b.com", "nil"])
    }

    // MARK: - fetchUsage

    @Test func fetchUsageDecodesUsageStatus() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            return jsonResponse(
                request.url!,
                status: 200,
                body: #"{"periodStart":"2026-09-01T00:00:00Z","periodEnd":"2026-10-01T00:00:00Z","audioSecondsUsed":1234.5,"audioSecondsLimit":36000}"#
            )
        }
        defer { StubURLProtocol.handler = nil }

        let usage = try await client.fetchUsage()

        #expect(usage.audioSecondsUsed == 1234.5)
        #expect(usage.audioSecondsLimit == 36000)
        let request = try #require(capture.all().first)
        #expect(request.url?.path == "/api/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
    }

    @Test func fetchUsageDecodesNilLimit() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        StubURLProtocol.handler = { request in
            jsonResponse(
                request.url!,
                status: 200,
                body: #"{"periodStart":"2026-09-01T00:00:00Z","periodEnd":"2026-10-01T00:00:00Z","audioSecondsUsed":0}"#
            )
        }
        defer { StubURLProtocol.handler = nil }

        let usage = try await client.fetchUsage()
        #expect(usage.audioSecondsLimit == nil)
    }

    @Test func fetchUsageWithoutSessionThrowsNotSignedInWithoutHittingNetwork() async throws {
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            return jsonResponse(request.url!, status: 200, body: "{}")
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await client.fetchUsage()
            Issue.record("expected notSignedIn to be thrown")
        } catch let error as ProsioError {
            #expect(error == .notSignedIn)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(capture.all().isEmpty)
    }

    // MARK: - CloudBatchTranscribing

    @Test func transcribeSendsExpectedRequestAndDecodesResponse() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let capture = RequestCapture()
        let wav = Data("RIFF....WAVEfmt fake pcm bytes".utf8)
        StubURLProtocol.handler = { request in
            capture.record(request)
            return jsonResponse(request.url!, status: 200, body: #"{"text":"hello world","language":"en","durationSeconds":4.05}"#)
        }
        defer { StubURLProtocol.handler = nil }

        let options = TranscriptionOptions(mode: .smart, vocabulary: ["Prosio"], languageHints: ["zh-CN", "en-US"])
        let transcript: CloudTranscript = try await client.transcribe(wav: wav, options: options)

        #expect(transcript.text == "hello world")
        #expect(transcript.language == "en")
        #expect(transcript.durationSeconds == 4.05)

        let request = capture.all().first
        #expect(request?.url?.path == "/api/transcribe")
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(request?.timeoutInterval == 15)

        struct RequestBody: Decodable {
            let audio: String
            let mode: String
            let vocabulary: [String]
            let languageHints: [String]
            let sessionID: String
        }
        let body = try #require(request.flatMap(bodyData(from:)))
        let decoded = try JSONDecoder().decode(RequestBody.self, from: body)
        #expect(decoded.audio == wav.base64EncodedString())
        #expect(decoded.mode == "smart")
        #expect(decoded.vocabulary == ["Prosio"])
        #expect(decoded.languageHints == ["zh-CN", "en-US"])
        #expect(UUID(uuidString: decoded.sessionID) != nil)
    }

    @Test func transcribe413MapsToRecordingTooLong() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 413, body: #"{"error":{"code":"payload_too_large","message":"too big"}}"#)
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await client.transcribe(wav: Data([1, 2, 3]), options: TranscriptionOptions())
            Issue.record("expected transcriptionFailed to be thrown")
        } catch let error as ProsioError {
            #expect(error == .transcriptionFailed("recording too long"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func transcribeWithoutSessionThrowsNotSignedInWithoutHittingNetwork() async throws {
        let keychain = InMemoryKeychain()
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            return jsonResponse(request.url!, status: 200, body: "{}")
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await client.transcribe(wav: Data([1, 2, 3]), options: TranscriptionOptions())
            Issue.record("expected notSignedIn to be thrown")
        } catch let error as ProsioError {
            #expect(error == .notSignedIn)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(capture.all().isEmpty)
    }

    @Test func prewarmSendsHeadWithoutAuthAndThrottlesRepeatedCalls() async throws {
        let keychain = InMemoryKeychain() // no session token at all — prewarm needs no auth
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            return jsonResponse(request.url!, status: 204, body: "")
        }
        defer { StubURLProtocol.handler = nil }

        await client.prewarm()
        #expect(capture.all().count == 1)
        #expect(capture.all().first?.httpMethod == "HEAD")
        #expect(capture.all().first?.url?.path == "/api/transcribe")
        #expect(capture.all().first?.value(forHTTPHeaderField: "Authorization") == nil)

        // Immediately calling again within the throttle window must not fire a second request.
        await client.prewarm()
        #expect(capture.all().count == 1)
    }

    // MARK: - Composing

    @Test func composeStreamsDeltasAndSendsExpectedRequest() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
            return (response, Data("Hello, world!".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let request = ComposeRequest(mode: .rewrite, text: "hi there", scene: .email, vocabulary: ["Prosio"])
        var collected = ""
        for try await delta in client.compose(request) {
            collected += delta
        }
        #expect(collected == "Hello, world!")

        let sent = capture.all().first
        #expect(sent?.url?.path == "/api/compose")
        #expect(sent?.httpMethod == "POST")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")

        let body = try #require(sent.flatMap(bodyData(from:)))
        let decoded = try JSONDecoder().decode(ComposeRequest.self, from: body)
        #expect(decoded.mode == .rewrite)
        #expect(decoded.text == "hi there")
        #expect(decoded.scene == .email)
        #expect(decoded.vocabulary == ["Prosio"])
    }

    @Test func composeErrorStatusMapsBeforeStreaming() async throws {
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "svc", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(), keychainService: "svc", keychain: keychain)

        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 402, body: #"{"error":{"code":"quota_exceeded","message":"over limit"}}"#)
        }
        defer { StubURLProtocol.handler = nil }

        let request = ComposeRequest(mode: .translate, text: "hi", targetLanguage: "en-US")
        do {
            for try await _ in client.compose(request) {}
            Issue.record("expected quotaExceeded to be thrown")
        } catch let error as ProsioError {
            #expect(error == .quotaExceeded)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
    @Test func meetingUploadUsesSignedPartAndReceivesSonioxVersion() async throws {
        let id = UUID()
        let file = FileManager.default.temporaryDirectory.appending(path: "meeting-client-\(UUID()).m4a")
        try Data([1, 2, 3, 4, 5]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let keychain = InMemoryKeychain()
        keychain.write(Data("session-token".utf8), service: "meeting-test", account: "session")
        let client = BackendClient(baseURL: URL(string: "https://api.prosio.test")!, session: makeStubbedSession(),
                                   keychainService: "meeting-test", keychain: keychain)
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/meetings/jobs"):
                return jsonResponse(request.url!, status: 200,
                                    body: #"{"status":"uploading","partSize":8388608}"#)
            case ("POST", "/api/meetings/jobs/\(id.uuidString)/parts"):
                return jsonResponse(request.url!, status: 200,
                                    body: #"{"url":"https://storage.prosio.test/upload"}"#)
            case ("PUT", "/upload"):
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["ETag": "\"part-1\""])!, Data())
            case ("POST", "/api/meetings/jobs/\(id.uuidString)/complete"):
                return jsonResponse(request.url!, status: 200, body: #"{"status":"submitted"}"#)
            case ("GET", "/api/meetings/jobs/\(id.uuidString)"):
                return jsonResponse(request.url!, status: 200,
                                    body: #"{"status":"completed","transcript":{"text":"hello","tokens":[{"text":"hello","start_ms":0,"end_ms":500,"speaker":"1"}]}}"#)
            default:
                throw URLError(.badURL)
            }
        }
        defer { StubURLProtocol.handler = nil }

        let result = try await client.submitMeeting(id: id, file: file, durationSeconds: 1,
                                                     languageHints: ["en-US"])
        #expect(result.text == "hello")
        #expect(result.tokens.first?.speaker == "1")
        let requests = capture.all()
        #expect(requests.count == 5)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(bodyData(from: requests[3]).flatMap { String(data: $0, encoding: .utf8) }?.contains("part-1") == true)
    }
}

@Suite struct FileBackedKeychainTests {

    @Test func writeThenReadRoundTrips() throws {
        let fileURL = makeTempFileURL("dev-session.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let keychain = FileBackedKeychain(fileURL: fileURL)

        #expect(keychain.read(service: "svc", account: "session") == nil)

        keychain.write(Data("tok_abc".utf8), service: "svc", account: "session")
        let read = keychain.read(service: "svc", account: "session")
        #expect(read.flatMap { String(data: $0, encoding: .utf8) } == "tok_abc")
    }

    @Test func writeCreatesFileWithOwnerOnlyPermissions() throws {
        let fileURL = makeTempFileURL("dev-session.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let keychain = FileBackedKeychain(fileURL: fileURL)

        keychain.write(Data("tok_abc".utf8), service: "svc", account: "session")

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test func deleteRemovesOnlyThatEntry() throws {
        let fileURL = makeTempFileURL("dev-session.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let keychain = FileBackedKeychain(fileURL: fileURL)

        keychain.write(Data("tok_a".utf8), service: "svc", account: "session")
        keychain.write(Data("tok_b".utf8), service: "other", account: "session")

        keychain.delete(service: "svc", account: "session")

        #expect(keychain.read(service: "svc", account: "session") == nil)
        #expect(keychain.read(service: "other", account: "session").flatMap { String(data: $0, encoding: .utf8) } == "tok_b")
    }

    @Test func overwriteReplacesPreviousValue() throws {
        let fileURL = makeTempFileURL("dev-session.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let keychain = FileBackedKeychain(fileURL: fileURL)

        keychain.write(Data("tok_old".utf8), service: "svc", account: "session")
        keychain.write(Data("tok_new".utf8), service: "svc", account: "session")

        let read = keychain.read(service: "svc", account: "session")
        #expect(read.flatMap { String(data: $0, encoding: .utf8) } == "tok_new")
    }

    @Test func missingFileReadsAsNilWithoutCrashing() throws {
        let fileURL = makeTempFileURL("does-not-exist.json")
        let keychain = FileBackedKeychain(fileURL: fileURL)
        #expect(keychain.read(service: "svc", account: "session") == nil)
    }

    @Test func backendClientUsesFileBackedKeychainInDebugByDefault() async throws {
        #if DEBUG
        let fileURL = FileBackedKeychain.defaultFileURL()
        #expect(fileURL.lastPathComponent == "dev-session.json")
        #expect(fileURL.path.contains("Prosio"))
        #else
        // Release builds keep using the real Keychain — nothing to assert here without touching it.
        #endif
    }
}
