import AVFoundation
import Foundation
import Testing

@MainActor
private struct RecordingHandoffDiscoveryStub: RecordingEditorApplicationDiscovering {
    let apps: [RecordingEditorApplication]
    func installedApplications() -> [RecordingEditorApplication] { apps }
}

@MainActor
private final class RecordingHandoffOpenerSpy: RecordingEditorApplicationOpening {
    var requests: [(URL, RecordingEditorApplication)] = []
    var failure: (any Error)?
    func open(document: URL, in application: RecordingEditorApplication) async throws {
        if let failure { throw failure }
        requests.append((document, application))
    }
}

@Suite("Editor handoff boundary")
@MainActor
struct RecordingEditorHandoffTests {
    @Test func explicitRequestTargetsChosenEditorAndDoesNotClaimImport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Timeline.fcpxml")
        try Data("<fcpxml version=\"1.10\"><resources/></fcpxml>".utf8).write(to: file)
        let app = application(.finalCutPro, id: "com.apple.FinalCut")
        let spy = RecordingHandoffOpenerSpy()
        let handoff = RecordingEditorHandoff(discovery: RecordingHandoffDiscoveryStub(apps: [app]), opener: spy)
        #expect(spy.requests.isEmpty)
        #expect(handoff.availability(for: .finalCutPro).canRequestOpen)
        let receipt = try await handoff.open(exportedFile: file, editor: .finalCutPro)
        #expect(spy.requests.count == 1)
        #expect(spy.requests[0].0 == file)
        #expect(spy.requests[0].1 == app)
        #expect(!receipt.importVerified)
        #expect(receipt.applicationVersion == "test-version")
    }

    @Test func missingWrongEditorMalformedOrOversizedFilesNeverLaunch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Timeline.xml")
        try Data("<xmeml version=\"5\"><sequence/></xmeml>".utf8).write(to: file)
        let spy = RecordingHandoffOpenerSpy()
        let missing = RecordingEditorHandoff(discovery: RecordingHandoffDiscoveryStub(apps: []), opener: spy)
        await #expect(throws: RecordingEditorHandoffError.editorNotInstalled(.premiere)) { try await missing.open(exportedFile: file, editor: .premiere) }
        let fake = application(.premiere, id: "com.apple.Safari")
        let wrong = RecordingEditorHandoff(discovery: RecordingHandoffDiscoveryStub(apps: [fake]), opener: spy)
        #expect(wrong.applications(for: .premiere).isEmpty)
        let premiere = application(.premiere, id: "com.adobe.PremierePro.26")
        let real = RecordingEditorHandoff(discovery: RecordingHandoffDiscoveryStub(apps: [premiere]), opener: spy)
        await #expect(throws: RecordingEditorHandoffError.invalidApplication) { try await real.open(exportedFile: file, editor: .premiere, application: fake) }
        try Data("<fcpxml/>".utf8).write(to: file)
        await #expect(throws: RecordingEditorHandoffError.incompatibleFormat) { try await real.open(exportedFile: file, editor: .premiere) }
        try Data("<xmeml".utf8).write(to: file)
        await #expect(throws: RecordingEditorHandoffError.invalidInterchange) { try await real.open(exportedFile: file, editor: .premiere) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 32_000_001); try handle.close()
        await #expect(throws: RecordingEditorHandoffError.invalidInterchange) { try await real.open(exportedFile: file, editor: .premiere) }
        #expect(spy.requests.isEmpty)
    }

    @Test func unverifiedJianyingAndMulticamHaveExplicitGates() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = RecordingHandoffOpenerSpy()
        let jianying = application(.jianying, id: "com.lemon.lvpro")
        let premiere = application(.premiere, id: "com.adobe.PremierePro.26")
        let handoff = RecordingEditorHandoff(discovery: RecordingHandoffDiscoveryStub(apps: [jianying, premiere]), opener: spy)
        #expect(!handoff.availability(for: .jianying).canRequestOpen)
        #expect(handoff.availability(for: .jianying).application == jianying)
        let json = root.appendingPathComponent("draft_content.json")
        try Data("{}".utf8).write(to: json)
        await #expect(throws: RecordingEditorHandoffError.unverifiedJianyingVersion("test-version")) { try await handoff.open(exportedFile: json, editor: .jianying) }
        let xml = root.appendingPathComponent("Multicam.xml")
        try Data("<xmeml version=\"5\"><sequence><media><video><track><clipitem><multiclip><name>Test</name><angle/></multiclip></clipitem></track></video></media></sequence></xmeml>".utf8).write(to: xml)
        await #expect(throws: RecordingEditorHandoffError.unverifiedMulticamRequiresExplicitChoice) { try await handoff.open(exportedFile: xml, editor: .premiere) }
        #expect(spy.requests.isEmpty)
        let receipt = try await handoff.open(exportedFile: xml, editor: .premiere, allowExperimentalMulticam: true)
        #expect(spy.requests.count == 1)
        #expect(!receipt.importVerified)
    }

    @Test func openerFailurePropagatesAndDiscoveryReadsBundleIdentities() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Adobe Premiere Pro/Adobe Premiere Pro.app")
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.adobe.PremierePro.26", "CFBundleShortVersionString": "26.0", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let discovered = RecordingWorkspaceEditorDiscovery(roots: [root]).installedApplications()
        #expect(discovered.count == 1)
        #expect(discovered.first?.version == "26.0")
        let spy = RecordingHandoffOpenerSpy(); spy.failure = CocoaError(.fileReadNoPermission)
        let file = root.appendingPathComponent("Timeline.xml")
        try Data("<xmeml version=\"5\"/>".utf8).write(to: file)
        let handoff = RecordingEditorHandoff(discovery: RecordingHandoffDiscoveryStub(apps: discovered), opener: spy)
        await #expect(throws: CocoaError.self) { try await handoff.open(exportedFile: file, editor: .premiere) }
        #expect(spy.requests.isEmpty)
    }

    @Test func nativeCandidatePreservesRecoveredAnglesAndIndependentStereoAudio() throws {
        let screen = RecordingSource(id: "screen", kind: .screen, name: "屏幕 & 演示")
        let camera = RecordingSource(id: "camera", kind: .camera, name: "机位")
        let mic = RecordingSource(id: "mic", kind: .microphone, name: "麦克风")
        let segments = [RecordingSegment(sourceID: screen.id, relativePath: "screen.mov", timelineStartMicroseconds: 123_456, durationMicroseconds: 2_000_000), RecordingSegment(sourceID: screen.id, relativePath: "recovered.mov", timelineStartMicroseconds: 4_000_000, durationMicroseconds: 2_000_000), RecordingSegment(sourceID: camera.id, relativePath: "camera.mov", timelineStartMicroseconds: 0, durationMicroseconds: 6_000_000), RecordingSegment(sourceID: mic.id, relativePath: "mic.wav", timelineStartMicroseconds: 0, durationMicroseconds: 6_000_000)]
        let sources = [screen, camera, mic]
        let session = RecordingSessionManifest(title: "示例", phase: .ready, sources: sources, segments: segments)
        let media = segments.map { segment in RecordingMediaInfo(segment: segment, source: sources.first { $0.id == segment.sourceID }!, url: URL(fileURLWithPath: "/tmp/\(segment.relativePath)"), duration: CMTime(value: 6, timescale: 1), width: 1920, height: 1080, frameDuration: CMTime(value: 1001, timescale: 30_000), sampleRate: 48_000, channels: segment.sourceID == mic.id ? 2 : nil) }
        let candidate = try RecordingPremiereMulticamAdapter.candidate(session: session, media: media)
        let xml = try XMLDocument(data: candidate)
        #expect(try xml.nodes(forXPath: "/xmeml/sequence/media/video/track").count == 1)
        #expect(try xml.nodes(forXPath: "//multiclip/angle").count == 2)
        #expect(try xml.nodes(forXPath: "//multiclip/collapsed").first?.stringValue == "FALSE")
        #expect(try xml.nodes(forXPath: "//multiclip/angle[1]//sequence/media/video/track/clipitem").count == 2)
        #expect(try xml.nodes(forXPath: "//multiclip/angle[1]//sequence/media/video/track/clipitem[2]/start").first?.stringValue == "120")
        #expect(try xml.nodes(forXPath: "/xmeml/sequence/media/audio/track").count == 2)
        #expect(try xml.nodes(forXPath: "/xmeml/sequence/media/audio/track[2]/clipitem/sourcetrack/trackindex").first?.stringValue == "2")
    }

    @Test func mixedFrameRatesKeepSourceRangesDistinctFromTimelinePlacement() throws {
        let screen = RecordingSource(id: "screen", kind: .screen, name: "Screen")
        let camera = RecordingSource(id: "camera", kind: .camera, name: "Camera")
        let segments = [RecordingSegment(sourceID: screen.id, relativePath: "screen.mov", timelineStartMicroseconds: 0, durationMicroseconds: 2_000_000), RecordingSegment(sourceID: camera.id, relativePath: "camera.mov", timelineStartMicroseconds: 1_000_000, mediaStartMicroseconds: 1_000_000, durationMicroseconds: 2_000_000)]
        let session = RecordingSessionManifest(title: "Mixed rates", sources: [screen, camera], segments: segments)
        let media = [RecordingMediaInfo(segment: segments[0], source: screen, url: URL(fileURLWithPath: "/tmp/screen.mov"), duration: CMTime(value: 4, timescale: 1), width: 1920, height: 1080, frameDuration: CMTime(value: 1001, timescale: 30_000), sampleRate: nil, channels: nil), RecordingMediaInfo(segment: segments[1], source: camera, url: URL(fileURLWithPath: "/tmp/camera.mov"), duration: CMTime(value: 4, timescale: 1), width: 1920, height: 1080, frameDuration: CMTime(value: 1, timescale: 25), sampleRate: nil, channels: nil)]
        let xml = try XMLDocument(data: RecordingProjectExporter.fcp7XML(session: session, media: media))
        let cameraNode = try #require(try xml.nodes(forXPath: "/xmeml/sequence/media/video/track[2]/clipitem").first)
        #expect(try cameraNode.nodes(forXPath: "start").first?.stringValue == "30")
        #expect(try cameraNode.nodes(forXPath: "end").first?.stringValue == "90")
        #expect(try cameraNode.nodes(forXPath: "in").first?.stringValue == "25")
        #expect(try cameraNode.nodes(forXPath: "out").first?.stringValue == "75")
        #expect(try cameraNode.nodes(forXPath: "file/rate/timebase").first?.stringValue == "25")
        #expect(try cameraNode.nodes(forXPath: "file/duration").first?.stringValue == "100")
    }

    private func application(_ editor: RecordingEditor, id: String) -> RecordingEditorApplication { RecordingEditorApplication(editor: editor, url: URL(fileURLWithPath: "/Applications/Test-\(editor.rawValue).app"), bundleIdentifier: id, version: "test-version") }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prosio-handoff-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
