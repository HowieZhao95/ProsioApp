import ApplicationServices
import CoreGraphics
import Foundation

/// Optional geometry from the previously frontmost app's visible accessibility tree.
/// No title, value, URL, text or document contents are requested.
nonisolated struct CaptureAXWindow: Sendable {
    let id: CGWindowID
    let rect: CGRect // Quartz global, top-left origin
}
nonisolated struct CaptureAXBoundary: Sendable {
    let windowID: CGWindowID
    let rect: CGRect // Quartz global, top-left origin
}
nonisolated struct CaptureAXAncestor: Sendable {
    let frame: CGRect?
    let hidden: Bool
}

/// Pure filtering and traversal limits shared by the AX reader and synthetic tests.
nonisolated enum CaptureAXBoundaryPolicy {
    static let maximumWindows = 2
    static let maximumNodes = 96
    static let maximumDepth = 7
    static let maximumChildrenPerNode = 24
    static let maximumBoundaries = 24
    static let totalBudget: TimeInterval = 0.45

    static let containerRoles: Set<String> = [
        "AXGroup", "AXSplitGroup", "AXScrollArea", "AXWebArea", "AXTable", "AXList",
        "AXOutline", "AXLayoutArea", "AXBrowser", "AXToolbar", "AXTabGroup", "AXCollection",
        "AXGrid", "AXSection", "AXSheet", "AXPopover"
    ]
    private static let leafRoles: Set<String> = [
        "AXButton", "AXStaticText", "AXTextField", "AXTextArea", "AXImage", "AXCheckBox",
        "AXRadioButton", "AXSlider", "AXMenuItem"
    ]

    static func shouldVisit(depth: Int, visited: Int, cancelled: Bool) -> Bool {
        !cancelled && depth <= maximumDepth && visited < maximumNodes
    }
    static func shouldTraverseChildren(role: String, depth: Int) -> Bool {
        depth < maximumDepth && !leafRoles.contains(role)
    }
    static func visibleClip(frame: CGRect?, ancestorClip: CGRect, hidden: Bool) -> CGRect? {
        guard !hidden else { return nil }
        guard let frame else { return ancestorClip }
        guard finite(frame),frame.width > 0,frame.height > 0 else { return nil }
        let clipped=frame.standardized.intersection(ancestorClip.standardized)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
    /// The path is ordered window → target. Any hidden or fully clipped ancestor rejects it.
    static func ancestorClips(_ path: [CaptureAXAncestor], within window: CGRect) -> [CGRect]? {
        var clips:[CGRect]=[],clip=window.standardized
        for ancestor in path {
            guard let next=visibleClip(frame:ancestor.frame,ancestorClip:clip,hidden:ancestor.hidden) else { return nil }
            clips.append(next);clip=next
        }
        return clips
    }
    static func acceptedRect(role: String, frame: CGRect?, ancestorClip: CGRect, hidden: Bool) -> CGRect? {
        guard containerRoles.contains(role),let frame,
              let clipped=visibleClip(frame:frame,ancestorClip:ancestorClip,hidden:hidden) else { return nil }
        let toolbar=role == "AXToolbar"
        guard clipped.width >= (toolbar ? 80 : 48),clipped.height >= (toolbar ? 24 : 32),
              clipped.width*clipped.height >= (toolbar ? 1_800 : 2_000),
              clipped.width*clipped.height < ancestorClip.width*ancestorClip.height*0.94 else { return nil }
        return clipped
    }
    static func windowMatchError(_ axRect: CGRect, _ cgRect: CGRect) -> CGFloat? {
        guard finite(axRect),finite(cgRect),axRect.width > 0,axRect.height > 0,
              cgRect.width > 0,cgRect.height > 0 else { return nil }
        let overlap=axRect.standardized.intersection(cgRect.standardized)
        guard !overlap.isNull else { return nil }
        let area=overlap.width*overlap.height
        let smaller=min(axRect.width*axRect.height,cgRect.width*cgRect.height)
        let larger=max(axRect.width*axRect.height,cgRect.width*cgRect.height)
        guard smaller/larger >= 0.70,area/smaller >= 0.78 else { return nil }
        return (abs(axRect.minX-cgRect.minX)+abs(axRect.maxX-cgRect.maxX))/max(cgRect.width,1) +
               (abs(axRect.minY-cgRect.minY)+abs(axRect.maxY-cgRect.maxY))/max(cgRect.height,1)
    }
    static func matchesWindow(_ axRect: CGRect, _ cgRect: CGRect) -> Bool { windowMatchError(axRect,cgRect) != nil }
    private static func finite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width < 20_000 && rect.height < 20_000
    }
}

