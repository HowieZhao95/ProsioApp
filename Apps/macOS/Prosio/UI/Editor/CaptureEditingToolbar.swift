import AppKit
import SwiftUI

/// The approved C direction: one restrained floating capsule attached to the selection.
struct CaptureEditingToolbar: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: CaptureEditingSession
    var width: CGFloat = 404

    static let primaryTools: [EditorTool] = [.select, .rectangle, .ellipse, .line, .freehand, .text, .pixelate]
    private var isDark: Bool { colorScheme == .dark }
    private var ink: Color { isDark ? Color(red: 0.91, green: 0.89, blue: 0.85) : Color(red: 0.37, green: 0.35, blue: 0.32) }
    private var surface: Color { isDark ? Color(red: 0.22, green: 0.21, blue: 0.20) : Color(red: 0.99, green: 0.98, blue: 0.96) }

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Self.primaryTools) { tool in toolButton(tool) }
                    divider
                    iconButton("arrow.uturn.backward", label: "Undo", hint: "Undo · ⌘Z") { session.undo() }
                        .disabled(!session.canUndo)
                    iconButton("arrow.uturn.forward", label: "Redo", hint: "Redo · ⇧⌘Z") { session.redo() }
                        .disabled(!session.canRedo)
                    divider
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)

            translationButton
            iconButton("xmark", label: "Exit screenshot", hint: "Exit · Esc") { session.cancel() }
            iconButton("pin", label: "Pin screenshot", hint: "Pin screenshot above other windows") {
                session.requestOutput(.pin)
            }
            .disabled(session.isTranslating)
            iconButton("square.and.arrow.down", label: "Download JPEG", hint: "Save JPEG · ⌘S") {
                session.requestOutput(.saveJPEG)
            }
            .disabled(session.isTranslating)
            iconButton("doc.on.doc", label: "Copy and exit", hint: "Copy and exit · ⌘C / Return") {
                session.requestOutput(.copy)
            }
            .foregroundStyle(isDark ? surface : Color.white)
            .background(ink, in: Circle())
            .disabled(session.isTranslating)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ink)
        .buttonStyle(.borderless)
        .disabled(session.isOutputting)
        .padding(5)
        .frame(width: width, height: 42)
        .background(surface.opacity(0.97), in: Capsule())
        .overlay(Capsule().stroke(ink.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(isDark ? 0.20 : 0.14), radius: 15, y: 5)
    }

    private var translationLanguageName: String {
        switch session.translationTarget {
        case "zh-Hant": "繁體中文"
        case "en-US": "English"
        case "ja-JP": "日本語"
        case "ko-KR": "한국어"
        case "fr-FR": "Français"
        case "de-DE": "Deutsch"
        default: "简体中文"
        }
    }
    private var translationButton: some View {
        Button {
            if session.isTranslating { session.cancelTranslation() }
            else { session.translateCapture() }
        } label: {
            Group {
                if session.isTranslating { ProgressView().controlSize(.small) }
                else { Image(systemName: "translate") }
            }.frame(width: 28, height: 30).contentShape(Rectangle())
        }
        .accessibilityLabel(session.isTranslating ? "取消截图翻译" : "翻译并覆盖原图")
        .help(session.isTranslating ? "取消翻译 · Esc" : "翻译为 \(translationLanguageName)并覆盖原图 · 右键选择语言")
        .contextMenu {
            ForEach([("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("fr-FR", "Français"), ("de-DE", "Deutsch")], id: \.0) { code, name in
                Button { session.translateCapture(to: code) } label: {
                    if session.translationTarget == code { Label(name, systemImage: "checkmark") }
                    else { Text(name) }
                }.disabled(session.isTranslating)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(ink.opacity(0.16)).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private func select(_ tool: EditorTool) {
        session.selectDrawingTool(tool == .line ? session.preferredLineTool : tool)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button { select(tool) } label: {
            Group {
                if tool == .text {
                    Text("T").font(.system(size: 15, weight: .medium, design: .serif))
                } else {
                    Image(systemName: tool.systemImage)
                }
            }
            .frame(width: 28, height: 30).contentShape(Rectangle())
        }
        .accessibilityLabel(label(tool))
        .help(label(tool))
        .background(isActive(tool) ? ink.opacity(0.11) : .clear, in: Circle())
        .overlay(Circle().stroke(isActive(tool) ? ink.opacity(0.8) : .clear, lineWidth: 1.5))
    }

    private func label(_ tool: EditorTool) -> String {
        switch tool { case .select: "选择 / 移动"; case .rectangle: "矩形"; case .ellipse: "椭圆"; case .line: "线条"; case .freehand: "画笔"; case .text: "文字"; case .pixelate: "遮挡"; default: tool.label }
    }
    private func isActive(_ tool: EditorTool) -> Bool {
        if tool == .line { return [.arrow, .line, .markerLine].contains(session.tool) }
        if tool == .pixelate { return [.pixelate, .blur, .redact].contains(session.tool) }
        return session.tool == tool
    }
    private func iconButton(_ symbol: String, label: String, hint: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 30).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .help(hint)
    }
}

/// A contextual second row for annotation tools; the main toolbar stays one line.
struct CaptureAnnotationPalette: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: CaptureEditingSession
    static let width: CGFloat = 350
    static let height: CGFloat = 118
    var width: CGFloat = Self.width
    private let colors: [RGBAColor] = [.rectangleStroke, .arrowStroke, .highlightFill.withAlpha(1), .lineStroke, .ellipseStroke, .pixelateOutline, .textForeground, .redactionFill]
    private var ink: Color { colorScheme == .dark ? Color(white: 0.91) : Color(red: 0.37, green: 0.35, blue: 0.32) }
    private var surface: Color { colorScheme == .dark ? Color(red: 0.22, green: 0.21, blue: 0.20) : Color(red: 0.99, green: 0.98, blue: 0.96) }
    private var isText: Bool { session.propertyTool == .text }
    private func colorBinding(_ fill: Bool = false) -> Binding<Color> {
        Binding(get: { Color(nsColor: (fill ? session.displayedStyle.fillColor : session.displayedAnnotationColor).nsColor) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.deviceRGB) else { return }
            let color = RGBAColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1)
            if fill { session.setAnnotationFillColor(color) } else { session.setAnnotationColor(color) }
        })
    }
    var body: some View {
        VStack(spacing: 8) { colorRow; attributeRow; metricsRow }
            .padding(.horizontal, 12).frame(width: width, height: Self.height)
            .foregroundStyle(ink).disabled(session.isOutputting)
            .background(surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(ink.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.14), radius: 15, y: 5)
    }
    private var colorRow: some View {
        HStack(spacing: width < 320 ? 5 : 9) {
            Text(session.selectedAnnotation == nil ? "新图形" : "已选中").font(.system(size: 11)).foregroundStyle(ink.opacity(0.7))
            if session.showsRedactionControls { Text("遮挡区域").font(.system(size: 12)); Spacer() }
            else {
                ForEach(Array(colors.prefix(width < 320 ? 6 : 8).enumerated()), id: \.offset) { _, color in colorButton(color) }
                CaptureColorWell(color: colorBinding(), label: "自定义描边颜色").frame(width: 18, height: 18)
            }
        }
    }
    private func colorButton(_ color: RGBAColor) -> some View {
        Button { session.setAnnotationColor(color) } label: {
            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 18, height: 18)
                .overlay(Circle().stroke(ink.opacity(0.25), lineWidth: 0.5))
                .overlay(Circle().stroke(ink, lineWidth: 1.5).padding(-3).opacity(session.displayedAnnotationColor == color ? 1 : 0))
        }.buttonStyle(.plain).accessibilityLabel(RGBAColor.paletteOption(for: color)?.label ?? "颜色")
    }
    private var attributeRow: some View {
        HStack(spacing: 8) {
            if session.showsRedactionControls { redactionPicker }
            else if session.showsShapeControls { shapeControls }
            else if session.showsLineControls { linePicker }
            else { Text(isText ? "拖动文字可调整位置" : "颜色与粗细用于下一笔").foregroundStyle(ink.opacity(0.7)); Spacer() }
        }.font(.system(size: 12)).toggleStyle(.checkbox).frame(height: 24)
    }
    private var shapeControls: some View {
        Group {
            Toggle("描边", isOn: Binding(get: { session.displayedStyle.lineWidth > 0 }, set: { session.setAnnotationStroke($0) }))
            Toggle("填充", isOn: Binding(get: { session.displayedStyle.fillColor.alpha > 0 }, set: { session.setAnnotationFill($0) }))
            if session.displayedStyle.fillColor.alpha > 0 {
                CaptureColorWell(color: colorBinding(true), label: "填充颜色").frame(width: 18, height: 18)
            }
            Spacer(minLength: 0)
            Menu("样式") {
                Button("仅描边") { session.setShapeAppearance("outline") }
                Button("实心填充") { session.setShapeAppearance("solid") }
                Button("半透明高亮") { session.setShapeAppearance("highlight") }
            }.menuStyle(.borderlessButton).fixedSize()
        }
    }
    private var linePicker: some View {
        Group {
            Text("端点")
            Picker("线条端点", selection: Binding(get: { session.selectedLineTool ?? session.tool }, set: { session.setLineTool($0) })) {
                Text("无").tag(EditorTool.line); Text("箭头").tag(EditorTool.arrow); Text("刻度").tag(EditorTool.markerLine)
            }.pickerStyle(.segmented)
        }
    }
    private var redactionPicker: some View {
        Picker("遮挡方式", selection: Binding(get: { session.propertyTool }, set: { session.setRedactionTool($0) })) {
            Text("马赛克").tag(EditorTool.pixelate); Text("模糊").tag(EditorTool.blur)
        }.pickerStyle(.segmented)
    }
    private var metricsRow: some View {
        HStack(spacing: 12) {
            if session.showsRedactionControls {
                if session.propertyTool != .redact {
                    Text("强度")
                    Slider(value: Binding(get: { session.displayedRedactionRadius }, set: { session.setRedactionRadius($0) }), in: session.redactionStrengthRange, step: 1, onEditingChanged: { adjust($0) })
                    Text("\(Int(session.displayedRedactionRadius))").monospacedDigit().frame(width: 24)
                } else { Text("完全覆盖选中区域").foregroundStyle(ink.opacity(0.7)); Spacer() }
            } else { widthControl; opacityControl }
        }.font(.system(size: 11))
    }
    private var widthControl: some View {
        HStack(spacing: 5) {
            Text(isText ? "字号" : "粗细")
            Slider(value: Binding(get: { isText ? session.displayedFontSize : max(1, session.displayedLineWidth) }, set: { setSize($0) }),
                   in: isText ? 12...64 : 1...16, step: 1, onEditingChanged: { adjust($0) })
                .disabled(!isText && session.showsShapeControls && session.displayedStyle.lineWidth == 0)
            Text("\(Int(isText ? session.displayedFontSize : session.displayedLineWidth))").monospacedDigit().frame(width: 20)
        }
    }
    private var opacityControl: some View {
        HStack(spacing: 5) {
            Text("不透明度")
            Slider(value: Binding(get: { session.displayedStyle.opacity }, set: { session.setAnnotationOpacity($0) }), in: 0...1, onEditingChanged: { adjust($0) })
            Text("\(Int((session.displayedStyle.opacity*100).rounded()))%").monospacedDigit().frame(width: 34)
        }
    }
    private func setSize(_ value: CGFloat) {
        if isText { session.setAnnotationFontSize(value) } else { session.setAnnotationLineWidth(value) }
    }
    private func adjust(_ editing: Bool) {
        if editing { session.beginStyleAdjustment() } else { session.endStyleAdjustment() }
    }
}

