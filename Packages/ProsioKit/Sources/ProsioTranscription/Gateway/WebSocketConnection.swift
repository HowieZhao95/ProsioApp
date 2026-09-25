import Foundation

/// One message received from (or to be sent to) the Gateway WebSocket. Mirrors
/// `URLSessionWebSocketTask.Message` but is our own type so `WebSocketConnection` doesn't leak
/// Foundation's type directly (keeps the fake test double simple).
enum GatewayWireMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// An open WebSocket session. Abstracts `URLSessionWebSocketTask` so tests can inject a fake.
/// See `docs/gateway-ws-protocol.md` for the wire protocol this is used to speak.
protocol WebSocketConnection: Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    func receive() async throws -> GatewayWireMessage
    /// Closes the socket. Best-effort, never throws. Safe to call more than once.
    func close(code: Int)
}

/// Factory for `WebSocketConnection`s, so `GatewayTranscriptionEngine` doesn't depend on
/// `URLSession` directly and tests can inject a fake.
protocol WebSocketConnecting: Sendable {
    /// Opens a connection to `url`, carrying `authToken` via the Gateway's
    /// `Sec-WebSocket-Protocol` auth subprotocol (see docs/gateway-ws-protocol.md §3). Returns as
    /// soon as the task is created and resumed — this implementation does not wait for an
    /// explicit "open" acknowledgement; the first `send`/`receive` call surfaces any connection
    /// failure.
    func connect(url: URL, authToken: String) throws -> any WebSocketConnection
}

/// Real implementation backed by `URLSessionWebSocketTask`.
struct URLSessionWebSocketConnecting: WebSocketConnecting {
    let session: URLSession

    func connect(url: URL, authToken: String) throws -> any WebSocketConnection {
        var request = URLRequest(url: url)
        // Gateway auth rides Sec-WebSocket-Protocol, not a header — see docs/gateway-ws-protocol.md §3.
        request.addValue(
            "ai-gateway-transcription.v1, ai-gateway-auth.\(authToken)",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_048_576 // 1 MiB receive buffer; well above the server's 256 KiB send limit.
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func send(data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> GatewayWireMessage {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .data(data)
        @unknown default:
            return .data(Data())
        }
    }

    func close(code: Int) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: nil)
    }
}
