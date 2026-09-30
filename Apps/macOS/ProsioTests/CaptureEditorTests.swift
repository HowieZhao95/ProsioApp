import CoreGraphics
import Foundation
import Testing

nonisolated enum CaptureEditorTestPixels {
    static func image(width: Int = 40, height: Int = 32) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes += [UInt8(x * 200 / max(1, width - 1)), UInt8(y * 220 / max(1, height - 1)), 40, 255] } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    static func rgba(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let one = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        return Array(try rgba(one))
    }
    static func redaction(rect: CGRect = CGRect(x: 8, y: 7, width: 4, height: 3), mode: RedactionMode = .solid) -> Annotation {
        Annotation(id: UUID(), kind: .redaction(RedactionShape(rect: rect, mode: mode)), style: AnnotationStyle())
    }
}

@Suite("Capture editor commands")
@MainActor
struct CaptureEditorCommandTests {
    @Test("Resizing and moving crop keeps annotation geometry anchored to source pixels")
    func cropDoesNotMoveAnnotation() {
        let annotation = CaptureEditorTestPixels.redaction()
        let history = EditorHistory(snapshot: EditorSnapshot(cropRect: CGRect(x: 5, y: 4, width: 20, height: 16), annotations: [annotation]))
        history.apply(SetCropCommand(rect: CGRect(x: 3, y: 2, width: 28, height: 24)))
        #expect(history.snapshot.annotations == [annotation])
        #expect(history.snapshot.cropRect == CGRect(x: 3, y: 2, width: 28, height: 24))
        history.undo()
        #expect(history.snapshot.cropRect == CGRect(x: 5, y: 4, width: 20, height: 16))
        #expect(history.snapshot.annotations == [annotation])
        history.redo()
        #expect(history.snapshot.annotations == [annotation])
    }
    @Test("Undo redo preserves update/delete and a new edit abandons the redo branch")
    func historyBranch() {
        let original = CaptureEditorTestPixels.redaction()
        let moved = original.translated(by: CGSize(width: 3, height: -2))
        let history = EditorHistory(snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 40, height: 32)))
        history.apply(AddAnnotationCommand(annotation: original))
        history.apply(UpdateAnnotationCommand(annotation: moved))
        history.apply(DeleteAnnotationsCommand(annotationIDs: [original.id]))
        #expect(history.snapshot.annotations.isEmpty)
        history.undo(); #expect(history.snapshot.annotations == [moved])
        history.undo(); #expect(history.snapshot.annotations == [original])
        history.redo(); #expect(history.snapshot.annotations == [moved])
        history.undo()
        history.apply(SetCropCommand(rect: CGRect(x: 1, y: 1, width: 20, height: 20)))
        #expect(!history.canRedo)
        #expect(history.snapshot.annotations == [original])
    }
    @Test("Selection alone creates no content undo step and deleting clears selected IDs")
    func selectionIsUIState() {
        let annotation = CaptureEditorTestPixels.redaction()
        let history = EditorHistory(snapshot: EditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 40, height: 32), annotations: [annotation]))
        history.setSelection([annotation.id]); #expect(!history.canUndo)
        history.apply(DeleteAnnotationsCommand(annotationIDs: [annotation.id]))
        #expect(history.snapshot.selectedAnnotationIDs.isEmpty)
        history.undo(); #expect(history.snapshot.annotations == [annotation])
    }
    @Test("All annotation geometry kinds translate by the same crop-origin delta")
    func translatedKinds() {
        let style = AnnotationStyle()
        let kinds: [AnnotationKind] = [.rectangle(RectangleShape(rect: CGRect(x: 8, y: 7, width: 4, height: 3))), .ellipse(EllipseShape(rect: CGRect(x: 8, y: 7, width: 4, height: 3))), .arrow(ArrowShape(start: CGPoint(x: 8, y: 7), end: CGPoint(x: 12, y: 10))), .line(LineShape(start: CGPoint(x: 8, y: 7), end: CGPoint(x: 12, y: 10))), .markerLine(LineShape(start: CGPoint(x: 8, y: 7), end: CGPoint(x: 12, y: 10))), .text(TextShape(rect: CGRect(x: 8, y: 7, width: 4, height: 3), text: "hello")), .freehand(FreehandShape(points: [CGPoint(x: 8, y: 7), CGPoint(x: 12, y: 10)])), .highlight(HighlightShape(rect: CGRect(x: 8, y: 7, width: 4, height: 3))), .redaction(RedactionShape(rect: CGRect(x: 8, y: 7, width: 4, height: 3), mode: .solid))]
        for kind in kinds {
            let a = Annotation(id: UUID(), kind: kind, style: style)
            let shifted = a.translated(by: CGSize(width: -5, height: -4))
            #expect(shifted.id == a.id); #expect(shifted.style == style)
            #expect(shifted.boundingRect.origin.x == a.boundingRect.origin.x - 5)
            #expect(shifted.boundingRect.origin.y == a.boundingRect.origin.y - 4)
            #expect(shifted.boundingRect.size == a.boundingRect.size)
        }
    }
}

