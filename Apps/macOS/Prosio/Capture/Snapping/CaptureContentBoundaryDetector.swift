import CoreGraphics
import Foundation
import Vision

/// Optional, conservative image-only panel detection; not DOM or text recognition.
/// Run on a worker task. No permission requests, screen reads, or UI side effects occur here.
nonisolated enum CaptureContentBoundaryDetector {
    static let maximumInputEdge = 1536
    static let maximumCandidates = 20

    static func detect(image: CGImage, imageRect: CGRect, snapshotID: UUID,
                       isCancelled: @Sendable () -> Bool = { Task<Never, Never>.isCancelled }) throws -> [CaptureSnapCandidate] {
        if isCancelled() { throw CancellationError() }
        let imageRect = CaptureInteractionGeometry.valid(imageRect)
        guard imageRect.width > 0, imageRect.height > 0, image.width > 0, image.height > 0 else { return [] }
        guard let thumbnail = boundedImage(image) else { return [] }
        if isCancelled() { throw CancellationError() }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = maximumCandidates
        request.minimumConfidence = 0.86
        request.minimumSize = 0.06
        request.minimumAspectRatio = 0.08
        request.maximumAspectRatio = 1
        request.quadratureTolerance = 3
        try VNImageRequestHandler(cgImage: thumbnail, orientation: .up).perform([request])
        if isCancelled() { throw CancellationError() }
        var accepted: [CaptureSnapCandidate] = []
        for observation in (request.results ?? []).sorted(by: { $0.confidence > $1.confidence }) {
            // Reject perspective/skewed shapes rather than snapping to their bounding-box corners.
            let tolerance: CGFloat = 0.008
            guard abs(observation.topLeft.y - observation.topRight.y) <= tolerance,
                  abs(observation.bottomLeft.y - observation.bottomRight.y) <= tolerance,
                  abs(observation.topLeft.x - observation.bottomLeft.x) <= tolerance,
                  abs(observation.topRight.x - observation.bottomRight.x) <= tolerance else { continue }
            let normalized = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { continue }
            let rect = topLeftRect(fromNormalizedVisionRect: normalized, imageRect: imageRect)
            // Keep ordinary visible panels/cards while rejecting noisy tiny rectangles.
            let areaRatio = normalized.width * normalized.height
            guard areaRatio >= 0.006, areaRatio <= 0.90,
                  rect.width >= 48, rect.height >= 32,
                  !accepted.contains(where: { intersectionOverUnion($0.rect, rect) > 0.90 }) else { continue }
            accepted.append(CaptureSnapCandidate(id: "content-panel-\(accepted.count)", source: .contentBlock,
                rect: rect, confidence: CGFloat(observation.confidence), snapshotID: snapshotID, priority: 100 + accepted.count))
        }
        if isCancelled() { throw CancellationError() }
        return accepted
    }

    /// Vision normalized coordinates are bottom-left; the interaction space is top-left.
    static func topLeftRect(fromNormalizedVisionRect normalized: CGRect, imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + normalized.minX * imageRect.width,
               y: imageRect.minY + (1 - normalized.maxY) * imageRect.height,
               width: normalized.width * imageRect.width, height: normalized.height * imageRect.height)
    }

    private static func boundedImage(_ image: CGImage) -> CGImage? {
        let scale = min(1, CGFloat(maximumInputEdge) / CGFloat(max(image.width, image.height)))
        if scale == 1 { return image }
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let area = overlap.width * overlap.height
        let union = a.width * a.height + b.width * b.height - area
        return union > 0 ? area / union : 0
    }
}
