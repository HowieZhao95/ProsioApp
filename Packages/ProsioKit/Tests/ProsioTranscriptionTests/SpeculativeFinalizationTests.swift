import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

/// Tests for `CloudBatchTranscriptionEngine`'s speculative finalization (fires a transcription
/// request during a mid-session pause so most of the cloud round-trip overlaps with the tail of
/// the recording, instead of starting cold at release). Uses the internal tunables initializer
/// with a short pause threshold so tests run fast and deterministically — chunk pause duration is
/// computed from `AudioChunk.timestamp` deltas, not wall-clock time, so nothing here needs to
/// actually wait out a real 600ms.
@Suite struct SpeculativeFinalizationTests {
    /// speech (0...0.1s) -> pause (0.1...0.5s, >= 0.3s threshold) -> stream ends. One speculative
    /// request should fire once the pause crosses the threshold, and since nothing more is said,
    /// its result should be used directly with no second ("real") request at audio end.
    @Test func pauseFiresSpeculativeRequest_usedAsFinalWhenOnlySilenceFollows() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "speculative result"))
        let engine = CloudBatchTranscriptionEngine(
            transcriber: fake,
            maxSpeculativeRequests: 3,
            speculativePauseThreshold: 0.3,
            speculativeLevelThreshold: 0.1
        )

        let chunks = [
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.00),
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.05),
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.10), // pause starts
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.20),
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.30),
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.41), // 0.31s of pause >= 0.3s -> fires
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.50), // trailing silence, no new fire
        ]
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("speculative result")])
        // Exactly one request: the speculative one. No second ("real") request at audio end.
        #expect(fake.transcribeCallCount == 1)

        // The speculative snapshot must have been taken when the pause crossed the threshold
        // (chunks 0...5 = 6 chunks: 2 speech + 4 pause, the last of which is the one whose
        // cumulative pause duration first reaches the 0.3s threshold), not after the trailing
        // silence chunk (7 chunks) — i.e. it's a snapshot, not the full stream.
        let header = try #require(ParsedWAVHeader(fake.calls[0].wav))
        #expect(header.dataSize == UInt32(6 * TestFixtures.audioChunk().pcm16.count))
    }

    /// speech -> pause long enough to fire speculatively (with a slow response, so it's still in
    /// flight) -> MORE speech (invalidates the speculative snapshot and cancels it) -> stream
    /// ends. The stale speculative result must never be used; a fresh request covering the full
    /// audio must be made instead.
    @Test func talkingAfterPause_ignoresStaleSpeculativeAndFiresFreshRequest() async throws {
        // Branch on the WAV's byte size, not call order: the speculative request is an
        // independent, unstructured `Task` (started from `fire`) racing against the engine's own
        // loop, so which of the two calls the fake records *first* is not deterministic — only
        // the audio each one actually covers is.
        let chunkBytes = TestFixtures.audioChunk().pcm16.count
        let speculativeSnapshotBytes = UInt32(3 * chunkBytes)
        let fake = FakeCloudBatchTranscribing { wav, _, _ in
            let header = ParsedWAVHeader(wav)
            if header?.dataSize == speculativeSnapshotBytes {
                // Slow: still in flight when new speech arrives below.
                try await Task.sleep(for: .milliseconds(300))
                return CloudTranscript(text: "STALE — must not be used")
            }
            return CloudTranscript(text: "fresh correct result")
        }
        let engine = CloudBatchTranscriptionEngine(
            transcriber: fake,
            maxSpeculativeRequests: 3,
            speculativePauseThreshold: 0.3,
            speculativeLevelThreshold: 0.1
        )

        let chunks = [
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.00),
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.10),
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.41), // pause fires speculative #1 (slow) — 3 chunks so far
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.45), // speech resumes: invalidates + cancels #1
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.50),
        ]
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("fresh correct result")])
        #expect(fake.transcribeCallCount == 2)
        // The fresh (real) request must cover the FULL audio (all 5 chunks), not just the
        // pre-pause snapshot.
        let fullAudioCall = try #require(fake.calls.first { $0.wav.count != Int(speculativeSnapshotBytes) + 44 })
        let header = try #require(ParsedWAVHeader(fullAudioCall.wav))
        #expect(header.dataSize == UInt32(chunks.count * chunkBytes))
    }

    /// A clip with no qualifying pause at all (speech right up to release) must behave exactly
    /// like before speculation existed: one request, covering the full audio, at audio end.
    @Test func noQualifyingPause_behavesLikeBeforeSpeculation() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "no pause result"))
        let engine = CloudBatchTranscriptionEngine(
            transcriber: fake,
            maxSpeculativeRequests: 3,
            speculativePauseThreshold: 0.3,
            speculativeLevelThreshold: 0.1
        )

        let chunks = (0..<6).map { TestFixtures.audioChunk(level: 0.5, timestamp: Double($0) * 0.05) }
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("no pause result")])
        #expect(fake.transcribeCallCount == 1)
    }

    /// A short trailing pause that never crosses the threshold before audio ends must not fire a
    /// speculative request, and must not force one at audio end either — falls through to the
    /// normal single full-audio request.
    @Test func pauseShorterThanThreshold_neverFiresSpeculatively() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "result"))
        let engine = CloudBatchTranscriptionEngine(
            transcriber: fake,
            maxSpeculativeRequests: 3,
            speculativePauseThreshold: 0.6,
            speculativeLevelThreshold: 0.1
        )

        let chunks = [
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.00),
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.05),
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.10), // pause starts, but...
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.30), // ...only 0.2s — under 0.6s threshold
        ]
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}

        #expect(fake.transcribeCallCount == 1)
        let header = try #require(ParsedWAVHeader(fake.calls[0].wav))
        #expect(header.dataSize == UInt32(chunks.count * TestFixtures.audioChunk().pcm16.count))
    }

    /// With the cap set to 1, a second qualifying pause (after intervening speech invalidated the
    /// first speculative attempt) must not fire a second speculative request — the session falls
    /// through to one fresh full-audio request at audio end.
    @Test func capLimitsSpeculativeRequestCount() async throws {
        // Branch on WAV size, not call order — see the comment in
        // `talkingAfterPause_ignoresStaleSpeculativeAndFiresFreshRequest` for why call order
        // between the speculative (unstructured `Task`) and fresh (structured) calls isn't
        // deterministic.
        let speculativeSnapshotBytes = UInt32(3 * TestFixtures.audioChunk().pcm16.count)
        let fake = FakeCloudBatchTranscribing { wav, _, _ in
            if ParsedWAVHeader(wav)?.dataSize == speculativeSnapshotBytes {
                try await Task.sleep(for: .milliseconds(200))
                return CloudTranscript(text: "STALE — must not be used")
            }
            return CloudTranscript(text: "fresh final")
        }
        let engine = CloudBatchTranscriptionEngine(
            transcriber: fake,
            maxSpeculativeRequests: 1,
            speculativePauseThreshold: 0.3,
            speculativeLevelThreshold: 0.1
        )

        let chunks = [
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.00), // speech
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.10), // pause #1 starts
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.41), // fires speculative #1 (cap now hit)
            TestFixtures.audioChunk(level: 0.5, timestamp: 0.45), // speech resumes, invalidates #1
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.55), // pause #2 starts
            TestFixtures.audioChunk(level: 0.02, timestamp: 0.90), // would qualify, but cap blocks it
        ]
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("fresh final")])
        // Exactly 2 calls total: the one capped speculative attempt (stale, ignored) + one fresh
        // final — never a 3rd call for the second pause.
        #expect(fake.transcribeCallCount == 2)
    }

    /// Cancelling the consuming task while a speculative result is being awaited at audio end
    /// must stop promptly, not hang for the speculative request's full duration.
    @Test func cancellationWhileAwaitingSpeculativeResult_stopsPromptly() async throws {
        let fake = FakeCloudBatchTranscribing(result: CloudTranscript(text: "too slow"), transcribeDelay: .seconds(30))
        let engine = CloudBatchTranscriptionEngine(
            transcriber: fake,
            maxSpeculativeRequests: 3,
            speculativePauseThreshold: 0.3,
            speculativeLevelThreshold: 0.1
        )

        let (audio, continuation) = AsyncStream<AudioChunk>.makeStream()
        continuation.yield(TestFixtures.audioChunk(level: 0.5, timestamp: 0.00))
        continuation.yield(TestFixtures.audioChunk(level: 0.02, timestamp: 0.10))
        continuation.yield(TestFixtures.audioChunk(level: 0.02, timestamp: 0.41)) // fires speculative (30s delay)
        continuation.finish()

        let stream = engine.transcribe(audio: audio, options: TranscriptionOptions())
        let consumer = Task<Error?, Never> {
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        let error = await consumer.value

        if let prosioError = error as? ProsioError {
            #expect(prosioError == .cancelled)
        }
    }
}
