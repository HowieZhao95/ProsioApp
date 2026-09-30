import AppKit
import AVFoundation
import SwiftUI

/// A's desktop controls: sources live in native menus instead of a setup form.
struct RecordingSelectionToolbarView: View {
    @Bindable var coordinator: RecordingCoordinator

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                iconButton("xmark", title: "取消录制", action: coordinator.dismissSelection)
                    .keyboardShortcut(.escape, modifiers: [])
                divider
                ForEach([RecordingSelectionMode.display, .window, .region], id: \.rawValue) { mode in
                    iconButton(symbol(mode), title: title(mode)) { coordinator.setSelectionMode(mode) }
                        .disabled(coordinator.isBusy)
                        .background(coordinator.screenMode == mode.rawValue ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                divider
                Menu {
                    Text("摄像头 · 最多两路")
                    ForEach(coordinator.inventory?.cameras ?? []) { source in
                        Button { coordinator.toggleCamera(source.id) } label: {
                            Label(source.name, systemImage: coordinator.isCameraSelected(source.id) ? "checkmark" : "video")
                        }
                        .disabled(!coordinator.isCameraSelected(source.id) && coordinator.selectedCameraIDs.count >= 2)
                    }
                    if coordinator.inventory?.cameras.isEmpty != false { Text("未发现摄像头") }
                    ForEach(coordinator.selectedCameraIDs.filter { id in !(coordinator.inventory?.cameras.contains { $0.id == id } ?? false) }, id: \.self) { id in
                        Button("关闭不可用机位") { coordinator.toggleCamera(id) }
                    }
                    if !coordinator.selectedCameraIDs.isEmpty {
                        Divider()
                        Button("关闭所有摄像头") { coordinator.clearCameras() }
                    }
                    Divider()
                    Button("刷新设备") { Task { await coordinator.refreshSelectionSources() } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: coordinator.selectedCameraSources.isEmpty ? "video.slash" : "video")
                        if !coordinator.selectedCameraSources.isEmpty { Text("\(coordinator.selectedCameraSources.count)").font(.system(size: 10, weight: .medium)) }
                    }.frame(height: 32)
                }.help("摄像头").disabled(coordinator.isBusy)
                Menu {
                    Toggle("麦克风", isOn: $coordinator.includeMicrophone)
                    if coordinator.includeMicrophone {
                        ForEach(coordinator.inventory?.microphones ?? []) { source in
                            Button { coordinator.microphoneID = source.id } label: {
                                Label(coordinator.microphoneName(source), systemImage: coordinator.microphoneID == source.id ? "checkmark" : "mic")
                            }
                        }
                        if coordinator.inventory?.microphones.isEmpty != false { Text("未发现麦克风") }
                    }
                    Divider()
                    Toggle("系统声音", isOn: $coordinator.includeSystemAudio)
                } label: {
                    Image(systemName: coordinator.includeMicrophone ? "mic" : "mic.slash").frame(height: 32)
                }.help("声音").disabled(coordinator.isBusy)
                Menu {
                    Toggle("显示鼠标指针", isOn: $coordinator.showsCursor)
                    Divider()
                    Button("录制素材…") { coordinator.dismissSelection(); coordinator.showWindow() }
                } label: { Image(systemName: "ellipsis").frame(height: 32) }.help("更多选项").disabled(coordinator.isBusy)
                divider
                Button(action: coordinator.begin) {
                    HStack(spacing: 7) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(coordinator.countdown.map(String.init) ?? "录制").font(.system(size: 12, weight: .semibold))
                    }.frame(width: 68, height: 32)
                        .background(.background, in: RoundedRectangle(cornerRadius: 9))
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(coordinator.isBusy || !coordinator.selectionTargetReady || coordinator.loadingSources)
                .help("开始录制")
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2), lineWidth: 0.5))
            if let message = coordinator.message {
                HStack(spacing: 8) {
                    Text(message).lineLimit(2)
                    if let recovery = coordinator.permissionRecovery {
                        Button("打开设置", action: coordinator.openPermissions).help(recovery.title)
                    }
                    if coordinator.permissionRecovery == .screen {
                        Button("重试") { Task { await coordinator.refreshSelectionSources() } }
                    }
                }
                .font(.system(size: 11)).padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 480)
            }
        }
        .font(.system(size: 15, weight: .regular))
        .padding(8)
    }

    private var divider: some View { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 22).padding(.horizontal, 3) }
    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 32) }.help(title).accessibilityLabel(title)
    }
    private func symbol(_ mode: RecordingSelectionMode) -> String {
        switch mode { case .display: "display"; case .window: "macwindow"; case .region: "rectangle.dashed" }
    }
    private func title(_ mode: RecordingSelectionMode) -> String {
        switch mode { case .display: "录制屏幕"; case .window: "录制窗口"; case .region: "录制区域" }
    }
}

