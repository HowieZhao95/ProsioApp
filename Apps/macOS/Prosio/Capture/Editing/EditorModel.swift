// Adapted from SnipSnipSnip Editor/EditorModel.swift, fixed commit
// 7919eac9df9d9dec8427dbc0c10aecd32baf5530. Copyright (c) 2026 Oontz; MIT.
import AppKit
import CoreGraphics
import Foundation

nonisolated enum TextAlignmentMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case left
    case center
    case right

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .left:
            return "Align Left"
        case .center:
            return "Align Center"
        case .right:
            return "Align Right"
        }
    }

    nonisolated var shortLabel: String {
        switch self {
        case .left:
            return "Left"
        case .center:
            return "Center"
        case .right:
            return "Right"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .left:
            return "text.alignleft"
        case .center:
            return "text.aligncenter"
        case .right:
            return "text.alignright"
        }
    }

    nonisolated var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left:
            return .left
        case .center:
            return .center
        case .right:
            return .right
        }
    }
}

nonisolated struct PaletteColorOption: Identifiable, Equatable {
    let id: String
    let label: String
    let color: RGBAColor
    let showsCheckerboard: Bool
}

nonisolated struct RGBAColor: Equatable, Codable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated func withAlpha(_ alpha: CGFloat) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated var complementary: RGBAColor {
        RGBAColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: alpha)
    }

    nonisolated static func == (lhs: RGBAColor, rhs: RGBAColor) -> Bool {
        lhs.red == rhs.red
            && lhs.green == rhs.green
            && lhs.blue == rhs.blue
            && lhs.alpha == rhs.alpha
    }

    nonisolated static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    nonisolated static let rectangleStroke = RGBAColor(red: 0.89, green: 0.20, blue: 0.24, alpha: 1)
    nonisolated static let ellipseStroke = RGBAColor(red: 0.24, green: 0.45, blue: 0.89, alpha: 1)
    nonisolated static let lineStroke = RGBAColor(red: 0.10, green: 0.68, blue: 0.56, alpha: 1)
    nonisolated static let arrowStroke = RGBAColor(red: 0.95, green: 0.56, blue: 0.14, alpha: 1)
    nonisolated static let highlightFill = RGBAColor(red: 1.00, green: 0.89, blue: 0.18, alpha: 0.35)
    nonisolated static let freehandStroke = RGBAColor(red: 0.22, green: 0.77, blue: 0.35, alpha: 1)
    nonisolated static let highlighterStroke = RGBAColor(red: 1.00, green: 0.92, blue: 0.20, alpha: 0.55)
    nonisolated static let textForeground = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    nonisolated static let textBackground = RGBAColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.8)
    nonisolated static let calloutFill = RGBAColor(red: 0.88, green: 0.15, blue: 0.28, alpha: 1)
    nonisolated static let measureStroke = RGBAColor(red: 0.19, green: 0.78, blue: 0.92, alpha: 1)
    nonisolated static let blurOutline = RGBAColor(red: 0.19, green: 0.58, blue: 0.96, alpha: 1)
    nonisolated static let pixelateOutline = RGBAColor(red: 0.51, green: 0.29, blue: 0.78, alpha: 1)
    nonisolated static let redactionFill = RGBAColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)

    nonisolated static let paletteOptions: [PaletteColorOption] = [
        PaletteColorOption(id: "red", label: "Red", color: .rectangleStroke, showsCheckerboard: false),
        PaletteColorOption(id: "blue", label: "Blue", color: .ellipseStroke, showsCheckerboard: false),
        PaletteColorOption(id: "green", label: "Green", color: .lineStroke, showsCheckerboard: false),
        PaletteColorOption(id: "orange", label: "Orange", color: .arrowStroke, showsCheckerboard: false),
        PaletteColorOption(id: "yellow", label: "Yellow", color: .highlightFill.withAlpha(1), showsCheckerboard: false),
        PaletteColorOption(id: "pink", label: "Pink", color: .calloutFill, showsCheckerboard: false),
        PaletteColorOption(id: "sky-blue", label: "Sky Blue", color: .blurOutline, showsCheckerboard: false),
        PaletteColorOption(id: "white", label: "White", color: .textForeground, showsCheckerboard: false),
        PaletteColorOption(id: "black", label: "Black", color: .redactionFill, showsCheckerboard: false),
        PaletteColorOption(id: "transparent", label: "Transparent", color: .clear, showsCheckerboard: true)
    ]

    nonisolated static func paletteOption(id: String) -> PaletteColorOption? {
        paletteOptions.first { $0.id == id }
    }

    nonisolated static func paletteOption(for color: RGBAColor) -> PaletteColorOption? {
        paletteOptions.first { $0.color == color }
    }

    nonisolated static let palette: [RGBAColor] = paletteOptions.map(\.color)
}

