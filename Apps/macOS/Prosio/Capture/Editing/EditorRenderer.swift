// Adapted from SnipSnipSnip Editor/EditorRenderer.swift (7919eac9),
// crop/projection, stroke-and-fill, arrow and sampled CoreImage redaction paths.
// Copyright (c) 2026 Oontz. MIT; see third-party notices.
import AppKit
import CoreGraphics
import CoreImage
import CoreText

nonisolated enum EditorRenderError: LocalizedError {
    case invalidCrop, renderingFailed, redactionFailed
    var errorDescription: String? { switch self {
    case .invalidCrop: "The selected area is outside the frozen screenshot."
    case .renderingFailed: "The edited screenshot could not be rendered."
    case .redactionFailed: "A redaction could not be applied. The image was not exported."
    } }
}
nonisolated enum EditorRenderer {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static func render(baseImage: CGImage, snapshot: EditorSnapshot) throws -> CGImage {
        let bounds=CGRect(x:0,y:0,width:baseImage.width,height:baseImage.height)
        let crop=snapshot.cropRect.standardized.integral
        guard crop.width>0,crop.height>0,bounds.contains(crop), let cropped=baseImage.cropping(to:crop) else { throw EditorRenderError.invalidCrop }
        guard let space=CGColorSpace(name:CGColorSpace.sRGB), let context=CGContext(data:nil,width:cropped.width,height:cropped.height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorRenderError.renderingFailed }
        let canvas=CGRect(x:0,y:0,width:cropped.width,height:cropped.height)
        context.draw(cropped,in:canvas)
        for annotation in snapshot.annotations {
            let a=annotation.translated(by:CGSize(width:-crop.minX,height:-crop.minY))
            // Geometry is top-left y-down; CoreGraphics output is bottom-left.
            context.saveGState()
            context.translateBy(x:0,y:canvas.height); context.scaleBy(x:1,y:-1)
            let style=a.style
            switch a.kind {
            case .redaction(let s):
                context.setAlpha(a.style.opacity)
                let local=s.rect.standardized.integral.intersection(canvas)
                if !local.isNull && local.width>0 && local.height>0 {
                    if s.mode == .solid { context.setFillColor(RGBAColor.redactionFill.cgColor); context.fill(local) }
                    else {
                        context.restoreGState()
                        guard let composite=context.makeImage(),let focused=processedRedaction(mode:s.mode,rect:local,image:composite,radius:style.effectRadius) else { throw EditorRenderError.redactionFailed }
                        context.saveGState()
                        context.setAlpha(a.style.opacity)
                        context.interpolationQuality = s.mode == .pixelate ? .none : .high
                        context.draw(focused,in:CGRect(x:local.minX,y:canvas.height-local.maxY,width:local.width,height:local.height))
                    }
                }
            default: drawVectorAnnotation(a, in: context)
            }
            context.restoreGState()
        }
        guard let image=context.makeImage() else { throw EditorRenderError.renderingFailed }; return image
    }
    // Draw in top-left source-pixel coordinates, shared by export and live dragging.
    static func drawVectorAnnotation(_ a: Annotation, in context: CGContext) {
        let style = a.style
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(style.opacity)
        switch a.kind {
        case .rectangle(let s): strokeAndFill(path:CGPath(rect:s.rect,transform:nil),style:style,context:context)
        case .ellipse(let s): strokeAndFill(path:CGPath(ellipseIn:s.rect,transform:nil),style:style,context:context)
        case .arrow(let s):
            let path=CGMutablePath(); path.move(to:s.start); path.addLine(to:s.end)
            let length=hypot(s.end.x-s.start.x,s.end.y-s.start.y)
            if length>0 {
                let head=arrowHeadLength(bodyLength:length,lineWidth:style.lineWidth), angle=atan2(s.end.y-s.start.y,s.end.x-s.start.x)
                path.move(to:CGPoint(x:s.end.x-head*cos(angle-0.5),y:s.end.y-head*sin(angle-0.5)))
                path.addLine(to:s.end); path.addLine(to:CGPoint(x:s.end.x-head*cos(angle+0.5),y:s.end.y-head*sin(angle+0.5)))
            }
            stroke(path:path,style:style,context:context)
        case .line(let s), .markerLine(let s):
            let path = CGMutablePath()
            path.move(to: s.start); path.addLine(to: s.end)
            if case .markerLine = a.kind {
                let angle = atan2(s.end.y-s.start.y, s.end.x-s.start.x)
                let halfTick = max(6, style.lineWidth*2)
                let dx = -sin(angle)*halfTick, dy = cos(angle)*halfTick
                for point in [s.start, s.end] {
                    path.move(to: CGPoint(x: point.x-dx, y: point.y-dy))
                    path.addLine(to: CGPoint(x: point.x+dx, y: point.y+dy))
                }
            }
            stroke(path: path, style: style, context: context)
        case .freehand(let s):
            let path=CGMutablePath()
            if let first=s.points.first { path.move(to:first); for p in s.points.dropFirst() { path.addLine(to:p) } }
            stroke(path:path,style:style,context:context)
        case .highlight(let s):
            context.setFillColor(style.strokeColor.withAlpha(0.32).cgColor); context.fill(s.rect)
        case .text(let s): drawText(s,style:style,context:context)
        case .redaction(let s):
            if s.mode == .solid {
                context.setFillColor(RGBAColor.redactionFill.cgColor)
                context.fill(s.rect)
            }
        }
    }
    // Retained upstream adaptive arrowhead sizing; short arrows cannot grow a detached head.
    static func arrowHeadLength(bodyLength:CGFloat,lineWidth:CGFloat) -> CGFloat {
        guard bodyLength>0 else { return max(lineWidth*3.5,14) }
        let baseLength=max(lineWidth*3.5,14)
        let proportionalLength=bodyLength*0.14
        let strokeRelativeCap=max(lineWidth*7,36)
        let shortArrowCap=bodyLength*0.38
        return min(min(max(baseLength,proportionalLength),strokeRelativeCap),shortArrowCap)
    }
    private static func strokeAndFill(path:CGPath,style:AnnotationStyle,context:CGContext) {
        context.saveGState()
        if style.fillColor.alpha>0 { context.setFillColor(style.fillColor.cgColor); context.addPath(path); context.fillPath() }
        if style.lineWidth>0 { stroke(path:path,style:style,context:context) }
        context.restoreGState()
    }
    private static func stroke(path:CGPath,style:AnnotationStyle,context:CGContext) {
        context.setStrokeColor(style.strokeColor.cgColor); context.setLineWidth(style.lineWidth)
        context.setLineCap(.round);context.setLineJoin(.round);context.addPath(path);context.strokePath()
    }
    private static func drawText(_ shape:TextShape,style:AnnotationStyle,context:CGContext) {
        // CoreText receives its own y-up frame inside the top-left shape rectangle.
        context.saveGState();context.translateBy(x:shape.rect.minX,y:shape.rect.maxY);context.scaleBy(x:1,y:-1)
        let font=CTFontCreateWithName("Helvetica" as CFString,max(style.fontSize,1),nil)
        let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):style.strokeColor.cgColor]
        let text=NSAttributedString(string:shape.text,attributes:attributes)
        let setter=CTFramesetterCreateWithAttributedString(text)
        let path=CGPath(rect:CGRect(origin:.zero,size:shape.rect.size),transform:nil)
        context.textMatrix = .identity
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil),context)
        context.restoreGState()
    }
    private static func processedRedaction(mode:RedactionMode,rect:CGRect,image:CGImage,radius:CGFloat) -> CGImage? {
        let amount=max(radius,1)
        let expanded=rect.insetBy(dx:-max(amount*2,12),dy:-max(amount*2,12)).intersection(CGRect(x:0,y:0,width:image.width,height:image.height)).integral
        guard let sample=image.cropping(to:expanded) else { return nil }
        let input=CIImage(cgImage:sample)
        guard let filter=CIFilter(name:mode == .blur ? "CIGaussianBlur" : "CIPixellate") else { return nil }
        filter.setValue(mode == .blur ? input.clampedToExtent() : input,forKey:kCIInputImageKey)
        filter.setValue(amount,forKey:mode == .blur ? kCIInputRadiusKey : kCIInputScaleKey)
        if mode == .pixelate { filter.setValue(CIVector(x:input.extent.midX,y:input.extent.midY),forKey:kCIInputCenterKey) }
        guard let output=filter.outputImage?.cropped(to:input.extent),let processed=ciContext.createCGImage(output,from:input.extent) else { return nil }
        return processed.cropping(to:rect.offsetBy(dx:-expanded.minX,dy:-expanded.minY))
    }
}
