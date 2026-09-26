import Foundation
import ProsioCore

/// Pure decision logic for the two toggle hotkeys (Dictate, Ask), kept free of CGEvent/AppKit
/// plumbing so it can be unit tested directly. Owned by mac-system agent.
///
/// Semantics: plain toggle for each key, no hold-to-talk, no double-tap. Every decision is a pure
/// function of `DictationController.phase`/`.intent` read fresh at the moment of the key press —
/// there is no persistent state of our own, so there's nothing to desync.
/// - idle/finished/failed -> `.start(intent)` for whichever key was pressed.
/// - `.answering` (an answer card is up): Ask key -> `.start(.ask)` (a follow-up question in the
///   same thread); Dictate key -> `.dismissAnswerThenStart(.dictate)` (leave Ask mode, dictate).
/// - `.listening` with a press of the key that matches the *active* intent -> `.stop`. A press of
///   the *other* key while listening is `.ignore` (it doesn't belong to the running session).
/// - `.finalizing`/`.composing`/`.inserting` -> `.ignore` (no queue).
/// - Esc: `.listening` -> `.cancel`; `.answering` -> `.dismissAnswer`; otherwise `.none`.
enum HotkeyStateMachine {
    enum Effect: Equatable {
        case start(DictationIntent)
        case dismissAnswerThenStart(DictationIntent)
        case dismissAnswer
        case stop
        case cancel
        /// A key press that isn't currently actionable (previous session still finishing, or the
        /// wrong key for the session that's running). Distinct from `.none` purely so the caller
        /// can log it distinctly for diagnostics.
        case ignore
        case none
    }

    /// A trigger key (`intent` says which one: `.dictate` or `.ask`) went down.
    static func triggerKeyDown(intent: DictationIntent, phase: DictationPhase, activeIntent: DictationIntent?) -> Effect {
        switch phase {
        case .idle, .finished, .failed:
            return .start(intent)
        case .answering:
            return intent == .ask ? .start(intent) : .dismissAnswerThenStart(intent)
        case .listening:
            // The dictate key owns both `.dictate` and auto-resolved `.edit` sessions.
            if let activeIntent, (activeIntent == .ask) == (intent == .ask) {
                return .stop
            }
            return .ignore
        case .finalizing, .composing, .inserting:
            return .ignore
        }
    }

    /// Esc was pressed.
    static func escKeyDown(phase: DictationPhase) -> Effect {
        switch phase {
        case .listening: return .cancel
        case .answering: return .dismissAnswer
        case .idle, .finalizing, .composing, .inserting, .finished, .failed: return .none
        }
    }

    /// Whether the Esc-fallback `NSEvent` monitors (see `HotkeyMonitor`) need to be installed for
    /// this phase — exactly the phases where `escKeyDown` can produce an effect. Kept as its own
    /// pure function so the install/remove *decision* is unit-testable even though the actual
    /// `NSEvent` monitor plumbing isn't.
    static func needsEscMonitor(phase: DictationPhase) -> Bool {
        escKeyDown(phase: phase) != .none
    }
}

/// Tracks whether a trigger key is physically held down, purely from a stream of "the OS says
/// down"/"the OS says up" observations (`flagsChanged` events), so the caller can act only on a
/// genuine down transition and ignore auto-repeat/duplicate-down observations while the key is
/// already held (and ignore key-up entirely, per the toggle-only hotkey design). One instance per
/// physical key (Dictate and Ask each get their own).
struct TriggerPhysicalState: Equatable {
    private(set) var isDown = false

    /// - Returns: `true` if this observation repeats the already-tracked state (no real
    ///   transition happened — e.g. a duplicate/auto-repeat down, or a redundant up).
    @discardableResult
    mutating func observe(isDown newIsDown: Bool) -> Bool {
        let isRepeat = newIsDown == isDown
        isDown = newIsDown
        return isRepeat
    }

    mutating func reset() {
        isDown = false
    }
}
