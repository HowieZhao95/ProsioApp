import Foundation
import ProsioCore

/// Pure decision logic for the single toggle hotkey, kept free of CGEvent/AppKit plumbing so it
/// can be unit tested directly. Owned by mac-system agent.
///
/// Semantics: plain toggle, no hold-to-talk, no double-tap. Every decision is a pure function of
/// `DictationController.phase` read fresh at the moment of the key press — there is no persistent
/// state of our own, so there's nothing to desync. Ask/Translate are now spoken keyword prefixes
/// handled in core, not separate hotkeys — every press calls `controller.start(trigger:
/// .toggle, intent: nil)`.
/// - idle/finished/failed -> `.start`.
/// - `.answering` (an answer card is up) -> `.start` too: core treats a fresh press while
///   answering as a follow-up question and keeps the card up (no dismiss).
/// - `.listening` -> `.stop`.
/// - `.finalizing`/`.composing`/`.inserting` -> `.ignore` (no queue).
/// - Esc: `.listening` -> `.cancel`; `.answering` -> `.dismissAnswer`; otherwise `.none`.
enum HotkeyStateMachine {
    enum Effect: Equatable {
        case start
        case stop
        case cancel
        case dismissAnswer
        /// A key press that isn't currently actionable (previous session still finishing).
        /// Distinct from `.none` purely so the caller can log it distinctly for diagnostics.
        case ignore
        case none
    }

    /// The trigger key went down.
    static func triggerKeyDown(phase: DictationPhase) -> Effect {
        switch phase {
        case .idle, .finished, .failed, .answering:
            return .start
        case .listening:
            return .stop
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

    /// Whether the Esc-fallback Carbon hotkey (see `HotkeyMonitor`) needs to be registered for
    /// this phase — exactly the phases where `escKeyDown` can produce an effect. Kept as its own
    /// pure function so the register/unregister *decision* is unit-testable even though the
    /// actual Carbon hotkey plumbing isn't.
    static func needsEscMonitor(phase: DictationPhase) -> Bool {
        escKeyDown(phase: phase) != .none
    }
}

/// Tracks whether the trigger key is physically held down, purely from a stream of "the OS says
/// down"/"the OS says up" observations (`flagsChanged` events), so the caller can act only on a
/// genuine down transition and ignore auto-repeat/duplicate-down observations while the key is
/// already held (and ignore key-up entirely, per the toggle-only hotkey design).
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
