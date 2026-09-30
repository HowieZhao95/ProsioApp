import Foundation
import Testing

@Suite("Meeting persistence")
@MainActor
struct MeetingStoreTests {
    @Test func interruptedMeetingCanBeFoundAndRecovered() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "meeting-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var record = try store.create()
        let recording = store.directory(for: record.id).appending(path: "microphone.caf")
        try Data([1, 2, 3]).write(to: recording)
        record.microphoneFile = recording.lastPathComponent
        try store.save(record)

        let reopened = MeetingStore(root: root)
        let recovered = try #require(reopened.records.first)
        #expect(recovered.id == record.id)
        #expect(recovered.phase == .failed)
        #expect(FileManager.default.fileExists(atPath: recording.path))
    }
}
