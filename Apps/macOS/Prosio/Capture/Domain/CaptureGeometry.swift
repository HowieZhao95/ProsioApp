// Adapted from SnipSnipSnip, commit 7919eac9df9d9dec8427dbc0c10aecd32baf5530.
// Copyright (c) 2026 Oontz. MIT; see THIRD_PARTY_LICENSES/SnipSnipSnip-LICENSE.
import CoreGraphics
import Foundation

/// Scales points and rects between two top-left, y-down spaces.
nonisolated struct TopLeftRectTransform: Equatable {
    let sourceBounds: CGRect
    let targetBounds: CGRect

    init(sourceBounds: CGRect, targetBounds: CGRect) {
        self.sourceBounds = sourceBounds.standardized
        self.targetBounds = targetBounds.standardized
    }

    func targetPoint(fromSourcePoint point: CGPoint) -> CGPoint {
        gscScaledPoint(point, from: sourceBounds, to: targetBounds)
    }

    func targetRect(fromSourceRect rect: CGRect) -> CGRect {
        gscScaledRect(rect, from: sourceBounds, to: targetBounds)
    }
}

nonisolated struct CaptureGlobalRect: Equatable {
    let cgRect: CGRect

    init(_ rect: CGRect) {
        cgRect = rect.gscIntegralStandardized
    }
}

nonisolated struct DisplayLocalRect: Equatable {
    let cgRect: CGRect

    init(_ rect: CGRect) {
        cgRect = rect.gscIntegralStandardized
    }
}

/// Maps AppKit global screen points into top-left overlay-local points.
nonisolated struct AppKitOverlayTransform: Equatable {
    let overlayFrame: CGRect

    init(overlayFrame: CGRect) {
        self.overlayFrame = overlayFrame.gscFiniteOr(.zero)
    }

    func localPoint(fromGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - overlayFrame.minX, y: overlayFrame.maxY - point.y)
    }

    func globalPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: overlayFrame.minX + point.x, y: overlayFrame.maxY - point.y)
    }
}

/// Maps Quartz/ScreenCaptureKit global points into top-left display-local points.
nonisolated struct CaptureScreenTransform: Equatable {
    let captureFrame: CGRect

    init(captureFrame: CGRect) {
        self.captureFrame = captureFrame.gscFiniteOr(.zero)
    }

    func localPoint(fromGlobalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - captureFrame.minX, y: point.y - captureFrame.minY)
    }

    func globalPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(x: captureFrame.minX + point.x, y: captureFrame.minY + point.y)
    }

    func localRect(fromGlobalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: normalized.minX - captureFrame.minX,
            y: normalized.minY - captureFrame.minY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
    }

    func localRect(fromGlobalRect rect: CaptureGlobalRect) -> DisplayLocalRect {
        DisplayLocalRect(localRect(fromGlobalRect: rect.cgRect))
    }

    func globalRect(fromLocalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        return CGRect(
            x: captureFrame.minX + normalized.minX,
            y: captureFrame.minY + normalized.minY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
    }
}