/// Keep native color picking and keyboard access without the surrounding pill.
private struct CaptureColorWell: NSViewRepresentable {
    @Binding var color: Color
    let label: String
    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CapturePlainColorWell, context: Context) -> CGSize? {
        CGSize(width: 18, height: 18)
    }
    func makeNSView(context: Context) -> CapturePlainColorWell {
        let well = CapturePlainColorWell(frame: .zero)
        well.colorWellStyle = .minimal
        well.supportsAlpha = false
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.setAccessibilityLabel(label)
        well.toolTip = label
        return well
    }
    func updateNSView(_ well: CapturePlainColorWell, context: Context) {
        context.coordinator.color = $color
        well.color = NSColor(color)
        well.isEnabled = context.environment.isEnabled
        well.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        var color: Binding<Color>
        init(color: Binding<Color>) { self.color = color }
        @objc func changed(_ sender: NSColorWell) { color.wrappedValue = Color(nsColor: sender.color) }
    }
}
private final class CapturePlainColorWell: NSColorWell {
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let swatch = NSBezierPath(ovalIn: rect)
        color.setFill(); swatch.fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        swatch.lineWidth = 0.5; swatch.stroke()
    }
}

struct CaptureHistoryNavigation: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: CaptureEditingSession
    let sourceIndex: Int

    var body: some View {
        HStack(spacing: 3) {
            Button { session.browseHistory(older:true,from:sourceIndex) } label: {
                Image(systemName:"chevron.left").frame(width:30,height:28)
            }
            .disabled(!session.canBrowseOlder)
            .accessibilityLabel("Previous screenshot")
            .help("Previous screenshot · ←")
            Text(session.isBrowsingHistory ? "\(session.historyPosition) / \(session.historyCount)" : "当前")
                .font(.system(size:11,weight:.medium,design:.rounded))
                .monospacedDigit()
                .frame(maxWidth:.infinity)
                .accessibilityLabel(session.isBrowsingHistory ? "Screenshot \(session.historyPosition) of \(session.historyCount)" : "Current screenshot")
            Button { session.browseHistory(older:false,from:sourceIndex) } label: {
                Image(systemName:"chevron.right").frame(width:30,height:28)
            }
            .disabled(!session.canBrowseNewer)
            .accessibilityLabel("Next screenshot")
            .help("Next screenshot · →")
        }
        .buttonStyle(.plain)
        .font(.system(size:12,weight:.semibold))
        .foregroundStyle(colorScheme == .dark ? Color.white : Color(red:0.30,green:0.29,blue:0.27))
        .padding(.horizontal,5)
        .frame(width:148,height:32)
        .background(colorScheme == .dark ? Color(red:0.22,green:0.21,blue:0.20).opacity(0.96) : Color(red:0.99,green:0.98,blue:0.96).opacity(0.96),in:Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(colorScheme == .dark ? 0.38 : 0.12),lineWidth:1))
        .shadow(color:.black.opacity(0.16),radius:10,y:3)
    }
}
