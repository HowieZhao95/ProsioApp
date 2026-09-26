import Foundation
import Testing
@testable import ProsioCore

@Suite struct SceneResolverTests {

    @Test func overrideWinsOverBuiltInTable() {
        let context = FocusContext(bundleID: "com.apple.mail", appName: "Mail")
        let scene = SceneResolver.scene(for: context, overrides: ["com.apple.mail": .general])
        #expect(scene == .general)
    }

    @Test func emailApps() {
        for appName in ["Mail", "Microsoft Outlook", "Spark", "Superhuman"] {
            let context = FocusContext(appName: appName)
            #expect(SceneResolver.scene(for: context) == .email, "\(appName) should resolve to .email")
        }
    }

    @Test func chatApps() {
        for appName in ["Messages", "WeChat", "Slack", "Discord", "Telegram", "WhatsApp", "Microsoft Teams", "Lark", "DingTalk"] {
            let context = FocusContext(appName: appName)
            #expect(SceneResolver.scene(for: context) == .chat, "\(appName) should resolve to .chat")
        }
    }

    @Test func codeApps() {
        for appName in ["Xcode", "Visual Studio Code", "Cursor", "Zed", "Terminal", "iTerm2", "Warp"] {
            let context = FocusContext(appName: appName)
            #expect(SceneResolver.scene(for: context) == .code, "\(appName) should resolve to .code")
        }
    }

    @Test func documentApps() {
        for appName in ["Notes", "Pages", "Microsoft Word", "Notion", "Obsidian", "Bear", "Craft"] {
            let context = FocusContext(appName: appName)
            #expect(SceneResolver.scene(for: context) == .document, "\(appName) should resolve to .document")
        }
    }

    @Test func unknownAppIsGeneral() {
        let context = FocusContext(bundleID: "com.example.unknown", appName: "SomeRandomApp")
        #expect(SceneResolver.scene(for: context) == .general)
    }

    @Test func browserByURLHost() {
        let cases: [(String, WritingScene)] = [
            ("https://mail.google.com/mail/u/0", .email),
            ("https://outlook.office.com/mail", .email),
            ("https://app.slack.com/client", .chat),
            ("https://web.whatsapp.com/", .chat),
            ("https://github.com/prosio/app", .code),
            ("https://docs.google.com/document/d/1", .document),
            ("https://notion.so/some-page", .document),
            ("https://example.com/", .general)
        ]
        for (urlString, expected) in cases {
            let context = FocusContext(appName: "Safari", url: URL(string: urlString))
            #expect(SceneResolver.scene(for: context) == expected, "\(urlString) should resolve to \(expected)")
        }
    }

    @Test func nonBrowserAppWithURLIgnoresHost() {
        // URL is only consulted for recognized browsers.
        let context = FocusContext(appName: "SomeRandomApp", url: URL(string: "https://github.com/x"))
        #expect(SceneResolver.scene(for: context) == .general)
    }

    @Test func browserWithNoURLIsGeneral() {
        let context = FocusContext(appName: "Chrome")
        #expect(SceneResolver.scene(for: context) == .general)
    }

    @Test func matchesByBundleIDWhenAppNameMissing() {
        let context = FocusContext(bundleID: "com.apple.dt.Xcode")
        #expect(SceneResolver.scene(for: context) == .code)
    }
}
