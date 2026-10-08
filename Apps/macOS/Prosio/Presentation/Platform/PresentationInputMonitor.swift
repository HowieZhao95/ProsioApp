import AppKit
import Carbon

/// A passive tap on the main run loop. It neither consumes nor synthesizes input and never
/// buffers raw events. The coordinator validates privacy before any label is decoded.
@MainActor final class PresentationInputMonitor {
    var onEvent: (CGEventType, CGEvent) -> Void = { _, _ in }
    var onInterruption: () -> Void = {}
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isHealthy: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var permissionGranted: Bool { CGPreflightListenEventAccess() }
    var secureInput: Bool { IsSecureEventInputEnabled() }

    func start() -> Bool {
        if isHealthy { return true }
        stop()
        guard permissionGranted else { return false }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<PresentationInputMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.onInterruption()
                } else { monitor.onEvent(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return isHealthy
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    static func shortcutLabel(_ event: CGEvent, mode: PresentationPreferences.KeyDisplayMode = .shortcuts) -> String? {
        let flags = event.flags
        guard mode == .allKeys || !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return nil }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let specials: [Int64: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 71: "Clear", 76: "⌤", 115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let key = specials[code] ?? NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased()
        guard let key, !key.isEmpty, key.count <= 12,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let prefix = [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .compactMap { flags.contains($0.0) ? $0.1 : nil }.joined(separator: " ")
        return prefix.isEmpty ? key : prefix + " " + key
    }
}
