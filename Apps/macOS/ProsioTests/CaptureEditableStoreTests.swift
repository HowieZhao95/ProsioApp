import CoreGraphics
import Foundation
import ImageIO
import Testing

nonisolated private final class CaptureDocumentSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    func checkpoint() { lock.withLock { entered = true }; release.wait() }
    var hasEntered: Bool { lock.withLock { entered } }
}

@Suite("Capture editable persistence")
@MainActor
struct CaptureEditableStoreTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureEditableStoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func document() throws -> EditableCaptureDocument {
        let annotation = CaptureEditorTestPixels.redaction()
        let outside = CaptureEditorTestPixels.redaction(rect: CGRect(x: 32, y: 26, width: 4, height: 3))
        return EditableCaptureDocument(baseImage: try CaptureEditorTestPixels.image(), snapshot: EditorSnapshot(cropRect: CGRect(x: 5, y: 4, width: 20, height: 16), annotations: [annotation, outside], selectedAnnotationIDs: [annotation.id]), kind: .region, sourceName: "Synthetic frozen display", sourceRect: CGRect(x: -100, y: -50, width: 20, height: 16), capturedAt: Date(timeIntervalSince1970: 100))
    }
    private func loadImage(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    @Test("Restriction writes only crop source pixels and translates related geometry without UI selection")
    func restriction() throws {
        let original = try document(), restricted = try original.restrictedToSelection()
        #expect(restricted.baseImage.width == 20); #expect(restricted.baseImage.height == 16)
        #expect(restricted.snapshot.cropRect == CGRect(x: 0, y: 0, width: 20, height: 16))
        #expect(restricted.sourceRect == CGRect(x: -97.5, y: -48, width: 10, height: 8))
        #expect(restricted.snapshot.selectedAnnotationIDs.isEmpty)
        #expect(restricted.snapshot.annotations == [original.snapshot.annotations[0].translated(by: CGSize(width: -5, height: -4))])
        #expect(try CaptureEditorTestPixels.pixel(restricted.baseImage, x: 0, y: 0) == CaptureEditorTestPixels.pixel(original.baseImage, x: 5, y: 4))
        #expect(try CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: original.baseImage, snapshot: original.snapshot)) == CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: restricted.baseImage, snapshot: restricted.snapshot)))
    }
    @Test("V2 fresh reopen retains editable geometry and exact flattened output while discarding full desktop")
    func v2Reopen() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), store = CaptureAssetStore(rootURL: url)
        let expected = try EditorRenderer.render(baseImage: input.baseImage, snapshot: input.snapshot)
        let asset = try await store.saveDocument(input)
        #expect(asset.version == 2); #expect(asset.pixelWidth == 20); #expect(asset.pixelHeight == 16)
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets == [asset]); #expect(reopened.recoveryWarnings.isEmpty)
        let loaded = try reopened.loadDocument(asset)
        #expect(try loaded.snapshot == input.restrictedToSelection().snapshot)
        #expect(loaded.baseImage.width == 20); #expect(loaded.baseImage.height == 16)
        let flattened = try loadImage(reopened.imageURL(for: asset))
        #expect(try CaptureEditorTestPixels.rgba(flattened) == CaptureEditorTestPixels.rgba(expected))
        #expect(try CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: loaded.baseImage, snapshot: loaded.snapshot)) == CaptureEditorTestPixels.rgba(expected))
        // Underlying crop stays editable locally, while the standalone public PNG has redaction baked in.
        #expect(try CaptureEditorTestPixels.pixel(loaded.baseImage, x: 4, y: 4) != CaptureEditorTestPixels.pixel(flattened, x: 4, y: 4))
        let contents = try FileManager.default.contentsOfDirectory(atPath: reopened.imageURL(for: asset).deletingLastPathComponent().path)
        #expect(Set(contents) == Set(["image.png", "source.png", "document.json", "asset.json"]))
    }
    @Test("Completed history restores the full frozen screen, original crop, and every annotation")
    func fullScreenHistory() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), store = CaptureAssetStore(rootURL: url)
        let asset = try await CaptureOutputTransaction.perform(document: input, store: store) { _ in }
        #expect(asset.version == 3)
        #expect(asset.pixelWidth == 20 && asset.pixelHeight == 16)
        let reopened = CaptureAssetStore(rootURL: url)
        let restored = try reopened.loadDocument(asset)
        #expect(restored.baseImage.width == input.baseImage.width)
        #expect(restored.baseImage.height == input.baseImage.height)
        #expect(restored.snapshot.cropRect == input.snapshot.cropRect)
        #expect(restored.snapshot.annotations == input.snapshot.annotations)
        #expect(restored.sourceRect == input.sourceRect)
        #expect(try CaptureEditorTestPixels.rgba(restored.baseImage) == CaptureEditorTestPixels.rgba(input.baseImage))
        let output = try loadImage(reopened.imageURL(for: asset))
        let expected = try EditorRenderer.render(baseImage: input.baseImage, snapshot: input.snapshot)
        #expect(try CaptureEditorTestPixels.rgba(output) == CaptureEditorTestPixels.rgba(expected))
        let source = FrozenCaptureSource(id:UUID(),image:restored.baseImage,
            display:DisplaySnapshot(displayID:0,name:"Test",frame:CGRect(x:0,y:0,width:40,height:32),overlayFrame:CGRect(x:0,y:0,width:40,height:32),scale:1),
            sourceRect:restored.sourceRect,overlayRect:CGRect(x:0,y:0,width:40,height:32),kind:restored.kind,name:restored.sourceName,capturedAt:restored.capturedAt)
        let session = CaptureEditingSession(sources:[source],snapshotID:UUID(),candidates:[],initialSource:0,initialSnapshot:restored.snapshot)
        session.setCrop(CGRect(x:0,y:0,width:40,height:32))
        #expect(session.snapshot?.annotations == input.snapshot.annotations)
        #expect(try session.document().baseImage.width == 40)
    }
    @Test("Legacy v1 PNG opens as editable whole-image document without inventing annotations")
    func v1Compatibility() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let base = try CaptureEditorTestPixels.image(), store = CaptureAssetStore(rootURL: url)
        let screenshot = CapturedScreenshot(image: base, kind: .window, sourceName: "Legacy", sourceRect: CGRect(x: -100, y: 10, width: 20, height: 16), capturedAt: Date(timeIntervalSince1970: 10))
        let asset = try await store.save(screenshot)
        let loaded = try CaptureAssetStore(rootURL: url).loadDocument(asset)
        #expect(loaded.snapshot.cropRect == CGRect(x: 0, y: 0, width: 40, height: 32))
        #expect(loaded.snapshot.annotations.isEmpty)
        #expect(loaded.sourceRect == screenshot.sourceRect)
        #expect(try CaptureEditorTestPixels.rgba(loaded.baseImage) == CaptureEditorTestPixels.rgba(base))
    }
    @Test("Document metadata write failure leaves earlier history and current editing unchanged")
    func v2WriteFailure() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), existingStore = CaptureAssetStore(rootURL: url)
        let existing = try await existingStore.saveDocument(input)
        let failing = CaptureAssetStore(rootURL: url, afterPNGWritten: { pending in
            try FileManager.default.createDirectory(at: pending.appendingPathComponent("document.json"), withIntermediateDirectories: false)
        })
        let history = EditorHistory(snapshot: input.snapshot)
        do { _ = try await failing.saveDocument(input); Issue.record("Blocked document manifest unexpectedly committed") } catch {}
        #expect(failing.assets == [existing]); #expect(history.snapshot == input.snapshot)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == [existing.id.uuidString + ".prosiocapture"])
        #expect(CaptureAssetStore(rootURL: url).assets == [existing])
    }
    @Test("V2 cancellation after flattened PNG leaves no new source or history item")
    func v2CancelMidWrite() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), original = CaptureAssetStore(rootURL: url)
        let existing = try await original.saveDocument(input)
        let gate = CaptureDocumentSaveGate(); defer { gate.release.signal() }
        let store = CaptureAssetStore(rootURL: url, afterPNGWritten: { _ in gate.checkpoint() })
        let task = Task { @MainActor in try await store.saveDocument(input) }
        var reached = false
        for _ in 0..<400 { if gate.hasEntered { reached = true; break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(reached)
        if !reached { task.cancel(); return }
        task.cancel(); gate.release.signal()
        do { _ = try await task.value; Issue.record("Cancelled document unexpectedly committed") } catch { #expect(error is CancellationError) }
        #expect(store.assets == [existing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == [existing.id.uuidString + ".prosiocapture"])
        #expect(CaptureAssetStore(rootURL: url).assets == [existing])
    }
    @Test("Damaged v2 editable metadata is preserved and excluded with a recovery warning")
    func damagedV2Document() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url), asset = try await store.saveDocument(document())
        let manifest = store.imageURL(for: asset).deletingLastPathComponent().appendingPathComponent("document.json")
        try Data("broken JSON".utf8).write(to: manifest)
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets.isEmpty); #expect(reopened.recoveryWarnings.count == 1)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
    @Test("Saving a crop that intersects only rectangle stroke preserves the visible border on reopen")
    func strokeOnlyIntersection() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let base = try CaptureEditorTestPixels.image()
        var style = AnnotationStyle(); style.lineWidth = 8; style.strokeColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        let annotation = Annotation(id: UUID(), kind: .rectangle(RectangleShape(rect: CGRect(x: 10, y: 8, width: 12, height: 12))), style: style)
        let document = EditableCaptureDocument(baseImage: base, snapshot: EditorSnapshot(cropRect: CGRect(x: 6, y: 10, width: 3, height: 8), annotations: [annotation]), kind: .region, sourceName: "stroke only", sourceRect: CGRect(x: 0, y: 0, width: 40, height: 32), capturedAt: .now)
        let expected = try EditorRenderer.render(baseImage: base, snapshot: document.snapshot)
        let store = CaptureAssetStore(rootURL: url), asset = try await store.saveDocument(document)
        let reopened = try CaptureAssetStore(rootURL: url).loadDocument(asset)
        #expect(reopened.snapshot.annotations.count == 1)
        #expect(try CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: reopened.baseImage, snapshot: reopened.snapshot)) == CaptureEditorTestPixels.rgba(expected))
        #expect(try CaptureEditorTestPixels.pixel(expected, x: 1, y: 3)[0] > 240)
    }

    @Test("Mismatched source dimensions and inconsistent editable crop are rejected rather than reopening a different image")
    func inconsistentV2Dimensions() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let wrongSource = try await store.saveDocument(document())
        let wrongCrop = try await store.saveDocument(document())
        let sourceURL = store.imageURL(for: wrongSource).deletingLastPathComponent().appendingPathComponent("source.png")
        try CaptureAssetStore.writePNG(CaptureEditorTestPixels.image(), to: sourceURL)
        let docURL = store.imageURL(for: wrongCrop).deletingLastPathComponent().appendingPathComponent("document.json")
        try JSONEncoder().encode(EditableCaptureManifest(version: 2, snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 10, height: 8)))).write(to: docURL)
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets.isEmpty); #expect(reopened.recoveryWarnings.count == 2)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path)); #expect(FileManager.default.fileExists(atPath: docURL.path))
    }

    @Test("Failed external output rolls back only its newly persisted history asset")
    func outputTransactionRollback() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), store = CaptureAssetStore(rootURL: url)
        let existing = try await store.saveDocument(input)
        do { _ = try await CaptureOutputTransaction.perform(document: input, store: store) { _ in throw CaptureStoreError.imageEncodingFailed }; Issue.record("External failure unexpectedly succeeded") }
        catch { #expect(error is CaptureOutputFailure) }
        #expect(store.assets == [existing]); #expect(CaptureAssetStore(rootURL: url).assets == [existing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == [existing.id.uuidString + ".prosiocapture"])
    }
    @Test("Successful external output retains precisely the committed asset passed to it")
    func outputTransactionSuccess() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), store = CaptureAssetStore(rootURL: url)
        var exportedID: UUID?
        let result = try await CaptureOutputTransaction.perform(document: input, store: store) { asset in exportedID = asset.id }
        #expect(result.id == exportedID); #expect(store.assets == [result])
        #expect(CaptureAssetStore(rootURL: url).assets == [result])
    }
    @Test("The 51st successful output evicts the oldest complete history directory")
    func historyRetention() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let input = try document(), store = CaptureAssetStore(rootURL:url)
        var first: CaptureAsset?
        var second: CaptureAsset?
        for index in 0..<51 {
            let item = EditableCaptureDocument(baseImage:input.baseImage,snapshot:input.snapshot,kind:input.kind,
                sourceName:input.sourceName,sourceRect:input.sourceRect,capturedAt:Date(timeIntervalSince1970:Double(index)))
            let saved = try await CaptureOutputTransaction.perform(document:item,store:store) { _ in }
            if index == 0 { first = saved }
            if index == 1 { second = saved }
        }
        #expect(store.assets.count == 50)
        let oldest = try #require(first)
        #expect(!store.assets.contains(oldest))
        #expect(!FileManager.default.fileExists(atPath:store.imageURL(for:oldest).path))
        #expect(CaptureAssetStore(rootURL:url).assets.count == 50)
        let replay = EditableCaptureDocument(baseImage:input.baseImage,snapshot:input.snapshot,kind:input.kind,
            sourceName:input.sourceName,sourceRect:input.sourceRect,capturedAt:Date(timeIntervalSince1970:0))
        let replayAsset = try await CaptureOutputTransaction.perform(document:replay,store:store) { _ in }
        #expect(store.assets.first?.id == replayAsset.id)
        #expect(!store.assets.contains(try #require(second)))
        #expect(store.assets.count == 50)
    }

}

@Suite("Capture output state")
struct CaptureOutputStateTests {
    @Test("Duplicate output is rejected and cancelled save or failure remains editable for retry")
    func failureAndRetry() {
        var state = CaptureOutputState()
        let started = state.begin(), duplicate = state.begin(); #expect(started); #expect(!duplicate)
        state.failedOrSaveCancelled(); #expect(state.phase == .editing)
        let retry = state.begin(); #expect(retry); state.succeeded(); #expect(state.phase == .finished)
        let afterFinish = state.begin(); #expect(!afterFinish); state.failedOrSaveCancelled(); #expect(state.phase == .finished)
    }
    @Test("Late output completion cannot resurrect a cancelled editing session")
    func staleCompletionAfterCancel() {
        var state = CaptureOutputState()
        let started = state.begin(); #expect(started); state.cancelSession()
        state.succeeded(); state.failedOrSaveCancelled()
        let afterCancel = state.begin(); #expect(state.phase == .cancelled); #expect(!afterCancel)
    }
}