@Suite("Capture editor pixels")
struct CaptureEditorRendererTests {
    @Test("Straight lines have no arrowhead; capped annotation lines render a perpendicular tick at each endpoint")
    func lineStylePixels() throws {
        let base = try CaptureEditorTestPixels.image()
        let line = LineShape(start: CGPoint(x: 10, y: 16), end: CGPoint(x: 30, y: 16))
        let straight = Annotation(kind: .line(line))
        let capped = straight.changingLineTool(.markerLine)
        let arrow = straight.changingLineTool(.arrow)
        let crop = CGRect(x: 0, y: 0, width: 40, height: 32)
        let plainPixels = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [straight]))
        let cappedPixels = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [capped]))
        let arrowPixels = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [arrow]))
        for x in [10, 30] {
            let tick = try CaptureEditorTestPixels.pixel(cappedPixels, x: x, y: 10)
            #expect(tick[0] > 200 && tick[1] < 80)
            #expect(try CaptureEditorTestPixels.pixel(plainPixels, x: x, y: 10) == CaptureEditorTestPixels.pixel(base, x: x, y: 10))
        }
        #expect(try CaptureEditorTestPixels.pixel(plainPixels, x: 25, y: 13) == CaptureEditorTestPixels.pixel(base, x: 25, y: 13))
        #expect(try CaptureEditorTestPixels.pixel(arrowPixels, x: 25, y: 13) != CaptureEditorTestPixels.pixel(base, x: 25, y: 13))
    }
    @Test("Unified filled rectangles match legacy highlight pixels and opacity survives storage with backward compatibility")
    func unifiedOpacityPixels() throws {
        let base = try CaptureEditorTestPixels.image()
        let rect = CGRect(x: 8, y: 7, width: 20, height: 16)
        let old = Annotation(kind: .highlight(HighlightShape(rect: rect)))
        let unified = old.updatingStyle(old.editableStyle)
        let crop = CGRect(x: 0, y: 0, width: 40, height: 32)
        let before = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [old]))
        let after = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [unified]))
        #expect(try CaptureEditorTestPixels.rgba(before) == CaptureEditorTestPixels.rgba(after))
        var transparent = unified
        transparent.style.opacity = 0
        let invisible = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [transparent]))
        #expect(try CaptureEditorTestPixels.rgba(invisible) == CaptureEditorTestPixels.rgba(base))
        var style = AnnotationStyle(fillColor: .ellipseStroke, lineWidth: 0, opacity: 0.4)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(style)) == style)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? [String: Any])
        json.removeValue(forKey: "opacity")
        style.opacity = 1
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: JSONSerialization.data(withJSONObject: json)) == style)
    }
    @Test("Mosaic and blur strengths below four produce distinct pixels instead of sharing a hard minimum")
    func lowRedactionStrengths() throws {
        let base = try CaptureEditorTestPixels.image(width: 80, height: 60)
        let crop = CGRect(x: 0, y: 0, width: 80, height: 60)
        let effect = CGRect(x: 10, y: 10, width: 60, height: 40)
        let mark = Annotation(kind: .rectangle(RectangleShape(rect: CGRect(x: 25, y: 22, width: 30, height: 16))),
                              style: AnnotationStyle(fillColor: .textForeground, lineWidth: 0))
        for mode in [RedactionMode.pixelate, .blur] {
            var outputs: [Data] = []
            for strength: CGFloat in [1, 2, 3, 4, 10] {
                let annotation = Annotation(kind: .redaction(RedactionShape(rect: effect, mode: mode)),
                                            style: AnnotationStyle(effectRadius: strength))
                outputs.append(try CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: base,
                    snapshot: EditorSnapshot(cropRect: crop, annotations: [mark, annotation]))))
            }
            for pair in zip(outputs, outputs.dropFirst()) { #expect(pair.0 != pair.1) }
        }
    }
    @Test("Crop exports exact pixel dimensions and the top-left source orientation")
    func cropPixels() throws {
        let base = try CaptureEditorTestPixels.image()
        let snapshot = EditorSnapshot(cropRect: CGRect(x: 5, y: 4, width: 20, height: 16))
        let output = try EditorRenderer.render(baseImage: base, snapshot: snapshot)
        #expect(output.width == 20); #expect(output.height == 16)
        for (x, y) in [(0, 0), (19, 0), (0, 15), (19, 15), (7, 6)] {
            #expect(try CaptureEditorTestPixels.pixel(output, x: x, y: y) == CaptureEditorTestPixels.pixel(base, x: x + 5, y: y + 4))
        }
    }
    @Test("Selected handles and UI state do not enter the rendered image")
    func noUIInOutput() throws {
        let base = try CaptureEditorTestPixels.image()
        let a = CaptureEditorTestPixels.redaction()
        let plain = EditorSnapshot(cropRect: CGRect(x: 5, y: 4, width: 20, height: 16), annotations: [a])
        var selected = plain; selected.selectedAnnotationIDs = [a.id]
        #expect(try CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: base, snapshot: plain)) == CaptureEditorTestPixels.rgba(EditorRenderer.render(baseImage: base, snapshot: selected)))
    }
    @Test("Solid redaction follows source pixels when crop changes and leaves outside pixels intact")
    func solidRedactionAndCrop() throws {
        let base = try CaptureEditorTestPixels.image()
        let annotation = CaptureEditorTestPixels.redaction()
        for crop in [CGRect(x: 5, y: 4, width: 20, height: 16), CGRect(x: 2, y: 1, width: 30, height: 24)] {
            let output = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop, annotations: [annotation]))
            let hidden = try CaptureEditorTestPixels.pixel(output, x: 9 - Int(crop.minX), y: 8 - Int(crop.minY))
            #expect(hidden[0] < 25 && hidden[1] < 25 && hidden[2] < 25)
            #expect(try hidden != CaptureEditorTestPixels.pixel(base, x: 9, y: 8))
            #expect(try CaptureEditorTestPixels.pixel(output, x: 0, y: 0) == CaptureEditorTestPixels.pixel(base, x: Int(crop.minX), y: Int(crop.minY)))
        }
    }
    @Test("Invalid or out-of-source crops fail instead of silently exporting another region")
    func invalidCrops() throws {
        let base = try CaptureEditorTestPixels.image()
        for crop in [CGRect.zero, CGRect(x: -1, y: 0, width: 10, height: 10), CGRect(x: 30, y: 20, width: 20, height: 20)] {
            do { _ = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: crop)); Issue.record("Invalid crop unexpectedly rendered") } catch { #expect(error is EditorRenderError) }
        }
    }
    @Test("Blur and mosaic operate on already composited annotations without altering outside pixels")
    func effectsIncludeCompositedLayers() throws {
        let base = try CaptureEditorTestPixels.image()
        var style = AnnotationStyle(); style.lineWidth = 0
        style.fillColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        let mark = Annotation(id: UUID(), kind: .rectangle(RectangleShape(rect: CGRect(x: 10, y: 8, width: 10, height: 12))), style: style)
        let full = CGRect(x: 0, y: 0, width: 40, height: 32), effectRect = CGRect(x: 8, y: 6, width: 16, height: 18)
        let marked = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: full, annotations: [mark]))
        for mode: RedactionMode in [.blur, .pixelate] {
            var effect = CaptureEditorTestPixels.redaction(rect: effectRect, mode: mode); effect.style.effectRadius = 6
            let processed = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: full, annotations: [mark, effect]))
            let baseOnlyEffect = try EditorRenderer.render(baseImage: base, snapshot: EditorSnapshot(cropRect: full, annotations: [effect]))
            let region = try #require(processed.cropping(to: effectRect))
            #expect(try CaptureEditorTestPixels.rgba(region) != CaptureEditorTestPixels.rgba(#require(marked.cropping(to: effectRect))))
            #expect(try CaptureEditorTestPixels.rgba(region) != CaptureEditorTestPixels.rgba(#require(baseOnlyEffect.cropping(to: effectRect))))
            #expect(try CaptureEditorTestPixels.pixel(processed, x: 2, y: 2) == CaptureEditorTestPixels.pixel(base, x: 2, y: 2))
            #expect(try CaptureEditorTestPixels.pixel(processed, x: 30, y: 28) == CaptureEditorTestPixels.pixel(base, x: 30, y: 28))
        }
    }

}

