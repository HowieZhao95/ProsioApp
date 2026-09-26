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
        #expect(settings.languageHints == ["zh-CN", "en-US"])
        #expect(settings.showEdgeGlow == true)
        #expect(settings.restoreClipboard == true)
        #expect(settings.historyEnabled == true)
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
        settings.holdThreshold = 0.75

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.triggerKey == .rightOption)
        #expect(reloaded.backendURL == URL(string: "https://example.com")!)
        #expect(reloaded.languageHints == ["fr-FR"])
        #expect(reloaded.showEdgeGlow == false)
        #expect(reloaded.restoreClipboard == false)
        #expect(reloaded.historyEnabled == false)
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
}
