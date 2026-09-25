import Foundation
import ProsioCore

/// Streams audio to Vercel AI Gateway (`google/gemini-3.5-transcribe-live`, SMART mode) over WebSocket,
/// authenticating with a short-lived token from `GatewayTokenProviding`.
/// PUBLIC API FROZEN — implementation owned by speech agent.
///
/// Wire protocol: see `docs/gateway-ws-protocol.md`.
public struct GatewayTranscriptionEngine: TranscriptionEngine {
    public let model: String
    public let tokenProvider: any GatewayTokenProviding

    let connecting: any WebSocketConnecting
    /// Instance (not static) so tests can shorten them without mutating shared global state —
    /// Swift Testing runs tests concurrently by default.
    let connectTimeout: Duration
    let finalTimeout: Duration

    static let maxAudioFrameBytes = 64 * 1024
    /// Wire sample rate sent to Google via the Gateway — matches `AudioFormat.pcm16Mono16k`
    /// exactly, so no resampling is needed (Gemini Live only accepts 16 kHz; the Gateway returns
    /// 400 "Unsupported inputAudioFormat" for 24 kHz — confirmed live, see
    /// docs/gateway-ws-protocol.md §7).
    static let wireSampleRate: Double = AudioFormat.pcm16Mono16k.sampleRate

    public init(model: String = ModelID.cloudTranscribe, tokenProvider: any GatewayTokenProviding, session: URLSession = .shared) {
        self.init(model: model, tokenProvider: tokenProvider, connecting: URLSessionWebSocketConnecting(session: session))
    }

    /// Test/internal seam: inject a fake `WebSocketConnecting` (and optionally shorter timeouts)
    /// instead of a real `URLSession`.
    init(
        model: String,
        tokenProvider: any GatewayTokenProviding,
        connecting: any WebSocketConnecting,
        connectTimeout: Duration = .seconds(5),
        finalTimeout: Duration = .seconds(8)
    ) {
        self.model = model
        self.tokenProvider = tokenProvider
        self.connecting = connecting
        self.connectTimeout = connectTimeout
        self.finalTimeout = finalTimeout
    }

    public var id: String { "gateway.\(model.split(separator: "/").last.map(String.init) ?? model)" }
    public var isOnDevice: Bool { false }

