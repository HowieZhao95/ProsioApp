import CoreGraphics
import Foundation

nonisolated enum CaptureSnapSource: String, Sendable { case window, contentBlock, viewport }
nonisolated struct CaptureSnapCandidate: Equatable, Sendable {
    let id: String
    let source: CaptureSnapSource
    let rect: CGRect
    let confidence: CGFloat
    let snapshotID: UUID
    let priority: Int
    /// Opaque windows in front of this window at freeze time. Empty for image/AX candidates.
    let occluders: [CGRect]
    init(id: String, source: CaptureSnapSource, rect: CGRect, confidence: CGFloat,
         snapshotID: UUID, priority: Int = 0, occluders: [CGRect] = []) {
        self.id = id; self.source = source; self.rect = rect; self.confidence = confidence
        self.snapshotID = snapshotID; self.priority = priority; self.occluders = occluders
    }
}

/// Supply front-to-back CGWindowList metadata transformed to the same display-local space.
/// This deliberately carries no window titles, page text, or URL.
nonisolated struct CaptureWindowBoundary: Sendable {
    let id: CGWindowID
    let rect: CGRect
    let ownerPID: Int32
    let layer: Int
    let opacity: CGFloat
    let isOnScreen: Bool
    let snapshotID: UUID
}

nonisolated enum CaptureSnapCandidates {
    /// A single click chooses the smallest visible frozen boundary under the pointer.
    /// Display edges are useful for dragging but must not consume every empty-space click.
    static func hoverCandidate(at point: CGPoint, candidates: [CaptureSnapCandidate],
                               snapshotID: UUID, viewport: CGRect) -> CaptureSnapCandidate? {
        guard viewport.contains(point) else { return nil }
        return filtered(candidates, snapshotID: snapshotID, viewport: viewport).filter { candidate in
            candidate.source != .viewport && candidate.rect.standardized.contains(point) &&
            !candidate.occluders.contains(where: { $0.contains(point) })
        }.min { left, right in
            let leftArea = left.rect.width * left.rect.height, rightArea = right.rect.width * right.rect.height
            if leftArea != rightArea { return leftArea < rightArea }
            if left.source != right.source { return left.source == .contentBlock }
            if left.priority != right.priority { return left.priority < right.priority }
            return left.id < right.id
        }
    }
    static func filtered(_ candidates: [CaptureSnapCandidate], snapshotID: UUID, viewport: CGRect,
                         minimumConfidence: CGFloat = 0.85) -> [CaptureSnapCandidate] {
        let viewport = CaptureInteractionGeometry.valid(viewport)
        var ids = Set<String>()
        return candidates.filter {
            guard $0.snapshotID == snapshotID, $0.confidence.isFinite,
                  $0.confidence >= minimumConfidence, $0.confidence <= 1,
                  $0.rect.origin.x.isFinite, $0.rect.origin.y.isFinite,
                  $0.rect.width.isFinite, $0.rect.height.isFinite,
                  $0.rect.minX.isFinite, $0.rect.maxX.isFinite, $0.rect.minY.isFinite, $0.rect.maxY.isFinite,
                  $0.rect.standardized.width > 0, $0.rect.standardized.height > 0,
                  $0.rect.standardized.intersects(viewport) else { return false }
            return ids.insert($0.id).inserted
        }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.id < $1.id
        }
    }

    /// Keep a partially exposed window hoverable without treating its hidden edges as visible.
    /// Only opaque, normal-layer windows can occlude another normal window here.
    static func windowCandidates(fromFrontToBack windows: [CaptureWindowBoundary], snapshotID: UUID,
                                 viewport: CGRect, excludingOwnerPID: Int32? = nil) -> [CaptureSnapCandidate] {
        var foreground: [CGRect] = [], result: [CaptureSnapCandidate] = []
        for (rank, window) in windows.enumerated() {
            guard window.snapshotID == snapshotID, window.isOnScreen, window.opacity.isFinite,
                  window.opacity > 0.01, window.ownerPID != excludingOwnerPID else { continue }
            let rect = CaptureInteractionGeometry.valid(window.rect)
            guard rect.width > 0, rect.height > 0, rect.intersects(viewport) else { continue }
            guard window.layer == 0, window.opacity >= 0.98 else { continue }
            let occluders=foreground.compactMap { front -> CGRect? in
                let overlap=front.intersection(rect)
                return overlap.isNull || overlap.isEmpty ? nil : overlap
            }
            foreground.append(rect)
            guard !fullyCovered(rect, by:occluders) else { continue }
            result.append(CaptureSnapCandidate(id: "window-\(window.id)", source: .window, rect: rect,
                confidence: 1, snapshotID: snapshotID, priority: rank, occluders: occluders))
        }
        return filtered(result, snapshotID: snapshotID, viewport: viewport)
    }
    private static func fullyCovered(_ rect: CGRect, by occluders: [CGRect]) -> Bool {
        // A bounded sample is intentionally conservative: never offer an entirely hidden window.
        for y in 0..<5 { for x in 0..<5 {
            let point=CGPoint(x:rect.minX+(CGFloat(x)+0.5)*rect.width/5,
                              y:rect.minY+(CGFloat(y)+0.5)*rect.height/5)
            if !occluders.contains(where: { $0.contains(point) }) { return false }
        } }
        return true
    }
    static func edgeIsVisible(_ candidate: CaptureSnapCandidate, axis: CaptureSnapAxis,
                              edge: CaptureSnapEdge) -> Bool {
        guard !candidate.occluders.isEmpty else { return true }
        let rect=candidate.rect.standardized
        for part in 0..<12 {
            let fraction=(CGFloat(part)+0.5)/12
            let point=axis == .x
                ? CGPoint(x:edge == .minimum ? rect.minX : rect.maxX,y:rect.minY+fraction*rect.height)
                : CGPoint(x:rect.minX+fraction*rect.width,y:edge == .minimum ? rect.minY : rect.maxY)
            // A window touching an edge may own that exact coordinate; probe just inside it.
            let inside=axis == .x
                ? CGPoint(x:point.x+(edge == .minimum ? 1 : -1),y:point.y)
                : CGPoint(x:point.x,y:point.y+(edge == .minimum ? 1 : -1))
            if !candidate.occluders.contains(where: { $0.contains(inside) }) { return true }
        }
        return false
    }
}

