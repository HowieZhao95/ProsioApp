import AppKit
import Foundation
import Testing

@Suite("Codex observation state")
struct AgentReducerTests {
    @Test func liveStatusExpiresWithoutAnotherSuccessfulQuery() {
        let task = AgentTask(id: "one", state: .running, live: true, liveConfirmedAt: Date(timeIntervalSince1970: 100))
        #expect(task.displayedState(at: Date(timeIntervalSince1970: 114)) == .running)
        #expect(task.displayedState(at: Date(timeIntervalSince1970: 115)) == .unknown)
    }
    @Test func approvalIsNotAnOrdinaryQuestionAndNewFlagsAreUnknown() {
        let approval = CodexEventReducer.runtimeTask(["id": "one", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]], fallback: nil)
        #expect(approval?.stateLabel == "等待操作审批")
        let future = CodexEventReducer.runtimeTask(["id": "one", "status": ["type": "active", "activeFlags": ["futureFlag"]]], fallback: nil)
        #expect(future?.state == .unknown)
    }
    @Test func decisionsPreserveBindingAndOptionConsequences() {
        let input = "{\"questions\":[{\"id\":\"direction\",\"question\":\"哪个方向？\",\"options\":[{\"label\":\"A\",\"description\":\"成本低\"}]}]}"
        let decisions = CodexEventReducer.decisions(from: input, callID: "call", turnID: "turn")
        #expect(decisions.first?.id == "direction")
        #expect(decisions.first?.callID == "call" && decisions.first?.turnID == "turn")
        #expect(decisions.first?.options.first?.detail == "成本低")
    }
    private func record(_ type: String, _ payload: [String: Any], at: String = "2026-10-03T01:00:00.000Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": at, "payload": payload])
    }
    @Test func desktopOriginTakesPrecedenceOverVSCodeSource() throws {
        var task = AgentTask(id: "one")
        #expect(CodexEventReducer.apply(try record("session_meta", ["id": "one", "originator": "codex_work_desktop", "source": "vscode"]), to: &task))
        #expect(task.surface == .workDesktop)
        #expect(AgentSurface.resolve(originator: "codex_vscode", source: "vscode") == .vscode)
        #expect(AgentSurface.resolve(originator: "codex_cli_rs", source: "cli") == .cli)
    }
    @Test func completionFromOlderTurnCannotFinishCurrentTurn() throws {
        var task = AgentTask(id: "one")
        _ = CodexEventReducer.apply(try record("event_msg", ["type": "task_started", "turn_id": "new"]), to: &task)
        _ = CodexEventReducer.apply(try record("event_msg", ["type": "task_complete", "turn_id": "old"]), to: &task)
        #expect(task.state == .running)
        _ = CodexEventReducer.apply(try record("event_msg", ["type": "task_complete", "turn_id": "new"]), to: &task)
        #expect(task.state == .completed && task.question == nil)
    }
    @Test func questionOnlyClearsWhenItsMatchingCallReturns() throws {
        var task = AgentTask(id: "one")
        let args = "{\"questions\":[{\"question\":\"选哪个方向？\",\"options\":[{\"label\":\"方向 A\"},{\"label\":\"方向 B\"}]}]}"
        _ = CodexEventReducer.apply(try record("response_item", ["type": "function_call", "name": "request_user_input", "call_id": "q", "arguments": args]), to: &task)
        #expect(task.state == .waiting && task.question?.contains("方向 A") == true)
        _ = CodexEventReducer.apply(try record("response_item", ["type": "function_call", "name": "exec_command", "call_id": "tool"]), to: &task)
        #expect(task.state == .waiting)
        _ = CodexEventReducer.apply(try record("response_item", ["type": "function_call_output", "call_id": "tool"]), to: &task)
        #expect(task.state == .waiting && task.question != nil)
        _ = CodexEventReducer.apply(try record("response_item", ["type": "function_call_output", "call_id": "q"]), to: &task)
        #expect(task.state == .running && task.question == nil)
    }
    @Test func plainAssistantQuestionDoesNotBecomeVerifiedDecision() throws {
        var task = AgentTask(id: "one")
        _ = CodexEventReducer.apply(try record("response_item", ["type": "message", "role": "assistant", "content": [["text": "要不要继续？"]]]), to: &task)
        #expect(task.state == .unknown && task.question == nil)
    }
    @Test func asynchronousQuestionDoesNotClaimBlockedExecution() throws {
        var task = AgentTask(id: "one")
        _ = CodexEventReducer.apply(try record("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "async"]), to: &task)
        #expect(task.state == .running && task.waitingCalls.isEmpty)
    }
    @Test func staleAndReadFailureNeverClaimRunning() {
        var task = AgentTask(id: "one", state: .running, updatedAt: Date(timeIntervalSince1970: 100))
        #expect(task.displayedState(at: Date(timeIntervalSince1970: 279)) == .running)
        #expect(task.displayedState(at: Date(timeIntervalSince1970: 280)) == .unknown)
        task.live = true
        #expect(task.displayedState(at: Date(timeIntervalSince1970: 1000)) == .running)
        task.readError = true
        #expect(task.displayedState(at: Date(timeIntervalSince1970: 1000)) == .unknown)
    }
    @Test func runtimeIdleAndUnknownFlagsAreHandledConservatively() {
        let waiting = CodexEventReducer.runtimeTask(["id": "one", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]], fallback: nil)
        #expect(waiting?.state == .waiting && waiting?.live == true)
        let idle = CodexEventReducer.runtimeTask(["id": "one", "status": ["type": "idle"]], fallback: waiting)
        #expect(idle?.state == .idle && idle?.question == nil)
        let unknown = CodexEventReducer.runtimeTask(["id": "one", "status": ["type": "newServerStatus"]], fallback: waiting)
        #expect(unknown?.state == .unknown)
    }
    @Test func subagentIdentityIsPreserved() throws {
        var task = AgentTask(id: "child")
        _ = CodexEventReducer.apply(try record("session_meta", ["id": "child", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]]), to: &task)
        #expect(task.parentID == "parent")
    }
    @Test func malformedAndUnknownEventsDoNotCrash() throws {
        var task = AgentTask(id: "one")
        #expect(!CodexEventReducer.apply(Data("{bad".utf8), to: &task))
        #expect(CodexEventReducer.apply(try record("future_kind", [:]), to: &task))
        #expect(task.state == .unknown)
    }
}

