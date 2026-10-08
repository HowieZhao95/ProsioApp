import Foundation
import Testing

@Suite("Task-bound voice draft") @MainActor
struct AgentVoiceTests {
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }
    @Test func transcriptionKeepsCapturedTargetAndNeverSends() async throws {
        let voice = AgentVoiceInput()
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        var stopped = false
        var engineTarget: AgentVoiceTarget?
        voice.factory = { target in engineTarget = target; return AgentVoiceStream(text: pair.stream, stop: { stopped = true; pair.continuation.finish() }, cancel: {}) }
        var captured: AgentVoiceTarget?
        var draft: String?
        voice.onDraft = { captured = $0; draft = $1 }
        let target = AgentVoiceTarget(taskID: "A", taskTitle: "Task A", turnID: "turn-A")
        voice.start(target: target)
        try await settle { !voice.preparing }
        pair.continuation.yield("Choose A, keep the budget low")
        try await settle { !voice.text.isEmpty }
        #expect(draft == nil)
        // Starting another task while recording cannot redirect the destination.
        voice.start(target: .init(taskID: "B", taskTitle: "Task B", turnID: "turn-B"))
        #expect(voice.target == target)
        #expect(engineTarget == target)
        voice.finish()
        try await settle { !voice.finishing }
        #expect(stopped && captured == target && draft == "Choose A, keep the budget low")
    }
    @Test func cancellationDiscardsLateTranscription() async throws {
        let voice = AgentVoiceInput()
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        voice.factory = { _ in AgentVoiceStream(text: pair.stream, stop: {}, cancel: { pair.continuation.finish() }) }
        var applied = false
        voice.onDraft = { _, _ in applied = true }
        voice.start(target: .init(taskID: "A", taskTitle: "Task A", turnID: "turn-A"))
        try await settle { !voice.preparing }
        voice.cancel()
        pair.continuation.yield("This must not be applied")
        pair.continuation.finish()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!applied && voice.target == nil && voice.text.isEmpty)
    }
    @Test func permissionOrEngineFailurePreservesNoPhantomAnswer() async throws {
        let voice = AgentVoiceInput()
        voice.factory = { _ in throw CancellationError() }
        var applied = false
        voice.onDraft = { _, _ in applied = true }
        voice.start(target: .init(taskID: "A", taskTitle: "Task A", turnID: "turn-A"))
        try await settle { !voice.recording }
        #expect(!applied && voice.message != nil)
    }
}
