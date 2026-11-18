import Foundation

enum ComposeOutput {
    private static let wrappingQuotes: [(String, String)] = [
        ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』"),
    ]
    private static let artOrFence = try! NSRegularExpression(pattern: "```|[─-▟]|[+\\-]{3,}|\\|.*\\|.*\\|")
    private static let expansion = try! NSRegularExpression(pattern: "\\b(expand|elaborate|add (a|an|another|more|some))\\b|扩写|补充|扩展", options: [.caseInsensitive])

    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenced = text.range(of: #"^```[^\n]*\n([\s\S]*)\n```$"#, options: .regularExpression) {
            let inner = String(text[fenced])
            if let start = inner.range(of: "\n"), let end = inner.range(of: "\n```", options: .backwards) {
                text = String(inner[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            for (open, close) in wrappingQuotes where text.hasPrefix(open) && text.hasSuffix(close) && text.count >= open.count + close.count {
                text = String(text.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return ListFormatting.normalizeMarkers(text)
    }

    static func editDrift(output: String, selection: String, instruction: String) -> Bool {
        let introducedArt = matches(artOrFence, output) && !matches(artOrFence, selection)
        let expansionRequested = matches(expansion, instruction)
        let tooLong = !expansionRequested && selection.count >= 20 && output.count > selection.count * 3
        return introducedArt || tooLong
    }

    static func stripInventedWriteSignature(output: String, instruction: String, context: String?) -> String {
        var lines = output.components(separatedBy: "\n")
        guard let last = lastNonEmpty(lines), last > 0 else { return output }
        let lastLine = lines[last].trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeName(lastLine), let previous = lastNonEmpty(lines, before: last), looksLikeClosing(lines[previous]) else { return output }
        let haystack = "\(instruction)\n\(context ?? "")".lowercased()
        if haystack.contains(lastLine.lowercased()) { return output }
        lines.removeSubrange(last...)
        return lines.joined(separator: "\n").replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
    }

    static func unchangedInput(_ request: ComposeRequest) -> String {
        request.mode == .edit ? (request.selection ?? request.text) : request.text
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func lastNonEmpty(_ lines: [String], before: Int? = nil) -> Int? {
        let end = before ?? lines.count
        var index = end - 1
        while index >= 0 {
            if !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return index }
            index -= 1
        }
        return nil
    }

    private static func looksLikeClosing(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.range(of: #"[!！,，]\s*$"#, options: .regularExpression) != nil { return true }
        if ["谢谢", "多谢", "敬上", "此致", "敬礼"].contains(where: { trimmed.hasPrefix($0) }) { return true }
        return trimmed.range(of: #"^(?:thanks|thank you|regards|best regards|best|sincerely|cheers)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func looksLikeName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return false }
        if trimmed.range(of: #"^[一-鿿]{2,4}$"#, options: .regularExpression) != nil { return true }
        return trimmed.range(of: #"^[A-Z][A-Za-z'-]*(?:\s+[A-Z][A-Za-z'-]*){0,2}$"#, options: .regularExpression) != nil
    }
}
