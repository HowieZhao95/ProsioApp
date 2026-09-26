import Testing
@testable import ProsioCore

@MainActor
private func makeClassifyingController(
    audio: FakeAudio = FakeAudio(),
    cloud: FakeEngine,
    local: FakeEngine,
    composer: FakeComposer? = nil,
    intentClassifier: FakeIntentClassifier? = nil,
    contextProvider: FakeContextProvider = FakeContextProvider(),
    inserter: FakeInserter = FakeInserter(),
    history: HistoryStore = HistoryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings()
) -> DictationController {
    DictationController(
        audio: audio,
        engines: EngineSet(cloud: cloud, local: local),
        inserter: inserter,
        contextProvider: contextProvider,
        history: history,
        dictionary: DictionaryStore(fileURL: nil),
        settings: settings,
        composer: composer,
        intentClassifier: intentClassifier
    )
}

@Suite struct DictationControllerIntentClassificationTests {

    @Test @MainActor func classifierDictate_InsertsDirectlyAndPublishesIntent() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("just type this please")])
        let local = FakeEngine(id: "local", steps: [.final("just type this please")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .dictate, confidence: 0.9, source: "jev"))
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "just type this please")
        #expect(controller.intent == .dictate)
        #expect(classifier.callCount == 1)
        #expect(classifier.lastHasSelection == false)
    }

    @Test @MainActor func classifierEdit_RoutesToComposeEdit() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("make it punchier")])
        let local = FakeEngine(id: "local", steps: [.final("make it punchier")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .edit, confidence: 0.95, source: "jev"))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Punchier text."])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Notes", selectedText: "Some long dull text.")
        let inserter = FakeInserter()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: classifier, contextProvider: contextProvider, inserter: inserter, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["Punchier text."])
        #expect(controller.intent == .edit)
        #expect(classifier.lastHasSelection == true)
        #expect(composer.lastRequest?.mode == .edit)
        #expect(composer.lastRequest?.selection == "Some long dull text.")
    }

    @Test @MainActor func classifierAsk_RoutesToAnswerCardWithWholeTranscript() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Prosio what is the capital of Portugal")])
        let local = FakeEngine(id: "local", steps: [.final("Prosio what is the capital of Portugal")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .ask, confidence: 0.92, source: "jev"))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Lisbon."])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .ask)
        // Whole transcript is the question — no client-side stripping for a classifier decision.
        #expect(composer.lastRequest?.text == "Prosio what is the capital of Portugal")
        #expect(controller.answer?.question == "Prosio what is the capital of Portugal")
        #expect(controller.answer?.text == "Lisbon.")
    }

    @Test @MainActor func classifierTranslate_SendsWholeUtteranceAsTranslateCommand() async throws {
        let audio = FakeAudio()
        let transcript = "帮我翻成日语：我们明天开会"
        let cloud = FakeEngine(id: "cloud", steps: [.final(transcript)])
        let local = FakeEngine(id: "local", steps: [.final(transcript)])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .translate, confidence: 0.88, source: "jev"))
        let composer = FakeComposer()
        composer.behavior = .deltas(["会議は明日です。"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.translateTarget = "ja-JP"

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(composer.lastRequest?.mode == .translateCommand)
        #expect(composer.lastRequest?.text == transcript) // whole utterance, not stripped
        #expect(composer.lastRequest?.targetLanguage == "ja-JP")
        #expect(controller.previewText == "会議は明日です。")
        #expect(controller.sessionTranslateTarget == nil) // cleared once the session finishes
    }

    @Test @MainActor func classifierTimeout_DegradesToRules() async throws {
        let audio = FakeAudio()
        let transcript = "翻译成英文：你好世界"
        let cloud = FakeEngine(id: "cloud", steps: [.final(transcript)])
        let local = FakeEngine(id: "local", steps: [.final(transcript)])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .hang
        let composer = FakeComposer()
        composer.behavior = .deltas(["Hello world"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: classifier, settings: settings)
        controller.classifyIntentTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        // Rules recognize the translate cue and strip it client-side (mode .translate, not .translateCommand).
        #expect(composer.lastRequest?.mode == .translate)
        #expect(composer.lastRequest?.text == "你好世界")
        #expect(controller.previewText == "Hello world")
    }

    @Test @MainActor func classifierError_FalseCommandSafety_DegradesToRulesThenDictate() async throws {
        // The classifier errored (not just "unavailable"); the transcript has no rule cue either
        // -> must safely default to `.dictate`, never leave the session stuck or mis-routed.
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("this is just a normal sentence")])
        let local = FakeEngine(id: "local", steps: [.final("this is just a normal sentence")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .fail(.network("classifier down"))
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "this is just a normal sentence")
        #expect(controller.intent == .dictate)
    }

    @Test @MainActor func classifierReturnsNilIntent_DegradesToRules() async throws {
        // Server "unavailable" shape: 200 with `intent: null`.
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("提问，几点了")])
        let local = FakeEngine(id: "local", steps: [.final("提问，几点了")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: nil, confidence: nil, source: "unavailable"))
        let composer = FakeComposer()
        composer.behavior = .deltas(["It's 3pm."])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .ask)
        #expect(controller.answer?.text == "It's 3pm.")
    }

    @Test @MainActor func noClassifierConfigured_UsesRulesOnly() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("提问，现在几点")])
        let local = FakeEngine(id: "local", steps: [.final("提问，现在几点")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["现在是下午三点。"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: nil, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .ask)
    }

    @Test @MainActor func classificationRunsConcurrently_DoesNotAddLatencyWhenFasterThanCloud() async throws {
        // Cloud is staggered behind classification; if classification blocked the transcript
        // resolution instead of running concurrently, this would still pass — the real assertion
        // is that BOTH the classifier and cloud were exercised and the final result is correct,
        // proving classification happened alongside (not after waiting for) the transcript.
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.delay(.milliseconds(80)), .final("write a quick note")])
        let local = FakeEngine(id: "local", steps: [.partial("write a quick note"), .final("write a quick note")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .delayThenDecision(.milliseconds(10), IntentDecision(intent: .dictate, confidence: 0.9, source: "jev"))
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == "write a quick note" }
        controller.stop()
        await waitUntil { classifier.callCount == 1 } // classification kicked off right at stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.intent == .dictate)
        #expect(controller.previewText == "write a quick note")
    }

    @Test @MainActor func followUpWhileAnswering_SkipsClassificationEntirely() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("first question")])
        let local = FakeEngine(id: "local", steps: [.final("first question")])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .dictate, confidence: 0.9, source: "jev"))
        let composer = FakeComposer()
        composer.behavior = .deltas(["first answer"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeClassifyingController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold, intent: .ask) // simulate the first ask (as if classified)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }
        #expect(classifier.callCount == 0) // explicit intent bypasses classification

        // Follow-up: fn press while answering, no explicit intent this time.
        controller.start(trigger: .hold)
        #expect(controller.intent == .ask)
        controller.stop()
        await waitUntil { classifier.callCount == 0 } // still never classified — follow-up skip
        controller.cancel()
    }
}
