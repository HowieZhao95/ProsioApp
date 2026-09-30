import AppKit
import Observation
import SwiftUI

nonisolated struct FrozenCaptureSource: @unchecked Sendable {
    let id: UUID
    let image: CGImage
    let display: DisplaySnapshot
    let sourceRect: CGRect
    let overlayRect: CGRect
    let kind: CaptureKind
    let name: String
    let capturedAt: Date
    var pixelBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    var transform: TopLeftRectTransform { TopLeftRectTransform(sourceBounds: overlayRect, targetBounds: pixelBounds) }
}
nonisolated enum CaptureOutputAction { case copy, save, saveJPEG, pin }
nonisolated enum CaptureOutputResult { case success, saveCancelled, failure(String) }

/// One ownership scope for frozen pixels, selection, edits, drafts, output, and overlay cleanup.
@Observable @MainActor
final class CaptureEditingSession {
    enum Theme: String, CaseIterable, Identifiable { case system, light, dark; var id: String { rawValue } }
    let sources: [FrozenCaptureSource]
    let snapshotID: UUID
    private(set) var candidateSets: [[CaptureSnapCandidate]]
    var tool: EditorTool = .select { didSet { changed() } }
    var color = RGBAColor.rectangleStroke { didSet { changed() } }
    var lineWidth: CGFloat = 3
    var preferredLineTool: EditorTool = .arrow
    private var rememberedStrokeWidths: [EditorTool: CGFloat] = [:]
    private var toolStyles: [EditorTool: AnnotationStyle] = [:]
    private(set) var isAdjustingStyle = false
    var theme: Theme = .system { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "prosio.capture.theme"); changed() } }
    private(set) var revision = 0
    private(set) var message: String?
    private(set) var outputState = CaptureOutputState()
    private(set) var activeSource: Int?
    private(set) var textEditing = false
    @ObservationIgnored private var history: EditorHistory?
    @ObservationIgnored private var savedHistoryAssets: [CaptureAsset] = []
    @ObservationIgnored private var historyDocumentLoader: ((CaptureAsset) throws -> EditableCaptureDocument)?
    @ObservationIgnored private var historyFrames: [UUID: (source: FrozenCaptureSource, edits: EditorHistory)] = [:]
    @ObservationIgnored private var liveHistory: EditorHistory?
    @ObservationIgnored private var liveActiveSource: Int?
    @ObservationIgnored private var historySource: FrozenCaptureSource?
    @ObservationIgnored private var historyAnchorSource: Int?
    private(set) var historyPosition = 0
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var canvases: [CaptureEditingCanvas] = []
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var detectionTasks:[Task<Void,Never>]=[]
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var renderedCrop: CGImage?
    @ObservationIgnored private var renderedSourceIndex: Int?
    @ObservationIgnored private var renderedSnapshot: EditorSnapshot?
    @ObservationIgnored private var textCommit: (() -> Void)?
    @ObservationIgnored private var lastDraft: CaptureAsset?
    @ObservationIgnored private var finished = false
    @ObservationIgnored var output: (EditableCaptureDocument, CaptureOutputAction, NSWindow?) async -> CaptureOutputResult = { _,_,_ in .failure("Output is unavailable.") }
    @ObservationIgnored var saveDraft: (EditableCaptureDocument) async throws -> CaptureAsset = { _ in throw CaptureStoreError.invalidAsset }
    @ObservationIgnored var discardDraft: (CaptureAsset) -> Void = { _ in }
    @ObservationIgnored var didFinish: () -> Void = {}

    init(sources: [FrozenCaptureSource], snapshotID: UUID, candidates: [CaptureSnapCandidate], candidateSets: [[CaptureSnapCandidate]] = [], initialSource: Int? = nil, initialSnapshot: EditorSnapshot? = nil) {
        self.sources=sources;self.snapshotID=snapshotID;self.candidateSets=candidateSets.count == sources.count ? candidateSets : sources.map { _ in candidates }
        self.theme=Theme(rawValue:UserDefaults.standard.string(forKey:"prosio.capture.theme") ?? "system") ?? .system
        if let initialSource, sources.indices.contains(initialSource) {
            activeSource=initialSource
            history=EditorHistory(snapshot: initialSnapshot ?? EditorSnapshot(cropRect:sources[initialSource].pixelBounds))
        }
    }
    func candidates(for index: Int) -> [CaptureSnapCandidate] { candidateSets.indices.contains(index) ? candidateSets[index] : [] }
    var historyCount: Int { savedHistoryAssets.count }
    var canBrowseOlder: Bool { historyPosition < historyCount }
    var canBrowseNewer: Bool { historyPosition > 0 }
    var isBrowsingHistory: Bool { historyPosition > 0 }
    func historySource(for sourceIndex: Int) -> FrozenCaptureSource? {
        guard isBrowsingHistory,historyAnchorSource == sourceIndex else { return nil }
        return historySource
    }
    func configureHistory(assets: [CaptureAsset], loader: @escaping (CaptureAsset) throws -> EditableCaptureDocument) {
        savedHistoryAssets = assets
        historyDocumentLoader = loader
        changed()
    }
    func browseHistory(older: Bool, from sourceIndex: Int) {
        guard !finished,!isOutputting,!textEditing, sources.indices.contains(sourceIndex) else { return }
        let next = historyPosition + (older ? 1 : -1)
        guard (0...historyCount).contains(next) else { return }
        if next == 0 {
            historyPosition=0
            history=liveHistory
            activeSource=liveActiveSource
            historySource=nil;historyAnchorSource=nil
            liveHistory=nil;liveActiveSource=nil
        } else {
            let anchor=historyAnchorSource ?? activeSource ?? sourceIndex
            let asset=savedHistoryAssets[next - 1]
            let frame: (source: FrozenCaptureSource, edits: EditorHistory)
            if let cached=historyFrames[asset.id] { frame=cached }
            else {
                do {
                    guard let document=try historyDocumentLoader?(asset) else { throw CaptureStoreError.invalidAsset }
                    let display=sources[anchor].display
                    let source=FrozenCaptureSource(id:asset.id,image:document.baseImage,display:display,
                        sourceRect:document.sourceRect,overlayRect:display.overlayFrame,
                        kind:document.kind,name:document.sourceName,capturedAt:document.capturedAt)
                    frame=(source,EditorHistory(snapshot:document.snapshot))
                    historyFrames[asset.id]=frame
                } catch { message="历史截图无法打开：\(error.localizedDescription)";changed();return }
            }
            if historyPosition == 0 {
                liveHistory=history
                liveActiveSource=activeSource
                historyAnchorSource=anchor
            }
            historyPosition=next
            historySource=frame.source
            history=frame.edits
            activeSource=anchor
        }
        message=nil
        renderTask?.cancel();renderedCrop=nil;renderedSnapshot=nil;renderedSourceIndex=nil
        canvases.forEach { $0.historyFrameChanged() }
        changed(render:true)
    }
    func registerCanvas(_ canvas: CaptureEditingCanvas) {
        guard !canvases.contains(where: { $0 === canvas }) else { return }
        canvases.append(canvas)
    }
    var snapshot: EditorSnapshot? { _ = revision; return history?.snapshot }
    var canUndo: Bool { _ = revision; return history?.canUndo ?? false }
    var canRedo: Bool { _ = revision; return history?.canRedo ?? false }
    var isOutputting: Bool { outputState.phase == .outputting }
    var selectedAnnotation: Annotation? {
        guard let snapshot else { return nil }
        return snapshot.annotations.last { snapshot.selectedAnnotationIDs.contains($0.id) }
    }
    var selectedColorAnnotation: Annotation? {
        guard let snapshot else { return nil }
        return snapshot.annotations.last { annotation in
            snapshot.selectedAnnotationIDs.contains(annotation.id) && annotation.isColorEditable
        }
    }
    private func styleFamily(_ tool: EditorTool) -> EditorTool {
        switch tool { case .arrow, .line, .markerLine: .line; case .highlight: .rectangle; default: tool }
    }
    private func defaultStyle(for tool: EditorTool) -> AnnotationStyle {
        AnnotationStyle(strokeColor: color, lineWidth: lineWidth, fontSize: 22,
                        effectRadius: [.pixelate, .blur].contains(tool) ? 4 : 16)
    }
    var propertyTool: EditorTool { selectedAnnotation?.propertyTool ?? tool }
    var showsRedactionControls: Bool { [.pixelate, .blur, .redact].contains(propertyTool) }
    var showsShapeControls: Bool { [.rectangle, .ellipse, .highlight].contains(propertyTool) }
    var displayedStyle: AnnotationStyle {
        if let annotation = selectedAnnotation { return annotation.editableStyle }
        return toolStyles[styleFamily(tool)] ?? defaultStyle(for: tool)
    }
    var displayedAnnotationColor: RGBAColor { displayedStyle.strokeColor }
    func selectDrawingTool(_ newTool: EditorTool) {
        commitText(); endStyleAdjustment(); selectAnnotation(nil); tool = newTool
    }
    func beginStyleAdjustment() {
        guard !isOutputting, !finished, !isAdjustingStyle else { return }
        isAdjustingStyle = true; history?.beginGroupedEdit()
    }
    func endStyleAdjustment() {
        guard isAdjustingStyle else { return }
        isAdjustingStyle = false; history?.endGroupedEdit(); changed(render: true, autosave: true)
    }
    private var currentPixelScale: CGFloat {
        guard let canvas = canvases.first(where: { $0.sourceIndex == activeSource }) else { return 1 }
        return canvas.annotationPixelScale
    }
    var displayedLineWidth: CGFloat {
        selectedColorAnnotation != nil ? displayedStyle.lineWidth / currentPixelScale : displayedStyle.lineWidth
    }
    private func updateStyle(_ change: (inout AnnotationStyle, CGFloat) -> Void) {
        guard !isOutputting, !finished else { return }
        var defaults = toolStyles[styleFamily(propertyTool)] ?? defaultStyle(for: propertyTool)
        change(&defaults, 1); toolStyles[styleFamily(propertyTool)] = defaults
        guard let snapshot else { changed(); return }
        let replacements = snapshot.annotations.filter { snapshot.selectedAnnotationIDs.contains($0.id) && $0.isColorEditable }.map { annotation in
            var style = annotation.editableStyle
            change(&style, currentPixelScale)
            return annotation.updatingStyle(style)
        }
        if replacements.isEmpty { changed(); return }
        apply(UpdateAnnotationsCommand(annotations: replacements))
    }
    func setAnnotationOpacity(_ opacity: CGFloat) {
        let value = min(max(opacity, 0), 1)
        updateStyle { style, _ in style.opacity = value }
        canvases.forEach { $0.annotationOpacityChanged(value) }
    }
    func setAnnotationLineWidth(_ width: CGFloat) { updateStyle { style, scale in style.lineWidth = min(max(width, 1), 16)*scale } }
    func setAnnotationStroke(_ enabled: Bool) {
        let family = styleFamily(propertyTool)
        if !enabled && displayedLineWidth > 0 { rememberedStrokeWidths[family] = displayedLineWidth }
        let width = rememberedStrokeWidths[family] ?? 3
        updateStyle { style, scale in
            style.lineWidth = enabled ? width*scale : 0
            if !enabled && style.fillColor.alpha == 0 { style.fillColor = style.strokeColor }
        }
    }
    func setAnnotationFillColor(_ color: RGBAColor) { updateStyle { style, _ in style.fillColor = color } }
    var displayedFontSize: CGFloat { selectedColorAnnotation != nil ? displayedStyle.fontSize / currentPixelScale : displayedStyle.fontSize }
    func setAnnotationFontSize(_ size: CGFloat) {
        let value = min(max(size, 12), 64)
        updateStyle { style, scale in style.fontSize = value*scale }
        canvases.forEach { $0.annotationFontSizeChanged(value) }
    }
    func setAnnotationFill(_ enabled: Bool) {
        updateStyle { style, scale in
            style.fillColor = enabled ? style.strokeColor : .clear
            if !enabled && style.lineWidth == 0 { style.lineWidth = 3*scale }
        }
    }
    func setShapeAppearance(_ appearance: String) {
        updateStyle { style, scale in
            style.lineWidth = appearance == "outline" ? 3*scale : 0
            style.fillColor = appearance == "outline" ? .clear : style.strokeColor
            style.opacity = appearance == "highlight" ? 0.32 : 1
        }
    }
    var showsAnnotationPalette: Bool { tool.usesColor || selectedAnnotation != nil || showsRedactionControls }
    func setAnnotationColor(_ newColor: RGBAColor) {
        guard !isOutputting,!finished else { return }
        color = newColor
        canvases.forEach { $0.annotationColorChanged(newColor) }
        updateStyle { style, _ in
            let previous = style.strokeColor
            let followsStroke = style.fillColor.withAlpha(1) == previous.withAlpha(1)
            style.strokeColor = newColor
            if style.fillColor.alpha > 0 && (followsStroke || style.lineWidth == 0) {
                style.fillColor = newColor.withAlpha(style.fillColor.alpha)
            }
        }
    }
    var selectedLineTool: EditorTool? {
        guard let snapshot else { return nil }
        return snapshot.annotations.last(where: { snapshot.selectedAnnotationIDs.contains($0.id) })?.lineTool
    }
    var showsLineControls: Bool { selectedLineTool != nil || [.arrow, .line, .markerLine].contains(tool) }
    func setLineTool(_ newTool: EditorTool) {
        guard [.arrow, .line, .markerLine].contains(newTool), !isOutputting else { return }
        commitText()
        preferredLineTool = newTool
        if let snapshot {
            let replacements = snapshot.annotations.filter { snapshot.selectedAnnotationIDs.contains($0.id) && $0.lineTool != nil }
                .map { $0.changingLineTool(newTool) }
            if !replacements.isEmpty { apply(UpdateAnnotationsCommand(annotations: replacements)) }
        }
        tool = newTool
    }
    func setRedactionTool(_ newTool: EditorTool) {
        guard [.redact, .blur, .pixelate].contains(newTool), !isOutputting, !finished else { return }
        endStyleAdjustment(); commitText()
        if let snapshot {
            let replacements = snapshot.annotations.filter { snapshot.selectedAnnotationIDs.contains($0.id) }.compactMap { annotation -> Annotation? in
                guard case .redaction(var shape) = annotation.kind else { return nil }
                shape.mode = newTool == .redact ? .solid : newTool == .blur ? .blur : .pixelate
                var copy = annotation; copy.kind = .redaction(shape)
                if [.pixelate, .blur].contains(newTool) {
                    copy.style.effectRadius = min(max(copy.style.effectRadius/currentPixelScale, 1), 10)*currentPixelScale
                }
                return copy
            }
            if !replacements.isEmpty { apply(UpdateAnnotationsCommand(annotations: replacements)) }
        }
        tool = newTool
    }
    var redactionStrengthRange: ClosedRange<CGFloat> { 1...10 }
    func setRedactionRadius(_ radius: CGFloat) {
        guard !isOutputting, !finished else { return }
        let family = propertyTool
        let range = redactionStrengthRange
        let strength = min(max(radius, range.lowerBound), range.upperBound)
        var defaults = toolStyles[family] ?? defaultStyle(for: family)
        defaults.effectRadius = strength; toolStyles[family] = defaults
        if let annotation = selectedAnnotation, case .redaction = annotation.kind {
            var copy = annotation; copy.style.effectRadius = strength*currentPixelScale
            apply(UpdateAnnotationCommand(annotation: copy))
        } else { changed() }
    }
    var displayedRedactionRadius: CGFloat {
        let radius = selectedAnnotation != nil ? displayedStyle.effectRadius/currentPixelScale : displayedStyle.effectRadius
        let range = redactionStrengthRange
        return min(max(radius, range.lowerBound), range.upperBound)
    }
    func annotationStyle(pixelScale ratio: CGFloat) -> AnnotationStyle {
        var style = toolStyles[styleFamily(tool)] ?? defaultStyle(for: tool)
        style.lineWidth *= ratio; style.fontSize *= ratio; style.effectRadius *= ratio
        return style
    }
    func startContentDetection() {
        for (index,source) in sources.enumerated() {
            let id=snapshotID
            let task=Task { [weak self] in
                let worker=Task.detached(priority:.utility) { try CaptureContentBoundaryDetector.detect(image:source.image,imageRect:source.overlayRect,snapshotID:id) }
                do {
                    let candidates=try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard let self,!Task.isCancelled,!finished else { return }
                    appendCandidates(candidates,sourceIndex:index,snapshotID:id)
                } catch { /* Optional visual snapping never blocks basic screenshot editing. */ }
            }
            detectionTasks.append(task)
        }
    }
    func begin(historyWindow: Bool = false) async {
        guard !sources.isEmpty,!Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation=continuation
                for (index, source) in sources.enumerated() {
                    let frame=source.display.overlayFrame
                    let window: NSWindow
                    if historyWindow {
                        window=CaptureEditorWindow(contentRect:NSRect(x:0,y:0,width: min(frame.width,1000),height:min(frame.height,720)),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                        window.title="Edit Screenshot";window.contentMinSize=NSSize(width:360,height:300); window.center()
                    } else {
                        window=CaptureEditorWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
                        window.level = .screenSaver;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
                    }
                    window.isOpaque=true;window.backgroundColor = .black;window.hasShadow=false
                    window.acceptsMouseMovedEvents=true
                    window.sharingType = .none;window.isReleasedWhenClosed=false
                    let canvas=CaptureEditingCanvas(frame:CGRect(origin:.zero,size:window.contentLayoutRect.size),sourceIndex:index,session:self,isHistory:historyWindow || source.kind == .window)
                    canvas.autoresizingMask=[.width,.height];window.contentView=canvas
                    (window as? CaptureEditorWindow)?.onClose={ [weak self] in self?.cancel() }
                    windows.append(window);registerCanvas(canvas);window.orderFrontRegardless()
                }
                NSApp.activate(ignoringOtherApps:true)
                let i=activeSource ?? sources.firstIndex(where: { $0.display.overlayFrame.contains(NSEvent.mouseLocation) }) ?? 0
                windows[i].makeKeyAndOrderFront(nil);windows[i].makeFirstResponder(canvases[i])
                canvases.forEach { $0.refreshHoverAtCurrentMouse() }
                changed(render:true,autosave:history != nil)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.forceCancel() } }
    }
    func selectSource(_ index: Int, localRect: CGRect) {
        guard sources.indices.contains(index) else { return }
        selectPixelsSource(index,pixelRect:sources[index].transform.targetRect(fromSourceRect:localRect))
    }
    func selectPixelsSource(_ index: Int, pixelRect: CGRect) {
        guard !finished,!isOutputting,sources.indices.contains(index) else { return }
        guard !isBrowsingHistory || historyAnchorSource == index else { return }
        if activeSource != index { activeSource=index;history=nil }
        let pixels=pixelRect.standardized.integral.intersection((historySource ?? sources[index]).pixelBounds)
        guard pixels.width>=3,pixels.height>=3 else { return }
        if history == nil { history=EditorHistory(snapshot:EditorSnapshot(cropRect:pixels)) }
        else { history?.apply(SetCropCommand(rect:pixels)) }
        changed(render:true,autosave:true)
    }
    func appendCandidates(_ candidates: [CaptureSnapCandidate], sourceIndex: Int, snapshotID: UUID) {
        guard !finished,self.snapshotID == snapshotID,candidateSets.indices.contains(sourceIndex) else { return }
        candidateSets[sourceIndex] += candidates
        canvases.filter { $0.sourceIndex == sourceIndex }.forEach { $0.refreshHoverCandidate() }
    }
    func setCrop(_ rect: CGRect) {
        guard !isOutputting,!finished else { return }
        guard let index=activeSource else { return }
        let crop=rect.standardized.integral.intersection((historySource ?? sources[index]).pixelBounds)
        guard crop.width>=3,crop.height>=3 else { return }
        history?.apply(SetCropCommand(rect:crop)); changed(render:true,autosave:true)
    }
    func apply(_ command: any DocumentCommand) { guard !isOutputting,!finished else { return };history?.apply(command);changed(render:true,autosave:true) }
    func selectAnnotation(_ id: UUID?) { guard !isOutputting,!finished else { return };endStyleAdjustment();history?.setSelection(id.map { [$0] } ?? []);changed() }
    func undo() { guard !isOutputting,!finished else { return };endStyleAdjustment();commitText();history?.undo();changed(render:true,autosave:true) }
    func redo() { guard !isOutputting,!finished else { return };endStyleAdjustment();commitText();history?.redo();changed(render:true,autosave:true) }
    func deleteSelection() { guard let snapshot else { return };apply(DeleteAnnotationsCommand(annotationIDs:snapshot.selectedAnnotationIDs)) }
    func registerTextEditor(commit: @escaping ()->Void) { textEditing=true;textCommit=commit;changed() }
    func commitText() { let commit=textCommit;textCommit=nil;textEditing=false;commit?();changed() }
    func abortText() { textCommit=nil;textEditing=false;canvases.forEach { $0.removeTextEditor() };changed() }
    func escape() {
        guard !isOutputting,!finished else { return }
        endStyleAdjustment()
        if textEditing { abortText();return }
        if canvases.contains(where:{ $0.cancelGesture() }) { return }
        if tool != .select { tool = .select; return }
        if !(snapshot?.selectedAnnotationIDs.isEmpty ?? true) { selectAnnotation(nil);return }
        cancel()
    }
    func document() throws -> EditableCaptureDocument {
        guard let index=activeSource,let snapshot else { throw EditorRenderError.invalidCrop }
        let s=historySource ?? sources[index]
        return EditableCaptureDocument(baseImage:s.image,snapshot:snapshot,kind:s.kind,sourceName:s.name,sourceRect:s.sourceRect,capturedAt:s.capturedAt)
    }
    func requestOutput(_ action: CaptureOutputAction) {
        endStyleAdjustment();commitText()
        guard let document=try? document(),outputState.begin(),!finished else { return }
        message=nil; changed()
        outputTask=Task { [weak self] in
            guard let self else { return }
            let result=await output(document,action,activeSource.flatMap { windows.indices.contains($0) ? windows[$0] : nil })
            guard !finished else { return }
            switch result {
            case .success: outputState.succeeded(); finish()
            case .saveCancelled: outputState.failedOrSaveCancelled(); changed()
            case .failure(let error): outputState.failedOrSaveCancelled();message=error;changed()
            }
        }
    }
    func cancel() { guard !isOutputting else { return };forceCancel() }
    func forceCancel() { outputState.cancelSession();finish() }
    private func finish() {
        guard !finished else { return };finished=true
        detectionTasks.forEach { $0.cancel() };detectionTasks.removeAll();renderTask?.cancel();draftTask?.cancel();outputTask?.cancel()
        if let lastDraft { discardDraft(lastDraft) };lastDraft=nil
        textCommit=nil;canvases.forEach { $0.removeTextEditor() }
        windows.forEach { $0.orderOut(nil);$0.contentView=nil;$0.close() };windows.removeAll();canvases.removeAll();NSCursor.arrow.set()
        let continuation=continuation;self.continuation=nil;didFinish();continuation?.resume()
    }
    func renderedImage() -> CGImage? { renderedSourceIndex == activeSource ? renderedCrop : nil }
    func renderedImageMatches(_ snapshot: EditorSnapshot) -> Bool {
        renderedSourceIndex == activeSource && renderedCrop != nil
            && renderedSnapshot?.cropRect == snapshot.cropRect
            && renderedSnapshot?.annotations == snapshot.annotations
    }
    func renderedImageCrop() -> CGRect? { renderedSnapshot?.cropRect }
    private func changed(render: Bool = false,autosave: Bool = false) {
        revision += 1
        if isAdjustingStyle { canvases.forEach { $0.needsDisplay = true } }
        else { canvases.forEach { $0.sessionChanged() } }
        guard !finished else { return }
        if render, !isAdjustingStyle,let index=activeSource,let snapshot {
            renderTask?.cancel();let image=(historySource ?? sources[index]).image
            renderTask=Task { [weak self] in
                let result=await Task.detached(priority:.userInitiated) { try? { try Task.checkCancellation();return try EditorRenderer.render(baseImage:image,snapshot:snapshot) }() }.value
                guard let self,!Task.isCancelled,!finished else { return }
                renderedCrop=result;renderedSnapshot=snapshot;renderedSourceIndex=index;canvases.forEach { $0.needsDisplay=true }
            }
        }
        if autosave, !isAdjustingStyle,let document=try? document() {
            draftTask?.cancel()
            draftTask=Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for:.milliseconds(350))
                    let asset=try await saveDraft(document)
                    guard !Task.isCancelled,!finished else { discardDraft(asset);return }
                    if let old=lastDraft { discardDraft(old) };lastDraft=asset
                } catch is CancellationError {} catch { message="Draft could not be saved: \(error.localizedDescription)";changed() }
            }
        }
    }
}
private final class CaptureEditorWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func performClose(_ sender: Any?) { onClose?() }
}
