import Foundation
import Observation

public enum TriggerKey: String, Codable, CaseIterable, Sendable {
    case fn, rightOption, rightCommand, rightControl
}

public enum EnginePreference: String, Codable, CaseIterable, Sendable {
    /// Cloud first, fall back to on-device on failure/offline.
    case auto
    case cloud
    case local
}

/// User preferences, persisted in UserDefaults. PUBLIC API FROZEN — implementation owned by core agent.
@MainActor
@Observable
public final class AppSettings {
    public var triggerKey: TriggerKey = .fn {
        didSet { defaults.set(triggerKey.rawValue, forKey: Keys.triggerKey) }
    }
    public var enginePreference: EnginePreference = .auto {
        didSet { defaults.set(enginePreference.rawValue, forKey: Keys.enginePreference) }
    }
    public var backendURL: URL = URL(string: "http://localhost:3000")! {
        didSet { defaults.set(backendURL.absoluteString, forKey: Keys.backendURL) }
    }
    public var languageHints: [String] = ["zh-CN", "en-US"] {
        didSet { defaults.set(languageHints, forKey: Keys.languageHints) }
    }
    public var showEdgeGlow: Bool = true {
        didSet { defaults.set(showEdgeGlow, forKey: Keys.showEdgeGlow) }
    }
    public var restoreClipboard: Bool = true {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }
    public var historyEnabled: Bool = true {
        didSet { defaults.set(historyEnabled, forKey: Keys.historyEnabled) }
    }
    /// Seconds a push-to-talk key must be held before it counts as "hold" rather than "tap".
    public var holdThreshold: TimeInterval = 0.3 {
        didSet { defaults.set(holdThreshold, forKey: Keys.holdThreshold) }
    }
    /// When on, `DictationController` writes a debug recording (audio.wav + session.json) for
    /// every session under Application Support, for diagnosing accuracy issues. Approved
    /// additive public API (2026-09-26). Default `true` for now, during testing.
    public var saveDebugRecordings: Bool = true {
        didSet { defaults.set(saveDebugRecordings, forKey: Keys.saveDebugRecordings) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let triggerKey = "prosio.triggerKey"
        static let enginePreference = "prosio.enginePreference"
        static let backendURL = "prosio.backendURL"
        static let languageHints = "prosio.languageHints"
        static let showEdgeGlow = "prosio.showEdgeGlow"
        static let restoreClipboard = "prosio.restoreClipboard"
        static let historyEnabled = "prosio.historyEnabled"
        static let holdThreshold = "prosio.holdThreshold"
        static let saveDebugRecordings = "prosio.saveDebugRecordings"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.triggerKey), let value = TriggerKey(rawValue: raw) {
            triggerKey = value
        }
        if let raw = defaults.string(forKey: Keys.enginePreference), let value = EnginePreference(rawValue: raw) {
            enginePreference = value
        }
        if let raw = defaults.string(forKey: Keys.backendURL), let url = URL(string: raw) {
            backendURL = url
        }
        if let hints = defaults.array(forKey: Keys.languageHints) as? [String] {
            languageHints = hints
        }
        if defaults.object(forKey: Keys.showEdgeGlow) != nil {
            showEdgeGlow = defaults.bool(forKey: Keys.showEdgeGlow)
        }
        if defaults.object(forKey: Keys.restoreClipboard) != nil {
            restoreClipboard = defaults.bool(forKey: Keys.restoreClipboard)
        }
        if defaults.object(forKey: Keys.historyEnabled) != nil {
            historyEnabled = defaults.bool(forKey: Keys.historyEnabled)
        }
        if defaults.object(forKey: Keys.holdThreshold) != nil {
            holdThreshold = defaults.double(forKey: Keys.holdThreshold)
        }
        if defaults.object(forKey: Keys.saveDebugRecordings) != nil {
            saveDebugRecordings = defaults.bool(forKey: Keys.saveDebugRecordings)
        }
    }
}
