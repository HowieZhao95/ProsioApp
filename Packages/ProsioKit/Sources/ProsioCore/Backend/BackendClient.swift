import Foundation
import Security

public struct UsageReport: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var engineID: String
    public var audioSeconds: Double
    public var startedAt: Date

    public init(sessionID: UUID, engineID: String, audioSeconds: Double, startedAt: Date) {
        self.sessionID = sessionID
        self.engineID = engineID
        self.audioSeconds = audioSeconds
        self.startedAt = startedAt
    }
}

/// HTTP client for the Prosio backend (see docs/API.md). Session token stored in Keychain.
/// PUBLIC API FROZEN — implementation owned by core agent.
public final class BackendClient: GatewayTokenProviding, @unchecked Sendable {
    public let baseURL: URL

    private let session: URLSession
    private let keychainService: String
    private let keychain: any KeychainStoring
    private let accountName = "session"

    /// Guards `tokenCache`/`lastPrewarmAt`; kept as a plain lock (not an actor) so `isSignedIn` and
    /// the keychain wrapper stay usable from synchronous, non-async call sites.
    private let lock = NSLock()
    private var tokenCache: [String: GatewayToken] = [:]
    private var lastPrewarmAt: Date?

    public convenience init(baseURL: URL, session: URLSession = .shared, keychainService: String = "app.prosio.session") {
        self.init(baseURL: baseURL, session: session, keychainService: keychainService, keychain: SystemKeychain())
    }

    /// Internal designated initializer — lets tests inject an in-memory keychain instead of the
    /// real Security framework. Not part of the frozen public API.
    init(baseURL: URL, session: URLSession, keychainService: String, keychain: any KeychainStoring) {
        self.baseURL = baseURL
        self.session = session
        self.keychainService = keychainService
        self.keychain = keychain
    }

    public var isSignedIn: Bool { currentSessionToken() != nil }

    /// Dev-only sign-in (server must run with PROSIO_DEV_AUTH=1). Stores the session token.
    public func devSignIn(email: String) async throws {
        struct RequestBody: Encodable { let email: String }
        struct ResponseUser: Decodable { let id: String; let email: String }
        struct ResponseBody: Decodable { let sessionToken: String; let user: ResponseUser }

        let body = try Self.makeEncoder().encode(RequestBody(email: email))
        let request = try makeRequest(path: "api/auth/dev", method: "POST", body: body, requiresAuth: false)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        let decoded = try Self.makeDecoder().decode(ResponseBody.self, from: data)
        guard let tokenData = decoded.sessionToken.data(using: .utf8) else {
            throw ProsioError.network("invalid session token encoding")
        }
        keychain.write(tokenData, service: keychainService, account: accountName)
    }

    public func signOut() {
        keychain.delete(service: keychainService, account: accountName)
        lock.lock()
        tokenCache = [:]
        lock.unlock()
    }

    public func token(for model: String) async throws -> GatewayToken {
        if let cached = takeCachedTokenIfFresh(for: model) {
            schedulePrefetch(for: model)
            return cached
        }
        let fresh = try await performTokenRequest(model: model)
        schedulePrefetch(for: model)
        return fresh
    }

