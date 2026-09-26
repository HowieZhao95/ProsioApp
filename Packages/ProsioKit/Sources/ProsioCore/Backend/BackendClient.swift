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

/// Settings-screen usage summary for the current billing period (`GET /api/usage`). Additive
/// (2026-09-26).
public struct UsageStatus: Sendable, Codable, Hashable {
    public var periodStart: Date
    public var periodEnd: Date
    public var audioSecondsUsed: Double
    /// `nil` when the plan has no fixed cap.
    public var audioSecondsLimit: Double?

    public init(periodStart: Date, periodEnd: Date, audioSecondsUsed: Double, audioSecondsLimit: Double? = nil) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.audioSecondsUsed = audioSecondsUsed
        self.audioSecondsLimit = audioSecondsLimit
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
    /// Same store as `accountName`, alongside it — the signed-in account's email, so
    /// `signedInEmail` survives a relaunch without a network round-trip.
    private let emailAccountName = "session-email"

    /// Guards `tokenCache`/`lastPrewarmAt`/the session-token cache; kept as a plain lock (not an
    /// actor) so `isSignedIn` stays usable from synchronous, non-async call sites.
    private let lock = NSLock()
    private var tokenCache: [String: GatewayToken] = [:]
    private var lastPrewarmAt: Date?
    private var _onSignInStateChange: (@Sendable (Bool) -> Void)?
    /// The last value delivered to the *current* `_onSignInStateChange` closure — `nil` means it
    /// hasn't been sent anything yet. Reset whenever a new closure is assigned, so a fresh
    /// subscriber always gets exactly one initial value, and de-duplicated against on every
    /// `notifySignInStateChange()` call so the immediate replay in the setter below and the
    /// forwarding task started in `init` (which can both observe the same "already loaded" state
    /// when they race) never deliver the same value twice.
    private var _lastNotifiedSignInState: Bool?

