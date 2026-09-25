import Foundation

/// Tries `primary`; if it fails before emitting any event, replays buffered audio into `secondary`.
/// PUBLIC API FROZEN — implementation owned by core agent.
public struct FallbackTranscriptionEngine: TranscriptionEngine {
    public let primary: any TranscriptionEngine
    public let secondary: any TranscriptionEngine

    /// Internal hook (not part of the frozen public contract): fired with `primary.id` as soon as
    /// a `transcribe` call starts, and again with `secondary.id` if/when that call falls back.
    /// Lets `DictationController` track which underlying engine actually produced the result
    /// (e.g. for usage billing keyed on the real engine id, not this wrapper's composite id).
    var onActiveEngineChange: (@Sendable (String) -> Void)?

    public init(primary: any TranscriptionEngine, secondary: any TranscriptionEngine) {
        self.primary = primary
        self.secondary = secondary
    }

    public var id: String { "fallback(\(primary.id)->\(secondary.id))" }
    public var isOnDevice: Bool { primary.isOnDevice }

    public func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let primaryEngine = primary
        let secondaryEngine = secondary
        let onActiveEngineChange = onActiveEngineChange

        return AsyncThrowingStream { continuation in
            let tee = AudioTee()
            let box = CancelBox()

            // Attach primary's feed before the pump starts consuming `audio`, so no chunk is lost.
            let primaryAudio = tee.attach()

            var pumpTaskRef: Task<Void, Never>!
            pumpTaskRef = Task {
                for await chunk in audio {
                    tee.push(chunk)
                }
                tee.finishInput()
            }
            box.add { pumpTaskRef.cancel() }

            var mainTaskRef: Task<Void, Never>!
            mainTaskRef = Task {
                onActiveEngineChange?(primaryEngine.id)

                var finalYielded = false
                var primaryError: Error?

                do {
                    for try await event in primaryEngine.transcribe(audio: primaryAudio, options: options) {
                        continuation.yield(event)
                        if case .final = event { finalYielded = true }
                    }
                } catch {
                    primaryError = error
                }

                if finalYielded {
                    box.cancelAll()
                    continuation.finish()
                    return
                }

                let wasCancelled: Bool = {
                    if primaryError is CancellationError { return true }
                    if let prosioError = primaryError as? ProsioError, prosioError == .cancelled { return true }
                    return false
                }()

                if Task.isCancelled || wasCancelled {
                    box.cancelAll()
                    continuation.finish(throwing: primaryError ?? ProsioError.cancelled)
                    return
                }

                // Primary failed (or ended silently) before `.final`, and we were not cancelled:
                // fall back to secondary, which replays every buffered chunk then keeps receiving
                // any audio still arriving live (or finishes immediately if the input already ended).
                onActiveEngineChange?(secondaryEngine.id)
                let secondaryAudio = tee.attach()
                do {
                    for try await event in secondaryEngine.transcribe(audio: secondaryAudio, options: options) {
                        continuation.yield(event)
                    }
                    box.cancelAll()
                    continuation.finish()
                } catch {
                    box.cancelAll()
                    continuation.finish(throwing: error)
                }
            }
            box.add { mainTaskRef.cancel() }

            continuation.onTermination = { _ in
                box.cancelAll()
            }
        }
    }
}

// MARK: - Internal plumbing

/// Broadcasts audio chunks to whichever listeners are currently attached, while retaining every
/// chunk seen so far so a listener attached *later* (the secondary engine) can be replayed the
/// full history before continuing to receive live chunks. All mutation + notification happens
/// under a single lock so replay-then-subscribe is atomic with respect to concurrent `push`.
private final class AudioTee: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [AudioChunk] = []
    private var finished = false
    private var listeners: [AsyncStream<AudioChunk>.Continuation] = []

    /// Returns a stream that immediately replays every chunk seen so far, then receives any
    /// future chunks live (or finishes right away if the input has already finished).
    func attach() -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            lock.lock()
            for chunk in buffer {
                continuation.yield(chunk)
            }
            if finished {
                lock.unlock()
                continuation.finish()
            } else {
                listeners.append(continuation)
                lock.unlock()
            }
        }
    }

    func push(_ chunk: AudioChunk) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        for listener in listeners {
            listener.yield(chunk)
        }
    }

    func finishInput() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        for listener in listeners {
            listener.finish()
        }
        listeners = []
    }
}

/// Collects cancellation closures for the unstructured tasks this engine spins up, so that
/// cancelling the consumer (`AsyncThrowingStream`'s `onTermination`) promptly cancels all of them.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellers: [() -> Void] = []
    private var cancelled = false

    func add(_ cancel: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            cancel()
            return
        }
        cancellers.append(cancel)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let toCancel = cancellers
        cancellers = []
        lock.unlock()
        for cancel in toCancel {
            cancel()
        }
    }
}
