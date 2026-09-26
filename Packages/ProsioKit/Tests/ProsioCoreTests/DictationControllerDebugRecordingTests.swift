import Foundation
import Testing
@testable import ProsioCore

@MainActor
private func makeDebugTestController(
    audio: FakeAudio = FakeAudio(),
    cloud: FakeEngine,
    local: FakeEngine,
    settings: AppSettings,
    debugRoot: URL
) -> DictationController {
    let controller = DictationController(
        audio: audio,
        engines: EngineSet(cloud: cloud, local: local),
        inserter: FakeInserter(),
        contextProvider: FakeContextProvider(),
        history: HistoryStore(fileURL: nil),
        dictionary: DictionaryStore(fileURL: nil),
        settings: settings
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
        let cloud = FakeEngine(id: "gateway.gemini-3.5-transcribe", steps: [.final("Cloud final text")])
        let local = FakeEngine(id: "apple.speechanalyzer", isOnDevice: true, steps: [.partial("Local partial"), .final("Local final text")])
        let settings = makeTestSettings()
        settings.enginePreference = .auto
        settings.saveDebugRecordings = true

        let controller = makeDebugTestController(audio: audio, cloud: cloud, local: local, settings: settings, debugRoot: root)

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
        #expect(record.cloudEngineID == "gateway.gemini-3.5-transcribe")
        #expect(record.engineIDUsed == "gateway.gemini-3.5-transcribe")
        #expect(record.localFinalText == "Local final text")
        #expect(record.cloudFinalText == "Cloud final text")
        #expect(record.insertedText == "Cloud final text")
        #expect(record.outcome == "pasted")
        #expect(record.suspectedDrop == false)
        #expect(record.timings.startToMicOpenMs != nil)
        #expect(record.timings.micOpenToFirstChunkMs != nil)
        #expect(record.timings.stopToFinalReceivedMs != nil)
        #expect(record.timings.finalReceivedToInsertionDoneMs != nil)
    }

    @Test @MainActor func doesNotWriteWhenSaveDebugRecordingsIsDisabled() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let cloud = FakeEngine(id: "cloud", steps: [.final("Cloud text")])
        let local = FakeEngine(id: "local", steps: [.final("Local text")])
        let settings = makeTestSettings()
        settings.enginePreference = .auto
        settings.saveDebugRecordings = false

        let controller = makeDebugTestController(audio: audio, cloud: cloud, local: local, settings: settings, debugRoot: root)

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
        let cloud = FakeEngine(id: "cloud", steps: [.delay(.milliseconds(50)), .final(shortCloud)])
        let local = FakeEngine(id: "local", steps: [.final(longLocal)])
        let settings = makeTestSettings()
        settings.enginePreference = .auto
        settings.saveDebugRecordings = true

        let controller = makeDebugTestController(audio: audio, cloud: cloud, local: local, settings: settings, debugRoot: root)

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
}
