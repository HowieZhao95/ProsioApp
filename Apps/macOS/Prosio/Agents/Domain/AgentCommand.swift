import Foundation

nonisolated struct AgentCommand: Sendable, Equatable {
    enum Kind: Sendable { case supplement, interrupt, answer }
    var id = UUID()
    var taskID: String
    var turnID: String
    var kind: Kind
    var text: String?
    var route = AgentControlRoute.appServer
    var decisions: [AgentDecision] = []
    var answers: [String: [String]] = [:]
}

nonisolated struct AgentCommandReceipt: Sendable, Equatable {
    enum State: Sendable {
        case accepted, applied, appliedToNewTurn, interrupted, notDelivered, uncertain, expired, rejected
        var label: String {
            switch self {
            case .accepted: "运行实例已接受请求，应用结果仍待确认。"
            case .applied: "原任务已记录此次输入；后续执行结果请查看最新状态。"
            case .appliedToNewTurn: "补充已进入同一任务的新轮次；请查看最新任务状态。"
            case .interrupted: "已确认原轮次中断。已发生的操作不会被撤回。"
            case .notDelivered: "未送达原任务，请检查运行实例连接。"
            case .uncertain: "暂未收到结果，请核实原任务；不会自动重复发送。"
            case .expired: "原轮次已改变，请刷新后查看最新任务。"
            case .rejected: "运行实例未接受请求，请在来源应用处理。"
            }
        }
    }
    var commandID: UUID
    var state: State
    var targetTurnID: String? = nil
}

nonisolated protocol AgentControlling: Sendable {
    func submit(_ command: AgentCommand) async -> AgentCommandReceipt
    func reconcile(_ command: AgentCommand) async -> AgentCommandReceipt
}

nonisolated extension AgentControlling {
    func reconcile(_ command: AgentCommand) async -> AgentCommandReceipt {
        .init(commandID: command.id, state: .uncertain)
    }
}
