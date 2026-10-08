import AppKit
import CoreText
import Foundation
import Testing

private actor TranslationProbe {
    var ocrCalls = 0, calls = 0, active = 0, peak = 0
    func recognize(_ regions: [CaptureTextRegion]) -> [CaptureTextRegion] { ocrCalls += 1; return regions }
    func translate(_ texts: [String], language: String) async throws -> [String] {
        calls += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        return texts.map { language + ":" + $0 }
    }
}

@Suite("Screenshot translation")
struct CaptureTranslationTests {
    private func region(_ text: String = "Hello", x: CGFloat = 5) -> CaptureTextRegion {
        CaptureTextRegion(text: text, rect: CGRect(x: x, y: 4, width: 26, height: 18), background: .textForeground, foreground: .redactionFill)
    }
    private func document() throws -> EditableCaptureDocument {
        let image = try CaptureEditorTestPixels.image()
        return EditableCaptureDocument(baseImage: image, snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 40, height: 32)),
            kind: .region, sourceName: "test", sourceRect: CGRect(x: 0, y: 0, width: 40, height: 32), capturedAt: Date())
    }

    @Test func deduplicatesAndCachesOCRAndTranslation() async throws {
        let probe = TranslationProbe(), regions = [region(), region(x: 8)]
        let pipeline = CaptureTranslationPipeline(translate: { try await probe.translate($0, language: $1) }, recognize: { _ in await probe.recognize(regions) })
        let doc = try document(), id = UUID()
        let first = try await pipeline.overlays(document: doc, sourceID: id, target: "zh-Hans")
        #expect(first.count == 2)
        let started = Date()
        let repeated = try await pipeline.overlays(document: doc, sourceID: id, target: "zh-Hans")
        print("Cached screenshot translation: \(Date().timeIntervalSince(started) * 1000) ms")
        #expect(repeated == first)
        #expect(await probe.calls == 1); #expect(await probe.ocrCalls == 1)
        _ = try await pipeline.overlays(document: doc, sourceID: id, target: "ja-JP")
        #expect(await probe.calls == 2); #expect(await probe.ocrCalls == 1)
        let translated = EditableCaptureDocument(baseImage: doc.baseImage, snapshot: EditorSnapshot(cropRect: doc.snapshot.cropRect, annotations: first), kind: doc.kind, sourceName: doc.sourceName, sourceRect: doc.sourceRect, capturedAt: doc.capturedAt)
        _ = try await pipeline.overlays(document: translated, sourceID: id, target: "zh-Hans")
        #expect(await probe.calls == 2); #expect(await probe.ocrCalls == 1)
    }

    @Test func limitsConcurrencyToTwoAndInvalidatesOCRWhenCropChanges() async throws {
        let probe = TranslationProbe(), regions = (0..<100).map { region("Line \($0)") }
        let pipeline = CaptureTranslationPipeline(translate: { try await probe.translate($0, language: $1) }, recognize: { _ in await probe.recognize(regions) })
        let doc = try document(), id = UUID()
        #expect(try await pipeline.overlays(document: doc, sourceID: id, target: "zh-Hans").count == 100)
        #expect(await probe.peak == 2); #expect(await probe.calls == 3)
        var snapshot = doc.snapshot; snapshot.cropRect = CGRect(x: 1, y: 1, width: 30, height: 25)
        let changed = EditableCaptureDocument(baseImage: doc.baseImage, snapshot: snapshot, kind: doc.kind, sourceName: doc.sourceName, sourceRect: doc.sourceRect, capturedAt: doc.capturedAt)
        _ = try await pipeline.overlays(document: changed, sourceID: id, target: "zh-Hans")
        #expect(await probe.ocrCalls == 2); #expect(await probe.calls == 3)
    }

    @Test func rejectsIncompleteResultAndEmptyOCR() async throws {
        let regions = [region()]
        let pipeline = CaptureTranslationPipeline(translate: { _, _ in [] }, recognize: { _ in regions })
        let doc = try document()
        await #expect(throws: CaptureTranslationError.self) { try await pipeline.overlays(document: doc, sourceID: UUID(), target: "zh-Hans") }
        let empty = CaptureTranslationPipeline(translate: { _, _ in Issue.record("Must not translate empty OCR"); return [] }, recognize: { _ in [] })
        await #expect(throws: CaptureTranslationError.self) { try await empty.overlays(document: doc, sourceID: UUID(), target: "zh-Hans") }
    }

    @MainActor @Test func translationIsOneUndoStepAndPersistsThroughCrop() throws {
        let doc = try document()
        let old = Annotation(kind: .text(TextShape(rect: region().rect, text: "你好", translationSource: "Hello")), style: AnnotationStyle(fillColor: .textForeground))
        let manual = Annotation(kind: .text(TextShape(rect: CGRect(x: 2, y: 2, width: 12, height: 12), text: "note")))
        let history = EditorHistory(snapshot: EditorSnapshot(cropRect: doc.snapshot.cropRect, annotations: [old, manual]))
        var new = old; new.kind = .text(TextShape(rect: region().rect, text: "こんにちは", translationSource: "Hello"))
        history.apply(SetCaptureTranslationCommand(annotations: [new], crop: doc.snapshot.cropRect))
        #expect(history.snapshot.annotations == [manual, new])
        history.undo(); #expect(history.snapshot.annotations == [old, manual])
        history.redo(); #expect(history.snapshot.annotations == [manual, new])
        let saved = EditableCaptureDocument(baseImage: doc.baseImage, snapshot: history.snapshot, kind: doc.kind, sourceName: doc.sourceName, sourceRect: doc.sourceRect, capturedAt: doc.capturedAt)
        let restricted = try saved.restrictedToSelection()
        #expect(restricted.snapshot.annotations.last?.isTranslation == true)
        #expect(try JSONDecoder().decode(EditorSnapshot.self, from: JSONEncoder().encode(restricted.snapshot)) == restricted.snapshot)
    }

    @Test func overlayCoversOriginalPixelsAndLeavesOutsideUnchanged() throws {
        let doc = try document(), rect = region().rect
        let mark = Annotation(kind: .text(TextShape(rect: rect, text: "译文", translationSource: "Hello")),
            style: AnnotationStyle(strokeColor: .redactionFill, fillColor: .textForeground, lineWidth: 0, fontSize: 10))
        let image = try EditorRenderer.render(baseImage: doc.baseImage, snapshot: EditorSnapshot(cropRect: doc.snapshot.cropRect, annotations: [mark]))
        #expect(image.width == doc.baseImage.width); #expect(image.height == doc.baseImage.height)
        #expect(try CaptureEditorTestPixels.pixel(image, x: 0, y: 0) == CaptureEditorTestPixels.pixel(doc.baseImage, x: 0, y: 0))
        #expect(try CaptureEditorTestPixels.pixel(image, x: 30, y: 21) == [255, 255, 255, 255])
        #expect(try CaptureEditorTestPixels.rgba(image) != CaptureEditorTestPixels.rgba(doc.baseImage))
    }

    @Test func fitsExpandedTranslationWithinOriginalBox() {
        let text = "A much longer translated sentence that needs to wrap."
        let rect = CGRect(x: 0, y: 0, width: 120, height: 32)
        let size = CaptureTranslationOCR.fontSize(text: text, rect: rect)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)]
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        #expect(CTFrameGetVisibleStringRange(frame).length == (text as NSString).length)
        #expect(size > 1 && size < rect.height)
    }

    @MainActor @Test func cropChangeCancelsAndDiscardsLateTranslation() async throws {
        let doc = try document(), regions = [region()]
        let display = DisplaySnapshot(displayID: 1, name: "test", frame: doc.sourceRect, overlayFrame: doc.sourceRect, scale: 1)
        let source = FrozenCaptureSource(id: UUID(), image: doc.baseImage, display: display, sourceRect: doc.sourceRect, overlayRect: doc.sourceRect, kind: .region, name: "test", capturedAt: Date())
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0)
        session.translationPipeline = CaptureTranslationPipeline(translate: { _, _ in try? await Task.sleep(for: .milliseconds(80)); return ["你好"] }, recognize: { _ in regions })
        session.translateCapture()
        #expect(session.isTranslating)
        session.setCrop(CGRect(x: 1, y: 1, width: 30, height: 25))
        #expect(!session.isTranslating)
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.snapshot?.annotations.isEmpty == true)
        session.forceCancel()
    }
}

