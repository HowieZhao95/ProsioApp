import CoreGraphics
import Foundation

/// All interaction coordinates are display-local logical points, with a top-left origin.
nonisolated enum CaptureResizeHandle: String, CaseIterable, Sendable {
    case north, northEast, east, southEast, south, southWest, west, northWest
    var movesMinX: Bool { self == .west || self == .northWest || self == .southWest }
    var movesMaxX: Bool { self == .east || self == .northEast || self == .southEast }
    var movesMinY: Bool { self == .north || self == .northEast || self == .northWest }
    var movesMaxY: Bool { self == .south || self == .southEast || self == .southWest }
    func position(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesMinX ? rect.minX : movesMaxX ? rect.maxX : rect.midX,
                y: movesMinY ? rect.minY : movesMaxY ? rect.maxY : rect.midY)
    }
}

nonisolated enum CaptureToolbarSide: String, Sendable { case below, above, right, left, inside }
nonisolated struct CaptureToolbarPlacement: Equatable, Sendable {
    let frame: CGRect
    let side: CaptureToolbarSide
    /// A constrained frame cannot resize actual controls: the UI must remeasure a compact layout.
    let requiresCompactLayout: Bool
}

nonisolated enum CaptureInteractionGeometry {
    static func move(_ rect: CGRect, translation: CGSize, within viewport: CGRect,
                     minimumSize: CGSize = CGSize(width: 24, height: 24)) -> CGRect {
        let bounds = valid(viewport), base = constrained(rect, within: bounds, minimumSize: minimumSize)
        return CGRect(x: clamp(base.minX + finite(translation.width), bounds.minX, bounds.maxX - base.width),
                      y: clamp(base.minY + finite(translation.height), bounds.minY, bounds.maxY - base.height),
                      width: base.width, height: base.height)
    }

    /// Delta is always measured from the gesture's original rect, never the previous snapped rect.
    static func resize(_ rect: CGRect, handle: CaptureResizeHandle, translation: CGSize,
                       within viewport: CGRect, minimumSize: CGSize = CGSize(width: 24, height: 24)) -> CGRect {
        let bounds = valid(viewport), base = constrained(rect, within: bounds, minimumSize: minimumSize)
        let minW = min(max(0, finite(minimumSize.width)), bounds.width)
        let minH = min(max(0, finite(minimumSize.height)), bounds.height)
        var x1 = base.minX, x2 = base.maxX, y1 = base.minY, y2 = base.maxY
        if handle.movesMinX { x1 = clamp(x1 + finite(translation.width), bounds.minX, x2 - minW) }
        if handle.movesMaxX { x2 = clamp(x2 + finite(translation.width), x1 + minW, bounds.maxX) }
        if handle.movesMinY { y1 = clamp(y1 + finite(translation.height), bounds.minY, y2 - minH) }
        if handle.movesMaxY { y2 = clamp(y2 + finite(translation.height), y1 + minH, bounds.maxY) }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    static func constrained(_ rect: CGRect, within viewport: CGRect,
                            minimumSize: CGSize = CGSize(width: 24, height: 24)) -> CGRect {
        let bounds = valid(viewport), r = valid(rect)
        let w = clamp(r.width, min(max(0, finite(minimumSize.width)), bounds.width), bounds.width)
        let h = clamp(r.height, min(max(0, finite(minimumSize.height)), bounds.height), bounds.height)
        return CGRect(x: clamp(r.minX, bounds.minX, bounds.maxX - w),
                      y: clamp(r.minY, bounds.minY, bounds.maxY - h), width: w, height: h)
    }

    static func toolbarPlacement(selection: CGRect, viewport: CGRect, toolbarSize: CGSize,
                                 previousSide: CaptureToolbarSide? = nil, margin: CGFloat = 12) -> CaptureToolbarPlacement {
        let viewport = valid(viewport), selection = valid(selection)
        let gap = max(0, finite(margin))
        let inset = min(gap, min(viewport.width, viewport.height) / 2)
        let safe = viewport.insetBy(dx: inset, dy: inset)
        let requested = CGSize(width: max(0, finite(toolbarSize.width)), height: max(0, finite(toolbarSize.height)))
        let size = CGSize(width: min(requested.width, safe.width), height: min(requested.height, safe.height))
        let compact = size != requested
        let centeredX = clamp(selection.midX - size.width / 2, safe.minX, safe.maxX - size.width)
        let centeredY = clamp(selection.midY - size.height / 2, safe.minY, safe.maxY - size.height)
        let candidates: [(CaptureToolbarSide, CGRect)] = [
            (.below, CGRect(x: centeredX, y: selection.maxY + gap, width: size.width, height: size.height)),
            (.above, CGRect(x: centeredX, y: selection.minY - gap - size.height, width: size.width, height: size.height)),
            (.right, CGRect(x: selection.maxX + gap, y: centeredY, width: size.width, height: size.height)),
            (.left, CGRect(x: selection.minX - gap - size.width, y: centeredY, width: size.width, height: size.height))
        ]
        let fits: (CGRect) -> Bool = { r in
            r.minX >= safe.minX && r.maxX <= safe.maxX && r.minY >= safe.minY && r.maxY <= safe.maxY
        }
        // Preserve a side while it still fits, to avoid flips near a placement threshold.
        if let previousSide, let previous = candidates.first(where: { $0.0 == previousSide && fits($0.1) }) {
            return CaptureToolbarPlacement(frame: previous.1, side: previous.0, requiresCompactLayout: compact)
        }
        if let preferred = candidates.first(where: { fits($0.1) }) {
            return CaptureToolbarPlacement(frame: preferred.1, side: preferred.0, requiresCompactLayout: compact)
        }
        return CaptureToolbarPlacement(frame: CGRect(x: centeredX,
            y: clamp(selection.maxY + gap, safe.minY, safe.maxY - size.height), width: size.width, height: size.height),
            side: .inside, requiresCompactLayout: compact)
    }

    /// Attach a contextual palette to the toolbar while keeping both surfaces on screen.
    static func palettePlacement(toolbarFrame: CGRect, viewport: CGRect, paletteSize: CGSize,
                                 gap: CGFloat = 7, margin: CGFloat = 12) -> CGRect {
        let viewport = valid(viewport)
        let inset = min(max(0, margin), min(viewport.width, viewport.height) / 2)
        let safe = viewport.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(max(0, paletteSize.width), safe.width),
                          height: min(max(0, paletteSize.height), safe.height))
        let x = clamp(toolbarFrame.midX - size.width / 2, safe.minX, safe.maxX - size.width)
        let below = CGRect(x: x, y: toolbarFrame.maxY + gap, width: size.width, height: size.height)
        let above = CGRect(x: x, y: toolbarFrame.minY - gap - size.height, width: size.width, height: size.height)
        if below.maxY <= safe.maxY { return below }
        if above.minY >= safe.minY { return above }
        let right = CGRect(x: toolbarFrame.maxX + gap,
                           y: clamp(toolbarFrame.midY - size.height / 2, safe.minY, safe.maxY - size.height),
                           width: size.width, height: size.height)
        if right.maxX <= safe.maxX { return right }
        let left = CGRect(x: toolbarFrame.minX - gap - size.width, y: right.minY,
                          width: size.width, height: size.height)
        if left.minX >= safe.minX { return left }
        return CGRect(x: x, y: clamp(below.minY, safe.minY, safe.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func valid(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.maxX.isFinite,
              rect.minY.isFinite, rect.maxY.isFinite else { return .zero }
        return rect.standardized
    }
    static func finite(_ value: CGFloat) -> CGFloat { value.isFinite ? value : 0 }
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { min(max(value, lower), max(lower, upper)) }
}
