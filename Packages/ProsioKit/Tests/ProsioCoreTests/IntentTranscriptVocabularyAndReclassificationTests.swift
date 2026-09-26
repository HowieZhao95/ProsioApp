import Foundation
import Testing
@testable import ProsioCore

/// Live-acceptance fix (2026-09-26): spoken "提问，葡萄牙的首都是哪里？" reached the classifier as two
/// different, both-degraded transcripts — cloud SMART normalized "提问" to the far more common
/// "请问" (which `IntentRules` deliberately never treats as a cue), and the local preview clipped
/// the leading word entirely — so with Jev down, `IntentRules` saw no cue on either transcript and
/// silently downgraded a command to plain dictation. This file covers the two-part fix:
/// 1. Command cue words are merged into `TranscriptionOptions.vocabulary` so they're more likely to
///    survive transcription verbatim (`DictationController.transcriptionVocabulary`).
/// 2. The stop()-time speculative classification (on the local preview) is discarded and redone on
///    the actual final transcript whenever the two disagree in their leading text, or whenever the
///    early decision fell back to rules (which must always see the best available transcript).
@MainActor
private func makeController(
    audio: FakeAudio = FakeAudio(),
    cloud: FakeEngine,
    local: FakeEngine,
    composer: FakeComposer? = nil,
    intentClassifier: FakeIntentClassifier? = nil,
    dictionary: DictionaryStore = DictionaryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings(),
    debugRoot: URL? = nil
) -> DictationController {
    let controller = DictationController(
        audio: audio,
        engines: EngineSet(cloud: cloud, local: local),
        inserter: FakeInserter(),
        contextProvider: FakeContextProvider(),
        history: HistoryStore(fileURL: nil),
        dictionary: dictionary,
        settings: settings,
        composer: composer,
        intentClassifier: intentClassifier
    )
    if let debugRoot {
        controller.debugRecordingsRootOverride = debugRoot
    }
    return controller
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

private func decodeDebugRecord(at url: URL) throws -> DebugSessionRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DebugSessionRecord.self, from: Data(contentsOf: url))
}

@Suite struct TranscriptionVocabularyTests {

    @Test @MainActor func commandCueWordsAreMergedIntoTranscriptionVocabularyAndDedupedAgainstDictionary() async throws {
        let dictionary = DictionaryStore(fileURL: nil)
        try dictionary.add(term: "PR") // ordinary personal-dictionary term
        try dictionary.add(term: "Prosio") // deliberately overlaps a fixed cue hint

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("test")])
        let cloud = FakeEngine(id: "cloud", steps: [.final("test")])
        let settings = makeTestSettings()
        settings.enginePreference = .local

        let controller = makeController(audio: audio, cloud: cloud, local: local, dictionary: dictionary, settings: settings)

        controller.start(trigger: .hold)
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let vocabulary = try #require(local.lastOptions?.vocabulary)
        for cue in IntentRules.vocabularyHints {
            #expect(vocabulary.contains(cue), "expected cue \"\(cue)\" in transcription vocabulary")
        }
        #expect(vocabulary.contains("PR"))
        // "Prosio" appears once even though it's both a fixed cue hint and a dictionary entry.
        #expect(vocabulary.filter { $0 == "Prosio" }.count == 1)
    }
}

@Suite struct IntentReclassificationTests {

