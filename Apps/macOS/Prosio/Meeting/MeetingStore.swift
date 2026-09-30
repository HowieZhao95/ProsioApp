import Foundation
import Observation

struct MeetingUtterance: Codable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var speaker: String?
    var source: String
}

struct MeetingRecord: Codable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable { case recording, processing, ready, failed }
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var phase: Phase
    var microphoneFile: String?
    var systemFile: String?
    var playbackFile: String?
    var systemOffset: Double?
    var local: [MeetingUtterance] = []
    var cloud: [MeetingUtterance] = []
    var cloudStatus: String?
    var error: String?
    var cloudError: String?
    var title: String { startedAt.formatted(date: .abbreviated, time: .shortened) }
}

@Observable
final class MeetingStore {
    private(set) var records: [MeetingRecord] = []
    let root: URL

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func directory(for id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }

    func create() throws -> MeetingRecord {
        let record = MeetingRecord(id: UUID(), startedAt: .now, phase: .recording)
        try FileManager.default.createDirectory(at: directory(for: record.id), withIntermediateDirectories: true)
        try save(record)
        return record
    }

    func save(_ record: MeetingRecord) throws {
        let directory = directory(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.insert(record, at: 0) }
        records.sort { $0.startedAt > $1.startedAt }
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        records = directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appending(path: "manifest.json")),
                  var record = try? decoder.decode(MeetingRecord.self, from: data) else { return nil }
            // An interrupted process must never leave a meeting claiming to be recording forever.
            if record.phase == .recording || record.phase == .processing {
                record.phase = .failed
                record.error = "处理被中断；已保存的录音仍可在会议文件夹中找到。"
                try? encoderData(record).write(to: directory.appending(path: "manifest.json"), options: .atomic)
            }
            if record.cloudStatus == "processing" {
                record.cloudStatus = "failed"
                record.cloudError = "云端处理被中断；可重新上传或检查任务。"
                try? encoderData(record).write(to: directory.appending(path: "manifest.json"), options: .atomic)
            }
            return record
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private func encoderData(_ record: MeetingRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }
}
