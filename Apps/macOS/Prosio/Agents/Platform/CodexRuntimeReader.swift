import CryptoKit
import Darwin
import Foundation

nonisolated enum CodexRuntimeError: Error { case unavailable, timeout, invalidResponse, tooLarge, rejected, stale, uncertain }

/// A strictly read-only client for an existing Unix WebSocket endpoint.
/// It never launches app-server, resumes a thread, answers approvals, or sends user input.
nonisolated final class CodexRuntimeReader {
    private var fd: Int32 = -1
    private let deadline: Date
    private var nextID = 0
    private var receivedBytes = 0
    private let permitsControl: Bool
    init(timeout: TimeInterval = 4) { deadline = Date().addingTimeInterval(timeout); permitsControl = false }
    fileprivate init(controlTimeout: TimeInterval) { deadline = Date().addingTimeInterval(controlTimeout); permitsControl = true }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    func read(socketPath: String) throws -> [[String: Any]] {
        try connect(socketPath)
        _ = try request("initialize", params: ["clientInfo": ["name": "prosio_observer", "version": "0.1.0"]])
        try sendJSON(["method": "initialized", "params": [:]])
        let loaded = try request("thread/loaded/list", params: ["limit": 100])
        guard let ids = loaded["data"] as? [String] else { throw CodexRuntimeError.invalidResponse }
        var result: [[String: Any]] = []
        // Bound total RPC work. Discovery does not imply that a loaded thread is executing.
        for id in ids.prefix(32) {
            let response = try request("thread/read", params: ["threadId": id, "includeTurns": false])
            guard let thread = response["thread"] as? [String: Any] else { throw CodexRuntimeError.invalidResponse }
            result.append(thread)
        }
        return result
    }

    func readThread(socketPath: String, taskID: String) throws -> [String: Any] {
        try connect(socketPath)
        _ = try request("initialize", params: ["clientInfo": ["name": "prosio_receipt_reader", "version": "0.1.0"]])
        try sendJSON(["method": "initialized", "params": [:]])
        let result = try request("thread/read", params: ["threadId": taskID, "includeTurns": true])
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == taskID else {
            throw CodexRuntimeError.invalidResponse
        }
        return thread
    }

    fileprivate func control(socketPath: String, taskID: String, turnID: String, text: String?, interrupt: Bool, commandID: UUID) throws -> String {
        guard permitsControl else { throw CodexRuntimeError.rejected }
        try connect(socketPath)
        _ = try request("initialize", params: ["clientInfo": ["name": "prosio_control", "version": "0.1.0"]])
        try sendJSON(["method": "initialized", "params": [:]])
        let response = try request("thread/read", params: ["threadId": taskID, "includeTurns": true])
        guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == taskID,
              let status = thread["status"] as? [String: Any], status["type"] as? String == "active",
              let turns = thread["turns"] as? [[String: Any]],
              let active = turns.last(where: { $0["status"] as? String == "inProgress" }),
              active["id"] as? String == turnID else { throw CodexRuntimeError.stale }
        // A supplemental message cannot stand in for an answer to a pending approval/input RPC.
        let flags = status["activeFlags"] as? [String] ?? []
        guard interrupt || flags.isEmpty else { throw CodexRuntimeError.rejected }
        let method = interrupt ? "turn/interrupt" : "turn/steer"
        var params: [String: Any] = ["threadId": taskID]
        if interrupt { params["turnId"] = turnID }
        else {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodexRuntimeError.rejected }
            params["expectedTurnId"] = turnID
            params["clientUserMessageId"] = commandID.uuidString
            params["input"] = [["type": "text", "text": text]]
        }
        do {
            let result = try request(method, params: params)
            if !interrupt, result["turnId"] as? String != turnID { throw CodexRuntimeError.uncertain }
            return turnID
        } catch CodexRuntimeError.rejected { throw CodexRuntimeError.rejected }
        catch { throw CodexRuntimeError.uncertain }
    }

    private func connect(_ path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexRuntimeError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexRuntimeError.unavailable }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw CodexRuntimeError.unavailable }
            try ready(POLLOUT)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw CodexRuntimeError.unavailable
            }
        }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(handshake.utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 8192 else { throw CodexRuntimeError.tooLarge }
            header.append(try readBytes(1))
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard let text = String(data: header, encoding: .utf8),
              text.components(separatedBy: "\r\n").first?.contains(" 101 ") == true else {
            throw CodexRuntimeError.invalidResponse
        }
        let headers = text.components(separatedBy: "\r\n").dropFirst().reduce(into: [String: String]()) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            result[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["sec-websocket-accept"] == expected,
              headers["upgrade"]?.lowercased() == "websocket" else { throw CodexRuntimeError.invalidResponse }
    }

    private func ready(_ events: Int32) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CodexRuntimeError.timeout }
        var item = pollfd(fd: fd, events: Int16(events), revents: 0)
        let result = Darwin.poll(&item, 1, Int32(min(remaining * 1000, 4000)))
        guard result > 0 else { throw CodexRuntimeError.timeout }
        guard item.revents & Int16(events) != 0 else { throw CodexRuntimeError.unavailable }
    }

    private func readBytes(_ count: Int) throws -> Data {
        guard count <= 1024 * 1024 else { throw CodexRuntimeError.tooLarge }
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(POLLIN)
            let size = result.withUnsafeMutableBytes { bytes in
                Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard size > 0 else { throw CodexRuntimeError.unavailable }
            offset += size; receivedBytes += size
            guard receivedBytes <= 8 * 1024 * 1024 else { throw CodexRuntimeError.tooLarge }
        }
        return result
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try ready(POLLOUT)
            let size = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard size > 0 else { throw CodexRuntimeError.unavailable }
            offset += size
        }
    }

    private func sendFrame(_ data: Data, opcode: UInt8 = 1) throws {
        guard data.count < 65536 else { throw CodexRuntimeError.tooLarge }
        var frame = Data([0x80 | opcode])
        if data.count < 126 { frame.append(0x80 | UInt8(data.count)) }
        else { frame.append(contentsOf: [0xfe, UInt8(data.count >> 8), UInt8(data.count & 255)]) }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame)
    }

    private func sendJSON(_ object: [String: Any]) throws {
        try sendFrame(JSONSerialization.data(withJSONObject: object))
    }

    private func receiveJSON() throws -> [String: Any] {
        var message = Data()
        while true {
            let header = [UInt8](try readBytes(2))
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw CodexRuntimeError.invalidResponse }
            let opcode = header[0] & 15
            var length = UInt64(header[1] & 127)
            if length == 126 { length = try readBytes(2).reduce(0) { $0 << 8 | UInt64($1) } }
            if length == 127 { length = try readBytes(8).reduce(0) { $0 << 8 | UInt64($1) } }
            guard length <= 1024 * 1024, message.count + Int(length) <= 1024 * 1024 else { throw CodexRuntimeError.tooLarge }
            let payload = try readBytes(Int(length))
            if opcode == 8 { throw CodexRuntimeError.unavailable }
            if opcode == 9 { try sendFrame(payload, opcode: 10); continue }
            if opcode == 10 { continue }
            guard opcode == 1 || opcode == 0 else { throw CodexRuntimeError.invalidResponse }
            message.append(payload)
            if header[0] & 0x80 != 0 {
                guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                    throw CodexRuntimeError.invalidResponse
                }
                return object
            }
        }
    }

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        // A fixed allowlist prevents this observer from accidentally gaining control capabilities.
        guard ["initialize", "thread/loaded/list", "thread/read"].contains(method)
            || (permitsControl && ["turn/steer", "turn/interrupt"].contains(method)) else { throw CodexRuntimeError.rejected }
        nextID += 1
        try sendJSON(["id": nextID, "method": method, "params": params])
        while true {
            let message = try receiveJSON()
            // Server requests (including approvals) are deliberately never answered.
            guard message["method"] == nil, message["id"] as? Int == nextID else { continue }
            if message["error"] != nil { throw CodexRuntimeError.rejected }
            guard let result = message["result"] as? [String: Any] else { throw CodexRuntimeError.invalidResponse }
            return result
        }
    }
}

