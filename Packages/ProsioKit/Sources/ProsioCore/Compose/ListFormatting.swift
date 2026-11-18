import Foundation

enum ListFormatting {
    private static let latinEnumeration = try! NSRegularExpression(pattern: "\\b(?:first|second|third|finally|next)\\b", options: [.caseInsensitive])
    private static let cjkEnumeration = ["第一", "第二", "第三", "首先", "其次", "最后", "一是", "二是"]
    private static let listIntro = ["以下", "几点", "几个", "几件", "action items", "points", "things", "steps", "items"]
    private static let markdownList = try! NSRegularExpression(pattern: #"^\s*(?:[-*•·–]\s+\S|\d+[.、]\s*\S)"#)
    private static let bulletMarker = try! NSRegularExpression(pattern: #"^(\s*)[*•·–]\s+"#)
    private static let fenceLine = try! NSRegularExpression(pattern: #"^\s*```"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*(?:[-*•·–]\s+|\d+[.、]\s*)"#, options: [.anchorsMatchLines])
    private static let latinConnector = try! NSRegularExpression(pattern: "\\b(?:and|then|also|plus)\\b", options: [.caseInsensitive])
    private static let cjkConnectors = ["然后", "还有", "以及", "和", "跟"]
    private static let punctuation = try! NSRegularExpression(pattern: "[\\s.,!?;:，。！？；：、\"'“”‘’()（）\\[\\]【】\\-—–*•·]")

    static func normalizeMarkers(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line in
            if firstMatch(fenceLine, line) != nil {
                inFence.toggle()
                return line
            }
            guard !inFence, let match = firstMatch(bulletMarker, line), let range = Range(match.range(at: 1), in: line) else { return line }
            let indent = String(line[range])
            let rest = String(line[Range(match.range, in: line)!.upperBound...])
            return "\(indent)- \(rest)"
        }.joined(separator: "\n")
    }

    /// Spoken-list detector used before transcription. A list that is still one sentence must go to Gemini.
    static func forcesCloudFormatting(_ text: String) -> Bool {
        enumerationCount(text) >= 2 || listLikeClauses(text) >= 3
    }

    static func needsRepair(_ text: String) -> Bool {
        if text.components(separatedBy: "\n").contains(where: { firstMatch(markdownList, $0) != nil }) { return false }
        return enumerationCount(text) >= 2 || listLikeClauses(text) >= 3
    }

    static func passesSafetyCheck(original: String, repaired: String) -> Bool {
        strip(original) == strip(repaired)
    }

    private static func enumerationCount(_ text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        let latin = latinEnumeration.numberOfMatches(in: text, range: range)
        let cjk = cjkEnumeration.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        return latin + cjk
    }

    private static func listLikeClauses(_ text: String) -> Int {
        let hasColon = text.contains(":") || text.contains("：")
        let lowered = text.lowercased()
        let hasIntro = listIntro.contains { lowered.contains($0.lowercased()) }
        guard hasColon || hasIntro else { return 0 }
        let after = hasColon ? text.split(whereSeparator: { $0 == ":" || $0 == "：" }).dropFirst().joined(separator: "：") : text
        return after.split(whereSeparator: { $0 == "、" || $0 == "，" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.count
    }

    private static func strip(_ text: String) -> String {
        var value = replace(listMarker, in: text, with: "")
        value = replace(latinConnector, in: value, with: "")
        for connector in cjkConnectors { value = value.replacingOccurrences(of: connector, with: "") }
        value = replace(punctuation, in: value, with: "")
        return value.lowercased()
    }

    private static func firstMatch(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
