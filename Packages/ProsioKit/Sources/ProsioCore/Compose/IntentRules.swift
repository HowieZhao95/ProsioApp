import Foundation

/// Client-side bilingual (zh/en) fallback for `IntentClassifying`, used when the server's Jev
/// classifier errors, times out, or returns `intent: null` (`source: "unavailable"`) — and
/// whenever there's no classifier configured at all (offline / composer-less). See
/// docs/PROMPTS.md §5b for the source of truth.
///
/// PUBLIC API — pure, no I/O. Always resolves to *some* intent (never `nil`): a recognized cue
/// wins, otherwise the same default the classifier itself would apply (`dictate`, or `edit` when
/// there's a selection).
public enum IntentRules {
    /// Command cue words that must survive transcription verbatim for this fallback (and, ahead of
    /// it, Jev) to ever see them — merged into `TranscriptionOptions.vocabulary` (cloud
    /// transcription's prompt + SpeechAnalyzer's `contextualStrings`) alongside the user's personal
    /// dictionary. Without this, cloud SMART transcription can silently normalize a rarer cue to a
    /// far more common lookalike (observed: "提问" -> "请问", which `IntentRules` deliberately never
    /// treats as a cue — see `boundaryRequiredChineseAskKeywords`), or the on-device preview can
    /// clip a leading word — either way the cue never reaches this classifier.
    public static let vocabularyHints: [String] = [
        "提问", "问答", "请教", "翻译", "翻成", "译成", "Prosio",
        "帮我写", "帮我回复", "帮我起草", "帮我拟", "替我回", "写一封", "起草一封"
    ]

    public struct Result: Equatable, Sendable {
        public var intent: ClassifiedIntent
        /// Only set for `.translate`: the cue-parsed target language and the remainder of the
        /// utterance with the cue stripped off — sent to `compose(.translate)`. (A Jev-classified
        /// `.translate`, by contrast, sends the *whole* utterance to `compose(.translateCommand)`
        /// and lets the server extract the content itself.)
        public var translateTarget: String?
        public var translateBody: String?

        public init(intent: ClassifiedIntent, translateTarget: String? = nil, translateBody: String? = nil) {
            self.intent = intent
            self.translateTarget = translateTarget
            self.translateBody = translateBody
        }
    }

    public static func classify(_ transcript: String, hasSelection: Bool, defaultTranslateTarget: String) -> Result {
        let trimmed = trimLeadingWhitespaceAndPunctuation(transcript)

        if let (target, body) = parseTranslate(trimmed, defaultTarget: defaultTranslateTarget) {
            return Result(intent: .translate, translateTarget: target, translateBody: body)
        }
        if isWrite(trimmed) {
            return Result(intent: .write)
        }
        if isAsk(trimmed) {
            return Result(intent: .ask)
        }
        return Result(intent: hasSelection ? .edit : .dictate)
    }

    // MARK: - Write cues ("Help me write", docs/PROMPTS.md §4b/§5b)
    // 帮我写 / 帮我回复 / 帮我起草 / 帮我拟 / 替我回 / 写一封 / 起草一封 /
    // "help me write" / "draft a|an" / "write a|an (reply|email|message|note|post)" / "reply saying"
    // — only at the very start; never "你帮我…" (naturally excluded by anchoring at the start —
    // "你帮我" doesn't itself begin with "帮我"). Unlike ask/translate, no punctuation/一下 boundary
    // is required after the cue: the whole (untouched) transcript is sent as the write instruction,
    // so there's no structural body to extract.

    private static let chineseWriteCues = ["帮我写", "帮我回复", "帮我起草", "帮我拟", "替我回", "写一封", "起草一封"]

    private static let englishWriteCues: [String] = {
        var cues = ["help me write", "draft a", "draft an", "reply saying"]
        for noun in ["reply", "email", "message", "note", "post"] {
            cues.append("write a \(noun)")
            cues.append("write an \(noun)")
        }
        return cues
    }()

    private static func isWrite(_ text: String) -> Bool {
        if chineseWriteCues.contains(where: text.hasPrefix) { return true }
        let lower = text.lowercased()
        return englishWriteCues.contains(where: lower.hasPrefix)
    }

    // MARK: - Ask cues
    // 提问 / 问答 / 回答 / 请教 / 问一下 / 问问 / Prosio(,) / 普罗西奥 / "hey Prosio" / "question" / "quick question"
    // Chinese cues must be followed by punctuation, 一下, or a question body; never bare "Ask …",
    // and 请问 is deliberately excluded (too common in ordinary writing/dictation).

