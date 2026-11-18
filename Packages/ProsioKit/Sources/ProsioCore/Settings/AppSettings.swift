import Foundation
import Observation

public enum TriggerKey: String, Codable, CaseIterable, Sendable {
    case fn, rightOption, rightCommand, rightControl
}

/// User preferences, persisted in UserDefaults. PUBLIC API FROZEN — implementation owned by core agent.
@MainActor
@Observable
public final class AppSettings {
    private static func bundledBackendURL() -> URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "ProsioBackendURL") as? String,
           let url = URL(string: raw), url.scheme == "https", url.host != nil {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }

    public var triggerKey: TriggerKey = .fn {
        didSet { defaults.set(triggerKey.rawValue, forKey: Keys.triggerKey) }
    }
    public var backendURL: URL = AppSettings.bundledBackendURL() {
        didSet { defaults.set(backendURL.absoluteString, forKey: Keys.backendURL) }
    }
    /// BCP-47 hints for transcription. Defaults to the user's preferred system languages (mapped to
    /// the supported set below), falling back to `["en-US"]` when none map — only when nothing is
    /// stored yet (2026-09-26).
    public var languageHints: [String] = AppSettings.defaultLanguageHints() {
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
    /// additive public API (2026-09-26). Disabled by default; users opt in.
    public var saveDebugRecordings: Bool = false {
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
    /// OpenRouter speech-to-text model slug. The key itself lives in the Keychain.
    public var transcriptionModel: String = OpenRouterModels.defaultTranscription {
        didSet { defaults.set(transcriptionModel, forKey: Keys.transcriptionModel) }
    }
    /// OpenRouter chat model slug for rewrite, translate, edit, ask, and capture translation.
    public var composeModel: String = OpenRouterModels.defaultCompose {
        didSet { defaults.set(composeModel, forKey: Keys.composeModel) }
    }
    /// Used once when the primary compose model returns empty text or edit drift.
    public var composeFallbackModel: String = OpenRouterModels.defaultComposeFallback {
        didSet { defaults.set(composeFallbackModel, forKey: Keys.composeFallbackModel) }
    }
    /// Per-app scene overrides (bundleID -> scene), consulted before `SceneResolver`'s built-in table.
    public var sceneOverrides: [String: WritingScene] = [:] {
        didSet {
            let raw = sceneOverrides.mapValues(\.rawValue)
            defaults.set(raw, forKey: Keys.sceneOverrides)
        }
    }
    private let defaults: UserDefaults

    private enum Keys {
        static let triggerKey = "prosio.triggerKey"
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
        static let transcriptionModel = "prosio.transcriptionModel"
        static let composeModel = "prosio.composeModel"
        static let composeFallbackModel = "prosio.composeFallbackModel"
        // "prosio.askTriggerKey" removed (P1.1: single fn hotkey; Ask is voice-triggered). Not
        // read/written anymore — tolerate a stale value left over in a user's defaults.
        // "prosio.enginePreference" removed (P1.2: no engine-mode setting — routing is always
        // automatic, decided server-side per session). Not read/written anymore — tolerate a stale
        // value left over in a user's defaults.
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.triggerKey), let value = TriggerKey(rawValue: raw) {
            triggerKey = value
        }
        #if DEBUG
        if let raw = defaults.string(forKey: Keys.backendURL), let url = URL(string: raw) {
            backendURL = url
        }
        #endif
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
        if let model = defaults.string(forKey: Keys.transcriptionModel), !model.isEmpty {
            transcriptionModel = model
        }
        if let model = defaults.string(forKey: Keys.composeModel), !model.isEmpty {
            composeModel = Self.retiredComposeModels.contains(model) ? OpenRouterModels.defaultCompose : model
        }
        if let model = defaults.string(forKey: Keys.composeFallbackModel), !model.isEmpty {
            composeFallbackModel = Self.retiredComposeModels.contains(model) ? OpenRouterModels.defaultComposeFallback : model
        }
    }

    /// Every BCP-47 tag `languageHints` will ever default to, and the language-code prefixes (and,
    /// for Chinese, script/region hints) that map to each — in priority order, first match wins.
    /// `nonisolated`: pure data, no `AppSettings` instance state — lets `defaultLanguageHints`
    /// (also `nonisolated`) be called from a non-`@MainActor` context (e.g. plain unit tests).
    /// Defaults chosen before Muse. Replaced on launch so an already-opened settings window does not keep them.
    private nonisolated static let retiredComposeModels: Set<String> = [
        "openai/gpt-4o-mini", "google/gemini-2.5-flash", "google/gemini-3.5-flash", "google/gemini-3.5-flash-lite",
        "meta/muse-wonder", "meta/muse-spark-1.3",
    ]

    private nonisolated static let supportedLanguageHints: [(bcp47: String, matches: @Sendable (String) -> Bool)] = [
        ("zh-TW", { lower in
            lower.hasPrefix("zh") && (lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo"))
        }),
        ("zh-CN", { lower in lower.hasPrefix("zh") }),
        ("en-US", { lower in lower.hasPrefix("en") }),
        ("ja-JP", { lower in lower.hasPrefix("ja") }),
        ("ko-KR", { lower in lower.hasPrefix("ko") }),
        ("es-ES", { lower in lower.hasPrefix("es") }),
        ("fr-FR", { lower in lower.hasPrefix("fr") }),
        ("de-DE", { lower in lower.hasPrefix("de") })
    ]

    /// Maps the user's system-preferred languages (`Locale.preferredLanguages` by default — a
    /// parameter only so tests can supply a fixed list) to the supported BCP-47 tags above, in the
    /// user's preference order, deduped, capped at 3. Falls back to `["en-US"]` if none map (e.g. a
    /// system language this app doesn't have transcription support for). Used only as
    /// `languageHints`'s default value — never overrides an already-stored preference.
    nonisolated static func defaultLanguageHints(preferredLanguages: [String] = Locale.preferredLanguages) -> [String] {
        var result: [String] = []
        for identifier in preferredLanguages {
            let lower = identifier.lowercased()
            guard let mapped = supportedLanguageHints.first(where: { $0.matches(lower) })?.bcp47 else { continue }
            if !result.contains(mapped) {
                result.append(mapped)
            }
            if result.count >= 3 { break }
        }
        return result.isEmpty ? ["en-US"] : result
    }
}