    public func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(audio: audio, options: options, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProsioError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Flow

    private func run(
        audio: AsyncStream<AudioChunk>,
        options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        // Start consuming audio immediately: `relay`'s unbounded buffering is our "in-memory
        // buffer" while we mint a token and open the socket concurrently, per the contract.
        let (relay, relayContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let forwardingTask = Task {
            for await chunk in audio {
                if Task.isCancelled { break }
                relayContinuation.yield(chunk)
            }
            relayContinuation.finish()
        }
        defer { forwardingTask.cancel() }

        try Task.checkCancellation()

        let token = try await fetchToken()

        let connection: any WebSocketConnection
        do {
            connection = try await withTimeout(connectTimeout, onTimeout: .network("gateway connect timed out")) {
                try connecting.connect(url: token.url, authToken: token.token)
            }
        } catch {
            throw Self.mapTransportError(error)
        }

        do {
            let startFrame = try GatewayWireProtocol.startFrame(sampleRate: Self.wireSampleRate, options: options)
            try await withTimeout(connectTimeout, onTimeout: .network("gateway connect timed out")) {
                try await connection.send(text: startFrame)
            }
        } catch {
            connection.close(code: 1011)
            throw Self.mapTransportError(error)
        }

        let audioDoneMarker = DeadlineMarker()
        let finalTimeout = self.finalTimeout
        let debugLogging = ProcessInfo.processInfo.environment["PROSIO_GATEWAY_DEBUG"] == "1"

        // Three siblings, not a per-message race: `sendAudio` and `receiveEvents` run for the
        // whole connection lifetime concurrently (so partials can be yielded the moment they
        // arrive, without waiting on anything audio-related), and a single long-lived watchdog
        // enforces the post-audio-done final timeout by force-closing the socket (which makes
        // the blocked `receive()` in `receiveEvents` throw promptly) rather than racing a fresh
        // `TaskGroup` per incoming message.
        let timedOut = TimeoutFlag()
        try await withThrowingTaskGroup(of: ChildOutcome.self) { group in
            group.addTask {
                try await Self.sendAudio(relay: relay, connection: connection, audioDoneMarker: audioDoneMarker)
                return .senderDone
            }
            group.addTask {
                try await Self.receiveEvents(connection: connection, continuation: continuation, debugLogging: debugLogging)
                return .receiverDone
            }
            group.addTask {
                try await Self.finalTimeoutWatchdog(connection: connection, audioDoneMarker: audioDoneMarker, finalTimeout: finalTimeout, timedOut: timedOut)
            }

            do {
                var receiverDone = false
                while !receiverDone {
                    guard let outcome = try await group.next() else { break }
                    if outcome == .receiverDone { receiverDone = true }
                    // `.senderDone` just means all audio + audio-done were sent — keep waiting.
                }
                // Cancels the watchdog (and the sender, if for some reason it's still running);
                // their results are never retrieved, so a cancellation error from either is
                // silently discarded on scope exit rather than rethrown.
                group.cancelAll()
            } catch {
                connection.close(code: 1011)
                // The watchdog closes the socket before throwing, so the receiver's resulting
                // "connection closed" error can win the race — report the timeout either way.
                if timedOut.isSet { throw Self.finalTimeoutError }
                throw Self.mapTransportError(error)
            }
        }

        connection.close(code: 1000)
        if debugLogging {
            FileHandle.standardError.write(Data("[gateway] closed 1000 (normal)\n".utf8))
        }
    }

    private enum ChildOutcome: Sendable {
        case senderDone
        case receiverDone
    }

    private func fetchToken() async throws -> GatewayToken {
        do {
            return try await tokenProvider.token(for: model)
        } catch let error as ProsioError {
            throw error
        } catch {
            throw ProsioError.network(String(describing: error))
        }
    }

    /// Sends buffered + live audio, real-time paced from the moment sending starts. Pacing
    /// matters because connect setup (token mint + WS open + start frame) can take long enough
    /// that several seconds of audio pile up in `relay` before this loop ever runs; without
    /// pacing, that backlog gets flushed to the socket in a tight loop with no inter-frame delay,
    /// which the live Gateway appears to handle badly (dropped/delayed recognition — see
    /// docs/gateway-ws-protocol.md §7a). Pacing to real-time is a no-op once caught up (live mic
    /// audio already arrives on its own schedule), so this is safe for the normal case too.
    private static func sendAudio(
        relay: AsyncStream<AudioChunk>,
        connection: any WebSocketConnection,
        audioDoneMarker: DeadlineMarker
    ) async throws {
        let clock = ContinuousClock()
        let sendStart = clock.now
        var audioMillisecondsSent = 0

        do {
            for await chunk in relay {
                // No resampling: `chunk.pcm16` is already `AudioFormat.pcm16Mono16k`, matching
                // the Gateway wire rate exactly.
                let wireAudio = chunk.pcm16
                let scheduledInstant = sendStart.advanced(by: .milliseconds(audioMillisecondsSent))
                if clock.now < scheduledInstant {
                    try await Task.sleep(until: scheduledInstant)
                }

                for frame in wireAudio.chunked(maxBytes: maxAudioFrameBytes) {
                    try await connection.send(data: frame)
                }
                let sampleCount = wireAudio.count / 2
                audioMillisecondsSent += Int((Double(sampleCount) / wireSampleRate * 1000).rounded())
            }
            try await connection.send(text: GatewayWireProtocol.audioDoneFrame)
        } catch {
            await audioDoneMarker.mark()
            throw mapTransportError(error)
        }
        await audioDoneMarker.mark()
    }

    /// Reads server frames for the whole connection lifetime (no per-message timeout: the
    /// sibling `finalTimeoutWatchdog` bounds how long this can block after audio-done by closing
    /// the socket, which makes `connection.receive()` throw). Yields `.partial` the instant each
    /// `transcript-delta`/`transcript-partial` arrives — see `GatewayTranscriptAccumulator` for
    /// how those combine into one cumulative preview string (confirmed against a live run;
    /// `transcript-delta` is a whole committed segment, not an appendable fragment).
    private static func receiveEvents(
        connection: any WebSocketConnection,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation,
        debugLogging: Bool
    ) async throws {
        var accumulator = GatewayTranscriptAccumulator()

        while true {
            let message = try await connection.receive()
            guard case .text(let text) = message else { continue }
            if debugLogging {
                FileHandle.standardError.write(Data("[gateway] recv: \(text)\n".utf8))
            }
            // Unknown/malformed frames are ignored per envelope rule 6.
            guard let part = GatewayServerPart.decode(text) else { continue }

            switch part {
            case .streamStart, .responseMetadata, .raw:
                continue

            case .transcriptDelta(let delta):
                continuation.yield(.partial(accumulator.applyDelta(delta)))

            case .transcriptPartial(let text):
                continuation.yield(.partial(accumulator.applyPartial(text)))

            case .transcriptFinal(let text):
                accumulator.applyTranscriptFinal(text)

            case .finish(let text):
                let finalText = accumulator.resolveFinalText(finishText: text)
                guard !finalText.isEmpty else { throw ProsioError.emptyTranscript }
                continuation.yield(.final(finalText))
                return

            case .error(let message):
                throw ProsioError.transcriptionFailed(message)

            case .unknown:
                continue
            }
        }
    }

    /// Bounds how long `receiveEvents` may block waiting for `finish`/`error` once audio-done has
    /// been sent, by force-closing the socket after `finalTimeout` elapses (unmarked = audio
    /// still streaming = no timeout applies yet). One long-lived task for the whole connection,
    /// not re-armed per message.
    private static func finalTimeoutWatchdog(
        connection: any WebSocketConnection,
        audioDoneMarker: DeadlineMarker,
        finalTimeout: Duration,
        timedOut: TimeoutFlag
    ) async throws -> Never {
        let deadline = await audioDoneMarker.deadline(after: finalTimeout)
        try await Task.sleep(until: deadline)
        timedOut.set()
        connection.close(code: 1000)
        throw finalTimeoutError
    }

    private static let finalTimeoutError = ProsioError.network("timed out waiting for final transcript")

    private static func mapTransportError(_ error: Error) -> Error {
        if error is ProsioError { return error }
        if error is CancellationError { return ProsioError.cancelled }
        return ProsioError.network(String(describing: error))
    }
}

/// Set by the final-timeout watchdog just before it force-closes the socket.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
