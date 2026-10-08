import Darwin
import Foundation

/// Optional adapter for the installed desktop host's versioned local coordination protocol.
/// Only connects to an existing, same-user endpoint; never claims task ownership.
nonisolated final class CodexDesktopIPC {
    private var fd: Int32 = -1
    private var clientID = "initializing-client"
    private let deadline: Date
    private var received = 0
    private let permitsControl: Bool
    init(timeout: TimeInterval = 4, permitsControl: Bool = false) {
        deadline = Date().addingTimeInterval(timeout); self.permitsControl = permitsControl
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    func connect(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw CodexRuntimeError.unavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexRuntimeError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexRuntimeError.unavailable }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw CodexRuntimeError.unavailable }
            try ready(POLLOUT)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CodexRuntimeError.unavailable }
        }
        let response = try request("initialize", params: ["clientType": "prosio_companion"], version: 0)
        guard let result = response["result"] as? [String: Any], let id = result["clientId"] as? String else {
            throw CodexRuntimeError.invalidResponse
        }
        clientID = id
    }

    func owner(taskID: String) throws -> String {
        let response = try request("thread-owner-discovery", params: ["hostId": "local", "conversationId": taskID], version: 1)
        guard let owner = response["handledByClientId"] as? String else { throw CodexRuntimeError.invalidResponse }
        return owner
    }

    func snapshot(taskID: String, owner: String) throws -> [String: Any] {
        try following(taskID: taskID, owner: owner, enabled: true)
        defer { try? following(taskID: taskID, owner: owner, enabled: false) }
        while true {
            let message = try receive()
            guard message["type"] as? String == "broadcast", message["method"] as? String == "thread-stream-state-changed",
                  message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any], params["conversationId"] as? String == taskID,
                  params["hostId"] as? String == "local",
                  let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot" else { continue }
            guard message["version"] as? Int == 11,
                  let state = change["conversationState"] as? [String: Any], state["id"] as? String == taskID else {
                throw CodexRuntimeError.invalidResponse
            }
            return state
        }
    }

    func answer(taskID: String, owner: String, requestID: Any, answers: [String: [String]]) throws {
        let values = answers.mapValues { ["answers": $0] }
        _ = try request("thread-follower-submit-user-input", params: ["conversationId": taskID,
            "requestId": requestID, "response": ["answers": values]], version: 1, owner: owner)
    }

    func interrupt(taskID: String, owner: String, turnID: String) throws {
        _ = try request("thread-follower-interrupt-turn", params: ["conversationId": taskID,
            "expectedTurnId": turnID, "mode": "user-stop"], version: 4, owner: owner)
    }

    /// The host binds this to the task's active turn at submission time, not the caller's turn.
    func supplement(taskID: String, owner: String, text: String, commandID: UUID, workspace: String) throws -> String {
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        let restore: [String: Any] = ["id": commandID.uuidString, "input": input, "cwd": workspace,
            "context": ["workspaceRoots": workspace.isEmpty ? [] : [workspace]]]
        let response = try request("thread-follower-steer-turn", params: ["conversationId": taskID,
            "input": input, "restoreMessage": restore, "clientUserMessageId": commandID.uuidString], version: 1, owner: owner)
        guard let outer = response["result"] as? [String: Any], let result = outer["result"] as? [String: Any],
              let turnID = result["turnId"] as? String, !turnID.isEmpty else { throw CodexRuntimeError.invalidResponse }
        return turnID
    }

    private func following(taskID: String, owner: String, enabled: Bool) throws {
        try send(["type": "broadcast", "sourceClientId": clientID, "method": "thread-stream-following-changed",
            "version": 1, "targetClientIds": [owner], "params": ["hostId": "local", "conversationId": taskID, "following": enabled]])
    }

    private func request(_ method: String, params: [String: Any], version: Int, owner: String? = nil) throws -> [String: Any] {
        guard ["initialize", "thread-owner-discovery"].contains(method)
            || permitsControl && ["thread-follower-submit-user-input", "thread-follower-interrupt-turn", "thread-follower-steer-turn"].contains(method) else {
            throw CodexRuntimeError.rejected
        }
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
            "method": method, "params": params, "version": version, "timeoutMs": 2000]
        if let owner { message["targetClientId"] = owner }
        try send(message)
        while true {
            let response = try receive()
            guard response["type"] as? String == "response", response["requestId"] as? String == id else { continue }
            guard response["resultType"] as? String == "success" else { throw CodexRuntimeError.rejected }
            if let owner, response["handledByClientId"] as? String != owner { throw CodexRuntimeError.invalidResponse }
            return response
        }
    }

    private func receive() throws -> [String: Any] {
        let length = try read(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 8 * 1024 * 1024 else { throw CodexRuntimeError.tooLarge }
        guard let message = try JSONSerialization.jsonObject(with: read(Int(length))) as? [String: Any] else {
            throw CodexRuntimeError.invalidResponse
        }
        // Explicitly refuse routing requests. This companion is never an owner or approval host.
        if message["type"] as? String == "client-discovery-request", let id = message["requestId"] {
            try send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
        }
        return message
    }

    private func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= 1024 * 1024 else { throw CodexRuntimeError.tooLarge }
        var frame = Data((0..<4).map { UInt8((body.count >> ($0 * 8)) & 255) }); frame.append(body)
        var offset = 0
        while offset < frame.count {
            try ready(POLLOUT)
            let count = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0) }
            if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard count > 0 else { throw CodexRuntimeError.unavailable }
            offset += count
        }
    }

    private func read(_ size: Int) throws -> Data {
        var data = Data(count: size), offset = 0
        while offset < size {
            try ready(POLLIN)
            let count = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), size - offset, 0) }
            if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard count > 0 else { throw CodexRuntimeError.unavailable }
            offset += count; received += count
            guard received <= 32 * 1024 * 1024 else { throw CodexRuntimeError.tooLarge }
        }
        return data
    }
    private func ready(_ events: Int32) throws {
        guard deadline.timeIntervalSinceNow > 0 else { throw CodexRuntimeError.timeout }
        var item = pollfd(fd: fd, events: Int16(events), revents: 0)
        guard poll(&item, 1, Int32(min(deadline.timeIntervalSinceNow * 1000, 8000))) > 0 else { throw CodexRuntimeError.timeout }
        guard item.revents & Int16(events) != 0 else { throw CodexRuntimeError.unavailable }
    }
}
