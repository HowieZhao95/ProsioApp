import Foundation
import ProsioCore
import Testing
// HotkeyStateMachine/TriggerPhysicalState are compiled directly into this target (see
// project.yml) — no `@testable import Prosio` needed (and this bundle has no host app at all).

@Suite("HotkeyStateMachine")
struct HotkeyStateMachineTests {
    // MARK: - triggerKeyDown: idle/finished/failed always start whichever key was pressed

    @Test("idle -> start(intent) for either key")
    func idleStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .idle, activeIntent: nil) == .start(.dictate))
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .idle, activeIntent: nil) == .start(.ask))
    }

    @Test("finished -> start(intent) (a fresh press after completion starts a new session)")
    func finishedStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .finished(.pasted), activeIntent: nil) == .start(.dictate))
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .finished(.pasted), activeIntent: nil) == .start(.ask))
    }

    @Test("failed -> start(intent) (a fresh press after a failure starts a new session)")
    func failedStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .failed(.cancelled), activeIntent: nil) == .start(.dictate))
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .failed(.cancelled), activeIntent: nil) == .start(.ask))
    }

    // MARK: - listening: only the key matching the active intent stops it

    @Test("listening + matching key -> stop")
    func listeningMatchingKeyStops() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .listening, activeIntent: .dictate) == .stop)
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .listening, activeIntent: .ask) == .stop)
    }

    @Test("listening + the other key -> ignore (doesn't belong to the running session)")
    func listeningOtherKeyIgnores() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .listening, activeIntent: .dictate) == .ignore)
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .listening, activeIntent: .ask) == .ignore)
    }

    @Test("listening with no active intent recorded -> ignore (defensive; shouldn't normally happen)")
    func listeningNoActiveIntentIgnores() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .listening, activeIntent: nil) == .ignore)
    }

    // MARK: - answering: Ask key = follow-up, Dictate key = dismiss then dictate

    @Test("answering + ask key -> start(.ask) (follow-up question, same thread)")
    func answeringAskKeyStartsFollowUp() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .answering, activeIntent: .ask) == .start(.ask))
    }

    @Test("answering + dictate key -> dismissAnswerThenStart(.dictate)")
    func answeringDictateKeyDismissesThenStarts() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .answering, activeIntent: .ask) == .dismissAnswerThenStart(.dictate))
    }

    // MARK: - No queue: finalizing/composing/inserting always ignore

    @Test("finalizing/composing/inserting -> ignore, for either key")
    func busyPhasesIgnoreBothKeys() {
        for phase: DictationPhase in [.finalizing, .composing, .inserting] {
            #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: phase, activeIntent: .dictate) == .ignore)
            #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: phase, activeIntent: .dictate) == .ignore)
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

    // MARK: - needsEscMonitor (gates HotkeyMonitor's NSEvent-based Esc fallback)

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

    @Test("Dictate and ask keys track independently (separate instances)")
    func independentTrackers() {
        var dictateState = TriggerPhysicalState()
        var askState = TriggerPhysicalState()

        _ = dictateState.observe(isDown: true)

        // The ask key's own tracker is unaffected by the dictate key's state.
        #expect(askState.observe(isDown: true) == false)
        #expect(dictateState.isDown == true)
        #expect(askState.isDown == true)
    }
}

@Suite("Edit sessions")
struct HotkeyStateMachineEditTests {
    @Test("dictate key stops an auto-resolved edit session")
    func dictateKeyStopsEdit() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .dictate, phase: .listening, activeIntent: .edit) == .stop)
    }

    @Test("ask key does not stop an edit session")
    func askKeyIgnoresEdit() {
        #expect(HotkeyStateMachine.triggerKeyDown(intent: .ask, phase: .listening, activeIntent: .edit) == .ignore)
    }
}
