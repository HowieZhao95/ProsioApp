import CoreGraphics
import Foundation
import Testing

private actor CaptureTestPlatform: ScreenCapturePlatform {
    let content: ScreenContentSnapshot
    private(set) var requests: [ScreenCaptureRequest] = []
    init(content: ScreenContentSnapshot) { self.content = content }
    func shareableContent() async throws -> ScreenContentSnapshot { content }
    func captureScreenshot(_ request: ScreenCaptureRequest) async throws -> CGImage {
        requests.append(request)
        throw ScreenCapturePlatformError.imageUnavailable
    }
}

@Suite("Capture request planning")
@MainActor
struct CaptureServiceTests {
    private var displays: [DisplaySnapshot] {
        [DisplaySnapshot(displayID: 990001, name: "left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), overlayFrame: CGRect(x: -1920, y: -180, width: 1920, height: 1080), scale: 1),
         DisplaySnapshot(displayID: 990002, name: "primary", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)]
    }
    @Test("Single-display region uses display-local points and scaled output pixels")
    func regionRequest() throws {
        let service = ScreenCaptureService()
        let plan = try #require(service.directDisplayCaptureRequest(for: CGRect(x: -1800, y: 50, width: 400, height: 200), displays: displays))
        #expect(plan.displayID == 990001)
        #expect(plan.sourceRect.cgRect == CGRect(x: 120, y: 50, width: 400, height: 200))
        #expect(plan.outputSize == CGSize(width: 400, height: 200))
        let retina = try #require(service.directDisplayCaptureRequest(for: CGRect(x: 100, y: 50, width: 400, height: 200), displays: displays))
        #expect(retina.outputSize == CGSize(width: 800, height: 400))
    }
    @Test("Regions outside or across display edges are rejected without silently clipping")
    func regionBoundary() {
        let service = ScreenCaptureService()
        for rect in [CGRect(x: -10, y: 50, width: 20, height: 20), CGRect(x: 1400, y: 50, width: 100, height: 20), CGRect(x: 0, y: 0, width: 2, height: 20), CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            #expect(service.directDisplayCaptureRequest(for: rect, displays: displays) == nil)
        }
        #expect(service.directDisplayCaptureRequest(for: CGRect(x: 0, y: 0, width: 1440, height: 900), displays: displays)?.outputSize == CGSize(width: 2880, height: 1800))
    }
    @Test("Current display uses AppKit overlay coordinates rather than Quartz coordinates")
    func currentDisplay() {
        let service = ScreenCaptureService()
        #expect(service.currentDisplay(from: displays, preferredDisplayID: 990002, preferredPoint: CGPoint(x: -100, y: -100))?.displayID == 990001)
        #expect(service.currentDisplay(from: displays, preferredDisplayID: 990002, preferredPoint: nil)?.displayID == 990002)
        #expect(service.currentDisplay(from: [], preferredPoint: nil) == nil)
    }
    @Test("Disconnected display aborts before submitting screenshot request")
    func disconnectedDisplay() async {
        let platform = CaptureTestPlatform(content: ScreenContentSnapshot(displays: [], windows: [], applications: []))
        let service = ScreenCaptureService(platform: platform)
        do { _ = try await service.captureDisplay(displays[0]); Issue.record("Disconnected display unexpectedly captured") }
        catch { #expect(error is ScreenCaptureError) }
        #expect(await platform.requests.isEmpty)
    }
    @Test("Window targets do not switch to an unrelated reused window ID")
    func reusedWindowID() async {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let platform = CaptureTestPlatform(content: ScreenContentSnapshot(displays: displays, windows: [ScreenWindowSnapshot(id: 8, ownerName: "other", ownerPID: 200, bundleIdentifier: nil, title: "new", frame: frame, layer: 0, isOnScreen: true)], applications: []))
        let service = ScreenCaptureService(platform: platform)
        let chosen = CaptureWindowSummary(id: 8, ownerName: "chosen", ownerPID: 100, title: "old", frame: frame, layer: 0, focusRank: 0, thumbnail: nil)
        do { _ = try await service.captureWindow(chosen); Issue.record("Wrong window unexpectedly captured") }
        catch { #expect(error as? ScreenCapturePlatformError == .windowUnavailable) }
        #expect(await platform.requests.isEmpty)
    }
}

@Suite("Capture and voice hotkey ownership")
struct CaptureHotkeyRoutingTests {
    @Test("Voice Escape rejects capture IDs and leaves them to the capture handler")
    func captureDoesNotRouteToVoiceEscape() {
        #expect(!HotkeyRouting.isVoiceEscape(signature: HotkeyRouting.captureSignature, id: 1))
        #expect(HotkeyRouting.isCapture(signature: HotkeyRouting.captureSignature, id: 1))
        #expect(!HotkeyRouting.isCapture(signature: HotkeyRouting.voiceEscapeSignature, id: 1))
        #expect(HotkeyRouting.isVoiceEscape(signature: HotkeyRouting.voiceEscapeSignature, id: 1))
    }
    @Test("Neither handler claims an unknown ID or foreign signature")
    func unrelatedHotkeys() {
        for id: UInt32 in [0, 2, UInt32.max] {
            #expect(!HotkeyRouting.isVoiceEscape(signature: HotkeyRouting.voiceEscapeSignature, id: id))
            #expect(!HotkeyRouting.isCapture(signature: HotkeyRouting.captureSignature, id: id))
        }
        #expect(!HotkeyRouting.isVoiceEscape(signature: 0, id: 1))
        #expect(!HotkeyRouting.isCapture(signature: 0, id: 1))
    }
    @Test("A queued voice effect must recheck capture suspension before applying")
    func suspendedQueuedVoiceEffects() {
        #expect(HotkeyRouting.canApplyVoiceEffect(isStarted: true, isCaptureSuspended: false))
        #expect(!HotkeyRouting.canApplyVoiceEffect(isStarted: true, isCaptureSuspended: true))
        #expect(!HotkeyRouting.canApplyVoiceEffect(isStarted: false, isCaptureSuspended: false))
        #expect(!HotkeyRouting.canApplyVoiceEffect(isStarted: false, isCaptureSuspended: true))
    }
}
