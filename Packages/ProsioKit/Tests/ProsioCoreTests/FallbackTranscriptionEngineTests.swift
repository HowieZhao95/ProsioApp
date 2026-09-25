import Testing
@testable import ProsioCore

@Suite struct FallbackTranscriptionEngineTests {

    @Test func primaryFailsBeforeAnyEvent_SecondaryReceivesFullReplayedAudio() async throws {
        let chunks = (0..<5).map { makeAudioChunk(timestamp: Double($0) * 0.1) }
        let primary = FakeEngine(id: "primary", steps: [.fail(.engineUnavailable("down"))])
        let secondary = FakeEngine(id: "secondary", steps: [.final("ok")])
        let engine = FallbackTranscriptionEngine(primary: primary, secondary: secondary)

        let audioStream = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audioStream, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("ok")])
        #expect(await primary.recorder.callCount == 1)
        #expect(await secondary.recorder.callCount == 1)
        let received = await secondary.recorder.receivedChunks
        #expect(received.map(\.timestamp) == chunks.map(\.timestamp))
    }

    @Test func primarySucceeds_SecondaryNeverCalled() async throws {
        let chunks = [makeAudioChunk(timestamp: 0), makeAudioChunk(timestamp: 0.1)]
        let primary = FakeEngine(id: "primary", steps: [.partial("hi"), .final("hi there")])
        let secondary = FakeEngine(id: "secondary", steps: [.final("should not run")])
        let engine = FallbackTranscriptionEngine(primary: primary, secondary: secondary)

        let audioStream = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audioStream, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.partial("hi"), .final("hi there")])
        #expect(await secondary.recorder.callCount == 0)
    }

    @Test func bothFail_ThrowsSecondarysError() async throws {
        let primary = FakeEngine(id: "primary", steps: [.fail(.engineUnavailable("primary down"))])
        let secondary = FakeEngine(id: "secondary", steps: [.fail(.engineUnavailable("secondary down"))])
        let engine = FallbackTranscriptionEngine(primary: primary, secondary: secondary)

        let audioStream = AsyncStream<AudioChunk> { continuation in
            continuation.yield(makeAudioChunk(timestamp: 0))
            continuation.finish()
        }

        do {
            for try await _ in engine.transcribe(audio: audioStream, options: TranscriptionOptions()) {}
            Issue.record("expected an error to be thrown")
        } catch let error as ProsioError {
            #expect(error == .engineUnavailable("secondary down"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func partialsFromPrimaryBeforeFailurePassThrough() async throws {
        let primary = FakeEngine(id: "primary", steps: [.partial("partial from primary"), .fail(.engineUnavailable("down"))])
        let secondary = FakeEngine(id: "secondary", steps: [.final("secondary final")])
        let engine = FallbackTranscriptionEngine(primary: primary, secondary: secondary)

        let audioStream = AsyncStream<AudioChunk> { continuation in
            continuation.yield(makeAudioChunk(timestamp: 0))
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audioStream, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.partial("partial from primary"), .final("secondary final")])
    }
}
