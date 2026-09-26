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
    /// P1.2 additive: "local" (the server found `CloudTranscribeRequest.localTranscript` clean
    /// enough and skipped Gemini) or "cloud". `nil` from the legacy `transcribe(wav:options:)` path.
    public var source: String?
    /// P1.2 additive: the server-side intent decision for this session, returned inline with the
    /// transcript — replaces a separate `/api/intent` call on the main dictation path. A `nil`
    /// `intent` inside means "unavailable"; callers fall back to `IntentRules`.
    public var intent: IntentDecision?
    /// P1.2 additive: the server router's verdict that produced `source`.
    public var route: TranscribeRouteInfo?

    public init(text: String, language: String? = nil, durationSeconds: Double? = nil, source: String? = nil, intent: IntentDecision? = nil, route: TranscribeRouteInfo? = nil) {
        self.text = text
        self.language = language
        self.durationSeconds = durationSeconds
        self.source = source
        self.intent = intent
        self.route = route
    }
}

/// P1.2 additive: upload codec for a batch transcription request — "wav" (uncompressed, today's
/// baseline) or "ogg-opus" (speech's `OggOpusEncoder`, ~16x smaller). See docs/P1.2-AUDIO-ROUTING.md.
public enum UploadAudioFormat: String, Sendable, Codable, Hashable {
    case wav
    case oggOpus = "ogg-opus"
}

/// P1.2 additive: the server router's verdict on `CloudTranscribeRequest.localTranscript`, included
/// on every `/api/transcribe` response (`CloudTranscript.route`).
public struct TranscribeRouteInfo: Sendable, Codable, Hashable {
    /// Router's probability that the local transcript is clean enough to insert as-is (0...1), if known.
    public var cleanProbability: Double?
    /// Short machine-readable reason, e.g. "clean", "needs-cleanup", "router-unavailable".
    public var reason: String

    public init(cleanProbability: Double? = nil, reason: String) {
        self.cleanProbability = cleanProbability
        self.reason = reason
    }
}

/// P1.2 additive: everything `POST /api/transcribe` needs to do local-transcript-aware routing and
/// intent classification server-side in one round trip, instead of separate `/api/route` +
/// `/api/intent` calls. See docs/P1.2-AUDIO-ROUTING.md §3.
public struct CloudTranscribeRequest: Sendable {
    public var audioData: Data
    public var audioFormat: UploadAudioFormat
    public var options: TranscriptionOptions
    /// The on-device transcript, if any — lets the server skip Gemini when it's already clean.
    public var localTranscript: String?
    public var hasSelection: Bool
    public var app: AppContext?
    public var sessionID: UUID

    public init(audioData: Data, audioFormat: UploadAudioFormat = .wav, options: TranscriptionOptions, localTranscript: String? = nil, hasSelection: Bool = false, app: AppContext? = nil, sessionID: UUID = UUID()) {
        self.audioData = audioData
        self.audioFormat = audioFormat
        self.options = options
        self.localTranscript = localTranscript
        self.hasSelection = hasSelection
        self.app = app
        self.sessionID = sessionID
    }
}

/// Transcribes a complete recording in the cloud (Prosio backend -> Gateway `google/gemini-3.5-transcribe`, SMART).
/// Implemented by `BackendClient` (`POST /api/transcribe`, see docs/API.md).
public protocol CloudBatchTranscribing: Sendable {
    /// - Parameter wav: a complete RIFF/WAVE file, 16 kHz mono PCM16. Legacy single-shot call,
    ///   kept for existing conformers/callers (e.g. `ProsioTranscription.CloudBatchTranscriptionEngine`).
    func transcribe(wav: Data, options: TranscriptionOptions) async throws -> CloudTranscript
    /// P1.2: the main dictation path's single request (see `CloudTranscribeRequest`). Conformers
    /// that don't override this get a default bridge to the legacy method above (audioFormat/
    /// localTranscript/hasSelection/app silently dropped, `source`/`intent`/`route` come back nil)
    /// — see the `public extension` below. `BackendClient` overrides it with the real behavior.
    func transcribe(_ request: CloudTranscribeRequest) async throws -> CloudTranscript
    /// Opens/refreshes the HTTPS connection ahead of time (called when dictation starts) to cut first-byte latency.
    func prewarm() async
}

extension CloudBatchTranscribing {
    public func transcribe(_ request: CloudTranscribeRequest) async throws -> CloudTranscript {
        try await transcribe(wav: request.audioData, options: request.options)
    }
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
    /// Focused window title, if readable (P1: scene detection, prompts).
    public var windowTitle: String?
    /// Current page URL when the frontmost app is a browser, if readable.
    public var url: URL?
    /// Text selected in the focused element when dictation started (P1: Edit mode, Ask context).
    public var selectedText: String?