@Suite("Screenshot OCR geometry and performance")
struct CaptureTranslationOCRTests {
    private func fontFixture(name: String, size: CGFloat, foreground: CGColor = CGColor(gray: 0, alpha: 1), background: CGColor = CGColor(gray: 1, alpha: 1)) throws -> (CGImage, CGRect) {
        let text = "Hello world Save screenshot"
        let line = CaptureTranslationTypography.line(text, name: name, size: size)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = Int(ceil(ink.width)) + 40, height = Int(ceil(ink.height)) + 40
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(background); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(foreground); context.textPosition = CGPoint(x: 20 - ink.minX, y: CGFloat(height) - 20 - ink.maxY)
        CTLineDraw(line, context)
        return (try #require(context.makeImage()), CGRect(x: 18, y: 18, width: ink.width + 4, height: ink.height + 4))
    }

    @Test func matchesCommonSourceFamiliesAndWeights() throws {
        let started = Date()
        for name in ["Helvetica", "Helvetica-Bold", "Menlo-Regular", "Menlo-Bold", "TimesNewRomanPS-BoldMT", "TimesNewRomanPS-ItalicMT"] {
            let (image, rect) = try fontFixture(name: name, size: 32)
            let matched = CaptureTranslationTypography.match(text: "Hello world Save screenshot", image: image, rect: rect, background: .textForeground)
            print("Font match \(name): \(matched.name) \(matched.size)")
            #expect(matched.name == name)
            #expect(abs(matched.size - 32) < 2)
        }
        print("Six local font matches: \(Date().timeIntervalSince(started) * 1000) ms")
    }

    @Test func preservesSolidBackgroundAndColoredInk() throws {
        let (image, rect) = try fontFixture(name: "Helvetica-Bold", size: 32, foreground: CGColor(red: 0.8, green: 0.1, blue: 0.15, alpha: 1))
        let (background, foreground) = CaptureTranslationOCR.sampleColors(image: image, rect: rect)
        #expect(background.red == 1 && background.green == 1 && background.blue == 1)
        #expect(abs(foreground.red - 0.8) < 0.08)
        #expect(foreground.green < 0.2 && foreground.blue < 0.25)
    }

    @Test func samplesDarkBackgroundAndKeepsBoldSourceStyle() throws {
        let (image, rect) = try fontFixture(name: "Helvetica-Bold", size: 48, foreground: CGColor(gray: 1, alpha: 1),
            background: CGColor(red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255, alpha: 1))
        let (background, foreground) = CaptureTranslationOCR.sampleColors(image: image, rect: rect)
        let sourceBackground = try CaptureEditorTestPixels.pixel(image, x: 0, y: 0)
        #expect(abs(background.red - CGFloat(sourceBackground[0]) / 255) < 0.005)
        #expect(background.green == background.red && background.blue == background.red)
        #expect(foreground.red > 0.95 && foreground.green > 0.95 && foreground.blue > 0.95)
        let matched = CaptureTranslationTypography.match(text: "Hello world Save screenshot", image: image, rect: rect, background: background)
        #expect(matched.name == "Helvetica-Bold")
        #expect(abs(matched.size - 48) < 2)
        let shape = TextShape(rect: rect, text: "保存截图", automaticallySizesToText: false, translationSource: "Hello world Save screenshot",
            fontName: matched.name, translationSourceRect: rect)
        let mark = Annotation(kind: .text(shape), style: AnnotationStyle(strokeColor: foreground, fillColor: background, fontSize: matched.size))
        let output = try EditorRenderer.render(baseImage: image, snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: image.width, height: image.height), annotations: [mark]))
        let paintedBackground = try CaptureEditorTestPixels.pixel(output, x: Int(rect.maxX) - 2, y: Int(rect.maxY) - 2)
        #expect(paintedBackground == sourceBackground)
    }

    @Test func preservesTypographyFromRealRetinaCapture() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("docs/evidence/capture-translation/font-preservation-source.png")
        let image = try #require(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let document = EditableCaptureDocument(baseImage: image, snapshot: EditorSnapshot(cropRect: bounds), kind: .region,
            sourceName: "Real font fixture", sourceRect: bounds, capturedAt: Date())
        let regions = try await CaptureTranslationOCR.recognize(document)
        let expected: [(String, String, CGFloat)] = [("Screenshot", "Helvetica-Bold", 64), ("Your", "Helvetica", 36),
            ("Privacy", "Helvetica-Bold", 36), ("The meeting", "Menlo-Regular", 32), ("Save", "TimesNewRomanPS-ItalicMT", 40), ("Small", "Helvetica", 28)]
        for (prefix, name, size) in expected {
            let region = try #require(regions.first { $0.text.hasPrefix(prefix) })
            print("Real Retina font \(prefix): \(region.fontName) \(region.fontSize ?? 0)")
            #expect(region.fontName == name)
            #expect(abs((region.fontSize ?? 0) - size) < size * 0.15)
        }
    }

    @Test func wrapsAtSourceSizeBeforeShrinkingAndAvoidsNeighbors() throws {
        let original = CGRect(x: 10, y: 10, width: 120, height: 32)
        let crop = CGRect(x: 0, y: 0, width: 150, height: 160)
        let text = "A longer translated sentence wraps here."
        let available = CaptureTranslationTextLayout.availableRect(for: original, crop: crop, obstacles: [original], preferredSize: 24)
        let fitted = CaptureTranslationTextLayout.fit(text: text, fontName: "Helvetica-Bold", preferredSize: 24, original: original, available: available)
        #expect(fitted.size == 24)
        #expect(fitted.rect.height > original.height)
        let layout = try #require(CaptureTranslationTextLayout.layout(text: text, fontName: "Helvetica-Bold", size: fitted.size, width: fitted.rect.width - 4))
        #expect(layout.lines.count > 1)
        #expect(layout.height <= fitted.rect.height - 4)
        let neighbor = CGRect(x: 10, y: 48, width: 130, height: 24)
        let constrained = CaptureTranslationTextLayout.availableRect(for: original, crop: crop, obstacles: [original, neighbor], preferredSize: 24)
        let smaller = CaptureTranslationTextLayout.fit(text: text, fontName: "Helvetica-Bold", preferredSize: 24, original: original, available: constrained)
        #expect(smaller.size < 24)
        #expect(!smaller.rect.intersects(neighbor))
        #expect(crop.contains(smaller.rect))
    }

    @Test func sourceSizePreservesHeadingHierarchyAndNewMetadataRoundTrips() throws {
        let original = CGRect(x: 10, y: 10, width: 260, height: 48)
        let available = CGRect(x: 10, y: 10, width: 400, height: 120)
        let heading = CaptureTranslationTextLayout.fit(text: "截图翻译测试", fontName: "Helvetica-Bold", preferredSize: 40, original: original, available: available)
        let body = CaptureTranslationTextLayout.fit(text: "保存截图", fontName: "Helvetica", preferredSize: 20, original: original, available: available)
        #expect(heading.size == 40 && body.size == 20)
        let shape = TextShape(rect: heading.rect, text: "截图翻译测试", automaticallySizesToText: false,
            translationSource: "Screenshot translation test", fontName: "Helvetica-Bold", translationSourceRect: original)
        let restored = try JSONDecoder().decode(TextShape.self, from: JSONEncoder().encode(shape))
        #expect(restored == shape)
        let old = TextShape(rect: original, text: "Old text")
        let decoded = try JSONDecoder().decode(TextShape.self, from: JSONEncoder().encode(old))
        #expect(decoded.fontName == nil && decoded.translationSourceRect == nil)
        let annotation = Annotation(kind: .text(shape))
        if case .text(let moved) = annotation.translated(by: CGSize(width: 8, height: 6)).kind {
            #expect(moved.fontName == shape.fontName)
            #expect(moved.translationSourceRect == original.offsetBy(dx: 8, dy: 6))
        } else { Issue.record("Translation shape lost") }
    }

    @Test func wrappedTranslationDrawsAllLinesWithoutErasingFreeSpace() throws {
        let (image, _) = try fontFixture(name: "Helvetica", size: 32)
        let original = CGRect(x: 18, y: 18, width: 100, height: 24)
        let rect = CGRect(x: 18, y: 18, width: 170, height: 48)
        let shape = TextShape(rect: rect, text: "Hello world\nSave screenshot", automaticallySizesToText: false,
            translationSource: "Hello", fontName: "Helvetica-Bold", translationSourceRect: original)
        let mark = Annotation(kind: .text(shape), style: AnnotationStyle(strokeColor: .rectangleStroke, fillColor: .textForeground, fontSize: 18))
        let output = try EditorRenderer.render(baseImage: image, snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: image.width, height: image.height), annotations: [mark]))
        let bytes = try CaptureEditorTestPixels.rgba(output)
        var first = 0, second = 0
        for y in 18..<min(output.height, 66) { for x in 18..<188 {
            let index = (y * output.width + x) * 4
            if bytes[index] > 160 && bytes[index + 1] < 100 {
                if y < 42 { first += 1 } else { second += 1 }
            }
        } }
        #expect(first > 15 && second > 15)
        #expect(try CaptureEditorTestPixels.pixel(output, x: 185, y: 60) == CaptureEditorTestPixels.pixel(image, x: 185, y: 60))
    }

    @Test func recognizesSelectedVisibleTextAndSkipsRedactions() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let blank = try #require(context.makeImage())
        let lines = ["Hello world", "Save screenshot", "SECRET PASSWORD", "Outside selection"]
        let marks = lines.enumerated().map { index, text in
            Annotation(kind: .text(TextShape(rect: CGRect(x: 250, y: index == 3 ? 500 : 160 + index * 70, width: 550, height: 55), text: text)),
                style: AnnotationStyle(strokeColor: .redactionFill, fontSize: 32))
        }
        let base = try EditorRenderer.render(baseImage: blank, snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), annotations: marks))
        let crop = CGRect(x: 200, y: 120, width: 800, height: 260)
        let mask = Annotation(kind: .redaction(RedactionShape(rect: CGRect(x: 245, y: 295, width: 570, height: 65), mode: .solid)))
        let document = EditableCaptureDocument(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [mask]), kind: .region,
            sourceName: "OCR test", sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), capturedAt: Date())
        let start = Date()
        let regions = try await CaptureTranslationOCR.recognize(document)
        let duration = Date().timeIntervalSince(start)
        print("Screenshot OCR 1920x1080, crop 800x260: \(Int(duration * 1000)) ms, \(regions.count) regions")
        #expect(regions.contains { $0.text.contains("Hello") })
        #expect(regions.contains { $0.text.contains("Save") })
        #expect(!regions.contains { $0.text.contains("SECRET") || $0.text.contains("Outside") })
        for region in regions {
            #expect(crop.contains(region.rect))
            #expect(region.rect.minX >= 245 && region.rect.maxX < 810)
            #expect(region.background.red > 0.9)
        }
        let outputs = regions.map { region in
            Annotation(kind: .text(TextShape(rect: region.rect, text: region.text.contains("Hello") ? "你好，世界" : "保存截图", automaticallySizesToText: false, translationSource: region.text)),
                style: AnnotationStyle(strokeColor: region.foreground, fillColor: region.background,
                    lineWidth: 0, fontSize: CaptureTranslationOCR.fontSize(text: "你好，世界", rect: region.rect)))
        }
        let result = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [mask] + outputs))
        #expect(result.width == 800 && result.height == 260)
        let url = URL(fileURLWithPath: "/tmp/prosio-capture-translation-preview.png")
        let representation = NSBitmapImageRep(cgImage: result)
        try #require(representation.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func capsOnlyOCRResolution() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 5120, height: 1440, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let scaled = try CaptureTranslationOCR.scaledForRecognition(image)
        #expect(scaled.width == 4096 && scaled.height == 1152)
        #expect(image.width == 5120 && image.height == 1440)
    }
}