@Suite("Read-only incremental discovery")
struct CodexLogTests {
    @Test func localDateAheadOfUTCDoesNotHideCurrentSession() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try line("session_meta", ["id": "local-date"]).write(to: file)
        let observer = CodexLogObserver(root: root)
        let beforeUTCMidnight = Date(timeIntervalSince1970: 1790989200 - 4 * 3600)
        #expect(await observer.snapshot(now: beforeUTCMidnight).tasks.first?.id == "local-date")
    }
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("sessions/2026/10/03")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (root, directory.appendingPathComponent("rollout-test.jsonl"))
    }
    private var now: Date { Date(timeIntervalSince1970: 1790989260) } // 2026-10-03 01:01 UTC
    private func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-03T01:00:00Z", "payload": payload])
        data.append(10); return data
    }
    @Test func discoversExistingSessionTitlesAndIncrementalCompletion() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var data = try line("session_meta", ["id": "one", "originator": "codex_work_desktop", "source": "vscode", "cwd": "/workspace/Prosio"])
        data.append(try line("event_msg", ["type": "task_started", "turn_id": "t1"]))
        try data.write(to: file)
        try Data("{\"id\":\"one\",\"thread_name\":\"真实任务标题\"}\n".utf8).write(to: root.appendingPathComponent("session_index.jsonl"))
        let observer = CodexLogObserver(root: root)
        let first = await observer.snapshot(now: now)
        #expect(first.tasks.count == 1 && first.tasks.first?.title == "真实任务标题")
        #expect(first.tasks.first?.state == .running)
        let unchanged = await observer.snapshot(now: now)
        #expect(unchanged.bytesRead == 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: line("event_msg", ["type": "task_complete", "turn_id": "t1"])); try handle.close()
        let completed = await observer.snapshot(now: now)
        #expect(completed.tasks.first?.state == .completed)
        #expect(try Data(contentsOf: file).starts(with: data))
    }
    @Test func partialRecordIsRetriedAfterWriterFinishes() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let meta = try line("session_meta", ["id": "one"])
        let event = try line("event_msg", ["type": "task_started", "turn_id": "t1"])
        let half = event.count / 2
        var data = meta; data.append(event.prefix(half)); try data.write(to: file)
        let observer = CodexLogObserver(root: root)
        #expect(await observer.snapshot(now: now).tasks.first?.state == .unknown)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: event.suffix(from: half)); try handle.close()
        #expect(await observer.snapshot(now: now).tasks.first?.state == .running)
    }
    @Test func truncationAndDeletionCannotLeaveOldRunningState() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var data = try line("session_meta", ["id": "one"])
        data.append(try line("event_msg", ["type": "task_started", "turn_id": "long-turn"]))
        try data.write(to: file)
        let observer = CodexLogObserver(root: root)
        #expect(await observer.snapshot(now: now).tasks.first?.state == .running)
        try line("session_meta", ["id": "replacement"]).write(to: file)
        let replaced = await observer.snapshot(now: now)
        #expect(replaced.tasks.first?.id == "replacement" && replaced.tasks.first?.state == .unknown)
        try FileManager.default.removeItem(at: file)
        #expect(await observer.snapshot(now: now).tasks.isEmpty)
    }
    @Test func largeLogIsBoundedAndRetainsMetadata() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var data = try line("session_meta", ["id": "large", "originator": "codex_cli_rs"])
        data.append(Data(repeating: 32, count: 2 * 1024 * 1024)); data.append(10)
        data.append(try line("event_msg", ["type": "task_complete", "turn_id": "t1"]))
        try data.write(to: file)
        let result = await CodexLogObserver(root: root).snapshot(now: now)
        #expect(result.bytesRead <= 600 * 1024)
        #expect(result.tasks.first?.id == "large" && result.tasks.first?.state == .completed)
        #expect(result.tasks.first?.truncated == true)
    }
    @Test func missingSourceAndSymlinkDoNotReadUnrelatedFiles() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("auth.json")
        let bytes = Data("credential sentinel".utf8)
        try bytes.write(to: secret)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        let result = await CodexLogObserver(root: root).snapshot(now: now)
        #expect(result.tasks.isEmpty && result.bytesRead == 0)
        #expect(try Data(contentsOf: secret) == bytes)
        let missing = await CodexAgentObserver(root: root.appendingPathComponent("missing")).snapshot(now: now)
        #expect(missing.tasks.isEmpty && !missing.warnings.isEmpty)
    }
    @Test func damagedRecordDoesNotLeaveVerifiedRunningState() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var data = try line("session_meta", ["id": "one"])
        data.append(try line("event_msg", ["type": "task_started", "turn_id": "t1"]))
        data.append(Data("{malformed}\n".utf8)); try data.write(to: file)
        let result = await CodexLogObserver(root: root).snapshot(now: now)
        #expect(result.tasks.first?.state == .unknown && result.tasks.first?.truncated == true)
    }
}

