import os

/// Shared logger for dictation diagnostics (timings, suspected dropped content). Not part of the
/// public contract.
enum DictationLog {
    static let logger = Logger(subsystem: "app.prosio.mac", category: "dictation")
}
