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
    /// P1: menu-bar Translate toggle — when on, every `.dictate` session is translated to
    /// `translateTarget` instead of inserted as-is (unless a one-off translate prefix overrides).
    public var translateEnabled: Bool = false {
        didSet { defaults.set(translateEnabled, forKey: Keys.translateEnabled) }
    }
    /// BCP-47 target language for the Translate toggle.
    public var translateTarget: String = "en-US" {
        didSet { defaults.set(translateTarget, forKey: Keys.translateTarget) }
    }
    /// P1: adapt dictated text to the focused app's writing scene (email/chat/code/document) via
    /// the rewrite compose mode. No effect when the scene is `.general`.
    public var adaptToApp: Bool = true {
        didSet { defaults.set(adaptToApp, forKey: Keys.adaptToApp) }
    }
    /// Per-app scene overrides (bundleID -> scene), consulted before `SceneResolver`'s built-in table.
    public var sceneOverrides: [String: WritingScene] = [:] {
        didSet {
            let raw = sceneOverrides.mapValues(\.rawValue)
            defaults.set(raw, forKey: Keys.sceneOverrides)
        }
    }
    /// P1: the key that triggers Ask mode (default right ⌘).
    public var askTriggerKey: TriggerKey = .rightCommand {
        didSet { defaults.set(askTriggerKey.rawValue, forKey: Keys.askTriggerKey) }
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
        static let translateEnabled = "prosio.translateEnabled"
        static let translateTarget = "prosio.translateTarget"
        static let adaptToApp = "prosio.adaptToApp"
        static let sceneOverrides = "prosio.sceneOverrides"
        static let askTriggerKey = "prosio.askTriggerKey"
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
        if defaults.object(forKey: Keys.translateEnabled) != nil {
            translateEnabled = defaults.bool(forKey: Keys.translateEnabled)
        }
        if let target = defaults.string(forKey: Keys.translateTarget) {
            translateTarget = target
        }
        if defaults.object(forKey: Keys.adaptToApp) != nil {
            adaptToApp = defaults.bool(forKey: Keys.adaptToApp)
        }
        if let raw = defaults.dictionary(forKey: Keys.sceneOverrides) as? [String: String] {
            sceneOverrides = raw.compactMapValues { WritingScene(rawValue: $0) }
        }
        if let raw = defaults.string(forKey: Keys.askTriggerKey), let value = TriggerKey(rawValue: raw) {
            askTriggerKey = value
        }
    }
}
