import Foundation

/// Classifies the focused app/window into a `WritingScene`, client-side and instant. Used by
/// `DictationController` to decide whether (and how) to adapt dictated text.
///
/// Order: per-app `overrides` first, then a built-in bundle-ID/app-name table, then (for browsers)
/// the page URL's host, else `.general`. PUBLIC API — pure, no I/O.
public enum SceneResolver {
    public static func scene(for context: FocusContext, overrides: [String: WritingScene] = [:]) -> WritingScene {
        if let bundleID = context.bundleID, let override = overrides[bundleID] {
            return override
        }
        if let scene = sceneFromAppTable(bundleID: context.bundleID, appName: context.appName) {
            return scene
        }
        if isBrowser(bundleID: context.bundleID, appName: context.appName), let host = context.url?.host {
            return sceneForHost(host)
        }
        return .general
    }

    // MARK: - App table

    private static let categoryTable: [(WritingScene, [String])] = [
        (.email, ["mail", "outlook", "spark", "superhuman"]),
        (.chat, ["messages", "wechat", "weixin", "slack", "discord", "telegram", "whatsapp", "teams", "lark", "dingtalk", "feishu"]),
        (.code, ["xcode", "code", "cursor", "zed", "jetbrains", "intellij", "webstorm", "pycharm", "clion", "rubymine", "goland", "terminal", "iterm", "warp", "ghostty"]),
        (.document, ["notes", "pages", "word", "notion", "obsidian", "bear", "craft"])
    ]

    private static func sceneFromAppTable(bundleID: String?, appName: String?) -> WritingScene? {
        for (scene, keywords) in categoryTable where matches(bundleID: bundleID, appName: appName, keywords: keywords) {
            return scene
        }
        return nil
    }

    private static func matches(bundleID: String?, appName: String?, keywords: [String]) -> Bool {
        let haystacks = [bundleID?.lowercased(), appName?.lowercased()].compactMap { $0 }
        guard !haystacks.isEmpty else { return false }
        return keywords.contains { keyword in haystacks.contains { $0.contains(keyword) } }
    }

    // MARK: - Browsers, by URL host

    private static let browserKeywords = ["safari", "chrome", "arc", "edge", "brave", "firefox"]

    private static func isBrowser(bundleID: String?, appName: String?) -> Bool {
        matches(bundleID: bundleID, appName: appName, keywords: browserKeywords)
    }

    private static func sceneForHost(_ host: String) -> WritingScene {
        let h = host.lowercased()
        if h.contains("mail.google.com") || h.contains("outlook.") { return .email }
        if h.contains("slack.com") || h.contains("discord.com") || h.contains("web.whatsapp.com")
            || h.contains("teams.microsoft.com") || h.contains("web.telegram.org") { return .chat }
        if h.contains("github.com") || h.contains("gitlab.com") || h.contains("stackoverflow.com") { return .code }
        if h.contains("docs.google.com") || h.contains("notion.so") || h.contains("confluence") { return .document }
        return .general
    }
}
