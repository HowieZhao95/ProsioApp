import AppKit
import SwiftUI

@MainActor
final class CaptureEditingCanvas: NSView {
    let sourceIndex: Int
    unowned let session: CaptureEditingSession
    let isHistory: Bool
    private var toolbar: NSHostingView<CaptureEditingToolbar>?
    private var annotationPalette: NSHostingView<CaptureAnnotationPalette>?
    private var historyNavigation: NSHostingView<CaptureHistoryNavigation>?
    private var toolbarSide: CaptureToolbarSide?
    private var textClipView:NSClipView?
    private var textView: CaptureAnnotationTextView?
    private var editingTextID: UUID?
    private var editingTextStyle: AnnotationStyle?
    private var gesture: Gesture?
    private var temporarySelection: CGRect?
    private var draft: Annotation?
    private var pendingAnnotationSnapshot: EditorSnapshot?
    private var snapState=CaptureSnapState()
    private var guides: [CaptureSnapGuide]=[]
    static let selectionDragThreshold: CGFloat = 5
    private(set) var hoverCandidateID: String?
    private var hoverPreviewCandidate: CaptureSnapCandidate?
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var pixelSampler: CapturePixelSampler?
    private var attemptedPixelSampler=false
    private(set) var pixelColorFormat: CapturePixelColorFormat = .hex
    private var shiftPressedAt: TimeInterval?
    private var copiedColorUntil: TimeInterval = 0
    var colorClipboardWriter: (String) -> Void = { value in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value,forType:.string)
    }
    private var didDragSelection=false
    private var lastConfirmationPoint: CGPoint?
    private enum Gesture {
        case selection(CGPoint,CaptureSnapCandidate?), move(CGRect,CGPoint), resize(CGRect,CaptureResizeHandle,CGPoint)
        case drawing(CGPoint), annotation(Annotation,CGPoint), endpoint(Annotation,AnnotationEndpoint,CGPoint)
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect,sourceIndex:Int,session:CaptureEditingSession,isHistory:Bool) {
        self.sourceIndex=sourceIndex;self.session=session;self.isHistory=isHistory
        super.init(frame:frame)
        setAccessibilityElement(true);setAccessibilityLabel("Screenshot selection and annotation canvas")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area=NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);trackingArea=area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) { hoverPoint=point(event);refreshHoverCandidate();needsDisplay=true }
    override func mouseMoved(with event:NSEvent) { hoverPoint=point(event);refreshHoverCandidate();needsDisplay=true }
    override func mouseExited(with event:NSEvent) { hoverPoint=nil;refreshHoverCandidate();needsDisplay=true }
    func refreshHoverAtCurrentMouse() {
        guard let window else { return }
        let local=convert(window.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)
        hoverPoint=bounds.contains(local) ? local : nil
        refreshHoverCandidate();needsDisplay=true
    }
    func refreshHoverCandidate() {
        let old=hoverCandidateID
        if case .selection(_,let pending)? = gesture,!didDragSelection,selection == nil {
            hoverPreviewCandidate=pending
        } else if let p=hoverPoint,gesture == nil,selection == nil,!isHistory,!session.isBrowsingHistory,!session.isOutputting {
            hoverPreviewCandidate=candidate(at:p)
        } else { hoverPreviewCandidate=nil }
        hoverCandidateID=hoverPreviewCandidate?.id
        if old != hoverCandidateID { needsDisplay=true }
    }
    private func candidate(at point:CGPoint)->CaptureSnapCandidate? {
        guard imageFrame.contains(point),!isHistory else { return nil }
        return CaptureSnapCandidates.hoverCandidate(at:point,candidates:session.candidates(for:sourceIndex),
            snapshotID:session.snapshotID,viewport:imageFrame)
            ?? CaptureSnapCandidate(id:"display-fallback",source:.viewport,rect:imageFrame,
                confidence:1,snapshotID:session.snapshotID)
    }
    var source: FrozenCaptureSource { session.historySource(for:sourceIndex) ?? session.sources[sourceIndex] }
    private var imageFrame: CGRect {
        guard isHistory || session.historySource(for:sourceIndex) != nil else { return source.overlayRect }
        let available=bounds.insetBy(dx:24,dy:72)
        let ratio=min(available.width/CGFloat(source.image.width),available.height/CGFloat(source.image.height))
        let size=CGSize(width:CGFloat(source.image.width)*ratio,height:CGFloat(source.image.height)*ratio)
        return CGRect(x:available.midX-size.width/2,y:available.midY-size.height/2,width:size.width,height:size.height)
    }
    var annotationPixelScale: CGFloat { CGFloat(source.image.width)/max(imageFrame.width,1) }
    private var style: AnnotationStyle { session.annotationStyle(pixelScale:CGFloat(source.image.width)/max(imageFrame.width,1)) }
    private var pixelToView: TopLeftRectTransform { TopLeftRectTransform(sourceBounds:source.pixelBounds,targetBounds:imageFrame) }
    private var viewToPixel: TopLeftRectTransform { TopLeftRectTransform(sourceBounds:imageFrame,targetBounds:source.pixelBounds) }
    private var selection: CGRect? {
        if let temporarySelection { return temporarySelection }
        guard session.activeSource == sourceIndex,let crop=session.snapshot?.cropRect else { return nil }
        return pixelToView.targetRect(fromSourceRect:crop)
    }
    private var previewCandidate: CaptureSnapCandidate? {
        guard selection == nil else { return nil }
        if case .selection(_,let candidate)? = gesture,!didDragSelection { return candidate }
        guard gesture == nil else { return nil }
        return hoverPreviewCandidate
    }
    var previewCandidateID: String? { previewCandidate?.id }
    override func setFrameSize(_ newSize:NSSize) { super.setFrameSize(newSize);sessionChanged() }
    func historyFrameChanged() {
        gesture=nil;temporarySelection=nil;draft=nil;guides=[];pendingAnnotationSnapshot=nil
        hoverPoint=nil;hoverPreviewCandidate=nil;hoverCandidateID=nil
        pixelSampler=nil;attemptedPixelSampler=false;lastConfirmationPoint=nil;toolbarSide=nil
    }
    func sessionChanged() {
        let appearance: NSAppearance?
        switch session.theme { case .system: appearance=nil;case .light:appearance=NSAppearance(named:.aqua);case .dark:appearance=NSAppearance(named:.darkAqua) }
        self.appearance=appearance
        if let selection,session.snapshot != nil,session.activeSource == sourceIndex {
            if toolbar == nil {
                let toolbar=NSHostingView(rootView:CaptureEditingToolbar(session:session))
                toolbar.setAccessibilityLabel("Screenshot tools");addSubview(toolbar);self.toolbar=toolbar
            }
            let width=min(404,max(260,bounds.width-24))
            toolbar?.rootView=CaptureEditingToolbar(session:session,width:width)
            let budget:CGFloat=42
            toolbar?.layoutSubtreeIfNeeded()
            let measured=toolbar?.fittingSize.height ?? budget
            let height=max(measured.isFinite ? measured : budget,budget)
            let placement=CaptureInteractionGeometry.toolbarPlacement(selection:selection,viewport:bounds,toolbarSize:CGSize(width:width,height:height),previousSide:toolbarSide)
            var frame=placement.frame
            if let point=lastConfirmationPoint,frame.insetBy(dx:-10,dy:-10).contains(point) {
                let safe=bounds.insetBy(dx:12,dy:12)
                let top=CGRect(x:frame.minX,y:safe.minY,width:frame.width,height:frame.height)
                let bottom=CGRect(x:frame.minX,y:safe.maxY-frame.height,width:frame.width,height:frame.height)
                if let alternative=[top,bottom].first(where: { safe.contains($0) && !$0.insetBy(dx:-10,dy:-10).contains(point) }) {
                    frame=alternative
                }
            }
            toolbarSide=placement.side;toolbar?.frame=frame;toolbar?.isHidden=false
            if session.showsAnnotationPalette {
                if annotationPalette == nil {
                    let palette=NSHostingView(rootView:CaptureAnnotationPalette(session:session,width:min(CaptureAnnotationPalette.width,max(1,bounds.width-24))))
                    palette.setAccessibilityLabel("Annotation colors")
                    addSubview(palette);annotationPalette=palette
                }
                annotationPalette?.rootView=CaptureAnnotationPalette(session:session,width:min(CaptureAnnotationPalette.width,max(1,bounds.width-24)))
                annotationPalette?.frame=CaptureInteractionGeometry.palettePlacement(
                    toolbarFrame:frame,viewport:bounds,
                    paletteSize:CGSize(width:CaptureAnnotationPalette.width,height:CaptureAnnotationPalette.height))
                annotationPalette?.isHidden=false
            } else { annotationPalette?.isHidden=true }
        } else { toolbar?.isHidden=true;annotationPalette?.isHidden=true }
        if session.historyCount > 0 && !isHistory && (!session.isBrowsingHistory || session.historySource(for:sourceIndex) != nil) {
            if historyNavigation == nil {
                let navigation=NSHostingView(rootView:CaptureHistoryNavigation(session:session,sourceIndex:sourceIndex))
                navigation.setAccessibilityLabel("Screenshot history navigation")
                addSubview(navigation);historyNavigation=navigation
            }
            historyNavigation?.rootView=CaptureHistoryNavigation(session:session,sourceIndex:sourceIndex)
            let size=CGSize(width:148,height:32)
            var frame=CGRect(x:max(12,bounds.midX-size.width/2),y:12,width:size.width,height:size.height)
            if let toolbar,!toolbar.isHidden,frame.intersects(toolbar.frame.insetBy(dx:-8,dy:-8)) {
                frame.origin.y=max(12,bounds.maxY-size.height-12)
            }
            historyNavigation?.frame=frame;historyNavigation?.isHidden=false
        } else { historyNavigation?.isHidden=true }
        refreshHoverCandidate();needsDisplay=true;window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        addCursorRect(bounds,cursor:session.tool == .select ? .crosshair : .crosshair)
        if let selection {
            if let snapshot = session.snapshot {
                for annotation in snapshot.annotations where snapshot.selectedAnnotationIDs.contains(annotation.id) {
                    if let line = annotation.lineGeometry {
                        for point in [line.start, line.end] {
                            let p = pixelToView.targetPoint(fromSourcePoint: point)
                            addCursorRect(CGRect(x: p.x-9, y: p.y-9, width: 18, height: 18), cursor: .crosshair)
                        }
                    }
                }
            }
            for h in CaptureResizeHandle.allCases {
                let p=h.position(in:selection)
                addCursorRect(CGRect(x:p.x-9,y:p.y-9,width:18,height:18),cursor:(h == .east || h == .west) ? .resizeLeftRight : (h == .north || h == .south) ? .resizeUpDown : .crosshair)
            }
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.setFill();bounds.fill()
        NSImage(cgImage:source.image,size:imageFrame.size).draw(in:imageFrame,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        let selected=selection
        let annotationPreview = annotationPreviewSnapshot
        if let annotationPreview, let selected {
            drawAnnotationPreview(annotationPreview, clippedTo: selected)
        } else if let image=session.renderedImage(),let crop=session.renderedImageCrop(),session.activeSource == sourceIndex {
            NSGraphicsContext.saveGraphicsState()
            if let selected { NSBezierPath(rect:selected).addClip() }
            let r=pixelToView.targetRect(fromSourceRect:crop)
            NSImage(cgImage:image,size:r.size).draw(in:r,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let preview=previewCandidate
        let previewRect=preview?.rect.standardized.intersection(imageFrame)
        let shade=NSBezierPath(rect:bounds)
        if let focus=selected ?? previewRect,!focus.isNull,!focus.isEmpty {
            shade.appendRect(focus);shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.28).setFill();shade.fill()
        if let selected {
            NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
            let border=NSBezierPath(rect:selected.insetBy(dx:1,dy:1));border.lineWidth=2;border.stroke()
            for h in CaptureResizeHandle.allCases {
                let p=h.position(in:selected),r=CGRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7)
                NSColor.systemBlue.setFill();NSBezierPath(roundedRect:r,xRadius:2,yRadius:2).fill()
                NSColor.black.withAlphaComponent(0.3).setStroke();NSBezierPath(roundedRect:r,xRadius:2,yRadius:2).stroke()
            }
            if let snapshot=session.snapshot {
                for annotation in (annotationPreview ?? snapshot).annotations where snapshot.selectedAnnotationIDs.contains(annotation.id) && annotation.id != editingTextID {
                    if let line = annotation.lineGeometry {
                        for point in [line.start, line.end] {
                            let p = pixelToView.targetPoint(fromSourcePoint: point)
                            let handle = NSBezierPath(roundedRect: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8), xRadius: 1, yRadius: 1)
                            NSColor.white.setFill(); handle.fill()
                            NSColor.systemBlue.setStroke(); handle.lineWidth = 1.5; handle.stroke()
                        }
                    } else {
                        let r=pixelToView.targetRect(fromSourceRect:annotation.boundingRect)
                        NSColor.systemBlue.setStroke();let path=NSBezierPath(rect:r);path.setLineDash([4,3],count:2,phase:0);path.stroke()
                    }
                }
            }
            if let draft, annotationPreview == nil { NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:selected).addClip();drawDraft(draft);NSGraphicsContext.restoreGraphicsState() }
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            for guide in guides {
                let p=NSBezierPath()
                if guide.axis == .x { p.move(to:CGPoint(x:guide.position,y:guide.start));p.line(to:CGPoint(x:guide.position,y:guide.end)) }
                else { p.move(to:CGPoint(x:guide.start,y:guide.position));p.line(to:CGPoint(x:guide.end,y:guide.position)) }
                p.lineWidth=1;p.stroke()
            }
        } else {
            let hint="单击选中 · 双击复制 · 拖动框选 · Esc 退出" as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:15,weight:.medium),.foregroundColor:NSColor.white]
            let extent=hint.size(withAttributes:attrs)
            NSColor.black.withAlphaComponent(0.68).setFill()
            NSBezierPath(roundedRect:CGRect(x:16,y:16,width:extent.width+16,height:extent.height+12),xRadius:8,yRadius:8).fill()
            hint.draw(at:CGPoint(x:24,y:22),withAttributes:attrs)
        }
        if let candidate=preview {
            let rect=candidate.rect.standardized.intersection(imageFrame)
            if !rect.isNull,!rect.isEmpty {
                let border=NSBezierPath(rect:rect.insetBy(dx:1,dy:1));border.lineWidth=2
                NSColor.systemBlue.withAlphaComponent(0.95).setStroke();border.stroke()
                let title=candidate.source == .window ? "窗口" : candidate.source == .viewport ? "全屏" : "可见内容块"
                let text="\(title)  \(Int(rect.width)) × \(Int(rect.height))" as NSString
                let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.white]
                let size=text.size(withAttributes:attrs)
                let pill=CGRect(x:max(8,min(rect.minX,bounds.maxX-size.width-20)),
                                y:rect.minY>=26 ? rect.minY-25 : min(rect.maxY+5,bounds.maxY-24),
                                width:size.width+16,height:21)
                NSColor.systemBlue.withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect:pill,xRadius:6,yRadius:6).fill()
                text.draw(at:CGPoint(x:pill.minX+8,y:pill.minY+3),withAttributes:attrs)
            }
        }
        drawPixelLoupe()
        if let message=session.message,selection != nil {
            let frame=CGRect(x:max(12,(bounds.width-440)/2),y:16,width:min(440,bounds.width-24),height:42)
            NSColor.black.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect:frame,xRadius:10,yRadius:10).fill()
            let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center
            (message as NSString).draw(in:frame.insetBy(dx:12,dy:5),withAttributes:[
                .font:NSFont.systemFont(ofSize:12,weight:.medium),
                .foregroundColor:NSColor.white,
                .paragraphStyle:paragraph
            ])
        }
    }
    private var loupeIsActive: Bool {
        guard !isHistory,!session.isBrowsingHistory,!session.textEditing,!session.isOutputting else { return false }
        switch gesture {
        case .selection?,.resize?,.move?: return true
        case nil: return selection == nil
        default: return false
        }
    }
    var loupeSample: (point: CapturePixelPoint,color: CapturePixelColor)? {
        guard loupeIsActive,let pointer=hoverPoint,
              let point=CapturePixelLoupeGeometry.sourcePixel(at:pointer,imageFrame:imageFrame,
                imageSize:CGSize(width:source.image.width,height:source.image.height)) else { return nil }
        if !attemptedPixelSampler {
            attemptedPixelSampler=true;pixelSampler=CapturePixelSampler(image:source.image)
        }
        guard let color=pixelSampler?.color(at:point) else { return nil }
        return (point,color)
    }
    var loupeFrame: CGRect? {
        guard loupeSample != nil,let pointer=hoverPoint else { return nil }
        let obstructions=[toolbar,annotationPalette].compactMap { view -> CGRect? in
            guard let view,!view.isHidden else { return nil }
            return view.frame
        }
        return CapturePixelLoupeGeometry.placement(pointer:pointer,viewport:bounds,
            popupSize:CGSize(width:190,height:224),avoiding:obstructions)
    }
    private func drawPixelLoupe() {
        guard let sample=loupeSample,let frame=loupeFrame,let sampler=pixelSampler else { return }
        let dark=effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        NSGraphicsContext.saveGraphicsState()
        let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius=14;shadow.shadowOffset=CGSize(width:0,height:-3);shadow.set()
        (dark ? NSColor(white:0.10,alpha:0.97) : NSColor(white:0.97,alpha:0.98)).setFill()
        NSBezierPath(roundedRect:frame,xRadius:12,yRadius:12).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke();NSBezierPath(roundedRect:frame.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12).stroke()
        let cell:CGFloat=14,grid=CGRect(x:frame.midX-77,y:frame.minY+10,width:154,height:154)
        NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:grid,xRadius:5,yRadius:5).addClip()
        for row in 0..<11 { for col in 0..<11 {
            let point=CapturePixelPoint(x:min(max(sample.point.x+col-5,0),sampler.width-1),
                                       y:min(max(sample.point.y+row-5,0),sampler.height-1))
            if let color=sampler.color(at:point) {
                NSColor(srgbRed:CGFloat(color.red)/255,green:CGFloat(color.green)/255,blue:CGFloat(color.blue)/255,alpha:1).setFill()
                CGRect(x:grid.minX+CGFloat(col)*cell,y:grid.minY+CGFloat(row)*cell,width:cell,height:cell).fill()
            }
        } }
        let lines=NSBezierPath();lines.lineWidth=0.5
        for i in 1..<11 {
            let d=CGFloat(i)*cell
            lines.move(to:CGPoint(x:grid.minX+d,y:grid.minY));lines.line(to:CGPoint(x:grid.minX+d,y:grid.maxY))
            lines.move(to:CGPoint(x:grid.minX,y:grid.minY+d));lines.line(to:CGPoint(x:grid.maxX,y:grid.minY+d))
        }
        NSColor.black.withAlphaComponent(0.15).setStroke();lines.stroke()
        let center=CGRect(x:grid.minX+70,y:grid.minY+70,width:14,height:14)
        NSColor.black.setStroke();let marker=NSBezierPath(rect:center);marker.lineWidth=3;marker.stroke()
        NSColor.white.setStroke();marker.lineWidth=1;marker.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let foreground=dark ? NSColor.white : NSColor.black
        func label(_ value:String,_ y:CGFloat,_ size:CGFloat,_ color:NSColor) {
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedSystemFont(ofSize:size,weight:.medium),.foregroundColor:color]
            let text=value as NSString,extent=text.size(withAttributes:attributes)
            text.draw(at:CGPoint(x:frame.midX-extent.width/2,y:y),withAttributes:attributes)
        }
        label("(\(sample.point.x), \(sample.point.y))",frame.minY+170,11,foreground)
        let swatch=CGRect(x:frame.minX+12,y:frame.minY+188,width:12,height:12)
        NSColor(srgbRed:CGFloat(sample.color.red)/255,green:CGFloat(sample.color.green)/255,blue:CGFloat(sample.color.blue)/255,alpha:1).setFill()
        swatch.fill();NSColor.separatorColor.setStroke();NSBezierPath(rect:swatch).stroke()
        label(sample.color.formatted(pixelColorFormat),frame.minY+186,11,foreground)
        label(Date.timeIntervalSinceReferenceDate<copiedColorUntil ? "已复制颜色" : "C 复制 · Shift RGB/HEX",frame.minY+205,10,foreground.withAlphaComponent(0.65))
    }
    override func flagsChanged(with event:NSEvent) {
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard loupeSample != nil,!session.textEditing else { shiftPressedAt=nil;return }
        let other = !flags.intersection([.command,.option,.control,.function]).isEmpty
        if flags.contains(.shift) {
            if (event.keyCode == 56 || event.keyCode == 60),!other { shiftPressedAt=event.timestamp }
            else { shiftPressedAt=nil }
        } else {
            if CapturePixelLoupeKeys.togglesFormat(shiftDownAt:shiftPressedAt,releaseAt:event.timestamp,
                interrupted:false,otherModifiers:other,textEditing:session.textEditing) {
                pixelColorFormat = pixelColorFormat == .hex ? .rgb : .hex;needsDisplay=true
            }
            shiftPressedAt=nil
        }
    }
    override func scrollWheel(with event:NSEvent) { shiftPressedAt=nil;super.scrollWheel(with:event) }
    private var isEditingAnnotation: Bool {
        switch gesture { case .annotation?, .endpoint?: true; default: false }
    }
    private func endpointHit(at point: CGPoint) -> (Annotation, AnnotationEndpoint, CGPoint)? {
        guard let snapshot = session.snapshot else { return nil }
        for annotation in snapshot.annotations.reversed() where snapshot.selectedAnnotationIDs.contains(annotation.id) {
            guard let line = annotation.lineGeometry else { continue }
            let endpoints: [(AnnotationEndpoint, CGPoint)] = [(.start, line.start), (.end, line.end)]
            if let nearest = endpoints.min(by: {
                let a = pixelToView.targetPoint(fromSourcePoint: $0.1)
                let b = pixelToView.targetPoint(fromSourcePoint: $1.1)
                return hypot(a.x-point.x, a.y-point.y) < hypot(b.x-point.x, b.y-point.y)
            }) {
                let handle = pixelToView.targetPoint(fromSourcePoint: nearest.1)
                if hypot(handle.x-point.x, handle.y-point.y) <= 9 {
                    return (annotation, nearest.0, nearest.1)
                }
            }
        }
        return nil
    }
    private var annotationPreviewSnapshot: EditorSnapshot? {
        guard session.activeSource == sourceIndex, var snapshot = session.snapshot else { return nil }
        if let editingTextID {
            snapshot.annotations.removeAll { $0.id == editingTextID }
            return snapshot
        }
        if session.isAdjustingStyle { pendingAnnotationSnapshot = snapshot; return snapshot }
        if isEditingAnnotation {
            if let draft {
                snapshot.annotations = snapshot.annotations.map { $0.id == draft.id ? draft : $0 }
            }
            return snapshot
        }
        if let pending = pendingAnnotationSnapshot {
            if pending.cropRect == snapshot.cropRect, pending.annotations == snapshot.annotations,
               !session.renderedImageMatches(snapshot) { return snapshot }
            pendingAnnotationSnapshot = nil
        }
        return nil
    }
    private func drawAnnotationPreview(_ snapshot: EditorSnapshot, clippedTo selection: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: selection).addClip()
        // Effects need the composited pixels; ordinary annotations draw directly without
        // allocating a screenshot-sized bitmap on every mouse event.
        let hasEffects = snapshot.annotations.contains {
            if case .redaction(let shape) = $0.kind { return shape.mode != .solid }
            return false
        }
        if hasEffects {
            if let image = try? EditorRenderer.render(baseImage: source.image, snapshot: snapshot) {
                let rect = pixelToView.targetRect(fromSourceRect: snapshot.cropRect.integral)
                NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero,
                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.translateBy(x: imageFrame.minX, y: imageFrame.minY)
        context.scaleBy(x: imageFrame.width / CGFloat(source.image.width),
                        y: imageFrame.height / CGFloat(source.image.height))
        for annotation in snapshot.annotations {
            EditorRenderer.drawVectorAnnotation(annotation, in: context)
        }
    }
    private func drawDraft(_ annotation: Annotation) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if case .redaction(let shape) = annotation.kind, shape.mode != .solid {
            annotation.style.strokeColor.nsColor.setStroke()
            let path = NSBezierPath(rect: pixelToView.targetRect(fromSourceRect: shape.rect))
            path.lineWidth = 1; path.stroke()
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.translateBy(x: imageFrame.minX, y: imageFrame.minY)
        context.scaleBy(x: imageFrame.width / CGFloat(source.image.width),
                        y: imageFrame.height / CGFloat(source.image.height))
        EditorRenderer.drawVectorAnnotation(annotation, in: context)
    }
    private func point(_ event:NSEvent)->CGPoint { convert(event.locationInWindow,from:nil) }
    override func mouseDown(with event:NSEvent) {
        guard !session.isOutputting else { return }
        guard !session.isBrowsingHistory || session.historySource(for:sourceIndex) != nil else { return }
        shiftPressedAt=nil;hoverPoint=point(event)
        session.commitText();window?.makeKey();window?.makeFirstResponder(self)
        let p=point(event);snapState=CaptureSnapState();guides=[];draft=nil;didDragSelection=false
        if let selected=selection,session.activeSource == sourceIndex {
            if let (annotation, endpoint, position) = endpointHit(at: p) {
                let pixel = viewToPixel.targetPoint(fromSourcePoint: p)
                gesture = .endpoint(annotation, endpoint, CGPoint(x: pixel.x-position.x, y: pixel.y-position.y))
                needsDisplay = true
                return
            }
            if !isHistory,event.clickCount >= 2,selected.contains(p) {
                let pixel=viewToPixel.targetPoint(fromSourcePoint:p)
                if let annotation=session.snapshot?.annotations.reversed().first(where: { $0.contains(pixel) }),
                   case .text(let shape)=annotation.kind {
                    session.selectAnnotation(annotation.id)
                    beginText(rect:shape.rect,text:shape.text,id:annotation.id,existingStyle:annotation.style)
                } else { session.requestOutput(.copy) }
                return
            }
            // Eight handles always win over drawing / annotation hit-testing.
            if let h=CaptureResizeHandle.allCases.min(by:{ let a=$0.position(in:selected),b=$1.position(in:selected);return hypot(a.x-p.x,a.y-p.y)<hypot(b.x-p.x,b.y-p.y) }),let hp=Optional(h.position(in:selected)),abs(hp.x-p.x)<=10,abs(hp.y-p.y)<=10 {
                gesture = .resize(selected,h,p);return
            }
            if selected.contains(p) {
                if session.tool == .select {
                    let pixel=viewToPixel.targetPoint(fromSourcePoint:p)
                    if let a=session.snapshot?.annotations.reversed().first(where:{$0.contains(pixel)}) {
                        session.selectAnnotation(a.id)
                        if event.clickCount == 2,case .text(let s)=a.kind { beginText(rect:s.rect,text:s.text,id:a.id,existingStyle:a.style);return }
                        gesture = .annotation(a,pixel)
                    } else { session.selectAnnotation(nil);gesture = .move(selected,p) }
                } else if session.tool == .text {
                    let pixel=viewToPixel.targetPoint(fromSourcePoint:p)
                    let width=min(CGFloat(source.image.width)-pixel.x, max(120,style.fontSize*12))
                    let rect=CGRect(x:pixel.x,y:pixel.y,width:width,height:style.fontSize*4).intersection(session.snapshot!.cropRect)
                    beginText(rect:rect,text:"",id:nil)
                } else { gesture = .drawing(viewToPixel.targetPoint(fromSourcePoint:p)) }
                return
            }
        }
        guard imageFrame.contains(p) else { return }
        let candidate=selection == nil ? candidate(at:p) : nil
        gesture = .selection(p,candidate);temporarySelection=nil;sessionChanged()
    }
    override func mouseDragged(with event:NSEvent) {
        shiftPressedAt=nil;hoverPoint=point(event)
        guard let gesture,!session.isOutputting else { return };let p=point(event)
        switch gesture {
        case .selection(let anchor,_):
            guard didDragSelection || hypot(p.x-anchor.x,p.y-anchor.y)>=Self.selectionDragThreshold else { return }
            didDragSelection=true
            let raw=CGRect(x:min(p.x,anchor.x),y:min(p.y,anchor.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y)).intersection(imageFrame)
            let handle:CaptureResizeHandle=p.x>=anchor.x ? (p.y>=anchor.y ? .southEast : .northEast) : (p.y>=anchor.y ? .southWest : .northWest)
            temporarySelection=snapped(raw,operation:.resize(handle),minimumSize:CGSize(width:3,height:3))
        case .move(let original,let anchor):
            let raw=CaptureInteractionGeometry.move(original,translation:CGSize(width:p.x-anchor.x,height:p.y-anchor.y),within:imageFrame)
            temporarySelection=snapped(raw,operation:.move)
        case .resize(let original,let h,let anchor):
            let raw=CaptureInteractionGeometry.resize(original,handle:h,translation:CGSize(width:p.x-anchor.x,height:p.y-anchor.y),within:imageFrame)
            temporarySelection=snapped(raw,operation:.resize(h))
        case .annotation(let original,let anchor):
            let pixel=viewToPixel.targetPoint(fromSourcePoint:p)
            draft=original.translated(by:CGSize(width:pixel.x-anchor.x,height:pixel.y-anchor.y))
        case .endpoint(let original, let endpoint, let offset):
            let pixel = viewToPixel.targetPoint(fromSourcePoint: p)
            let crop = session.snapshot?.cropRect ?? source.pixelBounds
            let target = CGPoint(x: min(max(pixel.x-offset.x, crop.minX), crop.maxX),
                                 y: min(max(pixel.y-offset.y, crop.minY), crop.maxY))
            draft = original.movingEndpoint(endpoint, to: target)
        case .drawing(let anchor):
            let pixel=viewToPixel.targetPoint(fromSourcePoint:p)
            let rect=CGRect(x:min(pixel.x,anchor.x),y:min(pixel.y,anchor.y),width:abs(pixel.x-anchor.x),height:abs(pixel.y-anchor.y))
            let kind:AnnotationKind
            switch session.tool {
            case .rectangle:kind = .rectangle(RectangleShape(rect:rect))
            case .ellipse:kind = .ellipse(EllipseShape(rect:rect))
            case .line: kind = .line(LineShape(start: anchor, end: pixel))
            case .markerLine: kind = .markerLine(LineShape(start: anchor, end: pixel))
            case .arrow:kind = .arrow(ArrowShape(start:anchor,end:pixel))
            case .freehand:
                var points:[CGPoint]=[anchor];if case .freehand(let s)=draft?.kind { points=s.points };points.append(pixel);kind = .freehand(FreehandShape(points:points))
            case .highlight:kind = .highlight(HighlightShape(rect:rect))
            case .redact,.pixelate,.blur:kind = .redaction(RedactionShape(rect:rect,mode:session.tool == .redact ? .solid : session.tool == .pixelate ? .pixelate : .blur))
            default:return
            }
            draft=Annotation(id:draft?.id ?? UUID(),kind:kind,style:style)
        }
        switch gesture {
        case .annotation, .endpoint, .drawing: needsDisplay = true
        default: sessionChanged()
        }
    }
    private func snapped(_ rect:CGRect,operation:CaptureSnapOperation,minimumSize:CGSize=CGSize(width:24,height:24))->CGRect {
        guard !isHistory && !session.isBrowsingHistory else { return rect }
        let result=CaptureSnapEngine.snap(rect:rect,operation:operation,viewport:imageFrame,candidates:session.candidates(for:sourceIndex),snapshotID:session.snapshotID,state:snapState,minimumSize:minimumSize)
        snapState=result.state;guides=result.guides;return result.rect
    }
    override func mouseUp(with event:NSEvent) {
        mouseDragged(with:event)
        guard let gesture else { return }
        switch gesture {
        case .selection(_,let candidate):
            if didDragSelection {
                lastConfirmationPoint=nil
                if let rect=temporarySelection,rect.width>=3,rect.height>=3 { session.selectPixelsSource(sourceIndex,pixelRect:viewToPixel.targetRect(fromSourceRect:rect)) }
            } else if let candidate {
                let rect=candidate.rect.standardized.intersection(imageFrame)
                if rect.width>=3,rect.height>=3 {
                    lastConfirmationPoint=point(event)
                    session.selectPixelsSource(sourceIndex,pixelRect:viewToPixel.targetRect(fromSourceRect:rect))
                }
            }
        case .move,.resize:
            if let rect=temporarySelection { session.setCrop(viewToPixel.targetRect(fromSourceRect:rect)) }
        case .drawing:
            if let draft,draft.boundingRect.width>1 || draft.boundingRect.height>1 { session.apply(AddAnnotationCommand(annotation:draft)) }
        case .annotation, .endpoint:
            if let draft {
                session.apply(UpdateAnnotationCommand(annotation:draft))
                pendingAnnotationSnapshot = session.snapshot
            }
        }
        self.gesture=nil;temporarySelection=nil;draft=nil;guides=[];didDragSelection=false;sessionChanged()
    }
    func cancelGesture()->Bool {
        guard gesture != nil else { return false };gesture=nil;temporarySelection=nil;draft=nil;guides=[];didDragSelection=false;sessionChanged();return true
    }
    override func keyDown(with event:NSEvent) {
        shiftPressedAt=nil
        let modifiers=event.modifierFlags
        if CapturePixelLoupeKeys.copiesColor(characters:event.charactersIgnoringModifiers,
            command:modifiers.contains(.command),option:modifiers.contains(.option),
            control:modifiers.contains(.control),shift:modifiers.contains(.shift),
            textEditing:session.textEditing,loupeVisible:loupeSample != nil),let sample=loupeSample {
            colorClipboardWriter(sample.color.formatted(pixelColorFormat))
            copiedColorUntil=Date.timeIntervalSinceReferenceDate+1.2;needsDisplay=true
            DispatchQueue.main.asyncAfter(deadline:.now()+1.25) { [weak self] in self?.needsDisplay=true }
            return
        }
        switch CaptureKeyRouting.action(keyCode:event.keyCode,characters:event.charactersIgnoringModifiers,
            command:event.modifierFlags.contains(.command),shift:event.modifierFlags.contains(.shift),textEditing:session.textEditing,outputInProgress:session.isOutputting) {
        case .escape:session.escape()
        case .copy:session.requestOutput(.copy)
        case .save:session.requestOutput(.saveJPEG)
        case .undo:session.undo()
        case .redo:session.redo()
        case .historyOlder:session.browseHistory(older:true,from:sourceIndex)
        case .historyNewer:session.browseHistory(older:false,from:sourceIndex)
        case .delete:session.deleteSelection()
        case .commitText:session.commitText()
        case .passThrough:super.keyDown(with:event)
        }
    }
    private func beginText(rect:CGRect,text:String,id:UUID?,existingStyle:AnnotationStyle?=nil) {
        let textStyle=existingStyle ?? style
        editingTextStyle=textStyle
        // The input area can grow to the crop edge; the committed bounds are measured from text.
        let crop = session.snapshot?.cropRect ?? source.pixelBounds
        let inputRect = CGRect(x: rect.minX, y: rect.minY,
                               width: max(1, crop.maxX-rect.minX), height: max(1, crop.maxY-rect.minY))
        let fullRect=pixelToView.targetRect(fromSourceRect:inputRect)
        let visibleRect=fullRect.intersection(selection ?? imageFrame).intersection(bounds)
        guard visibleRect.width>0,visibleRect.height>0 else { return }
        let clip=CaptureTextClipView(frame:visibleRect)
        clip.drawsBackground = false; clip.backgroundColor = .clear
        let editor=CaptureAnnotationTextView(frame:CGRect(origin:.zero,size:fullRect.size))
        editor.string=text;editor.isRichText=false;editor.drawsBackground=false
        editor.backgroundColor = .clear
        editor.insertionPointColor = textStyle.strokeColor.nsColor
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textColor=textStyle.strokeColor.withAlpha(textStyle.strokeColor.alpha*textStyle.opacity).nsColor;editor.font=NSFont(name:"Helvetica",size:textStyle.fontSize*imageFrame.width/CGFloat(source.image.width))
        editor.textContainerInset = .zero;editor.textContainer?.lineFragmentPadding=0
        editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false
        editor.textContainer?.widthTracksTextView=true;editor.textContainer?.heightTracksTextView=false
        editor.onCommit={ [weak self] in self?.session.commitText() }
        editor.onEscape={ [weak self] in self?.session.abortText() }
        clip.documentView=editor
        clip.scroll(to:CGPoint(x:visibleRect.minX-fullRect.minX,y:visibleRect.minY-fullRect.minY))
        textClipView=clip;textView=editor;editingTextID=id
        if let toolbar { addSubview(clip,positioned:.below,relativeTo:toolbar) } else { addSubview(clip) };window?.makeFirstResponder(editor)
        session.registerTextEditor { [weak self, weak editor] in
            guard let self,let editor else { return }
            let value=editor.string
            var shapeRect=rect
            if let container = editor.textContainer, let layout = editor.layoutManager {
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container)
                let scale = self.annotationPixelScale
                // One source pixel of rounding room avoids clipping the final glyph or descent.
                shapeRect.size = CGSize(width: max(1, ceil(used.maxX*scale)+1),
                                        height: max(1, ceil(used.maxY*scale)+1))
            }
            if !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let committedStyle=self.editingTextStyle ?? textStyle
                let annotation=Annotation(id:id ?? UUID(),kind:.text(TextShape(rect:shapeRect,text:value)),style:committedStyle)
                if id != nil { session.apply(UpdateAnnotationCommand(annotation:annotation)) } else { session.apply(AddAnnotationCommand(annotation:annotation)) }
            }
            else if let id { session.apply(DeleteAnnotationsCommand(annotationIDs:[id])) }
            self.pendingAnnotationSnapshot = session.snapshot
            self.removeTextEditor()
        }
    }
    func annotationColorChanged(_ color:RGBAColor) {
        guard let textView else { return }
        editingTextStyle?.strokeColor = color
        let opacity = editingTextStyle?.opacity ?? 1
        textView.textColor=color.withAlpha(color.alpha*opacity).nsColor
        textView.insertionPointColor=color.nsColor
    }
    func annotationFontSizeChanged(_ size: CGFloat) {
        guard let textView else { return }
        editingTextStyle?.fontSize = size*annotationPixelScale
        textView.font = NSFont(name: textView.font?.fontName ?? "Helvetica", size: size)
    }
    func annotationOpacityChanged(_ opacity: CGFloat) {
        guard let textView, var style = editingTextStyle else { return }
        style.opacity = opacity; editingTextStyle = style
        textView.textColor = style.strokeColor.withAlpha(style.strokeColor.alpha*opacity).nsColor
    }
    func removeTextEditor() {
        if editingTextID != nil { pendingAnnotationSnapshot = session.snapshot }
        textClipView?.removeFromSuperview(); textClipView=nil; textView=nil
        editingTextID=nil; editingTextStyle=nil; needsDisplay=true
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(self) }
    }
}
private final class CaptureTextClipView:NSClipView { override var isFlipped:Bool { true } }
private final class CaptureAnnotationTextView: NSTextView {
    var onCommit:(()->Void)?;var onEscape:(()->Void)?
    override func keyDown(with event:NSEvent) {
        switch CaptureKeyRouting.action(keyCode:event.keyCode,characters:event.charactersIgnoringModifiers,
            command:event.modifierFlags.contains(.command),shift:event.modifierFlags.contains(.shift),textEditing:true,hasMarkedText:hasMarkedText()) {
        case .escape:onEscape?()
        case .commitText:onCommit?()
        default:super.keyDown(with:event)
        }
    }
}
