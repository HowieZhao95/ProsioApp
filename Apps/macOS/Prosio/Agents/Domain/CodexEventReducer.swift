import Foundation

nonisolated enum CodexEventReducer {
    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func apply(_ data: Data, to task: inout AgentTask) -> Bool {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = record["type"] as? String else { return false }
        // Valid records from newer schemas can have no payload. Ignore them, rather than
        // treating every unrecognized record as a damaged transcript.
        guard let payload = record["payload"] as? [String: Any] else { return true }
        let timestamp = date(record["timestamp"])
        switch kind {
        case "session_meta":
            if let id = payload["id"] as? String { task.id = id }
            task.workspace = payload["cwd"] as? String ?? task.workspace
            task.surface = AgentSurface.resolve(originator: payload["originator"] as? String,
                                                source: payload["source"] as? String)
            if let source = payload["source"] as? [String: Any],
               let subagent = source["subagent"] as? [String: Any],
               let spawn = subagent["thread_spawn"] as? [String: Any] {
                task.parentID = spawn["parent_thread_id"] as? String
            }
            task.updatedAt = timestamp ?? task.updatedAt
        case "turn_context":
            task.model = payload["model"] as? String ?? task.model
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                task.turnID = payload["turn_id"] as? String
                task.state = .running; task.activity = "正在处理任务"
                task.question = nil; task.decisions = []; task.waitingForApproval = false; task.pendingCalls = []; task.waitingCalls = []
            case "task_complete":
                // A late completion from an earlier turn must not end the current one.
                if let id = payload["turn_id"] as? String, let current = task.turnID, id != current { return true }
                task.state = .completed; task.activity = "本轮回复已完成"
                task.question = nil; task.decisions = []; task.waitingForApproval = false; task.pendingCalls = []; task.waitingCalls = []
            case "turn_aborted", "task_cancelled":
                if let id = payload["turn_id"] as? String, let current = task.turnID, id != current { return true }
                task.state = .interrupted; task.activity = "本轮执行已中断"
                task.question = nil; task.decisions = []; task.waitingForApproval = false; task.pendingCalls = []; task.waitingCalls = []
            case "error": task.state = .failed; task.activity = "任务报告了错误"
            case "agent_message":
                if task.state == .running { task.activity = "正在生成回复" }
            case "token_count":
                if task.state == .running { task.updatedAt = timestamp ?? task.updatedAt }
                return true
            default: return true
            }
            task.updatedAt = timestamp ?? task.updatedAt
        case "response_item":
            switch payload["type"] as? String {
            case "function_call", "custom_tool_call":
                let name = payload["name"] as? String ?? "工具"
                let id = payload["call_id"] as? String ?? ""
                if !id.isEmpty { task.pendingCalls.insert(id) }
                task.state = .running; task.activity = "正在使用 \(String(name.prefix(100)))"
                // Async questions return an acknowledgement immediately; that tool result is
                // not a user's answer and cannot prove that execution is blocked.
                if name.hasSuffix("request_user_input") {
                    task.state = .waiting
                    if !id.isEmpty { task.waitingCalls.insert(id) }
                    task.activity = "已提出结构化问题"
                    task.question = question(from: payload["arguments"] ?? payload["input"])
                    task.decisions = task.decisions.filter { $0.callID != id } + decisions(from: payload["arguments"] ?? payload["input"], callID: id, turnID: task.turnID)
                }
                if !task.waitingCalls.isEmpty { task.state = .waiting }
                task.updatedAt = timestamp ?? task.updatedAt
            case "function_call_output", "custom_tool_call_output":
                if let id = payload["call_id"] as? String {
                    task.pendingCalls.remove(id)
                    if task.waitingCalls.remove(id) != nil {
                        task.decisions.removeAll { $0.callID == id }
                        task.question = task.decisions.map(\.title).joined(separator: "\n\n").nilIfEmpty
                        if task.waitingCalls.isEmpty {
                            task.state = .running; task.activity = "问题已返回结果，后续状态待更新"
                        }
                    }
                }
                if task.pendingCalls.isEmpty && task.state == .running { task.activity = "正在处理工具结果" }
                task.updatedAt = timestamp ?? task.updatedAt
            case "message":
                if payload["role"] as? String == "assistant", task.state == .running {
                    task.activity = "正在生成回复"; task.updatedAt = timestamp ?? task.updatedAt
                }
            default: break
            }
        default: break
        }
        return true
    }

    static func decisions(from value: Any?, callID: String, turnID: String?) -> [AgentDecision] {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = object["questions"] as? [[String: Any]] else { return [] }
        return questions.prefix(3).enumerated().compactMap { index, item in
            guard let title = (item["question"] ?? item["title"]) as? String else { return nil }
            let options = (item["options"] as? [Any] ?? []).compactMap { value -> AgentDecisionOption? in
                if let label = value as? String { return .init(label: label, detail: "") }
                guard let option = value as? [String: Any], let label = option["label"] as? String else { return nil }
                return .init(label: label, detail: option["description"] as? String ?? "")
            }
            return AgentDecision(id: item["id"] as? String ?? "\(callID):\(index)", callID: callID,
                                 turnID: turnID, title: title, options: options)
        }
    }

    static func question(from value: Any?) -> String? {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = object["questions"] as? [[String: Any]] else { return nil }
        return questions.prefix(3).compactMap { item -> String? in
            guard let question = (item["question"] ?? item["title"]) as? String else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).prefix(3).compactMap { option -> String? in
                guard let label = option["label"] as? String else { return nil }
                return "• \(String(label.prefix(120)))"
            }
            return ([String(question.prefix(500))] + options).joined(separator: "\n")
        }.joined(separator: "\n\n").nilIfEmpty
    }

    static func runtimeTask(_ object: [String: Any], fallback: AgentTask?) -> AgentTask? {
        guard let id = object["id"] as? String else { return nil }
        var task = fallback ?? AgentTask(id: id)
        task.title = (object["name"] as? String)?.nilIfEmpty
            ?? (object["title"] as? String)?.nilIfEmpty ?? task.title
        task.workspace = object["cwd"] as? String ?? task.workspace
        let status = object["status"] as? [String: Any]
        switch status?["type"] as? String {
        case "active":
            let flags = status?["activeFlags"] as? [String] ?? []
            task.waitingForApproval = flags.contains("waitingOnApproval")
            task.state = !Set(flags).subtracting(["waitingOnUserInput", "waitingOnApproval"]).isEmpty ? .unknown
                : flags.contains("waitingOnUserInput") || task.waitingForApproval ? .waiting : .running
        case "idle": task.state = .idle; task.question = nil; task.decisions = []; task.waitingForApproval = false
        case "systemError": task.state = .failed
        default: task.state = .unknown
        }
        task.live = true; task.readError = false
        if let seconds = object["updatedAt"] as? Double { task.updatedAt = Date(timeIntervalSince1970: seconds) }
        return task
    }
}

nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
