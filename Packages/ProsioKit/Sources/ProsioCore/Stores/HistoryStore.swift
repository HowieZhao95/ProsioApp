import Foundation
import Observation

public struct HistoryItem: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var appBundleID: String?
    public var appName: String?
    public var engineID: String
    public var durationSeconds: Double
    public var insertion: InsertionOutcome

    public init(id: UUID = UUID(), createdAt: Date = .now, text: String, appBundleID: String? = nil, appName: String? = nil, engineID: String, durationSeconds: Double, insertion: InsertionOutcome) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.appBundleID = appBundleID
        self.appName = appName
        self.engineID = engineID
        self.durationSeconds = durationSeconds
        self.insertion = insertion
    }
}

/// Local dictation history (newest first), persisted as JSON. PUBLIC API FROZEN — implementation owned by core agent.
@MainActor
@Observable
public final class HistoryStore {
    public private(set) var items: [HistoryItem] = []

    private let fileURL: URL?
    private let limit: Int

    /// - Parameters:
    ///   - fileURL: JSON file location; `nil` = in-memory only.
    ///   - limit: max items kept (oldest dropped).
    public init(fileURL: URL?, limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = max(0, limit)
        let loaded = JSONFileStore.load([HistoryItem].self, from: fileURL)
        items = Self.sorted(loaded, limit: self.limit)
    }

    public func append(_ item: HistoryItem) throws {
        items.insert(item, at: 0)
        items = Self.sorted(items, limit: limit)
        try persist()
    }

    public func delete(id: HistoryItem.ID) throws {
        items.removeAll { $0.id == id }
        try persist()
    }

    public func clear() throws {
        items = []
        try persist()
    }

    private func persist() throws {
        try JSONFileStore.save(items, to: fileURL)
    }

    /// Newest first, then enforce `limit` by dropping the oldest (tail) entries.
    private static func sorted(_ items: [HistoryItem], limit: Int) -> [HistoryItem] {
        let ordered = items.sorted { $0.createdAt > $1.createdAt }
        if ordered.count > limit {
            return Array(ordered.prefix(limit))
        }
        return ordered
    }
}
