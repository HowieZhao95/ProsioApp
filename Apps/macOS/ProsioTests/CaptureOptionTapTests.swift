import Foundation
import Testing

@Suite("Either Option capture tap")
struct CaptureOptionTapTests {
    private func expectStep(
        _ state: inout CaptureOptionTapState,
        event: CaptureOptionTapState.Event,
        at timestamp: TimeInterval,
        eligible: Bool,
        fires expected: Bool
    ) {
        let actual = state.observe(event: event, at: timestamp, eligible: eligible)
        #expect(actual == expected)
    }

    private func expectOptionFlag(
        _ state: inout CaptureOptionTapState,
        keycode: Int64,
        flagsRaw: UInt64,
        at timestamp: TimeInterval,
        fires expected: Bool
    ) {
        let event = HotkeyRouting.optionFlagEvent(keycode: keycode, flagsRaw: flagsRaw)
        let eligible = !HotkeyRouting.oppositeOptionIsDown(keycode: keycode, flagsRaw: flagsRaw)
        expectStep(&state, event: event, at: timestamp, eligible: eligible, fires: expected)
    }
    @Test("Only a short release after a right Option press fires once")
    func releaseOnly() {
        var state = CaptureOptionTapState()
        expectStep(&state, event: .rightOptionUp, at: 1, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 2, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 2.18, eligible: true, fires: true)
        expectStep(&state, event: .rightOptionUp, at: 2.19, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 3, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 3.12, eligible: true, fires: true)
    }

    @Test("Left Option independently fires only on a short release")
    func leftReleaseOnly() {
        var state = CaptureOptionTapState()
        let left = HotkeyRouting.leftOptionDeviceFlag
        expectOptionFlag(&state, keycode: 58, flagsRaw: 0, at: 1, fires: false)
        expectOptionFlag(&state, keycode: 58, flagsRaw: left, at: 2, fires: false)
        expectOptionFlag(&state, keycode: 58, flagsRaw: 0, at: 2.12, fires: true)
        expectOptionFlag(&state, keycode: 58, flagsRaw: 0, at: 2.13, fires: false)
        expectOptionFlag(&state, keycode: 58, flagsRaw: left, at: 3, fires: false)
        expectOptionFlag(&state, keycode: 58, flagsRaw: 0, at: 3.5, fires: false)
    }

    @Test("Long holds and reversed timestamps cannot be mistaken for a tap")
    func durationBoundary() {
        var state = CaptureOptionTapState()
        expectStep(&state, event: .rightOptionDown, at: 10, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 10.46, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 11, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 10.99, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 12, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 12.40, eligible: true, fires: true)
    }

    @Test("A repeated down does not restart the allowed time window")
    func duplicateDownDoesNotExtendTap() {
        var state = CaptureOptionTapState()
        expectStep(&state, event: .rightOptionDown, at: 0, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 0.30, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 0.50, eligible: true, fires: false)
    }

    @Test("A repeated down while capture becomes busy revokes this press")
    func duplicateDownRevokesEligibility() {
        var state = CaptureOptionTapState()
        expectStep(&state, event: .rightOptionDown, at: 1, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 1.05, eligible: false, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 1.10, eligible: true, fires: false)
    }

    @Test("Each Option keycode uses its own device bit")
    func rightVersusLeftOption() {
        let rightBit = HotkeyRouting.rightOptionDeviceFlag
        let leftBit = HotkeyRouting.leftOptionDeviceFlag
        #expect(HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: rightBit) == .rightOptionDown)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: rightBit | leftBit) == .rightOptionDown)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: 0) == .rightOptionUp)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: leftBit) == .rightOptionUp)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 58, flagsRaw: leftBit) == .leftOptionDown)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 58, flagsRaw: rightBit | leftBit) == .leftOptionDown)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 58, flagsRaw: 0) == .leftOptionUp)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 58, flagsRaw: rightBit) == .leftOptionUp)
        #expect(HotkeyRouting.optionFlagEvent(keycode: 63, flagsRaw: rightBit) == .interruption)
    }

