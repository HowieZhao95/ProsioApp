import Foundation

/// Bounded incremental reader. It never stores raw transcripts or opens credential files.
actor CodexLogObserver: AgentObserving {
    struct Cursor {
        var offset: UInt64 = 0
        var remainder = Data()
        var task: AgentTask
        var identity: UInt64 = 0
        var modified = Date.distantPast
    }
    let root: URL
    private var cursors: [URL: Cursor] = [:]
    private let maxFiles = 100
    private let chunkLimit = 512 * 1024
    private let titleLimit = 2 * 1024 * 1024

    init(root: URL) { self.root = root }

    func snapshot(now: Date = Date()) async -> AgentMonitorSnapshot {
        var snapshot = AgentMonitorSnapshot(checkedAt: now)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            cursors.removeAll()
            snapshot.warnings = ["没有找到本地 Codex 会话目录。"]
            return snapshot
        }
        var candidates: [(URL, Date)] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Only date directories are traversed; unrelated files in CODEX_HOME are never opened.
        // Codex date directories may use the host local date while events use UTC.
        // Include the adjacent next UTC date so positive offsets do not hide active sessions.
        for day in -1..<14 {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let path = String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!)
            let directory = sessions.appendingPathComponent(path, isDirectory: true)
            do {
                if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                let urls = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                for url in urls where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    candidates.append((url, values.contentModificationDate ?? .distantPast))
                }
            } catch {
                if FileManager.default.fileExists(atPath: directory.path) {
                    snapshot.warnings.append("部分会话目录无法读取，请检查访问权限。")
                }
            }
        }
        candidates.sort { $0.1 > $1.1 }
        if candidates.count > maxFiles { snapshot.warnings.append("当前仅展示最近 \(maxFiles) 个本地会话。") }
        candidates = Array(candidates.prefix(maxFiles))
        let retained = Set(candidates.map(\.0))
        cursors = cursors.filter { retained.contains($0.key) }
        let titles = readTitles()
        for (url, modified) in candidates {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                var cursor = cursors[url] ?? Cursor(task: AgentTask(id: url.lastPathComponent))
                let reset = cursor.identity != identity || size < cursor.offset || (size == cursor.offset && modified != cursor.modified)
                if reset { cursor = Cursor(task: AgentTask(id: url.lastPathComponent)) }
                cursor.identity = identity
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                if cursor.offset == 0 && size > UInt64(chunkLimit) {
                    let head = try handle.read(upToCount: 64 * 1024) ?? Data()
                    snapshot.bytesRead += head.count
                    consume(head, cursor: &cursor, metadataOnly: true)
                    cursor.remainder = Data()
                    cursor.offset = size - UInt64(chunkLimit)
                    try handle.seek(toOffset: cursor.offset)
                    let tail = try handle.read(upToCount: chunkLimit) ?? Data()
                    snapshot.bytesRead += tail.count
                    // The first line may begin in the middle of an oversized JSON record.
                    if let boundary = tail.firstIndex(of: 10) {
                        consume(Data(tail.suffix(from: tail.index(after: boundary))), cursor: &cursor)
                    }
                    cursor.offset += UInt64(tail.count)
                    cursor.task.truncated = true
                } else if cursor.offset < size {
                    // If the writer outruns us, skip to a bounded tail rather than retain a backlog.
                    if size - cursor.offset > UInt64(chunkLimit) {
                        cursor.offset = size - UInt64(chunkLimit); cursor.remainder = Data()
                        cursor.task.state = .unknown; cursor.task.pendingCalls = []; cursor.task.waitingCalls = []
                        cursor.task.question = nil; cursor.task.decisions = []; cursor.task.truncated = true
                        try handle.seek(toOffset: cursor.offset)
                        let data = try handle.read(upToCount: chunkLimit) ?? Data()
                        snapshot.bytesRead += data.count
                        if let boundary = data.firstIndex(of: 10) {
                            consume(Data(data.suffix(from: data.index(after: boundary))), cursor: &cursor)
                        }
                        cursor.offset += UInt64(data.count)
                    } else {
                        try handle.seek(toOffset: cursor.offset)
                        let data = try handle.read(upToCount: chunkLimit) ?? Data()
                        snapshot.bytesRead += data.count
                        consume(data, cursor: &cursor)
                        cursor.offset += UInt64(data.count)
                    }
                }
                cursor.modified = modified
                cursor.task.readError = false
                if let title = titles[cursor.task.id] { cursor.task.title = title }
                else if cursor.task.title == "未命名任务", !cursor.task.workspace.isEmpty {
                    cursor.task.title = URL(fileURLWithPath: cursor.task.workspace).lastPathComponent
                }
                cursors[url] = cursor
            } catch {
                if var cursor = cursors[url] { cursor.task.readError = true; cursors[url] = cursor }
                snapshot.warnings.append("部分会话文件读取失败，相关状态不可确认。")
            }
        }
        snapshot.tasks = cursors.values.map(\.task).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        snapshot.scannedFiles = candidates.count
        snapshot.warnings = Array(Set(snapshot.warnings)).sorted()
        return snapshot
    }

    private func consume(_ data: Data, cursor: inout Cursor, metadataOnly: Bool = false) {
        var joined = cursor.remainder
        joined.append(data)
        let lines = joined.split(separator: 10, omittingEmptySubsequences: false)
        cursor.remainder = Data(lines.last ?? Data.SubSequence())
        for line in lines.dropLast() where !line.isEmpty {
            if metadataOnly {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["type"] as? String == "session_meta" else { continue }
            }
            if !CodexEventReducer.apply(Data(line), to: &cursor.task), !metadataOnly {
                cursor.task.truncated = true; cursor.task.state = .unknown
                cursor.task.question = nil; cursor.task.decisions = []
            }
        }
        if cursor.remainder.count > chunkLimit {
            cursor.remainder = Data(); cursor.task.truncated = true; cursor.task.state = .unknown
        }
    }

    private func readTitles() -> [String: String] {
        let url = root.appendingPathComponent("session_index.jsonl")
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [:] }
        let offset = size > UInt64(titleLimit) ? size - UInt64(titleLimit) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: titleLimit) else { return [:] }
        var titles: [String: String] = [:]
        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String, let title = object["thread_name"] as? String else { continue }
            titles[id] = String(title.prefix(200))
        }
        return titles
    }
}
