import Foundation
import Testing

@Suite("Original turn control") @MainActor
struct AgentControlTests {
    private func fixture(_ mode: String, kind: AgentCommand.Kind = .supplement,
                         expected: AgentCommandReceipt.State, mutates: Bool) async throws {
        let root = URL(fileURLWithPath: "/tmp/pc-\(UUID().uuidString.prefix(8))")
        let directory = root.appendingPathComponent("app-server-control")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("app-server-control.sock")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fake_runtime.py")
        process.arguments = [script.path, socket.path, mode]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(try output.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
        let controller = CodexAgentController(root: root)
        let command = AgentCommand(taskID: "existing-thread", turnID: "turn-one", kind: kind, text: "Keep it concise")
        let receipt = await controller.submit(command)
        #expect(receipt.state == expected)
        // The same request must return its previous outcome without touching the transport again.
        #expect(await controller.submit(command) == receipt)
        process.waitUntilExit()
        let methods = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: socket.path + ".methods.json")))
        #expect(methods == ["initialize", "initialized", "thread/read"] + (mutates ? [kind == .interrupt ? "turn/interrupt" : "turn/steer"] : []))
    }
    @Test func supplementBindsToCurrentTurnAndDeduplicates() async throws {
        try await fixture("control-normal", expected: .accepted, mutates: true)
    }
    @Test func staleTurnNeverReceivesInput() async throws {
        try await fixture("control-stale", expected: .expired, mutates: false)
    }
    @Test func approvalCannotBeAnsweredBySupplement() async throws {
        try await fixture("control-approval", expected: .rejected, mutates: false)
    }
    @Test func disconnectAfterSendIsUncertainAndNeverRetried() async throws {
        try await fixture("control-disconnect", expected: .uncertain, mutates: true)
    }
    @Test func rejectionDoesNotClaimAcceptance() async throws {
        try await fixture("control-reject", expected: .rejected, mutates: true)
    }
    @Test func interruptIsOnlyARequestToOriginalTurn() async throws {
        try await fixture("control-normal", kind: .interrupt, expected: .accepted, mutates: true)
    }
    @Test func offlineIsNotDelivered() async {
        let controller = CodexAgentController(root: URL(fileURLWithPath: "/tmp/nonexistent-prosio-controller"))
        let receipt = await controller.submit(.init(taskID: "one", turnID: "turn", kind: .supplement, text: "Hello"))
        #expect(receipt.state == .notDelivered)
    }
}
