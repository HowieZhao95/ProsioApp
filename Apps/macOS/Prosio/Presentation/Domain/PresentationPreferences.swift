import Foundation
import Observation

@Observable @MainActor
final class PresentationPreferences {
    enum PointerStyle: String, CaseIterable { case ring, clicksOnly }
    enum KeyDisplayMode: String, CaseIterable {
        case shortcuts, allKeys
        var title: String { self == .shortcuts ? "仅快捷组合" : "全部按键" }
    }
    enum Accent: String, CaseIterable { case blue, orange, purple }
    private let defaults: UserDefaults
    var pointerStyle: PointerStyle { didSet { save() } }
    var accent: Accent { didSet { save() } }
    var pointerSize: Double { didSet { save() } }
    var keyLinger: Double { didSet { save() } }
    var keyDisplayMode: KeyDisplayMode { didSet { save() } }
    var sessionPointer: Bool { didSet { save() } }
    var sessionKeys: Bool { didSet { save() } }
    var sessionAwake: Bool { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pointerStyle = PointerStyle(rawValue: defaults.string(forKey: "prosio.presentation.pointerStyle") ?? "") ?? .ring
        accent = Accent(rawValue: defaults.string(forKey: "prosio.presentation.accent") ?? "") ?? .blue
        pointerSize = Self.valid(defaults.object(forKey: "prosio.presentation.pointerSize") as? Double, range: 32...100, fallback: 64)
        keyLinger = Self.valid(defaults.object(forKey: "prosio.presentation.keyLinger") as? Double, range: 0.5...3, fallback: 1.2)
        keyDisplayMode = KeyDisplayMode(rawValue: defaults.string(forKey: "prosio.presentation.keyDisplayMode") ?? "") ?? .shortcuts
        sessionPointer = defaults.object(forKey: "prosio.presentation.sessionPointer") as? Bool ?? true
        sessionKeys = defaults.object(forKey: "prosio.presentation.sessionKeys") as? Bool ?? true
        sessionAwake = defaults.object(forKey: "prosio.presentation.sessionAwake") as? Bool ?? true
    }
    private static func valid(_ value: Double?, range: ClosedRange<Double>, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    var resolvedPointerSize: Double { Self.valid(pointerSize, range: 32...100, fallback: 64) }
    var resolvedKeyLinger: Double { Self.valid(keyLinger, range: 0.5...3, fallback: 1.2) }
    func reset() {
        pointerStyle = .ring; accent = .blue; pointerSize = 64; keyLinger = 1.2
        keyDisplayMode = .shortcuts
        sessionPointer = true; sessionKeys = true; sessionAwake = true
    }
    private func save() {
        defaults.set(pointerStyle.rawValue, forKey: "prosio.presentation.pointerStyle")
        defaults.set(accent.rawValue, forKey: "prosio.presentation.accent")
        defaults.set(resolvedPointerSize, forKey: "prosio.presentation.pointerSize")
        defaults.set(resolvedKeyLinger, forKey: "prosio.presentation.keyLinger")
        defaults.set(keyDisplayMode.rawValue, forKey: "prosio.presentation.keyDisplayMode")
        defaults.set(sessionPointer, forKey: "prosio.presentation.sessionPointer")
        defaults.set(sessionKeys, forKey: "prosio.presentation.sessionKeys")
        defaults.set(sessionAwake, forKey: "prosio.presentation.sessionAwake")
    }
}
