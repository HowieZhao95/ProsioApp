import CoreGraphics
import Foundation
import Testing

@Suite("Capture interaction geometry")
struct CaptureInteractionTests {
    @Test("Toolbar remains inside safe screen bounds at four corners, tiny and full-screen selections")
    func toolbarEdges() {
        let viewport = CGRect(x: -800, y: -200, width: 800, height: 600)
        let safe = viewport.insetBy(dx: 12, dy: 12)
        let selections = [CGRect(x: -800, y: -200, width: 30, height: 30), CGRect(x: -30, y: -200, width: 30, height: 30), CGRect(x: -800, y: 370, width: 30, height: 30), CGRect(x: -30, y: 370, width: 30, height: 30), CGRect(x: -400, y: 100, width: 3, height: 3), viewport]
        for selection in selections { for size in [CGSize(width: 300, height: 48), CGSize(width: 620, height: 112)] {
            let result = CaptureInteractionGeometry.toolbarPlacement(selection: selection, viewport: viewport, toolbarSize: size)
            #expect(safe.contains(result.frame)); #expect(result.frame.size == size)
            #expect(!result.requiresCompactLayout)
        } }
        #expect(CaptureInteractionGeometry.toolbarPlacement(selection: viewport, viewport: viewport, toolbarSize: CGSize(width: 300, height: 48)).side == .inside)
    }
    @Test("Oversized toolbar explicitly requests compact controls rather than claiming unclipped content")
    func compactToolbar() {
        let viewport = CGRect(x: 0, y: 0, width: 240, height: 160)
        let result = CaptureInteractionGeometry.toolbarPlacement(selection: viewport, viewport: viewport, toolbarSize: CGSize(width: 700, height: 200))
        #expect(result.requiresCompactLayout)
        #expect(viewport.insetBy(dx: 12, dy: 12).contains(result.frame))
    }
    @Test("Toolbar side is retained when still fitting and flips above near bottom edge")
    func toolbarSideRetention() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600), size = CGSize(width: 300, height: 48)
        let retained = CaptureInteractionGeometry.toolbarPlacement(selection: CGRect(x: 200, y: 200, width: 100, height: 100), viewport: viewport, toolbarSize: size, previousSide: .above)
        #expect(retained.side == .above)
        let bottom = CaptureInteractionGeometry.toolbarPlacement(selection: CGRect(x: 200, y: 530, width: 100, height: 50), viewport: viewport, toolbarSize: size, previousSide: .below)
        #expect(bottom.side == .above)
    }
    @Test("Each resize handle clamps to viewport and minimum size while preserving opposite edges")
    func resizeClamp() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 200), initial = CGRect(x: 50, y: 40, width: 100, height: 80)
        for handle in CaptureResizeHandle.allCases {
            let expanded = CaptureInteractionGeometry.resize(initial, handle: handle, translation: CGSize(width: handle.movesMinX ? -999 : 999, height: handle.movesMinY ? -999 : 999), within: viewport)
            #expect(viewport.contains(expanded)); #expect(expanded.width >= 24); #expect(expanded.height >= 24)
            if !handle.movesMinX { #expect(expanded.minX == initial.minX) }
            if !handle.movesMaxX { #expect(expanded.maxX == initial.maxX) }
            if !handle.movesMinY { #expect(expanded.minY == initial.minY) }
            if !handle.movesMaxY { #expect(expanded.maxY == initial.maxY) }
            let shrunk = CaptureInteractionGeometry.resize(initial, handle: handle, translation: CGSize(width: handle.movesMinX ? 999 : -999, height: handle.movesMinY ? 999 : -999), within: viewport)
            #expect(viewport.contains(shrunk)); #expect(shrunk.width >= 24); #expect(shrunk.height >= 24)
        }
        #expect(CaptureInteractionGeometry.move(initial, translation: CGSize(width: -999, height: 999), within: viewport) == CGRect(x: 0, y: 120, width: 100, height: 80))
    }
}

@Suite("Capture snap candidates")
struct CaptureSnapTests {
    let viewport = CGRect(x: 0, y: 0, width: 500, height: 400)
    @Test("Hover selects the smallest visible frozen boundary and ignores viewport and stale detections")
    func hoverTarget() {
        let id = UUID()
        let candidates = [
            CaptureSnapCandidate(id: "display", source: .viewport, rect: viewport, confidence: 1, snapshotID: id),
            CaptureSnapCandidate(id: "window", source: .window, rect: CGRect(x: 80, y: 70, width: 320, height: 250), confidence: 1, snapshotID: id),
            CaptureSnapCandidate(id: "panel", source: .contentBlock, rect: CGRect(x: 160, y: 120, width: 100, height: 70), confidence: 0.95, snapshotID: id),
            CaptureSnapCandidate(id: "stale", source: .contentBlock, rect: CGRect(x: 170, y: 130, width: 20, height: 20), confidence: 1, snapshotID: UUID()),
            CaptureSnapCandidate(id: "weak", source: .contentBlock, rect: CGRect(x: 170, y: 130, width: 20, height: 20), confidence: 0.4, snapshotID: id)
        ]
        func hover(_ point: CGPoint) -> String? {
            CaptureSnapCandidates.hoverCandidate(at: point, candidates: candidates, snapshotID: id, viewport: viewport)?.id
        }
        #expect(hover(CGPoint(x: 180, y: 140)) == "panel")
        #expect(hover(CGPoint(x: 100, y: 100)) == "window")
        #expect(hover(CGPoint(x: 20, y: 20)) == nil)
        #expect(hover(CGPoint(x: 550, y: 20)) == nil)
    }
    @Test("Only current-snapshot finite confident unique candidates survive filtering")
    func candidateFiltering() {
        let id = UUID()
        func candidate(_ name: String, rect: CGRect = CGRect(x: 100, y: 100, width: 100, height: 80), confidence: CGFloat = 1, snapshot: UUID? = nil) -> CaptureSnapCandidate {
            CaptureSnapCandidate(id: name, source: .window, rect: rect, confidence: confidence, snapshotID: snapshot ?? id)
        }
        let input = [candidate("good"), candidate("good"), candidate("old", snapshot: UUID()), candidate("low", confidence: 0.5), candidate("nan", confidence: .nan), candidate("badRect", rect: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)), candidate("outside", rect: CGRect(x: 900, y: 900, width: 20, height: 20)), candidate("zero", rect: .zero)]
        #expect(CaptureSnapCandidates.filtered(input, snapshotID: id, viewport: viewport).map(\.id) == ["good"])
    }
    @Test("Entering within eight points locks, fourteen retains, eighteen releases and fresh state does not lock")
    func hysteresis() {
        let id = UUID(), candidate = CaptureSnapCandidate(id: "window", source: .window, rect: CGRect(x: 100, y: 100, width: 100, height: 80), confidence: 1, snapshotID: id)
        func raw(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 220, width: 40, height: 30) }
        let entered = CaptureSnapEngine.snap(rect: raw(94), operation: .move, viewport: viewport, candidates: [candidate], snapshotID: id)
        #expect(entered.rect.minX == 100); #expect(entered.state.x?.candidateID == "window")
        let held = CaptureSnapEngine.snap(rect: raw(86), operation: .move, viewport: viewport, candidates: [candidate], snapshotID: id, state: entered.state)
        #expect(held.rect.minX == 100)
        let released = CaptureSnapEngine.snap(rect: raw(82), operation: .move, viewport: viewport, candidates: [candidate], snapshotID: id, state: held.state)
        #expect(released.rect.minX == 82); #expect(released.state.x == nil)
        let fresh = CaptureSnapEngine.snap(rect: raw(86), operation: .move, viewport: viewport, candidates: [candidate], snapshotID: id)
        #expect(fresh.rect.minX == 86)
        let changedSnapshot = CaptureSnapEngine.snap(rect: raw(86), operation: .move, viewport: viewport, candidates: [candidate], snapshotID: UUID(), state: entered.state)
        #expect(changedSnapshot.rect.minX == 86); #expect(changedSnapshot.state.x == nil)
    }
    @Test("Resize snapping moves only dragged edge and never violates minimum size")
    func resizeSnap() {
        let id = UUID(), candidate = CaptureSnapCandidate(id: "window", source: .window, rect: CGRect(x: 100, y: 100, width: 100, height: 80), confidence: 1, snapshotID: id)
        let result = CaptureSnapEngine.snap(rect: CGRect(x: 50, y: 220, width: 44, height: 30), operation: .resize(.east), viewport: viewport, candidates: [candidate], snapshotID: id)
        #expect(result.rect == CGRect(x: 50, y: 220, width: 50, height: 30))
        #expect(result.guides.contains { $0.axis == .x && $0.position == 100 })
    }
    @Test("A hidden window edge cannot attract move snapping, while its exposed edge can")
    func coveredEdgeDoesNotSnap() {
        let id = UUID()
        let rear = CaptureSnapCandidate(id: "rear", source: .window,
            rect: CGRect(x: 100, y: 100, width: 200, height: 120), confidence: 1,
            snapshotID: id, occluders: [CGRect(x: 95, y: 95, width: 85, height: 130)])
        let hidden = CaptureSnapEngine.snap(rect: CGRect(x: 94, y: 250, width: 40, height: 30),
            operation: .move, viewport: viewport, candidates: [rear], snapshotID: id)
        #expect(hidden.rect.minX == 94)
        #expect(hidden.state.x?.candidateID != "rear")
        let visible = CaptureSnapEngine.snap(rect: CGRect(x: 294, y: 250, width: 40, height: 30),
            operation: .move, viewport: viewport, candidates: [rear], snapshotID: id)
        #expect(visible.rect.minX == 300)
        #expect(visible.state.x?.candidateID == "rear")
    }
    @Test("An AX content boundary does not hover or snap through a covering window")
    func coveredContentBlockEdge() {
        let id = UUID()
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let unobscured = CaptureSnapCandidate(id: "ax-panel", source: .contentBlock,
            rect: rect, confidence: 1, snapshotID: id)
        let covered = CaptureSnapCandidate(id: "ax-panel", source: .contentBlock,
            rect: rect, confidence: 1, snapshotID: id,
            occluders: [CGRect(x: 95, y: 95, width: 85, height: 130)])

        #expect(CaptureSnapCandidates.hoverCandidate(at: CGPoint(x: 110, y: 150),
            candidates: [covered], snapshotID: id, viewport: viewport) == nil)
        #expect(CaptureSnapCandidates.hoverCandidate(at: CGPoint(x: 250, y: 150),
            candidates: [covered], snapshotID: id, viewport: viewport)?.id == "ax-panel")

        let moving = CGRect(x: 94, y: 250, width: 40, height: 30)
        let prior = CaptureSnapEngine.snap(rect: moving, operation: .move,
            viewport: viewport, candidates: [unobscured], snapshotID: id)
        #expect(prior.state.x?.candidateID == "ax-panel")
        let hiddenMove = CaptureSnapEngine.snap(rect: moving, operation: .move,
            viewport: viewport, candidates: [covered], snapshotID: id, state: prior.state)
        #expect(hiddenMove.rect.minX == 94)
        #expect(hiddenMove.state.x == nil)

        let hiddenResize = CaptureSnapEngine.snap(rect: CGRect(x: 50, y: 250, width: 44, height: 30),
            operation: .resize(.east), viewport: viewport, candidates: [covered], snapshotID: id)
        #expect(hiddenResize.rect.maxX == 94)
        #expect(hiddenResize.state.x == nil)
        let exposedResize = CaptureSnapEngine.snap(rect: CGRect(x: 250, y: 250, width: 44, height: 30),
            operation: .resize(.east), viewport: viewport, candidates: [covered], snapshotID: id)
        #expect(exposedResize.rect.maxX == 300)
        #expect(exposedResize.state.x?.candidateID == "ax-panel")
    }
    @Test("Partly visible rear windows remain candidates; own app, translucent and offscreen windows do not")
    func windowVisibility() {
        let id = UUID()
        func window(_ n: UInt32, rect: CGRect, pid: Int32 = 100, opacity: CGFloat = 1, onScreen: Bool = true, snapshot: UUID? = nil) -> CaptureWindowBoundary {
            CaptureWindowBoundary(id: n, rect: rect, ownerPID: pid, layer: 0, opacity: opacity, isOnScreen: onScreen, snapshotID: snapshot ?? id)
        }
        let front = CGRect(x: 10, y: 10, width: 100, height: 100)
        let input = [window(1, rect: front), window(2, rect: CGRect(x: 50, y: 50, width: 150, height: 100)), window(3, rect: CGRect(x: 300, y: 20, width: 80, height: 80)), window(4, rect: CGRect(x: 300, y: 150, width: 80, height: 80), pid: 777), window(5, rect: CGRect(x: 20, y: 250, width: 80, height: 80), opacity: 0.5), window(6, rect: CGRect(x: 120, y: 250, width: 80, height: 80), onScreen: false), window(7, rect: CGRect(x: 220, y: 250, width: 80, height: 80), snapshot: UUID())]
        let visible = CaptureSnapCandidates.windowCandidates(fromFrontToBack: input, snapshotID: id, viewport: viewport, excludingOwnerPID: 777)
        #expect(visible.map(\.id) == ["window-1", "window-2", "window-3"])
        #expect(CaptureSnapCandidates.hoverCandidate(at: CGPoint(x: 75, y: 75), candidates: visible, snapshotID: id, viewport: viewport)?.id == "window-1")
        #expect(CaptureSnapCandidates.hoverCandidate(at: CGPoint(x: 160, y: 80), candidates: visible, snapshotID: id, viewport: viewport)?.id == "window-2")
    }

    @Test("Global windows are scoped to each display's local coordinates, including negative origins and scale")
    func multiDisplayWindowCoordinates() {
        let id = UUID()
        let left = CaptureDisplayTransform(
            captureFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            overlayFrame: CGRect(x: -960, y: -300, width: 960, height: 540))
        let right = CaptureDisplayTransform(
            captureFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            overlayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let globalWindows = [
            (id: CGWindowID(11), rect: CGRect(x: -1800, y: 100, width: 400, height: 300)),
            (id: CGWindowID(22), rect: CGRect(x: 200, y: 150, width: 300, height: 200))
        ]
        func candidates(on display: CaptureDisplayTransform) -> [CaptureSnapCandidate] {
            let boundaries = globalWindows.map { window in
                CaptureWindowBoundary(id: window.id,
                    rect: display.overlayLocalRect(fromCaptureGlobalRect: window.rect),
                    ownerPID: 120, layer: 0, opacity: 1, isOnScreen: true, snapshotID: id)
            }
            return CaptureSnapCandidates.windowCandidates(
                fromFrontToBack: boundaries, snapshotID: id,
                viewport: display.overlayLocalBounds)
        }
        #expect(candidates(on: left).map(\.id) == ["window-11"])
        #expect(candidates(on: left).first?.rect == CGRect(x: 60, y: 50, width: 200, height: 150))
        #expect(candidates(on: right).map(\.id) == ["window-22"])
        #expect(candidates(on: right).first?.rect == CGRect(x: 200, y: 150, width: 300, height: 200))
    }

    @Test("A fully covered rear window is not offered as a candidate")
    func fullyCoveredWindow() {
        let id = UUID()
        let covering = CaptureWindowBoundary(id: 1, rect: CGRect(x: 10, y: 10, width: 350, height: 260),
            ownerPID: 10, layer: 0, opacity: 1, isOnScreen: true, snapshotID: id)
        let behind = CaptureWindowBoundary(id: 2, rect: CGRect(x: 60, y: 40, width: 250, height: 180),
            ownerPID: 11, layer: 0, opacity: 1, isOnScreen: true, snapshotID: id)
        #expect(CaptureSnapCandidates.windowCandidates(
            fromFrontToBack: [covering, behind], snapshotID: id, viewport: viewport).map(\.id) == ["window-1"])
    }
}

