import Foundation

nonisolated struct NoteDay: Hashable, Codable, Comparable, Identifiable, Sendable {
    let key: String
    var id: String { key }
    init(_ date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10, (1...9999).contains(parts[0]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == parts[0],
              calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2],
              String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2]) == key else { return nil }
        self.key = key
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decode(String.self, forKey: .key)
        guard let day = NoteDay(key: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: values, debugDescription: "Invalid note date")
        }
        self = day
    }
    var date: Date {
        let p = key.split(separator: "-").map { Int($0)! }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }
}

nonisolated enum NoteDiskVersion: Codable, Equatable, Sendable {
    case missing
    case content(String)
}

nonisolated struct NoteDraft: Codable, Sendable {
    var day: NoteDay
    var directory: String?
    var text: String
    var baseline: NoteDiskVersion
    var dirty: Bool
}

nonisolated struct NoteLoaded: Sendable {
    var text: String
    var baseline: NoteDiskVersion
    var recovered: Bool
    var conflict: Bool
}

nonisolated enum NoteStoreError: LocalizedError, Equatable {
    case conflict(String), invalidText, recoveryUnavailable, invalidDirectory, tooLarge
    var errorDescription: String? {
        switch self {
        case .conflict(let day): "\(day) 的文件在别处已修改。当前内容已保留，未覆盖磁盘版本。"
        case .invalidText: "文件不是有效的 UTF-8 Markdown，未修改原文件。"
        case .recoveryUnavailable: "无法保留恢复副本。请先选择可写目录或取消退出。"
        case .invalidDirectory: "无法访问存储目录，请在设置中重新选择。"
        case .tooLarge: "便签超过 5 MB，请在外部编辑器中处理，原文件未修改。"
        }
    }
}
