import Foundation
import ProsioCore
import Testing
// HotkeyStateMachine/TriggerPhysicalState are compiled directly into this target (see
// project.yml) — no `@testable import Prosio` needed (and this bundle has no host app at all).

@Suite("HotkeyStateMachine")
struct HotkeyStateMachineTests {
    // MARK: - triggerKeyDown: purely a function of DictationController.phase

    @Test("idle -> start")
    func idleStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .idle) == .start)
    }

    @Test("listening -> stop")
    func listeningStops() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .listening) == .stop)
    }

    @Test("finalizing -> ignore (no queue)")
    func finalizingIgnores() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .finalizing) == .ignore)
    }

    @Test("inserting -> ignore (no queue)")
    func insertingIgnores() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .inserting) == .ignore)
    }

    @Test("finished -> start (a fresh press after completion starts a new session)")
    func finishedStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .finished(.pasted)) == .start)
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .finished(.copiedToClipboard)) == .start)
    }

    @Test("failed -> start (a fresh press after a failure starts a new session)")
    func failedStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .failed(.cancelled)) == .start)
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .failed(.emptyTranscript)) == .start)
    }

    // MARK: - escKeyDown: only cancels while actively listening

    @Test("esc while listening -> cancel")
    func escWhileListeningCancels() {
        #expect(HotkeyStateMachine.escKeyDown(phase: .listening) == .cancel)
    }

    @Test("esc outside listening is a no-op")
    func escOutsideListeningIsNoOp() {
        #expect(HotkeyStateMachine.escKeyDown(phase: .idle) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .finalizing) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .inserting) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .finished(.pasted)) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .failed(.cancelled)) == .none)
    }
}

@Suite("TriggerPhysicalState")
struct TriggerPhysicalStateTests {
    @Test("First observed down is not a repeat")
    func firstDownIsNotRepeat() {
        var tracker = TriggerPhysicalState()
        let isRepeat = tracker.observe(isDown: true)
        #expect(isRepeat == false)
        #expect(tracker.isDown == true)
    }

    @Test("A normal down-then-up sequence is never a repeat")
    func normalSequenceNeverRepeats() {
        var tracker = TriggerPhysicalState()
        #expect(tracker.observe(isDown: true) == false)
        #expect(tracker.observe(isDown: false) == false)
        #expect(tracker.observe(isDown: true) == false)
        #expect(tracker.observe(isDown: false) == false)
    }

    @Test("Two consecutive 'down' observations report a repeat (auto-repeat/duplicate, or a missed key-up)")
    func consecutiveDownsAreRepeat() {
        var tracker = TriggerPhysicalState()
        _ = tracker.observe(isDown: true)

        let isRepeat = tracker.observe(isDown: true)

        #expect(isRepeat == true)
        #expect(tracker.isDown == true)
    }

    @Test("Two consecutive 'up' observations report a repeat")
    func consecutiveUpsAreRepeat() {
        var tracker = TriggerPhysicalState()
        // Starts at isDown == false, so an initial "up" observation already collides.
        let isRepeat = tracker.observe(isDown: false)

        #expect(isRepeat == true)
        #expect(tracker.isDown == false)
    }

    @Test("Reset returns to the not-down baseline")
    func resetReturnsToNotDown() {
        var tracker = TriggerPhysicalState()
        _ = tracker.observe(isDown: true)
        tracker.reset()
        #expect(tracker.isDown == false)
        // A subsequent "down" is treated as fresh, not a repeat.
        #expect(tracker.observe(isDown: true) == false)
    }
}
