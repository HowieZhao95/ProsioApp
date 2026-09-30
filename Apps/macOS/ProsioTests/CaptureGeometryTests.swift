import CoreGraphics
import Testing

@Suite("Capture geometry")
struct CaptureGeometryTests {
    @Test("AppKit points map through each screen's distinct capture and overlay frames")
    func topologyMapping() {
        let cases: [(CGRect, CGRect, CGPoint, CGPoint)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 900), CGPoint(x: 100, y: 800), CGPoint(x: 100, y: 100)),
            (CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: -1920, y: -180, width: 1920, height: 1080), CGPoint(x: -1800, y: 800), CGPoint(x: -1800, y: 100)),
            (CGRect(x: 0, y: -1080, width: 1920, height: 1080), CGRect(x: 0, y: 900, width: 1920, height: 1080), CGPoint(x: 100, y: 1880), CGPoint(x: 100, y: -980)),
            (CGRect(x: 0, y: 900, width: 1920, height: 1080), CGRect(x: 0, y: -1080, width: 1920, height: 1080), CGPoint(x: 100, y: -100), CGPoint(x: 100, y: 1000))
        ]
        for (capture, overlay, appKitPoint, expectedCapturePoint) in cases {
            let transform = CaptureDisplayTransform(captureFrame: capture, overlayFrame: overlay)
            #expect(transform.captureGlobalPoint(fromOverlayGlobalPoint: appKitPoint) == expectedCapturePoint)
            #expect(transform.overlayGlobalPoint(fromCaptureGlobalPoint: expectedCapturePoint) == appKitPoint)
        }
    }

    @Test("Retina preview crops use top-left pixels and invert only AppKit source y")
    func retinaPreviewCrop() {
        let display = CaptureDisplayTransform(captureFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900), overlayFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let preview = CapturePreviewTransform(displayTransform: display, previewPixelSize: CGSize(width: 2880, height: 1800))
        let global = CGRect(x: -1340, y: 50, width: 300, height: 100)
        #expect(preview.previewTopLeftPixelRect(fromCaptureGlobalRect: global) == CGRect(x: 200, y: 100, width: 600, height: 200))
        #expect(preview.appKitSourceRect(fromCaptureGlobalRect: global) == CGRect(x: 200, y: 1500, width: 600, height: 200))
    }

    @Test("Fractional scaling expands outwards to preserve selected edge pixels")
    func fractionalPixelCoverage() {
        let transform = TopLeftRectTransform(sourceBounds: CGRect(x: 0, y: 0, width: 100, height: 80), targetBounds: CGRect(x: 0, y: 0, width: 150, height: 120))
        #expect(transform.targetRect(fromSourceRect: CGRect(x: 1, y: 1, width: 2, height: 2)) == CGRect(x: 1, y: 1, width: 4, height: 4))
    }

    @Test("Reverse drags standardize before scaling")
    func reverseDrag() {
        let transform = TopLeftRectTransform(sourceBounds: CGRect(x: 0, y: 0, width: 100, height: 100), targetBounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(transform.targetRect(fromSourceRect: CGRect(x: 70, y: 80, width: -40, height: -50)) == CGRect(x: 60, y: 60, width: 80, height: 100))
    }

    @Test("Local rect conversion preserves negative display origin and normalizes drag")
    func negativeOriginRect() {
        let transform = CaptureScreenTransform(captureFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        let local = transform.localRect(fromGlobalRect: CGRect(x: -1800, y: -900, width: 300, height: 200))
        #expect(local == CGRect(x: 120, y: 180, width: 300, height: 200))
        #expect(transform.globalRect(fromLocalRect: local) == CGRect(x: -1800, y: -900, width: 300, height: 200))
    }

    @Test("Invalid display dimensions and scale have finite safe defaults")
    func invalidDisplayMetadata() {
        let display = DisplaySnapshot(displayID: 9, name: "invalid", frame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), scale: .infinity)
        #expect(display.frame == .zero)
        #expect(display.scale == 1)
        let transform = TopLeftRectTransform(sourceBounds: .zero, targetBounds: CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(transform.targetPoint(fromSourcePoint: CGPoint(x: 999, y: 999)) == CGPoint(x: 10, y: 20))
    }

    @Test("Intersecting display resolution chooses max scale and outside region uses fallback")
    func mixedDisplayScales() {
        let displays = [DisplaySnapshot(displayID: 1, name: "1x", frame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1), DisplaySnapshot(displayID: 2, name: "2x", frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)]
        #expect(gscDisplayScale(forCaptureFrame: CGRect(x: -10, y: 0, width: 20, height: 20), displays: displays, fallbackScale: 1) == 2)
        #expect(gscDisplayScale(forCaptureFrame: CGRect(x: 200, y: 0, width: 20, height: 20), displays: displays, fallbackScale: 1.5) == 1.5)
    }
}
