import Foundation
import Testing
@testable import ProsioCore

@Suite struct DictionaryStoreTests {

    @Test @MainActor func addTrimsAndSorts() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "  banana  ")
        try store.add(term: "Apple")
        try store.add(term: "cherry")
        #expect(store.entries.map(\.term) == ["Apple", "banana", "cherry"])
    }

    @Test @MainActor func addRejectsEmptyTerm() throws {
        let store = DictionaryStore(fileURL: nil)
        #expect(throws: DictionaryStoreError.self) {
            try store.add(term: "   ")
        }
        #expect(store.entries.isEmpty)
    }

    @Test @MainActor func addRejectsTermOver100Characters() throws {
        let store = DictionaryStore(fileURL: nil)
        let longTerm = String(repeating: "a", count: 101)
        #expect(throws: DictionaryStoreError.self) {
            try store.add(term: longTerm)
        }
        #expect(store.entries.isEmpty)
    }

    @Test @MainActor func addRejectsCaseInsensitiveDuplicate() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Prosio")
        #expect(throws: DictionaryStoreError.self) {
            try store.add(term: "prosio")
        }
        #expect(store.entries.count == 1)
    }

    @Test @MainActor func updateBumpsUpdatedAt() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Term")
        let original = store.entries[0]

        var edited = original
        edited.term = "Term Two"
        edited.updatedAt = original.updatedAt.addingTimeInterval(60) // simulate elapsed time
        try store.update(edited)

        let updated = store.entries.first { $0.id == original.id }
        #expect(updated?.term == "Term Two")
        #expect((updated?.updatedAt ?? .distantPast) > original.updatedAt)
    }

    @Test @MainActor func deleteRemovesEntry() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Keep")
        try store.add(term: "Remove")
        let toRemove = store.entries.first { $0.term == "Remove" }!
        try store.delete(id: toRemove.id)
        #expect(store.entries.map(\.term) == ["Keep"])
    }

    @Test @MainActor func vocabularyReflectsTerms() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Alpha")
        try store.add(term: "Beta")
        #expect(store.vocabulary == ["Alpha", "Beta"])
    }

    @Test @MainActor func persistsRoundTrip() throws {
        let fileURL = makeTempFileURL("dictionary.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store1 = DictionaryStore(fileURL: fileURL)
        try store1.add(term: "Hello")
        try store1.add(term: "World")

        let store2 = DictionaryStore(fileURL: fileURL)
        #expect(store2.entries.map(\.term) == ["Hello", "World"])
    }

    @Test @MainActor func corruptFileStartsEmptyWithoutCrashing() throws {
        let fileURL = makeTempFileURL("dictionary.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: fileURL)

        let store = DictionaryStore(fileURL: fileURL)
        #expect(store.entries.isEmpty)
    }

    @Test @MainActor func inMemoryStoreDoesNotTouchDisk() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Ephemeral")
        #expect(store.entries.count == 1)
    }

    @Test @MainActor func mergeInsertsBrandNewRemoteEntries() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Local")

        let remote = DictionaryEntry(term: "Remote", note: "from server")
        try store.merge([remote])

        #expect(store.entries.map(\.term) == ["Local", "Remote"])
        #expect(store.entries.first { $0.term == "Remote" }?.id == remote.id)
    }

    @Test @MainActor func mergeSameID_NewerRemoteWins() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Term")
        let local = store.entries[0]

        var remote = local
        remote.note = "updated remotely"
        remote.updatedAt = local.updatedAt.addingTimeInterval(60)
        try store.merge([remote])

        #expect(store.entries.count == 1)
        #expect(store.entries[0].note == "updated remotely")
        #expect(store.entries[0].id == local.id)
    }

    @Test @MainActor func mergeSameID_OlderRemoteLoses() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Term")
        let local = store.entries[0]

        var remote = local
        remote.note = "stale"
        remote.updatedAt = local.updatedAt.addingTimeInterval(-60)
        try store.merge([remote])

        #expect(store.entries.count == 1)
        #expect(store.entries[0].note == local.note) // unchanged, local kept
    }

    @Test @MainActor func mergeSameTermDifferentID_ConvergesOnRemoteID() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Prosio")
        let local = store.entries[0]

        // A different device created an entry for the same term (case-insensitive) under a
        // different id, with newer content — remote should win and we should adopt its id.
        let remote = DictionaryEntry(
            id: UUID(),
            term: "prosio",
            note: "remote note",
            createdAt: local.createdAt,
            updatedAt: local.updatedAt.addingTimeInterval(60)
        )
        try store.merge([remote])

        #expect(store.entries.count == 1)
        #expect(store.entries[0].id == remote.id)
        #expect(store.entries[0].note == "remote note")
    }

    @Test @MainActor func mergeSameTermDifferentID_OlderRemoteKeepsLocalContentButAdoptsRemoteID() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Prosio", note: "local note")
        let local = store.entries[0]

        let remote = DictionaryEntry(
            id: UUID(),
            term: "PROSIO",
            note: "stale remote note",
            createdAt: local.createdAt,
            updatedAt: local.updatedAt.addingTimeInterval(-60)
        )
        try store.merge([remote])

        #expect(store.entries.count == 1)
        // Local content wins (it's newer)...
        #expect(store.entries[0].note == "local note")
        // ...but the id converges to the remote's, so both devices agree going forward.
        #expect(store.entries[0].id == remote.id)
    }

    @Test @MainActor func mergeKeepsSortOrderAndPersistsOnce() throws {
        let fileURL = makeTempFileURL("dictionary.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = DictionaryStore(fileURL: fileURL)
        try store.add(term: "banana")

        try store.merge([
            DictionaryEntry(term: "Apple"),
            DictionaryEntry(term: "cherry")
        ])

        #expect(store.entries.map(\.term) == ["Apple", "banana", "cherry"])

        let reloaded = DictionaryStore(fileURL: fileURL)
        #expect(reloaded.entries.map(\.term) == ["Apple", "banana", "cherry"])
    }

    @Test @MainActor func mergeWithEmptyRemoteIsNoOp() throws {
        let store = DictionaryStore(fileURL: nil)
        try store.add(term: "Term")
        try store.merge([])
        #expect(store.entries.map(\.term) == ["Term"])
    }
}