actor CodexAgentObserver: AgentObserving {
    private let logs: CodexLogObserver
    private let root: URL
    init(root: URL) { self.root = root; logs = CodexLogObserver(root: root) }
    func snapshot(now: Date = Date()) async -> AgentMonitorSnapshot {
        var snapshot = await logs.snapshot(now: now)
        let ipcPath = root.appendingPathComponent("ipc/ipc.sock").path
        if FileManager.default.fileExists(atPath: ipcPath) {
            do {
                let ipc = CodexDesktopIPC()
                try ipc.connect(path: ipcPath)
                var tasks = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for previous in snapshot.tasks.prefix(100) {
                    guard let owner = try? ipc.owner(taskID: previous.id) else { continue }
                    let state = try ipc.snapshot(taskID: previous.id, owner: owner)
                    if let task = CodexDesktopState.task(state, fallback: previous, now: now) { tasks[task.id] = task }
                }
                snapshot.tasks = tasks.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                snapshot.runtimeConnected = true
                snapshot.warnings.append("已连接桌面宿主；未被宿主管理的会话仍显示日志状态。")
                return snapshot
            } catch {
                snapshot.warnings.append("桌面实时连接未通过协议检查，尝试标准运行实例。")
            }
        }
        let socket = root.appendingPathComponent("app-server-control/app-server-control.sock").path
        guard FileManager.default.fileExists(atPath: socket) else {
            snapshot.warnings.append("实时连接不可用；当前显示本地日志记录，执行状态可能延迟。")
            return snapshot
        }
        do {
            let runtime = try CodexRuntimeReader().read(socketPath: socket)
            snapshot.runtimeConnected = true
            var tasks = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for object in runtime {
                guard let id = object["id"] as? String,
                      let task = CodexEventReducer.runtimeTask(object, fallback: tasks[id]) else { continue }
                var confirmed = task
                confirmed.liveConfirmedAt = now
                confirmed.controlRoute = .appServer
                tasks[id] = confirmed
            }
            snapshot.tasks = tasks.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            if runtime.count >= 32 { snapshot.warnings.append("实时状态查询最多覆盖 32 个已加载会话。") }
        } catch {
            snapshot.warnings.append("实时状态查询失败，已回退到本地日志。")
        }
        return snapshot
    }
}

