import Foundation
import Testing
@testable import ProsioCore

@Suite struct AppSettingsTests {

    private func makeThrowawaySuite() -> (UserDefaults, String) {
        let suiteName = "prosio.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @Test @MainActor func missingValuesUseDefaults() {
        let (defaults, suiteName) = makeThrowawaySuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.triggerKey == .fn)
        #expect(settings.backendURL == URL(string: "http://localhost:3000")!)
        // Derived from the system's preferred languages (see LanguageHintsDefaultTests) — just
        // confirm it matches whatever that derivation actually produces on this machine, rather
        // than hardcoding a specific locale-dependent result here.
        #expect(settings.languageHints == AppSettings.defaultLanguageHints())
        #expect(settings.showEdgeGlow == true)
        #expect(settings.restoreClipboard == true)
        #expect(settings.historyEnabled == true)
        #expect(settings.saveDebugRecordings == false)
        #expect(settings.holdThreshold == 0.3)
    }

    @Test @MainActor func persistsAndReloadsAllProperties() {
        let (defaults, suiteName) = makeThrowawaySuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.triggerKey = .rightOption
        settings.backendURL = URL(string: "https://example.com")!
        settings.languageHints = ["fr-FR"]
        settings.showEdgeGlow = false
        settings.restoreClipboard = false
        settings.historyEnabled = false
        settings.saveDebugRecordings = true
        settings.holdThreshold = 0.75

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.triggerKey == .rightOption)
        #expect(reloaded.backendURL == URL(string: "https://example.com")!)
        #expect(reloaded.languageHints == ["fr-FR"])
        #expect(reloaded.showEdgeGlow == false)
        #expect(reloaded.restoreClipboard == false)
        #expect(reloaded.historyEnabled == false)
        #expect(reloaded.saveDebugRecordings == true)
        #expect(reloaded.holdThreshold == 0.75)
    }

    @Test @MainActor func keysUseProsioPrefix() {
        let (defaults, suiteName) = makeThrowawaySuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.triggerKey = .rightControl
        settings.holdThreshold = 0.42

        #expect(defaults.string(forKey: "prosio.triggerKey") == TriggerKey.rightControl.rawValue)
        #expect(defaults.object(forKey: "prosio.holdThreshold") != nil)
    }

    @Test @MainActor func storedLanguageHintsAreNeverOverriddenByTheSystemDefault() {
        // "only when nothing is stored" — an explicitly saved value must survive reload even if it
        // doesn't look like anything `defaultLanguageHints()` would ever produce.
        let (defaults, suiteName) = makeThrowawaySuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.languageHints = ["pt-BR"]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.languageHints == ["pt-BR"])
    }
}

@Suite struct LanguageHintsDefaultTests {

    @Test func mapsChineseSimplifiedAndTraditionalDistinctly() {
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["zh-Hans-CN"]) == ["zh-CN"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["zh-Hant-TW"]) == ["zh-TW"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["zh-TW"]) == ["zh-TW"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["zh-HK"]) == ["zh-TW"])
        // Bare "zh" (no script/region signal) defaults to simplified.
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["zh"]) == ["zh-CN"])
    }

    @Test func mapsCommonLanguagesToTheirSupportedTag() {
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["en-GB"]) == ["en-US"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["ja-JP"]) == ["ja-JP"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["ko-KR"]) == ["ko-KR"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["es-MX"]) == ["es-ES"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["fr-CA"]) == ["fr-FR"])
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["de-AT"]) == ["de-DE"])
    }

    @Test func preservesPreferenceOrderAndDedupes() {
        // "zh-Hans-CN" and a later "zh-Hans-SG" both map to zh-CN -> only the first is kept.
        let result = AppSettings.defaultLanguageHints(preferredLanguages: ["ja-JP", "zh-Hans-CN", "zh-Hans-SG", "en-US"])
        #expect(result == ["ja-JP", "zh-CN", "en-US"])
    }

    @Test func capsAtThree() {
        let result = AppSettings.defaultLanguageHints(preferredLanguages: ["ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"])
        #expect(result.count == 3)
        #expect(result == ["ja-JP", "ko-KR", "fr-FR"])
    }

    @Test func fallsBackToEnglishWhenNothingMaps() {
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: ["ar-SA", "th-TH"]) == ["en-US"])
    }

    @Test func fallsBackToEnglishWhenPreferredLanguagesIsEmpty() {
        #expect(AppSettings.defaultLanguageHints(preferredLanguages: []) == ["en-US"])
    }
}
