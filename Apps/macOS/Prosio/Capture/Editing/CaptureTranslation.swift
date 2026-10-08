import CoreGraphics
import CoreText
import Foundation
import Vision

nonisolated struct CaptureTextRegion: Sendable {
    let text: String
    let rect: CGRect
    let background: RGBAColor
    let foreground: RGBAColor
    var fontName = "Helvetica"
    var fontSize: CGFloat? = nil
}

/// A small local template comparison preserves common family/weight styles without another model call.
nonisolated enum CaptureTranslationTypography {
    static func color(_ rgba: RGBAColor) -> CGColor {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: space, components: [rgba.red, rgba.green, rgba.blue, rgba.alpha]) else { return rgba.cgColor }
        return color
    }
    static func line(_ text: String, name: String, size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(name as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
    }

    static func match(text: String, image: CGImage, rect: CGRect, background: RGBAColor) -> (name: String, size: CGFloat) {
        var budget = 96
        return match(text: text, image: image, rect: rect, background: background, templateBudget: &budget)
    }

    static func match(text: String, image: CGImage, rect: CGRect, background: RGBAColor, templateBudget: inout Int) -> (name: String, size: CGFloat) {
        let box = rect.insetBy(dx: 2, dy: 2)
        let observed = mask(image: image, rect: box, background: background)
        let ink = observed?.bounds ?? box
        let hasCJK = text.unicodeScalars.contains { $0.value >= 0x2e80 && $0.value <= 0x9fff }
        let names = hasCJK ? ["PingFangSC-Regular", "PingFangSC-Semibold", "SongtiSC-Regular", "SongtiSC-Bold"]
            : ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Menlo-Regular", "Menlo-Bold", "TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT", "TimesNewRomanPS-ItalicMT"]
        let candidates = names.map { name -> (String, CTLine, CGRect, CGFloat) in
            let line = line(text, name: name, size: 100)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let aspect = abs(log((max(bounds.width, 1) / max(bounds.height, 1)) / (max(ink.width, 1) / max(ink.height, 1))))
            return (name, line, bounds, aspect)
        }.sorted { $0.3 < $1.3 }
        var name = candidates[0].0, best = CGFloat.infinity
        // Long OCR lines and tiny labels do not justify glyph-template work.
        if templateBudget > 0, text.count <= 120, ink.width >= 12, ink.height >= 7, let actual = observed?.pixels {
            for (candidate, template, bounds, aspect) in candidates.prefix(min(4, templateBudget)) {
                templateBudget -= 1
                guard bounds.width > 0, bounds.height > 0, let expected = mask(line: template, bounds: bounds) else { continue }
                let error = zip(actual, expected).reduce(CGFloat.zero) { $0 + abs($1.0 - $1.1) } / CGFloat(actual.count)
                let score = error + min(aspect, 1) * 0.12
                if score < best { best = score; name = candidate }
            }
        }
        let bounds = CTLineGetBoundsWithOptions(line(text, name: name, size: 100), .useGlyphPathBounds)
        let size = max(1, min(ink.height * 2, ink.height * 100 / max(bounds.height, 1)))
        return (name, size)
    }

    private static func context(height: Int = 32) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: 128, height: height, bitsPerComponent: 8, bytesPerRow: 512,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }
    private static func mask(image: CGImage, rect: CGRect, background: RGBAColor) -> (pixels: [CGFloat], bounds: CGRect)? {
        guard let cropped = image.cropping(to: rect), let context = context(height: 64) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 128, height: 64))
        guard let values = pixels(context, background: background) else { return nil }
        var left = 128, right = 0, bottom = 64, top = 0
        for y in 0..<64 { for x in 0..<128 where values[y * 128 + x] > 0.18 {
            left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y)
        } }
        guard right > left, top > bottom else { return nil }
        let width = right - left + 1, height = top - bottom + 1
        let normalized = (0..<4096).map { pixel -> CGFloat in
            let x = CGFloat(left) + (CGFloat(pixel % 128) + 0.5) * CGFloat(width) / 128 - 0.5
            let y = CGFloat(bottom) + (CGFloat(pixel / 128) + 0.5) * CGFloat(height) / 32 - 0.5
            let x0 = max(left, min(right, Int(floor(x)))), y0 = max(bottom, min(top, Int(floor(y))))
            let x1 = min(right, x0 + 1), y1 = min(top, y0 + 1)
            let dx = max(0, min(1, x - CGFloat(x0))), dy = max(0, min(1, y - CGFloat(y0)))
            return (values[y0 * 128 + x0] * (1 - dx) + values[y0 * 128 + x1] * dx) * (1 - dy)
                + (values[y1 * 128 + x0] * (1 - dx) + values[y1 * 128 + x1] * dx) * dy
        }
        return (normalized, CGRect(x: 0, y: 0, width: rect.width * CGFloat(width) / 128, height: rect.height * CGFloat(height) / 64))
    }
    private static func mask(line: CTLine, bounds: CGRect) -> [CGFloat]? {
        guard let context = context() else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 32))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.scaleBy(x: 128 / bounds.width, y: 32 / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.textPosition = .zero
        CTLineDraw(line, context)
        return pixels(context, background: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
    }
    private static func pixels(_ context: CGContext, background: RGBAColor) -> [CGFloat]? {
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (0..<(context.width * context.height)).map { pixel in
            let index = pixel * 4
            return min(1, max(abs(CGFloat(bytes[index]) / 255 - background.red),
                abs(CGFloat(bytes[index + 1]) / 255 - background.green), abs(CGFloat(bytes[index + 2]) / 255 - background.blue)) * 1.4)
        }
    }
}