@Suite("Capture content detector boundaries")
struct CaptureContentDetectorTests {
    @Test("Vision bottom-left normalized panel maps into offset top-left screen points")
    func normalizedCoordinates() {
        let rect = CaptureContentBoundaryDetector.topLeftRect(fromNormalizedVisionRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), imageRect: CGRect(x: -800, y: -200, width: 1000, height: 500))
        #expect(abs(rect.minX - (-700)) < 0.001)
        #expect(abs(rect.minY - 0) < 0.001)
        #expect(abs(rect.width - 300) < 0.001); #expect(abs(rect.height - 200) < 0.001)
    }
    @Test("Cancelled optional detector exits before expensive image analysis")
    func cancelledDetector() throws {
        do { _ = try CaptureContentBoundaryDetector.detect(image: CaptureEditorTestPixels.image(), imageRect: CGRect(x: 0, y: 0, width: 40, height: 32), snapshotID: UUID(), isCancelled: { true }); Issue.record("Cancelled detector unexpectedly completed") }
        catch { #expect(error is CancellationError) }
    }
    @Test("A controlled synthetic bordered panel produces a matching snapshot-bound candidate")
    func syntheticPanelDetection() throws {
        let context = try #require(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1); context.fill(CGRect(x: 40, y: 60, width: 220, height: 140))
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1); context.setLineWidth(2); context.stroke(CGRect(x: 40, y: 60, width: 220, height: 140))
        let image = try #require(context.makeImage()), id = UUID()
        let candidates = try CaptureContentBoundaryDetector.detect(image: image, imageRect: CGRect(x: -320, y: -50, width: 320, height: 240), snapshotID: id)
        let panel = try #require(candidates.first { abs($0.rect.width - 220) < 10 && abs($0.rect.height - 140) < 10 })
        #expect(panel.snapshotID == id); #expect(panel.source == .contentBlock)
        #expect(abs(panel.rect.minX - (-280)) < 10); #expect(abs(panel.rect.minY - (-10)) < 10)
    }

}

