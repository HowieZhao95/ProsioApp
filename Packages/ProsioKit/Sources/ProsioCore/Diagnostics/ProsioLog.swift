import os

/// Shared loggers for backend/compose diagnostics. Not part of the public contract.
enum ProsioLog {
    static let compose = Logger(subsystem: "app.prosio.mac", category: "compose")
    static let intent = Logger(subsystem: "app.prosio.mac", category: "intent")
}
