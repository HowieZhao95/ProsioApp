import CoreGraphics
import ProsioCore

/// Plain, `Equatable` snapshot of everything the HUD needs to render.
/// Derived from `DictationController` by `HUDController`, or synthesized by `HUDController.showcase()`.
/// Keeping this a value type lets previews and the showcase render any state without a real session.
struct HUDViewState: Equatable {
    enum Phase: Equatable {
        case idle
        case listening
        case finalizing
        case inserting
        case finished(InsertionOutcome)
        case failed(String)
    }

    var phase: Phase = .idle
    var previewText: String = ""
    var levelHistory: [Float] = Array(repeating: 0, count: DictationController.levelHistoryLength)
    var level: Float = 0
    /// Caret rect in global (AppKit, bottom-left origin) screen coordinates, if known.
    var caretRect: CGRect?

    var isVisible: Bool { phase != .idle }

    /// Whether the waveform + live preview strip should be shown (as opposed to a status line).
    var showsWaveform: Bool {
        switch phase {
        case .listening, .finalizing: true
        default: false
        }
    }

    /// Short status line shown once a session has stopped listening.
    var statusText: String? {
        switch phase {
        case .inserting: "Inserting…"
        case .finished(.pasted), .finished(.accessibility): "Inserted"
        case .finished(.copiedToClipboard): "Copied — press ⌘V"
        case .finished(.failed): "Couldn't insert — copied instead"
        case .failed(let message): message
        case .idle, .listening, .finalizing: nil
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
    init(_ phase: DictationPhase) {
        switch phase {
        case .idle: self = .idle
        case .listening: self = .listening
        case .finalizing: self = .finalizing
        case .inserting: self = .inserting
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
    static let previewFinishedPasted = HUDViewState(phase: .finished(.pasted), previewText: previewListening.previewText)
    static let previewFinishedCopied = HUDViewState(phase: .finished(.copiedToClipboard), previewText: previewListening.previewText)
    static let previewFailed = HUDViewState(phase: .failed(ProsioError.network("timeout").hudMessage), previewText: "")
}
#endif