nonisolated enum CaptureAXBoundaryProvider {
    private static let messageTimeout: Float = 0.035
    private static let sampleFractions: [CGPoint] = [
        CGPoint(x:0.5,y:0.5),CGPoint(x:0.2,y:0.2),CGPoint(x:0.8,y:0.2),
        CGPoint(x:0.2,y:0.8),CGPoint(x:0.8,y:0.8),
        CGPoint(x:0.5,y:0.2),CGPoint(x:0.5,y:0.8)
    ]
    private struct QueueItem {
        let element: AXUIElement
        let depth: Int
        let clip: CGRect
    }
    private struct AncestryItem {
        let role: String
        let frame: CGRect?
        let hidden: Bool
    }

    /// Called before Prosio creates its overlay. Missing AX permission or slow apps yield fewer candidates.
    static func sample(ownerPID: Int32, windows: [CaptureAXWindow],
                       isCancelled: @Sendable () -> Bool = { Task<Never,Never>.isCancelled }) -> [CaptureAXBoundary] {
        guard ownerPID > 0,!windows.isEmpty,!isCancelled() else { return [] }
        let deadline=Date().addingTimeInterval(CaptureAXBoundaryPolicy.totalBudget)
        let app=configured(AXUIElementCreateApplication(ownerPID))
        let axWindows=elements(app,kAXWindowsAttribute)
        var found:[CaptureAXBoundary]=[]
        for window in windows.prefix(CaptureAXBoundaryPolicy.maximumWindows) {
            guard Date()<deadline,!isCancelled() else { break }
            let frame=window.rect.standardized
            guard frame.width>=100,frame.height>=80 else { continue }
            let matched=axWindows.compactMap { axWindow -> (AXUIElement,CGFloat)? in
                guard Date()<deadline,!isCancelled() else { return nil }
                guard let bounds=rect(axWindow),let error=CaptureAXBoundaryPolicy.windowMatchError(bounds,frame) else { return nil }
                return (axWindow,error)
            }.min(by: { $0.1 < $1.1 })?.0
            if let matched {
                traverse(root:matched,window:window,deadline:deadline,isCancelled:isCancelled,into:&found)
            }
            // Hit testing covers container ancestry that an app omitted from its child arrays.
            for fraction in sampleFractions {
                guard Date()<deadline,!isCancelled(),found.count<CaptureAXBoundaryPolicy.maximumBoundaries else { break }
                let point=CGPoint(x:frame.minX+fraction.x*frame.width,y:frame.minY+fraction.y*frame.height)
                var hit:AXUIElement?
                guard AXUIElementCopyElementAtPosition(app,Float(point.x),Float(point.y),&hit) == .success,
                      let hit else { continue }
                var element:AXUIElement?=configured(hit),lineage:[AncestryItem]=[]
                var reachedWindow=false
                for _ in 0..<12 {
                    guard Date()<deadline,!isCancelled(),let current=element else { break }
                    let role=string(current,kAXRoleAttribute) ?? ""
                    lineage.append(AncestryItem(role:role,frame:rect(current),hidden:bool(current,kAXHiddenAttribute) ?? false))
                    if role == "AXWindow" { reachedWindow=true;break }
                    element=parent(current)
                }
                // A partial ancestry could miss an intervening scroll area or hidden group.
                guard reachedWindow else { continue }
                let ordered=Array(lineage.reversed())
                guard let clips=CaptureAXBoundaryPolicy.ancestorClips(ordered.map {
                    CaptureAXAncestor(frame:$0.frame,hidden:$0.hidden)
                },within:frame) else { continue }
                for index in ordered.indices {
                    let parentClip=index == 0 ? frame : clips[index-1]
                    let item=ordered[index]
                    if let visible=CaptureAXBoundaryPolicy.acceptedRect(role:item.role,frame:item.frame,
                        ancestorClip:parentClip,hidden:item.hidden),visible.contains(point) {
                        append(visible,windowID:window.id,into:&found)
                    }
                }
            }
        }
        return found
    }

    private static func traverse(root: AXUIElement,window: CaptureAXWindow,deadline: Date,
                                 isCancelled: @Sendable () -> Bool,into found: inout [CaptureAXBoundary]) {
        var queue=[QueueItem(element:root,depth:0,clip:window.rect.standardized)]
        var cursor=0,visited=0
        var seen=Set<CFHashCode>()
        while cursor<queue.count,Date()<deadline,found.count<CaptureAXBoundaryPolicy.maximumBoundaries {
            let item=queue[cursor];cursor+=1
            guard CaptureAXBoundaryPolicy.shouldVisit(depth:item.depth,visited:visited,cancelled:isCancelled()) else { break }
            let hash=CFHash(item.element)
            guard seen.insert(hash).inserted else { continue }
            visited+=1
            let element=configured(item.element)
            let hidden=bool(element,kAXHiddenAttribute) ?? false
            let frame=rect(element)
            guard let clip=CaptureAXBoundaryPolicy.visibleClip(frame:frame,ancestorClip:item.clip,hidden:hidden) else { continue }
            let role=string(element,kAXRoleAttribute) ?? ""
            if let accepted=CaptureAXBoundaryPolicy.acceptedRect(role:role,frame:frame,
                ancestorClip:item.clip,hidden:hidden) {
                append(accepted,windowID:window.id,into:&found)
            }
            guard CaptureAXBoundaryPolicy.shouldTraverseChildren(role:role,depth:item.depth),
                  Date()<deadline,!isCancelled() else { continue }
            // VisibleChildren avoids off-screen table rows. If unsupported, child frames are
            // intersected with every ancestor clip before they can become candidates.
            let children=visibleChildren(element)
            for child in children.prefix(CaptureAXBoundaryPolicy.maximumChildrenPerNode) {
                if queue.count-cursor+visited>=CaptureAXBoundaryPolicy.maximumNodes { break }
                queue.append(QueueItem(element:child,depth:item.depth+1,clip:clip))
            }
        }
    }
    private static func append(_ rect:CGRect,windowID:CGWindowID,into found:inout [CaptureAXBoundary]) {
        guard found.count<CaptureAXBoundaryPolicy.maximumBoundaries,
              !found.contains(where: { $0.windowID==windowID && near($0.rect,rect) }) else { return }
        found.append(CaptureAXBoundary(windowID:windowID,rect:rect))
    }
    private static func near(_ a:CGRect,_ b:CGRect)->Bool {
        abs(a.minX-b.minX)<4 && abs(a.minY-b.minY)<4 && abs(a.width-b.width)<4 && abs(a.height-b.height)<4
    }
    private static func configured(_ element:AXUIElement)->AXUIElement {
        AXUIElementSetMessagingTimeout(element,messageTimeout)
        return element
    }
    private static func attribute(_ element:AXUIElement,_ name:String)->AnyObject? {
        var value:AnyObject?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    private static func elements(_ element:AXUIElement,_ name:String)->[AXUIElement] {
        elements(attribute(element,name))
    }
    private static func elements(_ value:AnyObject?)->[AXUIElement] {
        guard let values=value as? [AnyObject] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value)==AXUIElementGetTypeID() else { return nil }
            return configured(unsafeDowncast(value,to:AXUIElement.self))
        }
    }
    private static func visibleChildren(_ element:AXUIElement)->[AXUIElement] {
        if let visible=attribute(element,kAXVisibleChildrenAttribute) {
            return elements(visible)
        }
        return elements(element,kAXChildrenAttribute)
    }
    private static func string(_ element:AXUIElement,_ name:String)->String? { attribute(element,name) as? String }
    private static func bool(_ element:AXUIElement,_ name:String)->Bool? { attribute(element,name) as? Bool }
    private static func parent(_ element:AXUIElement)->AXUIElement? {
        guard let value=attribute(element,kAXParentAttribute),CFGetTypeID(value)==AXUIElementGetTypeID() else { return nil }
        return configured(unsafeDowncast(value,to:AXUIElement.self))
    }
    private static func rect(_ element:AXUIElement)->CGRect? {
        guard let pointValue=attribute(element,kAXPositionAttribute),CFGetTypeID(pointValue)==AXValueGetTypeID(),
              let sizeValue=attribute(element,kAXSizeAttribute),CFGetTypeID(sizeValue)==AXValueGetTypeID() else { return nil }
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pointValue,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeDowncast(sizeValue,to:AXValue.self),.cgSize,&size),
              point.x.isFinite,point.y.isFinite,size.width.isFinite,size.height.isFinite,
              size.width>0,size.height>0,size.width<20_000,size.height<20_000 else { return nil }
        return CGRect(origin:point,size:size)
    }
}
