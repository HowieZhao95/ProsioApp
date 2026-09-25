import Foundation

/// Pure decision logic for the push-to-talk / toggle hotkey, kept free of CGEvent/AppKit
/// plumbing so it can be unit tested directly. Owned by mac-system agent.
///
/// Semantics:
/// - Trigger key down (idle -> holding) requests `.start` immediately, so the first syllable
///   is never lost.
/// - Trigger key up while holding: if held >= `holdThreshold`, request `.stop` (push-to-talk).
///   Otherwise it was a tap: arm `.toggleActive` and keep listening; the *next* trigger key
///   down requests `.stop` — unless the dictation already ended on its own (engine failure,
///   or finished) while armed, in which case `isBusy` will be false and it requests `.start`
///   instead, so the user never has to press twice to recover from a desynced toggle.
/// - Any other key pressed while holding (e.g. fn+arrow) requests `.cancel` (it was a shortcut,
///   not dictation).
/// - Esc while the caller reports it is busy requests `.cancel`, regardless of internal state.
struct HotkeyStateMachine: Equatable {
    enum State: Equatable {
        case idle
        case holding
        case toggleActive
    }

    enum Effect: Equatable {
        case start
        case stop
        case cancel
        case none
    }

    private(set) var state: State = .idle
    private var pressStartTime: TimeInterval?

    init() {}

    /// The trigger key was pressed (with no other relevant modifiers/keys held). `isBusy` should
    /// reflect `DictationController.isBusy` at the moment of the press: it's the source of truth
    /// for whether a `.toggleActive` dictation is actually still running, since it can end on its
    /// own (engine failure, or finished) without going through `triggerKeyDown`/`triggerKeyUp`.
    mutating func triggerKeyDown(at time: TimeInterval, isBusy: Bool) -> Effect {
        switch state {
        case .idle:
            state = .holding
            pressStartTime = time
            return .start
        case .toggleActive where isBusy:
            // Second tap while a toggle-mode dictation is still running: stop it.
            state = .idle
            pressStartTime = nil
            return .stop
        case .toggleActive:
            // The armed dictation already ended on its own (e.g. the engine failed); this press
            // is really a fresh start, not a stop. Without this, the state machine would issue a
            // no-op `.stop` and the user would have to press the trigger twice to recover.
            state = .holding
            pressStartTime = time
            return .start
        case .holding:
            // Auto-repeat or a spurious duplicate down event; ignore.
            return .none
        }
    }

    /// The trigger key was released.
    mutating func triggerKeyUp(at time: TimeInterval, holdThreshold: TimeInterval) -> Effect {
        guard state == .holding else { return .none }
        let held = time - (pressStartTime ?? time)
        pressStartTime = nil
        if held >= holdThreshold {
            state = .idle
            return .stop
        } else {
            state = .toggleActive
            return .none
        }
    }

    /// Any other key (or modifier) went down. Only meaningful while the trigger is physically held.
    mutating func otherKeyDown() -> Effect {
        guard state == .holding else { return .none }
        state = .idle
        pressStartTime = nil
        return .cancel
    }

    /// Esc was pressed. `isBusy` reflects `DictationController.isBusy`, which is the source of
    /// truth for whether there is anything to cancel.
    mutating func escKeyDown(isBusy: Bool) -> Effect {
        guard isBusy else { return .none }
        state = .idle
        pressStartTime = nil
        return .cancel
    }

    /// Forces back to idle, e.g. after the event tap is recreated.
    mutating func reset() {
        state = .idle
        pressStartTime = nil
    }
}
