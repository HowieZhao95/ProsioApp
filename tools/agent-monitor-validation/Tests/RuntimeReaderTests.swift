import Foundation
import Testing

@Suite("Existing runtime read-only transport") @MainActor
struct RuntimeReaderTests {
    private func fixture(_ mode: String, body: (String) throws -> Void) throws {
        let path = "/tmp/prosio-rpc-\(UUID().uuidString.prefix(8)).sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fake_runtime.py")
        process.arguments = [script.path, path, mode]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".methods.json")
        }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        #expect(ready == Data("ready\n".utf8))
        try body(path)
        if mode == "normal" {
            process.waitUntilExit()
            let data = try Data(contentsOf: URL(fileURLWithPath: path + ".methods.json"))
            let methods = try JSONDecoder().decode([String].self, from: data)
            #expect(methods == ["initialize", "initialized", "thread/loaded/list", "thread/read"])
        }
    }
    @Test func attachesToExistingThreadAndNeverAnswersApproval() throws {
        try fixture("normal") { path in
            let tasks = try CodexRuntimeReader().read(socketPath: path)
            #expect(tasks.count == 1 && tasks.first?["id"] as? String == "existing-thread")
            let task = CodexEventReducer.runtimeTask(tasks[0], fallback: nil)
            #expect(task?.state == .waiting && task?.live == true)
        }
    }
    @Test func rejectsForgedWebSocketHandshake() throws {
        try fixture("bad-handshake") { path in
            #expect(throws: (any Error).self) { try CodexRuntimeReader().read(socketPath: path) }
        }
    }
    @Test func unresponsiveRuntimeIsBounded() throws {
        try fixture("timeout") { path in
            let started = Date()
            #expect(throws: (any Error).self) { try CodexRuntimeReader(timeout: 0.15).read(socketPath: path) }
            #expect(Date().timeIntervalSince(started) < 1)
        }
    }
    @Test func oversizedMessageIsRejectedBeforeAllocatingBody() throws {
        try fixture("oversized") { path in
            #expect(throws: (any Error).self) { try CodexRuntimeReader().read(socketPath: path) }
        }
    }
    @Test func missingEndpointDoesNotLaunchReplacement() {
        #expect(throws: (any Error).self) { try CodexRuntimeReader().read(socketPath: "/tmp/prosio-missing-endpoint.sock") }
    }
}