    public init(bundleID: String? = nil, appName: String? = nil, processID: Int32? = nil, caretRect: CGRect? = nil, isSecureInput: Bool = false, windowTitle: String? = nil, url: URL? = nil, selectedText: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.processID = processID
        self.caretRect = caretRect
        self.isSecureInput = isSecureInput
        self.windowTitle = windowTitle
        self.url = url
        self.selectedText = selectedText
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
    /// P1: transcript is being transformed by the compose engine (rewrite / translate / edit).
    case composing
    case inserting
    /// P1 Ask mode: the answer card is shown (streaming or done). Leaves via `dismissAnswer()`/`insertAnswer()`.
    case answering
    case finished(InsertionOutcome)
    case failed(ProsioError)
}

// MARK: - P1 modes (see docs/PROMPTS.md, docs/API.md "Compose")

/// What a dictation session is for. Chosen at `start`: `.edit` automatically when text is selected,
/// `.ask` from the Ask key, otherwise `.dictate`.
public enum DictationIntent: String, Sendable, Codable, Hashable {
    /// Insert what was said (optionally adapted to the scene or translated).
    case dictate
    /// The transcript is an instruction applied to `FocusContext.selectedText`; the result replaces the selection.
    case edit
    /// The transcript is a question; the answer streams into the answer card.
    case ask
}

// MARK: - Intent classification (server Jev, client `IntentRules` fallback — docs/PROMPTS.md §5b)

/// What a finished dictation is for, as decided by `IntentClassifying` (or its client-side
/// `IntentRules` fallback). A superset of `DictationIntent`: `.translate` has no `DictationIntent`
/// equivalent — a translate-classified session still reports `DictationIntent.dictate`.
public enum ClassifiedIntent: String, Codable, Sendable {
    case dictate, edit, ask, translate
}

public struct IntentDecision: Sendable, Codable, Hashable {
    /// `nil` when the classifier is unavailable (error/timeout on the server, `source: "unavailable"`)
    /// — callers must then fall back to `IntentRules`.
    public var intent: ClassifiedIntent?
    public var confidence: Double?
    /// e.g. "jev", "unavailable". Set to "rules" client-side when `IntentRules` made the call instead.
    public var source: String
    /// P1.2 additive: "local" | "final" — which transcript this decision was made on, when the
    /// server evaluated more than one (see docs/P1.2-AUDIO-ROUTING.md §3 step 3). `nil` from the
    /// standalone `/api/intent` response or when unavailable.
    public var classifiedOn: String?

    public init(intent: ClassifiedIntent?, confidence: Double? = nil, source: String, classifiedOn: String? = nil) {
        self.intent = intent
        self.confidence = confidence
        self.source = source
        self.classifiedOn = classifiedOn
    }
}

/// Classifies a finished dictation (backend -> Gateway `typesafe-ai/jev`). Implemented by
/// `BackendClient` (`POST /api/intent`). Callers must treat errors/timeouts/`intent: nil` as
/// "unavailable" and fall back to `IntentRules`.
public protocol IntentClassifying: Sendable {
    func classify(transcript: String, hasSelection: Bool, app: AppContext?) async throws -> IntentDecision
}

public enum WritingScene: String, Sendable, Codable, Hashable, CaseIterable {
    /// No adaptation — insert the SMART transcript directly (fastest path).
    case general, email, chat, code, document
}

public struct AppContext: Sendable, Codable, Hashable {
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?

    public init(bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil, url: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
    }
}

public struct ComposeTurn: Sendable, Codable, Hashable {
    public enum Role: String, Sendable, Codable, Hashable { case user, assistant }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ComposeRequest: Sendable, Codable, Hashable {
    public enum Mode: String, Sendable, Codable, Hashable {
        case rewrite, translate, edit, ask
        /// The whole utterance was a spoken translate command (e.g. "translate this to French: …",
        /// in whatever phrasing) — the server extracts the content and target itself, rather than
        /// the client stripping a fixed prefix. `targetLanguage` is still sent as the default.
        case translateCommand
    }

    public var mode: Mode
    /// Dictation (rewrite/translate), instruction (edit) or question (ask).
    public var text: String
    /// Edit: the text to change. Ask: optional context.
    public var selection: String?
    public var scene: WritingScene
    /// BCP-47 target for `.translate`, e.g. "en-US".
    public var targetLanguage: String?
    public var app: AppContext?
    public var vocabulary: [String]
    /// Ask follow-ups: previous turns, oldest first.
    public var history: [ComposeTurn]

    public init(mode: Mode, text: String, selection: String? = nil, scene: WritingScene = .general, targetLanguage: String? = nil, app: AppContext? = nil, vocabulary: [String] = [], history: [ComposeTurn] = []) {
        self.mode = mode
        self.text = text
        self.selection = selection
        self.scene = scene
        self.targetLanguage = targetLanguage
        self.app = app
        self.vocabulary = vocabulary
        self.history = history
    }
}

/// Transforms text with an LLM via the backend (`POST /api/compose`). Implemented by `BackendClient`.
public protocol Composing: Sendable {
    /// Streams the output as text DELTAS in order; the stream finishes when complete. Throws `ProsioError`.
    func compose(_ request: ComposeRequest) -> AsyncThrowingStream<String, Error>
}

/// Ask-mode answer card state, owned by `DictationController`.
public struct AnswerState: Sendable, Equatable {
    public var question: String
    /// Cumulative answer text (Markdown) so far.
    public var text: String
    public var isStreaming: Bool
    public var error: ProsioError?
    /// Completed turns of this thread (for display and follow-ups), oldest first.
    public var turns: [ComposeTurn]

    public init(question: String, text: String = "", isStreaming: Bool = true, error: ProsioError? = nil, turns: [ComposeTurn] = []) {
        self.question = question
        self.text = text
        self.isStreaming = isStreaming
        self.error = error
        self.turns = turns
    }
}
