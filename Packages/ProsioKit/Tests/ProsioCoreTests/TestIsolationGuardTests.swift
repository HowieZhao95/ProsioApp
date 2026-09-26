import Foundation
import Testing
@testable import ProsioCore

/// Test-isolation regression guard (2026-09-26): `AppSettings.saveDebugRecordings` defaults to
/// `true`, and `DictationController` falls back to the REAL
/// `~/Library/Application Support/Prosio/debug` whenever `debugRecordingsRootOverride` isn't set —
/// which is how nearly every test in this package builds its controller. `swift test` was silently
/// writing dozens of debug recordings (test fixture text under real-looking session IDs) into that
/// directory on every run and, since only the last 30 are kept, evicting the user's real ones.
/// `makeTestSettings()` now defaults `saveDebugRecordings` to `false` — this suite guards that fix.
@Suite struct TestIsolationGuardTests {

    private static var realDebugRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Prosio/debug", directoryHint: .isDirectory)
    }

    @Test @MainActor func makeTestSettingsDisablesDebugRecordingsByDefault() {
        let settings = makeTestSettings()
        #expect(settings.saveDebugRecordings == false)
    }

    /// Builds a controller exactly the way virtually every other test in this package does — default
    /// `makeTestSettings()`, no `debugRecordingsRootOverride` — and proves the two halves of the
    /// safety invariant: (1) its resolved debug root, absent an override, IS the real path (so this
    /// guard is actually exercising the dangerous default, not a already-safe one), and (2) it never
    /// gets there because `saveDebugRecordings` is off. A test that copies this pattern but flips
    /// `saveDebugRecordings` back on without also setting an override — the exact mistake this fix
    /// addresses — must be caught by the end-to-end assertion below, not silently pass here.
    @Test @MainActor func typicalTestConstructedControllerResolvesButNeverWritesToTheRealDebugRoot() {
        let settings = makeTestSettings()
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("guard")])
        let local = FakeEngine(id: "local", steps: [.final("guard")])
        let controller = DictationController(
            audio: audio,
            engines: EngineSet(cloud: cloud, local: local),
            inserter: FakeInserter(),
            contextProvider: FakeContextProvider(),
            history: HistoryStore(fileURL: nil),
            dictionary: DictionaryStore(fileURL: nil),
            settings: settings
        )

        #expect(controller.resolvedDebugRecordingsRootForTesting == Self.realDebugRoot)
        #expect(settings.saveDebugRecordings == false)
    }

    /// End-to-end proof: run a full session through a controller built exactly like the vast
    /// majority of this package's tests (default `makeTestSettings()`, no
    /// `debugRecordingsRootOverride`) and confirm the real Application Support debug directory
    /// gains no new entry. Directory-diff based (rather than assuming the directory doesn't exist)
    /// so it's resilient to whatever's already there — real recordings from actual app usage, or
    /// leftovers from before this fix.
    @Test @MainActor func fullSessionWithDefaultTestSettingsWritesNothingToRealApplicationSupport() async throws {
        let root = Self.realDebugRoot
        let before = Set((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent)) ?? [])

        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("isolation guard transcript")])
        let local = FakeEngine(id: "local", steps: [.final("isolation guard transcript")])
        let controller = DictationController(
            audio: audio,
            engines: EngineSet(cloud: cloud, local: local),
            inserter: FakeInserter(),
            contextProvider: FakeContextProvider(),
            history: HistoryStore(fileURL: nil),
            dictionary: DictionaryStore(fileURL: nil),
            settings: makeTestSettings()
        )

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }
        // `writeDebugRecording` (if it ran at all) dispatches its actual file I/O onto a detached
        // background task — give it a moment to land before checking, so a regression here would
        // reliably fail instead of racing.
        try? await Task.sleep(for: .milliseconds(200))

        let after = Set((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent)) ?? [])
        #expect(after == before, "a test-constructed controller with default settings wrote to the real debug recordings directory")
    }
}
