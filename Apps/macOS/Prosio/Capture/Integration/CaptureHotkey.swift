import AppKit
import Carbon.HIToolbox
import Observation

/// Legacy combinations use Carbon; either Option is handled by the existing voice event tap
/// after a short, isolated press/release and requires Accessibility + Input Monitoring.
@Observable @MainActor
final class CaptureHotkey {
    enum Shortcut: Int, CaseIterable, Identifiable {
        case off = 0, controlShift2 = 1, controlShift3 = 2, optionEitherSide = 3
        var id: Int { rawValue }
        var label: String { switch self { case .off: "Off"; case .controlShift2: "⌃⇧2"; case .controlShift3: "⌃⇧3"; case .optionEitherSide: "Option（左右均可）" } }
    }
    private(set) var conflictMessage: String?
    @ObservationIgnored var onShortcutChange: () -> Void = {}
    var shortcut: Shortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "prosio.capture.regionShortcut")
            onShortcutChange()
            register()
        }
    }
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        let stored = UserDefaults.standard.object(forKey: "prosio.capture.regionShortcut") as? Int
        shortcut = Shortcut(rawValue: HotkeyRouting.defaultCaptureShortcutRawValue(stored: stored)) ?? .optionEitherSide
    }
    func start() { register() }
    func stop() {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    private func register() {
        stop(); conflictMessage = nil
        // The existing voice CGEventTap observes Option; installing a second listener here
        // would duplicate state and race with voice's own right-Option setting.
        guard shortcut != .off, shortcut != .optionEitherSide else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  HotkeyRouting.isCapture(signature: id.signature, id: id.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<CaptureHotkey>.fromOpaque(userData).takeUnretainedValue().action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { conflictMessage = "Screenshot shortcut could not be installed."; return }
        let key = shortcut == .controlShift2 ? kVK_ANSI_2 : kVK_ANSI_3
        let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | shiftKey), EventHotKeyID(signature: 0x50724370, id: 1), GetApplicationEventTarget(), 0, &reference)
        if result != noErr { conflictMessage = "This shortcut is unavailable. Choose another shortcut." }
    }
}