struct RecordingCompactControlView: View {
    @Bindable var coordinator: RecordingCoordinator
    var body: some View {
        HStack(spacing: 15) {
            Circle().fill(coordinator.phase == .paused ? Color.orange : .red).frame(width: 7, height: 7)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let seconds = Int(coordinator.elapsedSeconds)
                Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                    .monospacedDigit().font(.system(size: 12, weight: .medium))
            }
            if coordinator.phase == .finalizing {
                ProgressView().controlSize(.small).help("正在保存原片")
            } else {
                Button { Task { await coordinator.togglePause() } } label: {
                    Image(systemName: coordinator.phase == .paused ? "play.fill" : "pause.fill")
                }.help(coordinator.phase == .paused ? "继续录制" : "暂停录制")
                Button { Task { await coordinator.stop() } } label: {
                    RoundedRectangle(cornerRadius: 3).fill(.red).frame(width: 12, height: 12)
                }.help("结束录制").accessibilityLabel("结束录制")
            }
            Menu {
                Button(coordinator.previewsHidden ? "显示摄像头预览" : "隐藏摄像头预览") { coordinator.togglePreviewVisibility() }
                    .disabled(coordinator.selectedCameraSources.isEmpty)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(7)
        .accessibilityElement(children: .contain).accessibilityLabel("录制控制")
    }
}

enum RecordingCameraPreviewStyle {
    static let cornerRadius: CGFloat = 14
    static let shadowPadding: CGFloat = 18
    static let contentSize = CGSize(width: 224, height: 144)
    static let panelSize = CGSize(width: contentSize.width + shadowPadding * 2,
                                  height: contentSize.height + shadowPadding * 2)
}

struct RecordingCameraPreviewCard: View {
    @Bindable var coordinator: RecordingCoordinator
    let source: RecordingSource
    @State private var hovered = false
    @State private var dragPointerStart: NSPoint?
    @State private var dragWindowStart: NSPoint?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                RecordingCameraLayerView(session: coordinator.cameraPreviewSession(for: source.id))
                if let status = coordinator.previewStatusText(for: source.id) {
                    Text(status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(source.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.45))
            }
            if hovered {
                Button { coordinator.closeCameraPreview(source.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22).background(.black.opacity(0.5), in: Circle())
                }.buttonStyle(.plain).foregroundStyle(.white).padding(6)
                    .help(coordinator.isCapturing ? "隐藏预览，原片继续录制" : "关闭这个摄像头")
            }
        }
        .frame(width: RecordingCameraPreviewStyle.contentSize.width, height: RecordingCameraPreviewStyle.contentSize.height)
        .clipShape(RoundedRectangle(cornerRadius: RecordingCameraPreviewStyle.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: RecordingCameraPreviewStyle.cornerRadius).stroke(.white.opacity(0.30), lineWidth: 0.5))
        .onHover { hovered = $0 }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                // Screen coordinates stay stable while the hosting window follows the pointer.
                let pointer = NSEvent.mouseLocation
                if dragPointerStart == nil {
                    dragPointerStart = NSPoint(x: pointer.x - value.translation.width,
                                               y: pointer.y + value.translation.height)
                    dragWindowStart = coordinator.cameraPreviewOrigin(for: source.id)
                }
                if let start = dragPointerStart, let origin = dragWindowStart {
                    coordinator.moveCameraPreview(source.id, to: NSPoint(
                        x: origin.x + pointer.x - start.x,
                        y: origin.y + pointer.y - start.y))
                }
            }
            .onEnded { _ in dragPointerStart = nil; dragWindowStart = nil })
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        .padding(RecordingCameraPreviewStyle.shadowPadding)
    }
}

/// The preview attaches to a session; it never owns or starts that session.
private struct RecordingCameraLayerView: NSViewRepresentable {
    let session: AVCaptureSession?
    func makeNSView(context: Context) -> RecordingCameraLayerHost { RecordingCameraLayerHost() }
    func updateNSView(_ view: RecordingCameraLayerHost, context: Context) { view.preview.session = session }
    static func dismantleNSView(_ view: RecordingCameraLayerHost, coordinator: ()) { view.preview.session = nil }
}
private final class RecordingCameraLayerHost: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override var mouseDownCanMoveWindow: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = RecordingCameraPreviewStyle.cornerRadius
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}

struct RecordingCompletionView: View {
    @Bindable var coordinator: RecordingCoordinator
    private var needsReview: Bool {
        coordinator.phase != .ready || coordinator.selectedSession?.warnings.isEmpty == false
    }
    private var completionText: String {
        if coordinator.selectedSession?.segments.isEmpty == true { return "未取得可播放片段" }
        if coordinator.phase == .ready {
            return needsReview ? "录制已保存，请查看提示" : "录制已保存"
        }
        return "录制已结束，原片已保留"
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: needsReview ? "exclamationmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(needsReview ? Color.orange : .green)
            Text(completionText).help(coordinator.message ?? "").font(.system(size: 12, weight: .medium))
            Button("查看素材") { coordinator.closeCompletion(); coordinator.showWindow(sessionID: coordinator.selectedSessionID) }
                .buttonStyle(.plain).foregroundStyle(.tint)
            Button(action: coordinator.closeCompletion) { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(7)
    }
}
