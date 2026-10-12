import AppKit
import Foundation

// Export Prosio's actual SF Symbol resources for the code-based film UI.
// A fixed Aqua appearance avoids inheriting the desktop's current theme.
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: export-symbols <swift-source-root> <output-directory>") }
let source = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let pattern = try NSRegularExpression(pattern: #"\"([a-z][a-z0-9.]*)\""#)
var candidates: Set<String> = ["waveform", "checkmark", "xmark", "chevron.down", "chevron.left", "chevron.right", "arrow.up.right", "arrow.up", "pin", "pin.fill", "translate", "doc.on.doc", "square.and.arrow.down", "arrow.uturn.backward", "arrow.uturn.forward", "circle", "checkmark.circle.fill", "play.fill", "pause.fill", "stop.fill", "record.circle", "mic", "mic.slash", "video", "video.slash", "ellipsis", "rectangle", "rectangle.dashed", "macwindow", "display", "cpu", "paperplane.fill", "text.cursor"]
for case let url as URL in FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil)! {
    guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
    let ns = text as NSString
    for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        candidates.insert(ns.substring(with: match.range(at: 1)))
    }
}
var exported: [String] = []
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    for name in candidates.sorted() {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) else { continue }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        let fit = min(22 / max(symbol.size.width, 1), 22 / max(symbol.size.height, 1), 1)
        let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        symbol.draw(in: NSRect(x: (24-size.width)/2, y: (24-size.height)/2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try! data.write(to: output.appendingPathComponent(name + ".png"))
            exported.append(name)
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: ["source": "AppKit NSImage(systemSymbolName:) on macOS; symbols referenced in Prosio source", "names": exported], options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appendingPathComponent("manifest.json"))
print("Exported \(exported.count) native symbols")