@Suite("Capture accessibility boundary fallback")
struct CaptureAXBoundaryTests {
    @Test("Native sidebars, split panes and compact toolbars are eligible without a hit-test point")
    func nativeContainers() {
        let window = CGRect(x: -1280, y: 100, width: 1000, height: 700)
        let examples: [(String, CGRect)] = [
            ("AXSplitGroup", CGRect(x: -1220, y: 145, width: 880, height: 590)),
            ("AXToolbar", CGRect(x: -1280, y: 100, width: 1000, height: 32)),
            ("AXList", CGRect(x: -1280, y: 150, width: 185, height: 590)),
            ("AXOutline", CGRect(x: -1090, y: 160, width: 180, height: 550)),
            ("AXScrollArea", CGRect(x: -900, y: 150, width: 600, height: 590))
        ]
        for (role, rect) in examples {
            #expect(CaptureAXBoundaryPolicy.acceptedRect(role: role, frame: rect,
                ancestorClip: window, hidden: false) == rect, "\(role) should be a visible candidate")
            #expect(CaptureAXBoundaryPolicy.shouldTraverseChildren(role: role, depth: 1))
        }
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXToolbar",
            frame: CGRect(x: -1280, y: 100, width: 1000, height: 23),
            ancestorClip: window, hidden: false) == nil)
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXButton",
            frame: CGRect(x: -1200, y: 120, width: 120, height: 40),
            ancestorClip: window, hidden: false) == nil)
    }
    @Test("Only visible finite content within ancestor bounds can become an AX candidate")
    func visibilityAndClip() {
        let parent = CGRect(x: 100, y: 100, width: 200, height: 150)
        let crossing = CGRect(x: 50, y: 130, width: 300, height: 100)
        let clipped = CGRect(x: 100, y: 130, width: 200, height: 100)
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXScrollArea", frame: crossing,
            ancestorClip: parent, hidden: false) == clipped)
        #expect(CaptureAXBoundaryPolicy.visibleClip(frame: nil, ancestorClip: parent,
            hidden: false) == parent)
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXList", frame: crossing,
            ancestorClip: parent, hidden: true) == nil)
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXList",
            frame: CGRect(x: 400, y: 400, width: 100, height: 80),
            ancestorClip: parent, hidden: false) == nil)
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXList",
            frame: CGRect(x: CGFloat.nan, y: 100, width: 100, height: 80),
            ancestorClip: parent, hidden: false) == nil)
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXSplitGroup", frame: parent,
            ancestorClip: parent, hidden: false) == nil)
    }
    @Test("Hit-test fallback inherits every parent clip and rejects hidden ancestry")
    func fallbackAncestorClip() throws {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scroll = CGRect(x: 100, y: 100, width: 300, height: 200)
        let target = CGRect(x: 350, y: 140, width: 100, height: 90)
        let path = [CaptureAXAncestor(frame: window, hidden: false),
                    CaptureAXAncestor(frame: scroll, hidden: false),
                    CaptureAXAncestor(frame: target, hidden: false)]
        let clips = try #require(CaptureAXBoundaryPolicy.ancestorClips(path, within: window))
        #expect(clips == [window, scroll, CGRect(x: 350, y: 140, width: 50, height: 90)])
        #expect(CaptureAXBoundaryPolicy.acceptedRect(role: "AXGroup", frame: target,
            ancestorClip: clips[1], hidden: false) == clips[2])
        #expect(CaptureAXBoundaryPolicy.ancestorClips([
            path[0], CaptureAXAncestor(frame: scroll, hidden: true), path[2]
        ], within: window) == nil)
        #expect(CaptureAXBoundaryPolicy.ancestorClips([
            path[0], path[1], CaptureAXAncestor(frame: CGRect(x: 500, y: 140, width: 100, height: 90), hidden: false)
        ], within: window) == nil)
    }
    @Test("AX windows must correspond to their frozen Quartz windows, not nested sheets")
    func windowIdentity() throws {
        let cgWindow = CGRect(x: -900, y: 80, width: 800, height: 600)
        let slightlyInsetAX = CGRect(x: -896, y: 86, width: 792, height: 588)
        let plausibleButFarAX = CGRect(x: -850, y: 130, width: 720, height: 540)
        let nestedSheet = CGRect(x: -650, y: 180, width: 300, height: 300)
        #expect(CaptureAXBoundaryPolicy.matchesWindow(slightlyInsetAX, cgWindow))
        let closeError = try #require(CaptureAXBoundaryPolicy.windowMatchError(slightlyInsetAX, cgWindow))
        let farError = try #require(CaptureAXBoundaryPolicy.windowMatchError(plausibleButFarAX, cgWindow))
        #expect(closeError < farError)
        #expect(!CaptureAXBoundaryPolicy.matchesWindow(nestedSheet, cgWindow))
        #expect(CaptureAXBoundaryPolicy.windowMatchError(nestedSheet, cgWindow) == nil)
        #expect(!CaptureAXBoundaryPolicy.matchesWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), cgWindow))
    }
    @Test("Native AX traversal stays bounded, skips leaves and stops on cancellation")
    func traversalBudget() {
        #expect(CaptureAXBoundaryPolicy.maximumWindows <= 2)
        #expect(CaptureAXBoundaryPolicy.maximumNodes <= 128)
        #expect(CaptureAXBoundaryPolicy.maximumDepth <= 8)
        #expect(CaptureAXBoundaryPolicy.maximumChildrenPerNode <= 32)
        #expect(CaptureAXBoundaryPolicy.maximumBoundaries <= 32)
        #expect(CaptureAXBoundaryPolicy.totalBudget <= 0.5)
        #expect(CaptureAXBoundaryPolicy.shouldVisit(depth: 0, visited: 0, cancelled: false))
        #expect(CaptureAXBoundaryPolicy.shouldVisit(depth: CaptureAXBoundaryPolicy.maximumDepth,
            visited: CaptureAXBoundaryPolicy.maximumNodes - 1, cancelled: false))
        #expect(!CaptureAXBoundaryPolicy.shouldVisit(depth: CaptureAXBoundaryPolicy.maximumDepth + 1,
            visited: 0, cancelled: false))
        #expect(!CaptureAXBoundaryPolicy.shouldVisit(depth: 0,
            visited: CaptureAXBoundaryPolicy.maximumNodes, cancelled: false))
        #expect(!CaptureAXBoundaryPolicy.shouldVisit(depth: 0, visited: 0, cancelled: true))
        #expect(!CaptureAXBoundaryPolicy.shouldTraverseChildren(role: "AXButton", depth: 1))
        #expect(!CaptureAXBoundaryPolicy.shouldTraverseChildren(role: "AXStaticText", depth: 1))
        #expect(!CaptureAXBoundaryPolicy.shouldTraverseChildren(role: "AXList",
            depth: CaptureAXBoundaryPolicy.maximumDepth))
    }
    @Test("Unavailable, empty or cancelled AX input returns no candidates without a system query")
    func unavailableAX() {
        let window = CaptureAXWindow(id: 42, rect: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(CaptureAXBoundaryProvider.sample(ownerPID: -1, windows: [window]).isEmpty)
        #expect(CaptureAXBoundaryProvider.sample(ownerPID: 42, windows: []).isEmpty)
        #expect(CaptureAXBoundaryProvider.sample(ownerPID: 42, windows: [window], isCancelled: { true }).isEmpty)
    }
}

