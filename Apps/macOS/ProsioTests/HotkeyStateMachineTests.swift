import Foundation
import ProsioCore
import Testing
// HotkeyStateMachine/TriggerPhysicalState are compiled directly into this target (see
// project.yml) — no `@testable import Prosio` needed (and this bundle has no host app at all).

@Suite("HotkeyStateMachine")
struct HotkeyStateMachineTests {
    // MARK: - triggerKeyDown

    @Test("idle -> start")
    func idleStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .idle) == .start)
    }

    @Test("finished -> start (a fresh press after completion starts a new session)")
    func finishedStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .finished(.pasted)) == .start)
    }

    @Test("failed -> start (a fresh press after a failure starts a new session)")
    func failedStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .failed(.cancelled)) == .start)
    }

    @Test("listening -> stop")
    func listeningStops() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .listening) == .stop)
    }

    @Test("answering -> start (a follow-up question; core keeps the card up, no dismiss)")
    func answeringStartsFollowUp() {
        #expect(HotkeyStateMachine.triggerKeyDown(phase: .answering) == .start)
    }

    @Test("finalizing/composing/inserting -> ignore (no queue)")
    func busyPhasesIgnore() {
        for phase: DictationPhase in [.finalizing, .composing, .inserting] {
            #expect(HotkeyStateMachine.triggerKeyDown(phase: phase) == .ignore)
        }
    }

    // MARK: - escKeyDown

    @Test("esc while listening -> cancel")
    func escWhileListeningCancels() {
        #expect(HotkeyStateMachine.escKeyDown(phase: .listening) == .cancel)
    }

    @Test("esc while answering -> dismissAnswer")
    func escWhileAnsweringDismisses() {
        #expect(HotkeyStateMachine.escKeyDown(phase: .answering) == .dismissAnswer)
    }

    @Test("esc elsewhere is a no-op")
    func escElsewhereIsNoOp() {
        #expect(HotkeyStateMachine.escKeyDown(phase: .idle) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .finalizing) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .composing) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .inserting) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .finished(.pasted)) == .none)
        #expect(HotkeyStateMachine.escKeyDown(phase: .failed(.cancelled)) == .none)
    }

    // MARK: - needsEscMonitor (gates HotkeyMonitor's Carbon-hotkey-based Esc fallback)

    @Test("needsEscMonitor is true exactly where escKeyDown produces an effect")
    func needsEscMonitorMatchesEscKeyDown() {
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .listening) == true)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .answering) == true)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .idle) == false)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .finalizing) == false)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .composing) == false)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .inserting) == false)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .finished(.pasted)) == false)
        #expect(HotkeyStateMachine.needsEscMonitor(phase: .failed(.cancelled)) == false)
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
