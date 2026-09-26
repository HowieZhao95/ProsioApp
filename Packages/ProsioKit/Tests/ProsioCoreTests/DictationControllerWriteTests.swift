import Foundation
import Testing
@testable import ProsioCore

/// "Help me write" (docs/PROMPTS.md §4b, P1.3). No selection: composes and inserts at the cursor.
/// With a selection: streams into the answer card (selection is context, never rewritten) so
/// Insert/Copy decide. Any compose failure/empty result is uniform: nothing inserted, the
/// instruction goes to the clipboard, session fails with a fixed HUD message.
@MainActor
private func makeController(
    audio: FakeAudio = FakeAudio(),
    local: FakeEngine,
    cloud: FakeCloudTranscriber,
    composer: FakeComposer? = nil,
    contextProvider: FakeContextProvider = FakeContextProvider(),
    inserter: FakeInserter = FakeInserter(),
    history: HistoryStore = HistoryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings()
) -> DictationController {
    DictationController(
        audio: audio,
        localEngine: local,
        cloudTranscriber: cloud,
        inserter: inserter,
        contextProvider: contextProvider,
        history: history,
        dictionary: DictionaryStore(fileURL: nil),
        settings: settings,
        composer: composer
    )
}

private func waitForDebugFile(_ filename: String, in root: URL, timeout: TimeInterval = 3) async -> URL? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries {
                let candidate = entry.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

@Suite struct DictationControllerWriteTests {

    @Test @MainActor func serverIntentWrite_NoSelection_InsertsComposedTextAtCursor() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我写一封感谢邮件给老王")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我写一封感谢邮件给老王",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        // Delayed so `.composing` is observable by the poll below rather than resolving before it
        // ever checks (see `FakeComposer.Behavior.delayThenDeltas`'s doc comment).
        composer.behavior = .delayThenDeltas(.milliseconds(100), ["王先生您好，非常感谢您的帮助。"])
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, inserter: inserter, history: history)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .composing }
        #expect(controller.composeLabel == "Writing…")
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["王先生您好，非常感谢您的帮助。"])
        #expect(controller.intent == .write)
        #expect(composer.lastRequest?.mode == .write)
        #expect(composer.lastRequest?.text == "帮我写一封感谢邮件给老王")
        #expect(composer.lastRequest?.selection == nil)
        // History keeps both the instruction (transcript) and the generated text.
        #expect(history.items.first?.text == "王先生您好，非常感谢您的帮助。")
        #expect(history.items.first?.transcript == "帮我写一封感谢邮件给老王")
        #expect(history.items.first?.intent == .write)
    }

    @Test @MainActor func rulesWriteCue_NoSelection_InsertsComposedText() async throws {
        // Jev unavailable (`intent: null`) -> IntentRules recognizes the write cue client-side.
        let audio = FakeAudio()
        let transcript = "help me write a follow-up to the client"
        let local = FakeEngine(id: "local", steps: [.final(transcript)])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: transcript, source: "cloud", intent: IntentDecision(intent: nil, confidence: nil, source: "unavailable")))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Hi team, following up on our last conversation."])

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.intent == .write)
        #expect(composer.lastRequest?.mode == .write)
        #expect(composer.lastRequest?.text == transcript)
    }

    @Test @MainActor func writeWithSelection_StreamsIntoAnswerCardAndNeverReplacesSelection() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我回复说好的没问题")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我回复说好的没问题",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["好的，", "没问题。"])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Messages", selectedText: "明天能来开会吗？")
        let inserter = FakeInserter()

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, contextProvider: contextProvider, inserter: inserter)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .write)
        #expect(controller.answer?.text == "好的，没问题。")
        #expect(controller.answer?.question == "帮我回复说好的没问题")
        #expect(composer.lastRequest?.mode == .write)
        #expect(composer.lastRequest?.selection == "明天能来开会吗？")
        // Nothing auto-inserted, and the selection itself is untouched (no insert call at all yet).
        #expect(inserter.insertedTexts.isEmpty)

        await controller.insertAnswer()
        #expect(inserter.insertedTexts == ["好的，没问题。"])
        guard case .finished = controller.phase else {
            Issue.record("expected .finished, got \(controller.phase)")
            return
        }
        // `insertAnswer()` must record this card's actual intent (.write), not a hardcoded .ask.
    }

    @Test @MainActor func writeFailure_NoSelection_ClipboardFallbackAndHUDError() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我写一封感谢邮件")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我写一封感谢邮件",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .fail(.network("compose down"))
        let inserter = FakeInserter()
        inserter.outcomeToReturn = .copiedToClipboard
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, inserter: inserter, history: history)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("Couldn't write that — your words are on the clipboard"))
        #expect(inserter.insertedTexts == ["帮我写一封感谢邮件"])
        #expect(inserter.insertedContexts == [nil]) // clipboard-fallback semantics, never pasted anywhere
        #expect(history.items.first?.insertion == .copiedToClipboard)
        #expect(history.items.first?.text == "帮我写一封感谢邮件")
    }

    @Test @MainActor func writeFailure_WithSelection_NoInCardErrorJustClipboardFallback() async throws {
        // Even on the with-selection path, a compose failure must NOT leave a half-drafted answer
        // card with an in-card error — it collapses to the same uniform clipboard-fallback failure.
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我回复说收到了")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我回复说收到了",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .fail(.network("compose down"))
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Messages", selectedText: "文件收到了吗？")
        let inserter = FakeInserter()

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, contextProvider: contextProvider, inserter: inserter)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("Couldn't write that — your words are on the clipboard"))
        #expect(controller.answer == nil)
        #expect(inserter.insertedTexts == ["帮我回复说收到了"])
    }

    @Test @MainActor func writeFailure_EmptyComposeResult_ClipboardFallback() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我写一封邮件")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我写一封邮件",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["", "   "]) // whitespace-only -> nothing usable
        let inserter = FakeInserter()

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, inserter: inserter)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("Couldn't write that — your words are on the clipboard"))
        #expect(inserter.insertedTexts == ["帮我写一封邮件"])
    }

    @Test @MainActor func writeFailure_NoComposerConfigured_ClipboardFallback() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我写一封邮件")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我写一封邮件",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let inserter = FakeInserter()

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: nil, inserter: inserter)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("Couldn't write that — your words are on the clipboard"))
        #expect(inserter.insertedTexts == ["帮我写一封邮件"])
    }

    @Test @MainActor func debugRecordingUsesWriteComposeMode() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("帮我写一封感谢邮件")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "帮我写一封感谢邮件",
            source: "cloud",
            intent: IntentDecision(intent: .write, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["谢谢你的帮助。"])
        let settings = makeTestSettings()
        settings.saveDebugRecordings = true

        let controller = DictationController(
            audio: audio,
            localEngine: local,
            cloudTranscriber: cloud,
            inserter: FakeInserter(),
            contextProvider: FakeContextProvider(),
            history: HistoryStore(fileURL: nil),
            dictionary: DictionaryStore(fileURL: nil),
            settings: settings,
            composer: composer
        )
        controller.debugRecordingsRootOverride = root

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DebugSessionRecord.self, from: Data(contentsOf: jsonURL))

        #expect(record.composeMode == "write")
        #expect(record.intent == "write")
        #expect(record.intentDecisionClassified == "write")
    }
}