    /// Fired after the initial (background) session-token load completes, and again after every
    /// `devSignIn`/`signOut` — lets an observer (e.g. a menu bar item) track sign-in state without
    /// racing `isSignedIn`'s synchronous read against the async initial load (the bug this fixes: a
    /// UI reading `isSignedIn` at launch, before the background Keychain/file read finishes, sees a
    /// stale `false` even though a valid session is about to load). Always invoked off the main
    /// actor — hop yourself if needed.
    ///
    /// Safe to set at any time: if the initial load (or a prior sign-in/out) already completed when
    /// you assign this, it fires immediately (exactly once) with the current state, so there's no
    /// lost-update window regardless of ordering. For a one-shot read instead of an ongoing
    /// subscription, use `loadedIsSignedIn()`.
    public var onSignInStateChange: (@Sendable (Bool) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _onSignInStateChange
        }
        set {
            lock.lock()
            _onSignInStateChange = newValue
            _lastNotifiedSignInState = nil
            let snapshot = sessionTokenCache.snapshot()
            var valueToReplay: Bool?
            if newValue != nil, snapshot.loaded {
                let value = snapshot.token != nil
                _lastNotifiedSignInState = value
                valueToReplay = value
            }
            lock.unlock()
            if let valueToReplay {
                newValue?(valueToReplay)
            }
        }
    }

    /// Session-token cache: loaded once in the background at init (never on the caller's thread —
    /// in particular, never blocking the main actor during app launch with a Keychain prompt) and
    /// kept current by `devSignIn`/`signOut` afterward. `isSignedIn` answers from this cache. A
    /// standalone box (rather than storage directly on `self`) so the initial background load
    /// doesn't need to capture `self` before it's fully initialized.
    private let sessionTokenCache = SessionTokenCache()
    /// Resolves once the initial background Keychain read completes. `resolvedSessionToken()`
    /// awaits this once so the very first authenticated call still sees a freshly-loaded value,
    /// without ever touching the Keychain on whatever thread/actor called it.
    private let initialTokenLoad: Task<Void, Never>

    public convenience init(baseURL: URL, session: URLSession = .shared, keychainService: String = "app.prosio.session") {
        self.init(baseURL: baseURL, session: session, keychainService: keychainService, keychain: Self.defaultKeychain())
    }

    /// DEBUG builds use a file-backed store instead of the system Keychain: a self-signed debug
    /// build gets a fresh code signature (cdhash) on every rebuild, and legacy Keychain ACLs pin
    /// access to that cdhash — so "Always Allow" doesn't survive a rebuild and every relaunch
    /// re-prompts for the login-keychain password. Release builds are notarized/stable-signed and
    /// keep using the real Keychain. No migration: DEBUG never reads the old Keychain item — the
    /// app just re-signs in via `/api/auth/dev` the first time there's no token in the file store.
    private static func defaultKeychain() -> any KeychainStoring {
        #if DEBUG
        return FileBackedKeychain()
        #else
        return SystemKeychain()
        #endif
    }

    /// Internal designated initializer — lets tests inject an in-memory keychain instead of the
    /// real Security framework. Not part of the frozen public API.
    init(baseURL: URL, session: URLSession, keychainService: String, keychain: any KeychainStoring) {
        self.baseURL = baseURL
        self.session = session
        self.keychainService = keychainService
        self.keychain = keychain

        let cache = sessionTokenCache
        let accountName = self.accountName
        let emailAccountName = self.emailAccountName
        let initialTokenLoad = Task.detached {
            // Runs on a background thread, never the caller's (e.g. main) actor. Deliberately
            // doesn't capture `self` — `self` isn't fully initialized until this initializer
            // returns, and this must never block on that.
            let tokenData = keychain.read(service: keychainService, account: accountName)
            let token = tokenData.flatMap { String(data: $0, encoding: .utf8) }
            let emailData = keychain.read(service: keychainService, account: emailAccountName)
            let email = emailData.flatMap { String(data: $0, encoding: .utf8) }
            cache.set(token: token, email: email)
        }
        self.initialTokenLoad = initialTokenLoad

        // `self` is fully initialized from this point on, so this separate (non-detached, still
        // off the main actor) task may safely capture it — it does no I/O of its own, just awaits
        // the load above and forwards the result to `onSignInStateChange`, if anyone's listening.
        Task { [weak self] in
            await initialTokenLoad.value
            self?.notifySignInStateChange()
        }
    }

    public var isSignedIn: Bool {
        let snapshot = sessionTokenCache.snapshot()
        // Not loaded yet (a call landing in the brief window right after init) must not block —
        // answer `false` rather than hit the Keychain synchronously.
        return snapshot.loaded && snapshot.token != nil
    }

    /// The signed-in account's email, persisted alongside the session token (same store) and
    /// restored on load — `nil` when signed out, or (briefly, right after `init`) before the
    /// initial background load finishes, same caveat as `isSignedIn`. Always current by the time
    /// `onSignInStateChange` fires for a given transition (set before that notification goes out).
    public var signedInEmail: String? {
        sessionTokenCache.snapshot().email
    }

    /// Awaits the initial background session-token load (Keychain/file-backed store read) —
    /// resolves immediately if it already finished. Never touches the Keychain on the caller's
    /// thread/actor itself; it only awaits the background read that's already in flight.
    public func waitUntilLoaded() async {
        await initialTokenLoad.value
    }

    /// `isSignedIn`, but only answered after the initial session-token load has finished. Use this
    /// (instead of reading `isSignedIn` synchronously) right after constructing `BackendClient` —
    /// `isSignedIn` alone can read `false` in the brief window before that background Keychain/file
    /// read completes, even though a valid stored session is about to load.
    public func loadedIsSignedIn() async -> Bool {
        await waitUntilLoaded()
        return isSignedIn
    }

    /// Dev-only sign-in (server must run with PROSIO_DEV_AUTH=1). Stores the session token.
    public func devSignIn(email: String) async throws {
        struct RequestBody: Encodable { let email: String }
        struct ResponseUser: Decodable { let id: String; let email: String }
        struct ResponseBody: Decodable { let sessionToken: String; let user: ResponseUser }

        let body = try Self.makeEncoder().encode(RequestBody(email: email))
        let request = try await makeRequest(path: "api/auth/dev", method: "POST", body: body, requiresAuth: false)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        let decoded = try Self.makeDecoder().decode(ResponseBody.self, from: data)
        guard let tokenData = decoded.sessionToken.data(using: .utf8) else {
            throw ProsioError.network("invalid session token encoding")
        }
        keychain.write(tokenData, service: keychainService, account: accountName)
        if let emailData = decoded.user.email.data(using: .utf8) {
            keychain.write(emailData, service: keychainService, account: emailAccountName)
        }
        setCachedSession(token: decoded.sessionToken, email: decoded.user.email)
        notifySignInStateChange()
    }

    public func signOut() {
        keychain.delete(service: keychainService, account: accountName)
        keychain.delete(service: keychainService, account: emailAccountName)
        setCachedSession(token: nil, email: nil)
        lock.lock()
        tokenCache = [:]
        lock.unlock()
        notifySignInStateChange()
    }

    /// Fires `onSignInStateChange` (if set) with the current, already-loaded state. A no-op if the
    /// initial load hasn't finished yet — the forwarding task started in `init` calls this again
    /// once it has, so that case is never silently dropped.
    private func notifySignInStateChange() {
        lock.lock()
        let callback = _onSignInStateChange
        let snapshot = sessionTokenCache.snapshot()
        guard snapshot.loaded else {
            lock.unlock()
            return
        }
        let value = snapshot.token != nil
        guard _lastNotifiedSignInState != value else {
            // Already delivered (e.g. the `onSignInStateChange` setter's own immediate replay
            // raced this same "already loaded" state) — skip the duplicate.
            lock.unlock()
            return
        }
        _lastNotifiedSignInState = value
        lock.unlock()
        callback?(value)
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
        let request = try await makeRequest(path: "api/usage", method: "POST", body: body, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
    }

    /// Settings-screen usage summary for the current billing period.
    public func fetchUsage() async throws -> UsageStatus {
        let request = try await makeRequest(path: "api/usage", method: "GET", body: nil, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        return try Self.makeDecoder().decode(UsageStatus.self, from: data)
    }

    public func fetchDictionary() async throws -> [DictionaryEntry] {
        struct Payload: Decodable { let entries: [DictionaryEntry] }
        let request = try await makeRequest(path: "api/dictionary", method: "GET", body: nil, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        return try Self.makeDecoder().decode(Payload.self, from: data).entries
    }

    public func pushDictionary(_ entries: [DictionaryEntry]) async throws {
        struct Payload: Encodable { let entries: [DictionaryEntry] }
        let body = try Self.makeEncoder().encode(Payload(entries: entries))
        let request = try await makeRequest(path: "api/dictionary", method: "PUT", body: body, requiresAuth: true)
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
        let request = try await makeRequest(path: "api/transcribe/token", method: "POST", body: body, requiresAuth: true)
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        return try Self.makeDecoder().decode(GatewayToken.self, from: data)
    }

    // MARK: - Session token

    private func setCachedSession(token: String?, email: String?) {
        sessionTokenCache.set(token: token, email: email)
    }

    /// The current session token, awaiting the initial background Keychain load at most once
    /// (never touching the Keychain itself on the calling thread/actor).
    private func resolvedSessionToken() async -> String? {
        await initialTokenLoad.value
        return sessionTokenCache.snapshot().token
    }

    // MARK: - Networking

    private func makeRequest(path: String, method: String, body: Data?, requiresAuth: Bool, timeout: TimeInterval? = nil) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuth {
            guard let token = await resolvedSessionToken() else { throw ProsioError.notSignedIn }
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
        let request = try await makeRequest(
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

    /// P1.2: the main dictation path's single request. Sends `localTranscript`/`hasSelection`/`app`
    /// alongside the audio so the server can skip Gemini when the local transcript is already clean
    /// (`response.source == "local"`) and return the session's intent inline (`response.intent`) —
    /// see docs/P1.2-AUDIO-ROUTING.md §3. On HTTP 415 ("unsupported audio format", e.g. an Opus
    /// upload an older server can't decode yet) throws `ProsioError.network("unsupported-audio-format")`
    /// — `DictationController` recognizes that specific message and retries once as WAV.
    public func transcribe(_ request: CloudTranscribeRequest) async throws -> CloudTranscript {
        struct RequestBody: Encodable {
            let audio: String
            let audioFormat: UploadAudioFormat
            let mode: TranscriptionMode
            let vocabulary: [String]
            let languageHints: [String]
            let sessionID: UUID
            let localTranscript: String?
            let hasSelection: Bool
            let app: AppContext?
        }
        struct ResponseIntent: Decodable {
            let intent: ClassifiedIntent?
            let confidence: Double?
            let source: String
            let classifiedOn: String?
        }
        struct ResponseRoute: Decodable {
            let cleanProbability: Double?
            let reason: String
        }
        struct ResponseBody: Decodable {
            let text: String
            let language: String?
            let durationSeconds: Double?
            let source: String?
            let intent: ResponseIntent?
            let route: ResponseRoute?
        }

        let body = try Self.makeEncoder().encode(RequestBody(
            audio: request.audioData.base64EncodedString(),
            audioFormat: request.audioFormat,
            mode: request.options.mode,
            vocabulary: request.options.vocabulary,
            languageHints: request.options.languageHints,
            sessionID: request.sessionID,
            localTranscript: request.localTranscript,
            hasSelection: request.hasSelection,
            app: request.app
        ))
        let urlRequest = try await makeRequest(
            path: "api/transcribe",
            method: "POST",
            body: body,
            requiresAuth: true,
            timeout: Self.transcribeRequestTimeout
        )
        let (data, response) = try await performRequest(urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode == 415 {
            throw ProsioError.network("unsupported-audio-format")
        }
        try Self.checkResponse(response, data: data)
        let decoded = try Self.makeDecoder().decode(ResponseBody.self, from: data)
        let intent = decoded.intent.map {
            IntentDecision(intent: $0.intent, confidence: $0.confidence, source: $0.source, classifiedOn: $0.classifiedOn)
        }
        let route = decoded.route.map { TranscribeRouteInfo(cleanProbability: $0.cleanProbability, reason: $0.reason) }
        return CloudTranscript(
            text: decoded.text,
            language: decoded.language,
            durationSeconds: decoded.durationSeconds,
            source: decoded.source,
            intent: intent,
            route: route
        )
    }

    /// Opens/refreshes the HTTPS connection ahead of time. Best-effort: errors are ignored, and
    /// calls within `prewarmMinInterval` of the last one are skipped.
    public func prewarm() async {
        guard shouldPrewarmNow() else { return }
        guard let request = try? await makeRequest(path: "api/transcribe", method: "HEAD", body: nil, requiresAuth: false) else { return }
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

// `BackendClient: RouteDeciding` (`POST /api/route`) removed 2026-09-26 — see the removal note by
// `RouteDecision`/`RouteDeciding` in Contracts.swift.

// MARK: - IntentClassifying

extension BackendClient: IntentClassifying {
    /// Also a fast Jev decision (docs/PROMPTS.md §5b targets ~1200ms server-side); the client caps
    /// tighter still (`DictationController.classifyIntentTimeout`) since a slow decision should
    /// just fall through to `IntentRules`.
    private static let intentRequestTimeout: TimeInterval = 1.5

    public func classify(transcript: String, hasSelection: Bool, app: AppContext?) async throws -> IntentDecision {
        struct RequestBody: Encodable {
            let transcript: String
            let hasSelection: Bool
            let app: AppContext?
        }
        struct ResponseBody: Decodable {
            let intent: ClassifiedIntent?
            let confidence: Double?
            let source: String
        }
        let body = try Self.makeEncoder().encode(RequestBody(transcript: transcript, hasSelection: hasSelection, app: app))
        let request = try await makeRequest(
            path: "api/intent",
            method: "POST",
            body: body,
            requiresAuth: true,
            timeout: Self.intentRequestTimeout
        )
        let (data, response) = try await performRequest(request)
        try Self.checkResponse(response, data: data)
        let decoded = try Self.makeDecoder().decode(ResponseBody.self, from: data)
        return IntentDecision(intent: decoded.intent, confidence: decoded.confidence, source: decoded.source)
    }
}

// MARK: - Composing

extension BackendClient: Composing {
    /// Rewrite/translate/edit/ask can all involve real LLM latency; give it real headroom (the
    /// per-mode UX-level timeouts in `DictationController` are much tighter and race ahead of this).
    private static let composeRequestTimeout: TimeInterval = 30
    /// Flush the decode buffer at least this often even if it hasn't reached `flushByteThreshold`,
    /// so a slow trickle of bytes still shows up as timely deltas.
    private static let flushInterval: TimeInterval = 0.03
    private static let flushByteThreshold = 16

    /// Streams `POST /api/compose`'s chunked `text/plain` body as deltas via `URLSession.bytes`.
    ///
    /// Reads raw bytes into a small buffer and flushes its longest valid-UTF-8 prefix every
    /// ~16 bytes or ~30ms (whichever comes first), plus an unconditional final flush when the
    /// stream ends — so a slow or unevenly-chunked connection can never silently swallow trailing
    /// text. Logs (mode, latency, output length, error) via `ProsioLog.compose`.
    public func compose(_ request: ComposeRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                var outputLength = 0
                do {
                    let body = try Self.makeEncoder().encode(request)
                    let urlRequest = try await self.makeRequest(
                        path: "api/compose",
                        method: "POST",
                        body: body,
                        requiresAuth: true,
                        timeout: Self.composeRequestTimeout
                    )
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProsioError.network("invalid response")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        try Self.checkResponse(http, data: errorData)
                        throw ProsioError.network("HTTP \(http.statusCode)") // unreachable: checkResponse always throws here
                    }

                    var pending = Data()
                    var lastFlush = Date()

                    func flush() {
                        guard !pending.isEmpty else { return }
                        let (text, remainder) = Self.splitValidUTF8Prefix(pending)
                        pending = remainder
                        lastFlush = Date()
                        guard !text.isEmpty else { return }
                        outputLength += text.count
                        continuation.yield(text)
                    }

                    for try await byte in bytes {
                        pending.append(byte)
                        if pending.count >= Self.flushByteThreshold || Date().timeIntervalSince(lastFlush) >= Self.flushInterval {
                            flush()
                        }
                    }
                    // Final flush: whatever's left when the stream ends, decoded losslessly if it's
                    // not (quite) valid UTF-8 on its own, rather than ever dropping trailing text.
                    if !pending.isEmpty {
                        let text = String(decoding: pending, as: UTF8.self)
                        if !text.isEmpty {
                            outputLength += text.count
                            continuation.yield(text)
                        }
                    }

                    let latencyMs = Date().timeIntervalSince(startedAt) * 1000
                    ProsioLog.compose.info("compose ok mode=\(request.mode.rawValue, privacy: .public) latencyMs=\(Int(latencyMs), privacy: .public) outputLength=\(outputLength, privacy: .public)")
                    continuation.finish()
                } catch let error as ProsioError {
                    Self.logComposeFailure(mode: request.mode, startedAt: startedAt, outputLength: outputLength, error: error)
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    Self.logComposeFailure(mode: request.mode, startedAt: startedAt, outputLength: outputLength, error: ProsioError.cancelled)
                    continuation.finish(throwing: ProsioError.cancelled)
                } catch {
                    let mapped = ProsioError.network(error.localizedDescription)
                    Self.logComposeFailure(mode: request.mode, startedAt: startedAt, outputLength: outputLength, error: mapped)
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func logComposeFailure(mode: ComposeRequest.Mode, startedAt: Date, outputLength: Int, error: ProsioError) {
        let latencyMs = Date().timeIntervalSince(startedAt) * 1000
        ProsioLog.compose.error("compose failed mode=\(mode.rawValue, privacy: .public) latencyMs=\(Int(latencyMs), privacy: .public) outputLength=\(outputLength, privacy: .public) error=\(String(describing: error), privacy: .public)")
    }

    /// Splits off the longest prefix of `data` that decodes as valid UTF-8, returning it plus
    /// whatever's left (at most 3 bytes: a codepoint split across a chunk boundary). If the
    /// remainder still isn't a valid partial codepoint start, treats the whole buffer as invalid
    /// and returns it unsplit so the caller's final lossy decode has the full picture.
    private static func splitValidUTF8Prefix(_ data: Data) -> (text: String, remainder: Data) {
        guard !data.isEmpty else { return ("", Data()) }
        if let text = String(data: data, encoding: .utf8) {
            return (text, Data())
        }
        let maxBacktrack = min(3, data.count - 1)
        guard maxBacktrack >= 1 else { return ("", data) }
        for backtrack in 1...maxBacktrack {
            let prefixLength = data.count - backtrack
            let prefix = data.prefix(prefixLength)
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, Data(data.suffix(backtrack)))
            }
        }
        return ("", data)
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

/// DEBUG-only `KeychainStoring` backed by a plain file instead of the system Keychain — see
/// `BackendClient.defaultKeychain()` for why. Not used in Release builds. `0600` permissions
/// (owner read/write only); best-effort otherwise, since this is a dev convenience, not a secret
/// store with real guarantees.
struct FileBackedKeychain: KeychainStoring {
    private let fileURL: URL

    init(fileURL: URL = FileBackedKeychain.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Prosio/dev-session.json", directoryHint: .notDirectory)
    }

    func read(service: String, account: String) -> Data? {
        loadAll()?[key(service: service, account: account)]
    }

    func write(_ data: Data, service: String, account: String) {
        var all = loadAll() ?? [:]
        all[key(service: service, account: account)] = data
        save(all)
    }

    func delete(service: String, account: String) {
        guard var all = loadAll() else { return }
        all.removeValue(forKey: key(service: service, account: account))
        save(all)
    }

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }

    private func loadAll() -> [String: Data]? {
        guard let raw = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([String: Data].self, from: raw)
    }

    private func save(_ all: [String: Data]) {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Best-effort: this is a dev-only convenience store, never worth crashing the app over.
        }
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

/// Thread-safe holder for `BackendClient`'s cached session token, standalone so the initial
/// background Keychain load (kicked off from `init`) never has to capture `self`.
private final class SessionTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var email: String?
    private var loaded = false

    func snapshot() -> (loaded: Bool, token: String?, email: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (loaded, token, email)
    }

    func set(token: String?, email: String?) {
        lock.lock()
        self.token = token
        self.email = email
        loaded = true
        lock.unlock()
    }
}
