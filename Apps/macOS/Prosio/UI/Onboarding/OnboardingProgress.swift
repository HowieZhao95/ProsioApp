import Foundation
import Observation

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case voice, capture, notes, tools, ready
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .voice: "语音输入"
        case .capture: "屏幕截图"
        case .notes: "桌面便签"
        case .tools: "更多工具"
        case .ready: "开始使用"
        }
    }
    var number: String { String(format: "%02d", rawValue + 1) }
}

/// Visiting a page and completing a real exercise are separate. Permissions remain system-owned.
@Observable
final class OnboardingProgress {
    static let version = 1
    private let defaults: UserDefaults
    private(set) var page: OnboardingPage
    private(set) var experienced: Set<OnboardingPage>
    private(set) var dismissed: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        page = OnboardingPage(rawValue: defaults.integer(forKey: "prosio.onboarding.page")) ?? .voice
        experienced = Set((defaults.array(forKey: "prosio.onboarding.experienced") as? [Int] ?? []).compactMap(OnboardingPage.init(rawValue:)))
        dismissed = defaults.integer(forKey: "prosio.onboarding.dismissedVersion") >= Self.version
    }
    var shouldPresentOnLaunch: Bool { !dismissed }
    var previous: OnboardingPage? { OnboardingPage(rawValue: page.rawValue - 1) }
    var next: OnboardingPage? { OnboardingPage(rawValue: page.rawValue + 1) }
    func select(_ page: OnboardingPage) {
        self.page = page
        defaults.set(page.rawValue, forKey: "prosio.onboarding.page")
    }
    func markExperienced(_ page: OnboardingPage) {
        experienced.insert(page)
        defaults.set(experienced.map(\.rawValue).sorted(), forKey: "prosio.onboarding.experienced")
    }
    func dismiss() {
        dismissed = true
        defaults.set(Self.version, forKey: "prosio.onboarding.dismissedVersion")
    }
    func handleWindowClose(isTerminating: Bool) {
        if !isTerminating { dismiss() }
    }
    func reopen() { select(.voice) }
}
