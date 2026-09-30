import CoreGraphics
import Foundation

nonisolated struct CapturePixelPoint: Equatable, Sendable {
    let x: Int
    let y: Int
}
nonisolated struct CapturePixelColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    var hex: String { String(format: "#%02X%02X%02X",red,green,blue) }
    var rgb: String { "RGB(\(red), \(green), \(blue))" }
    func formatted(_ format: CapturePixelColorFormat) -> String { format == .hex ? hex : rgb }
}
nonisolated enum CapturePixelColorFormat: Sendable { case hex, rgb }

/// Cached, color-managed source pixels. CGContext converts the frozen image to sRGB once;
/// pointer updates only read a few bytes and never redraw the whole image.
nonisolated struct CapturePixelSampler: Sendable {
    let width: Int
    let height: Int
    private let bytes: Data
    init?(image: CGImage) {
        guard image.width > 0,image.height > 0,image.width <= Int.max/4,
              image.height <= Int.max/(image.width*4),
              let space=CGColorSpace(name:CGColorSpace.sRGB),
              let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,
                  bytesPerRow:image.width*4,space:space,
                  bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let data=context.data else { return nil }
        width=image.width;height=image.height
        bytes=Data(bytes:data,count:image.width*image.height*4)
    }
    func color(at point: CapturePixelPoint) -> CapturePixelColor? {
        guard point.x>=0,point.y>=0,point.x<width,point.y<height else { return nil }
        let index=(point.y*width+point.x)*4
        return bytes.withUnsafeBytes { raw -> CapturePixelColor in
            let p=raw.bindMemory(to:UInt8.self),alpha=Int(p[index+3])
            func unpremultiply(_ value:UInt8)->UInt8 {
                guard alpha>0 else { return 0 }
                return UInt8(min(255,(Int(value)*255+alpha/2)/alpha))
            }
            return CapturePixelColor(red:unpremultiply(p[index]),green:unpremultiply(p[index+1]),blue:unpremultiply(p[index+2]))
        }
    }
}

nonisolated enum CapturePixelLoupeGeometry {
    static func sourcePixel(at viewPoint: CGPoint,imageFrame: CGRect,imageSize: CGSize) -> CapturePixelPoint? {
        guard viewPoint.x.isFinite,viewPoint.y.isFinite,imageFrame.width.isFinite,imageFrame.height.isFinite,
              imageFrame.width>0,imageFrame.height>0,imageSize.width>0,imageSize.height>0,
              viewPoint.x>=imageFrame.minX,viewPoint.x<=imageFrame.maxX,
              viewPoint.y>=imageFrame.minY,viewPoint.y<=imageFrame.maxY else { return nil }
        let x=Int(floor((viewPoint.x-imageFrame.minX)*imageSize.width/imageFrame.width))
        let y=Int(floor((viewPoint.y-imageFrame.minY)*imageSize.height/imageFrame.height))
        return CapturePixelPoint(x:min(max(x,0),Int(imageSize.width)-1),y:min(max(y,0),Int(imageSize.height)-1))
    }
    static func placement(pointer: CGPoint,viewport: CGRect,popupSize: CGSize,
                          avoiding obstacles: [CGRect] = [],margin: CGFloat = 10) -> CGRect {
        let bounds=viewport.standardized.insetBy(dx:margin,dy:margin)
        let w=min(max(0,popupSize.width),max(0,bounds.width)),h=min(max(0,popupSize.height),max(0,bounds.height))
        let offset:CGFloat=18
        let origins=[CGPoint(x:pointer.x+offset,y:pointer.y+offset),
                     CGPoint(x:pointer.x-offset-w,y:pointer.y+offset),
                     CGPoint(x:pointer.x+offset,y:pointer.y-offset-h),
                     CGPoint(x:pointer.x-offset-w,y:pointer.y-offset-h)]
        let frames=origins.map { CGRect(origin:$0,size:CGSize(width:w,height:h)) }
        if let fitting=frames.first(where: { frame in
            bounds.contains(frame) && obstacles.allSatisfy { obstacle in !obstacle.intersects(frame) }
        }) {
            return fitting
        }
        // Prefer an on-screen position that overlaps the least toolbar area.
        return frames.map { frame in
            CGRect(x:min(max(frame.minX,bounds.minX),bounds.maxX-w),
                   y:min(max(frame.minY,bounds.minY),bounds.maxY-h),width:w,height:h)
        }.min { left,right in
            func score(_ r:CGRect)->CGFloat {
                let overlap=obstacles.reduce(CGFloat.zero) { sum,obstacle in
                    let intersection=r.intersection(obstacle)
                    return sum+(intersection.isNull ? 0 : intersection.width*intersection.height)
                }
                return overlap*1000+hypot(r.midX-pointer.x,r.midY-pointer.y)
            }
            return score(left)<score(right)
        } ?? CGRect(origin:bounds.origin,size:CGSize(width:w,height:h))
    }
}

nonisolated enum CapturePixelLoupeKeys {
    static func copiesColor(characters: String?,command: Bool,option: Bool,control: Bool,shift: Bool,
                            textEditing: Bool,loupeVisible: Bool) -> Bool {
        loupeVisible && !textEditing && !command && !option && !control && !shift &&
        characters?.lowercased() == "c"
    }
    static func togglesFormat(shiftDownAt: TimeInterval?,releaseAt: TimeInterval,
                              interrupted: Bool,otherModifiers: Bool,textEditing: Bool) -> Bool {
        guard let shiftDownAt,!interrupted,!otherModifiers,!textEditing else { return false }
        let duration=releaseAt-shiftDownAt
        return duration>=0 && duration<=0.45
    }
}
