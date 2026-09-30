import Foundation
import Testing

@Suite("Recording storage")
@MainActor
struct RecordingStoreTests {
    @Test func configurationBoundsAndSourceKindsAreValidated() throws {
        let screen = RecordingScreenTarget.display(1)
        let tooMany = RecordingConfiguration(screenTarget: screen, cameras: [camera("a"), camera("b"), camera("c")])
        #expect(throws: RecordingConfigurationError.tooManyCameras) { try tooMany.validate() }

        let duplicate = RecordingConfiguration(screenTarget: screen, cameras: [camera("same"), camera("same")])
        #expect(throws: RecordingConfigurationError.duplicateSourceID("same")) { try duplicate.validate() }

        let reserved = RecordingConfiguration(screenTarget: screen, cameras: [camera("systemAudio")])
        #expect(throws: RecordingConfigurationError.duplicateSourceID("systemAudio")) { try reserved.validate() }

        let wrongKind = RecordingConfiguration(screenTarget: screen, cameras: [
            RecordingSource(id: "mic", kind: .microphone, name: "Mic")
        ])
        #expect(throws: RecordingConfigurationError.invalidSourceKind("mic")) { try wrongKind.validate() }

        let invalidRegion = RecordingConfiguration(screenTarget: .region(
            displayID: 1,
            rect: RecordingRegion(x: 0, y: 0, width: .infinity, height: 10)
        ))
        #expect(throws: RecordingConfigurationError.invalidRegion) { try invalidRegion.validate() }

        #expect(throws: RecordingConfigurationError.invalidFrameRate) {
            try RecordingConfiguration(screenTarget: screen, framesPerSecond: 120).validate()
        }
        #expect(throws: RecordingConfigurationError.invalidSegmentDuration) {
            try RecordingConfiguration(screenTarget: screen, segmentDurationSeconds: .nan).validate()
        }
        try RecordingConfiguration(screenTarget: screen).validate()
    }

    @Test func independentSessionsPersistSegmentsAndDerivedDuration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        let config = RecordingConfiguration(screenTarget: .display(1), cameras: [camera("usb-1")])
        let first = try store.create(configuration: config)
        let second = try store.create(configuration: RecordingConfiguration(screenTarget: .window(3)))
        #expect(first.id != second.id)
        #expect(store.sessions.count == 2)

        let mediaFolder = store.directory(for: first.id).appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let clip = mediaFolder.appendingPathComponent("screen-000.mov")
        try Data([0, 1, 2, 3]).write(to: clip)
        let segment = RecordingSegment(
            sourceID: "screen",
            relativePath: "media/screen-000.mov",
            timelineStartMicroseconds: 2_000_000,
            durationMicroseconds: 4_500_000,
            width: 1920,
            height: 1080
        )
        try store.appendSegment(segment, to: first.id)
        #expect(store.sessions.first(where: { $0.id == first.id })?.durationMicroseconds == 6_500_000)

        let reopened = RecordingStore(root: root)
        #expect(reopened.sessions.count == 2)
        #expect(reopened.sessions.first(where: { $0.id == first.id })?.segments == [segment])
        #expect(FileManager.default.fileExists(atPath: clip.path))
    }

    @Test func activePhasesRecoverAsInterruptedAndKeepMedia() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        var session = try store.create(configuration: RecordingConfiguration(screenTarget: .display(1)))
        session.phase = .recording
        let partial = store.directory(for: session.id).appendingPathComponent("screen.partial.mov")
        try Data([1, 2, 3]).write(to: partial)
        session.segments = [RecordingSegment(
            sourceID: "screen",
            relativePath: "screen.partial.mov",
            timelineStartMicroseconds: 0,
            durationMicroseconds: 10
        )]
        try store.save(session)

        let reopened = RecordingStore(root: root)
        let recovered = try #require(reopened.sessions.first)
        #expect(recovered.phase == .interrupted)
        #expect(recovered.warnings.contains { $0.contains("尚未完成") })
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(recovered.segments.count == 1)
    }

    @Test func traversalAndSymlinkEscapeAreRejectedWithoutDeletingFiles() throws {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = RecordingStore(root: root)
        let session = try store.create(configuration: RecordingConfiguration(screenTarget: .display(1)))
        let traversal = RecordingSegment(sourceID: "screen", relativePath: "../outside.mov", timelineStartMicroseconds: 0, durationMicroseconds: 1)
        #expect(throws: RecordingStoreError.unsafeRelativePath("../outside.mov")) {
            try store.save(RecordingSessionManifest(id: session.id, title: "unsafe", sources: session.sources, segments: [traversal]))
        }

        let media = store.directory(for: session.id).appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        let symlinkEscape = RecordingSegment(sourceID: "screen", relativePath: "media/clip.mov", timelineStartMicroseconds: 0, durationMicroseconds: 1)
        #expect(throws: RecordingStoreError.unsafeRelativePath("media/clip.mov")) {
            try store.save(RecordingSessionManifest(id: session.id, title: "unsafe", sources: session.sources, segments: [symlinkEscape]))
        }
        #expect(FileManager.default.fileExists(atPath: media.path))
    }

    @Test func recoveryDropsMissingMediaFromPlayableListAndReportsIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        let session = try store.create(configuration: RecordingConfiguration(screenTarget: .display(1)))
        let media = store.directory(for: session.id).appendingPathComponent("screen.mov")
        try Data([1, 2, 3]).write(to: media)
        let segment = RecordingSegment(sourceID: "screen", relativePath: "screen.mov", timelineStartMicroseconds: 0, durationMicroseconds: 2_000_000)
        try store.appendSegment(segment, to: session.id)
        try FileManager.default.removeItem(at: media)

        let reopened = RecordingStore(root: root)
        let recovered = try #require(reopened.sessions.first)
        #expect(recovered.segments.isEmpty)
        #expect(recovered.warnings.contains { $0.contains("缺失或为空") })
        #expect(reopened.warnings.contains { $0.contains("缺失或为空") })
    }

    @Test func unsupportedAndMalformedManifestsArePreservedWithWarnings() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsupportedID = UUID()
        let malformedID = UUID()
        let unsupportedDir = root.appendingPathComponent(unsupportedID.uuidString, isDirectory: true)
        let malformedDir = root.appendingPathComponent(malformedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unsupportedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: malformedDir, withIntermediateDirectories: true)
        let unsupported = RecordingSessionManifest(schemaVersion: 7, id: unsupportedID, title: "future", sources: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unsupported).write(to: unsupportedDir.appendingPathComponent("manifest.json"))
        try Data("{not json".utf8).write(to: malformedDir.appendingPathComponent("manifest.json"))

        let store = RecordingStore(root: root)
        #expect(store.sessions.isEmpty)
        #expect(store.warnings.count == 2)
        #expect(FileManager.default.fileExists(atPath: unsupportedDir.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: malformedDir.appendingPathComponent("manifest.json").path))
    }

    private func camera(_ id: String) -> RecordingSource {
        RecordingSource(id: id, kind: .camera, name: id)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recording-store-\(UUID().uuidString)", isDirectory: true)
    }
}
