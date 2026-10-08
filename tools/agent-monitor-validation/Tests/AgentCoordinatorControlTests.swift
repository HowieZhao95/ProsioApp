import Foundation
import Testing

@Suite("UI original-request consistency") @MainActor
struct AgentCoordinatorControlTests {
    private func setup(_ receipt: AgentCommandReceipt.State = .accepted, taskState: AgentTaskState = .waiting) -> (AgentMonitorCoordinator, AgentTask, CoordinatorControlFixture) {
        let decision = AgentDecision(id: "choice", callID: "i:7", turnID: "turn-one", title: "Choose", options: [], requestID: .integer(7))
        let task = AgentTask(id: "task-one", title: "Task", state: taskState, updatedAt: Date(),
                             live: true, liveConfirmedAt: Date(), turnID: "turn-one", decisions: taskState == .running ? [] : [decision], controlRoute: .desktopIPC)
        let snapshot = AgentMonitorSnapshot(tasks: [task], checkedAt: Date(), runtimeConnected: true)
        let fixture = CoordinatorControlFixture(snapshot: snapshot, state: receipt)
        return (AgentMonitorCoordinator(source: fixture, initial: snapshot, control: fixture), task, fixture)
    }

    @Test func doubleClickAndAcceptedAnswerCannotResendWhileSnapshotLags() async {
        let (coordinator, task, fixture) = setup()
        let decision = task.decisions[0]
        coordinator.answerDrafts[coordinator.answerKey(task: task, decision: decision)] = "A, with a constraint"
        async let first: Void = coordinator.sendAnswers(to: task, decision: decision)
        async let second: Void = coordinator.sendAnswers(to: task, decision: decision)
        _ = await (first, second)
        await coordinator.sendAnswers(to: task, decision: decision)
        #expect(await fixture.submittedCount == 1)
        #expect(!coordinator.canAnswer(task, decision: decision))
        await coordinator.reconcile(taskID: task.id)
        #expect(await fixture.submittedCount == 1)
    }

    @Test func acceptedInterruptDoesNotSendAgainAgainstSameTurn() async {
        let (coordinator, task, fixture) = setup()
        await coordinator.requestInterrupt(task)
        await coordinator.requestInterrupt(task)
        #expect(await fixture.submittedCount == 1)
        #expect(!coordinator.canInterrupt(task))
    }

    @Test func undeliveredAnswerAllowsExplicitRetry() async {
        let (coordinator, task, fixture) = setup(.notDelivered)
        let decision = task.decisions[0]
        coordinator.answerDrafts[coordinator.answerKey(task: task, decision: decision)] = "A"
        await coordinator.sendAnswers(to: task, decision: decision)
        #expect(coordinator.canAnswer(task, decision: decision))
        await coordinator.sendAnswers(to: task, decision: decision)
        #expect(await fixture.submittedCount == 2)
    }
    @Test func supplementUsesDesktopTaskRouteAndPreservesWholeText() async {
        let (coordinator, task, fixture) = setup(.applied, taskState: .running)
        let text = "A, for students, draft only; do not publish"
        coordinator.drafts[task.id] = text
        #expect(coordinator.canSupplement(task))
        await coordinator.sendSupplement(to: task)
        let command = await fixture.lastCommand
        #expect(command?.taskID == task.id && command?.text == text && command?.route == .desktopIPC)
        #expect(coordinator.drafts[task.id] == "")
    }
    @Test func newerDraftSurvivesEarlierCommandsReceipt() async throws {
        let (coordinator, task, _) = setup(.applied, taskState: .running)
        coordinator.drafts[task.id] = "First message"
        let send = Task { await coordinator.sendSupplement(to: task) }
        for _ in 0..<100 {
            if coordinator.sendingTaskIDs.contains(task.id) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        coordinator.drafts[task.id] = "Second message, not sent yet"
        await send.value
        #expect(coordinator.drafts[task.id] == "Second message, not sent yet")
    }
    @Test func taskBoundDraftSurvivesTurnChange() async {
        let (coordinator, task, fixture) = setup(.applied, taskState: .running)
        coordinator.drafts[task.id] = "Still intended for this task"
        var next = task; next.turnID = "turn-two"
        await fixture.replaceTask(next)
        await coordinator.refresh()
        #expect(coordinator.drafts[task.id] == "Still intended for this task")
    }
}

private actor CoordinatorControlFixture: AgentObserving, AgentControlling {
    var value: AgentMonitorSnapshot
    let state: AgentCommandReceipt.State
    private(set) var submittedCount = 0
    private(set) var lastCommand: AgentCommand?
    init(snapshot: AgentMonitorSnapshot, state: AgentCommandReceipt.State) { value = snapshot; self.state = state }
    func snapshot(now: Date) async -> AgentMonitorSnapshot { value }
    func replaceTask(_ task: AgentTask) { value.tasks = [task] }
    func submit(_ command: AgentCommand) async -> AgentCommandReceipt {
        submittedCount += 1
        lastCommand = command
        try? await Task.sleep(for: .milliseconds(20))
        return .init(commandID: command.id, state: state)
    }
    func reconcile(_ command: AgentCommand) async -> AgentCommandReceipt { .init(commandID: command.id, state: .uncertain) }
}