/// Explicit user commands have a separate client and never expand the observation allowlist.
actor CodexAgentController: AgentControlling {
    private let socketPath: String
    private let ipcPath: String
    private var receipts: [UUID: AgentCommandReceipt] = [:]
    init(root: URL) {
        socketPath = root.appendingPathComponent("app-server-control/app-server-control.sock").path
        ipcPath = root.appendingPathComponent("ipc/ipc.sock").path
    }
    func submit(_ command: AgentCommand) async -> AgentCommandReceipt {
        if let existing = receipts[command.id] { return existing }
        if command.route == .desktopIPC {
            let receipt = submitDesktop(command)
            receipts[command.id] = receipt
            return receipt
        }
        let receipt: AgentCommandReceipt
        guard command.kind != .answer else { return .init(commandID: command.id, state: .rejected) }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            receipt = .init(commandID: command.id, state: .notDelivered)
            receipts[command.id] = receipt; return receipt
        }
        do {
            _ = try CodexRuntimeReader(controlTimeout: 8).control(socketPath: socketPath,
                taskID: command.taskID, turnID: command.turnID, text: command.text, interrupt: command.kind == .interrupt, commandID: command.id)
            receipt = .init(commandID: command.id, state: .accepted)
        } catch CodexRuntimeError.stale { receipt = .init(commandID: command.id, state: .expired) }
        catch CodexRuntimeError.uncertain { receipt = .init(commandID: command.id, state: .uncertain) }
        catch CodexRuntimeError.rejected { receipt = .init(commandID: command.id, state: .rejected) }
        catch { receipt = .init(commandID: command.id, state: .notDelivered) }
        receipts[command.id] = receipt
        return receipt
    }
    func reconcile(_ command: AgentCommand) async -> AgentCommandReceipt {
        let receipt: AgentCommandReceipt
        if command.route == .appServer {
            do {
                let thread = try CodexRuntimeReader().readThread(socketPath: socketPath, taskID: command.taskID)
                let turn = (thread["turns"] as? [[String: Any]] ?? []).first { $0["id"] as? String == command.turnID }
                if command.kind == .interrupt, turn?["status"] as? String == "interrupted" {
                    receipt = .init(commandID: command.id, state: .interrupted)
                } else if command.kind == .supplement,
                          (turn?["items"] as? [[String: Any]] ?? []).contains(where: {
                              $0["type"] as? String == "userMessage" && $0["clientId"] as? String == command.id.uuidString
                          }) {
                    receipt = .init(commandID: command.id, state: .applied)
                } else { receipt = .init(commandID: command.id, state: .uncertain) }
            } catch { receipt = .init(commandID: command.id, state: .uncertain) }
            receipts[command.id] = receipt
            return receipt
        }
        do {
            let ipc = CodexDesktopIPC(timeout: 4)
            try ipc.connect(path: ipcPath)
            let owner = try ipc.owner(taskID: command.taskID)
            let state = try ipc.snapshot(taskID: command.taskID, owner: owner)
            if command.kind == .answer, let requestID = command.decisions.first?.requestID,
               let recorded = CodexDesktopState.recordedAnswers(state, requestID: requestID, turnID: command.turnID) {
                receipt = .init(commandID: command.id, state: recorded == command.answers ? .applied : .expired)
            } else if command.kind == .supplement, let text = command.text,
                      let turnID = CodexDesktopState.recordedSupplement(state, commandID: command.id, text: text) {
                receipt = .init(commandID: command.id, state: turnID == command.turnID ? .applied : .appliedToNewTurn, targetTurnID: turnID)
            } else if command.kind == .interrupt,
                      CodexDesktopState.turns(state).contains(where: { $0["turnId"] as? String == command.turnID && $0["status"] as? String == "interrupted" }) {
                receipt = .init(commandID: command.id, state: .interrupted)
            } else { receipt = .init(commandID: command.id, state: .uncertain) }
        } catch { receipt = .init(commandID: command.id, state: .uncertain) }
        receipts[command.id] = receipt
        return receipt
    }

    private func submitDesktop(_ command: AgentCommand) -> AgentCommandReceipt {
        var attempted = false
        do {
            let ipc = CodexDesktopIPC(timeout: 8, permitsControl: true)
            try ipc.connect(path: ipcPath)
            let owner = try ipc.owner(taskID: command.taskID)
            let before = try ipc.snapshot(taskID: command.taskID, owner: owner)
            if command.kind == .supplement, let text = command.text,
               let turnID = CodexDesktopState.recordedSupplement(before, commandID: command.id, text: text) {
                return .init(commandID: command.id, state: turnID == command.turnID ? .applied : .appliedToNewTurn, targetTurnID: turnID)
            }
            guard let task = CodexDesktopState.task(before, fallback: nil, now: Date()),
                  (command.kind == .supplement ? task.turnID != nil : task.turnID == command.turnID) else {
                return .init(commandID: command.id, state: .expired)
            }
            switch command.kind {
            case .supplement:
                guard task.state == .running, !task.waitingForApproval, task.decisions.isEmpty,
                      let text = command.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .init(commandID: command.id, state: .rejected)
                }
                attempted = true
                let actualTurn = try ipc.supplement(taskID: command.taskID, owner: owner, text: text,
                                                   commandID: command.id, workspace: task.workspace)
                let after = try ipc.snapshot(taskID: command.taskID, owner: owner)
                guard let recordedTurn = CodexDesktopState.recordedSupplement(after, commandID: command.id, text: text),
                      recordedTurn == actualTurn else {
                    return .init(commandID: command.id, state: .uncertain, targetTurnID: actualTurn)
                }
                return .init(commandID: command.id, state: actualTurn == command.turnID ? .applied : .appliedToNewTurn,
                             targetTurnID: actualTurn)
            case .interrupt:
                attempted = true
                try ipc.interrupt(taskID: command.taskID, owner: owner, turnID: command.turnID)
                return .init(commandID: command.id, state: .accepted)
            case .answer:
                guard let requestID = command.decisions.first?.requestID,
                      !command.decisions.isEmpty, command.decisions.allSatisfy({ $0.requestID == requestID }),
                      task.decisions.filter({ $0.requestID == requestID }) == command.decisions,
                      Set(command.answers.keys) == Set(command.decisions.map(\.id)),
                      command.answers.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }) else {
                    return .init(commandID: command.id, state: .expired)
                }
                if let recorded = CodexDesktopState.recordedAnswers(before, requestID: requestID, turnID: command.turnID) {
                    return .init(commandID: command.id, state: recorded == command.answers ? .applied : .expired)
                }
                attempted = true
                try ipc.answer(taskID: command.taskID, owner: owner, requestID: requestID.wireValue, answers: command.answers)
                let after = try ipc.snapshot(taskID: command.taskID, owner: owner)
                if let recorded = CodexDesktopState.recordedAnswers(after, requestID: requestID, turnID: command.turnID) {
                    return .init(commandID: command.id, state: recorded == command.answers ? .applied : .expired)
                }
                return .init(commandID: command.id, state: .uncertain)
            }
        } catch CodexRuntimeError.rejected {
            return .init(commandID: command.id, state: .rejected)
        } catch {
            return .init(commandID: command.id, state: attempted ? .uncertain : .notDelivered)
        }
    }

}
