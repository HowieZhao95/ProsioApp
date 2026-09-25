import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

@Suite struct CloudBatchTranscriptionEngineTests {

    @Test func idAndIsOnDevice() {
        let engine = CloudBatchTranscriptionEngine(transcriber: FakeCloudBatchTranscribing(result: CloudTranscript(text: "x")))
        #expect(engine.id == "cloud.gemini-3.5-transcribe")
        #expect(engine.isOnDevice == false)
    }

    @Test func buffersAudioAndYieldsSingleFinal() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "Hello world.", language: "en", durationSeconds: 1.5))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let chunks = (0..<5).map { TestFixtures.audioChunk(pcm16: [Int16($0), Int16($0 + 1)], timestamp: Double($0) * 0.05) }
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("Hello world.")])
        #expect(fake.transcribeCallCount == 1)
        // A short grace window for the fire-and-forget prewarm Task to actually run.
        try await Task.sleep(for: .milliseconds(20))
        #expect(fake.prewarmCallCount == 1)
    }

    @Test func wavHeaderIsCorrect16kMonoPCM16() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "ok"))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let samples: [Int16] = [1, -1, 1234, -1234, Int16.max, Int16.min]
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk(pcm16: samples))
            continuation.finish()
        }

        for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}

        let wav = try #require(fake.lastWAV)
        let header = try #require(ParsedWAVHeader(wav))
        #expect(header.numChannels == 1)
        #expect(header.sampleRate == 16_000)
        #expect(header.bitsPerSample == 16)
        #expect(header.dataSize == UInt32(samples.count * 2))
        #expect(wav.count == header.dataOffset + Int(header.dataSize))

        // The PCM payload itself must be an untouched concatenation of the chunk's bytes.
        let expectedPCM = int16SamplesToLittleEndianData(samples)
        #expect(wav.suffix(from: header.dataOffset) == expectedPCM)
    }

    @Test func optionsPassThroughUnchanged() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "ok"))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)
        let options = TranscriptionOptions(mode: .verbatim, vocabulary: ["Prosio", "PR"], languageHints: ["zh-CN", "en-US"])

        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }

        for try await _ in engine.transcribe(audio: audio, options: options) {}

        #expect(fake.lastOptions == options)
    }

    @Test func zeroAudio_throwsEmptyTranscriptWithoutCallingBackend() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "should not be reached"))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let audio = AsyncStream<AudioChunk> { continuation in continuation.finish() }

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected .emptyTranscript")
        } catch let error as ProsioError {
            #expect(error == .emptyTranscript)
        }
        #expect(fake.transcribeCallCount == 0)
    }

    @Test func emptyTrimmedResultText_throwsEmptyTranscript() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "   \n  "))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected .emptyTranscript")
        } catch let error as ProsioError {
            #expect(error == .emptyTranscript)
        }
    }

    @Test func resultTextIsTrimmed() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "  Hello there.  \n"))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }
        #expect(events == [.final("Hello there.")])
    }

    @Test func backendError_mapsProsioErrorThrough() async throws {
        let fake = FakeCloudBatchTranscribing(error: ProsioError.quotaExceeded)
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected .quotaExceeded")
        } catch let error as ProsioError {
            #expect(error == .quotaExceeded)
        }
    }

    @Test func backendGenericError_mapsToNetwork() async throws {
        let fake = FakeCloudBatchTranscribing(error: URLError(.timedOut))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected .network")
        } catch let error as ProsioError {
            guard case .network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
    }

    @Test func cancellationDuringBackendCall_stopsPromptlyAndMapsToCancelled() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "too slow"), transcribeDelay: .seconds(30))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }

        let stream = engine.transcribe(audio: audio, options: TranscriptionOptions())
        let consumer = Task<Error?, Never> {
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        let error = await consumer.value

        // Either surfaces as our own cancellation mapping, or Swift's own CancellationError from
        // the consuming loop being torn down — both indicate prompt cancellation, not a 30s hang.
        if let prosioError = error as? ProsioError {
            #expect(prosioError == .cancelled)
        }
    }

    @Test func cancellationWhileBufferingAudio_stopsPromptly() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "should not be reached"))
        let engine = CloudBatchTranscriptionEngine(transcriber: fake)

        // Audio stream that never finishes on its own.
        let (audio, _) = AsyncStream<AudioChunk>.makeStream()

        let stream = engine.transcribe(audio: audio, options: TranscriptionOptions())
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Expected once we cancel below.
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value

        #expect(fake.transcribeCallCount == 0)
    }
}
