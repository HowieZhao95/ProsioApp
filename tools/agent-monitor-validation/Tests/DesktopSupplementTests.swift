import Foundation
import Testing

@Suite("Desktop task-bound supplements") @MainActor
struct DesktopSupplementTests {
    private func fixture(_ mode: String, expected: AgentCommandReceipt.State, mutates: Bool) async throws {
        let root = URL(fileURLWithPath: "/tmp/ps-\(UUID().uuidString.prefix(8))")
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
        let controller = CodexAgentController(root: root)
        let command = AgentCommand(taskID: "existing-thread", turnID: "turn-one", kind: .supplement,
                                   text: "Keep it concise; do not publish", route: .desktopIPC)
        let receipt = await controller.submit(command)
        #expect(receipt.state == expected)
        if expected == .applied { #expect(receipt.targetTurnID == "turn-one") }
        if expected == .appliedToNewTurn { #expect(receipt.targetTurnID == "turn-two") }
        #expect(await controller.submit(command) == receipt)
        process.waitUntilExit()
        let methods = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: socket.path + ".methods.json")))
        #expect(methods.filter { $0 == "thread-follower-steer-turn" }.count == (mutates ? 1 : 0))
        #expect(!methods.contains { $0.contains("approval") || $0.contains("start-turn") || $0.contains("update-thread") })
    }
    @Test func inputRecordAndActualTurnAreConfirmed() async throws {
        try await fixture("steer-normal", expected: .applied, mutates: true)
    }
    @Test func hostRetargetIsReportedAsNewTurnOfSameTask() async throws {
        try await fixture("steer-retarget", expected: .appliedToNewTurn, mutates: true)
    }
    @Test func approvalCannotBeBypassedBySupplement() async throws {
        try await fixture("steer-approval", expected: .rejected, mutates: false)
    }
    @Test func completedTaskDoesNotStartAnotherTurn() async throws {
        try await fixture("steer-ended", expected: .expired, mutates: false)
    }
    @Test func disconnectAfterSendIsUncertainAndNotRetried() async throws {
        try await fixture("steer-disconnect", expected: .uncertain, mutates: true)
    }
    @Test func acceptanceWithoutMatchingRecordIsUncertain() async throws {
        try await fixture("steer-no-evidence", expected: .uncertain, mutates: true)
    }
    @Test func explicitRejectionDoesNotClaimAcceptanceOrUncertainty() async throws {
        try await fixture("steer-reject", expected: .rejected, mutates: true)
    }
}