nonisolated struct RectangleShape: Equatable, Codable, Sendable {
    var rect: CGRect
}

nonisolated struct EllipseShape: Equatable, Codable, Sendable {
    var rect: CGRect
}

nonisolated struct LineShape: Equatable, Codable, Sendable {
    var start: CGPoint
    var end: CGPoint
}

nonisolated struct FreehandShape: Equatable, Codable, Sendable {
    var points: [CGPoint]
}

nonisolated struct HighlighterShape: Equatable, Codable, Sendable {
    var points: [CGPoint]
}

nonisolated struct TextShape: Equatable, Codable, Sendable {
    var rect: CGRect
    var text: String
    var alignment: TextAlignmentMode = .left
    var automaticallySizesToText: Bool = true
    /// Present only on translated overlays. Optional for older saved captures.
    var translationSource: String? = nil
    /// Optional so older captures keep their existing rendering. Font matching is best effort.
    var fontName: String? = nil
    /// Only the original ink is erased when translation wraps into surrounding free space.
    var translationSourceRect: CGRect? = nil
}

nonisolated struct HighlightShape: Equatable, Codable, Sendable {
    var rect: CGRect
}


nonisolated enum EditorTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case select, rectangle, ellipse, arrow, line, markerLine, text, freehand, highlight, redact, pixelate, blur
    var id: String { rawValue }
    var label: String { switch self { case .select: "Select / move"; case .line: "直线"; case .markerLine: "标注线"; case .arrow: "箭头"; case .freehand: "Pen"; case .redact: "Solid redaction"; default: rawValue.capitalized } }
    var systemImage: String { switch self {
    case .select: "cursorarrow"; case .rectangle: "rectangle"; case .ellipse: "oval"; case .arrow: "arrow.up.right"; case .line: "line.diagonal"; case .markerLine: "arrow.left.and.right"; case .text: "text.cursor"; case .freehand: "pencil.tip"; case .highlight: "highlighter"; case .redact: "rectangle.fill"; case .pixelate: "square.grid.3x3.fill"; case .blur: "drop.halffull"
    } }
    var usesColor: Bool { ![.select, .redact, .pixelate, .blur].contains(self) }
}
nonisolated struct AnnotationStyle: Equatable, Codable, Sendable {
    var strokeColor: RGBAColor = .rectangleStroke
    var fillColor: RGBAColor = .clear
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 28
    var effectRadius: CGFloat = 16
    var opacity: CGFloat = 1
}
// Stored screenshots from earlier builds have no opacity field.
extension AnnotationStyle {
    private enum CodingKeys: String, CodingKey { case strokeColor, fillColor, lineWidth, fontSize, effectRadius, opacity }
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try values.decodeIfPresent(RGBAColor.self, forKey: .strokeColor) ?? .rectangleStroke
        fillColor = try values.decodeIfPresent(RGBAColor.self, forKey: .fillColor) ?? .clear
        lineWidth = try values.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 4
        fontSize = try values.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 28
        effectRadius = try values.decodeIfPresent(CGFloat.self, forKey: .effectRadius) ?? 16
        opacity = min(max(try values.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1, 0), 1)
    }
}
nonisolated struct ArrowShape: Equatable, Codable, Sendable { var start: CGPoint; var end: CGPoint }
nonisolated enum RedactionMode: String, Codable, Sendable { case blur, pixelate, solid }
nonisolated struct RedactionShape: Equatable, Codable, Sendable { var rect: CGRect; var mode: RedactionMode }
nonisolated enum AnnotationKind: Equatable, Codable, Sendable {
    case rectangle(RectangleShape), ellipse(EllipseShape), arrow(ArrowShape), line(LineShape), markerLine(LineShape), text(TextShape), freehand(FreehandShape), highlight(HighlightShape), redaction(RedactionShape)
    func transformingGeometry(rect: (CGRect) -> CGRect, point: (CGPoint) -> CGPoint) -> AnnotationKind {
        switch self {
        case .rectangle(let s): .rectangle(RectangleShape(rect: rect(s.rect)))
        case .ellipse(let s): .ellipse(EllipseShape(rect: rect(s.rect)))
        case .arrow(let s): .arrow(ArrowShape(start: point(s.start), end: point(s.end)))
        case .line(let s): .line(LineShape(start: point(s.start), end: point(s.end)))
        case .markerLine(let s): .markerLine(LineShape(start: point(s.start), end: point(s.end)))
        case .text(let s): .text(TextShape(rect: rect(s.rect), text: s.text, alignment: s.alignment, automaticallySizesToText: s.automaticallySizesToText, translationSource: s.translationSource, fontName: s.fontName, translationSourceRect: s.translationSourceRect.map(rect)))
        case .freehand(let s): .freehand(FreehandShape(points: s.points.map(point)))
        case .highlight(let s): .highlight(HighlightShape(rect: rect(s.rect)))
        case .redaction(let s): .redaction(RedactionShape(rect: rect(s.rect), mode: s.mode))
        }
    }
}
nonisolated enum AnnotationEndpoint: CaseIterable { case start, end }
nonisolated struct Annotation: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var kind: AnnotationKind
    var style: AnnotationStyle
    init(id: UUID = UUID(), kind: AnnotationKind, style: AnnotationStyle = AnnotationStyle()) { self.id = id; self.kind = kind; self.style = style }
    var isColorEditable: Bool {
        if case .redaction = kind { return false }
        return true
    }
    var isTranslation: Bool {
        if case .text(let shape) = kind { return shape.translationSource != nil }
        return false
    }
    var propertyTool: EditorTool {
        switch kind {
        case .rectangle, .highlight: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .markerLine: .markerLine
        case .text: .text
        case .freehand: .freehand
        case .redaction(let shape): shape.mode == .solid ? .redact : shape.mode == .blur ? .blur : .pixelate
        }
    }
    var editableStyle: AnnotationStyle {
        var copy = style
        if case .highlight = kind {
            copy.fillColor = style.strokeColor.withAlpha(style.strokeColor.alpha * 0.32)
            copy.lineWidth = 0
        }
        return copy
    }
    func updatingStyle(_ style: AnnotationStyle) -> Annotation {
        var copy = self
        if case .highlight(let shape) = kind { copy.kind = .rectangle(RectangleShape(rect: shape.rect)) }
        copy.style = style
        return copy
    }
    var lineGeometry: LineShape? {
        switch kind {
        case .arrow(let shape): LineShape(start: shape.start, end: shape.end)
        case .line(let shape), .markerLine(let shape): shape
        default: nil
        }
    }
    var lineTool: EditorTool? {
        switch kind {
        case .arrow: .arrow
        case .line: .line
        case .markerLine: .markerLine
        default: nil
        }
    }
    func changingLineTool(_ tool: EditorTool) -> Annotation {
        guard let shape = lineGeometry else { return self }
        var copy = self
        switch tool {
        case .arrow: copy.kind = .arrow(ArrowShape(start: shape.start, end: shape.end))
        case .line: copy.kind = .line(shape)
        case .markerLine: copy.kind = .markerLine(shape)
        default: break
        }
        return copy
    }
    func movingEndpoint(_ endpoint: AnnotationEndpoint, to point: CGPoint) -> Annotation {
        guard var shape = lineGeometry, let tool = lineTool else { return self }
        if endpoint == .start { shape.start = point } else { shape.end = point }
        var copy = self
        copy.kind = .line(shape)
        return copy.changingLineTool(tool)
    }
    var boundingRect: CGRect {
        switch kind {
        case .rectangle(let s): s.rect
        case .ellipse(let s): s.rect
        case .text(let s): s.rect
        case .highlight(let s): s.rect
        case .redaction(let s): s.rect
        case .arrow(let s): CGRect(x: min(s.start.x,s.end.x), y: min(s.start.y,s.end.y), width: abs(s.end.x-s.start.x), height: abs(s.end.y-s.start.y)).insetBy(dx: -style.lineWidth*3, dy: -style.lineWidth*3)
        case .line(let s), .markerLine(let s): Self.pointBounds([s.start, s.end]).insetBy(dx: -max(6, style.lineWidth*2), dy: -max(6, style.lineWidth*2))
        case .freehand(let s): Self.pointBounds(s.points).insetBy(dx: -style.lineWidth/2, dy: -style.lineWidth/2)
        }
    }
    var renderBounds: CGRect {
        switch kind {
        case .rectangle(let s): return s.rect.insetBy(dx: -style.lineWidth/2, dy: -style.lineWidth/2)
        case .ellipse(let s): return s.rect.insetBy(dx: -style.lineWidth/2, dy: -style.lineWidth/2)
        case .arrow: return boundingRect.insetBy(dx: -max(14,style.lineWidth*4), dy: -max(14,style.lineWidth*4))
        default: return boundingRect
        }
    }
    private static func pointBounds(_ points: [CGPoint]) -> CGRect {
        guard let p = points.first else { return .zero }
        var a=p, b=p
        for p in points { a.x=min(a.x,p.x); a.y=min(a.y,p.y); b.x=max(b.x,p.x); b.y=max(b.y,p.y) }
        return CGRect(x: a.x, y: a.y, width: b.x-a.x, height: b.y-a.y)
    }
    func translated(by delta: CGSize) -> Annotation {
        var copy=self
        copy.kind=kind.transformingGeometry(rect: { $0.offsetBy(dx: delta.width, dy: delta.height) }, point: { CGPoint(x: $0.x+delta.width,y:$0.y+delta.height) })
        return copy
    }
    func contains(_ point: CGPoint) -> Bool {
        switch kind {
        case .ellipse(let s):
            let r=s.rect.insetBy(dx:-6,dy:-6); guard r.width>0,r.height>0 else { return false }
            let x=(point.x-r.midX)/(r.width/2), y=(point.y-r.midY)/(r.height/2)
            return x*x+y*y<=1.1
        case .arrow(let s): return annotationDistance(point, s.start, s.end)<=max(style.lineWidth*1.5,10)
        case .line(let s), .markerLine(let s): return annotationDistance(point, s.start, s.end)<=max(style.lineWidth*1.5,10)
        case .freehand(let s): return zip(s.points,s.points.dropFirst()).contains { annotationDistance(point,$0.0,$0.1)<=max(style.lineWidth*1.5,8) }
        default: return boundingRect.insetBy(dx:-6,dy:-6).contains(point)
        }
    }
}
nonisolated func annotationDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx=b.x-a.x, dy=b.y-a.y, l=dx*dx+dy*dy
    let t=l>0 ? min(max(((p.x-a.x)*dx+(p.y-a.y)*dy)/l,0),1) : 0
    return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
}
nonisolated struct EditorSnapshot: Equatable, Codable, Sendable {
    var cropRect: CGRect
    var annotations: [Annotation] = []
    var selectedAnnotationIDs: [UUID] = []
}
