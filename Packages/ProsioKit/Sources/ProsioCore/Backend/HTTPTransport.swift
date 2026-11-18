import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        continuation.finish(throwing: ProviderHTTPError.status(status))
                        return
                    }
                    var line = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        } else if byte != 13 {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum ProviderHTTPError: Error {
    case status(Int)
}
