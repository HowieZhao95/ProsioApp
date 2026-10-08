import AppKit
import ApplicationServices
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

@Observable @MainActor
final class CaptureCoordinator {
    enum Action { case region, window, currentDisplay, selectedDisplay }
    let store: CaptureAssetStore
    let drafts: CaptureAssetStore
    private(set) var isBusy=false
    private(set) var message:String?
    private let permissions:PermissionsManager
    private let service:ScreenCaptureService
    @ObservationIgnored var canBegin:()->Bool={ true }
    @ObservationIgnored var onSelectionActivity:(Bool)->Void={ _ in }
    @ObservationIgnored private var session:CaptureEditingSession?
    @ObservationIgnored private var libraryWindow:NSWindow?
    @ObservationIgnored private var pinnedWindows:[UUID:CapturePinnedWindow]=[:]
    @ObservationIgnored private var task:Task<Void,Never>?
    @ObservationIgnored private var activePicker:NSAlert?
    @ObservationIgnored private var activeSavePanel:NSSavePanel?
    @ObservationIgnored private var isShuttingDown=false
    @ObservationIgnored private var lastExternalApplication:NSRunningApplication?
    @ObservationIgnored private var applicationObserver:NSObjectProtocol?
    @ObservationIgnored private var screenObserver:NSObjectProtocol?
    @ObservationIgnored var hotkey:CaptureHotkey?
    @ObservationIgnored var translateTexts: CaptureTranslationPipeline.Translate = { _, _ in throw CaptureTranslationError.unavailable }

