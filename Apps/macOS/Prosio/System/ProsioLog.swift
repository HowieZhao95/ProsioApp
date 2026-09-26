import os

/// Shared `os.Logger` instances for the mac-system layer. Readable via:
///   `log show --predicate 'subsystem == "app.prosio.mac"' --last 1h`
/// Info level only; never logs dictated/user text content, only control-flow facts (states,
/// effects, outcomes, permission statuses).
enum ProsioLog {
    static let subsystem = "app.prosio.mac"

    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let textInsertion = Logger(subsystem: subsystem, category: "textInsertion")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let focus = Logger(subsystem: subsystem, category: "focus")
}
