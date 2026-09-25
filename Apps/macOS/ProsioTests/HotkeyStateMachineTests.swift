import Testing
@testable import Prosio

@Suite("HotkeyStateMachine")
struct HotkeyStateMachineTests {
    @Test("Trigger key down requests start immediately")
    func startsOnKeyDown() {
        var sm = HotkeyStateMachine()
        #expect(sm.state == .idle)

        let effect = sm.triggerKeyDown(at: 0, isBusy: false)

        #expect(effect == .start)
        #expect(sm.state == .holding)
    }

    @Test("Holding past the threshold stops on release (push-to-talk)")
    func holdStopsOnRelease() {
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)

        let effect = sm.triggerKeyUp(at: 0.5, holdThreshold: 0.3)

        #expect(effect == .stop)
        #expect(sm.state == .idle)
    }

    @Test("A quick tap arms toggle mode; the next trigger press stops it while still busy")
    func tapArmsToggleThenStops() {
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)

        let releaseEffect = sm.triggerKeyUp(at: 0.1, holdThreshold: 0.3)
        #expect(releaseEffect == .none)
        #expect(sm.state == .toggleActive)

        // The dictation is still running (isBusy: true) when the second press arrives.
        let secondPressEffect = sm.triggerKeyDown(at: 5, isBusy: true)
        #expect(secondPressEffect == .stop)
        #expect(sm.state == .idle)
    }

    @Test("A trigger press while toggle-armed but no longer busy starts fresh instead of a no-op stop")
    func togglePressAfterDesyncStartsFresh() {
        // Simulates the dictation ending on its own (engine failure, or finished) while the
        // state machine was still armed in `.toggleActive` — the next trigger press must not
        // require a second press to recover.
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)
        _ = sm.triggerKeyUp(at: 0.1, holdThreshold: 0.3)
        #expect(sm.state == .toggleActive)

        let effect = sm.triggerKeyDown(at: 5, isBusy: false)

        #expect(effect == .start)
        #expect(sm.state == .holding)
    }

    @Test("Another key while holding cancels (it was a shortcut, not dictation)")
    func otherKeyWhileHoldingCancels() {
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)

        let effect = sm.otherKeyDown()

        #expect(effect == .cancel)
        #expect(sm.state == .idle)
    }

    @Test("Another key while idle or toggling is a no-op")
    func otherKeyIgnoredOutsideHolding() {
        var sm = HotkeyStateMachine()
        #expect(sm.otherKeyDown() == .none)

        _ = sm.triggerKeyDown(at: 0, isBusy: false)
        _ = sm.triggerKeyUp(at: 0.1, holdThreshold: 0.3)
        #expect(sm.state == .toggleActive)
        #expect(sm.otherKeyDown() == .none)
        #expect(sm.state == .toggleActive)
    }

    @Test("Esc cancels only when the caller reports it is busy")
    func escCancelsOnlyWhenBusy() {
        var sm = HotkeyStateMachine()
        #expect(sm.escKeyDown(isBusy: false) == .none)

        _ = sm.triggerKeyDown(at: 0, isBusy: false)
        let effect = sm.escKeyDown(isBusy: true)

        #expect(effect == .cancel)
        #expect(sm.state == .idle)
    }

    @Test("Esc cancels a toggle-armed dictation too")
    func escCancelsToggleActive() {
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)
        _ = sm.triggerKeyUp(at: 0.1, holdThreshold: 0.3)
        #expect(sm.state == .toggleActive)

        let effect = sm.escKeyDown(isBusy: true)

        #expect(effect == .cancel)
        #expect(sm.state == .idle)
    }

    @Test("A duplicate/auto-repeat key-down while already holding is ignored")
    func repeatedKeyDownWhileHoldingIsIgnored() {
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)

        let effect = sm.triggerKeyDown(at: 0.05, isBusy: true)

        #expect(effect == .none)
        #expect(sm.state == .holding)
    }

    @Test("Reset returns to idle from any state")
    func resetReturnsToIdle() {
        var sm = HotkeyStateMachine()
        _ = sm.triggerKeyDown(at: 0, isBusy: false)
        sm.reset()
        #expect(sm.state == .idle)
    }
}
