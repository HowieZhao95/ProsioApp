import Foundation

/// Shared JSON-file persistence helpers for `DictionaryStore` and `HistoryStore`.
/// Not part of the public contract — internal implementation detail.
enum JSONFileStore {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Loads and decodes `[T]` from `fileURL`. Returns an empty array when the file is missing,
    /// unreadable, or contains corrupt/undecodable JSON — callers must never crash on a bad file.
    static func load<T: Decodable>(_ type: [T].Type, from fileURL: URL?) -> [T] {
        guard let fileURL else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? makeDecoder().decode([T].self, from: data) else { return [] }
        return decoded
    }

    /// Atomically writes `items` as JSON to `fileURL`, creating the parent directory if needed.
    /// No-op when `fileURL` is nil (in-memory only).
    static func save<T: Encodable>(_ items: [T], to fileURL: URL?) throws {
        guard let fileURL else { return }
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let data = try makeEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }
}