@Suite struct HistoryStoreTests {

    @Test @MainActor func appendOrdersNewestFirst() throws {
        let store = HistoryStore(fileURL: nil)
        try store.append(HistoryItem(createdAt: Date(timeIntervalSince1970: 1), text: "a", engineID: "e", durationSeconds: 1, insertion: .pasted))
        try store.append(HistoryItem(createdAt: Date(timeIntervalSince1970: 3), text: "c", engineID: "e", durationSeconds: 1, insertion: .pasted))
        try store.append(HistoryItem(createdAt: Date(timeIntervalSince1970: 2), text: "b", engineID: "e", durationSeconds: 1, insertion: .pasted))
        #expect(store.items.map(\.text) == ["c", "b", "a"])
    }

    @Test @MainActor func limitDropsOldest() throws {
        let store = HistoryStore(fileURL: nil, limit: 2)
        try store.append(HistoryItem(createdAt: Date(timeIntervalSince1970: 1), text: "a", engineID: "e", durationSeconds: 1, insertion: .pasted))
        try store.append(HistoryItem(createdAt: Date(timeIntervalSince1970: 2), text: "b", engineID: "e", durationSeconds: 1, insertion: .pasted))
        try store.append(HistoryItem(createdAt: Date(timeIntervalSince1970: 3), text: "c", engineID: "e", durationSeconds: 1, insertion: .pasted))
        #expect(store.items.map(\.text) == ["c", "b"])
    }

    @Test @MainActor func deleteRemovesItem() throws {
        let store = HistoryStore(fileURL: nil)
        try store.append(HistoryItem(text: "a", engineID: "e", durationSeconds: 1, insertion: .pasted))
        let id = store.items[0].id
        try store.delete(id: id)
        #expect(store.items.isEmpty)
    }

    @Test @MainActor func clearRemovesAllItemsAndPersistsEmptyState() throws {
        let fileURL = makeTempFileURL("history.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = HistoryStore(fileURL: fileURL)
        try store.append(HistoryItem(text: "a", engineID: "e", durationSeconds: 1, insertion: .pasted))
        try store.clear()
        #expect(store.items.isEmpty)

        let reloaded = HistoryStore(fileURL: fileURL)
        #expect(reloaded.items.isEmpty)
    }

    @Test @MainActor func persistsRoundTrip() throws {
        let fileURL = makeTempFileURL("history.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store1 = HistoryStore(fileURL: fileURL)
        try store1.append(HistoryItem(text: "x", appBundleID: "com.test", appName: "Test", engineID: "e", durationSeconds: 2.5, insertion: .accessibility))

        let store2 = HistoryStore(fileURL: fileURL)
        #expect(store2.items.map(\.text) == ["x"])
        #expect(store2.items.first?.insertion == .accessibility)
        #expect(store2.items.first?.durationSeconds == 2.5)
    }

    @Test @MainActor func corruptFileStartsEmptyWithoutCrashing() throws {
        let fileURL = makeTempFileURL("history.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL)
        #expect(store.items.isEmpty)
    }
}
