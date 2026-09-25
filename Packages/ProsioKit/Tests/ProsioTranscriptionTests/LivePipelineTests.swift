import Foundation
import Testing
@testable import ProsioCore
@testable import ProsioTranscription

/// Headless end-to-end: real DictationController + real SpeechAnalyzer preview + real backend/Gemini final.
/// Only the microphone (WAV file, real-time paced) and the inserter (recorder) are fakes.
///
///   PROSIO_PIPELINE_WAV=/path/16k.wav PROSIO_BACKEND=http://localhost:3123 \
///     swift test --filter LivePipelineTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROSIO_PIPELINE_WAV"] != nil))
@MainActor
struct LivePipelineTests {
    @Test func dictatesWavEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let wav = try Data(contentsOf: URL(fileURLWithPath: env["PROSIO_PIPELINE_WAV"]!))
        let backendURL = URL(string: env["PROSIO_BACKEND"] ?? "http://localhost:3123")!

        let defaults = UserDefaults(suiteName: "prosio.livepipeline.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.enginePreference = .auto
        settings.languageHints = (env["PROSIO_PIPELINE_LANGS"] ?? "zh-CN,en-US").split(separator: ",").map(String.init)

        let backend = BackendClient(baseURL: backendURL, keychainService: "app.prosio.livepipeline.\(UUID().uuidString)")
        try await backend.devSignIn(email: "pipeline@prosio.app")
        defer { backend.signOut() }

        let dictionary = DictionaryStore(fileURL: nil)
        for term in (env["PROSIO_PIPELINE_VOCAB"] ?? "Prosio,PR").split(separator: ",") {
            try dictionary.add(term: String(term))
        }

        let audio = WavAudio(wav: wav)
        let inserter = RecordingInserter()
        let controller = DictationController(
            audio: audio,
            engines: EngineSet(
                cloud: CloudBatchTranscriptionEngine(transcriber: backend),
                local: SpeechAnalyzerEngine(locale: Locale(identifier: settings.languageHints.first ?? "en-US"))
            ),
            inserter: inserter,
            contextProvider: StaticContext(),
            history: HistoryStore(fileURL: nil),
            dictionary: dictionary,
            settings: settings
        )

        let clock = ContinuousClock()
        let t0 = clock.now
        func ms() -> Int { Int((clock.now - t0) / .milliseconds(1)) }

        controller.start(trigger: .hold)
        var lastPreview = ""
        var firstPreviewAt: Int?
        // Poll the observable state like the HUD would, until the "user" releases the key.
        while !audio.exhausted {
            if controller.previewText != lastPreview {
                lastPreview = controller.previewText
                firstPreviewAt = firstPreviewAt ?? ms()
                print("PIPE \(ms())ms preview: \(lastPreview)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let releasedAt = ms()
        controller.stop()
        print("PIPE \(releasedAt)ms --- key released ---")

        while controller.isBusy {
            if controller.previewText != lastPreview {
                lastPreview = controller.previewText
                print("PIPE \(ms())ms preview(finalizing): \(lastPreview)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let insertedAt = ms()
        print("PIPE \(insertedAt)ms phase=\(controller.phase) engine=\(controller.activeEngineID ?? "-")")
        print("PIPE INSERTED: \((inserter.texts.last ?? "<none>").replacingOccurrences(of: "\n", with: " ⏎ "))")
        print("PIPE summary: firstPreview=\(firstPreviewAt ?? -1)ms releaseToInsert=\(insertedAt - releasedAt)ms")

        #expect(inserter.texts.count == 1)
        #expect(controller.activeEngineID == "cloud.gemini-3.5-transcribe")
    }
}

/// Plays a 16 kHz mono PCM16 WAV as if it were the microphone (50 ms chunks, real-time paced).
private final class WavAudio: AudioCapturing, @unchecked Sendable {
    private let pcm: Data
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var feeder: Task<Void, Never>?
    private var _exhausted = false

    init(wav: Data) {
        let range = wav.range(of: Data("data".utf8))!
        pcm = wav.subdata(in: (range.upperBound + 4)..<wav.endIndex)
    }

    var exhausted: Bool { lock.withLock { _exhausted } }

    func start() throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        lock.withLock { self.continuation = continuation }
        let pcm = pcm
        feeder = Task { [weak self] in
            let chunkBytes = 800 * 2
            var offset = 0
            while offset < pcm.count, !Task.isCancelled {
                let end = min(offset + chunkBytes, pcm.count)
                let samples = pcm.subdata(in: offset..<end)
                continuation.yield(AudioChunk(pcm16: samples, level: 0.5, timestamp: Double(offset) / 32_000))
                offset = end
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.lock.withLock { self?._exhausted = true }
        }
        return stream
    }

    func stop() {
        feeder?.cancel()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

@MainActor
private final class RecordingInserter: TextInserting {
    var texts: [String] = []
    func insert(_ text: String, into context: FocusContext?) async -> InsertionOutcome {
        texts.append(text)
        return .pasted
    }
}

@MainActor
private final class StaticContext: FocusContextProviding {
    func currentContext() -> FocusContext { FocusContext(bundleID: "com.apple.TextEdit", appName: "TextEdit") }
}
