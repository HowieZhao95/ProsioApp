import Foundation
import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import Testing

@Suite("Presentation ownership and privacy")
struct PresentationStateTests {
    @Test func endingSessionKeepsManualChangesAndPrivacyStop() {
        var state = PresentationState()
        state.manualPointer = true
        state.begin(pointer: true, keys: true)
        state.manualKeys = true // User enabled this independently during the session.
        state.privacyStop()
        state.end()
        #expect(state.pointerRequested && state.keysRequested)
        #expect(!state.pointerActive && !state.keysActive)
        state.begin(pointer: false, keys: false)
        #expect(!state.visualsAllowed) // Starting another session cannot bypass privacy stop.
        state.resume()
        #expect(state.pointerActive && state.keysActive)
    }
    @Test func pausedSessionDoesNotDiscardOwnership() {
        var state = PresentationState()
        state.begin(pointer: true, keys: false)
        state.begin(pointer: false, keys: true) // Duplicate begin is idempotent.
        state.pause()
        #expect(state.pointerRequested && !state.pointerActive && !state.keysRequested)
        state.resume()
        #expect(state.pointerActive)
        state.end()
        #expect(!state.pointerRequested && state.phase == .idle)
    }
    @Test func repeatAndUnrelatedReleaseDoNotCreateHistoryOrEndChord() {
        var chord = PresentationChord()
        chord.press(label: "⌘ S", keyCode: 1, at: 0)
        chord.press(label: "⌘ S", keyCode: 1, at: 1)
        chord.release(keyCode: 2, at: 2, linger: 1.2)
        chord.expire(at: 3)
        #expect(chord.isPressed && chord.label == "⌘ S")
        chord.release(keyCode: 1, at: 4, linger: 1.2)
        chord.expire(at: 5)
        #expect(!chord.isPressed && chord.label != nil)
        chord.expire(at: 5.2)
        #expect(chord.label == nil)
    }
    @Test func privacyClearAndLostReleaseLeaveNoStuckKeys() {
        var chord = PresentationChord()
        chord.press(label: "⌘ S", keyCode: 1, at: 0)
        chord.clear()
        chord.release(keyCode: 1, at: 1, linger: 1)
        #expect(chord.label == nil)
        chord.press(label: "⌘ S", keyCode: 1, at: 2)
        chord.expire(at: 32)
        #expect(chord.label == nil && !chord.isPressed)
    }
}