    init(permissions:PermissionsManager,rootURL:URL,service:ScreenCaptureService=ScreenCaptureService()) {
        self.permissions=permissions;self.service=service
        store=CaptureAssetStore(rootURL:rootURL);drafts=CaptureAssetStore(rootURL:rootURL.appendingPathComponent(".drafts",isDirectory:true))
        store.pruneHistory(keeping:50)
        if let app=NSWorkspace.shared.frontmostApplication,app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApplication=app }
        applicationObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] notification in
            guard let pid=(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { if pid != ProcessInfo.processInfo.processIdentifier { self?.lastExternalApplication=NSRunningApplication(processIdentifier:pid) } }
        }
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self,self.isBusy else { return };self.message="Displays changed. Start a new screenshot.";self.activeSavePanel?.cancel(nil);self.session?.forceCancel();self.task?.cancel() }
        }
    }
    func start(_ action:Action) {
        guard beginAllowed() else { return }
        permissions.refresh()
        guard permissions.screenCaptureGranted else {
            permissions.requestScreenCapture();message="Allow Prosio in Screen & System Audio Recording, then try again.";return
        }
        let previous=externalApplication(),pointer=NSEvent.mouseLocation,snapshotID=UUID()
        beginActivity()
        task=Task { [weak self] in
            guard let self else { return }
            defer { endActivity(previous:previous) }
            do {
                try await Task.sleep(for:.milliseconds(120))
                let displays=try await service.displays();try Task.checkCancellation()
                guard !displays.isEmpty else { throw ScreenCaptureError.noDisplays }
                var chosen=displays
                var window:CaptureWindowSummary?
                if action == .window {
                    let windows=try await service.listWindows();try Task.checkCancellation()
                    guard !windows.isEmpty else { throw ScreenCaptureError.noWindowsAvailable }
                    guard let index=choose(title:"Capture a window",labels:windows.map(\.displayTitle)) else { return }
                    try Task.checkCancellation();window=windows[index]
                    chosen=displays.filter { $0.frame.intersects(windows[index].frame) }
                    guard let first=chosen.first else { throw ScreenCaptureError.currentDisplayUnavailable };chosen=[first]
                } else if action == .selectedDisplay {
                    guard let index=choose(title:"Capture a display",labels:displays.enumerated().map { "\($0.offset+1). \($0.element.name)" }) else { return }
                    try Task.checkCancellation();chosen=[displays[index]]
                } else if action == .currentDisplay {
                    guard let display=service.currentDisplay(from:displays,preferredPoint:pointer) else { throw ScreenCaptureError.currentDisplayUnavailable };chosen=[display]
                }
                // Capture inventory and pixels before constructing any Prosio overlay.
                var sources:[FrozenCaptureSource]=[],candidateSets:[[CaptureSnapCandidate]]=[]
                for display in chosen {
                    let windowInfo=Self.windowInventory()
                    let axTask:Task<[CaptureAXBoundary],Never>?
                    if action == .region,AXIsProcessTrusted(),let pid=previous?.processIdentifier {
                        let windows=Self.axWindows(from:windowInfo,ownerPID:pid,displayFrame:display.frame)
                        axTask=windows.isEmpty ? nil : Task.detached(priority:.utility) {
                            CaptureAXBoundaryProvider.sample(ownerPID:pid,windows:windows)
                        }
                    } else { axTask=nil }
                    let screenshot:CapturedScreenshot
                    let localRect:CGRect
                    if let window {
                        screenshot=try await service.captureWindow(window)
                        localRect=CaptureDisplayTransform(captureFrame:display.frame,overlayFrame:display.overlayFrame).overlayLocalRect(fromCaptureGlobalRect:screenshot.sourceRect)
                    } else {
                        screenshot=try await service.captureDisplay(display)
                        localRect=CGRect(origin:.zero,size:display.overlayFrame.size)
                    }
                    try Task.checkCancellation()
                    let axBoundaries=await withTaskCancellationHandler {
                        await axTask?.value ?? []
                    } onCancel: { axTask?.cancel() }
                    try Task.checkCancellation()
                    let afterInventory=Self.windowInventory()
                    let stable=Self.stableWindowIDs(before:windowInfo,after:afterInventory)
                    let source=FrozenCaptureSource(id:UUID(),image:screenshot.image,display:display,sourceRect:screenshot.sourceRect,overlayRect:localRect,kind:action == .region ? .region : screenshot.kind,name:screenshot.sourceName,capturedAt:screenshot.capturedAt)
                    sources.append(source)
                    let transform=CaptureDisplayTransform(captureFrame:display.frame,overlayFrame:display.overlayFrame)
                    let boundaries=windowInfo.compactMap { info -> CaptureWindowBoundary? in
                        guard let id=info[kCGWindowNumber as String] as? NSNumber,let pid=info[kCGWindowOwnerPID as String] as? NSNumber,
                              let dict=info[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:dict) else { return nil }
                        return CaptureWindowBoundary(id:id.uint32Value,rect:transform.overlayLocalRect(fromCaptureGlobalRect:rect),ownerPID:pid.int32Value,
                            layer:stable.contains(id.uint32Value) ? ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) : 1,opacity:(info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,isOnScreen:true,snapshotID:snapshotID)
                    }
                    var candidates=CaptureSnapCandidates.windowCandidates(fromFrontToBack:boundaries,snapshotID:snapshotID,viewport:localRect,excludingOwnerPID:ProcessInfo.processInfo.processIdentifier)
                    for (index,boundary) in axBoundaries.enumerated() where stable.contains(boundary.windowID) {
                        guard let parent=candidates.first(where: { $0.id == "window-\(boundary.windowID)" }) else { continue }
                        let rect=transform.overlayLocalRect(fromCaptureGlobalRect:boundary.rect).intersection(localRect)
                        guard !rect.isNull,rect.width>=32,rect.height>=24 else { continue }
                        candidates.append(CaptureSnapCandidate(id:"ax-content-\(boundary.windowID)-\(index)",source:.contentBlock,
                            rect:rect,confidence:0.95,snapshotID:snapshotID,priority:50+index,occluders:parent.occluders))
                    }
                    candidates.append(CaptureSnapCandidate(id:"display-boundary",source:.viewport,rect:localRect,confidence:1,snapshotID:snapshotID))
                    candidateSets.append(candidates)
                }
                let initial=action == .region ? nil : 0
                let session=CaptureEditingSession(sources:sources,snapshotID:snapshotID,candidates:[],candidateSets:candidateSets,initialSource:initial)
                configure(session);self.session=session
                session.configureHistory(assets:Array(store.assets.prefix(50))) { [weak self] asset in
                    guard let self else { throw CaptureStoreError.invalidAsset }
                    return try self.store.loadDocument(asset)
                }
                session.startContentDetection()
                await session.begin()
            } catch is CancellationError {} catch {
                message=error.localizedDescription
                if !isShuttingDown { let alert=NSAlert();alert.messageText="Screenshot failed";alert.informativeText=error.localizedDescription;alert.runModal() }
            }
        }
    }
    private func beginAllowed()->Bool {
        guard !isBusy,!isShuttingDown else { return false }
        guard canBegin() else { message="Finish the current voice session before taking a screenshot.";return false }
        return true
    }
    private func externalApplication()->NSRunningApplication? {
        if let current=NSWorkspace.shared.frontmostApplication,current.processIdentifier != ProcessInfo.processInfo.processIdentifier { return current }
        return lastExternalApplication
    }
    private func beginActivity() { isBusy=true;message=nil;libraryWindow?.orderOut(nil);onSelectionActivity(true) }
    private func endActivity(previous:NSRunningApplication?) {
        session=nil;task=nil;isBusy=false;onSelectionActivity(false)
        if !isShuttingDown { previous?.activate(options:[]) }
    }
    private func configure(_ session:CaptureEditingSession) {
        session.translationPipeline = CaptureTranslationPipeline(translate: translateTexts)
        session.output={ [weak self] document,action,window in
            guard let self else { return .failure("Prosio is unavailable.") }
            return await self.output(document,action:action,window:window)
        }
        session.saveDraft={ [weak self] document in guard let self else { throw CancellationError() };return try await drafts.saveDocument(document) }
        session.discardDraft={ [weak self] asset in try? self?.drafts.delete(asset) }
    }
    private func choose(title:String,labels:[String])->Int? {
        let alert=NSAlert();alert.messageText=title;activePicker=alert;defer { activePicker=nil }
        NSApp.activate(ignoringOtherApps:true)
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:30))
        for (index,title) in labels.enumerated() { let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.representedObject=index;picker.menu?.addItem(item) }
        alert.accessoryView=picker;alert.addButton(withTitle:"Capture");alert.addButton(withTitle:"Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? picker.selectedItem?.representedObject as? Int : nil
    }
    func cancel() {
        if let activeSavePanel { activeSavePanel.cancel(nil);return }
        if session?.isOutputting == true { return };session?.cancel();task?.cancel();if activePicker != nil { NSApp.abortModal() }
    }
    func shutdown() {
        isShuttingDown=true;activeSavePanel?.cancel(nil);session?.forceCancel();task?.cancel();hotkey?.stop()
        Array(pinnedWindows.values).forEach { $0.close() };pinnedWindows.removeAll()
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) };applicationObserver=nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) };screenObserver=nil
    }
    private func output(_ document:EditableCaptureDocument,action:CaptureOutputAction,window:NSWindow?) async -> CaptureOutputResult {
        var destination:URL?
        if action != .copy && action != .pin {
            let panel=NSSavePanel();panel.allowedContentTypes=action == .saveJPEG ? [.jpeg,.png] : [.png];panel.nameFieldStringValue="Prosio-\(Date().formatted(.iso8601).replacingOccurrences(of:":",with:"-")).\(action == .saveJPEG ? "jpg" : "png")"
            activeSavePanel=panel
            let response=await withCheckedContinuation { continuation in
                if let window { panel.beginSheetModal(for:window) { continuation.resume(returning:$0) } }
                else { panel.begin { continuation.resume(returning:$0) } }
            }
            activeSavePanel=nil
            guard response == .OK,let url=panel.url else { return .saveCancelled };destination=url
        }
        do {
            try Task.checkCancellation()
            _ = try await CaptureOutputTransaction.perform(document:document,store:store) { asset in
                let imageURL=store.imageURL(for:asset)
                if action == .pin {
                    guard let source=CGImageSourceCreateWithURL(imageURL as CFURL,nil),
                          let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CaptureStoreError.invalidAsset }
                    let id=UUID()
                    let pinned=CapturePinnedWindow(image:image,screen:window?.screen ?? NSScreen.main)
                    pinned.onClose={ [weak self] in self?.pinnedWindows.removeValue(forKey:id) }
                    pinnedWindows[id]=pinned
                    pinned.orderFrontRegardless()
                    return
                }
                let format=destination?.pathExtension.lowercased() == "png" ? UTType.png : action == .saveJPEG ? UTType.jpeg : UTType.png
                let data=try await Task.detached(priority:.userInitiated) { try Self.outputData(at:imageURL,format:format) }.value
                try Task.checkCancellation()
                if let destination {
                    let writer=Task.detached(priority:.userInitiated) { try Task.checkCancellation();try data.write(to:destination,options:.atomic) }
                    try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                } else {
                    let item=NSPasteboardItem();item.setData(data,forType:.png)
                    if let tiff=NSImage(data:data)?.tiffRepresentation { item.setData(tiff,forType:.tiff) }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects([item]) else { throw CaptureStoreError.invalidAsset }
                }
            }
            message=action == .copy ? "Screenshot copied." : action == .pin ? "Screenshot pinned." : "Screenshot saved."
            return .success
        } catch { return .failure(error.localizedDescription) }
    }
    func openEditor(_ asset:CaptureAsset) { reopen(asset,in:store) }
    func reopenDraft(_ asset:CaptureAsset) { reopen(asset,in:drafts) }
    private func reopen(_ asset:CaptureAsset,in sourceStore:CaptureAssetStore) {
        guard beginAllowed() else { return }
        do {
            let document=try sourceStore.loadDocument(asset)
            guard let screen=NSScreen.main else { throw ScreenCaptureError.noDisplays }
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let display=DisplaySnapshot(displayID:id,name:screen.localizedName,frame:screen.frame,overlayFrame:screen.frame,scale:screen.backingScaleFactor)
            let source=FrozenCaptureSource(id:UUID(),image:document.baseImage,display:display,sourceRect:document.sourceRect,overlayRect:CGRect(x:0,y:0,width:document.baseImage.width,height:document.baseImage.height),kind:document.kind,name:document.sourceName,capturedAt:document.capturedAt)
            let previous=externalApplication();beginActivity()
            let session=CaptureEditingSession(sources:[source],snapshotID:source.id,candidates:[],initialSource:0,initialSnapshot:document.snapshot)
            configure(session);self.session=session
            if sourceStore === drafts { session.didFinish={ [weak session,weak self] in if session?.outputState.phase == .finished { try? self?.drafts.delete(asset) } } }
            task=Task { [weak self] in guard let self else { return };defer { endActivity(previous:previous) };await session.begin(historyWindow:true) }
        } catch { message=error.localizedDescription }
    }
    func showLibrary() {
        store.reload();drafts.reload()
        if let libraryWindow { libraryWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return }
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Recent Screenshots";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:CaptureLibraryView(coordinator:self));window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);libraryWindow=window
    }
    func copy(_ asset:CaptureAsset) {
        do {
            let data=try Data(contentsOf:store.imageURL(for:asset)),item=NSPasteboardItem();item.setData(data,forType:.png)
            if let tiff=NSImage(data:data)?.tiffRepresentation { item.setData(tiff,forType:.tiff) };NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else { throw CaptureStoreError.invalidAsset };message="Screenshot copied."
        } catch { message=error.localizedDescription }
    }
    func export(_ asset:CaptureAsset) {
        let panel=NSSavePanel();panel.allowedContentTypes=[.jpeg,.png];panel.nameFieldStringValue="Prosio.jpg"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            let format=url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
            try Self.outputData(at:store.imageURL(for:asset),format:format).write(to:url,options:.atomic)
        } catch { message=error.localizedDescription }
    }
    nonisolated private static func windowInventory() -> [[String:Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    }
    nonisolated private static func axWindows(from inventory:[[String:Any]],ownerPID:Int32,displayFrame:CGRect) -> [CaptureAXWindow] {
        var result:[CaptureAXWindow]=[]
        for info in inventory {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)>=0.98,
                  let id=(info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict=info[kCGWindowBounds as String] as? NSDictionary,
                  let rect=CGRect(dictionaryRepresentation:dict),rect.intersects(displayFrame) else { continue }
            // A lower window covered by the first one cannot yield visible content.
            if result.contains(where: { $0.rect.intersects(rect) }) { continue }
            result.append(CaptureAXWindow(id:id,rect:rect))
            if result.count == 2 { break }
        }
        return result
    }
    nonisolated private static func stableWindowIDs(before:[[String:Any]],after:[[String:Any]]) -> Set<CGWindowID> {
        var stable=Set<CGWindowID>()
        for (rank,info) in before.enumerated() {
            guard after.indices.contains(rank),let id=info[kCGWindowNumber as String] as? NSNumber,
                (after[rank][kCGWindowNumber as String] as? NSNumber)==id,
                let a=info[kCGWindowBounds as String] as? NSDictionary,let b=after[rank][kCGWindowBounds as String] as? NSDictionary,
                a==b,(info[kCGWindowOwnerPID as String] as? NSNumber)==(after[rank][kCGWindowOwnerPID as String] as? NSNumber) else { continue }
            stable.insert(id.uint32Value)
        }
        return stable
    }
    nonisolated private static func outputData(at url:URL,format:UTType) throws -> Data {
        try Task.checkCancellation()
        let png=try Data(contentsOf:url)
        if format == .png { return png }
        guard let source=CGImageSourceCreateWithData(png as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CaptureStoreError.invalidAsset }
        let data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,format.identifier as CFString,1,nil) else { throw CaptureStoreError.imageEncodingFailed }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureStoreError.imageEncodingFailed }
        return data as Data
    }
    func delete(_ asset:CaptureAsset) { do { try store.delete(asset) } catch { message=error.localizedDescription } }
}
