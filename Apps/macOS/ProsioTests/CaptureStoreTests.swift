import CoreGraphics
import Foundation
import ImageIO
import Testing

nonisolated private final class CaptureSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    func waitAtCheckpoint() {
        lock.withLock { entered = true }
        release.wait()
    }
    var hasEntered: Bool { lock.withLock { entered } }
}

@Suite("Capture asset persistence")
@MainActor
struct CaptureStoreTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureStoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func screenshot(at time: TimeInterval = 10) throws -> CapturedScreenshot {
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try #require(context.makeImage())
        return CapturedScreenshot(image: image, kind: .region, sourceName: "Test display", sourceRect: CGRect(x: -20, y: -10, width: 4, height: 3), capturedAt: Date(timeIntervalSince1970: time))
    }

    @Test("Fresh store restores stable identity and actual PNG dimensions and color")
    func reopen() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let asset = try await store.save(screenshot())
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets == [asset]); #expect(reopened.recoveryWarnings.isEmpty)
        let source = try #require(CGImageSourceCreateWithURL(reopened.imageURL(for: asset) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 8); #expect(image.height == 6)
        // PNG decoders may return indexed/paletted bytes: render into a known RGBA space before comparing.
        let rgba = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        rgba.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 6))
        let bytes = try #require(rgba.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] == 255); #expect(bytes[1] == 0); #expect(bytes[2] == 0); #expect(bytes[3] == 255)
        #expect(asset.sourceRect == CGRect(x: -20, y: -10, width: 4, height: 3))
    }

    @Test("Reopening sorts by capture time and deleting one leaves the other intact")
    func sortAndDelete() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let newer = try await store.save(screenshot(at: 20))
        let older = try await store.save(screenshot(at: 10))
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets.map(\.id) == [newer.id, older.id])
        try reopened.delete(newer)
        #expect(!FileManager.default.fileExists(atPath: reopened.imageURL(for: newer).path))
        #expect(FileManager.default.fileExists(atPath: reopened.imageURL(for: older).path))
        #expect(CaptureAssetStore(rootURL: url).assets == [older])
    }

    @Test("A file at storage root makes save fail without a successful-looking asset")
    func rootFailure() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: url)
        let store = CaptureAssetStore(rootURL: url)
        do { _ = try await store.save(screenshot()); Issue.record("Save unexpectedly succeeded") } catch {}
        #expect(store.assets.isEmpty); #expect(!store.recoveryWarnings.isEmpty)
        #expect(try Data(contentsOf: url) == Data("occupied".utf8))
    }

    @Test("Missing PNG and incompatible manifests are skipped with recoverable warnings")
    func damagedAssets() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let missing = try await store.save(screenshot())
        let future = try await store.save(screenshot(at: 11))
        try FileManager.default.removeItem(at: store.imageURL(for: missing))
        let manifest = store.imageURL(for: future).deletingLastPathComponent().appendingPathComponent("asset.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets.isEmpty); #expect(reopened.recoveryWarnings.count == 2)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("Interrupted pending directory never appears as committed asset or gets destroyed on reopen")
    func pendingRecovery() throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let pending = url.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        try Data("partial PNG".utf8).write(to: pending.appendingPathComponent("image.png"))
        let store = CaptureAssetStore(rootURL: url)
        #expect(store.assets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: pending.path))
    }
    @Test("PNG encoding succeeds but invalid manifest data aborts the entire directory commit")
    func manifestFailure() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let valid = try screenshot()
        let invalid = CapturedScreenshot(image: valid.image, kind: valid.kind, sourceName: valid.sourceName, sourceRect: CGRect(x: CGFloat.nan, y: 0, width: 4, height: 3), capturedAt: valid.capturedAt)
        let store = CaptureAssetStore(rootURL: url)
        do { _ = try await store.save(invalid); Issue.record("Nonfinite manifest unexpectedly committed") } catch {}
        #expect(store.assets.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        #expect(CaptureAssetStore(rootURL: url).assets.isEmpty)
    }

    @Test("A cancelled caller cannot publish a new persisted asset")
    func alreadyCancelledSave() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let shot = try screenshot()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(shot)
        }
        do { _ = try await task.value; Issue.record("Cancelled save unexpectedly committed") }
        catch { #expect(error is CancellationError) }
        #expect(store.assets.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }

    @Test("Damaged PNG content is excluded from recent assets with an explicit warning")
    func damagedPNG() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let asset = try await store.save(screenshot())
        try Data("not a PNG".utf8).write(to: store.imageURL(for: asset), options: .atomic)
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets.isEmpty)
        #expect(reopened.recoveryWarnings.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(for: asset).path))
    }

    @Test("PNG header alone is not mistaken for a complete recoverable screenshot")
    func truncatedPNG() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureAssetStore(rootURL: url)
        let asset = try await store.save(screenshot())
        let pngURL = store.imageURL(for: asset)
        let original = try Data(contentsOf: pngURL)
        // Keep the PNG signature and IHDR dimensions, discard IDAT pixel data and the ending chunk.
        try original.prefix(33).write(to: pngURL, options: .atomic)
        let reopened = CaptureAssetStore(rootURL: url)
        #expect(reopened.assets.isEmpty)
        #expect(reopened.recoveryWarnings.count == 1)
    }

    @Test("Cancellation after PNG write cleans pending data and never commits a partial asset")
    func cancelAfterPNGWritten() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let gate = CaptureSaveGate()
        defer { gate.release.signal() }
        let store = CaptureAssetStore(rootURL: url, afterPNGWritten: { _ in gate.waitAtCheckpoint() })
        let shot = try screenshot()
        let task = Task { @MainActor in try await store.save(shot) }
        var entered = false
        for _ in 0..<400 {
            if gate.hasEntered { entered = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered, "Writer did not reach its PNG checkpoint")
        if !entered { task.cancel(); return }
        let pending = try #require(FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first)
        #expect(pending.lastPathComponent.hasPrefix(".pending-"))
        let source = try #require(CGImageSourceCreateWithURL(pending.appendingPathComponent("image.png") as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil, "PNG must be fully encoded before cancelling")
        task.cancel()
        gate.release.signal()
        do { _ = try await task.value; Issue.record("Mid-save cancellation unexpectedly committed") }
        catch { #expect(error is CancellationError) }
        #expect(store.assets.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        #expect(CaptureAssetStore(rootURL: url).assets.isEmpty)
    }

    @Test("Filesystem manifest write failure after a good PNG rolls back only its own pending directory")
    func manifestWriteFailure() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let originalStore = CaptureAssetStore(rootURL: url)
        let existing = try await originalStore.save(screenshot())
        let store = CaptureAssetStore(rootURL: url, afterPNGWritten: { pending in
            try FileManager.default.createDirectory(at: pending.appendingPathComponent("asset.json"), withIntermediateDirectories: false)
        })
        do { _ = try await store.save(screenshot(at: 30)); Issue.record("Manifest filesystem collision unexpectedly committed") } catch {}
        #expect(store.assets == [existing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == [existing.id.uuidString + ".prosiocapture"])
        #expect(CaptureAssetStore(rootURL: url).assets == [existing])
        #expect(FileManager.default.fileExists(atPath: originalStore.imageURL(for: existing).path))
    }

}
