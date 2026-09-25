import Foundation
import Observation

public struct DictionaryEntry: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var term: String
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), term: String, note: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.term = term
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Errors thrown by `DictionaryStore.add`/`update`. Internal — not part of the frozen contract.
public enum DictionaryStoreError: Error, Sendable, Equatable {
    /// `term` was empty after trimming whitespace.
    case emptyTerm
    /// `term` exceeded 100 characters.
    case termTooLong
    /// An entry with the same term already exists (case-insensitive). We choose to throw rather
    /// than silently no-op so callers (UI) can surface a clear "already in your dictionary" message.
    case duplicateTerm
}

/// Personal dictionary, persisted as JSON. PUBLIC API FROZEN — implementation owned by core agent.
@MainActor
@Observable
public final class DictionaryStore {
    public private(set) var entries: [DictionaryEntry] = []

    private let fileURL: URL?

    /// - Parameter fileURL: JSON file location; `nil` = in-memory only (tests, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        entries = Self.sorted(JSONFileStore.load([DictionaryEntry].self, from: fileURL))
    }

    /// Terms to send as transcription vocabulary.
    public var vocabulary: [String] { entries.map(\.term) }

    public func add(term: String, note: String? = nil) throws {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryStoreError.emptyTerm }
        guard trimmed.count <= 100 else { throw DictionaryStoreError.termTooLong }
        guard !entries.contains(where: { $0.term.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw DictionaryStoreError.duplicateTerm
        }
        entries.append(DictionaryEntry(term: trimmed, note: note))
        entries = Self.sorted(entries)
        try persist()
    }

    public func update(_ entry: DictionaryEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let trimmed = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryStoreError.emptyTerm }
        guard trimmed.count <= 100 else { throw DictionaryStoreError.termTooLong }
        guard !entries.contains(where: { $0.id != entry.id && $0.term.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw DictionaryStoreError.duplicateTerm
        }
        var updated = entry
        updated.term = trimmed
        updated.updatedAt = .now
        entries[index] = updated
        entries = Self.sorted(entries)
        try persist()
    }

    public func delete(id: DictionaryEntry.ID) throws {
        entries.removeAll { $0.id == id }
        try persist()
    }

    /// Merges `remote` entries into the local dictionary — last-write-wins by `id`. Approved as an
    /// additive public API (2026-09-26) for the app's dictionary sync code; not in the original
    /// frozen contract.
    ///
    /// For each remote entry:
    /// - Same `id` locally: keep whichever of the two has the later `updatedAt` (ties keep local,
    ///   to avoid an unnecessary write).
    /// - No `id` match, but a local entry has the same term (case-insensitive): keep whichever has
    ///   the later `updatedAt` (ties prefer remote), but the merged entry always adopts the
    ///   REMOTE id, so both devices converge on one id for that term.
    /// - No match at all: insert the remote entry as-is (id/createdAt/updatedAt preserved).
    ///
    /// Deletions are out of scope (TODO(P1): tombstones). Persists once at the end and keeps the
    /// usual sort order.
    public func merge(_ remote: [DictionaryEntry]) throws {
        guard !remote.isEmpty else { return }

        var indexByID: [DictionaryEntry.ID: Int] = [:]
        indexByID.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            indexByID[entry.id] = index
        }

        for remoteEntry in remote {
            if let index = indexByID[remoteEntry.id] {
                if remoteEntry.updatedAt > entries[index].updatedAt {
                    entries[index] = remoteEntry
                }
                continue
            }

            if let termIndex = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(remoteEntry.term) == .orderedSame }) {
                let local = entries[termIndex]
                if remoteEntry.updatedAt >= local.updatedAt {
                    entries[termIndex] = remoteEntry
                } else {
                    var converged = local
                    converged.id = remoteEntry.id
                    entries[termIndex] = converged
                }
                indexByID[remoteEntry.id] = termIndex
                continue
            }

            entries.append(remoteEntry)
            indexByID[remoteEntry.id] = entries.count - 1
        }

        entries = Self.sorted(entries)
        try persist()
    }

    private func persist() throws {
        try JSONFileStore.save(entries, to: fileURL)
    }

    private static func sorted(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.sorted { lhs, rhs in
            lhs.term.localizedCaseInsensitiveCompare(rhs.term) == .orderedAscending
        }
    }
}
