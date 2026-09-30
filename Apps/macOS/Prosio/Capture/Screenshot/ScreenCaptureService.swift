// Adapted from SnipSnipSnip Capture/ScreenCaptureService.swift at
// 7919eac9df9d9dec8427dbc0c10aecd32baf5530; MIT, see third-party notices.
import AppKit
import CoreGraphics
import Foundation

nonisolated enum ScreenCaptureError: LocalizedError {
    case permissionDenied, noDisplays, noWindowsAvailable, currentDisplayUnavailable, invalidRegion, regionSpansMultipleDisplays
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording access is required for screenshots."
        case .noDisplays: "No active displays were found."
        case .noWindowsAvailable: "No shareable windows are available."
        case .currentDisplayUnavailable: "The selected display is no longer available."
        case .invalidRegion: "Choose an area at least 3 points wide and tall."
        case .regionSpansMultipleDisplays: "Keep the selected area within one display."
        }
    }
}

nonisolated struct DirectDisplayCaptureRequest: Equatable {
    let displayID: CGDirectDisplayID
    let sourceRect: DisplayLocalRect
    let outputSize: CGSize
}

@MainActor
struct ScreenCaptureService {
    let platform: any ScreenCapturePlatform
    init(platform: any ScreenCapturePlatform = LiveScreenCapturePlatform()) { self.platform = platform }

    func displays() async throws -> [DisplaySnapshot] {
        let content = try await platform.shareableContent()
        return content.displays.map { display in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
            return DisplaySnapshot(displayID: display.displayID, name: screen?.localizedName ?? display.name,
                                   frame: display.frame, overlayFrame: screen?.frame ?? display.overlayFrame,
                                   scale: screen?.backingScaleFactor ?? display.scale)
        }
    }

    func listWindows(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> [CaptureWindowSummary] {
        let content = try await platform.shareableContent()
        let windows = content.windows.filter { $0.ownerPID != processID && $0.layer == 0 && $0.isOnScreen && $0.frame.width >= 60 && $0.frame.height >= 40 }
        return windows.map { CaptureWindowSummary(id: $0.id, ownerName: $0.ownerName, ownerPID: $0.ownerPID, title: $0.title, frame: $0.frame, layer: $0.layer, focusRank: 0, thumbnail: nil) }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    nonisolated func directDisplayCaptureRequest(for region: CGRect, displays: [DisplaySnapshot]) -> DirectDisplayCaptureRequest? {
        guard [region.origin.x, region.origin.y, region.width, region.height].allSatisfy(\.isFinite) else { return nil }
        let rect = region.gscIntegralStandardized
        guard rect.width > 2, rect.height > 2,
              let display = displays.first(where: { $0.frame.contains(rect) }) else { return nil }
        return DirectDisplayCaptureRequest(displayID: display.displayID,
            sourceRect: CaptureScreenTransform(captureFrame: display.frame).localRect(fromGlobalRect: CaptureGlobalRect(rect)),
            outputSize: CGSize(width: rect.width * display.scale, height: rect.height * display.scale))
    }

    nonisolated func currentDisplay(from displays: [DisplaySnapshot], preferredDisplayID: CGDirectDisplayID? = nil, preferredPoint: CGPoint?) -> DisplaySnapshot? {
        if let preferredPoint, let match = displays.first(where: { $0.overlayFrame.contains(preferredPoint) }) { return match }
        if let preferredDisplayID, let match = displays.first(where: { $0.displayID == preferredDisplayID }) { return match }
        return displays.first
    }

    func captureDisplay(_ display: DisplaySnapshot) async throws -> CapturedScreenshot {
        let current = try await displays()
        guard let resolved = current.first(where: { $0.displayID == display.displayID }) else { throw ScreenCaptureError.currentDisplayUnavailable }
        let image = try await platform.captureScreenshot(ScreenCaptureRequest(target: .display(resolved.displayID, excludingProcessID: ProcessInfo.processInfo.processIdentifier),
            configuration: ScreenCaptureConfiguration(width: Int((resolved.frame.width * resolved.scale).rounded(.up)), height: Int((resolved.frame.height * resolved.scale).rounded(.up)))))
        return CapturedScreenshot(image: image, kind: .fullscreen, sourceName: resolved.name, sourceRect: resolved.frame, capturedAt: .now)
    }

    func captureRegion(in selection: CGRect, displays: [DisplaySnapshot]) async throws -> CapturedScreenshot {
        guard let plan = directDisplayCaptureRequest(for: selection, displays: displays) else { throw ScreenCaptureError.regionSpansMultipleDisplays }
        let current = try await self.displays()
        guard let display = current.first(where: { $0.displayID == plan.displayID }), display.frame == displays.first(where: { $0.displayID == plan.displayID })?.frame else { throw ScreenCaptureError.currentDisplayUnavailable }
        let image = try await platform.captureScreenshot(ScreenCaptureRequest(target: .display(plan.displayID, excludingProcessID: ProcessInfo.processInfo.processIdentifier),
            configuration: ScreenCaptureConfiguration(width: Int(plan.outputSize.width.rounded(.up)), height: Int(plan.outputSize.height.rounded(.up)), sourceRect: plan.sourceRect.cgRect, ignoreShadows: true, ignoreClipping: true)))
        return CapturedScreenshot(image: image, kind: .region, sourceName: display.name, sourceRect: selection.gscIntegralStandardized, capturedAt: .now)
    }

    func captureWindow(_ window: CaptureWindowSummary) async throws -> CapturedScreenshot {
        let content = try await platform.shareableContent()
        guard let source = content.windows.first(where: { $0.id == window.id && $0.ownerPID == window.ownerPID }) else { throw ScreenCapturePlatformError.windowUnavailable }
        let displays = try await self.displays()
        let scale = gscDisplayScale(forCaptureFrame: source.frame, displays: displays, fallbackScale: 1)
        let image = try await platform.captureScreenshot(ScreenCaptureRequest(target: .window(source.id), configuration: ScreenCaptureConfiguration(width: Int((source.frame.width * scale).rounded(.up)), height: Int((source.frame.height * scale).rounded(.up)), ignoreShadows: true, ignoreClipping: true)))
        return CapturedScreenshot(image: image, kind: .window, sourceName: window.displayTitle, sourceRect: source.frame, capturedAt: .now)
    }
}
