import Testing
@testable import ProsioCore

@MainActor
private func makeController(
    audio: FakeAudio = FakeAudio(),
    local: FakeEngine,
    cloud: FakeCloudTranscriber = FakeCloudTranscriber(),
    audioPreparer: any AudioPreparing = WAVAudioPreparer(),
    inserter: FakeInserter = FakeInserter(),
    contextProvider: FakeContextProvider = FakeContextProvider(),
    history: HistoryStore = HistoryStore(fileURL: nil),
    dictionary: DictionaryStore = DictionaryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings(),
    composer: FakeComposer? = nil
) -> DictationController {
    DictationController(
        audio: audio,
        localEngine: local,
        cloudTranscriber: cloud,
        inserter: inserter,
        contextProvider: contextProvider,
        history: history,
        dictionary: dictionary,
        settings: settings,
        audioPreparer: audioPreparer,
        composer: composer
    )
}

/// P1.2: no more engine-mode setting — every session runs the same flow (local preview + one
/// `/api/transcribe` request at `stop()`). See docs/P1.2-AUDIO-ROUTING.md.
@Suite struct DictationControllerTests {

    // MARK: - Single-request cloud pass

    @Test @MainActor func cloudSource_InsertsCloudTextAndUsesCloudEngineID() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.partial("L1"), .partial("L1 L2"), .final("L1 L2 done")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "Cloud final text", source: "cloud"))
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, inserter: inserter, history: history)

        controller.start(trigger: .hold)
        #expect(controller.phase == .listening)

        await waitUntil { controller.previewText == "L1 L2" }
        #expect(controller.previewText == "L1 L2")

        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["Cloud final text"])
        #expect(controller.previewText == "Cloud final text")
        #expect(controller.activeEngineID == DictationController.cloudEngineID)
        #expect(history.items.first?.text == "Cloud final text")
        #expect(history.items.first?.engineID == DictationController.cloudEngineID)
        #expect(cloud.lastRequest?.localTranscript == "L1 L2 done")
    }

    @Test @MainActor func localSource_InsertsLocalTextDirectlyAndSkipsCompose() async throws {
        // Server found the local transcript clean enough and skipped Gemini — the server-decided
        // text is inserted as-is, HUD finishes as normal (docs/P1.2-AUDIO-ROUTING.md §3 step 4).
        let audio = FakeAudio()
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.final("clean local text")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "clean local text",
            source: "local",
            intent: IntentDecision(intent: .dictate, confidence: 0.97, source: "jev"),
            route: TranscribeRouteInfo(cleanProbability: 0.98, reason: "clean")
        ))
        let composer = FakeComposer() // configured but must never be called on this fast path
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, inserter: inserter, history: history, composer: composer)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["clean local text"])
        #expect(controller.activeEngineID == local.id)
        #expect(controller.intent == .dictate)
        #expect(history.items.first?.engineID == local.id)
        #expect(composer.callCount == 0)
    }

    @Test @MainActor func nullServerIntent_FallsBackToIntentRulesOnReturnedText() async throws {
        // `intent: null` (Jev unavailable server-side) -> classify client-side via `IntentRules` on
        // the returned (cloud) text — no separate `/api/intent` call in the main path.
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("提问，几点了")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "提问，几点了",
            source: "cloud",
            intent: IntentDecision(intent: nil, confidence: nil, source: "unavailable")
        ))
        let composer = FakeComposer()
        composer.behavior = .deltas(["现在是下午三点。"])

        let controller = makeController(audio: audio, local: local, cloud: cloud, composer: composer)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .ask)
        #expect(controller.answer?.text == "现在是下午三点。")
    }

    @Test @MainActor func format415_RetriesOnceAsWAV() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("hello")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .rejectNonWAV(thenResult: CloudTranscript(text: "hello", source: "cloud"))
        let preparer = FakeAudioPreparer()
        preparer.formatToReturn = .oggOpus
        let inserter = FakeInserter()

        let controller = makeController(audio: audio, local: local, cloud: cloud, audioPreparer: preparer, inserter: inserter)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(cloud.requestedFormats == [.oggOpus, .wav])
        #expect(cloud.callCount == 2)
        #expect(inserter.insertedTexts == ["hello"])
    }

    @Test @MainActor func offlineFallsBackToLocalTranscriptClassifiedByRules() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "apple.speechanalyzer", steps: [.final("write this down please")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .fail(.network("offline"))
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, inserter: inserter, history: history)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(inserter.insertedTexts == ["write this down please"])
        #expect(controller.activeEngineID == local.id)
        #expect(controller.intent == .dictate)
        #expect(history.items.first?.text == "write this down please")
        #expect(history.items.first?.engineID == local.id)
    }

    @Test @MainActor func cloudRequestTimesOut_FallsBackToLocalTranscript() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("local final on timeout")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .hang
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, history: history)
        controller.cloudRequestTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == local.id)
        #expect(history.items.first?.text == "local final on timeout")
    }

    @Test @MainActor func localEngineReceivesEveryAudioChunkAndItsTranscriptIsSentAsLocalTranscript() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("local final")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "cloud final", source: "cloud"))

        let controller = makeController(audio: audio, local: local, cloud: cloud)

        controller.start(trigger: .hold)
        let chunks = (0..<5).map { makeAudioChunk(timestamp: Double($0) * 0.1) }
        for chunk in chunks {
            audio.push(chunk)
        }
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let localReceived = await local.recorder.receivedChunks
        #expect(localReceived.map(\.timestamp) == chunks.map(\.timestamp))
        #expect(cloud.lastRequest?.localTranscript == "local final")
        #expect((cloud.lastRequest?.audioData.count ?? 0) > 0)
    }

    @Test @MainActor func cancelDuringFinalizingWhileWaitingForCloud() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("local text")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .hang
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, inserter: inserter, history: history)
        controller.cloudRequestTimeout = .seconds(10) // long enough that we cancel well before it fires

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .finalizing }
        #expect(controller.phase == .finalizing)

        controller.cancel()

        #expect(controller.phase == .idle)
        #expect(controller.previewText.isEmpty)
        #expect(inserter.insertedTexts.isEmpty)
        #expect(history.items.isEmpty)
        #expect(!controller.isBusy)
    }

    // MARK: - General session lifecycle

    @Test @MainActor func startIsNoOpWhileBusy() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.hang])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .hang
        let controller = makeController(audio: audio, local: local, cloud: cloud)

        controller.start(trigger: .hold)
        #expect(controller.phase == .listening)
        let engineIDAfterFirstStart = controller.activeEngineID

        controller.start(trigger: .toggle)
        #expect(controller.activeEngineID == engineIDAfterFirstStart)
        #expect(audio.startCallCount == 1)

        controller.cancel()
    }

    @Test @MainActor func emptyShortAudioGoesIdleSilently() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "", source: "cloud"))
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, history: history)

        controller.start(trigger: .toggle)
        audio.push(makeAudioChunk(timestamp: 0.15)) // total audio well under 0.4s

        controller.stop()
        await waitUntil { controller.phase == .idle }

        #expect(controller.phase == .idle)
        #expect(controller.previewText.isEmpty)
        #expect(history.items.isEmpty)
    }

    @Test @MainActor func emptyLongAudioFails() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "   ", source: "cloud"))
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, history: history)

        controller.start(trigger: .toggle)
        audio.push(makeAudioChunk(timestamp: 1.2)) // well over 0.4s

        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .emptyTranscript)
        #expect(history.items.isEmpty)
    }

    @Test @MainActor func cancelMidListeningGoesIdleWithoutInserting() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.partial("hi"), .hang])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .hang
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, inserter: inserter, history: history)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == "hi" }

        controller.cancel()

        #expect(controller.phase == .idle)
        #expect(controller.previewText.isEmpty)
        #expect(inserter.insertedTexts.isEmpty)
        #expect(history.items.isEmpty)
        #expect(audio.stopCallCount == 1)
    }

    @Test @MainActor func audioStartFailureReportsFailedPhase() async throws {
        let audio = FakeAudio()
        audio.startBehavior = .throwError(.microphonePermissionDenied)
        let local = FakeEngine(id: "local", steps: [.final("x")])
        let cloud = FakeCloudTranscriber()

        let controller = makeController(audio: audio, local: local, cloud: cloud)
        controller.start(trigger: .hold)

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .microphonePermissionDenied)
        #expect(!controller.isBusy)
    }

    @Test @MainActor func cancelDuringInsertionDoesNotResurrectFinishedPhaseOrHistory() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.hang])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "hello", source: "cloud"))
        let inserter = FakeInserter()
        inserter.holdUntilReleased = true
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, local: local, cloud: cloud, inserter: inserter, history: history)
        controller.localFinalTimeout = .milliseconds(50)
        var completed: HistoryItem?
        controller.onSessionCompleted = { completed = $0 }

        controller.start(trigger: .hold)
        audio.push(makeAudioChunk(timestamp: 0.5)) // local never finalizes; some captured audio is needed to reach the cloud call
        controller.stop()

        // Wait until we're actually inside the (held) `inserter.insert` call.
        await waitUntil(timeout: 3) { controller.phase == .inserting }
        #expect(inserter.insertedTexts == ["hello"])

        controller.cancel()
        #expect(controller.phase == .idle)

        // Now let the stale insertion complete; its result must be discarded.
        inserter.release()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(controller.phase == .idle)
        #expect(history.items.isEmpty)
        #expect(completed == nil)
    }

    @Test @MainActor func micOpensBeforeFocusContextIsRead() async throws {
        let audio = FakeAudio()
        let contextProvider = FakeContextProvider()
        let local = FakeEngine(id: "local", steps: [.hang])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .hang

        var order: [String] = []
        audio.onStart = { order.append("audioStart") }
        contextProvider.onCurrentContext = { order.append("context") }

        let controller = makeController(audio: audio, local: local, cloud: cloud, contextProvider: contextProvider)

        controller.start(trigger: .hold)

        #expect(order == ["audioStart", "context"])
        #expect(controller.phase == .listening)

        controller.cancel()
    }
}