    /// These already end in "一下" (or are a reduplicated "问问") — self-sufficient, so they only
    /// need *some* non-empty content after them, not a further boundary.
    private static let selfSufficientChineseAskKeywords = ["问一下", "问问"]
    private static let boundaryRequiredChineseAskKeywords = ["提问", "问答", "回答", "请教", "Prosio", "普罗西奥"]

    /// A small set of interrogative openers — satisfies "a question body" per docs/PROMPTS.md
    /// §5b when the cue isn't followed by punctuation or 一下 (e.g. "提问怎么撤销 commit").
    private static let interrogativeStarters = ["怎么", "什么", "为什么", "哪", "谁", "几", "多少", "是否", "能否", "如何"]

    private static func isAsk(_ text: String) -> Bool {
        for keyword in selfSufficientChineseAskKeywords where text.hasPrefix(keyword) {
            let rest = text.dropFirst(keyword.count)
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        for keyword in boundaryRequiredChineseAskKeywords where text.hasPrefix(keyword) {
            let rest = text.dropFirst(keyword.count)
            if consumeBoundary(rest) != nil { return true }
            if interrogativeStarters.contains(where: { rest.hasPrefix($0) }) { return true }
        }
        return isAskEnglish(text)
    }

    private static let englishAskCues = ["quick question", "hey prosio", "question"]

    private static func isAskEnglish(_ text: String) -> Bool {
        let lower = text.lowercased()
        for cue in englishAskCues where lower.hasPrefix(cue) {
            let rest = lower[lower.index(lower.startIndex, offsetBy: cue.count)...]
            guard let first = rest.first else { continue }
            if first == "," || first == ":" { return true }
        }
        return false
    }

    // MARK: - Translate cues
    // 翻译 / 翻成 / 译成 / 帮我翻译 / 用(英文|日语…)说 / "translate (this) (to|into) X" / "in English|Japanese…, "

    private static let translateKeywordsNeedingConnector = ["帮我翻译", "翻译"]
    private static let translateConnectors = ["成", "为", "到"]
    private static let translateKeywordsWithBuiltInConnector = ["翻成", "译成"]

    private static let chineseLanguageNames: [(name: String, bcp47: String)] = [
        ("繁体中文", "zh-Hant"), ("繁体", "zh-Hant"), ("繁中", "zh-Hant"),
        ("简体中文", "zh-CN"), ("中文简体", "zh-CN"), ("中文", "zh-CN"), ("汉语", "zh-CN"),
        ("英文", "en-US"), ("英语", "en-US"),
        ("日语", "ja-JP"), ("日文", "ja-JP"),
        ("韩语", "ko-KR"), ("韩文", "ko-KR"),
        ("法语", "fr-FR"), ("法文", "fr-FR"),
        ("德语", "de-DE"), ("德文", "de-DE"),
        ("西班牙语", "es-ES"), ("西班牙文", "es-ES")
    ].sorted { $0.name.count > $1.name.count }

    private static let englishLanguageNames: [(name: String, bcp47: String)] = [
        ("simplified chinese", "zh-CN"), ("traditional chinese", "zh-Hant"),
        ("mandarin chinese", "zh-CN"), ("mandarin", "zh-CN"), ("chinese", "zh-CN"),
        ("english", "en-US"),
        ("japanese", "ja-JP"),
        ("korean", "ko-KR"),
        ("french", "fr-FR"),
        ("german", "de-DE"),
        ("spanish", "es-ES")
    ].sorted { $0.name.count > $1.name.count }

    private static func parseTranslate(_ text: String, defaultTarget: String) -> (target: String, body: String)? {
        if let result = parseTranslateUseChinese(text, defaultTarget: defaultTarget) { return result }
        if let result = parseTranslateChinese(text, defaultTarget: defaultTarget) { return result }
        if let result = parseTranslateEnglish(text, defaultTarget: defaultTarget) { return result }
        if let result = parseTranslateInLanguageEnglish(text, defaultTarget: defaultTarget) { return result }
        return nil
    }

    /// "用英文说，你好" / "用日语说一下你好"
    private static func parseTranslateUseChinese(_ text: String, defaultTarget: String) -> (target: String, body: String)? {
        guard text.hasPrefix("用") else { return nil }
        var rest = text.dropFirst(1)
        var target: String?
        for (name, bcp47) in chineseLanguageNames where rest.hasPrefix(name) {
            rest = rest.dropFirst(name.count)
            target = bcp47
            break
        }
        guard let target, rest.hasPrefix("说") else { return nil }
        return matchBoundaryAndBody(rest.dropFirst(1), target: target)
    }

    private static func parseTranslateChinese(_ text: String, defaultTarget: String) -> (target: String, body: String)? {
        for keyword in translateKeywordsNeedingConnector where text.hasPrefix(keyword) {
            var rest = text.dropFirst(keyword.count)
            for connector in translateConnectors where rest.hasPrefix(connector) {
                rest = rest.dropFirst(connector.count)
                break
            }
            if let result = matchLanguageThenBoundary(rest, defaultTarget: defaultTarget) { return result }
        }
        for keyword in translateKeywordsWithBuiltInConnector where text.hasPrefix(keyword) {
            let rest = text.dropFirst(keyword.count)
            if let result = matchLanguageThenBoundary(rest, defaultTarget: defaultTarget) { return result }
        }
        return nil
    }

    private static func matchLanguageThenBoundary(_ rest: Substring, defaultTarget: String) -> (target: String, body: String)? {
        var r = rest
        var target = defaultTarget
        for (name, bcp47) in chineseLanguageNames where r.hasPrefix(name) {
            r = r.dropFirst(name.count)
            target = bcp47
            break
        }
        return matchBoundaryAndBody(r, target: target)
    }

    private static func matchBoundaryAndBody(_ rest: Substring, target: String) -> (target: String, body: String)? {
        guard let afterBoundary = consumeBoundary(rest) else { return nil }
        let body = afterBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (target, body)
    }

    /// "Translate (this/it) (to/into) <language>: …", or bare "Translate: …" (default target).
    private static func parseTranslateEnglish(_ text: String, defaultTarget: String) -> (target: String, body: String)? {
        let lower = text.lowercased()
        guard lower.hasPrefix("translate") else { return nil }
        var index = lower.index(lower.startIndex, offsetBy: "translate".count)

        for pronoun in [" this", " it"] where lower[index...].hasPrefix(pronoun) {
            index = lower.index(index, offsetBy: pronoun.count)
            break
        }

        var target = defaultTarget
        for connector in [" into ", " to "] where lower[index...].hasPrefix(connector) {
            let afterConnector = lower.index(index, offsetBy: connector.count)
            for (name, bcp47) in englishLanguageNames where lower[afterConnector...].hasPrefix(name) {
                index = lower.index(afterConnector, offsetBy: name.count)
                target = bcp47
                break
            }
            break
        }

        guard let afterBoundary = consumeBoundary(lower[index...]) else { return nil }
        let bodyLength = afterBoundary.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard bodyLength > 0 else { return nil }
        return (target, String(text.suffix(bodyLength)))
    }

    /// "In English, …" / "In Japanese: …"
    private static func parseTranslateInLanguageEnglish(_ text: String, defaultTarget: String) -> (target: String, body: String)? {
        let lower = text.lowercased()
        guard lower.hasPrefix("in ") else { return nil }
        let afterIn = lower.index(lower.startIndex, offsetBy: 3)
        for (name, bcp47) in englishLanguageNames where lower[afterIn...].hasPrefix(name) {
            let afterName = lower.index(afterIn, offsetBy: name.count)
            guard let afterBoundary = consumeBoundary(lower[afterName...]) else { continue }
            let bodyLength = afterBoundary.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard bodyLength > 0 else { continue }
            return (bcp47, String(text.suffix(bodyLength)))
        }
        return nil
    }

    // MARK: - Shared boundary rule

    private static let separatorCharacters: Set<Character> = [",", "，", ":", "：", "。"]

    /// Consumes an optional "一下" then any run of separators/whitespace — in either order of
    /// presence, as long as at least one of the two was actually there. Returns `nil` when the
    /// cue is followed by neither (ordinary content, not a command).
    private static func consumeBoundary(_ text: Substring) -> Substring? {
        var s = text
        var consumedSomething = false

        if s.hasPrefix("一下") {
            s = s.dropFirst(2)
            consumedSomething = true
        }
        if let first = s.first, first.isWhitespace || separatorCharacters.contains(first) {
            while let f = s.first, f.isWhitespace || separatorCharacters.contains(f) {
                s = s.dropFirst()
            }
            consumedSomething = true
        }
        return consumedSomething ? s : nil
    }

    private static func trimLeadingWhitespaceAndPunctuation(_ text: String) -> String {
        var s = Substring(text)
        while let first = s.first, first.isWhitespace || first.isPunctuation {
            s = s.dropFirst()
        }
        return String(s)
    }
}