@Suite("Capture text and output key routing")
struct CaptureTextKeyRoutingTests {
    @Test("Text editing owns Return and Cmd-C, while Cmd-Return commits text without output")
    func textOwnsKeys() {
        #expect(CaptureKeyRouting.action(keyCode: 36, characters: "\r", command: false, shift: false, textEditing: true) == .passThrough)
        #expect(CaptureKeyRouting.action(keyCode: 8, characters: "c", command: true, shift: false, textEditing: true) == .passThrough)
        #expect(CaptureKeyRouting.action(keyCode: 36, characters: "\r", command: true, shift: false, textEditing: true) == .commitText)
        #expect(CaptureKeyRouting.action(keyCode: 36, characters: "\r", command: true, shift: false, textEditing: true, hasMarkedText: true) == .passThrough)
        #expect(CaptureKeyRouting.action(keyCode: 53, characters: nil, command: false, shift: false, textEditing: true, hasMarkedText: true) == .passThrough)
        #expect(CaptureKeyRouting.action(keyCode: 53, characters: nil, command: false, shift: false, textEditing: true) == .escape)
        #expect(CaptureKeyRouting.action(keyCode: 123, characters: nil, command: false, shift: false, textEditing: true) == .passThrough)
        #expect(CaptureKeyRouting.action(keyCode: 124, characters: nil, command: false, shift: false, textEditing: true) == .passThrough)
    }
    @Test("Outside text editing Return and Cmd-C copy, save and undo retain their distinct actions")
    func editingActions() {
        #expect(CaptureKeyRouting.action(keyCode: 36, characters: "\r", command: false, shift: false, textEditing: false) == .copy)
        #expect(CaptureKeyRouting.action(keyCode: 8, characters: "c", command: true, shift: false, textEditing: false) == .copy)
        #expect(CaptureKeyRouting.action(keyCode: 1, characters: "s", command: true, shift: false, textEditing: false) == .save)
        #expect(CaptureKeyRouting.action(keyCode: 6, characters: "z", command: true, shift: true, textEditing: false) == .redo)
        #expect(CaptureKeyRouting.action(keyCode: 6, characters: "z", command: true, shift: false, textEditing: false) == .undo)
        #expect(CaptureKeyRouting.action(keyCode: 123, characters: nil, command: false, shift: false, textEditing: false) == .historyOlder)
        #expect(CaptureKeyRouting.action(keyCode: 124, characters: nil, command: false, shift: false, textEditing: false) == .historyNewer)
    }
    @Test("Output in progress does not dispatch another key action or commit text")
    func outputSuppressesKeys() {
        for key: UInt16 in [36, 53, 8, 1, 51] {
            #expect(CaptureKeyRouting.action(keyCode: key, characters: "c", command: true, shift: false, textEditing: false, outputInProgress: true) == .passThrough)
        }
    }
}
