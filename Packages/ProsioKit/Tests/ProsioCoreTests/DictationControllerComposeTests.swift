import Testing
@testable import ProsioCore

@MainActor
private func makeComposeController(
    audio: FakeAudio = FakeAudio(),
    cloud: FakeEngine,
    local: FakeEngine,
    composer: FakeComposer? = nil,
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
        composer: composer
    )
}

@Suite struct DictationControllerComposeTests {

    // MARK: - .dictate: rewrite

    @Test @MainActor func rewrite_AdaptToAppOnNonGeneralScene_InsertsComposedText() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("please review the attached document")])
        let local = FakeEngine(id: "local", steps: [.final("please review the attached document")])
        let composer = FakeComposer()
        composer.behavior = .delayThenDeltas(.milliseconds(100), ["Please review the ", "attached document."])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(bundleID: "com.apple.mail", appName: "Mail")
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.adaptToApp = true

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, contextProvider: contextProvider, history: history, settings: settings)

        controller.start(trigger: .hold)
        #expect(controller.scene == .email)
        #expect(controller.intent == .dictate)

        controller.stop()
        await waitUntil { controller.phase == .composing }
        #expect(controller.composeLabel == "Polishing…")

        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "Please review the attached document.")
        #expect(history.items.first?.text == "Please review the attached document.")
        #expect(history.items.first?.transcript == "please review the attached document")
        #expect(history.items.first?.intent == .dictate)
        #expect(composer.lastRequest?.mode == .rewrite)
        #expect(composer.lastRequest?.scene == .email)
    }

    @Test @MainActor func rewrite_GeneralScene_SkipsComposeEntirely() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("hello there")])
        let local = FakeEngine(id: "local", steps: [.final("hello there")])
        let composer = FakeComposer()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.adaptToApp = true
        // Default FakeContextProvider has no recognizable app -> .general scene.

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "hello there")
        #expect(composer.callCount == 0)
    }

    @Test @MainActor func rewrite_FailureFallsBackToUntransformedTranscript() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("draft message body")])
        let local = FakeEngine(id: "local", steps: [.final("draft message body")])
        let composer = FakeComposer()
        composer.behavior = .fail(.network("compose down"))
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(bundleID: "com.apple.mail", appName: "Mail")
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.adaptToApp = true

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, contextProvider: contextProvider, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        guard case .finished(let outcome) = controller.phase else {
            Issue.record("expected .finished, got \(controller.phase)")
            return
        }
        #expect(outcome == .pasted)
        #expect(controller.previewText == "draft message body")
    }

    @Test @MainActor func rewrite_TimeoutFallsBackToUntransformedTranscript() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("some text")])
        let local = FakeEngine(id: "local", steps: [.final("some text")])
        let composer = FakeComposer()
        composer.behavior = .hang
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(bundleID: "com.apple.mail", appName: "Mail")
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.adaptToApp = true

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, contextProvider: contextProvider, settings: settings)
        controller.composeTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "some text")
    }

    @Test @MainActor func noComposer_AdaptToAppOn_StillFastPath() async throws {
        // composer: nil -> P1 off, exactly today's behavior even with adaptToApp on and a
        // non-general scene.
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("hi")])
        let local = FakeEngine(id: "local", steps: [.final("hi")])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(bundleID: "com.apple.mail", appName: "Mail")
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.adaptToApp = true

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: nil, contextProvider: contextProvider, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "hi")
    }

    // MARK: - .dictate: translate

    @Test @MainActor func translateEnabled_ComposesWithTargetLanguage() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("hello world")])
        let local = FakeEngine(id: "local", steps: [.final("hello world")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["你好，", "世界"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.translateEnabled = true
        settings.translateTarget = "zh-CN"

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "你好，世界")
        #expect(composer.lastRequest?.mode == .translate)
        #expect(composer.lastRequest?.targetLanguage == "zh-CN")
        #expect(composer.lastRequest?.text == "hello world")
    }

    @Test @MainActor func oneOffTranslatePrefix_OverridesToggleAndStripsClientSide() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("翻译成英文：你好世界")])
        let local = FakeEngine(id: "local", steps: [.final("翻译成英文：你好世界")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["Hello world"])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.translateEnabled = false // prefix alone should trigger translate

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, history: history, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "Hello world")
        #expect(composer.lastRequest?.mode == .translate)
        #expect(composer.lastRequest?.targetLanguage == "en-US")
        #expect(composer.lastRequest?.text == "你好世界") // prefix stripped client-side
        #expect(history.items.first?.transcript == "翻译成英文：你好世界")
    }

    @Test @MainActor func translateFailure_CopiesToClipboardAndFails_NeverInsertsUntranslated() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("hello world")])
        let local = FakeEngine(id: "local", steps: [.final("hello world")])
        let composer = FakeComposer()
        composer.behavior = .fail(.network("translate down"))
        let inserter = FakeInserter()
        inserter.outcomeToReturn = .copiedToClipboard
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.translateEnabled = true

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, inserter: inserter, history: history, settings: settings)
        var completed: HistoryItem?
        controller.onSessionCompleted = { completed = $0 }

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .network("translate down"))
        // The untranslated transcript must never be pasted — it's handed to the inserter with a
        // nil context (clipboard-fallback semantics), and recorded as `.copiedToClipboard`.
        #expect(inserter.insertedTexts == ["hello world"])
        #expect(inserter.insertedContexts == [nil])
        #expect(history.items.first?.insertion == .copiedToClipboard)
        #expect(history.items.first?.text == "hello world")
        #expect(completed?.insertion == .copiedToClipboard)
    }

    // MARK: - .edit

    @Test @MainActor func edit_AutoResolvedWhenSelectionPresent_InsertsComposedResult() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("make it shorter")])
        let local = FakeEngine(id: "local", steps: [.final("make it shorter")])
        let composer = FakeComposer()
        composer.behavior = .delayThenDeltas(.milliseconds(100), ["Shortened text."])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Notes", selectedText: "This is the original, much longer text.")
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, contextProvider: contextProvider, inserter: inserter, history: history, settings: settings)

        controller.start(trigger: .hold) // no explicit intent -> auto-resolves to .edit
        #expect(controller.intent == .edit)

        controller.stop()
        await waitUntil { controller.phase == .composing }
        #expect(controller.composeLabel == "Editing…")

        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["Shortened text."])
        #expect(composer.lastRequest?.mode == .edit)
        #expect(composer.lastRequest?.selection == "This is the original, much longer text.")
        #expect(composer.lastRequest?.text == "make it shorter")
        #expect(history.items.first?.intent == .edit)
        #expect(history.items.first?.transcript == "make it shorter")
    }

    @Test @MainActor func edit_Failure_FailsWithSelectionUntouched() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("fix the grammar")])
        let local = FakeEngine(id: "local", steps: [.final("fix the grammar")])
        let composer = FakeComposer()
        composer.behavior = .fail(.transcriptionFailed("edit engine down"))
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Notes", selectedText: "some text")
        let inserter = FakeInserter()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, contextProvider: contextProvider, inserter: inserter, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("edit engine down"))
        // Selection untouched: the inserter is never called on edit failure.
        #expect(inserter.insertedTexts.isEmpty)
    }

    @Test @MainActor func edit_ExplicitIntentOverridesAutoResolution() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("just dictate this")])
        let local = FakeEngine(id: "local", steps: [.final("just dictate this")])
        let contextProvider = FakeContextProvider()
        // Selection present, but caller explicitly requests .dictate -> must not become .edit.
        contextProvider.contextToReturn = FocusContext(appName: "Notes", selectedText: "existing selection")
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, contextProvider: contextProvider, settings: settings)

        controller.start(trigger: .hold, intent: .dictate)
        #expect(controller.intent == .dictate)
        controller.cancel()
    }

    @Test @MainActor func edit_SecureInputNeverAutoResolvesToEdit() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.hang])
        let contextProvider = FakeContextProvider()
        contextProvider.contextToReturn = FocusContext(appName: "Notes", isSecureInput: true, selectedText: "password123")
        let settings = makeTestSettings()

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, contextProvider: contextProvider, settings: settings)

        controller.start(trigger: .hold)
        #expect(controller.intent == .dictate)
        controller.cancel()
    }

    // MARK: - .ask

    @Test @MainActor func ask_StreamsDeltasAndCanBeInserted() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("what is the capital of France")])
        let local = FakeEngine(id: "local", steps: [.final("what is the capital of France")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["Paris ", "is the capital of France."])
        let inserter = FakeInserter()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, inserter: inserter, settings: settings)

        controller.start(trigger: .hold, intent: .ask)
        #expect(controller.intent == .ask)
        controller.stop()

        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }
        #expect(controller.answer?.text == "Paris is the capital of France.")
        #expect(controller.answer?.question == "what is the capital of France")
        #expect(composer.lastRequest?.mode == .ask)

        await controller.insertAnswer()
        #expect(inserter.insertedTexts == ["Paris is the capital of France."])
        guard case .finished(let outcome) = controller.phase else {
            Issue.record("expected .finished, got \(controller.phase)")
            return
        }
        #expect(outcome == .pasted)
        #expect(controller.answer == nil)
    }

    @Test @MainActor func ask_ErrorSurfacesOnAnswerState() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("why is the sky blue")])
        let local = FakeEngine(id: "local", steps: [.final("why is the sky blue")])
        let composer = FakeComposer()
        composer.behavior = .fail(.network("ask down"))
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, settings: settings)

        controller.start(trigger: .hold, intent: .ask)
        controller.stop()

        await waitUntil { controller.answer?.isStreaming == false }
        #expect(controller.answer?.error == .network("ask down"))
        #expect(controller.phase == .answering)
    }

    @Test @MainActor func ask_EmptyStreamedAnswerSurfacesAsError() async throws {
        // The stream completes with no error but yields zero usable text (the real bug this test
        // guards against: a silently blank answer card with no error shown).
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("what time is it")])
        let local = FakeEngine(id: "local", steps: [.final("what time is it")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["", "   "]) // whitespace-only deltas -> nothing usable
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, settings: settings)

        controller.start(trigger: .hold, intent: .ask)
        controller.stop()

        await waitUntil { controller.answer?.isStreaming == false }
        #expect(controller.answer?.error == .network("empty answer"))
        #expect(controller.phase == .answering)
        // No turns recorded for a non-answer, and insertAnswer() must be a no-op (empty text).
        #expect(controller.answer?.turns.isEmpty == true)
        await controller.insertAnswer()
        #expect(controller.phase == .answering)
    }

    @Test @MainActor func ask_DismissGoesIdleWithoutInserting() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("a question")])
        let local = FakeEngine(id: "local", steps: [.final("a question")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["an answer"])
        let inserter = FakeInserter()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, inserter: inserter, settings: settings)

        controller.start(trigger: .hold, intent: .ask)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }

        controller.dismissAnswer()
        #expect(controller.answer == nil)
        #expect(controller.phase == .idle)
        #expect(inserter.insertedTexts.isEmpty)
    }

    @Test @MainActor func ask_FollowUpKeepsTurnsAndDismissingDictateClearsCard() async throws {
        let audio = FakeAudio()
        let firstCloud = FakeEngine(id: "cloud", steps: [.final("first question")])
        let firstLocal = FakeEngine(id: "local", steps: [.final("first question")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["first answer"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: firstCloud, local: firstLocal, composer: composer, settings: settings)

        controller.start(trigger: .hold, intent: .ask)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }
        #expect(controller.answer?.turns.count == 2) // user question + assistant answer

        // A follow-up .ask must NOT dismiss the card and must carry the prior turns as history.
        #expect(!controller.isBusy) // .answering isn't "busy", a new start() is allowed
        controller.start(trigger: .hold, intent: .ask)
        #expect(controller.answer != nil) // not dismissed
        controller.stop()
        await waitUntil { composer.callCount == 2 }
        await waitUntil { controller.answer?.isStreaming == false }

        #expect(composer.lastRequest?.history.count == 2)
        #expect(composer.lastRequest?.history.first?.text == "first question")
    }

    @Test @MainActor func startingDictateWhileAnsweringDismissesCardFirst() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("a question"), .hang])
        let local = FakeEngine(id: "local", steps: [.final("a question"), .hang])
        let composer = FakeComposer()
        composer.behavior = .deltas(["an answer"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, settings: settings)

        controller.start(trigger: .hold, intent: .ask)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }
        #expect(controller.answer != nil)

        // Starting a plain dictate session must dismiss the card first.
        let cloud2 = FakeEngine(id: "cloud2", steps: [.final("second controller question")])
        let local2 = FakeEngine(id: "local2", steps: [.final("second controller question")])
        let controller2 = makeComposeController(audio: FakeAudio(), cloud: cloud2, local: local2, composer: composer, settings: settings)
        controller2.start(trigger: .hold, intent: .ask)
        controller2.stop()
        await waitUntilAnswerReady(controller2)
        controller2.start(trigger: .hold, intent: .dictate)
        #expect(controller2.answer == nil)
        controller2.cancel()
    }

    @Test @MainActor func ask_EmptyQuestionCancelsSilently() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("   ")])
        let local = FakeEngine(id: "local", steps: [.final("   ")])
        let composer = FakeComposer()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeComposeController(audio: audio, cloud: cloud, local: local, composer: composer, settings: settings)

        controller.start(trigger: .toggle, intent: .ask)
        audio.push(makeAudioChunk(timestamp: 1.0)) // long enough that "empty" isn't the accidental-tap path
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        // Empty transcript is caught upstream (handleEmptyFinal) before ask-specific dispatch.
        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(error == .emptyTranscript)
        #expect(composer.callCount == 0)
    }
}

@MainActor
private func waitUntilAnswerReady(_ controller: DictationController) async {
    await waitUntil { controller.answer?.isStreaming == false }
}
