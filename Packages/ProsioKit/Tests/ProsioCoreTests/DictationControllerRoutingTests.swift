import Testing
@testable import ProsioCore

@MainActor
private func makeRoutedController(
    audio: FakeAudio = FakeAudio(),
    cloud: FakeEngine,
    local: FakeEngine,
    router: FakeRouter? = nil,
    prewarmCounter: CallCounter? = nil,
    inserter: FakeInserter = FakeInserter(),
    history: HistoryStore = HistoryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings()
) -> DictationController {
    let prewarmCloud: (@Sendable () async -> Void)? = prewarmCounter.map { counter in
        { @Sendable in counter.increment() }
    }
    return DictationController(
        audio: audio,
        engines: EngineSet(cloud: cloud, local: local),
        inserter: inserter,
        contextProvider: FakeContextProvider(),
        history: history,
        dictionary: DictionaryStore(fileURL: nil),
        settings: settings,
        router: router,
        prewarmCloud: prewarmCloud
    )
}

@Suite struct DictationControllerRoutingTests {

    @Test @MainActor func cleanLocal_InsertsLocalDirectly_CloudNeverCalled() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("should not be used")])
        let local = FakeEngine(id: "local", steps: [.partial("Hel"), .final("Hello world")])
        let router = FakeRouter()
        router.behavior = .decision(RouteDecision(needsCloud: false, cleanProbability: 0.97, reason: "clean"))
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, history: history, settings: settings)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == "Hel" }

        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "Hello world")
        #expect(controller.activeEngineID == "local")
        #expect(history.items.first?.text == "Hello world")
        #expect(history.items.first?.engineID == "local")
        #expect(router.callCount == 1)
        #expect(router.lastLocalTranscript == "Hello world")
        #expect(await cloud.recorder.callCount == 0)
    }

    @Test @MainActor func needsCloud_CloudCalledWithFullReplayedAudio() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud cleaned text")])
        let local = FakeEngine(id: "local", steps: [.final("messy local text uh")])
        let router = FakeRouter()
        router.behavior = .decision(RouteDecision(needsCloud: true, cleanProbability: 0.2, reason: "needs-cleanup"))
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, history: history, settings: settings)

        controller.start(trigger: .hold)
        let chunks = (0..<4).map { makeAudioChunk(timestamp: Double($0) * 0.1) }
        for chunk in chunks { audio.push(chunk) }

        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "cloud")
        #expect(history.items.first?.text == "Cloud cleaned text")
        #expect(history.items.first?.engineID == "cloud")

        let cloudReceived = await cloud.recorder.receivedChunks
        #expect(cloudReceived.map(\.timestamp) == chunks.map(\.timestamp))
    }

    @Test @MainActor func routerError_FallsThroughToCloud() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud final")])
        let local = FakeEngine(id: "local", steps: [.final("local text here")])
        let router = FakeRouter()
        router.behavior = .fail(.network("router down"))
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "cloud")
        #expect(controller.previewText == "Cloud final")
        #expect(await cloud.recorder.callCount == 1)
    }

    @Test @MainActor func routerTimeout_FallsThroughToCloud() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud final")])
        let local = FakeEngine(id: "local", steps: [.final("local text here")])
        let router = FakeRouter()
        router.behavior = .hang
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, settings: settings)
        controller.routerDecisionTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "cloud")
        #expect(controller.previewText == "Cloud final")
        #expect(await cloud.recorder.callCount == 1)
    }

    @Test @MainActor func emptyLocal_GoesToCloudWithoutCallingRouter() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud saved the day")])
        let local = FakeEngine(id: "local", steps: [.final("")])
        let router = FakeRouter()
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, settings: settings)
        controller.routingLocalFinalTimeout = .milliseconds(200)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "cloud")
        #expect(controller.previewText == "Cloud saved the day")
        #expect(router.callCount == 0)
        #expect(await cloud.recorder.callCount == 1)
    }

    @Test @MainActor func localFinalTimesOut_GoesToCloudWithoutCallingRouter() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud saved the day")])
        let local = FakeEngine(id: "local", steps: [.hang])
        let router = FakeRouter()
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, settings: settings)
        controller.routingLocalFinalTimeout = .milliseconds(50)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil(timeout: 3) { if case .finished = controller.phase { return true }; return false }

        #expect(controller.activeEngineID == "cloud")
        #expect(router.callCount == 0)
        #expect(await cloud.recorder.callCount == 1)
    }

    @Test @MainActor func cloudModeUnchanged_RouterNeverCalledEvenWhenSet() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud text")])
        let local = FakeEngine(id: "local", steps: [.final("Local text")])
        let router = FakeRouter()
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "Cloud text")
        #expect(router.callCount == 0)
    }

    @Test @MainActor func localModeUnchanged_RouterNeverCalledEvenWhenSet() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("should not run")])
        let local = FakeEngine(id: "local", steps: [.final("Local text")])
        let router = FakeRouter()
        let settings = makeTestSettings()
        settings.enginePreference = .local

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.previewText == "Local text")
        #expect(router.callCount == 0)
        #expect(await cloud.recorder.callCount == 0)
    }

    @Test @MainActor func cancelDuringRouting_GoesIdleWithoutInserting() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud final")])
        let local = FakeEngine(id: "local", steps: [.final("local text here")])
        let router = FakeRouter()
        router.behavior = .hang
        let inserter = FakeInserter()
        let history = HistoryStore(fileURL: nil)
        let settings = makeTestSettings()
        settings.enginePreference = .auto

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, router: router, inserter: inserter, history: history, settings: settings)
        controller.routerDecisionTimeout = .seconds(10) // long enough that we cancel well before it fires

        controller.start(trigger: .hold)
        controller.stop()
        // Give resolveRoutedStop time to get local's final and start waiting on the (hanging) router.
        await waitUntil { router.callCount == 1 }
        #expect(controller.phase == .finalizing)

        controller.cancel()

        #expect(controller.phase == .idle)
        #expect(controller.previewText.isEmpty)
        #expect(inserter.insertedTexts.isEmpty)
        #expect(history.items.isEmpty)
        #expect(!controller.isBusy)
    }

    @Test @MainActor func prewarmCloudFiresAtStart() async throws {
        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.hang])
        let local = FakeEngine(id: "local", steps: [.hang])
        let counter = CallCounter()

        let controller = makeRoutedController(audio: audio, cloud: cloud, local: local, prewarmCounter: counter)

        controller.start(trigger: .hold)
        await waitUntil { counter.count == 1 }
        #expect(counter.count == 1)

        controller.cancel()
    }
}
