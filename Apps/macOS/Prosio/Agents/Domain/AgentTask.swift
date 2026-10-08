import Foundation

nonisolated enum AgentSurface: String, Sendable, CaseIterable {
    case workDesktop, codexDesktop, cli, vscode, unknown
    var label: String {
        switch self {
        case .workDesktop: "ChatGPT Work / Codex"
        case .codexDesktop: "Codex Desktop"
        case .cli: "Codex CLI"
        case .vscode: "Codex IDE"
        case .unknown: "Codex · 来源未知"
        }
    }
    static func resolve(originator: String?, source: String?) -> Self {
        // Desktop originators take precedence: Work currently also records source=vscode.
        let origin = originator?.lowercased() ?? ""
        if origin.contains("work_desktop") { return .workDesktop }
        if origin.contains("desktop") || origin == "codex_app" { return .codexDesktop }
        if origin.contains("vscode") { return .vscode }
        if origin.contains("cli") || source == "cli" { return .cli }
        if source == "vscode" { return .vscode }
        return .unknown
    }
}

nonisolated enum AgentTaskState: String, Sendable, CaseIterable {
    case running, waiting, completed, interrupted, failed, idle, unknown
    var label: String {
        switch self {
        case .running: "执行中"
        case .waiting: "等待你回答"
        case .completed: "本轮已结束"
        case .interrupted: "已中断"
        case .failed: "执行失败"
        case .idle: "空闲"
        case .unknown: "状态待确认"
        }
    }
}

nonisolated struct AgentTask: Identifiable, Sendable, Equatable {
    var id: String
    var title = "未命名任务"
    var surface = AgentSurface.unknown
    var workspace = ""
    var model = ""
    var parentID: String?
    var state = AgentTaskState.unknown
    var activity = "尚无可确认的活动"
    var question: String?
    var updatedAt: Date?
    var live = false
    var liveConfirmedAt: Date?
    var truncated = false
    var readError = false
    var turnID: String?
    var pendingCalls: Set<String> = []
    var waitingCalls: Set<String> = []
    var waitingForApproval = false
    var decisions: [AgentDecision] = []
    var controlRoute = AgentControlRoute.none

    var stateLabel: String { state == .waiting && waitingForApproval ? "等待操作审批" : state.label }

    func displayedState(at now: Date, staleAfter: TimeInterval = 180) -> AgentTaskState {
        guard !readError else { return .unknown }
        if live {
            if let liveConfirmedAt, now.timeIntervalSince(liveConfirmedAt) >= 15 { return .unknown }
            return state
        }
        if state == .running || state == .waiting {
            guard let updatedAt, now.timeIntervalSince(updatedAt) < staleAfter else { return .unknown }
        }
        return state
    }
}

/// Transcript decisions describe observed context, never permission to answer a live RPC.
nonisolated struct AgentDecision: Identifiable, Sendable, Equatable {
    var id: String
    var callID: String
    var turnID: String?
    var title: String
    var options: [AgentDecisionOption]
    var requestID: AgentRequestID?
}

nonisolated enum AgentControlRoute: Sendable { case none, appServer, desktopIPC }
nonisolated enum AgentRequestID: Sendable, Equatable {
    case string(String), integer(Int)
    init?(_ value: Any?) {
        if let string = value as? String { self = .string(string) }
        else if let integer = value as? Int { self = .integer(integer) }
        else { return nil }
    }
    var wireValue: Any { switch self { case .string(let value): value; case .integer(let value): value } }
    var key: String { switch self { case .string(let value): "s:\(value)"; case .integer(let value): "i:\(value)" } }
}

nonisolated struct AgentDecisionOption: Identifiable, Sendable, Equatable {
    var id: String { label }
    var label: String
    var detail: String
}

nonisolated struct AgentMonitorSnapshot: Sendable {
    var tasks: [AgentTask] = []
    var checkedAt = Date()
    var runtimeConnected = false
    var warnings: [String] = []
    var scannedFiles = 0
    var bytesRead = 0
}

/// New providers implement observation independently from future control capabilities.
nonisolated protocol AgentObserving: Sendable {
    func snapshot(now: Date) async -> AgentMonitorSnapshot
}
