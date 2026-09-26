import Foundation

/// The Translate target language list shown in Settings → Modes, and the short codes used for the
/// capsule's mode chip. Shared so the two stay in sync.
struct TranslateLanguageOption: Identifiable, Hashable {
    /// BCP-47 tag, e.g. "en-US" — matches `AppSettings.translateTarget`.
    let code: String
    let name: String
    /// 1-2 character label for the capsule's mode chip, e.g. "EN".
    let shortCode: String
    var id: String { code }
}

enum TranslateLanguages {
    static let all: [TranslateLanguageOption] = [
        .init(code: "en-US", name: "English", shortCode: "EN"),
        .init(code: "zh-CN", name: "简体中文", shortCode: "简"),
        .init(code: "zh-TW", name: "繁體中文", shortCode: "繁"),
        .init(code: "ja-JP", name: "日本語", shortCode: "日"),
        .init(code: "ko-KR", name: "한국어", shortCode: "한"),
        .init(code: "es-ES", name: "Español", shortCode: "ES"),
        .init(code: "fr-FR", name: "Français", shortCode: "FR"),
        .init(code: "de-DE", name: "Deutsch", shortCode: "DE"),
    ]

    static func shortCode(for bcp47: String) -> String {
        all.first(where: { $0.code == bcp47 })?.shortCode ?? String(bcp47.prefix(2)).uppercased()
    }

    static func name(for bcp47: String) -> String {
        all.first(where: { $0.code == bcp47 })?.name ?? bcp47
    }
}
