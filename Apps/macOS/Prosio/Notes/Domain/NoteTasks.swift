import Foundation

nonisolated struct NoteTask: Identifiable, Equatable, Sendable {
    let line: Int
    let title: String
    let completed: Bool
    var id: Int { line }
}

nonisolated struct NoteTaskSummary: Equatable, Sendable {
    var tasks: [NoteTask] = []
    var completed: Int { tasks.filter(\.completed).count }
    var remaining: Int { tasks.count - completed }

    /// Markdown checkboxes remain the source of truth. Code examples are not tasks.
    static func parse(_ markdown: String) -> Self {
        let marker = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+\[([ xX])\](?:[ \t]+(.*)|$)"#)
        let list = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*]|[0-9]+[.)])[ \t]+"#)
        let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)
        var tasks: [NoteTask] = []
        var activeFence: (Character, Int)?
        var listContentIndent: Int?
        var inComment = false
        for (index, raw) in markdown.components(separatedBy: .newlines).enumerated() {
            // Blockquote containers can contain both tasks and fenced code.
            var line = raw.replacingOccurrences(of: "\r", with: "")
            while let range = line.range(of: #"^ {0,3}> ?"#, options: .regularExpression) { line.removeSubrange(range) }
            let indentation = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let codeIndent = (listContentIndent ?? 0) + 4
            // Remove list indentation for a fence within a list item.
            let lineRange = NSRange(line.startIndex..., in: line)
            let listMatch = list.firstMatch(in: line, range: lineRange)
            let fenceLine: String
            if let listMatch, let prefix = Range(listMatch.range, in: line) {
                fenceLine = String(line[prefix.upperBound...])
            } else if let contentIndent = listContentIndent, indentation >= contentIndent {
                fenceLine = String(line.dropFirst(min(indentation, contentIndent)))
            } else { fenceLine = line }
            let fenceRange = NSRange(fenceLine.startIndex..., in: fenceLine)
            if let match = fence.firstMatch(in: fenceLine, range: fenceRange), let runRange = Range(match.range(at: 1), in: fenceLine), let suffixRange = Range(match.range(at: 2), in: fenceLine) {
                let run = fenceLine[runRange], suffix = fenceLine[suffixRange]
                if let active = activeFence {
                    if run.first == active.0 && run.count >= active.1 && suffix.trimmingCharacters(in: .whitespaces).isEmpty { activeFence = nil }
                } else if run.first != "`" || !suffix.contains("`") {
                    activeFence = (run.first!, run.count)
                    if let listMatch { listContentIndent = listMatch.range.length }
                }
                continue
            }
            if activeFence != nil { continue }
            if inComment || line.contains("<!--") {
                inComment = !line.contains("-->")
                continue
            }
            if indentation >= codeIndent { continue }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty && indentation < (listContentIndent ?? 0) { listContentIndent = nil }
            let range = NSRange(line.startIndex..., in: line)
            if let match = list.firstMatch(in: line, range: range) { listContentIndent = match.range.length }
            guard let match = marker.firstMatch(in: line, range: range), let checked = Range(match.range(at: 2), in: line) else { continue }
            let title = Range(match.range(at: 3), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
            tasks.append(NoteTask(line: index, title: title.isEmpty ? "未命名任务" : title, completed: line[checked] != " "))
        }
        return Self(tasks: tasks)
    }
}
