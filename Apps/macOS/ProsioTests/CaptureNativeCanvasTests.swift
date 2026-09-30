import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing

@Suite("Capture native canvas with synthetic frozen pixels", .serialized)
@MainActor
struct CaptureNativeCanvasTests {
    private func source(overlay: CGRect = CGRect(x: 0, y: 0, width: 640, height: 480)) throws -> FrozenCaptureSource {
        FrozenCaptureSource(id: UUID(), image: try CaptureEditorTestPixels.image(width: 320, height: 240), display: DisplaySnapshot(displayID: 990099, name: "SYNTHETIC TEST DISPLAY", frame: overlay, overlayFrame: overlay, scale: 0.5), sourceRect: CGRect(x: 0, y: 0, width: 320, height: 240), overlayRect: overlay, kind: .region, name: "SYNTHETIC PIXELS — NOT SYSTEM CAPTURE", capturedAt: Date(timeIntervalSince1970: 100))
    }
    private func canvas(_ session: CaptureEditingSession, size: CGSize = CGSize(width: 640, height: 480), history: Bool = false, register: Bool = false) -> (CaptureEditingCanvas, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = CaptureEditingCanvas(frame: CGRect(origin: .zero, size: size), sourceIndex: 0, session: session, isHistory: history)
        window.contentView = view
        if register { session.registerCanvas(view) }
        view.sessionChanged()
        return (view, window)
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint, view: NSView,
                       clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1))
    }
    private func drag(_ view: CaptureEditingCanvas, from: CGPoint, to: CGPoint) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: from, view: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: to, view: view))
        view.mouseUp(with: try event(.leftMouseUp, at: to, view: view))
    }
    private func click(_ view: CaptureEditingCanvas, at point: CGPoint,
                       clickCount: Int = 1) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: point, view: view, clickCount: clickCount))
        view.mouseUp(with: try event(.leftMouseUp, at: point, view: view, clickCount: clickCount))
    }
    private func move(_ view: CaptureEditingCanvas, to point: CGPoint) throws {
        view.mouseMoved(with: try event(.mouseMoved, at: point, view: view))
    }
    private func enter(_ view: CaptureEditingCanvas, at point: CGPoint) throws {
        let entry = try #require(NSEvent.enterExitEvent(with: .mouseEntered,
            location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, trackingNumber: 1, userData: nil))
        view.mouseEntered(with: entry)
    }
    private func exit(_ view: CaptureEditingCanvas, at point: CGPoint) throws {
        let leave = try #require(NSEvent.enterExitEvent(with: .mouseExited,
            location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 2, trackingNumber: 1, userData: nil))
        view.mouseExited(with: leave)
    }
    private func key(_ view: CaptureEditingCanvas, type: NSEvent.EventType = .keyDown,
                     characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                     keyCode: UInt16, timestamp: TimeInterval = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero,
            modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }
    private func textEditor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let text = textEditor(in: child) { return text } }
        return nil
    }
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint, in view: NSView) throws -> [UInt8] {
        let image = try #require(bitmap.cgImage)
        return try CaptureEditorTestPixels.pixel(image,
            x: Int(point.x * CGFloat(bitmap.pixelsWide) / view.bounds.width),
            y: Int(point.y * CGFloat(bitmap.pixelsHigh) / view.bounds.height))
    }
    private func differs(_ first: [UInt8], from second: [UInt8], by threshold: Int) -> Bool {
        (0..<3).contains { abs(Int(first[$0]) - Int(second[$0])) >= threshold }
    }
    private func writeEvidence(_ bitmap: NSBitmapImageRep, name: String) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("docs/evidence/capture-m2/synthetic-native")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func writeSnapEvidence(_ bitmap: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/prosio-capture-snapping-native-evidence-20260928", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func writeLoupeEvidence(_ bitmap: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/prosio-capture-loupe-native-evidence-20260928", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func panelSource() throws -> FrozenCaptureSource {
        let context = try #require(CGContext(data: nil, width: 320, height: 240,
            bitsPerComponent: 8, bytesPerRow: 1280,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(red: 0.88, green: 0.92, blue: 0.96, alpha: 1)
        context.fill(CGRect(x: 40, y: 40, width: 240, height: 160))
        context.setFillColor(red: 0.46, green: 0.70, blue: 0.88, alpha: 1)
        context.fill(CGRect(x: 120, y: 65, width: 80, height: 55))
        let overlay = CGRect(x: 0, y: 0, width: 640, height: 480)
        return FrozenCaptureSource(id: UUID(), image: try #require(context.makeImage()),
            display: DisplaySnapshot(displayID: 990098, name: "SYNTHETIC PANELS", frame: overlay, overlayFrame: overlay, scale: 0.5),
            sourceRect: CGRect(x: 0, y: 0, width: 320, height: 240), overlayRect: overlay,
            kind: .region, name: "SYNTHETIC PANELS — NOT SYSTEM CAPTURE", capturedAt: Date(timeIntervalSince1970: 100))
    }
    @Test("Moving an arrow replaces its old pixels immediately, follows each event and commits one undo step")
    func annotationDragPreview() async throws {
        let source = try source()
        let initial = EditorSnapshot(cropRect: source.pixelBounds)
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                            initialSource: 0, initialSnapshot: initial)
        let (view, window) = canvas(session, register: true)
        defer { session.forceCancel(); window.close() }
        let oldPoint = CGPoint(x: 160, y: 140)
        let nextPoint = CGPoint(x: 160, y: 220)
        let finalPoint = CGPoint(x: 160, y: 280)
        let baseline = try bitmap(view)
        let oldBackground = try pixel(baseline, at: oldPoint, in: view)
        let nextBackground = try pixel(baseline, at: nextPoint, in: view)
        let finalBackground = try pixel(baseline, at: finalPoint, in: view)
        let arrow = Annotation(kind: .arrow(ArrowShape(start: CGPoint(x: 50, y: 70),
                                                      end: CGPoint(x: 110, y: 70))))
        session.apply(AddAnnotationCommand(annotation: arrow))
        for _ in 0..<100 {
            if session.renderedImageMatches(try #require(session.snapshot)) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.renderedImageMatches(try #require(session.snapshot)))
        session.tool = .select
        view.mouseDown(with: try event(.leftMouseDown, at: oldPoint, view: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: nextPoint, view: view))
        let first = try bitmap(view)
        #expect(!differs(try pixel(first, at: oldPoint, in: view), from: oldBackground, by: 10))
        #expect(differs(try pixel(first, at: nextPoint, in: view), from: nextBackground, by: 40))
        #expect(session.snapshot?.annotations == [arrow], "Dragging must not commit history on every event")
        view.mouseDragged(with: try event(.leftMouseDragged, at: finalPoint, view: view))
        let second = try bitmap(view)
        #expect(!differs(try pixel(second, at: nextPoint, in: view), from: nextBackground, by: 10))
        #expect(differs(try pixel(second, at: finalPoint, in: view), from: finalBackground, by: 40))
        // Verify the arrowhead follows too, rather than showing just a line.
        let headPoint = CGPoint(x: 214, y: 276)
        #expect(differs(try pixel(second, at: headPoint, in: view),
                        from: try pixel(baseline, at: headPoint, in: view), by: 40))
        #expect(view.cancelGesture())
        let cancelled = try bitmap(view)
        #expect(differs(try pixel(cancelled, at: oldPoint, in: view), from: oldBackground, by: 40))
        #expect(!differs(try pixel(cancelled, at: finalPoint, in: view), from: finalBackground, by: 10))
        try drag(view, from: oldPoint, to: finalPoint)
        let committed = try bitmap(view)
        #expect(!differs(try pixel(committed, at: oldPoint, in: view), from: oldBackground, by: 10))
        #expect(differs(try pixel(committed, at: finalPoint, in: view), from: finalBackground, by: 40),
                "Mouse-up must not flash the stale rendered image")
        #expect(session.snapshot?.annotations == [arrow.translated(by: CGSize(width: 0, height: 70))])
        session.undo()
        #expect(session.snapshot?.annotations == [arrow])
        session.redo()
        #expect(session.snapshot?.annotations == [arrow.translated(by: CGSize(width: 0, height: 70))])
    }

    @Test("Moving filled annotations preserves layering and blur/pixelation in the live pixels")
    func filledAnnotationDragPreview() throws {
        let source = try source()
        for mode in [RedactionMode.solid, .blur, .pixelate] {
            let moving = Annotation(kind: .rectangle(RectangleShape(rect: CGRect(x: 50, y: 60, width: 60, height: 30))),
                                    style: AnnotationStyle(fillColor: .rectangleStroke))
            let overlay = Annotation(kind: .highlight(HighlightShape(rect: CGRect(x: 75, y: 135, width: 10, height: 10))),
                                     style: AnnotationStyle(strokeColor: .ellipseStroke))
            let effect = Annotation(kind: .redaction(RedactionShape(rect: CGRect(x: 180, y: 60, width: 30, height: 40), mode: mode)))
            let initial = EditorSnapshot(cropRect: source.pixelBounds, annotations: [moving, overlay, effect])
            let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                                initialSource: 0, initialSnapshot: initial)
            let (view, window) = canvas(session)
            defer { session.forceCancel(); window.close() }
            view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 160, y: 150), view: view))
            view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 160, y: 280), view: view))
            var expected = initial
            expected.annotations[0] = moving.translated(by: CGSize(width: 0, height: 65))
            let rendered = try EditorRenderer.render(baseImage: source.image, snapshot: expected)
            let live = try bitmap(view)
            for point in [CGPoint(x: 160, y: 150), CGPoint(x: 160, y: 280),
                          CGPoint(x: 130, y: 270), CGPoint(x: 390, y: 160)] {
                let expectedPixel = try CaptureEditorTestPixels.pixel(rendered, x: Int(point.x / 2), y: Int(point.y / 2))
                #expect(!differs(try pixel(live, at: point, in: view), from: expectedPixel, by: 12))
            }
            #expect(session.snapshot?.annotations == initial.annotations)
        }
    }

    @Test("Arrow, straight line and capped line endpoints resize independently and win over crop handles")
    func lineEndpointEditing() throws {
        for tool in [EditorTool.arrow, .line, .markerLine] {
            let source = try source()
            let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                                initialSource: 0, initialSnapshot: EditorSnapshot(cropRect: source.pixelBounds))
            let (view, window) = canvas(session, register: true)
            defer { session.forceCancel(); window.close() }
            session.tool = tool
            try drag(view, from: CGPoint(x: 100, y: 140), to: CGPoint(x: 220, y: 180))
            let created = try #require(session.snapshot?.annotations.first)
            #expect(created.lineTool == tool)
            #expect(created.lineGeometry == LineShape(start: CGPoint(x: 50, y: 70), end: CGPoint(x: 110, y: 90)))
            // Endpoints are editable immediately after drawing, while the drawing tool remains active.
            try drag(view, from: CGPoint(x: 220, y: 180), to: CGPoint(x: 320, y: 240))
            let resized = try #require(session.snapshot?.annotations.first)
            #expect(resized.id == created.id && resized.style == created.style)
            #expect(resized.lineGeometry == LineShape(start: CGPoint(x: 50, y: 70), end: CGPoint(x: 160, y: 120)))
            session.undo()
            #expect(session.snapshot?.annotations == [created])
            session.redo()
            #expect(session.snapshot?.annotations == [resized])
            // Grabbing slightly off-center preserves the pointer offset, and Escape cancels.
            view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 104, y: 144), view: view))
            view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 164, y: 204), view: view))
            #expect(session.snapshot?.annotations == [resized])
            #expect(view.cancelGesture())
            try drag(view, from: CGPoint(x: 100, y: 140), to: CGPoint(x: 180, y: 280))
            #expect(session.snapshot?.annotations.first?.lineGeometry == LineShape(start: CGPoint(x: 90, y: 140), end: CGPoint(x: 160, y: 120)))
            // Clamp to the image, then grab the endpoint coincident with the screenshot's corner handle.
            try drag(view, from: CGPoint(x: 320, y: 240), to: CGPoint(x: 900, y: 900))
            #expect(session.snapshot?.annotations.first?.lineGeometry?.end == CGPoint(x: 320, y: 240))
            try drag(view, from: CGPoint(x: 640, y: 480), to: CGPoint(x: 500, y: 350))
            #expect(session.snapshot?.cropRect == source.pixelBounds)
            #expect(session.snapshot?.annotations.first?.lineGeometry == LineShape(start: CGPoint(x: 90, y: 140), end: CGPoint(x: 250, y: 175)))
            let beforeMove = try #require(session.snapshot?.annotations.first)
            session.tool = .select
            try drag(view, from: CGPoint(x: 340, y: 315), to: CGPoint(x: 360, y: 335))
            #expect(session.snapshot?.annotations == [beforeMove.translated(by: CGSize(width: 10, height: 10))])
            let geometry = session.snapshot?.annotations.first?.lineGeometry
            for newTool in [EditorTool.arrow, .line, .markerLine] {
                session.setLineTool(newTool)
                #expect(session.snapshot?.annotations.count == 1)
                #expect(session.snapshot?.annotations.first?.lineTool == newTool)
                #expect(session.snapshot?.annotations.first?.lineGeometry == geometry)
                let snapshot = try #require(session.snapshot)
                let data = try JSONEncoder().encode(snapshot)
                #expect(try JSONDecoder().decode(EditorSnapshot.self, from: data) == snapshot)
            }
        }
    }

    @Test("Unified shape properties edit existing geometry, remember each tool, and group slider changes into one undo")
    func unifiedShapeProperties() throws {
        let source = try source()
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                            initialSource: 0, initialSnapshot: EditorSnapshot(cropRect: source.pixelBounds))
        let (view, window) = canvas(session, register: true)
        defer { session.forceCancel(); window.close() }
        #expect(!CaptureEditingToolbar.primaryTools.contains(.highlight))
        #expect(!CaptureEditingToolbar.primaryTools.contains(.arrow))
        session.selectDrawingTool(.rectangle)
        session.setShapeAppearance("highlight")
        try drag(view, from: CGPoint(x: 100, y: 140), to: CGPoint(x: 220, y: 220))
        let filled = try #require(session.snapshot?.annotations.first)
        #expect(filled.propertyTool == .rectangle)
        #expect(filled.style.lineWidth == 0 && filled.style.fillColor.alpha > 0 && filled.style.opacity == 0.32)
        session.beginStyleAdjustment()
        try writeEvidence(bitmap(view), name: "synthetic-native-unified-shape-properties.png")
        session.setAnnotationOpacity(0.5); session.setAnnotationOpacity(0.7); session.setAnnotationOpacity(0.9)
        let preview = try bitmap(view)
        let expectedImage = try EditorRenderer.render(baseImage: source.image, snapshot: #require(session.snapshot))
        #expect(!differs(try pixel(preview, at: CGPoint(x: 160, y: 180), in: view),
                        from: try CaptureEditorTestPixels.pixel(expectedImage, x: 80, y: 90), by: 12))
        session.endStyleAdjustment()
        #expect(session.snapshot?.annotations.first?.style.opacity == 0.9)
        session.undo()
        #expect(session.snapshot?.annotations == [filled])
        session.redo()
        #expect(session.snapshot?.annotations.first?.style.opacity == 0.9)
        session.setAnnotationStroke(true)
        session.setAnnotationFillColor(.ellipseStroke)
        session.setAnnotationColor(.arrowStroke)
        #expect(session.snapshot?.annotations.first?.style.fillColor == .ellipseStroke)
        #expect(session.snapshot?.annotations.first?.style.strokeColor == .arrowStroke)
        #expect(session.snapshot?.annotations.first?.id == filled.id)
        #expect(session.snapshot?.annotations.first?.boundingRect == filled.boundingRect)
        session.setAnnotationFill(false)
        #expect(session.snapshot?.annotations.first?.style.fillColor == .clear)
        #expect(try #require(session.snapshot?.annotations.first?.style.lineWidth) > 0)
        session.selectDrawingTool(.ellipse)
        #expect(session.snapshot?.selectedAnnotationIDs.isEmpty == true)
        #expect(session.displayedStyle.fillColor == .clear && session.displayedStyle.opacity == 1)
        session.selectDrawingTool(.rectangle)
        #expect(session.displayedStyle.opacity == 0.9)
        #expect(session.displayedStyle.fillColor == .clear)
        // Old highlights become ordinary rectangles when their attributes are edited.
        let legacy = Annotation(kind: .highlight(HighlightShape(rect: CGRect(x: 30, y: 40, width: 50, height: 30))))
        session.apply(AddAnnotationCommand(annotation: legacy))
        #expect(session.propertyTool == .rectangle && session.showsShapeControls)
        #expect(session.displayedStyle.lineWidth == 0)
        session.setAnnotationOpacity(0.6)
        let updated = try #require(session.snapshot?.annotations.last)
        if case .rectangle(let shape) = updated.kind { #expect(shape.rect == CGRect(x: 30, y: 40, width: 50, height: 30)) }
        else { Issue.record("Edited legacy highlight must be a rectangle") }
        session.undo(); #expect(session.snapshot?.annotations.last == legacy)
        session.selectDrawingTool(.pixelate)
        #expect(session.showsAnnotationPalette && session.showsRedactionControls)
        session.setRedactionTool(.blur)
        try drag(view, from: CGPoint(x: 350, y: 150), to: CGPoint(x: 450, y: 230))
        let hiddenID = session.snapshot?.annotations.last?.id
        session.setRedactionTool(.redact)
        #expect(session.snapshot?.annotations.last?.id == hiddenID)
        #expect(session.snapshot?.annotations.last?.propertyTool == .redact)
    }

    @Test("Text input is transparent, fits committed multiline text and grows again when re-edited")
    func transparentTextAndTightBounds() async throws {
        let source = try source()
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                            initialSource: 0, initialSnapshot: EditorSnapshot(cropRect: source.pixelBounds))
        let (view, window) = canvas(session, register: true)
        defer { session.forceCancel(); window.close() }
        session.selectDrawingTool(.text)
        let baseline = try bitmap(view)
        try click(view, at: CGPoint(x: 100, y: 140))
        let editor = try #require(textEditor(in: view))
        #expect(!editor.drawsBackground)
        #expect((editor.superview as? NSClipView)?.drawsBackground == false)
        editor.string = "文字输入\n第二行 gj"
        let container = try #require(editor.textContainer)
        let layout = try #require(editor.layoutManager)
        layout.ensureLayout(for: container)
        let measured = layout.usedRect(for: container)
        let preview = try bitmap(view)
        let blank = CGPoint(x: 400, y: 270)
        #expect(!differs(try pixel(preview, at: blank, in: view), from: try pixel(baseline, at: blank, in: view), by: 8))
        session.commitText()
        let annotation = try #require(session.snapshot?.annotations.last)
        #expect(annotation.boundingRect.width == ceil(measured.maxX*view.annotationPixelScale)+1)
        #expect(annotation.boundingRect.height == ceil(measured.maxY*view.annotationPixelScale)+1)
        #expect(annotation.boundingRect.width < 200 && annotation.boundingRect.height < 80)
        let output = try EditorRenderer.render(baseImage: source.image, snapshot: #require(session.snapshot))
        #expect(try CaptureEditorTestPixels.rgba(#require(output.cropping(to: annotation.boundingRect.integral))) !=
                    CaptureEditorTestPixels.rgba(#require(source.image.cropping(to: annotation.boundingRect.integral))))
        for _ in 0..<100 {
            if session.renderedImageMatches(try #require(session.snapshot)) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        session.tool = .select
        try click(view, at: CGPoint(x: 120, y: 160), clickCount: 2)
        let reopened = try #require(textEditor(in: view))
        #expect(reopened.frame.width > annotation.boundingRect.width/view.annotationPixelScale,
                "A fitted box must not force newly appended text to wrap at the old short width")
        reopened.string = ""
        let cleared = try bitmap(view)
        #expect(!differs(try pixel(cleared, at: CGPoint(x: 160, y: 168), in: view),
                        from: try pixel(baseline, at: CGPoint(x: 160, y: 168), in: view), by: 8),
                "Transparent re-editing must hide the previous rasterized text")
        reopened.string = "Hi"
        let reopenedContainer = try #require(reopened.textContainer)
        reopened.layoutManager?.ensureLayout(for: reopenedContainer)
        let shorter = try #require(reopened.layoutManager?.usedRect(for: reopenedContainer))
        session.commitText()
        #expect(session.snapshot?.annotations.last?.id == annotation.id)
        #expect(session.snapshot?.annotations.last?.boundingRect.width == ceil(shorter.maxX*view.annotationPixelScale)+1)
        #expect(try #require(session.snapshot?.annotations.last?.boundingRect.width) < annotation.boundingRect.width)
        session.undo(); #expect(session.snapshot?.annotations.last == annotation)
    }

    @Test("Mosaic and blur default to four and independently clamp strength to one through ten")
    func mosaicStrengthLimits() throws {
        let source = try source()
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                            initialSource: 0, initialSnapshot: EditorSnapshot(cropRect: source.pixelBounds))
        let (view, window) = canvas(session, register: true)
        defer { session.forceCancel(); window.close() }
        session.selectDrawingTool(.pixelate)
        #expect(session.displayedRedactionRadius == 4)
        #expect(session.redactionStrengthRange == 1...10)
        #expect(session.annotationStyle(pixelScale: 2).effectRadius == 8)
        session.setRedactionRadius(0); #expect(session.displayedRedactionRadius == 1)
        session.setRedactionRadius(99); #expect(session.displayedRedactionRadius == 10)
        session.setRedactionRadius(4)
        try drag(view, from: CGPoint(x: 100, y: 140), to: CGPoint(x: 220, y: 220))
        let annotation = try #require(session.snapshot?.annotations.last)
        #expect(annotation.style.effectRadius == 4*view.annotationPixelScale)
        session.tool = .select
        session.setRedactionRadius(20)
        #expect(session.displayedRedactionRadius == 10)
        #expect(session.snapshot?.annotations.last?.style.effectRadius == 10*view.annotationPixelScale)
        session.undo(); #expect(session.snapshot?.annotations.last == annotation)
        session.selectDrawingTool(.blur)
        #expect(session.redactionStrengthRange == 1...10)
        #expect(session.displayedRedactionRadius == 4)
        session.setRedactionRadius(0); #expect(session.displayedRedactionRadius == 1)
        session.setRedactionRadius(30); #expect(session.displayedRedactionRadius == 10)
        session.setRedactionRadius(3); #expect(session.displayedRedactionRadius == 3)
        session.selectDrawingTool(.pixelate)
        #expect(session.displayedRedactionRadius == 10)
    }

    @Test("Native initial drag snaps to frozen window candidates and commits source-pixel crop without a confirmation")
    func initialDragSnap() throws {
        let source = try source(), id = UUID()
        let candidate = CaptureSnapCandidate(id: "frozen-window", source: .window, rect: CGRect(x: 100, y: 120, width: 100, height: 100), confidence: 1, snapshotID: id)
        let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [candidate])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        try drag(view, from: CGPoint(x: 100, y: 120), to: CGPoint(x: 194, y: 214))
        #expect(session.snapshot?.cropRect == CGRect(x: 50, y: 60, width: 50, height: 50))
        #expect(session.activeSource == 0)
    }
    @Test("Native hover previews frozen window and content-block boundaries before any selection")
    func hoverBoundaries() throws {
        let source = try panelSource(), id = UUID()
        let candidates = [
            CaptureSnapCandidate(id: "outer-window", source: .window,
                rect: CGRect(x: 80, y: 80, width: 480, height: 320), confidence: 1, snapshotID: id),
            CaptureSnapCandidate(id: "inner-content", source: .contentBlock,
                rect: CGRect(x: 240, y: 240, width: 160, height: 110), confidence: 0.95, snapshotID: id)
        ]
        let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: candidates)
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        try move(view, to: CGPoint(x: 130, y: 130))
        #expect(view.hoverCandidateID == "outer-window")
        #expect(session.snapshot == nil)
        try writeSnapEvidence(bitmap(view), name: "synthetic-hover-window.png")
        try move(view, to: CGPoint(x: 300, y: 280))
        #expect(view.hoverCandidateID == "inner-content")
        #expect(session.snapshot == nil)
        try writeSnapEvidence(bitmap(view), name: "synthetic-hover-content.png")
        try move(view, to: CGPoint(x: 20, y: 20))
        #expect(view.hoverCandidateID == "display-fallback")
        try writeSnapEvidence(bitmap(view), name: "synthetic-hover-full-display.png")
    }

    @Test("Entering before any drag previews the complete bright candidate frame")
    func hoverFullFrameBrightness() throws {
        let source = try panelSource(), id = UUID()
        let candidate = CaptureSnapCandidate(id: "outer-window", source: .window,
            rect: CGRect(x: 80, y: 80, width: 480, height: 320), confidence: 1, snapshotID: id)
        let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [candidate])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        try enter(view, at: CGPoint(x: 130, y: 130))
        #expect(view.hoverCandidateID == "outer-window")
        #expect(session.snapshot == nil)
        let hovered = try bitmap(view)
        try writeSnapEvidence(hovered, name: "synthetic-hover-full-frame.png")

        try exit(view, at: CGPoint(x: 20, y: 20))
        #expect(view.hoverCandidateID == nil)
        let dimmed = try bitmap(view)
        try writeSnapEvidence(dimmed, name: "synthetic-no-hover-dimmed.png")

        // A frozen bright panel is inside the candidate; hovering should show its real pixels.
        let interior = CGPoint(x: 170, y: 180)
        let hoverPixel = try pixel(hovered, at: interior, in: view)
        let dimPixel = try pixel(dimmed, at: interior, in: view)
        let sourcePixel = try CaptureEditorTestPixels.pixel(source.image,
            x: Int(interior.x / 2), y: Int(interior.y / 2))
        for channel in 0..<3 {
            #expect(abs(Int(hoverPixel[channel]) - Int(sourcePixel[channel])) <= 8)
        }
        #expect(differs(hoverPixel, from: dimPixel, by: 30))

        // The whole perimeter, not merely a corner near the pointer, is visibly outlined.
        let edgeCenters = [CGPoint(x: 320, y: 80), CGPoint(x: 560, y: 240),
                           CGPoint(x: 320, y: 400), CGPoint(x: 80, y: 240)]
        for center in edgeCenters {
            let samples = [CGPoint(x: center.x - 1, y: center.y), center,
                           CGPoint(x: center.x + 1, y: center.y),
                           CGPoint(x: center.x, y: center.y - 1),
                           CGPoint(x: center.x, y: center.y + 1)]
            var outlined = false
            for sample in samples {
                let hoverEdge = try pixel(hovered, at: sample, in: view)
                let dimEdge = try pixel(dimmed, at: sample, in: view)
                if differs(hoverEdge, from: dimEdge, by: 25) { outlined = true }
            }
            #expect(outlined, "Hover border should be visible at all four sides")
        }
    }
    @Test("Native pixel loupe previews the frozen source before selecting")
    func pixelLoupeBeforeSelection() throws {
        let source = try source(), session = CaptureEditingSession(
            sources: [source], snapshotID: UUID(), candidates: [])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        session.theme = .light; view.sessionChanged()
        try move(view, to: CGPoint(x: 200, y: 200))
        let sample = try #require(view.loupeSample)
        #expect(sample.point == CapturePixelPoint(x: 100, y: 100))
        #expect(sample.color == CapturePixelColor(red: 62, green: 92, blue: 40))
        #expect(view.pixelColorFormat == .hex)
        #expect(view.loupeFrame != nil)
        #expect(session.snapshot == nil)
        try writeLoupeEvidence(bitmap(view), name: "synthetic-loupe-before-selection-light.png")
    }
    @Test("Native loupe keeps colors local to the frozen image across copy, Shift, drag and editing")
    func pixelLoupeInteractions() async throws {
        let source = try source(), session = CaptureEditingSession(
            sources: [source], snapshotID: UUID(), candidates: [])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        var copied: [String] = []
        var screenshotCopies = 0
        view.colorClipboardWriter = { copied.append($0) }
        session.output = { _, _, _ in screenshotCopies += 1; return .saveCancelled }

        try move(view, to: CGPoint(x: 638, y: 478))
        #expect(view.loupeSample?.point == CapturePixelPoint(x: 319, y: 239))
        #expect(view.loupeFrame.map { view.bounds.insetBy(dx: 10, dy: 10).contains($0) } == true)
        try writeLoupeEvidence(bitmap(view), name: "synthetic-loupe-edge-light.png")

        try move(view, to: CGPoint(x: 200, y: 200))
        let sample = try #require(view.loupeSample)
        view.keyDown(with: try key(view, characters: "c", keyCode: 8))
        #expect(copied == [sample.color.hex]); #expect(screenshotCopies == 0)
        try writeLoupeEvidence(bitmap(view), name: "synthetic-loupe-copy-feedback.png")

        view.flagsChanged(with: try key(view, type: .flagsChanged, modifiers: .shift,
            keyCode: 56, timestamp: 10))
        view.flagsChanged(with: try key(view, type: .flagsChanged,
            keyCode: 56, timestamp: 10.25))
        #expect(view.pixelColorFormat == .rgb)
        session.theme = .dark; view.sessionChanged()
        try writeLoupeEvidence(bitmap(view), name: "synthetic-loupe-rgb-dark.png")
        view.keyDown(with: try key(view, characters: "c", keyCode: 8))
        #expect(copied == [sample.color.hex, sample.color.rgb])

        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 60, y: 70), view: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 300, y: 250), view: view))
        #expect(view.loupeSample?.point == CapturePixelPoint(x: 150, y: 125))
        try writeLoupeEvidence(bitmap(view), name: "synthetic-loupe-during-drag.png")
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 250), view: view))
        #expect(session.snapshot != nil); #expect(view.loupeSample == nil)

        // Dragging an existing handle reveals the loupe while the editing toolbar remains visible.
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 300, y: 250), view: view))
        #expect(view.loupeSample != nil)
        let loupe = try #require(view.loupeFrame)
        #expect(view.bounds.insetBy(dx: 10, dy: 10).contains(loupe))
        if let toolbar = view.subviews.first(where: { !$0.isHidden && $0.frame.width >= 260 }) {
            #expect(!loupe.intersects(toolbar.frame))
        }
        try writeLoupeEvidence(bitmap(view), name: "synthetic-loupe-toolbar-avoidance.png")
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 250), view: view))

        view.keyDown(with: try key(view, characters: "c", modifiers: .command, keyCode: 8))
        for _ in 0..<100 where screenshotCopies == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(screenshotCopies == 1)
        #expect(copied == [sample.color.hex, sample.color.rgb])

        session.tool = .text
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 100), view: view))
        #expect(session.textEditing); #expect(view.loupeSample == nil)
        let editor = try #require(textEditor(in: view))
        editor.keyDown(with: try key(view, characters: "c", keyCode: 8))
        #expect(editor.string.contains("c"))
        #expect(copied == [sample.color.hex, sample.color.rgb])
        session.abortText()
    }

    @Test("Native click selects the small content block and exposes the editing toolbar")
    func clickContentBlock() throws {
        let source = try panelSource(), id = UUID()
        let candidate = CaptureSnapCandidate(id: "inner-content", source: .contentBlock,
            rect: CGRect(x: 240, y: 240, width: 160, height: 110), confidence: 0.95, snapshotID: id)
        let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [candidate])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        try move(view, to: CGPoint(x: 300, y: 280))
        try click(view, at: CGPoint(x: 300, y: 280))
        #expect(session.snapshot?.cropRect == CGRect(x: 120, y: 120, width: 80, height: 55))
        #expect(view.subviews.contains { !$0.isHidden && $0.frame.width >= 260 })
        try writeSnapEvidence(bitmap(view), name: "synthetic-click-content-toolbar.png")
    }

    @Test("Two real clicks copy the chosen candidate or full display once and finish")
    func doubleClickCopiesCurrentRegion() async throws {
        let source = try panelSource(), id = UUID()
        let candidate = CaptureSnapCandidate(id: "inner-content", source: .contentBlock,
            rect: CGRect(x: 240, y: 240, width: 160, height: 110), confidence: 0.95, snapshotID: id)
        let scenarios: [([CaptureSnapCandidate], CGPoint, CGRect, String)] = [
            ([candidate], CGPoint(x: 300, y: 280), CGRect(x: 120, y: 120, width: 80, height: 55), "synthetic-single-click-candidate.png"),
            ([], CGPoint(x: 320, y: 430), source.pixelBounds, "synthetic-single-click-full-display.png"),
            ([], CGPoint(x: 2, y: 2), source.pixelBounds, "synthetic-single-click-full-display-edge.png")
        ]
        for (candidates, point, expected, evidence) in scenarios {
            let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: candidates)
            let (view, window) = canvas(session)
            var outputs: [CGRect] = [], copyActions = 0, finishes = 0
            session.output = { document, action, _ in
                outputs.append(document.snapshot.cropRect)
                if case .copy = action { copyActions += 1 }
                return .success
            }
            session.didFinish = { finishes += 1 }
            try click(view, at: point, clickCount: 1)
            #expect(session.snapshot?.cropRect == expected)
            #expect(outputs.isEmpty); #expect(finishes == 0)
            if candidates.isEmpty {
                let toolbar = try #require(view.subviews.first(where: { !$0.isHidden && $0.frame.width >= 260 }))
                #expect(!toolbar.frame.contains(point), "Toolbar must leave the first click point free for the second click")
                #expect(view.hitTest(view.convert(point, to: nil)) === view)
            }
            try writeSnapEvidence(bitmap(view), name: evidence)
            try click(view, at: point, clickCount: 2)
            for _ in 0..<100 {
                if finishes == 1 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(outputs == [expected])
            #expect(copyActions == 1)
            #expect(finishes == 1)
            session.forceCancel(); window.close()
        }
    }

    @Test("Native drag shows guides before release and commits snapped source pixels")
    func dragGuideBeforeRelease() throws {
        let source = try panelSource(), id = UUID()
        let candidate = CaptureSnapCandidate(id: "outer-window", source: .window,
            rect: CGRect(x: 80, y: 80, width: 480, height: 320), confidence: 1, snapshotID: id)
        let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [candidate])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 80), view: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 554, y: 394), view: view))
        #expect(session.snapshot == nil)
        try writeSnapEvidence(bitmap(view), name: "synthetic-drag-snap-guides.png")
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 554, y: 394), view: view))
        #expect(session.snapshot?.cropRect == CGRect(x: 40, y: 40, width: 240, height: 160))
    }

    @Test("Small pointer jitter clicks a candidate, while deliberate drag makes a free rectangle")
    func clickVersusDragThreshold() throws {
        let source = try source(), id = UUID()
        let candidate = CaptureSnapCandidate(id: "panel", source: .contentBlock,
            rect: CGRect(x: 240, y: 240, width: 160, height: 110), confidence: 1, snapshotID: id)
        let clickSession = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [candidate])
        let (clickView, clickWindow) = canvas(clickSession)
        defer { clickSession.forceCancel(); clickWindow.close() }
        try move(clickView, to: CGPoint(x: 300, y: 280))
        #expect(clickView.hoverCandidateID == "panel")
        clickView.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 300, y: 280), view: clickView))
        #expect(clickView.hoverCandidateID == "panel")
        clickView.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 303, y: 282), view: clickView))
        #expect(clickView.hoverCandidateID == "panel")
        #expect(clickSession.snapshot == nil)
        clickView.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 303, y: 282), view: clickView))
        #expect(clickSession.snapshot?.cropRect == CGRect(x: 120, y: 120, width: 80, height: 55))

        let dragSession = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [candidate])
        let (dragView, dragWindow) = canvas(dragSession)
        defer { dragSession.forceCancel(); dragWindow.close() }
        try move(dragView, to: CGPoint(x: 300, y: 280))
        #expect(dragView.hoverCandidateID == "panel")
        dragView.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 300, y: 280), view: dragView))
        dragView.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 420, y: 380), view: dragView))
        #expect(dragView.hoverCandidateID == nil)
        #expect(dragSession.snapshot == nil)
        dragView.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 420, y: 380), view: dragView))
        #expect(dragSession.snapshot?.cropRect == CGRect(x: 150, y: 140, width: 60, height: 50))
    }

    @Test("Async candidate append refreshes a stationary pointer; stale results do not replace it")
    func appendedCandidateRefresh() throws {
        let source = try source(), id = UUID()
        let session = CaptureEditingSession(sources: [source], snapshotID: id, candidates: [])
        let (view, window) = canvas(session, register: true)
        defer { session.forceCancel(); window.close() }
        try move(view, to: CGPoint(x: 300, y: 280))
        #expect(view.hoverCandidateID == "display-fallback")
        let arriving = CaptureSnapCandidate(id: "late-panel", source: .contentBlock,
            rect: CGRect(x: 240, y: 240, width: 160, height: 110), confidence: 1, snapshotID: id)
        session.appendCandidates([arriving], sourceIndex: 0, snapshotID: id)
        #expect(view.hoverCandidateID == "late-panel")
        let stale = CaptureSnapCandidate(id: "stale", source: .contentBlock,
            rect: CGRect(x: 290, y: 270, width: 20, height: 20), confidence: 1, snapshotID: UUID())
        session.appendCandidates([stale], sourceIndex: 0, snapshotID: UUID())
        #expect(view.hoverCandidateID == "late-panel")
    }

    @Test("Without a candidate, single click selects the display while a fresh drag draws freely")
    func noCandidateFallback() throws {
        let source = try source(), session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [])
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        try move(view, to: CGPoint(x: 100, y: 120))
        #expect(view.hoverCandidateID == "display-fallback")
        try click(view, at: CGPoint(x: 100, y: 120))
        #expect(session.snapshot?.cropRect == source.pixelBounds)
        let freshSession = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [])
        let (freshView, freshWindow) = canvas(freshSession)
        defer { freshSession.forceCancel(); freshWindow.close() }
        try drag(freshView, from: CGPoint(x: 60, y: 70), to: CGPoint(x: 190, y: 170))
        #expect(freshSession.snapshot?.cropRect == CGRect(x: 30, y: 35, width: 65, height: 50))
    }
    @Test("History fit-to-window reselect maps the drawn image rectangle back to original pixels")
    func historyReselect() throws {
        let source = try source()
        let initial = EditorSnapshot(cropRect: CGRect(x: 50, y: 40, width: 100, height: 80))
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0, initialSnapshot: initial)
        let (view, window) = canvas(session, history: true); defer { session.forceCancel(); window.close() }
        // In this 640×480 history canvas, the 320×240 image fits at (96,72), 448×336 (1.4×).
        try drag(view, from: CGPoint(x: 110, y: 100), to: CGPoint(x: 208, y: 212))
        #expect(session.snapshot?.cropRect == CGRect(x: 10, y: 20, width: 70, height: 80))
    }
    @Test("All eight native handles resize before active drawing tool hit-testing")
    func handlesBeforeDrawing() throws {
        let source = try source(), crop = CGRect(x: 40, y: 30, width: 160, height: 120)
        for handle in CaptureResizeHandle.allCases {
            let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0, initialSnapshot: EditorSnapshot(cropRect: crop))
            session.tool = .redact
            let (view, window) = canvas(session)
            let point = handle.position(in: CGRect(x: 80, y: 60, width: 320, height: 240))
            try drag(view, from: point, to: CGPoint(x: point.x + (handle.movesMinX ? -20 : 20), y: point.y + (handle.movesMinY ? -20 : 20)))
            #expect(session.snapshot?.annotations.isEmpty == true)
            #expect(session.snapshot?.cropRect != crop)
            session.forceCancel(); window.close()
        }
    }
    @Test("Native light dark and narrow canvases preserve frozen pixels and record explicitly synthetic screenshots")
    func themeAndVisualEvidence() throws {
        let oldTheme = UserDefaults.standard.object(forKey: "prosio.capture.theme")
        defer { if let oldTheme { UserDefaults.standard.set(oldTheme, forKey: "prosio.capture.theme") } else { UserDefaults.standard.removeObject(forKey: "prosio.capture.theme") } }
        let source = try source(), initial = EditorSnapshot(cropRect: CGRect(x: 20, y: 20, width: 250, height: 160))
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0, initialSnapshot: initial)
        session.tool = .rectangle
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        let before = try CaptureEditorTestPixels.rgba(session.sources[0].image)
        session.theme = .light; view.sessionChanged()
        let light = try bitmap(view); try writeEvidence(light, name: "synthetic-native-light.png")
        session.theme = .dark; view.sessionChanged()
        let dark = try bitmap(view); try writeEvidence(dark, name: "synthetic-native-dark.png")
        let toolbar = try #require(view.subviews.first(where: { !$0.isHidden && $0.frame.width >= 260 }))
        #expect(toolbar.frame.width <= 420 && toolbar.frame.height <= 54,
                "The approved capture toolbar stays a compact single row")
        session.tool = .select; view.sessionChanged()
        #expect(toolbar.frame.height <= 54, "Selecting a different tool must not add a settings row")
        #expect(session.snapshot == initial)
        #expect(try CaptureEditorTestPixels.rgba(session.sources[0].image) == before)
        #expect(light.pixelsWide > 0 && dark.pixelsWide > 0)
        let lightImage = try #require(light.cgImage), darkImage = try #require(dark.cgImage)
        let scaleX = CGFloat(light.pixelsWide) / view.bounds.width, scaleY = CGFloat(light.pixelsHigh) / view.bounds.height
        // The contextual property panel is taller now; sample only unobstructed screenshot pixels.
        let covered = view.subviews.map { $0.frame.insetBy(dx: -12, dy: -12) }
        let samplePoints = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 120), CGPoint(x: 450, y: 130),
                            CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), CGPoint(x: 450, y: 250)]
            .filter { point in !covered.contains(where: { $0.contains(point) }) }
        #expect(samplePoints.count >= 3)
        for point in samplePoints {
            let lightPixel = try CaptureEditorTestPixels.pixel(lightImage, x: Int(point.x * scaleX), y: Int(point.y * scaleY))
            let darkPixel = try CaptureEditorTestPixels.pixel(darkImage, x: Int(point.x * scaleX), y: Int(point.y * scaleY))
            let sourcePixel = try CaptureEditorTestPixels.pixel(source.image, x: Int(point.x / 2), y: Int(point.y / 2))
            #expect(lightPixel == darkPixel)
            for channel in 0..<3 { #expect(abs(Int(lightPixel[channel]) - Int(sourcePixel[channel])) <= 6) }
        }
        let (narrow, narrowWindow) = canvas(session, size: CGSize(width: 280, height: 480), history: true)
        defer { narrowWindow.close() }
        try writeEvidence(bitmap(narrow), name: "synthetic-native-narrow.png")
        for child in narrow.subviews { #expect(narrow.bounds.contains(child.frame)) }
    }

    @Test("Annotation colors appear contextually, remain visible at screen edges, and affect the next stroke")
    func contextualAnnotationColors() async throws {
        let source = try source()
        let initial = EditorSnapshot(cropRect: CGRect(x: 15, y: 15, width: 285, height: 205))
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [],
                                            initialSource: 0, initialSnapshot: initial)
        let (view, window) = canvas(session, register: true); defer { session.forceCancel(); window.close() }
        func palette() -> NSHostingView<CaptureAnnotationPalette>? {
            view.subviews.compactMap { $0 as? NSHostingView<CaptureAnnotationPalette> }.first
        }
        #expect(palette() == nil)
        session.tool = .rectangle
        let colors = try #require(palette())
        let tools = try #require(view.subviews.compactMap { $0 as? NSHostingView<CaptureEditingToolbar> }.first)
        #expect(!colors.isHidden)
        #expect(!tools.frame.intersects(colors.frame))
        #expect(view.bounds.insetBy(dx: 12, dy: 12).contains(colors.frame))
        #expect(tools.frame.height <= 42)
        session.setAnnotationColor(.ellipseStroke)
        #expect(session.annotationStyle(pixelScale: 1).strokeColor == .ellipseStroke)
        try drag(view, from: CGPoint(x: 220, y: 180), to: CGPoint(x: 350, y: 250))
        let annotation = try #require(session.snapshot?.annotations.last)
        #expect(session.snapshot?.selectedAnnotationIDs == [annotation.id])
        #expect(annotation.style.strokeColor == .ellipseStroke)
        session.setAnnotationColor(.arrowStroke)
        #expect(session.snapshot?.annotations.last?.style.strokeColor == .arrowStroke)
        #expect(session.displayedAnnotationColor == .arrowStroke)
        session.undo()
        #expect(session.snapshot?.annotations.last?.style.strokeColor == .ellipseStroke)
        session.redo()
        #expect(session.snapshot?.annotations.last?.style.strokeColor == .arrowStroke)
        let document = try #require(session.snapshot)
        let output = try EditorRenderer.render(baseImage: source.image, snapshot: document)
        let stroke = try CaptureEditorTestPixels.pixel(output, x: 127, y: 75)
        #expect(stroke[0] > 180 && stroke[1] > 110 && stroke[2] < 90,
                "The recolored annotation must appear in the exported pixels")
        var liveRenderCaughtUp = false
        for _ in 0..<80 {
            guard let image = session.renderedImage() else {
                try await Task.sleep(for: .milliseconds(20));continue
            }
            let live = try CaptureEditorTestPixels.pixel(image, x: 127, y: 75)
            if (0..<3).allSatisfy({ abs(Int(live[$0]) - Int(stroke[$0])) <= 8 }) {
                liveRenderCaughtUp=true;break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(liveRenderCaughtUp, "The on-screen annotation must update to the chosen color")
        try writeEvidence(bitmap(view), name: "synthetic-native-annotation-palette.png")
        session.tool = .select
        #expect(!colors.isHidden, "The selected annotation still exposes its color controls")
        session.selectAnnotation(nil)
        #expect(colors.isHidden)
        session.tool = .freehand
        #expect(!colors.isHidden)
    }
    @Test("Left and right replay saved screenshots and restore the in-progress capture")
    func screenshotHistoryReplay() async throws {
        let live = try source()
        let liveSnapshot = EditorSnapshot(cropRect: CGRect(x: 30, y: 25, width: 160, height: 100),
            annotations: [Annotation(kind:.rectangle(RectangleShape(rect:CGRect(x:50,y:45,width:45,height:30))))])
        let session = CaptureEditingSession(sources:[live],snapshotID:UUID(),candidates:[],
            initialSource:0,initialSnapshot:liveSnapshot)
        let firstImage = try CaptureEditorTestPixels.image(width:120,height:90)
        let secondImage = try CaptureEditorTestPixels.image(width:80,height:60)
        let firstSnapshot = EditorSnapshot(cropRect:CGRect(x:0,y:0,width:120,height:90),
            annotations:[Annotation(kind:.arrow(ArrowShape(start:CGPoint(x:10,y:10),end:CGPoint(x:70,y:50))))])
        let secondSnapshot = EditorSnapshot(cropRect:CGRect(x:0,y:0,width:80,height:60))
        let now = Date(timeIntervalSince1970:1_000)
        let first = CaptureAsset(id:UUID(),version:2,createdAt:now,kind:.region,sourceName:"Previous 1",
            sourceRect:CGRect(x:0,y:0,width:120,height:90),pixelWidth:120,pixelHeight:90)
        let second = CaptureAsset(id:UUID(),version:2,createdAt:now.addingTimeInterval(-30),kind:.region,sourceName:"Previous 2",
            sourceRect:CGRect(x:0,y:0,width:80,height:60),pixelWidth:80,pixelHeight:60)
        var loads:[UUID:Int]=[:]
        session.configureHistory(assets:[first,second]) { asset in
            loads[asset.id,default:0] += 1
            let image=asset.id == first.id ? firstImage : secondImage
            let snapshot=asset.id == first.id ? firstSnapshot : secondSnapshot
            return EditableCaptureDocument(baseImage:image,snapshot:snapshot,kind:.region,
                sourceName:asset.sourceName,sourceRect:asset.sourceRect,capturedAt:asset.createdAt)
        }
        let (view,window)=canvas(session,register:true);defer { session.forceCancel();window.close() }
        let navigation=try #require(view.subviews.compactMap { $0 as? NSHostingView<CaptureHistoryNavigation> }.first)
        #expect(!navigation.isHidden)
        #expect(session.historyPosition == 0)
        view.keyDown(with:try key(view,keyCode:123))
        #expect(session.historyPosition == 1)
        #expect(view.source.image.width == 120)
        #expect(session.snapshot?.annotations == firstSnapshot.annotations)
        #expect(try session.document().baseImage.width == 120)
        for _ in 0..<100 {
            if session.renderedImage()?.width == 120 { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        #expect(session.renderedImage()?.width == 120)
        try writeEvidence(bitmap(view), name:"synthetic-native-history-replay.png")
        view.keyDown(with:try key(view,keyCode:123))
        #expect(session.historyPosition == 2)
        #expect(view.source.image.width == 80)
        session.setCrop(CGRect(x:5,y:4,width:60,height:40))
        view.keyDown(with:try key(view,keyCode:124))
        #expect(session.historyPosition == 1)
        view.keyDown(with:try key(view,keyCode:123))
        #expect(session.snapshot?.cropRect == CGRect(x:5,y:4,width:60,height:40))
        #expect(loads[first.id] == 1 && loads[second.id] == 1)
        view.keyDown(with:try key(view,keyCode:124))
        view.keyDown(with:try key(view,keyCode:124))
        #expect(session.historyPosition == 0)
        #expect(view.source.image.width == live.image.width)
        #expect(session.snapshot == liveSnapshot)
        view.keyDown(with:try key(view,keyCode:124))
        #expect(session.historyPosition == 0)
    }

    @Test("Native session rejects duplicate output, preserves edits while busy, and permits retry after save cancellation")
    func outputCancelRetry() async throws {
        let source = try source(), snapshot = EditorSnapshot(cropRect: CGRect(x: 20, y: 20, width: 100, height: 80))
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0, initialSnapshot: snapshot)
        defer { session.forceCancel() }
        var continuation: CheckedContinuation<CaptureOutputResult, Never>?
        var invocations = 0
        session.output = { _, _, _ in invocations += 1; return await withCheckedContinuation { continuation = $0 } }
        session.requestOutput(.save); session.requestOutput(.copy)
        session.setCrop(CGRect(x: 0, y: 0, width: 50, height: 50))
        for _ in 0..<200 { if continuation != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(invocations == 1); #expect(session.snapshot == snapshot)
        try #require(continuation).resume(returning: .saveCancelled); continuation = nil
        for _ in 0..<200 { if !session.isOutputting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(session.outputState.phase == .editing); #expect(session.snapshot == snapshot)
        session.requestOutput(.copy)
        for _ in 0..<200 { if continuation != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(invocations == 2)
        try #require(continuation).resume(returning: .failure("Injected output failure")); continuation = nil
        for _ in 0..<200 { if !session.isOutputting { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(session.message == "Injected output failure"); #expect(session.snapshot == snapshot)
    }
    @Test("Late native output completion cannot finish a force-cancelled session twice")
    func outputLateCompletion() async throws {
        let source = try source()
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0)
        var continuation: CheckedContinuation<CaptureOutputResult, Never>?
        var finishes = 0
        session.didFinish = { finishes += 1 }
        session.output = { _, _, _ in await withCheckedContinuation { continuation = $0 } }
        session.requestOutput(.copy)
        for _ in 0..<200 { if continuation != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        session.forceCancel(); #expect(finishes == 1)
        try #require(continuation).resume(returning: .success); continuation = nil
        try await Task.sleep(for: .milliseconds(20))
        #expect(finishes == 1); #expect(session.outputState.phase == .cancelled)
    }

    @Test("Native text Return inserts a line and Cmd-Return commits it without triggering screenshot output")
    func nativeTextReturn() throws {
        let source = try source(), initial = EditorSnapshot(cropRect: CGRect(x: 20, y: 20, width: 200, height: 150))
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0, initialSnapshot: initial)
        session.tool = .text
        let (view, window) = canvas(session); defer { session.forceCancel(); window.close() }
        #expect(session.tool == .text)
        let down = try event(.leftMouseDown, at: CGPoint(x: 120, y: 140), view: view)
        #expect(view.convert(down.locationInWindow, from: nil) == CGPoint(x: 120, y: 140))
        view.mouseDown(with: down)
        #expect(session.textEditing, "Text tool click should begin the editor; native children: \(view.subviews.map { String(describing: type(of: $0)) })")
        let editor = try #require(textEditor(in: view))
        editor.string = "First line"; editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let ordinary = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: ordinary)
        #expect(session.textEditing); #expect(editor.string.contains("\n")); #expect(session.snapshot?.annotations.isEmpty == true)
        let commit = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: commit)
        #expect(!session.textEditing); #expect(session.outputState.phase == .editing)
        #expect(session.snapshot?.annotations.count == 1)
    }

    @Test("History text re-edit keeps stored source-pixel style and scales the native font to fitted image")
    func historyTextStyle() throws {
        let source = try source()
        var style = AnnotationStyle(); style.fontSize = 30; style.strokeColor = RGBAColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1)
        let annotation = Annotation(id: UUID(), kind: .text(TextShape(rect: CGRect(x: 60, y: 60, width: 120, height: 80), text: "Stored text")), style: style)
        let session = CaptureEditingSession(sources: [source], snapshotID: UUID(), candidates: [], initialSource: 0, initialSnapshot: EditorSnapshot(cropRect: source.pixelBounds, annotations: [annotation]))
        let (view, window) = canvas(session, history: true); defer { session.forceCancel(); window.close() }
        try click(view, at: CGPoint(x: 200, y: 180), clickCount: 1)
        #expect(!session.textEditing)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(CGPoint(x: 200, y: 180), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        view.mouseDown(with: click)
        let editor = try #require(textEditor(in: view))
        #expect(abs((editor.font?.pointSize ?? 0) - 42) < 0.01)
        #expect(editor.textContainerInset == .zero); #expect(editor.textContainer?.lineFragmentPadding == 0)
        session.commitText()
        #expect(session.snapshot?.annotations.first?.id == annotation.id)
        #expect(session.snapshot?.annotations.first?.style == style)
    }

}