/// Translation uses ink bounds rather than full font ascent/descent, avoiding needless shrinkage.
nonisolated enum CaptureTranslationTextLayout {
    struct Layout {
        let lines: [CTLine]
        let bounds: [CGRect]
        let advance: CGFloat
        let height: CGFloat
    }
    static func layout(text: String, fontName: String, size: CGFloat, width: CGFloat) -> Layout? {
        guard width > 0, !text.isEmpty else { return nil }
        let font = CTFontCreateWithName(fontName as CFString, max(size, 1), nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let setter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = [], bounds: [CGRect] = [], offset = 0
        while offset < attributed.length {
            guard lines.count < 64 else { return nil }
            let count = CTTypesetterSuggestLineBreak(setter, offset, Double(width))
            guard count > 0 else { return nil }
            let line = CTTypesetterCreateLine(setter, CFRange(location: offset, length: count))
            var box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if box.isNull || box.height == 0 { box = CGRect(x: 0, y: -CTFontGetDescent(font), width: 0, height: size) }
            guard box.width <= width + 0.5 else { return nil }
            lines.append(line); bounds.append(box); offset += count
        }
        let advance = max(size * 1.15, (bounds.map(\.height).max() ?? size) + 2)
        let height = bounds.enumerated().map { CGFloat($0.offset) * advance + bounds[0].maxY - $0.element.minY }.max() ?? 0
        return Layout(lines: lines, bounds: bounds, advance: advance, height: height)
    }

    static func availableRect(for rect: CGRect, crop: CGRect, obstacles: [CGRect], preferredSize: CGFloat) -> CGRect {
        var right = crop.maxX
        for other in obstacles where other != rect && other.maxY > rect.minY && other.minY < rect.maxY {
            if other.minX >= rect.maxX { right = min(right, other.minX - 2) }
        }
        var bottom = min(crop.maxY, rect.minY + max(rect.height, preferredSize * 4.8 + 4))
        for other in obstacles where other != rect && other.maxX > rect.minX && other.minX < right {
            if other.minY >= rect.maxY { bottom = min(bottom, other.minY - 2) }
        }
        return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, right - rect.minX), height: max(rect.height, bottom - rect.minY))
    }

    static func fit(text: String, fontName: String, preferredSize: CGFloat, original: CGRect, available: CGRect) -> (size: CGFloat, rect: CGRect) {
        let preferred = max(1, preferredSize)
        if let layout = layout(text: text, fontName: fontName, size: preferred, width: original.width - 4), layout.height <= original.height - 4 {
            return (preferred, original)
        }
        let line = CaptureTranslationTypography.line(text, name: fontName, size: preferred)
        let naturalWidth = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width + 4
        let width = min(available.width, max(original.width, naturalWidth))
        var low: CGFloat = 1, high = preferred
        if let layout = layout(text: text, fontName: fontName, size: preferred, width: width - 4), layout.height <= available.height - 4 {
            return (preferred, CGRect(x: original.minX, y: original.minY, width: width, height: max(original.height, layout.height + 4)))
        }
        for _ in 0..<10 {
            let size = (low + high) / 2
            if let layout = layout(text: text, fontName: fontName, size: size, width: width - 4), layout.height <= available.height - 4 { low = size }
            else { high = size }
        }
        let height = layout(text: text, fontName: fontName, size: low, width: width - 4)?.height ?? original.height - 4
        return (low, CGRect(x: original.minX, y: original.minY, width: width, height: min(available.height, max(original.height, height + 4))))
    }

    static func draw(_ shape: TextShape, style: AnnotationStyle, context: CGContext) {
        guard let fontName = shape.fontName, let layout = layout(text: shape.text, fontName: fontName, size: style.fontSize, width: shape.rect.width - 4) else { return }
        context.textMatrix = .identity
        context.setFillColor(CaptureTranslationTypography.color(style.strokeColor))
        for (index, line) in layout.lines.enumerated() {
            context.textPosition = CGPoint(x: 2 - layout.bounds[index].minX,
                y: shape.rect.height - 2 - layout.bounds[0].maxY - CGFloat(index) * layout.advance)
            CTLineDraw(line, context)
        }
    }
}

