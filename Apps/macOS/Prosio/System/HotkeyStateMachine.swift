import Foundation
import ProsioCore

/// Pure decision logic for the toggle hotkey, kept free of CGEvent/AppKit plumbing so it can be
/// unit tested directly. Owned by mac-system agent.
///
/// Semantics (product decision: plain toggle, no hold-to-talk, no double-tap):
/// - Press trigger once -> start. Press again -> stop (then the HUD shows a processing/waiting
///   state until insertion finishes — mac-ui's concern, not ours).
/// - Only the trigger key DOWN transition is acted on; key-up is ignored entirely, and so is any
///   duplicate/auto-repeat "down" observed while the physical key is already held (see
///   `TriggerPhysicalState`, which the caller uses to filter those out before calling in here).
/// - There is deliberately no persistent state of our own: every decision is a pure function of
///   `DictationController.phase` at the moment of the key press, read fresh each time. This means
///   there is nothing for the hotkey to desync *about* — if a rebuilt/reinstalled event tap or a
///   missed event ever caused confusion before, that entire class of bug is gone by construction.
enum HotkeyStateMachine {
    enum Effect: Equatable {
        case start
        /// Stop and finalize the current (listening) session.
        case stop
        /// Cancel the current (listening) session without inserting anything.
        case cancel
        /// The trigger was pressed while a previous session was still finalizing/inserting.
        /// Deliberately dropped (no queue) — logged by the caller so it's visible in diagnostics.
        case ignore
        case none
    }

    /// The trigger key went down (a genuine new physical press — the caller is responsible for
    /// filtering out key-up and repeat/duplicate-down events before calling this).
    static func triggerKeyDown(phase: DictationPhase) -> Effect {
        switch phase {
        case .idle, .finished, .failed:
            return .start
        case .listening:
            return .stop
        case .finalizing, .inserting:
            return .ignore
        }
    }

    /// Esc was pressed. Only cancels while actively listening — there's nothing sensible to do
    /// mid-finalize/insert, and nothing to do at all outside a session.
    static func escKeyDown(phase: DictationPhase) -> Effect {
        phase == .listening ? .cancel : .none
    }
}

/// Tracks whether the trigger key is physically held down, purely from a stream of "the OS says
/// down"/"the OS says up" observations (`flagsChanged` events), so the caller can act only on a
/// genuine down transition and ignore auto-repeat/duplicate-down observations while the key is
/// already held (and ignore key-up entirely, per the current toggle-only hotkey design).
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
