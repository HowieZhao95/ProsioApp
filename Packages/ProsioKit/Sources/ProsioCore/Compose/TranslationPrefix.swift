import Foundation

/// Parses a one-off translate prefix from the very start of a dictation, e.g. "翻译成英文：你好"
/// or "Translate to French: Hello". PUBLIC API — pure, no I/O.
public enum TranslationPrefix {
    /// Returns `(targetLanguage, remainder)` — `targetLanguage` as BCP-47, `remainder` trimmed —
    /// or `nil` if `text` doesn't start with a recognized translate prefix.
    public static func parse(_ text: String) -> (targetLanguage: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result = parseChinese(trimmed) { return result }
        if let result = parseEnglish(trimmed) { return result }
        return nil
    }

    // MARK: - Chinese: "翻译成<language><separator><remainder>" / "译成..."

    private static let chinesePrefixes = ["翻译成", "译成"]

    private static let chineseLanguageNames: [(name: String, bcp47: String)] = [
        ("简体中文", "zh-CN"), ("中文简体", "zh-CN"), ("中文", "zh-CN"), ("汉语", "zh-CN"),
        ("英文", "en-US"), ("英语", "en-US"),
        ("日语", "ja-JP"), ("日文", "ja-JP"),
        ("韩语", "ko-KR"), ("韩文", "ko-KR"),
        ("法语", "fr-FR"), ("法文", "fr-FR"),
        ("德语", "de-DE"), ("德文", "de-DE"),
        ("西班牙语", "es-ES"), ("西班牙文", "es-ES")
    ].sorted { $0.name.count > $1.name.count }

    private static func parseChinese(_ text: String) -> (targetLanguage: String, remainder: String)? {
        for prefix in chinesePrefixes {
            guard text.hasPrefix(prefix) else { continue }
            let afterPrefix = String(text.dropFirst(prefix.count))
            for (name, bcp47) in chineseLanguageNames {
                guard afterPrefix.hasPrefix(name) else { continue }
                let rest = String(afterPrefix.dropFirst(name.count))
                if let remainder = stripLeadingSeparator(rest) {
                    return (bcp47, remainder)
                }
            }
        }
        return nil
    }

    // MARK: - English: "Translate [this/it] to/into <language><separator><remainder>"

    private static let englishLanguageNames: [(name: String, bcp47: String)] = [
        ("simplified chinese", "zh-CN"), ("mandarin chinese", "zh-CN"), ("mandarin", "zh-CN"), ("chinese", "zh-CN"),
        ("english", "en-US"),
        ("japanese", "ja-JP"),
        ("korean", "ko-KR"),
        ("french", "fr-FR"),
        ("german", "de-DE"),
        ("spanish", "es-ES")
    ].sorted { $0.name.count > $1.name.count }

    private static func parseEnglish(_ text: String) -> (targetLanguage: String, remainder: String)? {
        let lower = text.lowercased()
        guard lower.hasPrefix("translate") else { return nil }
        var index = lower.index(lower.startIndex, offsetBy: "translate".count)

        for pronoun in [" this", " it"] where lower[index...].hasPrefix(pronoun) {
            index = lower.index(index, offsetBy: pronoun.count)
            break
        }

        var matchedConnector = false
        for connector in [" into ", " to "] where lower[index...].hasPrefix(connector) {
            index = lower.index(index, offsetBy: connector.count)
            matchedConnector = true
            break
        }
        guard matchedConnector else { return nil }

        let afterConnector = lower[index...]
        for (name, bcp47) in englishLanguageNames {
            guard afterConnector.hasPrefix(name) else { continue }
            let nameEndIndex = lower.index(index, offsetBy: name.count)
            let restLower = String(lower[nameEndIndex...])
            guard let strippedLowerRemainder = stripLeadingSeparator(restLower) else { continue }
            // Recover the original casing for the remainder: same trailing length as the
            // (case-preserving-length) lowercased match.
            let remainderLength = strippedLowerRemainder.count
            let originalRemainder = String(text.suffix(remainderLength))
            return (bcp47, originalRemainder)
        }
        return nil
    }

    // MARK: - Shared

    /// A prefix must be followed by one of these (optionally surrounded by whitespace) to count —
    /// bare whitespace alone does not separate the language name from the remainder.
    private static let separators: Set<Character> = [":", "：", ",", "，", "、"]

    private static func stripLeadingSeparator(_ text: String) -> String? {
        var s = Substring(text)
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        guard let first = s.first, separators.contains(first) else { return nil }
        s = s.dropFirst()
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        return String(s)
    }
}