@Suite("Capture pixel loupe")
struct CapturePixelLoupeTests {
    @Test("Frozen source sampling keeps asymmetric top-left orientation and unpremultiplies alpha")
    func sourcePixelColors() throws {
        let image = try CaptureEditorTestPixels.image(width: 4, height: 3)
        let sampler = try #require(CapturePixelSampler(image: image))
        #expect(sampler.color(at: CapturePixelPoint(x: 0, y: 0)) ==
            CapturePixelColor(red: 0, green: 0, blue: 40))
        #expect(sampler.color(at: CapturePixelPoint(x: 3, y: 0)) ==
            CapturePixelColor(red: 200, green: 0, blue: 40))
        #expect(sampler.color(at: CapturePixelPoint(x: 0, y: 2)) ==
            CapturePixelColor(red: 0, green: 220, blue: 40))
        #expect(sampler.color(at: CapturePixelPoint(x: 3, y: 2)) ==
            CapturePixelColor(red: 200, green: 220, blue: 40))
        #expect(sampler.color(at: CapturePixelPoint(x: -1, y: 0)) == nil)
        #expect(sampler.color(at: CapturePixelPoint(x: 4, y: 2)) == nil)

        let provider = try #require(CGDataProvider(data: Data([128, 64, 0, 128]) as CFData))
        let translucent = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let color = try #require(CapturePixelSampler(image: translucent)?.color(at: CapturePixelPoint(x: 0, y: 0)))
        #expect(abs(Int(color.red) - 255) <= 2)
        #expect(abs(Int(color.green) - 128) <= 2)
        #expect(color.blue == 0)
    }
    @Test("View points map to exact Retina source pixels at negative origins and image edges")
    func sourcePixelGeometry() {
        let frame = CGRect(x: -800, y: -200, width: 800, height: 600)
        let pixels = CGSize(width: 1600, height: 1200)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> CapturePixelPoint? {
            CapturePixelLoupeGeometry.sourcePixel(at: CGPoint(x: x, y: y),
                imageFrame: frame, imageSize: pixels)
        }
        #expect(pixel(-800, -200) == CapturePixelPoint(x: 0, y: 0))
        #expect(pixel(-799, -199) == CapturePixelPoint(x: 2, y: 2))
        #expect(pixel(-700, -150) == CapturePixelPoint(x: 200, y: 100))
        #expect(pixel(-0.001, 399.999) == CapturePixelPoint(x: 1599, y: 1199))
        #expect(pixel(-801, -100) == nil)
        #expect(pixel(-500, 401) == nil)
        #expect(pixel(.nan, 0) == nil)
    }
    @Test("HEX and RGB text use sampled channel values rather than display color names")
    func formats() {
        let color = CapturePixelColor(red: 5, green: 160, blue: 255)
        #expect(color.hex == "#05A0FF")
        #expect(color.rgb == "RGB(5, 160, 255)")
        #expect(color.formatted(.hex) == color.hex)
        #expect(color.formatted(.rgb) == color.rgb)
    }
    @Test("Loupe popup stays on screen and avoids the toolbar when an open quadrant exists")
    func popupPlacement() {
        let viewport = CGRect(x: 0, y: 0, width: 640, height: 480)
        let size = CGSize(width: 170, height: 132)
        for pointer in [CGPoint(x: 0, y: 0), CGPoint(x: 640, y: 0),
                        CGPoint(x: 0, y: 480), CGPoint(x: 640, y: 480)] {
            let frame = CapturePixelLoupeGeometry.placement(pointer: pointer,
                viewport: viewport, popupSize: size)
            #expect(viewport.insetBy(dx: 10, dy: 10).contains(frame))
        }
        let toolbar = CGRect(x: 300, y: 100, width: 200, height: 80)
        let avoiding = CapturePixelLoupeGeometry.placement(pointer: CGPoint(x: 280, y: 120),
            viewport: viewport, popupSize: CGSize(width: 150, height: 100), avoiding: [toolbar])
        #expect(!avoiding.intersects(toolbar))
        let tiny = CapturePixelLoupeGeometry.placement(pointer: CGPoint(x: 98, y: 79),
            viewport: CGRect(x: 0, y: 0, width: 100, height: 80), popupSize: size)
        #expect(CGRect(x: 10, y: 10, width: 80, height: 60).contains(tiny))
    }
    @Test("Bare C copies only a visible color; Cmd-C, text and other modifiers retain their actions")
    func colorCopyKeys() {
        func copies(_ c: String? = "c", command: Bool = false, option: Bool = false,
                    control: Bool = false, shift: Bool = false, text: Bool = false,
                    visible: Bool = true) -> Bool {
            CapturePixelLoupeKeys.copiesColor(characters: c, command: command,
                option: option, control: control, shift: shift, textEditing: text,
                loupeVisible: visible)
        }
        #expect(copies())
        #expect(copies("C"))
        #expect(!copies(command: true))
        #expect(!copies(option: true))
        #expect(!copies(control: true))
        #expect(!copies(shift: true))
        #expect(!copies(text: true))
        #expect(!copies(visible: false))
        #expect(!copies("v"))
        #expect(CaptureKeyRouting.action(keyCode: 8, characters: "c", command: true,
            shift: false, textEditing: false) == .copy)
        #expect(CaptureKeyRouting.action(keyCode: 8, characters: "c", command: false,
            shift: false, textEditing: true) == .passThrough)
    }
    @Test("Shift tap changes format once, while long hold, mixed modifiers, interruption or text entry do not")
    func colorFormatKeys() {
        #expect(CapturePixelLoupeKeys.togglesFormat(shiftDownAt: 10, releaseAt: 10.3,
            interrupted: false, otherModifiers: false, textEditing: false))
        let cases: [(TimeInterval?, TimeInterval, Bool, Bool, Bool)] = [
            (nil, 10.3, false, false, false),
            (10, 10.6, false, false, false),
            (10, 9.9, false, false, false),
            (10, 10.3, true, false, false),
            (10, 10.3, false, true, false),
            (10, 10.3, false, false, true)
        ]
        for (down, up, interrupted, modifiers, text) in cases {
            #expect(!CapturePixelLoupeKeys.togglesFormat(shiftDownAt: down, releaseAt: up,
                interrupted: interrupted, otherModifiers: modifiers, textEditing: text))
        }
    }
}
