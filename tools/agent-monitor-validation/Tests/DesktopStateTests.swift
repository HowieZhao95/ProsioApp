import Foundation
import Testing

@Suite("Desktop state interpretation")
struct DesktopStateTests {
    private func state() -> [String: Any] {
        ["id": "thread", "threadRuntimeStatus": ["type": "active", "activeFlags": ["waitingOnUserInput"]],
         "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": [
            "old": ["turnId": "old-turn", "status": "completed", "turnStartedAtMs": 100, "items": []],
            "current": ["turnId": "current-turn", "status": "inProgress", "turnStartedAtMs": 200, "items": []]]]],
         "requests": [["id": "request", "method": "item/tool/requestUserInput", "params": [
            "threadId": "thread", "turnId": "current-turn", "questions": [[
                "id": "question", "question": "Pick one", "options": [["label": "A", "description": "Lower cost"]]]]]]]]
    }
    @Test func canonicalHistorySelectsCurrentTurnAndPreservesRequestIdentity() {
        let task = CodexDesktopState.task(state(), fallback: nil, now: Date())
        #expect(task?.turnID == "current-turn" && task?.state == .waiting)
        #expect(task?.decisions.first?.requestID == .string("request"))
        #expect(task?.controlRoute == .desktopIPC)
    }
    @Test func otherThreadRequestCannotBecomeOurDecision() {
        var value = state()
        value["requests"] = [["id": 17, "method": "item/tool/requestUserInput", "params": [
            "threadId": "other-thread", "turnId": "current-turn", "questions": [["id": "q", "question": "Pick"]]]]]
        #expect(CodexDesktopState.task(value, fallback: nil, now: Date())?.decisions.isEmpty == true)
    }
    @Test func missingQuestionIDsCannotProduceSubmitButtons() {
        var value = state()
        value["requests"] = [["id": 17, "method": "item/tool/requestUserInput", "params": [
            "threadId": "thread", "turnId": "current-turn", "questions": [["question": "Pick"]]]]]
        #expect(CodexDesktopState.task(value, fallback: nil, now: Date())?.decisions.isEmpty == true)
    }
    @Test func approvalRemainsDistinctAndDoesNotBecomeAnswerable() {
        var value = state()
        value["threadRuntimeStatus"] = ["type": "active", "activeFlags": ["waitingOnApproval"]]
        value["requests"] = [["id": 17, "method": "item/commandExecution/requestApproval", "params": [:]]]
        let task = CodexDesktopState.task(value, fallback: nil, now: Date())
        #expect(task?.stateLabel == "等待操作审批" && task?.decisions.isEmpty == true)
    }
    @Test func disappearingRequestIsNotProofOfAnswerApplication() {
        var value = state(); value["requests"] = []
        #expect(CodexDesktopState.recordedAnswers(value, requestID: .string("request"), turnID: "current-turn") == nil)
    }
    @Test func optionAndContextAreNotSilentlyTruncated() {
        let title = String(repeating: "Context ", count: 200)
        let args = "{\"questions\":[{\"id\":\"q\",\"question\":\"\(title)\",\"options\":[\"A\",\"B\",\"C\",\"D\"]}]}"
        let decisions = CodexEventReducer.decisions(from: args, callID: "call", turnID: "turn")
        #expect(decisions.first?.title == title && decisions.first?.options.count == 4)
    }
}