nonisolated enum CaptureSnapAxis: String, Sendable { case x, y }
nonisolated enum CaptureSnapEdge: String, Sendable { case minimum, maximum }
nonisolated enum CaptureSnapOperation: Sendable { case move, resize(CaptureResizeHandle) }
nonisolated struct CaptureSnapLock: Equatable, Sendable {
    let candidateID: String
    let candidateEdge: CaptureSnapEdge
    let movingEdge: CaptureSnapEdge
    let position: CGFloat
}
nonisolated struct CaptureSnapState: Equatable, Sendable {
    var snapshotID: UUID?
    var x: CaptureSnapLock?
    var y: CaptureSnapLock?
    init(snapshotID: UUID? = nil, x: CaptureSnapLock? = nil, y: CaptureSnapLock? = nil) {
        self.snapshotID = snapshotID; self.x = x; self.y = y
    }
}
nonisolated struct CaptureSnapGuide: Equatable, Sendable {
    let axis: CaptureSnapAxis
    let position: CGFloat
    let start: CGFloat
    let end: CGFloat
    let candidateID: String
}
nonisolated struct CaptureSnapResult: Equatable, Sendable {
    let rect: CGRect
    let guides: [CaptureSnapGuide]
    let state: CaptureSnapState
}

nonisolated enum CaptureSnapEngine {
    static let entryThreshold: CGFloat = 8
    static let releaseThreshold: CGFloat = 16

    /// rawRect comes from the original gesture plus raw pointer delta. Passing last frame's
    /// snapped rect here would incorrectly accumulate corrections and prevent lock release.
    static func snap(rect rawRect: CGRect, operation: CaptureSnapOperation, viewport: CGRect,
                     candidates: [CaptureSnapCandidate], snapshotID: UUID,
                     state oldState: CaptureSnapState = CaptureSnapState(),
                     minimumSize: CGSize = CGSize(width: 24, height: 24)) -> CaptureSnapResult {
        let bounds = CaptureInteractionGeometry.valid(viewport)
        var rect = CaptureInteractionGeometry.constrained(rawRect, within: bounds, minimumSize: minimumSize)
        var state = oldState.snapshotID == snapshotID ? oldState : CaptureSnapState()
        state.snapshotID = snapshotID
        let screen = CaptureSnapCandidate(id: "viewport", source: .viewport, rect: bounds,
            confidence: 1, snapshotID: snapshotID, priority: Int.min)
        let validCandidates = CaptureSnapCandidates.filtered([screen] + candidates, snapshotID: snapshotID, viewport: bounds)
        var guides: [CaptureSnapGuide] = []
        for axis in [CaptureSnapAxis.x, .y] {
            let moving = movingEdges(operation, axis: axis)
            let previous = axis == .x ? state.x : state.y
            var chosen: (CaptureSnapLock, CGRect, CaptureSnapCandidate)?
            if let previous, moving.contains(previous.movingEdge),
               let candidate = validCandidates.first(where: { $0.id == previous.candidateID }),
               coordinate(candidate.rect, axis: axis, edge: previous.candidateEdge) == previous.position,
               CaptureSnapCandidates.edgeIsVisible(candidate, axis:axis, edge:previous.candidateEdge) {
                let distance = previous.position - coordinate(rect, axis: axis, edge: previous.movingEdge)
                if abs(distance) <= releaseThreshold,
                   let corrected = corrected(rect, delta: distance, axis: axis, edge: previous.movingEdge,
                                             operation: operation, viewport: bounds, minimumSize: minimumSize) {
                    chosen = (previous, corrected, candidate)
                }
            }
            if chosen == nil {
                var bestDistance = CGFloat.infinity
                for candidate in validCandidates {
                    for sourceEdge in [CaptureSnapEdge.minimum, .maximum] {
                        guard CaptureSnapCandidates.edgeIsVisible(candidate,axis:axis,edge:sourceEdge) else { continue }
                        let target = coordinate(candidate.rect.standardized, axis: axis, edge: sourceEdge)
                        let lower = axis == .x ? bounds.minX : bounds.minY
                        let upper = axis == .x ? bounds.maxX : bounds.maxY
                        guard target >= lower, target <= upper else { continue }
                        for edge in moving {
                            let distance = target - coordinate(rect, axis: axis, edge: edge)
                            guard abs(distance) <= entryThreshold, abs(distance) < bestDistance,
                                  let corrected = corrected(rect, delta: distance, axis: axis, edge: edge,
                                    operation: operation, viewport: bounds, minimumSize: minimumSize) else { continue }
                            bestDistance = abs(distance)
                            chosen = (CaptureSnapLock(candidateID: candidate.id, candidateEdge: sourceEdge,
                                movingEdge: edge, position: target), corrected, candidate)
                        }
                    }
                }
            }
            if axis == .x { state.x = chosen?.0 } else { state.y = chosen?.0 }
            if let (lock, corrected, candidate) = chosen {
                rect = corrected
                let low = axis == .x ? min(rect.minY, candidate.rect.minY) : min(rect.minX, candidate.rect.minX)
                let high = axis == .x ? max(rect.maxY, candidate.rect.maxY) : max(rect.maxX, candidate.rect.maxX)
                guides.append(CaptureSnapGuide(axis: axis, position: lock.position,
                    start: max(low, axis == .x ? bounds.minY : bounds.minX),
                    end: min(high, axis == .x ? bounds.maxY : bounds.maxX), candidateID: candidate.id))
            }
        }
        return CaptureSnapResult(rect: rect, guides: guides, state: state)
    }

    private static func movingEdges(_ operation: CaptureSnapOperation, axis: CaptureSnapAxis) -> [CaptureSnapEdge] {
        switch operation {
        case .move: return [.minimum, .maximum]
        case .resize(let h):
            if axis == .x { return h.movesMinX ? [.minimum] : h.movesMaxX ? [.maximum] : [] }
            return h.movesMinY ? [.minimum] : h.movesMaxY ? [.maximum] : []
        }
    }
    private static func coordinate(_ r: CGRect, axis: CaptureSnapAxis, edge: CaptureSnapEdge) -> CGFloat {
        axis == .x ? (edge == .minimum ? r.minX : r.maxX) : (edge == .minimum ? r.minY : r.maxY)
    }
    private static func corrected(_ rect: CGRect, delta: CGFloat, axis: CaptureSnapAxis, edge: CaptureSnapEdge,
                                  operation: CaptureSnapOperation, viewport: CGRect, minimumSize: CGSize) -> CGRect? {
        var r = rect
        switch operation {
        case .move:
            if axis == .x { r.origin.x += delta } else { r.origin.y += delta }
        case .resize:
            if axis == .x {
                if edge == .minimum { r.origin.x += delta; r.size.width -= delta } else { r.size.width += delta }
            } else {
                if edge == .minimum { r.origin.y += delta; r.size.height -= delta } else { r.size.height += delta }
            }
        }
        let minW = min(max(0, minimumSize.width), viewport.width)
        let minH = min(max(0, minimumSize.height), viewport.height)
        guard r.width >= minW, r.height >= minH, r.minX >= viewport.minX, r.maxX <= viewport.maxX,
              r.minY >= viewport.minY, r.maxY <= viewport.maxY else { return nil }
        return r
    }
}