    @Test("Right Option release with no left device bit remains eligible")
    func rightReleaseIgnoresStaleLeftKeyPolling() {
        var state = CaptureOptionTapState()
        let downFlags = HotkeyRouting.rightOptionDeviceFlag
        let upFlags: UInt64 = 0 // The observed release had no left Option device bit.
        #expect(!HotkeyRouting.leftOptionIsDown(flagsRaw: downFlags))
        #expect(!HotkeyRouting.leftOptionIsDown(flagsRaw: upFlags))
        expectStep(&state, event: HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: downFlags),
                   at: 1, eligible: !HotkeyRouting.leftOptionIsDown(flagsRaw: downFlags), fires: false)
        expectStep(&state, event: HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: upFlags),
                   at: 1.115, eligible: !HotkeyRouting.leftOptionIsDown(flagsRaw: upFlags), fires: true)
    }

    @Test("A real left Option bit on right release blocks capture")
    func genuineLeftBitOnRelease() {
        var state = CaptureOptionTapState()
        let upFlags = HotkeyRouting.leftOptionDeviceFlag
        #expect(HotkeyRouting.leftOptionIsDown(flagsRaw: upFlags))
        #expect(HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: upFlags) == .rightOptionUp)
        #expect(HotkeyRouting.oppositeOptionIsDown(keycode: 61, flagsRaw: upFlags))
        expectStep(&state, event: .rightOptionDown, at: 2, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 2.115,
                   eligible: !HotkeyRouting.oppositeOptionIsDown(keycode: 61, flagsRaw: upFlags), fires: false)
    }

    @Test("A real right Option bit on left release blocks capture")
    func genuineRightBitOnLeftRelease() {
        var state = CaptureOptionTapState()
        let right = HotkeyRouting.rightOptionDeviceFlag
        #expect(HotkeyRouting.optionFlagEvent(keycode: 58, flagsRaw: right) == .leftOptionUp)
        #expect(HotkeyRouting.oppositeOptionIsDown(keycode: 58, flagsRaw: right))
        expectStep(&state, event: .leftOptionDown, at: 2, eligible: true, fires: false)
        expectOptionFlag(&state, keycode: 58, flagsRaw: right, at: 2.115, fires: false)
    }

    @Test("Crossing Option presses cancel in both directions until a fresh press")
    func crossingOptionsNeedFreshPress() {
        let left = HotkeyRouting.leftOptionDeviceFlag
        let right = HotkeyRouting.rightOptionDeviceFlag
        var leftFirst = CaptureOptionTapState()
        expectOptionFlag(&leftFirst, keycode: 58, flagsRaw: left, at: 1, fires: false)
        expectOptionFlag(&leftFirst, keycode: 61, flagsRaw: left | right, at: 1.04, fires: false)
        expectOptionFlag(&leftFirst, keycode: 61, flagsRaw: left, at: 1.08, fires: false)
        expectOptionFlag(&leftFirst, keycode: 58, flagsRaw: 0, at: 1.12, fires: false)
        expectOptionFlag(&leftFirst, keycode: 58, flagsRaw: left, at: 2, fires: false)
        expectOptionFlag(&leftFirst, keycode: 58, flagsRaw: 0, at: 2.11, fires: true)

        var rightFirst = CaptureOptionTapState()
        expectOptionFlag(&rightFirst, keycode: 61, flagsRaw: right, at: 3, fires: false)
        expectOptionFlag(&rightFirst, keycode: 58, flagsRaw: left | right, at: 3.04, fires: false)
        expectOptionFlag(&rightFirst, keycode: 58, flagsRaw: right, at: 3.08, fires: false)
        expectOptionFlag(&rightFirst, keycode: 61, flagsRaw: 0, at: 3.12, fires: false)
        expectOptionFlag(&rightFirst, keycode: 61, flagsRaw: right, at: 4, fires: false)
        expectOptionFlag(&rightFirst, keycode: 61, flagsRaw: 0, at: 4.11, fires: true)
    }

    @Test("Both Option bits present at the first observation cannot start a tap")
    func simultaneousOptionsNeverStart() {
        let left = HotkeyRouting.leftOptionDeviceFlag
        let right = HotkeyRouting.rightOptionDeviceFlag
        var state = CaptureOptionTapState()
        expectOptionFlag(&state, keycode: 58, flagsRaw: left | right, at: 1, fires: false)
        expectOptionFlag(&state, keycode: 61, flagsRaw: left | right, at: 1.01, fires: false)
        expectOptionFlag(&state, keycode: 58, flagsRaw: right, at: 1.1, fires: false)
        expectOptionFlag(&state, keycode: 61, flagsRaw: 0, at: 1.11, fires: false)
        expectOptionFlag(&state, keycode: 61, flagsRaw: right, at: 2, fires: false)
        expectOptionFlag(&state, keycode: 61, flagsRaw: 0, at: 2.1, fires: true)
    }

    @Test("Left Option pressed during right Option cancels even if released before right")
    func interveningLeftOptionEvent() {
        var state = CaptureOptionTapState()
        let rightDown = HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: HotkeyRouting.rightOptionDeviceFlag)
        let leftDown = HotkeyRouting.optionFlagEvent(
            keycode: 58, flagsRaw: HotkeyRouting.rightOptionDeviceFlag | HotkeyRouting.leftOptionDeviceFlag)
        let rightUp = HotkeyRouting.optionFlagEvent(keycode: 61, flagsRaw: 0)
        expectStep(&state, event: rightDown, at: 3, eligible: true, fires: false)
        expectStep(&state, event: leftDown, at: 3.04, eligible: false, fires: false)
        #expect(!HotkeyRouting.leftOptionIsDown(flagsRaw: 0))
        expectStep(&state, event: rightUp, at: 3.115, eligible: true, fires: false)
    }

    @Test("An interruption or reset cancels the current press and allows a later one")
    func interruptionsRequireFreshPress() {
        var state = CaptureOptionTapState()
        expectStep(&state, event: .rightOptionDown, at: 1, eligible: true, fires: false)
        expectStep(&state, event: .interruption, at: 1.05, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 1.15, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 2, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 2.1, eligible: true, fires: true)
        var cancelled = CaptureOptionTapState()
        expectStep(&cancelled, event: .rightOptionDown, at: 4, eligible: true, fires: false)
        cancelled.reset()
        expectStep(&cancelled, event: .rightOptionUp, at: 4.1, eligible: true, fires: false)
    }

    @Test("Permission, voice conflict, and capture busy gating must hold at both edges")
    func eligibilityAtBothEdges() {
        var state = CaptureOptionTapState()
        expectStep(&state, event: .rightOptionDown, at: 0, eligible: false, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 0.1, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 1, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 1.1, eligible: false, fires: false)
        expectStep(&state, event: .rightOptionDown, at: 2, eligible: true, fires: false)
        expectStep(&state, event: .rightOptionUp, at: 2.1, eligible: true, fires: true)
    }

    @Test("Right Option is unavailable during voice conflict or missing tap permissions")
    func availability() {
        let available = HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: false, accessibilityGranted: true,
            inputMonitoringGranted: true, tapHealthy: true
        )
        #expect(available == .ready)
        #expect(HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: true, accessibilityGranted: true,
            inputMonitoringGranted: true, tapHealthy: true
        ) == .voiceKeyConflict)
        #expect(HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: false, accessibilityGranted: false,
            inputMonitoringGranted: true, tapHealthy: true
        ) == .needsAccessibility)
        #expect(HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: false, accessibilityGranted: true,
            inputMonitoringGranted: false, tapHealthy: true
        ) == .needsInputMonitoring)
        #expect(HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: false, accessibilityGranted: true,
            inputMonitoringGranted: true, tapHealthy: false
        ) == .tapUnavailable)
    }

    @Test("An absent shortcut gets right Option, but prior choices stay intact")
    func shortcutPreferenceMigration() {
        #expect(HotkeyRouting.defaultCaptureShortcutRawValue(stored: nil) == 3)
        for raw in 0...3 {
            #expect(HotkeyRouting.defaultCaptureShortcutRawValue(stored: raw) == raw)
        }
        #expect(HotkeyRouting.defaultCaptureShortcutRawValue(stored: -1) == 3)
        #expect(HotkeyRouting.defaultCaptureShortcutRawValue(stored: 99) == 3)
    }
}
