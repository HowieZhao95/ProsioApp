import Testing
@testable import ProsioCore

/// P1.2: intent classification is now inline with the single `/api/transcribe` response
/// (`CloudTranscript.intent`) — there's no more separate client-side classifier race/timeout
/// machinery (that lived here pre-P1.2). `IntentRules` remains the fallback when the server's
/// intent is `nil` (Jev unavailable) or the request never reaches the server at all (offline —
/// covered in `DictationControllerTests`).
@MainActor
private func makeController(
    audio: FakeAudio = FakeAudio(),
    local: FakeEngine,
    cloud: FakeCloudTranscriber,
    composer: FakeComposer? = nil,
    contextProvider: FakeContextProvider = FakeContextProvider(),
    inserter: FakeInserter = FakeInserter(),
    settings: AppSettings = makeTestSettings()
) -> DictationController {
    DictationController(
        audio: audio,
        localEngine: local,
        cloudTranscriber: cloud,
        inserter: inserter,
        contextProvider: contextProvider,
        history: HistoryStore(fileURL: nil),
        dictionary: DictionaryStore(fileURL: nil),
        settings: settings,
        composer: composer
    )
}

@Suite struct DictationControllerIntentClassificationTests {

    @Test @MainActor func serverIntentEdit_RoutesToComposeEdit() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("make it punchier")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "make it punchier",
            source: "cloud",
            intent: IntentDecision(intent: .edit, confidence: 0.95, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Punchier text."])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Notes", selectedText: "Some long dull text.")
        let inserter = FakeInserter()

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, contextProvider: contextProvider, inserter: inserter)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["Punchier text."])
        #expect(controller.intent == .edit)
        #expect(composer.lastRequest?.mode == .edit)
        #expect(composer.lastRequest?.selection == "Some long dull text.")
    }

    @Test @MainActor func serverIntentAsk_RoutesToAnswerCardWithWholeTranscript() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("Prosio what is the capital of Portugal")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "Prosio what is the capital of Portugal",
            source: "cloud",
            intent: IntentDecision(intent: .ask, confidence: 0.92, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Lisbon."])

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .ask)
        // Whole transcript is the question — no client-side stripping for a server-classified decision.
        #expect(composer.lastRequest?.text == "Prosio what is the capital of Portugal")
        #expect(controller.answer?.text == "Lisbon.")
    }

    @Test @MainActor func serverIntentTranslate_SendsWholeUtteranceAsTranslateCommand() async throws {
        let audio = FakeAudio()
        let transcript = "帮我翻成日语：我们明天开会"
        let local = FakeEngine(id: "local", steps: [.final(transcript)])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: transcript,
            source: "cloud",
            intent: IntentDecision(intent: .translate, confidence: 0.88, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["会議は明日です。"])
        let settings = makeTestSettings()
        settings.translateTarget = "ja-JP"

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(composer.lastRequest?.mode == .translateCommand)
        #expect(composer.lastRequest?.text == transcript) // whole utterance, not stripped
        #expect(composer.lastRequest?.targetLanguage == "ja-JP")
        #expect(controller.previewText == "会議は明日です。")
        #expect(controller.sessionTranslateTarget == nil) // cleared once the session finishes
    }

    @Test @MainActor func nullServerIntent_RuleCueParsedClientSide() async throws {
        // `intent: null` (Jev unavailable server-side) -> `IntentRules` sees the translate cue and
        // strips it client-side (mode .translate, not .translateCommand), unlike the case above.
        let audio = FakeAudio()
        let transcript = "翻译成英文：你好世界"
        let local = FakeEngine(id: "local", steps: [.final(transcript)])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: transcript,
            source: "cloud",
            intent: IntentDecision(intent: nil, confidence: nil, source: "unavailable")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Hello world"])

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(composer.lastRequest?.mode == .translate)
        #expect(composer.lastRequest?.text == "你好世界")
        #expect(controller.previewText == "Hello world")
    }

    @Test @MainActor func noServerIntentField_FalseCommandSafety_DegradesToRulesThenDictate() async throws {
        // The response has no `intent` at all (e.g. a pre-P1.2 server) and the transcript has no
        // rule cue either -> must safely default to `.dictate`, never leave the session stuck or
        // mis-routed.
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("this is just a normal sentence")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "this is just a normal sentence", source: "cloud"))

        let controller = makeController(audio: audio, local: local, cloud: cloud)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "this is just a normal sentence")
        #expect(controller.intent == .dictate)
    }

    @Test @MainActor func followUpWhileAnswering_SkipsServerIntentEntirely() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("first question")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "first question",
            source: "cloud",
            intent: IntentDecision(intent: .dictate, confidence: 0.9, source: "jev")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["first answer"])

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer)

        controller.start(trigger: .hold, intent: .ask) // simulate the first ask (as if classified)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }

        // Follow-up: fn press while answering, no explicit intent this time -> always `.ask`
        // regardless of what the (still `.dictate`-scripted) fake cloud transcriber would say.
        controller.start(trigger: .hold)
        #expect(controller.intent == .ask)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }
        controller.cancel()
    }
}
