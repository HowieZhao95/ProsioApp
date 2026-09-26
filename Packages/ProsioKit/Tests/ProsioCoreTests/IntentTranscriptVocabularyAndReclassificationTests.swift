import Foundation
import Testing
@testable import ProsioCore

/// Live-acceptance fix (2026-09-26): spoken "提问，葡萄牙的首都是哪里？" reached the classifier as two
/// different, both-degraded transcripts — cloud SMART normalized "提问" to the far more common
/// "请问" (which `IntentRules` deliberately never treats as a cue), and the local preview clipped
/// the leading word entirely. Fix part 1: command cue words are merged into
/// `TranscriptionOptions.vocabulary` so they're more likely to survive transcription verbatim
/// (`DictationController.transcriptionVocabulary`). (Fix part 2 — reclassifying on the better of two
/// transcripts — was superseded by P1.2: there's only ever one transcript now, since the server
/// returns intent inline with `/api/transcribe`; see `DictationControllerIntentClassificationTests`.)
@MainActor
private func makeController(
    audio: FakeAudio = FakeAudio(),
    local: FakeEngine,
    cloud: FakeCloudTranscriber = FakeCloudTranscriber(),
    dictionary: DictionaryStore = DictionaryStore(fileURL: nil),
    settings: AppSettings = makeTestSettings()
) -> DictationController {
    DictationController(
        audio: audio,
        localEngine: local,
        cloudTranscriber: cloud,
        inserter: FakeInserter(),
        contextProvider: FakeContextProvider(),
        history: HistoryStore(fileURL: nil),
        dictionary: dictionary,
        settings: settings
    )
}

@Suite struct TranscriptionVocabularyTests {

    @Test @MainActor func commandCueWordsAreMergedIntoTranscriptionVocabularyAndDedupedAgainstDictionary() async throws {
        let dictionary = DictionaryStore(fileURL: nil)
        try dictionary.add(term: "PR") // ordinary personal-dictionary term
        try dictionary.add(term: "Prosio") // deliberately overlaps a fixed cue hint

        let audio = FakeAudio()
        let local = FakeEngine(id: "local", steps: [.final("test")])
        let cloud = FakeCloudTranscriber()
        cloud.behavior = .result(CloudTranscript(text: "test", source: "cloud"))

        let controller = makeController(audio: audio, local: local, cloud: cloud, dictionary: dictionary)

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

        // P1.2: the same vocabulary is also sent as part of the single `/api/transcribe` request.
        let requestVocabulary = try #require(cloud.lastRequest?.options.vocabulary)
        #expect(requestVocabulary == vocabulary)
    }
}
