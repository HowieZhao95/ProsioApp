import Foundation
@testable import ProsioTranscription

/// Actor-backed fake `WebSocketConnection` for testing `GatewayTranscriptionEngine` without a
/// real network connection. Programs a scripted sequence of incoming server messages, records
/// every outgoing frame, and can simulate a socket that never sends a `finish`/`error` part
/// (for timeout tests) or that fails outright on connect.
actor FakeWebSocketConnection: WebSocketConnection {
    enum ScriptedOutcome: Sendable {
        /// Deliver these text frames in order, then behave as `thenFinish`.
        case messages([String], thenFinish: FinishBehavior)
    }

    enum FinishBehavior: Sendable {
        /// After the scripted messages, `receive()` suspends until cancelled/closed (simulates a
        /// server that never sends `finish` — used for final-timeout tests).
        case hang
        /// After the scripted messages, `receive()` throws (simulates an abrupt close).
        case closeWithError
    }

    private(set) var sentTexts: [String] = []
    private(set) var sentData: [Data] = []
    private(set) var closeCodes: [Int] = []

    private var pendingMessages: [String]
    private let finishBehavior: FinishBehavior
    private let sendDelay: Duration?
    private var hangContinuations: [CheckedContinuation<GatewayWireMessage, Error>] = []
    private var isClosed = false

    init(messages: [String], thenFinish: FinishBehavior = .closeWithError, sendDelay: Duration? = nil) {
        self.pendingMessages = messages
        self.finishBehavior = thenFinish
        self.sendDelay = sendDelay
    }

    func send(text: String) async throws {
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
        sentTexts.append(text)
    }

    func send(data: Data) async throws {
        sentData.append(data)
    }

    func receive() async throws -> GatewayWireMessage {
        if !pendingMessages.isEmpty {
            let next = pendingMessages.removeFirst()
            return .text(next)
        }
        if isClosed {
            throw ProsioTestError.connectionClosed
        }
        switch finishBehavior {
        case .closeWithError:
            throw ProsioTestError.connectionClosed
        case .hang:
            // `withCheckedThrowingContinuation` alone never observes Task cancellation, so the
            // cancellation test would hang forever without this: `onCancel` runs outside actor
            // isolation, so it hops back in to resume (and clear) any pending waiters.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GatewayWireMessage, Error>) in
                    hangContinuations.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelHangingReceives() }
            }
        }
    }

    private func cancelHangingReceives() {
        let waiters = hangContinuations
        hangContinuations.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    nonisolated func close(code: Int) {
        Task { await self.recordClose(code: code) }
    }

    private func recordClose(code: Int) {
        closeCodes.append(code)
        isClosed = true
        let waiters = hangContinuations
        hangContinuations.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: ProsioTestError.connectionClosed)
        }
    }
}

enum ProsioTestError: Error, Equatable {
    case connectionClosed
    case connectFailed
}

/// Fake `WebSocketConnecting` that hands out a single pre-built `FakeWebSocketConnection`
/// (or throws, to simulate a connect failure) and records the URL/token it was asked to connect
/// with. A plain locked class (not an actor) because the protocol's `connect` is synchronous.
final class FakeWebSocketConnecting: WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: FakeWebSocketConnection?
    private let connectError: Error?
    private var _lastURL: URL?
    private var _lastAuthToken: String?

    var lastURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _lastURL
    }

    var lastAuthToken: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastAuthToken
    }

    init(connection: FakeWebSocketConnection) {
        self.connection = connection
        self.connectError = nil
    }

    init(connectError: Error) {
        self.connection = nil
        self.connectError = connectError
    }

    func connect(url: URL, authToken: String) throws -> any WebSocketConnection {
        lock.lock()
        _lastURL = url
        _lastAuthToken = authToken
        lock.unlock()

        if let connectError {
            throw connectError
        }
        guard let connection else {
            throw ProsioTestError.connectFailed
        }
        return connection
    }
}
