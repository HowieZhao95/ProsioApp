import ProsioCore

/// Shared friendly labels for `TriggerKey`, used by the menu bar and Settings > General.
extension TriggerKey {
    var displayName: String {
        switch self {
        case .fn: "fn (🌐)"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        }
    }

    var shortSymbol: String {
        switch self {
        case .fn: "🌐"
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        }
    }
}
