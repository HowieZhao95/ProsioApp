import Foundation
import Testing
@testable import ProsioCore

/// Live, opt-in tests against a real running Prosio backend (never run by default / in CI).
///
/// Enable with:
///   PROSIO_BACKEND_URL=http://localhost:3200 PROSIO_DEV_EMAIL=qa@prosio.app swift test --filter LiveComposeTests
///
/// Requires the server running with `PROSIO_DEV_AUTH=1` and a real Gateway key configured.
@Suite(.serialized) struct LiveComposeTests {

    private static var backendURL: URL? {
        ProcessInfo.processInfo.environment["PROSIO_BACKEND_URL"].flatMap(URL.init(string:))
    }

    private static var devEmail: String? {
        ProcessInfo.processInfo.environment["PROSIO_DEV_EMAIL"]
    }

    private func makeSignedInClient() async throws -> BackendClient? {
        guard let backendURL = Self.backendURL, let devEmail = Self.devEmail else { return nil }

        // A real (not in-memory) file-backed store, in an isolated temp directory, so this never
        // touches the developer's actual dev-session.json or the system Keychain.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("prosio-live-tests-\(UUID().uuidString)")
        let keychain = FileBackedKeychain(fileURL: tempDir.appendingPathComponent("session.json"))

        let client = BackendClient(baseURL: backendURL, session: .shared, keychainService: "app.prosio.live-test", keychain: keychain)
        try await client.devSignIn(email: devEmail)
        return client
    }

    @Test func composeAskReturnsNonEmptyStreamedAnswer() async throws {
        guard let client = try await makeSignedInClient() else {
            // Not configured for live testing -> skip quietly rather than fail CI/default runs.
            return
        }

        let request = ComposeRequest(mode: .ask, text: "What is the capital of Portugal?", scene: .general)
        var collected = ""
        for try await delta in client.compose(request) {
            collected += delta
        }

        #expect(!collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "ask produced empty output")
        #expect(collected.localizedCaseInsensitiveContains("lisbon"))
    }

    @Test func composeEditReturnsNonEmptyStreamedOutput() async throws {
        guard let client = try await makeSignedInClient() else {
            return
        }

        let request = ComposeRequest(mode: .edit, text: "make it more concise", selection: "This is a very long and verbose sentence that says very little of substance.", scene: .general)
        var collected = ""
        for try await delta in client.compose(request) {
            collected += delta
        }

        #expect(!collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "edit produced empty output")
    }
}