    public func reportUsage(_ report: UsageReport) async throws {
        let body = try Self.makeEncoder().encode(report)
        let request = try makeRequest(path: "api/usage", method: "POST", body: body, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
    }

    public func fetchDictionary() async throws -> [DictionaryEntry] {
        struct Payload: Decodable { let entries: [DictionaryEntry] }
        let request = try makeRequest(path: "api/dictionary", method: "GET", body: nil, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        return try Self.makeDecoder().decode(Payload.self, from: data).entries
    }

    public func pushDictionary(_ entries: [DictionaryEntry]) async throws {
        struct Payload: Encodable { let entries: [DictionaryEntry] }
        let body = try Self.makeEncoder().encode(Payload(entries: entries))
        let request = try makeRequest(path: "api/dictionary", method: "PUT", body: body, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
    }

    // MARK: - Token prefetch cache

    /// Removes and returns the cached token for `model` if it still has more than 5s of validity
    /// left (tokens are single-use, so a cache hit is always consumed regardless of freshness).
    private func takeCachedTokenIfFresh(for model: String) -> GatewayToken? {
        lock.lock()
        let cached = tokenCache.removeValue(forKey: model)
        lock.unlock()
        guard let cached, cached.expiresAt.timeIntervalSinceNow > 5 else { return nil }
        return cached
    }

    private func cacheToken(_ token: GatewayToken, for model: String) {
        lock.lock()
        tokenCache[model] = token
        lock.unlock()
    }

    /// Kicks off a background fetch to keep the per-model cache warm, called after every
    /// successful `token(for:)` (cache hit or miss) rather than exposing a public prefetch API.
    private func schedulePrefetch(for model: String) {
        Task { [weak self] in
            guard let self else { return }
            if let token = try? await self.performTokenRequest(model: model) {
                self.cacheToken(token, for: model)
            }
        }
    }

    private func performTokenRequest(model: String) async throws -> GatewayToken {
        struct RequestBody: Encodable { let model: String }
        let body = try Self.makeEncoder().encode(RequestBody(model: model))
        let request = try makeRequest(path: "api/transcribe/token", method: "POST", body: body, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        return try Self.makeDecoder().decode(GatewayToken.self, from: data)
    }

    // MARK: - Session token

    private func currentSessionToken() -> String? {
        guard let data = keychain.read(service: keychainService, account: accountName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Networking

    private func makeRequest(path: String, method: String, body: Data?, requiresAuth: Bool, timeout: TimeInterval? = nil) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuth {
            guard let token = currentSessionToken() else { throw ProsioError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let timeout {
            request.timeoutInterval = timeout
        }
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as ProsioError {
            throw error
        } catch {
            throw ProsioError.network(error.localizedDescription)
        }
    }

    private struct ServerErrorBody: Decodable {
        struct Payload: Decodable { let code: String; let message: String }
        let error: Payload
    }

    private static func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProsioError.network("invalid response")
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        if http.statusCode == 401 { throw ProsioError.notSignedIn }
        if http.statusCode == 402 { throw ProsioError.quotaExceeded }
        if http.statusCode == 413 { throw ProsioError.transcriptionFailed("recording too long") }

        if let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data) {
            throw ProsioError.network("\(body.error.code): \(body.error.message)")
        }
        throw ProsioError.network("HTTP \(http.statusCode)")
    }

    // MARK: - JSON coding

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFractionalSeconds = ISO8601DateFormatter()
            withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractionalSeconds.date(from: string) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(string)")
        }
        return decoder
    }
}

// MARK: - CloudBatchTranscribing

extension BackendClient: CloudBatchTranscribing {
    /// `POST /api/transcribe` can take a few seconds on a cold connection for a long recording;
    /// give it more headroom than the other, near-instant endpoints.
    private static let transcribeRequestTimeout: TimeInterval = 15
    /// Don't re-warm the connection more often than this.
    private static let prewarmMinInterval: TimeInterval = 20

    /// - Parameter wav: a complete RIFF/WAVE file, 16 kHz mono PCM16 (see docs/API.md).
    public func transcribe(wav: Data, options: TranscriptionOptions) async throws -> CloudTranscript {
        struct RequestBody: Encodable {
            let audio: String
            let mode: TranscriptionMode
            let vocabulary: [String]
            let languageHints: [String]
            let sessionID: UUID
        }
        let body = try Self.makeEncoder().encode(RequestBody(
            audio: wav.base64EncodedString(),
            mode: options.mode,
            vocabulary: options.vocabulary,
            languageHints: options.languageHints,
            sessionID: UUID()
        ))
        let request = try makeRequest(
            path: "api/transcribe",
            method: "POST",
            body: body,
            requiresAuth: true,
            timeout: Self.transcribeRequestTimeout
        )
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        return try Self.makeDecoder().decode(CloudTranscript.self, from: data)
    }

    /// Opens/refreshes the HTTPS connection ahead of time. Best-effort: errors are ignored, and
    /// calls within `prewarmMinInterval` of the last one are skipped.
    public func prewarm() async {
        guard shouldPrewarmNow() else { return }
        guard let request = try? makeRequest(path: "api/transcribe", method: "HEAD", body: nil, requiresAuth: false) else { return }
        _ = try? await session.data(for: request)
    }

    /// Synchronous (non-`async`) so the lock/unlock pair can be used directly — `NSLock` methods
    /// are unavailable from `async` function bodies.
    private func shouldPrewarmNow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastPrewarmAt, Date().timeIntervalSince(last) < Self.prewarmMinInterval {
            return false
        }
        lastPrewarmAt = Date()
        return true
    }
}

// MARK: - Keychain abstraction

/// Injectable so tests can use an in-memory store instead of the real Security framework.
protocol KeychainStoring: Sendable {
    func read(service: String, account: String) -> Data?
    func write(_ data: Data, service: String, account: String)
    func delete(service: String, account: String)
}

/// Generic-password Keychain storage via the Security framework.
struct SystemKeychain: KeychainStoring {
    func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func write(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Thread-safe in-memory `KeychainStoring` for tests.
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func read(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage["\(service)|\(account)"]
    }

    func write(_ data: Data, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage["\(service)|\(account)"] = data
    }

    func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: "\(service)|\(account)")
    }
}
