import Foundation
import Testing
@testable import ProsioCore

@MainActor
private func makeDebugTestController(
    audio: FakeAudio = FakeAudio(),
    local: FakeEngine,
    cloud: FakeCloudTranscriber,
    audioPreparer: any AudioPreparing = WAVAudioPreparer(),
    composer: FakeComposer? = nil,
    settings: AppSettings,
    debugRoot: URL
) -> DictationController {
    let controller = DictationController(
        audio: audio,
        localEngine: local,
        cloudTranscriber: cloud,
        inserter: FakeInserter(),
        contextProvider: FakeContextProvider(),
        history: HistoryStore(fileURL: nil),
        dictionary: DictionaryStore(fileURL: nil),
        settings: settings,
        audioPreparer: audioPreparer,
        composer: composer
    )
    controller.debugRecordingsRootOverride = debugRoot
    return controller
}

/// Polls until `root` contains at least one session subdirectory holding `filename`, since the
/// write happens on a detached background task.
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

@Suite struct DictationControllerDebugRecordingTests {

    @Test @MainActor func writesAudioAndSessionJSONAfterSuccessfulSession() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.partial("Local partial"), .final("Local final text")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "Cloud final text",
            source: "cloud",
            route: TranscribeRouteInfo(cleanProbability: 0.2, reason: "needs-cleanup")
        ))
        let settings = makeTestSettings()
        settings.saveDebugRecordings = true

        let controller = makeDebugTestController(audio: audio, local: local, cloud: cloud, settings: settings, debugRoot: root)

        controller.start(trigger: .hold)
        let chunk1 = AudioChunk(pcm16: Data([0x01, 0x02]), level: 0.2, timestamp: 0.1)
        let chunk2 = AudioChunk(pcm16: Data([0x03, 0x04]), level: 0.3, timestamp: 0.2)
        audio.push(chunk1)
        audio.push(chunk2)
        await waitUntil { controller.previewText == "Local partial" }

        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let sessionDir = jsonURL.deletingLastPathComponent()
        let wavURL = sessionDir.appendingPathComponent("audio.wav")
        #expect(FileManager.default.fileExists(atPath: wavURL.path))

        let wavData = try Data(contentsOf: wavURL)
        let expectedPCM = chunk1.pcm16 + chunk2.pcm16
        #expect(wavData.count == 44 + expectedPCM.count)
        #expect(wavData.suffix(expectedPCM.count) == expectedPCM)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DebugSessionRecord.self, from: Data(contentsOf: jsonURL))
        #expect(record.mode == "auto")
        #expect(record.localEngineID == "apple.speechanalyzer")
        #expect(record.cloudEngineID == DictationController.cloudEngineID)
        #expect(record.engineIDUsed == DictationController.cloudEngineID)
        #expect(record.localFinalText == "Local final text")
        #expect(record.cloudFinalText == "Cloud final text")
        #expect(record.insertedText == "Cloud final text")
        #expect(record.outcome == "pasted")
        #expect(record.suspectedDrop == false)
        #expect(record.routeSource == "cloud")
        #expect(record.routeCleanProbability == 0.2)
        #expect(record.routeReason == "needs-cleanup")
        #expect(record.audioFormat == "wav")
        #expect(record.uploadBytes != nil)
        #expect(record.originalSeconds != nil)
        #expect(record.trimmedSeconds != nil)
        #expect(record.timings.startToMicOpenMs != nil)
        #expect(record.timings.micOpenToFirstChunkMs != nil)
        #expect(record.timings.stopToFinalReceivedMs != nil)
        #expect(record.timings.finalReceivedToInsertionDoneMs != nil)
    }

    @Test @MainActor func doesNotWriteWhenSaveDebugRecordingsIsDisabled() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("Local text")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "Cloud text", source: "cloud"))
        let settings = makeTestSettings()
        settings.saveDebugRecordings = false

        let controller = makeDebugTestController(audio: audio, local: local, cloud: cloud, settings: settings, debugRoot: root)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        // Give any (unwanted) background write a moment to land, then confirm nothing did.
        try? await Task.sleep(for: .milliseconds(150))
        let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect((entries ?? []).isEmpty)
    }

    @Test @MainActor func marksSuspectedDropWhenCloudMuchShorterThanLocal() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        // Real-world-shaped repro of the accuracy bug: local (on-device) caught two sentences,
        // cloud only returned the first — well under the 55% ratio floor with 12+ local chars.
        let longLocal = "第一个问题是启动的速度不够跟手第二个问题是识别经常出错第三个问题是偶尔会闪退"
        let shortCloud = "第一个问题是启动的速度不够跟手"
        let local = FakeEngine(id: "local", steps: [.final(longLocal)])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .delayThenResult(.milliseconds(50), CloudTranscript(text: shortCloud, source: "cloud"))
        let settings = makeTestSettings()
        settings.saveDebugRecordings = true

        let controller = makeDebugTestController(audio: audio, local: local, cloud: cloud, settings: settings, debugRoot: root)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DebugSessionRecord.self, from: Data(contentsOf: jsonURL))

        #expect(record.suspectedDrop == true)
        #expect(record.insertedText == shortCloud) // we don't change the inserted text yet, per spec
    }

    @Test @MainActor func askSessionIsRecordedWithComposeFields() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("what is the capital of Portugal")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "what is the capital of Portugal", source: "cloud"))
        let composer = FakeComposer()
        composer.behavior = .deltas(["Lisbon ", "is the capital of Portugal."])
        let settings = makeTestSettings()
        settings.saveDebugRecordings = true

        let controller = makeDebugTestController(audio: audio, local: local, cloud: cloud, composer: composer, settings: settings, debugRoot: root)

        controller.start(trigger: .hold, intent: .ask)
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }
        await controller.insertAnswer()

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DebugSessionRecord.self, from: Data(contentsOf: jsonURL))

        #expect(record.intent == "ask")
        #expect(record.composeMode == "ask")
        #expect(record.composeOutput == "Lisbon is the capital of Portugal.")
        #expect(record.composeLatencyMs != nil)
        #expect(record.insertedText == "Lisbon is the capital of Portugal.")
    }

    @Test @MainActor func recordsRouteSourceLocalWhenServerSkipsGemini() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("clean text")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(
            text: "clean text",
            source: "local",
            intent: IntentDecision(intent: .dictate, confidence: 0.95, source: "jev"),
            route: TranscribeRouteInfo(cleanProbability: 0.97, reason: "clean")
        ))
        let settings = makeTestSettings()
        settings.saveDebugRecordings = true

        let controller = makeDebugTestController(audio: audio, local: local, cloud: cloud, settings: settings, debugRoot: root)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DebugSessionRecord.self, from: Data(contentsOf: jsonURL))

        #expect(record.routeSource == "local")
        #expect(record.routeCleanProbability == 0.97)
        #expect(record.routeReason == "clean")
        #expect(record.intentDecisionClassified == "dictate")
        #expect(record.intentDecisionSource == "jev")
    }
}
