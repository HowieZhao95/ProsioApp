import Foundation

/// Session ownership is additive: ending a session never restores a stale snapshot over
/// manual changes made during it. Runtime state is deliberately not persisted.
nonisolated struct PresentationState {
    enum Phase: Equatable { case idle, running, paused }
    private(set) var phase: Phase = .idle
    private(set) var privacyStopped = false
    var manualPointer = false
    var manualKeys = false
    private var sessionPointer = false
    private var sessionKeys = false

    var sessionOwnsPointer: Bool { sessionPointer }
    var sessionOwnsKeys: Bool { sessionKeys }
    var pointerRequested: Bool { manualPointer || sessionPointer }
    var keysRequested: Bool { manualKeys || sessionKeys }
    var visualsAllowed: Bool { !privacyStopped && phase != .paused }
    var pointerActive: Bool { pointerRequested && visualsAllowed }
    var keysActive: Bool { keysRequested && visualsAllowed }

    mutating func begin(pointer: Bool, keys: Bool) {
        guard phase == .idle else { return }
        sessionPointer = pointer
        sessionKeys = keys
        phase = .running
        // Privacy stop is sticky until the user explicitly resumes.
    }
    mutating func pause() { if phase == .running { phase = .paused } }
    mutating func resume() {
        privacyStopped = false
        if phase == .paused { phase = .running }
    }
    mutating func privacyStop() { privacyStopped = true }
    mutating func end() {
        phase = .idle
        sessionPointer = false
        sessionKeys = false
    }
}

/// One current chord, bounded memory, no event history or transcript. Releases start the
/// linger interval; repeated key-down events update the same chord rather than appending.
nonisolated struct PresentationChord {
    private(set) var label: String?
    private(set) var keyCode: Int64?
    private(set) var isPressed = false
    private var expiresAt: TimeInterval?
    private var lastEventAt: TimeInterval = 0

    mutating func press(label: String, keyCode: Int64, at now: TimeInterval) {
        self.label = label
        self.keyCode = keyCode
        isPressed = true
        expiresAt = nil
        lastEventAt = now
    }
    mutating func release(keyCode: Int64, at now: TimeInterval, linger: TimeInterval) {
        guard self.keyCode == keyCode, isPressed else { return }
        isPressed = false
        expiresAt = now + linger
        lastEventAt = now
    }
    mutating func expire(at now: TimeInterval) {
        // A lost key-up may not leave a stuck keycap indefinitely.
        if let expiresAt, now >= expiresAt { clear() }
        else if isPressed && now - lastEventAt >= 30 { clear() }
    }
    mutating func clear() { self = PresentationChord() }
}
