import Foundation
import Testing
@testable import ProsioCore

@Suite struct DropDetectionTests {

    @Test func flagsCloudMuchShorterThanLocal() {
        let local = String(repeating: "字", count: 30) // 30 chars, well over the 12-char floor
        let cloud = String(repeating: "字", count: 10) // 10/30 = 0.33 < 0.55
        #expect(DropDetection.isSuspectedDrop(localText: local, cloudText: cloud))
    }

    @Test func doesNotFlagComparableLengths() {
        let local = String(repeating: "字", count: 30)
        let cloud = String(repeating: "字", count: 28) // 28/30 = 0.93, well above the ratio floor
        #expect(!DropDetection.isSuspectedDrop(localText: local, cloudText: cloud))
    }

    @Test func doesNotFlagWhenLocalTooShort() {
        // Local under the 12-char floor even though the ratio would otherwise trip.
        let local = "hi there"
        let cloud = "h"
        #expect(!DropDetection.isSuspectedDrop(localText: local, cloudText: cloud))
    }

    @Test func ignoresPunctuationAndWhitespaceWhenComparing() {
        // Same "real" content, just formatted differently — must not falsely flag.
        let local = "hello, world! this is a test."
        let cloud = "helloworldthisisatest"
        #expect(!DropDetection.isSuspectedDrop(localText: local, cloudText: cloud))
    }

    @Test func nilTextsNeverFlag() {
        #expect(!DropDetection.isSuspectedDrop(localText: nil, cloudText: "anything"))
        #expect(!DropDetection.isSuspectedDrop(localText: "anything at all here", cloudText: nil))
    }
}

@Suite struct WAVFileTests {

    @Test func producesValidRIFFHeaderForPCM16Mono16k() {
        let samples = Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00]) // 3 Int16 samples, 6 bytes
        let wav = WAVFile.make(pcm16: samples, sampleRate: 16_000)

        #expect(wav.count == 44 + samples.count)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[8..<12] == Data("WAVE".utf8))
        #expect(wav[12..<16] == Data("fmt ".utf8))
        #expect(wav[36..<40] == Data("data".utf8))

        let dataSize = wav[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        #expect(Int(dataSize) == samples.count)

        let sampleRateField = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        #expect(sampleRateField == 16_000)

        #expect(wav.suffix(samples.count) == samples)
    }

    @Test func handlesEmptyAudio() {
        let wav = WAVFile.make(pcm16: Data(), sampleRate: 16_000)
        #expect(wav.count == 44)
    }
}

@Suite struct DebugRecordingWriterTests {

    private func makeRecord(sessionID: UUID, createdAt: Date, suspectedDrop: Bool = false) -> DebugSessionRecord {
        DebugSessionRecord(
            sessionID: sessionID.uuidString,
            createdAt: createdAt,
            mode: "auto",
            localEngineID: "apple.speechanalyzer",
            cloudEngineID: "gateway.gemini-3.5-transcribe",
            engineIDUsed: "gateway.gemini-3.5-transcribe",
            localFinalText: "local text",
            cloudFinalText: "cloud text",
            insertedText: "cloud text",
            outcome: "pasted",
            audioDurationSeconds: 3.2,
            suspectedDrop: suspectedDrop,
            timings: DebugSessionRecord.Timings(
                startToMicOpenMs: 12,
                micOpenToFirstChunkMs: 40,
                firstChunkToFirstLocalPartialMs: 200,
                stopToFinalReceivedMs: 2400,
                finalReceivedToInsertionDoneMs: 15
            )
        )
    }

    @Test func writesAudioAndSessionJSON() throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let createdAt = Date()
        let record = makeRecord(sessionID: sessionID, createdAt: createdAt, suspectedDrop: true)
        let pcm = Data([0x11, 0x22, 0x33, 0x44])

        DebugRecordingWriter.write(root: root, sessionID: sessionID, record: record, pcm16: pcm, sampleRate: 16_000)

        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let sessionDir = try #require(entries.first { $0.lastPathComponent.contains(sessionID.uuidString) })

        let wavData = try Data(contentsOf: sessionDir.appendingPathComponent("audio.wav"))
        #expect(wavData.count == 44 + pcm.count)
        #expect(wavData.suffix(pcm.count) == pcm)

        let jsonData = try Data(contentsOf: sessionDir.appendingPathComponent("session.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DebugSessionRecord.self, from: jsonData)
        #expect(decoded.sessionID == sessionID.uuidString)
        #expect(decoded.localFinalText == "local text")
        #expect(decoded.cloudFinalText == "cloud text")
        #expect(decoded.insertedText == "cloud text")
        #expect(decoded.outcome == "pasted")
        #expect(decoded.suspectedDrop == true)
        #expect(decoded.timings.stopToFinalReceivedMs == 2400)
    }

    @Test func prunesToKeepOnlyTheNewestSessions() throws {
        let root = makeTempFileURL("debug").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var writtenIDs: [UUID] = []
        for i in 0..<33 {
            let sessionID = UUID()
            writtenIDs.append(sessionID)
            let createdAt = base.addingTimeInterval(TimeInterval(i)) // strictly increasing -> increasing ISO timestamps
            let record = makeRecord(sessionID: sessionID, createdAt: createdAt)
            DebugRecordingWriter.write(root: root, sessionID: sessionID, record: record, pcm16: Data(), sampleRate: 16_000, keepLast: 30)
        }

        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(entries.count == 30)

        // The oldest 3 sessions must be gone; the newest 30 must remain.
        let remainingNames = Set(entries.map(\.lastPathComponent))
        for staleID in writtenIDs.prefix(3) {
            #expect(!remainingNames.contains { $0.contains(staleID.uuidString) })
        }
        for freshID in writtenIDs.suffix(30) {
            #expect(remainingNames.contains { $0.contains(freshID.uuidString) })
        }
    }

    @Test func doesNotThrowOrCrashOnWriteFailure() {
        // A root that can't possibly be created (parent is a file, not a directory) — the writer
        // must swallow the error rather than propagate or crash.
        let bogusParent = makeTempFileURL("not-a-directory")
        defer { try? FileManager.default.removeItem(at: bogusParent.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(at: bogusParent.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bogusParent.path, contents: Data())

        let badRoot = bogusParent.appendingPathComponent("debug")
        let record = makeRecord(sessionID: UUID(), createdAt: Date())
        DebugRecordingWriter.write(root: badRoot, sessionID: UUID(), record: record, pcm16: Data(), sampleRate: 16_000)
        // No crash/throw reaching here is the assertion.
    }
}
