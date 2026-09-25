import Testing
@testable import ProsioCore

@MainActor
private func makeController(
    audio: FakeAudio = FakeAudio(),
    cloud: FakeEngine,
    local: FakeEngine,
    inserter: FakeInserter = FakeInserter(),
    contextProvider: FakeContextProvider = FakeContextProvider(),
    history: HistoryStore = HistoryStore(fileURL: nil),
    dictionary: DictionaryStore = DictionaryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings()
) -> DictationController {
    DictationController(
        audio: audio,
        engines: EngineSet(cloud: cloud, local: local),
        inserter: inserter,
        contextProvider: contextProvider,
        history: history,
        dictionary: dictionary,
        settings: settings
    )
}

@Suite struct DictationControllerTests {

    // MARK: - .auto / .cloud parallel preview + final

    @Test @MainActor func autoMode_PreviewFromLocalWhileCloudFinalIsInserted() async throws {
        let audio = FakeAudio()
        // Cloud is staggered slightly behind local so the test can deterministically observe
        // "local's final shown as preview while cloud is still pending" before cloud completes.
        let cloud = FakeEngine(id: "gateway.gemini-3.5-transcribe-live", steps: [.delay(.milliseconds(150)), .final("Cloud final text")])
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.partial("L1"), .partial("L1 L2"), .final("L1 L2 done")])
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, inserter: inserter, history: history, settings: settings)

        controller.start(trigger: .hold)
        #expect(controller.phase == .listening)

        // Local's partials drive the live preview while cloud (final-only) is still pending.
        await waitUntil { controller.previewText == "L1 L2" }
        #expect(controller.previewText == "L1 L2")

        controller.stop()

        // Once audio ends, local's final text keeps showing as the preview while cloud finishes.
        await waitUntil { controller.previewText == "L1 L2 done" }

        await waitUntil { if case .finished = controller.phase { return true }; return false }

        // Cloud's final is what actually gets inserted, not local's.
        #expect(inserter.insertedTexts == ["Cloud final text"])
        #expect(controller.previewText == "Cloud final text")
        #expect(controller.activeEngineID == "gateway.gemini-3.5-transcribe-live")
        #expect(history.items.first?.text == "Cloud final text")
        #expect(history.items.first?.engineID == "gateway.gemini-3.5-transcribe-live")
    }

    @Test @MainActor func autoMode_LocalUnavailable_StillInsertsCloudFinal() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "gateway.gemini-3.5-transcribe-live", steps: [.final("Cloud final text")])
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.fail(.engineUnavailable("assets missing"))])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        guard case .finished(let outcome) = controller.phase else {
            Issue.record("expected .finished phase, got \(controller.phase)")
            return
        }
        #expect(outcome == .pasted)
        #expect(history.items.first?.text == "Cloud final text")
        #expect(controller.activeEngineID == "gateway.gemini-3.5-transcribe-live")
    }

    @Test @MainActor func autoMode_CloudFails_InsertsLocalFinalWithLocalEngineID() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "gateway.gemini-3.5-transcribe-live", steps: [.fail(.engineUnavailable("offline"))])
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.final("local result")])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "apple.speechanalyzer")
        #expect(history.items.first?.text == "local result")
        #expect(history.items.first?.engineID == "apple.speechanalyzer")
    }

    @Test @MainActor func autoMode_CloudFailsAndLocalUnusable_Fails() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.fail(.engineUnavailable("offline"))])
        let local = FakeEngine(id: "local", steps: [.fail(.engineUnavailable("also offline"))])
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .engineUnavailable("offline"))
    }

    @Test @MainActor func cloudMode_CloudFails_Fails_NoLocalFallback() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.fail(.transcriptionFailed("boom"))])
        let local = FakeEngine(id: "local", steps: [.final("local would have worked")])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("boom"))
        #expect(history.items.isEmpty)
    }

    @Test @MainActor func autoMode_CloudTimesOut_UsesLocalFinal() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.final("local final on timeout")])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)
        controller.finalTimeout = .milliseconds(50)
        controller.localFallbackTimeout = .seconds(2)

        controller.start(trigger: .hold)
        controller.stop() // local finishes ~instantly (audio ends immediately); cloud hangs past finalTimeout

        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "local")
        #expect(history.items.first?.text == "local final on timeout")
        #expect(history.items.first?.engineID == "local")
    }

    @Test @MainActor func cloudMode_CloudTimesOut_FailsWithNoLocalFallback() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.final("should not be used")])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)
        controller.finalTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("timeout"))
        #expect(history.items.isEmpty)
    }

    @Test @MainActor func bothEnginesReceiveEveryAudioChunk() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("cloud final")])
        let local = FakeEngine(id: "local", steps: [.final("local final")])
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, settings: settings)

        controller.start(trigger: .hold)
        let chunks = (0..<5).map { makeAudioChunk(timestamp: Double($0) * 0.1) }
        for chunk in chunks {
            audio.push(chunk)
        }
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let cloudReceived = await cloud.recorder.receivedChunks
        let localReceived = await local.recorder.receivedChunks
        #expect(cloudReceived.map(\.timestamp) == chunks.map(\.timestamp))
        #expect(localReceived.map(\.timestamp) == chunks.map(\.timestamp))
    }

    @Test @MainActor func cancelDuringFinalizingWhileWaitingForCloud() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.hang])
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, inserter: inserter, history: history, settings: settings)
        controller.finalTimeout = .seconds(10) // long enough that we cancel well before it fires

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { controller.phase == .finalizing }
        #expect(controller.phase == .finalizing)

        controller.cancel()

        #expect(controller.phase == .idle)
        #expect(controller.previewText.isEmpty)
        #expect(inserter.insertedTexts.isEmpty)
        #expect(history.items.isEmpty)

        // The controller must be immediately reusable afterwards.
        #expect(!controller.isBusy)
    }

    // MARK: - .local (unchanged single-engine path)

    @Test @MainActor func localMode_PreviewAndFinalBothFromLocal() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud.id", steps: [.final("should not be used")])
        let local = FakeEngine(id: "local.id", steps: [.final("local result")])
        let settings = makeTestSettings()
        settings.enginePreference = .local

        let controller = makeController(audio: audio, cloud: cloud, local: local, settings: settings)

        controller.start(trigger: .hold)
        #expect(controller.activeEngineID == "local.id")

        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "local result")
        #expect(await cloud.recorder.callCount == 0)
    }

    @Test @MainActor func localMode_EngineErrorWhileListeningFailsImmediately() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.fail(.transcriptionFailed("boom"))])
        let settings = makeTestSettings()
        settings.enginePreference = .local

        let controller = makeController(audio: audio, cloud: cloud, local: local, settings: settings)

        controller.start(trigger: .hold)
        await waitUntil { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("boom"))
        #expect(audio.stopCallCount == 1)
    }

    @Test @MainActor func localMode_TimeoutFallsBackToLastPreview() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.partial("partial text"), .hang])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .local

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)
        controller.finalTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        audio.push(makeAudioChunk(timestamp: 0.5))
        await waitUntil { controller.previewText == "partial text" }

        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "partial text")
        guard case .finished(let outcome) = controller.phase else {
            Issue.record("expected .finished phase, got \(controller.phase)")
            return
        }
        #expect(outcome == .pasted)
        #expect(history.items.count == 1)
        #expect(history.items.first?.text == "partial text")
    }

    @Test @MainActor func localMode_TimeoutWithNoPreviewFails() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.hang])
        let settings = makeTestSettings()
        settings.enginePreference = .local

        let controller = makeController(audio: audio, cloud: cloud, local: local, settings: settings)
        controller.finalTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .failed = controller.phase { return true }; return false }

        guard case .failed(let error) = controller.phase else {
            Issue.record("expected .failed phase, got \(controller.phase)")
            return
        }
        #expect(error == .transcriptionFailed("timeout"))
    }

    // MARK: - General session lifecycle (mode-agnostic)

    @Test @MainActor func startIsNoOpWhileBusy() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.hang])
        let controller = makeController(audio: audio, cloud: cloud, local: local)

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
        let cloud = FakeEngine(id: "cloud", steps: [.final("")])
        let local = FakeEngine(id: "local", steps: [.final("")])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)

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
        let cloud = FakeEngine(id: "cloud", steps: [.final("   ")])
        let local = FakeEngine(id: "local", steps: [.final("")])
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeController(audio: audio, cloud: cloud, local: local, history: history, settings: settings)

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
        let cloud = FakeEngine(id: "cloud", steps: [.partial("hi"), .hang])
        let local = FakeEngine(id: "local", steps: [.hang])
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)

        let controller = makeController(audio: audio, cloud: cloud, local: local, inserter: inserter, history: history)

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
        let cloud = FakeEngine(id: "cloud", steps: [.final("x")])
        let local = FakeEngine(id: "local", steps: [.final("x")])

        let controller = makeController(audio: audio, cloud: cloud, local: local)
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
        let cloud = FakeEngine(id: "cloud", steps: [.final("hello")])
        let local = FakeEngine(id: "local", steps: [.hang])
        let inserter = FakeInserter()
        inserter.holdUntilReleased = true
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeController(audio: audio, cloud: cloud, local: local, inserter: inserter, history: history, settings: settings)
        var completed: HistoryItem?
        controller.onSessionCompleted = { completed = $0 }

        controller.start(trigger: .hold)
        controller.stop()

        // Wait until we're actually inside the (held) `inserter.insert` call.
        await waitUntil { controller.phase == .inserting }
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
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.hang])

        var order: [String] = []
        audio.onStart = { order.append("audioStart") }
        contextProvider.onCurrentContext = { order.append("context") }

        let controller = makeController(audio: audio, cloud: cloud, local: local, contextProvider: contextProvider)

        controller.start(trigger: .hold)

        #expect(order == ["audioStart", "context"])
        #expect(controller.phase == .listening)

        controller.cancel()
    }
}
