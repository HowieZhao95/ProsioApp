// Adapted from SnipSnipSnip, commit 7919eac9df9d9dec8427dbc0c10aecd32baf5530.
// Copyright (c) 2026 Oontz. MIT; see THIRD_PARTY_LICENSES/SnipSnipSnip-LICENSE.
import CoreGraphics
import Foundation

nonisolated struct CaptureWindowSummary: Identifiable, Hashable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let focusRank: Int
    let thumbnail: CGImage?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ownerName : "\(ownerName) - \(trimmed)"
    }

    static func == (lhs: CaptureWindowSummary, rhs: CaptureWindowSummary) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated enum RegionCaptureSelection {
    case region(CGRect, cursorCaptureGlobalLocation: CGPoint?)
    case window(CaptureWindowSummary)
}

nonisolated struct DisplaySnapshot: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let name: String
    // ScreenCaptureKit display-space frame used for screenshot capture and crop math.
    let frame: CGRect
    // AppKit screen-space frame used only for positioning overlay windows.
    let overlayFrame: CGRect
    let scale: CGFloat

    init(displayID: CGDirectDisplayID, name: String, frame: CGRect, overlayFrame: CGRect? = nil, scale: CGFloat) {
        let sanitizedFrame = frame.gscFiniteOr(.zero)
        let sanitizedOverlayFrame = (overlayFrame ?? sanitizedFrame).gscFiniteOr(sanitizedFrame)

        self.displayID = displayID
        self.name = name
        self.frame = sanitizedFrame
        self.overlayFrame = sanitizedOverlayFrame
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}

nonisolated func gscDisplayScale(
    forCaptureFrame frame: CGRect,
    displays: [DisplaySnapshot],
    fallbackScale: CGFloat
) -> CGFloat {
    let intersectingScales = displays.compactMap { display -> CGFloat? in
        display.frame.intersects(frame) ? display.scale : nil
    }

    return max(intersectingScales.max() ?? fallbackScale, 1)
}

nonisolated struct DisplayPreview {
    let snapshot: DisplaySnapshot
    let image: CGImage
}

nonisolated struct DesktopCompositeSnapshot {
    let previewImage: CGImage?
    let globalFrame: CGRect
    let displays: [DisplaySnapshot]
    let displayPreviews: [DisplayPreview]
}


nonisolated enum CaptureKind: String, Codable, Sendable { case region, window, fullscreen }
nonisolated struct CapturedScreenshot: @unchecked Sendable {
    let image: CGImage
    let kind: CaptureKind
    let sourceName: String
    let sourceRect: CGRect
    let capturedAt: Date
}
