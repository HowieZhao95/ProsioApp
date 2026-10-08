import AppKit
import Carbon.HIToolbox
import Observation

@Observable @MainActor final class NotesHotkey {
    enum Shortcut: Int, CaseIterable, Identifiable {
        case off, controlOptionN, controlShiftN, commandOptionN
        var id: Int { rawValue }
        var label: String { switch self { case .off: "关闭"; case .controlOptionN: "⌃⌥N"; case .controlShiftN: "⌃⇧N"; case .commandOptionN: "⌘⌥N" } }
        var modifiers: UInt32 { switch self { case .off: 0; case .controlOptionN: UInt32(controlKey | optionKey); case .controlShiftN: UInt32(controlKey | shiftKey); case .commandOptionN: UInt32(cmdKey | optionKey) } }
    }
    var selection: Shortcut {
        didSet { defaults.set(selection.rawValue, forKey: "prosio.notes.shortcut"); start() }
    }
    private(set) var conflict: String?
    @ObservationIgnored private var reference: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let action: () -> Void
    init(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        self.action = action
        self.defaults = defaults
        selection = Shortcut(rawValue: defaults.object(forKey: "prosio.notes.shortcut") as? Int ?? 1) ?? .controlOptionN
    }
    func start() {
        stop(); conflict = nil
        guard selection != .off else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x50724E74, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<NotesHotkey>.fromOpaque(data).takeUnretainedValue().action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { conflict = "无法启用便签快捷键，请使用菜单入口。"; return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_N), selection.modifiers, EventHotKeyID(signature: 0x50724E74, id: 1), GetApplicationEventTarget(), 0, &reference)
        if result != noErr { conflict = "快捷键已被占用，请选择其它组合；菜单入口仍可使用。" }
    }
    func stop() {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
