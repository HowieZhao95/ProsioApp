import Foundation

nonisolated enum CodexDesktopState {
    static func turns(_ state: [String: Any]) -> [[String: Any]] {
        if let history = state["turnHistory"] as? [String: Any], history["kind"] as? String == "canonical",
           let canonical = history["history"] as? [String: Any], let entities = canonical["entitiesByKey"] as? [String: Any] {
            return entities.values.compactMap { $0 as? [String: Any] }
        }
        return state["turns"] as? [[String: Any]] ?? []
    }

    static func task(_ state: [String: Any], fallback: AgentTask?, now: Date) -> AgentTask? {
        guard let id = state["id"] as? String,
              let runtime = state["threadRuntimeStatus"] as? [String: Any] else { return nil }
        var task = CodexEventReducer.runtimeTask(["id": id, "status": runtime], fallback: fallback) ?? AgentTask(id: id)
        task.title = state["title"] as? String ?? task.title
        task.workspace = state["cwd"] as? String ?? task.workspace
        task.model = state["latestModel"] as? String ?? task.model
        task.liveConfirmedAt = now; task.controlRoute = .desktopIPC
        task.decisions = []; task.question = nil
        let active = turns(state).filter { $0["status"] as? String == "inProgress" }
            .max { ($0["turnStartedAtMs"] as? Double ?? 0) < ($1["turnStartedAtMs"] as? Double ?? 0) }
        task.turnID = active?["turnId"] as? String
        for request in state["requests"] as? [[String: Any]] ?? [] {
            guard request["method"] as? String == "item/tool/requestUserInput",
                  let requestID = AgentRequestID(request["id"]),
                  let params = request["params"] as? [String: Any], params["threadId"] as? String == id,
                  params["turnId"] as? String == task.turnID,
                  let questions = params["questions"] as? [[String: Any]],
                  !questions.contains(where: { $0["isSecret"] as? Bool == true }),
                  questions.allSatisfy({ ($0["id"] as? String)?.isEmpty == false }),
                  Set(questions.compactMap { $0["id"] as? String }).count == questions.count,
                  let data = try? JSONSerialization.data(withJSONObject: ["questions": questions]),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var decisions = CodexEventReducer.decisions(from: text, callID: requestID.key, turnID: task.turnID)
            // Never submit truncated identities or hidden questions as if they were complete.
            guard decisions.count == questions.count, decisions.allSatisfy({ !$0.id.isEmpty }) else { continue }
            for index in decisions.indices { decisions[index].requestID = requestID }
            task.decisions.append(contentsOf: decisions)
        }
        if !task.decisions.isEmpty {
            task.question = task.decisions.map(\.title).joined(separator: "\n\n")
            task.activity = "运行实例有待回答问题"
        } else if task.state == .waiting { task.activity = task.waitingForApproval ? "需要审批具体操作" : "需要在来源应用查看问题" }
        return task
    }

    static func recordedAnswers(_ state: [String: Any], requestID: AgentRequestID, turnID: String) -> [String: [String]]? {
        for turn in turns(state) where turn["turnId"] as? String == turnID {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                guard item["type"] as? String == "userInputResponse", AgentRequestID(item["requestId"]) == requestID,
                      item["completed"] as? Bool == true else { continue }
                return item["answers"] as? [String: [String]]
            }
        }
        return nil
    }

    static func recordedSupplement(_ state: [String: Any], commandID: UUID, text: String) -> String? {
        for turn in turns(state) {
            guard let turnID = turn["turnId"] as? String else { continue }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                let type = item["type"] as? String
                let content: [[String: Any]]?
                if type == "userMessage", item["clientId"] as? String == commandID.uuidString {
                    content = item["content"] as? [[String: Any]]
                } else if type == "steeringUserMessage", item["clientUserMessageId"] as? String == commandID.uuidString,
                          item["status"] as? String == "accepted", item["targetTurnId"] as? String == turnID {
                    content = item["input"] as? [[String: Any]]
                } else { continue }
                if content?.filter({ $0["type"] as? String == "text" }).compactMap({ $0["text"] as? String }).joined(separator: "\n") == text {
                    return turnID
                }
            }
        }
        return nil
    }
}