private actor DelayedObserver: AgentObserving {
    func snapshot(now: Date) async -> AgentMonitorSnapshot {
        try? await Task.sleep(for: .milliseconds(80))
        return AgentMonitorSnapshot(tasks: [AgentTask(id: "late")], checkedAt: now)
    }
}

@Suite("Monitoring lifecycle") @MainActor
struct AgentCoordinatorTests {
    @Test func menuPrioritizesAttentionAndExcludesStaleCounts() {
        let now = Date()
        let coordinator = AgentMonitorCoordinator(initial: AgentMonitorSnapshot(tasks: [
            AgentTask(id: "done", state: .completed, updatedAt: now),
            AgentTask(id: "stale", state: .running, updatedAt: now.addingTimeInterval(-500)),
            AgentTask(id: "running", state: .running, updatedAt: now.addingTimeInterval(-20)),
            AgentTask(id: "waiting", state: .waiting, updatedAt: now.addingTimeInterval(-10)),
            AgentTask(id: "failed", state: .failed, updatedAt: now.addingTimeInterval(-30)),
            AgentTask(id: "old", state: .completed, updatedAt: now.addingTimeInterval(-600))
        ], checkedAt: now))
        #expect(coordinator.runningCount == 1 && coordinator.attentionCount == 2)
        #expect(coordinator.menuTasks.map(\.id) == ["waiting", "failed", "running", "done", "stale"])
    }
    @Test func menuLifecycleRemembersPauseAndSurvivesDetailClose() throws {
        let suite = "prosio.agentMonitor.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AgentMonitorCoordinator(source: DelayedObserver(), defaults: defaults)
        coordinator.restoreMonitoring()
        #expect(coordinator.monitoring)
        coordinator.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(coordinator.monitoring)
        coordinator.stop(persistPreference: false)
        #expect(defaults.bool(forKey: "prosio.agentMonitor.enabled"))
        coordinator.restoreMonitoring()
        #expect(coordinator.monitoring)
        coordinator.stop()
        coordinator.restoreMonitoring()
        #expect(!coordinator.monitoring)
    }
    @Test func stoppedMonitorDiscardsPendingScan() async throws {
        let coordinator = AgentMonitorCoordinator(source: DelayedObserver())
        let request = Task { await coordinator.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        coordinator.stop()
        await request.value
        #expect(coordinator.snapshot.tasks.isEmpty && !coordinator.monitoring && !coordinator.refreshing)
    }
    @Test func filtersRespectStaleStatesAndPrioritizeDecisions() {
        let now = Date()
        let snapshot = AgentMonitorSnapshot(tasks: [
            AgentTask(id: "running", state: .running, updatedAt: now),
            AgentTask(id: "stale", state: .running, updatedAt: now.addingTimeInterval(-500)),
            AgentTask(id: "waiting", state: .waiting, updatedAt: now)
        ], checkedAt: now)
        let coordinator = AgentMonitorCoordinator(initial: snapshot)
        #expect(coordinator.visibleTasks.map(\.id) == ["waiting"])
        coordinator.filter = .active
        #expect(coordinator.visibleTasks.count == 2 && coordinator.visibleTasks.first?.id == "waiting")
        coordinator.filter = .recent
        #expect(coordinator.visibleTasks.count == 3)
    }
}
