import Foundation
import Testing

@Suite("Desktop original-request loop") @MainActor
struct DesktopIPCTests {
    private func fixture(_ mode: String, expected: AgentCommandReceipt.State, mutates: Bool) async throws {
        let root = URL(fileURLWithPath: "/tmp/pi-\(UUID().uuidString.prefix(8))")
        let directory = root.appendingPathComponent("ipc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("ipc.sock")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fake_desktop_ipc.py")
        process.arguments = [script.path, socket.path, mode]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(try pipe.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
        let decision = AgentDecision(id: "direction", callID: "i:17", turnID: "turn-one",
            title: "Choose a direction", options: [.init(label: "A", detail: "Lower cost"), .init(label: "B", detail: "More scope")], requestID: .integer(17))
        let command = AgentCommand(taskID: "existing-thread", turnID: "turn-one", kind: .answer,
            route: .desktopIPC, decisions: [decision], answers: ["direction": ["A"]])
        let controller = CodexAgentController(root: root)
        let receipt = await controller.submit(command)
        #expect(receipt.state == expected)
        #expect(await controller.submit(command) == receipt)
        process.waitUntilExit()
        let methods = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: socket.path + ".methods.json")))
        #expect(methods.filter { $0 == "thread-follower-submit-user-input" }.count == (mutates ? 1 : 0))
        #expect(!methods.contains { $0.contains("approval") || $0.contains("start-turn") || $0.contains("steer") })
    }
    @Test func matchingRecordedAnswerProvesApplication() async throws {
        try await fixture("normal", expected: .applied, mutates: true)
    }
    @Test func otherDeviceAnswerIsNotOurSuccess() async throws {
        try await fixture("conflict", expected: .expired, mutates: true)
    }
    @Test func disappearingQuestionWithoutAnswerEvidenceIsUncertain() async throws {
        try await fixture("no-evidence", expected: .uncertain, mutates: true)
    }
    @Test func interruptedConnectionNeverRetriesAnswer() async throws {
        try await fixture("disconnect", expected: .uncertain, mutates: true)
    }
    @Test func changedTurnDoesNotReceiveOldAnswer() async throws {
        try await fixture("stale-turn", expected: .expired, mutates: false)
    }
    @Test func alreadyResolvedQuestionDoesNotReceiveAnotherAnswer() async throws {
        try await fixture("already-resolved", expected: .expired, mutates: false)
    }
    @Test func newProtocolIsNotBlindlyTrusted() async throws {
        try await fixture("new-version", expected: .notDelivered, mutates: false)
    }
    @Test func recordedAnswerIsNotResentEvenWhenPendingCardLags() async throws {
        try await fixture("recorded-pending", expected: .applied, mutates: false)
    }
    @Test func recordedDifferentAnswerCannotBeOverwrittenByPendingCard() async throws {
        try await fixture("recorded-conflict", expected: .expired, mutates: false)
    }
}
