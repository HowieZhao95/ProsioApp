import AppKit
import Testing

@Suite("Live recording desktop selection")
struct RecordingDesktopSelectionTests {
    @Test func displayMappingUsesBothScreenFramesWithoutApplyingRetinaPixelsTwice() throws {
        let display = RecordingDisplayChoice(id: 7, name: "左侧 Retina", frame: CGRect(x: -1600, y: -100, width: 1600, height: 1000), width: 3200, height: 2000)
        let appKitFrame = CGRect(x: -1280, y: -140, width: 1280, height: 800)
        let transform = CaptureDisplayTransform(captureFrame: display.frame, overlayFrame: appKitFrame)
        let mouse = CGPoint(x: -1200, y: 620)
        #expect(transform.overlayLocalPoint(fromOverlayGlobalPoint: mouse) == CGPoint(x: 80, y: 40))
        #expect(transform.captureGlobalPoint(fromOverlayGlobalPoint: mouse) == CGPoint(x: -1500, y: -50))
        let target = try #require(RecordingDesktopSelectionGeometry.region(CGRect(x: 80, y: 40, width: 400, height: 200), display: display, screenFrame: appKitFrame))
        #expect(target == .region(displayID: 7, rect: RecordingRegion(x: 100, y: 50, width: 500, height: 250)))
        // Region coordinates are top-left local screen points, independent of the display's negative global origin.
        let clipped = try #require(RecordingDesktopSelectionGeometry.region(CGRect(x: -20, y: 750, width: 100, height: 100), display: display, screenFrame: appKitFrame))
        #expect(clipped == .region(displayID: 7, rect: RecordingRegion(x: 0, y: 937, width: 100, height: 63)))
        #expect(RecordingDesktopSelectionGeometry.region(CGRect(x: 0, y: 0, width: 15, height: 100), display: display, screenFrame: appKitFrame) == nil)
        #expect(RecordingDesktopSelectionGeometry.region(CGRect(x: 2000, y: 0, width: 100, height: 100), display: display, screenFrame: appKitFrame) == nil)
    }

    @Test func windowHitUsesLiveFrontOrderAndExcludesApplicationChrome() throws {
        let back = RecordingWindowChoice(id: 1, name: "A 前字母但后层窗口", frame: CGRect(x: -900, y: 40, width: 600, height: 500), width: 600, height: 500)
        let front = RecordingWindowChoice(id: 2, name: "Z 前层窗口", frame: back.frame, width: 600, height: 500)
        let own = RecordingWindowChoice(id: 3, name: "摄像头预览", frame: back.frame, width: 600, height: 500)
        let rows = [
            RecordingDesktopWindowHit(id: 3, frame: back.frame, ownerPID: 99, layer: 0, alpha: 1),
            RecordingDesktopWindowHit(id: 2, frame: CGRect(x: -850, y: 50, width: 400, height: 300), ownerPID: 20, layer: 0, alpha: 1),
            RecordingDesktopWindowHit(id: 1, frame: back.frame, ownerPID: 10, layer: 0, alpha: 1)
        ]
        let available = [back, front, own]
        #expect(RecordingDesktopSelectionGeometry.window(at: CGPoint(x: -800, y: 100), frontToBack: rows, available: available, excludingPID: 99)?.id == 2)
        #expect(RecordingDesktopSelectionGeometry.window(at: CGPoint(x: -800, y: 100), frontToBack: rows, available: available, excludingIDs: [2], excludingPID: 99)?.id == 1)
        #expect(RecordingDesktopSelectionGeometry.window(at: CGPoint(x: -350, y: 100), frontToBack: rows, available: available, excludingPID: 99)?.id == 1)
        #expect(RecordingDesktopSelectionGeometry.window(at: CGPoint(x: 0, y: 0), frontToBack: rows, available: available, excludingPID: 99) == nil)
        #expect(RecordingDesktopSelectionGeometry.window(at: CGPoint(x: -800, y: 100), frontToBack: rows, available: [back], excludingPID: 99)?.id == 1)
    }

    @Test func selectionLockAndControlHoverPreserveTheChosenTarget() {
        var state = RecordingDesktopSelectionState()
        state.hover(.window(8))
        state.hover(nil, overControls: true)
        #expect(state.target == .window(8))
        state.lock()
        state.hover(.display(2))
        state.hover(nil)
        #expect(state.target == .window(8))
        #expect(state.locked)
        state.reset()
        state.hover(.display(2))
        #expect(state.target == .display(2))
        #expect(!state.locked)
        state.hover(nil)
        state.lock()
        #expect(state.target == nil)
        #expect(!state.locked)
        state.selectRegion(.region(displayID: 2, rect: RecordingRegion(x: 0, y: 0, width: 100, height: 80)))
        #expect(state.locked)
        state.selectRegion(nil)
        #expect(state.target == nil)
        #expect(!state.locked)
    }

    @Test func freshClickRetargetsWhileHoverAndControlsRespectTheLock() {
        var state = RecordingDesktopSelectionState()
        state.click(.window(8))
        state.hover(.window(9))
        #expect(state.target == .window(8))
        state.click(.window(9))
        #expect(state.target == .window(9))
        #expect(state.locked)
        state.hover(nil, overControls: true)
        #expect(state.target == .window(9))
        state.click(.display(2))
        #expect(state.target == .display(2))
        #expect(state.locked)
        state.click(nil)
        #expect(state.target == nil)
        #expect(!state.locked)
        state.hover(.window(10))
        #expect(state.target == .window(10))
    }

    @Test func regionMoveAndAllEightResizeHandlesStayOnTheirOriginalScreen() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let rect = CGRect(x: 100, y: 150, width: 400, height: 300)
        let moved = CaptureInteractionGeometry.move(rect, translation: CGSize(width: -500, height: 900), within: viewport,
                                                    minimumSize: RecordingDesktopSelectionGeometry.minimumRegionSize)
        #expect(moved == CGRect(x: 0, y: 500, width: 400, height: 300))
        for handle in CaptureResizeHandle.allCases {
            #expect(RecordingDesktopSelectionGeometry.handle(at: handle.position(in: rect), in: rect) == handle)
            let resized = CaptureInteractionGeometry.resize(rect, handle: handle, translation: CGSize(width: 9000, height: -9000), within: viewport,
                                                             minimumSize: RecordingDesktopSelectionGeometry.minimumRegionSize)
            #expect(viewport.contains(resized))
            #expect(resized.width >= 16 && resized.height >= 16)
            if !handle.movesMinX { #expect(resized.minX == rect.minX) }
            if !handle.movesMaxX { #expect(resized.maxX == rect.maxX) }
            if !handle.movesMinY { #expect(resized.minY == rect.minY) }
            if !handle.movesMaxY { #expect(resized.maxY == rect.maxY) }
        }
        #expect(RecordingDesktopSelectionGeometry.handle(at: CGPoint(x: rect.midX, y: rect.midY), in: rect) == nil)
        let display = RecordingDisplayChoice(id: 9, name: "上方屏幕", frame: CGRect(x: 0, y: -800, width: 1280, height: 800), width: 2560, height: 1600)
        let target = try #require(RecordingDesktopSelectionGeometry.region(moved, display: display, screenFrame: CGRect(x: 0, y: 900, width: 1280, height: 800)))
        #expect(target == .region(displayID: 9, rect: RecordingRegion(x: 0, y: 500, width: 400, height: 300)))
    }
}
