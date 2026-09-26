import Foundation
import ProsioCore

/// Tiny leading chip shown in the capsule only when the session isn't plain dictation. Scene
/// adaptation (rewrite) is deliberately invisible — no chip — per the P1 design: the chip is only
/// for things the user actively chose (Edit, Translate, Ask).
enum HUDModeChip: Equatable {
    case edit
    case ask
    /// `shortCode` e.g. "EN" — see `TranslateLanguages`.
    case translate(shortCode: String)
}

/// Plain, `Equatable` snapshot of everything the HUD needs to render.
/// Derived from `DictationController` by `HUDController`, or synthesized by `HUDController.showcase()`.
/// Keeping this a value type lets previews and the showcase render any state without a real session.
///
/// Intentionally does NOT carry a caret rect: the capsule is bottom-center only (no caret-following) —
/// simpler, steadier, and one less thing that has to change every render.
struct HUDViewState: Equatable {
    enum Phase: Equatable {
        case idle
        case listening
        case finalizing
        /// P1: transcript is being transformed (rewrite / translate / edit) — same shimmer look as
        /// `.finalizing`, with `composeLabel` as the shimmer placeholder when there's no text yet.
        case composing
        case inserting
        case finished(InsertionOutcome)
        case failed(String)
    }

    var phase: Phase = .idle
    var previewText: String = ""
    var levelHistory: [Float] = Array(repeating: 0, count: DictationController.levelHistoryLength)
    var level: Float = 0
    /// P1: what this session is for — drives the mode chip. `.dictate` (the common case) shows a
    /// chip only when translating; `.edit`/`.ask` always show their own chip.
    var intent: DictationIntent = .dictate
    /// Set only when `intent == .dictate && translateEnabled` — the chip's short target code.
    var translateShortCode: String? = nil
    /// P1: shimmer placeholder label for `.composing` when there's no transcript yet (e.g.
    /// "Translating…", "Rewriting…"). Falls back to a generic label if nil.
    var composeLabel: String? = nil

    var isVisible: Bool { phase != .idle }

    /// Whether the waveform + live preview strip should be shown (as opposed to a status glyph + line).
    var showsWaveform: Bool {
        phase == .listening
    }

    /// Whether this phase shows the shimmering (processing/composing) text or label.
    var showsShimmer: Bool {
        switch phase {
        case .finalizing, .composing, .inserting: true
        default: false
        }
    }

    /// The shimmer placeholder label used when there's no transcript yet, for `.finalizing`/`.composing`/`.inserting`.
    var shimmerPlaceholder: String {
        phase == .composing ? (composeLabel ?? "Working…") : "Processing…"
    }

    var modeChip: HUDModeChip? {
        switch intent {
        case .edit: .edit
        case .ask: .ask
        case .dictate: translateShortCode.map { .translate(shortCode: $0) }
        }
    }

    /// Whether the mode chip should be shown for the current phase (only while a session is active).
    var showsModeChip: Bool {
        switch phase {
        case .listening, .finalizing, .composing, .inserting: modeChip != nil
        default: false
        }
    }

    /// Short status line shown once a session has stopped listening.
    var statusText: String? {
        switch phase {
        case .finished(.copiedToClipboard): "Copied — ⌘V"
        case .finished(.failed): "Couldn't insert"
        case .failed(let message): message
        case .idle, .listening, .finalizing, .composing, .inserting, .finished(.pasted), .finished(.accessibility): nil
        }
    }

    /// True while showing a state where the panel should accept clicks on a "Copy" affordance.
    var offersCopyAction: Bool {
        switch phase {
        case .failed: !previewText.isEmpty
        case .finished(.failed): true
        default: false
        }
    }

    var isErrorTinted: Bool {
        switch phase {
        case .failed, .finished(.failed): true
        default: false
        }
    }
}

extension HUDViewState.Phase {
    /// `.answering` maps to `.idle` here on purpose — the answer card takes over the whole
    /// presentation for that phase, and the capsule simply hides (see `HUDController`).
    init(_ phase: DictationPhase) {
        switch phase {
        case .idle: self = .idle
        case .listening: self = .listening
        case .finalizing: self = .finalizing
        case .composing: self = .composing
        case .inserting: self = .inserting
        case .answering: self = .idle
        case .finished(let outcome): self = .finished(outcome)
        case .failed(let error): self = .failed(error.hudMessage)
        }
    }
}

extension ProsioError {
    /// Short, user-facing description for the HUD's status line.
    var hudMessage: String {
        switch self {
        case .microphonePermissionDenied: "Microphone access needed"
        case .accessibilityPermissionDenied: "Accessibility access needed"
        case .audioUnavailable: "Microphone unavailable"
        case .notSignedIn: "Sign in required"
        case .quotaExceeded: "Usage limit reached"
        case .network: "Network error"
        case .engineUnavailable: "Dictation unavailable"
        case .transcriptionFailed: "Couldn't transcribe"
        case .emptyTranscript: "Didn't catch that"
        case .cancelled: "Cancelled"
        }
    }
}

#if DEBUG
extension HUDViewState {
    static let previewListening = HUDViewState(
        phase: .listening,
        previewText: "So let's meet on Wednesday — no, Thursday at 3pm to go over the roadmap",
        levelHistory: (0..<DictationController.levelHistoryLength).map { i in
            Float(0.25 + 0.65 * abs(sin(Double(i) * 0.4)))
        },
        level: 0.6
    )
    static let previewFinalizing = HUDViewState(phase: .finalizing, previewText: previewListening.previewText, levelHistory: previewListening.levelHistory, level: 0.15)
    /// The toggle-mode "cloud is still polishing" wait: mic already closed, no on-device text yet.
    static let previewProcessingNoText = HUDViewState(phase: .finalizing, previewText: "", level: 0)
    static let previewFinishedPasted = HUDViewState(phase: .finished(.pasted), previewText: previewListening.previewText)
    static let previewFinishedCopied = HUDViewState(phase: .finished(.copiedToClipboard), previewText: previewListening.previewText)
    static let previewFailed = HUDViewState(phase: .failed(ProsioError.network("timeout").hudMessage), previewText: "")

    static let previewEditListening = HUDViewState(
        phase: .listening,
        previewText: "make this sound more confident",
        levelHistory: previewListening.levelHistory,
        level: 0.5,
        intent: .edit
    )
    static let previewTranslateListening = HUDViewState(
        phase: .listening,
        previewText: "这是今天的会议纪要",
        levelHistory: previewListening.levelHistory,
        level: 0.5,
        intent: .dictate,
        translateShortCode: "EN"
    )
    static let previewComposingNoText = HUDViewState(phase: .composing, composeLabel: "Translating…")
    static let previewAskListening = HUDViewState(
        phase: .listening,
        previewText: "what's the capital of Portugal",
        levelHistory: previewListening.levelHistory,
        level: 0.5,
        intent: .ask
    )
}
#endif
