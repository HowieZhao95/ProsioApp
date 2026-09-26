// FROZEN CONTRACT — owned by the architect. Do not change signatures without approval.
// Every module codes against these types; implementations live elsewhere.

import CoreGraphics
import Foundation

// MARK: - Model IDs

public enum ModelID {
    /// Cloud streaming transcription via Vercel AI Gateway (SMART mode).
    public static let cloudTranscribe = "google/gemini-3.5-transcribe-live"
    /// Fast decision/routing model (P1).
    public static let router = "typesafe-ai/jev"
}

// MARK: - Audio

public struct AudioFormat: Sendable, Hashable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Wire format for every engine: 16 kHz, 16-bit signed little-endian, mono. (The only rate
    /// Gemini Live accepts — the Gateway returns 400 "Unsupported inputAudioFormat" for 24 kHz,
    /// confirmed live.)
    public static let pcm16Mono16k = AudioFormat(sampleRate: 16_000, channelCount: 1)
}

public struct AudioChunk: Sendable {
    /// PCM16 little-endian mono samples in `AudioFormat.pcm16Mono16k`.
    public var pcm16: Data
    /// Normalised RMS level 0...1, for metering UI.
    public var level: Float
    /// Seconds since capture started.
    public var timestamp: TimeInterval

    public init(pcm16: Data, level: Float, timestamp: TimeInterval) {
        self.pcm16 = pcm16
        self.level = level
        self.timestamp = timestamp
    }
}

public protocol AudioCapturing: AnyObject, Sendable {
    /// Opens the microphone and returns a stream of chunks in `AudioFormat.pcm16Mono16k`.
    /// The stream finishes after `stop()` is called. Throws `ProsioError.microphonePermissionDenied`
    /// or `ProsioError.audioUnavailable`.
    func start() throws -> AsyncStream<AudioChunk>
    /// Closes the microphone and finishes the stream returned by `start()`. Idempotent.
    func stop()
}

// MARK: - Transcription

public enum TranscriptionMode: String, Sendable, Codable, Hashable {
    /// Provider cleans fillers, resolves self-corrections, punctuates and formats.
    case smart
    /// Literal transcript.
    case verbatim
}

public struct TranscriptionOptions: Sendable, Hashable {
    public var mode: TranscriptionMode
    /// Personal dictionary terms (names, jargon) to bias recognition.
    public var vocabulary: [String]
    /// BCP-47 hints, e.g. ["zh-CN", "en-US"]. Empty = auto-detect.
    public var languageHints: [String]

    public init(mode: TranscriptionMode = .smart, vocabulary: [String] = [], languageHints: [String] = []) {
        self.mode = mode
        self.vocabulary = vocabulary
        self.languageHints = languageHints
    }
}

public enum TranscriptEvent: Sendable, Equatable {
    /// The full current preview text (cumulative, NOT a delta). May be revised by later events.
    case partial(String)
    /// Final text for the whole session. Emitted exactly once, as the last element.
    case final(String)
}

public protocol TranscriptionEngine: Sendable {
    /// Stable identifier, e.g. "gateway.gemini-3.5-transcribe-live", "apple.speechanalyzer".
    var id: String { get }
    var isOnDevice: Bool { get }
    /// Consumes `audio` until it finishes, then flushes and yields exactly one `.final`, then finishes.
    /// Must throw `ProsioError` values. Must stop promptly when the consuming task is cancelled.
    func transcribe(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptEvent, Error>
}

// MARK: - Cloud batch transcription

public struct CloudTranscript: Sendable, Codable, Hashable {
    public var text: String
    public var language: String?
    public var durationSeconds: Double?