/// Maps between ScreenCaptureKit capture-global points and AppKit overlay points.
///
/// - `captureFrame` is in Quartz global screen points with a top-left origin and y-down axis.
/// - `overlayFrame` is in AppKit screen points with a bottom-left origin.
/// - `captureLocal*` and `overlayLocal*` APIs operate in top-left, y-down local spaces.
nonisolated struct CaptureDisplayTransform: Equatable {
    let captureFrame: CGRect
    let overlayFrame: CGRect

    init(captureFrame: CGRect, overlayFrame: CGRect) {
        let sanitizedCaptureFrame = captureFrame.gscFiniteOr(.zero)
        self.captureFrame = sanitizedCaptureFrame
        self.overlayFrame = overlayFrame.gscFiniteOr(sanitizedCaptureFrame)
    }

    var captureLocalBounds: CGRect {
        CGRect(origin: .zero, size: captureFrame.size)
    }

    var overlayLocalBounds: CGRect {
        CGRect(origin: .zero, size: overlayFrame.size)
    }

    private var captureScreenTransform: CaptureScreenTransform {
        CaptureScreenTransform(captureFrame: captureFrame)
    }

    private var appKitOverlayTransform: AppKitOverlayTransform {
        AppKitOverlayTransform(overlayFrame: overlayFrame)
    }

    private var overlayToCaptureLocalTransform: TopLeftRectTransform {
        TopLeftRectTransform(sourceBounds: overlayLocalBounds, targetBounds: captureLocalBounds)
    }

    private var captureToOverlayLocalTransform: TopLeftRectTransform {
        TopLeftRectTransform(sourceBounds: captureLocalBounds, targetBounds: overlayLocalBounds)
    }

    func overlayLocalPoint(fromOverlayGlobalPoint point: CGPoint) -> CGPoint {
        appKitOverlayTransform.localPoint(fromGlobalPoint: point)
    }

    func overlayGlobalPoint(fromOverlayLocalPoint point: CGPoint) -> CGPoint {
        appKitOverlayTransform.globalPoint(fromLocalPoint: point)
    }

    func captureLocalPoint(fromCaptureGlobalPoint point: CGPoint) -> CGPoint {
        captureScreenTransform.localPoint(fromGlobalPoint: point)
    }

    func captureGlobalPoint(fromCaptureLocalPoint point: CGPoint) -> CGPoint {
        captureScreenTransform.globalPoint(fromLocalPoint: point)
    }

    func captureLocalPoint(fromOverlayLocalPoint point: CGPoint) -> CGPoint {
        overlayToCaptureLocalTransform.targetPoint(fromSourcePoint: point)
    }

    func overlayLocalPoint(fromCaptureLocalPoint point: CGPoint) -> CGPoint {
        captureToOverlayLocalTransform.targetPoint(fromSourcePoint: point)
    }

    func overlayLocalPoint(fromCaptureGlobalPoint point: CGPoint) -> CGPoint {
        overlayLocalPoint(fromCaptureLocalPoint: captureLocalPoint(fromCaptureGlobalPoint: point))
    }

    func captureGlobalPoint(fromOverlayLocalPoint point: CGPoint) -> CGPoint {
        captureGlobalPoint(fromCaptureLocalPoint: captureLocalPoint(fromOverlayLocalPoint: point))
    }

    func captureGlobalPoint(fromOverlayGlobalPoint point: CGPoint) -> CGPoint {
        captureGlobalPoint(fromOverlayLocalPoint: overlayLocalPoint(fromOverlayGlobalPoint: point))
    }

    func overlayGlobalPoint(fromCaptureGlobalPoint point: CGPoint) -> CGPoint {
        overlayGlobalPoint(
            fromOverlayLocalPoint: overlayLocalPoint(
                fromCaptureGlobalPoint: point
            )
        )
    }

    func captureLocalRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        captureScreenTransform.localRect(fromGlobalRect: rect)
    }

    func captureGlobalRect(fromCaptureLocalRect rect: CGRect) -> CGRect {
        captureScreenTransform.globalRect(fromLocalRect: rect)
    }

    func captureLocalRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        overlayToCaptureLocalTransform.targetRect(fromSourceRect: rect)
    }

    func overlayLocalRect(fromCaptureLocalRect rect: CGRect) -> CGRect {
        captureToOverlayLocalTransform.targetRect(fromSourceRect: rect)
    }

    func captureGlobalRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        captureGlobalRect(fromCaptureLocalRect: captureLocalRect(fromOverlayLocalRect: rect))
    }

    func overlayLocalRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        overlayLocalRect(fromCaptureLocalRect: captureLocalRect(fromCaptureGlobalRect: rect))
    }

    func overlayGlobalRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized
        let minPoint = overlayGlobalPoint(fromCaptureGlobalPoint: CGPoint(x: normalized.minX, y: normalized.maxY))
        let maxPoint = overlayGlobalPoint(fromCaptureGlobalPoint: CGPoint(x: normalized.maxX, y: normalized.minY))
        return CGRect(
            x: min(minPoint.x, maxPoint.x),
            y: min(minPoint.y, maxPoint.y),
            width: abs(maxPoint.x - minPoint.x),
            height: abs(maxPoint.y - minPoint.y)
        ).gscIntegralStandardized
    }
}

/// Maps preview images captured for a display back to capture-space geometry.
nonisolated struct CapturePreviewTransform: Equatable {
    let displayTransform: CaptureDisplayTransform
    let previewPixelSize: CGSize

    init(displayTransform: CaptureDisplayTransform, previewPixelSize: CGSize) {
        self.displayTransform = displayTransform
        self.previewPixelSize = previewPixelSize
    }

    private var previewPixelBounds: CGRect {
        CGRect(origin: .zero, size: previewPixelSize)
    }

    private var captureLocalToPreviewTransform: TopLeftRectTransform {
        TopLeftRectTransform(
            sourceBounds: displayTransform.captureLocalBounds,
            targetBounds: previewPixelBounds
        )
    }

    func previewTopLeftPixelRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        captureLocalToPreviewTransform.targetRect(
            fromSourceRect: displayTransform.captureLocalRect(fromCaptureGlobalRect: rect)
        )
    }

    func previewTopLeftPixelRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        captureLocalToPreviewTransform.targetRect(
            fromSourceRect: displayTransform.captureLocalRect(fromOverlayLocalRect: rect)
        )
    }

    func appKitSourceRect(fromCaptureGlobalRect rect: CGRect) -> CGRect {
        appKitSourceRect(fromTopLeftPixelRect: previewTopLeftPixelRect(fromCaptureGlobalRect: rect))
    }

    func appKitSourceRect(fromOverlayLocalRect rect: CGRect) -> CGRect {
        appKitSourceRect(fromTopLeftPixelRect: previewTopLeftPixelRect(fromOverlayLocalRect: rect))
    }

    private func appKitSourceRect(fromTopLeftPixelRect rect: CGRect) -> CGRect {
        let normalized = rect.standardized.integral
        return CGRect(
            x: normalized.minX,
            y: previewPixelBounds.height - normalized.maxY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
    }
}


extension CGRect {
    nonisolated var gscIntegralStandardized: CGRect { standardized.integral }
    nonisolated func gscFiniteOr(_ fallback: CGRect) -> CGRect {
        [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite) ? standardized : fallback.standardized
    }
}
nonisolated func gscScaledPoint(_ point: CGPoint, from old: CGRect, to new: CGRect) -> CGPoint {
    guard old.width > 0, old.height > 0 else { return new.origin }
    return CGPoint(x: new.minX + (point.x-old.minX)/old.width*new.width, y: new.minY + (point.y-old.minY)/old.height*new.height)
}
nonisolated func gscScaledRect(_ rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
    let rect = rect.standardized
    let a = gscScaledPoint(rect.origin, from: old, to: new)
    let b = gscScaledPoint(CGPoint(x: rect.maxX, y: rect.maxY), from: old, to: new)
    return CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y)).integral
}
