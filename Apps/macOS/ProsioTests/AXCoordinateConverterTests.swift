import Testing
import CoreGraphics
// AXCoordinateConverter is compiled directly into this target (see project.yml) — no import needed.

@Suite("AXCoordinateConverter")
struct AXCoordinateConverterTests {
    @Test("Flips an AX top-left-origin rect into AppKit bottom-left-origin space")
    func flipsOrigin() {
        // Primary screen 1440x900; AX caret rect 100x30 at (10, 20) from the top.
        let axRect = CGRect(x: 10, y: 20, width: 100, height: 30)

        let result = AXCoordinateConverter.appKitRect(fromAXRect: axRect, primaryScreenHeight: 900)

        // AppKit y = screenHeight - axY - height = 900 - 20 - 30 = 850
        #expect(result == CGRect(x: 10, y: 850, width: 100, height: 30))
    }

    @Test("A rect flush with the top edge in AX space lands near the top in AppKit space")
    func topEdgeMapsNearTopOfAppKitSpace() {
        let axRect = CGRect(x: 0, y: 0, width: 50, height: 40)

        let result = AXCoordinateConverter.appKitRect(fromAXRect: axRect, primaryScreenHeight: 800)

        #expect(result == CGRect(x: 0, y: 760, width: 50, height: 40))
    }

    @Test("A rect flush with the bottom edge in AX space maps to y = 0 in AppKit space")
    func bottomEdgeMapsToZero() {
        let axRect = CGRect(x: 0, y: 760, width: 50, height: 40)

        let result = AXCoordinateConverter.appKitRect(fromAXRect: axRect, primaryScreenHeight: 800)

        #expect(result.origin.y == 0)
    }

    @Test("Round-tripping the flip twice with the same height returns the original rect")
    func roundTripIsIdentity() {
        let original = CGRect(x: 42, y: 73, width: 120, height: 22)
        let height: CGFloat = 1080

        let flipped = AXCoordinateConverter.appKitRect(fromAXRect: original, primaryScreenHeight: height)
        let flippedBack = AXCoordinateConverter.appKitRect(fromAXRect: flipped, primaryScreenHeight: height)

        #expect(flippedBack == original)
    }
}