    public init(text: String, language: String? = nil, durationSeconds: Double? = nil) {
        self.text = text
        self.language = language
        self.durationSeconds = durationSeconds
    }
}

/// Transcribes a complete recording in the cloud (Prosio backend -> Gateway `google/gemini-3.5-transcribe`, SMART).
/// Implemented by `BackendClient` (`POST /api/transcribe`, see docs/API.md).
public protocol CloudBatchTranscribing: Sendable {
    /// - Parameter wav: a complete RIFF/WAVE file, 16 kHz mono PCM16.
    func transcribe(wav: Data, options: TranscriptionOptions) async throws -> CloudTranscript
    /// Opens/refreshes the HTTPS connection ahead of time (called when dictation starts) to cut first-byte latency.
    func prewarm() async
}

// MARK: - Routing (auto mode: is the on-device transcript good enough to insert as-is?)

public struct RouteDecision: Sendable, Codable, Hashable {
    /// True when the cloud SMART pass is needed; false = insert the on-device transcript directly.
    public var needsCloud: Bool
    /// Router's probability that the local transcript is clean enough to insert as-is (0...1), if known.
    public var cleanProbability: Double?
    /// Short machine-readable reason, e.g. "clean", "needs-cleanup", "likely-misrecognized", "router-error".
    public var reason: String

    public init(needsCloud: Bool, cleanProbability: Double? = nil, reason: String) {
        self.needsCloud = needsCloud
        self.cleanProbability = cleanProbability
        self.reason = reason
    }
}

/// Decides, from the on-device transcript, whether the cloud pass is needed (backend -> Gateway `typesafe-ai/jev`).
/// Implemented by `BackendClient` (`POST /api/route`, see docs/API.md). Callers must treat errors/timeouts as "needs cloud".
public protocol RouteDeciding: Sendable {
    func decide(localTranscript: String, options: TranscriptionOptions) async throws -> RouteDecision
}

// MARK: - Gateway token

public struct GatewayToken: Sendable, Codable, Hashable {
    /// Single-use, short-lived client secret minted by the Prosio backend via AI Gateway `getToken`.
    public var token: String
    /// WebSocket URL returned alongside the token.
    public var url: URL
    public var model: String
    public var expiresAt: Date

    public init(token: String, url: URL, model: String, expiresAt: Date) {
        self.token = token
        self.url = url
        self.model = model
        self.expiresAt = expiresAt
    }
}

public protocol GatewayTokenProviding: Sendable {
    func token(for model: String) async throws -> GatewayToken
}

// MARK: - Focus context & insertion

public struct FocusContext: Sendable, Codable, Hashable {
    public var bundleID: String?
    public var appName: String?
    public var processID: Int32?
    /// Caret rect in global screen coordinates (AppKit, bottom-left origin), if available.
    public var caretRect: CGRect?
    /// True when a secure text field has focus (e.g. password) — never paste there.
    public var isSecureInput: Bool

    public init(bundleID: String? = nil, appName: String? = nil, processID: Int32? = nil, caretRect: CGRect? = nil, isSecureInput: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.processID = processID
        self.caretRect = caretRect
        self.isSecureInput = isSecureInput
    }
}

@MainActor
public protocol FocusContextProviding: AnyObject {
    func currentContext() -> FocusContext
}

public enum InsertionOutcome: String, Sendable, Codable, Hashable {
    /// Inserted via clipboard + simulated Cmd+V.
    case pasted
    /// Inserted via Accessibility API.
    case accessibility
    /// Could not insert; text left on the clipboard for the user.
    case copiedToClipboard
    case failed
}

@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String, into context: FocusContext?) async -> InsertionOutcome
}

// MARK: - Errors

public enum ProsioError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case audioUnavailable(String)
    case notSignedIn
    case quotaExceeded
    case network(String)
    case engineUnavailable(String)
    case transcriptionFailed(String)
    case emptyTranscript
    case cancelled
}

// MARK: - Dictation

public enum DictationTrigger: Sendable, Hashable {
    /// Push-to-talk: `stop()` is called on key release.
    case hold
    /// Tap to start, tap again to stop.
    case toggle
}

public enum DictationPhase: Sendable, Equatable {
    case idle
    /// Microphone open, audio streaming, `previewText` updating.
    case listening
    /// Microphone closed, waiting for the engine's `.final`.
    case finalizing
    case inserting
    case finished(InsertionOutcome)
    case failed(ProsioError)
}
