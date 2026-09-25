import Foundation
import Testing
import ProsioCore
@testable import ProsioTranscription

@Suite struct GatewayTranscriptionEngineTests {

    // MARK: - Buffering before connect

    @Test func audioBufferedWhileTokenMintingIsSlow_thenFlushedInOrder() async throws {
        // The token provider takes 100ms; the audio stream finishes instantly. If buffering
        // works, none of the chunks are dropped and they still arrive at the socket once
        // connected.
        let chunks = (0..<5).map { TestFixtures.audioChunk(pcm16: [Int16($0)], timestamp: Double($0) * 0.05) }
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"finish","text":"ok","segments":[]}"#,
        ])
        let connecting = FakeWebSocketConnecting(connection: fakeConnection)
        let tokenProvider = FakeGatewayTokenProvider(token: TestFixtures.gatewayToken, delay: .milliseconds(100))

        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: tokenProvider,
            connecting: connecting
        )

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.final("ok")])
        let sentData = await fakeConnection.sentData
        // Every chunk should have produced at least one binary frame; none dropped.
        #expect(sentData.count == chunks.count)
    }

    // MARK: - Start frame content

    @Test func sendsStartFrameFirstThenAudioDoneAfterAudioEnds() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"finish","text":"ok","segments":[]}"#,
        ])
        let connecting = FakeWebSocketConnecting(connection: fakeConnection)
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: connecting
        )

        for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions(mode: .smart, vocabulary: ["Prosio"])) {}

        let sentTexts = await fakeConnection.sentTexts
        #expect(sentTexts.count == 2)
        #expect(sentTexts[0].contains("\"type\":\"transcription-stream.start\""))
        #expect(sentTexts[0].contains("\"mode\":\"SMART\""))
        #expect(sentTexts[0].contains("Prosio"))
        #expect(sentTexts[1] == GatewayWireProtocol.audioDoneFrame)
    }

    // MARK: - Partial accumulation

    @Test func deltaPartsAccumulateCumulatively() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"transcript-delta","delta":"Hello"}"#,
            #"{"type":"transcript-delta","delta":", world"}"#,
            #"{"type":"finish","text":"Hello, world.","segments":[]}"#,
        ])
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [.partial("Hello"), .partial("Hello, world"), .final("Hello, world.")])
    }

    /// Reflects the real server behavior confirmed against a live Gateway run (2026-09-26): a
    /// segment's `transcript-partial`s are progressively replaced (not appended) as the segment
    /// firms up, then exactly one `transcript-delta` commits the SMART-cleaned text for that
    /// whole segment (superseding its partials — the delta is not an incremental fragment), then
    /// the next segment's partials start fresh on top of what's committed so far.
    @Test func partialsReplaceWithinASegment_deltaCommitsTheSegment() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"transcript-partial","text":"Hel"}"#,
            #"{"type":"transcript-partial","text":"Hello"}"#,
            #"{"type":"transcript-delta","delta":"Hello there."}"#,
            #"{"type":"transcript-partial","text":"How"}"#,
            #"{"type":"finish","text":"Hello there. How are you?","segments":[]}"#,
        ])
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        #expect(events == [
            .partial("Hel"),
            .partial("Hello"),
            .partial("Hello there."), // the delta commits and clears the segment's partial
            .partial("Hello there.How"), // committed ("Hello there.") + new segment's partial "How"
            .final("Hello there. How are you?"),
        ])
    }

    @Test func transcriptFinal_isRememberedOnlyAsAFallbackForFinishText_doesNotAffectPartials() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"transcript-partial","text":"Hi"}"#,
            #"{"type":"transcript-final","text":"Hi there."}"#,
            // `finish.text` is empty here: the engine should fall back to the transcript-final text.
            #"{"type":"finish","text":"","segments":[]}"#,
        ])
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        var events: [TranscriptEvent] = []
        for try await event in engine.transcribe(audio: audio, options: TranscriptionOptions()) {
            events.append(event)
        }

        // The `transcript-final` in the middle must NOT change the running `.partial` — only
        // `transcript-delta`/`transcript-partial` do that.
        #expect(events == [.partial("Hi"), .final("Hi there.")])
    }

    @Test func partialArrivesWhileAudioStillStreaming() async throws {
        // Regression test for a live-run bug: all `.partial`s were only observed after the audio
        // stream finished. The fake socket delivers a message on the very first `receive()` call
        // regardless of audio state, so this proves nothing in the engine artificially gates
        // receiving/yielding behind audio completion (e.g. awaiting the sender's completion, or
        // the post-audio-done deadline marker, before the receive loop is allowed to run).
        let fakeConnection = FakeWebSocketConnection(
            messages: [#"{"type":"transcript-partial","text":"Hello"}"#],
            thenFinish: .hang
        )
        let (audio, audioContinuation) = AsyncStream<AudioChunk>.makeStream()
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        let stream = engine.transcribe(audio: audio, options: TranscriptionOptions())
        audioContinuation.yield(TestFixtures.audioChunk())
        // Audio stream intentionally left open (not finished) at this point.

        let collected = CollectedEvents()
        let consumer = Task {
            do {
                for try await event in stream {
                    await collected.append(event)
                }
            } catch {
                // Expected once we cancel below.
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        let eventsSoFar = await collected.values
        #expect(eventsSoFar == [.partial("Hello")])

        // Clean up: cancel the still-open audio side and the consuming task.
        audioContinuation.finish()
        consumer.cancel()
        _ = await consumer.value
    }

    // MARK: - Error mapping

    @Test func serverErrorPart_throwsTranscriptionFailed() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"error","error":{"message":"upstream boom","type":"internal_server_error"}}"#,
        ])
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected an error to be thrown")
        } catch let error as ProsioError {
            #expect(error == .transcriptionFailed("upstream boom"))
        }
    }

    @Test func tokenProviderNotSignedIn_passesThrough() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in continuation.finish() }
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(error: ProsioError.notSignedIn),
            connecting: FakeWebSocketConnecting(connection: FakeWebSocketConnection(messages: []))
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected an error to be thrown")
        } catch let error as ProsioError {
            #expect(error == .notSignedIn)
        }
    }

    @Test func tokenProviderQuotaExceeded_passesThrough() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in continuation.finish() }
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(error: ProsioError.quotaExceeded),
            connecting: FakeWebSocketConnecting(connection: FakeWebSocketConnection(messages: []))
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected an error to be thrown")
        } catch let error as ProsioError {
            #expect(error == .quotaExceeded)
        }
    }

    @Test func connectFailure_mapsToNetworkError() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in continuation.finish() }
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connectError: URLError(.cannotConnectToHost))
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected an error to be thrown")
        } catch let error as ProsioError {
            guard case .network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
    }

    @Test func emptyFinishText_throwsEmptyTranscript() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        let fakeConnection = FakeWebSocketConnection(messages: [
            #"{"type":"finish","text":"","segments":[]}"#,
        ])
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected an error to be thrown")
        } catch let error as ProsioError {
            #expect(error == .emptyTranscript)
        }
    }

    // MARK: - Cancellation

    @Test func cancellingConsumingTask_closesSocketAndStopsPromptly() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            // Never finishes on its own: this only ends via cancellation.
        }
        let fakeConnection = FakeWebSocketConnection(messages: [], thenFinish: .hang)
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection)
        )

        let stream = engine.transcribe(audio: audio, options: TranscriptionOptions())

        let consumer = Task {
            var events: [TranscriptEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                }
            } catch {
                // Cancellation surfaces as an error here; that's expected.
            }
            return events
        }

        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.value

        // Give the fire-and-forget close() Task a moment to run.
        try await Task.sleep(for: .milliseconds(50))
        let closeCodes = await fakeConnection.closeCodes
        #expect(!closeCodes.isEmpty)
    }

    // MARK: - Final timeout

    @Test func noFinishAfterAudioDone_timesOutWithNetworkError() async throws {
        let audio = AsyncStream<AudioChunk> { continuation in
            continuation.yield(TestFixtures.audioChunk())
            continuation.finish()
        }
        // Server never sends `finish`/`error` after audio-done: receive() hangs.
        let fakeConnection = FakeWebSocketConnection(messages: [], thenFinish: .hang)
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection),
            connectTimeout: .milliseconds(200),
            finalTimeout: .milliseconds(100)
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected a timeout error")
        } catch let error as ProsioError {
            guard case .network(let message) = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
            #expect(message.contains("timed out"))
        }
    }

    @Test func connectTimeout_firesWhenStartFrameSendIsTooSlow() async throws {
        // `connectTimeout` wraps opening the socket and sending the start frame (see
        // docs/gateway-ws-protocol.md §6); simulate a slow send to exercise that wrapper directly
        // without depending on token-minting timing.
        let audio = AsyncStream<AudioChunk> { continuation in continuation.finish() }
        let fakeConnection = FakeWebSocketConnection(messages: [], sendDelay: .milliseconds(500))
        let engine = GatewayTranscriptionEngine(
            model: ModelID.cloudTranscribe,
            tokenProvider: FakeGatewayTokenProvider(token: TestFixtures.gatewayToken),
            connecting: FakeWebSocketConnecting(connection: fakeConnection),
            connectTimeout: .milliseconds(100),
            finalTimeout: .seconds(1)
        )

        do {
            for try await _ in engine.transcribe(audio: audio, options: TranscriptionOptions()) {}
            Issue.record("expected a connect timeout error")
        } catch let error as ProsioError {
            guard case .network(let message) = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
            #expect(message.contains("connect timed out"))
        }
    }
}