    /// Direct repro of the live-acceptance bug: the local preview clips the leading cue entirely,
    /// while the (better, final) cloud transcript keeps it. With no classifier configured (pure
    /// `IntentRules`), the stop()-time speculative decision on the clipped local preview lands on
    /// `.dictate` (no cue) — but it must be discarded once the real final transcript arrives with
    /// the cue intact, and the session must end up correctly classified as `.ask`.
    @Test @MainActor func finalTranscriptWithCueBeatsClippedLocalPreview() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.partial("葡萄牙的首都是哪里"), .final("葡萄牙的首都是哪里")])
        let cloud = FakeEngine(id: "cloud", steps: [.final("提问，葡萄牙的首都是哪里？")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["里斯本。"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: nil, settings: settings)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == "葡萄牙的首都是哪里" }
        controller.stop()
        await waitUntil { controller.phase == .answering && controller.answer?.isStreaming == false }

        #expect(controller.intent == .ask)
        #expect(controller.answer?.text == "里斯本。")
    }

    /// A translate cue's boundary punctuation (the colon) falls just past the ~6-character leading
    /// window compared between the local preview and the final transcript, so the two are seen as
    /// matching there — but the local preview never actually resolves a boundary/body ("你好" runs
    /// straight into "翻译成英文" with no separator), so its stop()-time decision degrades to
    /// `.dictate` via `IntentRules`. Because that decision's source is "rules", it must always be
    /// redone against the final transcript regardless of the leading-text match, and the final
    /// transcript's colon lets `IntentRules` correctly resolve `.translate`.
    @Test @MainActor func rulesFallbackAlwaysReclassifiesOnFinalEvenWhenLeadingTextMatches() async throws {
        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.partial("翻译成英文你好"), .final("翻译成英文你好")])
        let cloud = FakeEngine(id: "cloud", steps: [.final("翻译成英文：你好")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["Hello"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.translateTarget = "zh-CN" // distinct from the cue's explicit "英文" (en-US) target

        let controller = makeController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: nil, settings: settings)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == "翻译成英文你好" }
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(composer.lastRequest?.mode == .translate) // rule-matched (cue stripped), not translateCommand
        #expect(composer.lastRequest?.text == "你好")
        #expect(composer.lastRequest?.targetLanguage == "en-US")
        #expect(controller.previewText == "Hello")
    }

    /// The counterpart to the above: when the early (local-preview) decision came from the real
    /// classifier (not rules) and its leading text still matches the final transcript, it must be
    /// kept as-is — no wasted reclassification.
    @Test @MainActor func matchingJevDecisionIsKeptWithoutReclassification() async throws {
        let audio = FakeAudio()
        let transcript = "please schedule the meeting for tomorrow at three pm"
        let local = FakeEngine(id: "local", steps: [.partial(transcript), .final(transcript)])
        let cloud = FakeEngine(id: "cloud", steps: [.final(transcript)])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .dictate, confidence: 0.97, source: "jev"))
        let settings = makeTestSettings()
        settings.enginePreference = .cloud

        let controller = makeController(audio: audio, cloud: cloud, local: local, intentClassifier: classifier, settings: settings)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == transcript }
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        #expect(controller.intent == .dictate)
        // Only the one (stop()-time) classifier call — no second attempt against the final transcript.
        #expect(classifier.callCount == 1)
    }
}

@Suite struct IntentReclassificationDebugRecordingTests {

    @Test @MainActor func recordsBothLocalAndFinalDecisionsWhenReclassified() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.partial("葡萄牙的首都是哪里"), .final("葡萄牙的首都是哪里")])
        let cloud = FakeEngine(id: "cloud", steps: [.final("提问，葡萄牙的首都是哪里？")])
        let composer = FakeComposer()
        composer.behavior = .deltas(["里斯本。"])
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.saveDebugRecordings = true

        let controller = makeController(audio: audio, cloud: cloud, local: local, composer: composer, intentClassifier: nil, settings: settings, debugRoot: root)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == "葡萄牙的首都是哪里" }
        controller.stop()
        await waitUntil { controller.answer?.isStreaming == false }
        await controller.insertAnswer()

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let record = try decodeDebugRecord(at: jsonURL)

        #expect(record.intentDecisionClassifiedOn == "final")
        #expect(record.intentDecisionLocalClassified == "dictate")
        #expect(record.intentDecisionLocalSource == "rules")
        #expect(record.intentDecisionFinalClassified == "ask")
        #expect(record.intentDecisionFinalSource == "rules")
        // The flat "winning" fields mirror the final decision that actually determined routing.
        #expect(record.intentDecisionClassified == "ask")
        #expect(record.intentDecisionSource == "rules")
    }

    @Test @MainActor func recordsLocalOnlyWhenNoReclassificationWasNeeded() async throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = FakeAudio()
        let transcript = "just a normal dictation"
        let local = FakeEngine(id: "local", steps: [.partial(transcript), .final(transcript)])
        let cloud = FakeEngine(id: "cloud", steps: [.final(transcript)])
        let classifier = FakeIntentClassifier()
        classifier.behavior = .decision(IntentDecision(intent: .dictate, confidence: 0.9, source: "jev"))
        let settings = makeTestSettings()
        settings.enginePreference = .cloud
        settings.saveDebugRecordings = true

        let controller = makeController(audio: audio, cloud: cloud, local: local, intentClassifier: classifier, settings: settings, debugRoot: root)

        controller.start(trigger: .hold)
        await waitUntil { controller.previewText == transcript }
        controller.stop()
        await waitUntil { if case .finished = controller.phase { return true }; return false }

        let jsonURL = try #require(await waitForDebugFile("session.json", in: root))
        let record = try decodeDebugRecord(at: jsonURL)

        #expect(record.intentDecisionClassifiedOn == "local")
        #expect(record.intentDecisionLocalClassified == "dictate")
        #expect(record.intentDecisionLocalSource == "jev")
        #expect(record.intentDecisionFinalClassified == nil)
        #expect(record.intentDecisionFinalSource == nil)
    }
}