@Suite("Presentation power leases") @MainActor
struct PresentationPowerTests {
    private final class Power: PresentationPowerManaging {
        var acquired = 0
        var released: [[IOPMAssertionID]] = []
        var fail = false
        struct Failure: Error {}
        func acquire() throws -> [IOPMAssertionID] {
            acquired += 1
            if fail { throw Failure() }
            return [41, 42]
        }
        func release(_ ids: [IOPMAssertionID]) { if !ids.isEmpty { released.append(ids) } }
    }
    @Test func sessionEndCannotCancelEarlierManualLease() {
        let power = Power()
        var time: TimeInterval = 0
        let service = AwakeService(power: power, now: { time })
        service.start(.manual, duration: 7200)
        service.start(.session, duration: nil)
        service.stop(.session)
        #expect(service.isActive && service.leases[.manual] != nil)
        #expect(power.acquired == 1 && power.released.isEmpty)
        time = 7200
        service.tick()
        #expect(!service.isActive && power.released == [[41, 42]])
        service.stopAll()
        #expect(power.released.count == 1)
    }
    @Test func stoppingManualLeavesSessionAndDeadlineExtensionIsAdditive() {
        let power = Power()
        var time: TimeInterval = 0
        let service = AwakeService(power: power, now: { time })
        service.start(.manual, duration: 900)
        time = 600
        service.extendManual(by: 900)
        #expect(service.remaining(.manual) == 1200)
        service.start(.session, duration: nil)
        service.stop(.manual)
        #expect(service.isActive && power.released.isEmpty)
        service.stop(.session)
        #expect(!service.isActive && power.released.count == 1)
    }
    @Test func failedAndInvalidRequestsNeverClaimActive() {
        let power = Power()
        power.fail = true
        let service = AwakeService(power: power, now: { 0 })
        service.start(.manual, duration: .nan)
        #expect(power.acquired == 0 && !service.isActive)
        service.start(.manual, duration: 900)
        #expect(service.error != nil && service.leases.isEmpty && !service.isActive)
        power.fail = false
        service.start(.manual, duration: nil)
        #expect(service.isActive && service.error == nil)
        service.stopAll()
        #expect(!service.isActive && service.leases.isEmpty)
    }
    @Test func sleepingPastDeadlineExpiresWithoutWallClockDependency() {
        let power = Power()
        var continuousTime: TimeInterval = 100
        let service = AwakeService(power: power, now: { continuousTime })
        service.start(.manual, duration: 900)
        continuousTime = 2000 // Continuous clock advances across sleep.
        service.tick()
        #expect(!service.isActive && service.leases.isEmpty)
    }
    @Test func corruptPreferencesAreBoundedAndRuntimeIsNotRestored() {
        let suite = "presentation-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10000.0, forKey: "prosio.presentation.pointerSize")
        defaults.set("unknown", forKey: "prosio.presentation.pointerStyle")
        defaults.set(-1.0, forKey: "prosio.presentation.keyLinger")
        let preferences = PresentationPreferences(defaults: defaults)
        #expect(preferences.pointerSize == 100 && preferences.keyLinger == 0.5)
        #expect(preferences.pointerStyle == .ring)
        preferences.accent = .purple
        #expect(PresentationPreferences(defaults: defaults).accent == .purple)
        #expect(PresentationState().phase == .idle)
    }
}

@Suite("Presentation shortcut labels") @MainActor
struct PresentationShortcutLabelTests {
    @Test func allKeysModeDisplaysOrdinaryAndSpecialKeys() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        event.flags = []
        #expect(PresentationInputMonitor.shortcutLabel(event, mode: .allKeys) != nil)
        let arrow = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        arrow.flags = []
        #expect(PresentationInputMonitor.shortcutLabel(arrow, mode: .allKeys) == "←")
    }
    @Test func ordinaryTypingAndModifierOnlyEventsHaveNoLabel() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        event.flags = []
        #expect(PresentationInputMonitor.shortcutLabel(event) == nil)
        event.flags = [.maskShift]
        #expect(PresentationInputMonitor.shortcutLabel(event) == nil)
    }
    @Test func shortcutsDecodeLettersAndMergeModifiers() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        event.flags = [.maskCommand, .maskShift]
        let label = try #require(PresentationInputMonitor.shortcutLabel(event))
        #expect(label.hasPrefix("⇧ ⌘ "))
        #expect(label.count > 4)
    }
    @Test func specialKeysDoNotDependOnUnicodeTranslation() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        event.flags = [.maskCommand]
        #expect(PresentationInputMonitor.shortcutLabel(event) == "⌘ ←")
    }
}

@Suite("Presentation keycap rendering") @MainActor
struct PresentationKeycapRenderingTests {
    @Test func visiblePanelPaintsPixelsAndClearsWithoutTakingFocus() async throws {
        _ = NSApplication.shared
        let suite = "presentation-render-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let overlays = PresentationOverlays(preferences: PresentationPreferences(defaults: defaults))
        defer { overlays.clear() }
        var chord = PresentationChord()
        chord.press(label: "⌘ C", keyCode: 8, at: 0)
        overlays.showChord(chord)
        try await Task.sleep(for: .milliseconds(100))
        let panel = try #require(NSApplication.shared.windows.first { $0.identifier?.rawValue == "prosio.presentation.keycap" })
        #expect(panel.isVisible && !panel.canBecomeKey && panel.ignoresMouseEvents)
        let view = try #require(panel.contentView)
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var paintedPixels = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { paintedPixels += 1 }
            }
        }
        #expect(paintedPixels > 50)
        overlays.clearKeys()
        #expect(!overlays.keycapVisible)
    }
}