nonisolated enum CaptureTranslationError: LocalizedError {
    case unavailable, noText, tooMuchText, invalidResponse, insufficientSpace
    var errorDescription: String? {
        switch self {
        case .unavailable: "请先登录，再使用截图翻译。"
        case .noText: "选区内没有识别到可翻译的文字。"
        case .tooMuchText: "选区文字过多，请缩小选区后翻译。"
        case .invalidResponse: "翻译结果不完整，请重试。"
        case .insufficientSpace: "选区内空间不足，无法完整显示译文，请扩大选区后重试。"
        }
    }
}

/// Session-scoped caches: recognition and translation caches never persist to disk.
actor CaptureTranslationPipeline {
    typealias Translate = @Sendable ([String], String) async throws -> [String]
    typealias Recognize = @Sendable (EditableCaptureDocument) async throws -> [CaptureTextRegion]
    private let translate: Translate
    private let recognize: Recognize
    private var recognized: (id: UUID, snapshot: EditorSnapshot, regions: [CaptureTextRegion])?
    private var translations: [String: String] = [:]
    private var lastOverlays: (id: UUID, snapshot: EditorSnapshot, target: String, annotations: [Annotation])?

    init(translate: @escaping Translate, recognize: @escaping Recognize = CaptureTranslationOCR.recognize) {
        self.translate = translate
        self.recognize = recognize
    }

    func overlays(document: EditableCaptureDocument, sourceID: UUID, target: String) async throws -> [Annotation] {
        var snapshot = document.snapshot
        snapshot.annotations.removeAll { $0.isTranslation }
        snapshot.selectedAnnotationIDs = []
        try Task.checkCancellation()
        if let cached = lastOverlays, cached.id == sourceID, cached.snapshot == snapshot, cached.target == target {
            return cached.annotations
        }
        let regions: [CaptureTextRegion]
        if let cached = recognized, cached.id == sourceID, cached.snapshot == snapshot { regions = cached.regions }
        else {
            let visible = EditableCaptureDocument(baseImage: document.baseImage, snapshot: snapshot,
                kind: document.kind, sourceName: document.sourceName, sourceRect: document.sourceRect, capturedAt: document.capturedAt)
            regions = try await recognize(visible)
            try Task.checkCancellation()
            recognized = (sourceID, snapshot, regions)
        }
        guard !regions.isEmpty else { throw CaptureTranslationError.noText }
        guard regions.count <= 200, regions.allSatisfy({ $0.text.utf16.count <= 3500 }),
            regions.reduce(0, { $0 + $1.text.utf16.count }) <= 16000 else { throw CaptureTranslationError.tooMuchText }
        var seen = Set<String>()
        let missing = regions.map(\.text).filter { translations[target + "\u{0}" + $0] == nil && seen.insert($0).inserted }
        let batches = Self.batches(missing)
        // At most two HTTP requests at once, regardless of how dense a screenshot is.
        for start in stride(from: 0, to: batches.count, by: 2) {
            try Task.checkCancellation()
            let translator = translate
            let results = try await withThrowingTaskGroup(of: ([String], [String]).self) { group in
                for batch in batches[start..<min(start + 2, batches.count)] {
                    group.addTask { (batch, try await translator(batch, target)) }
                }
                var result: [([String], [String])] = []
                for try await batch in group { result.append(batch) }
                return result
            }
            try Task.checkCancellation()
            for (input, output) in results {
                guard input.count == output.count, output.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4000 }) else {
                    throw CaptureTranslationError.invalidResponse
                }
                for (source, text) in zip(input, output) { translations[target + "\u{0}" + source] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        let obstacles = regions.map(\.rect) + snapshot.annotations.map(\.boundingRect)
        let result = try regions.compactMap { region -> Annotation? in
            guard let text = translations[target + "\u{0}" + region.text], text != region.text else { return nil }
            let preferred = region.fontSize ?? max(1, region.rect.height - 4)
            let available = CaptureTranslationTextLayout.availableRect(for: region.rect, crop: snapshot.cropRect, obstacles: obstacles, preferredSize: preferred)
            let fitted = CaptureTranslationTextLayout.fit(text: text, fontName: region.fontName, preferredSize: preferred, original: region.rect, available: available)
            guard let layout = CaptureTranslationTextLayout.layout(text: text, fontName: region.fontName, size: fitted.size, width: fitted.rect.width - 4),
                layout.height <= fitted.rect.height - 4 + 0.5 else { throw CaptureTranslationError.insufficientSpace }
            return Annotation(kind: .text(TextShape(rect: fitted.rect, text: text, automaticallySizesToText: false, translationSource: region.text,
                fontName: region.fontName, translationSourceRect: region.rect)),
                style: AnnotationStyle(strokeColor: region.foreground, fillColor: region.background, lineWidth: 0, fontSize: fitted.size))
        }
        if translations.count > 512 || translations.reduce(0, { $0 + $1.key.count + $1.value.count }) > 100000 { translations.removeAll(keepingCapacity: true) }
        lastOverlays = (sourceID, snapshot, target, result)
        return result
    }

    nonisolated static func batches(_ texts: [String]) -> [[String]] {
        var result: [[String]] = [], current: [String] = []
        var characters = 0
        for text in texts {
            if !current.isEmpty && (current.count == 40 || characters + text.utf16.count > 3500) {
                result.append(current); current = []; characters = 0
            }
            current.append(text); characters += text.utf16.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

nonisolated enum CaptureTranslationOCR {
    // Vision exposes cancel() for an in-flight request. Everything else is worker-owned.
    private final class Work: @unchecked Sendable {
        let request = VNRecognizeTextRequest()
    }
    static func recognize(_ document: EditableCaptureDocument) async throws -> [CaptureTextRegion] {
        let work = Work()
        let worker = Task.detached(priority: .userInitiated) { try recognizeSynchronously(document, request: work.request) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: {
            worker.cancel(); work.request.cancel()
        }
    }

    static func recognizeSynchronously(_ document: EditableCaptureDocument, request: VNRecognizeTextRequest) throws -> [CaptureTextRegion] {
        try Task.checkCancellation()
        // Render only selected, visible pixels. Redacted text must never reach the translator.
        let image = document.snapshot.annotations.isEmpty
            ? document.baseImage.cropping(to: document.snapshot.cropRect.integral)
            : try EditorRenderer.render(baseImage: document.baseImage, snapshot: document.snapshot)
        guard let image else { throw EditorRenderError.invalidCrop }
        let recognitionImage = try scaledForRecognition(image)
        try Task.checkCancellation()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: recognitionImage, options: [:]).perform([request])
        try Task.checkCancellation()
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = document.snapshot.cropRect
        let redactions = document.snapshot.annotations.filter { if case .redaction = $0.kind { return true }; return false }.map(\.boundingRect)
        // A dense screenshot pays for at most 96 small template rasters; remaining lines
        // retain metric-based family/size estimates. All results share the OCR cache.
        var templateBudget = 96
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Keep oversized lines so the pipeline reports the limit rather than silently omitting text.
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * bounds.width, y: (1 - box.maxY) * bounds.height,
                width: box.width * bounds.width, height: box.height * bounds.height)
                .insetBy(dx: -2, dy: -2).integral.intersection(bounds)
            let sourceRect = rect.offsetBy(dx: crop.minX, dy: crop.minY)
            guard rect.width >= 3, rect.height >= 3, !redactions.contains(where: { $0.intersects(sourceRect) }) else { return nil }
            let colors = sampleColors(image: image, rect: rect)
            let typography = CaptureTranslationTypography.match(text: text, image: image, rect: rect, background: colors.0, templateBudget: &templateBudget)
            return CaptureTextRegion(text: text, rect: sourceRect, background: colors.0, foreground: colors.1,
                fontName: typography.name, fontSize: typography.size)
        }
    }

    static func scaledForRecognition(_ image: CGImage) throws -> CGImage {
        let ratio = min(1, 4096 / CGFloat(max(image.width, image.height)))
        guard ratio < 1 else { return image }
        let width = max(1, Int(CGFloat(image.width) * ratio)), height = max(1, Int(CGFloat(image.height) * ratio))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorRenderError.renderingFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw EditorRenderError.renderingFailed }
        return scaled
    }

    /// A tiny border sample per line, independent of full screenshot resolution.
    static func sampleColors(image: CGImage, rect: CGRect) -> (RGBAColor, RGBAColor) {
        guard let sample = image.cropping(to: rect), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 32, height: 12, bitsPerComponent: 8, bytesPerRow: 128,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return (.textForeground, .redactionFill)
        }
        // Nearest sampling keeps plain backgrounds exact instead of averaging ink into them.
        context.interpolationQuality = .none
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 32, height: 12))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return (.textForeground, .redactionFill) }
        var counts: [Int: Int] = [:]
        var exact: [Int: Int] = [:]
        for y in 0..<12 { for x in 0..<32 where y < 2 || y >= 10 || x < 2 || x >= 30 {
            let i = (y * 32 + x) * 4
            let key = ((Int(bytes[i]) / 16) << 8) | ((Int(bytes[i + 1]) / 16) << 4) | (Int(bytes[i + 2]) / 16)
            counts[key, default: 0] += 1
            let rgb = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            exact[rgb, default: 0] += 1
        } }
        let key = counts.max(by: { $0.value < $1.value })?.key ?? 0xfff
        let rgb = exact.filter { rgb, _ in ((rgb >> 20) << 8 | ((rgb >> 12) & 0xf) << 4 | ((rgb >> 4) & 0xf)) == key }
            .max(by: { $0.value < $1.value })?.key ?? 0xffffff
        let background = RGBAColor(red: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        let luminance = background.red * 0.2126 + background.green * 0.7152 + background.blue * 0.0722
        var ink: [Int: Int] = [:]
        for y in 2..<10 { for x in 2..<30 {
            let i = (y * 32 + x) * 4
            let distance = abs(CGFloat(bytes[i]) / 255 - background.red) + abs(CGFloat(bytes[i + 1]) / 255 - background.green) + abs(CGFloat(bytes[i + 2]) / 255 - background.blue)
            if distance > 0.6 { ink[Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]), default: 0] += 1 }
        } }
        let foreground: RGBAColor
        if let color = ink.max(by: { $0.value < $1.value })?.key {
            foreground = RGBAColor(red: CGFloat(color >> 16 & 255) / 255, green: CGFloat(color >> 8 & 255) / 255, blue: CGFloat(color & 255) / 255, alpha: 1)
        } else { foreground = luminance > 0.5 ? .redactionFill : .textForeground }
        return (background, foreground)
    }

    static func fontSize(text: String, rect: CGRect) -> CGFloat {
        var low: CGFloat = 1, high = max(1, rect.height * 0.85)
        let length = (text as NSString).length
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        for _ in 0..<12 {
            let size = (low + high) / 2
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), path, nil)
            if CTFrameGetVisibleStringRange(frame).length >= length { low = size } else { high = size }
        }
        return low
    }
}
