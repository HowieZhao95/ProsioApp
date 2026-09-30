import Foundation

nonisolated enum HotkeyRouting {
    static let voiceEscapeSignature: UInt32 = 0x50727345
    static let captureSignature: UInt32 = 0x50724370
    static func isVoiceEscape(signature: UInt32, id: UInt32) -> Bool { signature == voiceEscapeSignature && id == 1 }
    static func isCapture(signature: UInt32, id: UInt32) -> Bool { signature == captureSignature && id == 1 }
    static func canApplyVoiceEffect(isStarted: Bool, isCaptureSuspended: Bool) -> Bool { isStarted && !isCaptureSuspended }

    enum OptionCaptureAvailability: Equatable {
        case ready, voiceKeyConflict, needsAccessibility, needsInputMonitoring, tapUnavailable
    }

    static func optionCaptureAvailability(
        voiceUsesRightOption: Bool,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        tapHealthy: Bool
    ) -> OptionCaptureAvailability {
        if voiceUsesRightOption { return .voiceKeyConflict }
        if !accessibilityGranted { return .needsAccessibility }
        // Without this grant, macOS may deliver flagsChanged but silently omit keyDown.
        // We cannot prove Option was used alone, so never enable the single-key shortcut.
        if !inputMonitoringGranted { return .needsInputMonitoring }
        if !tapHealthy { return .tapUnavailable }
        return .ready
    }

    // Existing users with a saved 0/1/2 choice keep it exactly; only an absent preference
    // receives the new default. Unknown values fall back to the new default too.
    static func defaultCaptureShortcutRawValue(stored: Int?) -> Int {
        guard let stored, (0...3).contains(stored) else { return 3 }
        return stored
    }

    // Device-specific Option bits in the macOS SDK. The aggregate Alternate flag
    // stays set when the opposite Option is held and cannot identify either release.
    static let rightOptionDeviceFlag: UInt64 = 0x40
    static let leftOptionDeviceFlag: UInt64 = 0x20
    static func leftOptionIsDown(flagsRaw: UInt64) -> Bool {
        flagsRaw & leftOptionDeviceFlag != 0
    }
    static func optionFlagEvent(keycode: Int64, flagsRaw: UInt64) -> CaptureOptionTapState.Event {
        switch keycode {
        case 58: return leftOptionIsDown(flagsRaw: flagsRaw) ? .leftOptionDown : .leftOptionUp
        case 61: return flagsRaw & rightOptionDeviceFlag == 0 ? .rightOptionUp : .rightOptionDown
        default: return .interruption
        }
    }
    static func oppositeOptionIsDown(keycode: Int64, flagsRaw: UInt64) -> Bool {
        switch keycode {
        case 58: flagsRaw & rightOptionDeviceFlag != 0
        case 61: leftOptionIsDown(flagsRaw: flagsRaw)
        default: false
        }
    }
}

nonisolated struct CaptureOptionTapState {
    enum Event: Equatable { case leftOptionDown, leftOptionUp, rightOptionDown, rightOptionUp, interruption }
    private enum Side { case left, right }
    static let maximumDuration: TimeInterval = 0.45
    private var downAt: TimeInterval?
    private var downSide: Side?
    private var eligibleAtDown = false
    var isPending: Bool { downAt != nil }
    func elapsed(at timestamp: TimeInterval) -> TimeInterval? {
        downAt.map { timestamp - $0 }
    }

    mutating func observe(event: Event, at timestamp: TimeInterval, eligible: Bool) -> Bool {
        switch event {
        case .leftOptionDown, .rightOptionDown:
            let side: Side = event == .leftOptionDown ? .left : .right
            // A duplicate down is not a fresh gesture and cannot extend the tap window.
            if downAt == nil {
                downAt = timestamp
                downSide = side
                eligibleAtDown = eligible
            } else if downSide != side || !eligible {
                eligibleAtDown = false
            }
            return false
        case .interruption:
            eligibleAtDown = false
            return false
        case .leftOptionUp, .rightOptionUp:
            let side: Side = event == .leftOptionUp ? .left : .right
            guard downSide == side else {
                eligibleAtDown = false
                return false
            }
            defer { reset() }
            guard let downAt, eligibleAtDown, eligible else { return false }
            let duration = timestamp - downAt
            return duration >= 0 && duration <= Self.maximumDuration
        }
    }

    mutating func reset() {
        downAt = nil
        downSide = nil
        eligibleAtDown = false
    }
}
