import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingWorkspaceView: View {
    @Bindable var coordinator: RecordingCoordinator

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    coordinator.showSelection()
                } label: {
                    Label("新建录制", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isBusy)
                Text("录制素材").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.store.sessions) { session in
                            Button { coordinator.selectedSessionID = session.id } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.title).font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                    Text(session.phase.displayName)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(coordinator.selectedSessionID == session.id
                                            ? Color.accentColor.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if coordinator.store.sessions.isEmpty {
                    Text("完成录制后，原片会保存在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(coordinator.store.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
            .background(.quaternary.opacity(0.25))

            VStack(alignment: .leading, spacing: 18) {
                if coordinator.isBusy { RecordingControlView(coordinator: coordinator) }
                if let session = coordinator.selectedSession {
                    RecordingSessionDetailView(coordinator: coordinator, session: session)
                        .id(session.id)
                } else {
                    ContentUnavailableView {
                        Label("还没有录制素材", systemImage: "film.stack")
                    } description: {
                        Text("在桌面上选好画面，即可开始录制。")
                    } actions: {
                        Button("开始录制…", action: coordinator.showSelection).buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
            .frame(minWidth: 530, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

}

struct RecordingControlView: View {
    @Bindable var coordinator: RecordingCoordinator
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: coordinator.phase == .paused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(coordinator.phase == .paused ? Color.secondary : Color.red)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.countdown.map { "\($0) 秒后开始" } ?? coordinator.phase.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text("各路原片独立保存")
                        .font(.caption).foregroundStyle(.secondary)
                    if coordinator.isCapturing {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let seconds = Int(coordinator.elapsedSeconds)
                            Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if coordinator.phase == .preparing {
                    Button("取消") { coordinator.cancelPreparation() }
                } else if coordinator.phase == .finalizing {
                    ProgressView().controlSize(.small)
                    Text("正在保存…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(coordinator.phase == .paused ? "继续" : "暂停") {
                        Task { await coordinator.togglePause() }
                    }
                    Button("结束录制") { Task { await coordinator.stop() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            if !compact, let session = coordinator.activeSession {
                HStack(spacing: 12) {
                    ForEach(session.sources) { source in
                        Label(source.name, systemImage: coordinator.sourceAvailability[source.id] == false
                              ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(coordinator.sourceAvailability[source.id] == false ? Color.orange : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            if let message = coordinator.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.red.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct RecordingSessionDetailView: View {
    @Bindable var coordinator: RecordingCoordinator
    let session: RecordingSessionManifest
    @State private var preview = RecordingPreviewController()
    @State private var selectedSource = ""
    @State private var editor: RecordingEditor = .finalCutPro
    @State private var previewError: String?
    @State private var exportingMP4 = false
    @State private var exportTask: Task<URL, Error>?
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0

    private var duration: Double { Double(session.durationMicroseconds) / 1_000_000 }
    private var canPreview: Bool { coordinator.activeSession?.id != session.id && !session.segments.isEmpty }
    private var videoSources: [RecordingSource] {
        RecordingPreviewController.availableVideoSources(in: session)
    }
    private var previewRequest: RecordingPreviewRequest {
        RecordingPreviewRequest(session: session, sourceID: selectedSource, isReady: canPreview)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).font(.title2.weight(.semibold))
                        Text("\(session.phase.displayName) · \(duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看原片") { coordinator.reveal(session) }
                }
                if canPreview {
                    if videoSources.isEmpty {
                        ContentUnavailableView("没有可预览的视频", systemImage: "video.slash",
                                               description: Text("已完成的声音原片仍保留，可查看文件或交给剪辑软件。"))
                    } else {
                        Picker("预览画面", selection: $selectedSource) {
                            ForEach(videoSources) { source in Text(source.name).tag(source.id) }
                        }.pickerStyle(.segmented)
                        if let player = preview.player {
                            RecordingPlayerView(player: player).frame(minHeight: 210, maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if preview.loading {
                            ProgressView("正在准备预览…").frame(maxWidth: .infinity, minHeight: 180)
                        }
                        if let previewError { Text(previewError).font(.caption).foregroundStyle(.orange) }
                        if let error = preview.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Text("导出范围").font(.caption).foregroundStyle(.secondary)
                            TextField("起点秒", value: $trimStart, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("至").font(.caption).foregroundStyle(.secondary)
                            TextField("终点秒", value: $trimEnd, format: .number)
                                .frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("秒").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("导出 MP4…") { Task { await exportMP4() } }
                                .disabled(exportingMP4 || preview.loading || selectedSource.isEmpty)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("交给剪辑软件").font(.system(size: 14, weight: .semibold))
                        HStack {
                            Picker("软件", selection: $editor) {
                                ForEach(RecordingEditor.allCases) { editor in Text(editor.title).tag(editor) }
                            }.labelsHidden()
                            Button("导出原片与项目…") {
                                Task { await coordinator.export(session, editor: editor) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(coordinator.exporting || coordinator.openingEditor)
                            if editor != .jianying, coordinator.hasExport(for: session.id, editor: editor) {
                                Button(coordinator.openingEditor ? "正在打开…" : "在\(editor.title)中打开") {
                                    Task { await coordinator.openExport(for: session.id, editor: editor) }
                                }
                                .disabled(coordinator.exporting || coordinator.openingEditor)
                            }
                        }
                        Text(editor.importVerificationNote)
                            .font(.caption).foregroundStyle(.secondary)
                        if coordinator.exporting || exportingMP4 {
                            HStack {
                                ProgressView("正在导出…").controlSize(.small)
                                Button("取消") {
                                    coordinator.cancelExport()
                                    exportTask?.cancel()
                                }.buttonStyle(.link)
                            }
                        }
                        if let message = coordinator.exportMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if session.segments.isEmpty {
                    ContentUnavailableView("还没有可播放片段", systemImage: "video",
                                           description: Text("完成的原片会在这里出现；未完成文件保留在录制文件夹。"))
                }
                ForEach(session.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            selectedSource = RecordingPreviewController.preferredSource(in: session, selectedID: selectedSource)
            trimEnd = duration
        }
        .onChange(of: videoSources.map(\.id)) {
            selectedSource = RecordingPreviewController.preferredSource(in: session, selectedID: selectedSource)
        }
        .onChange(of: duration) { old, new in
            if trimEnd == old || trimEnd == 0 { trimEnd = new }
        }
        .task(id: previewRequest) {
            await preview.load(previewRequest, sourceDirectory: coordinator.store.directory(for: session.id))
        }
        .onDisappear { preview.clear() }
    }

    private func exportMP4() async {
        guard !exportingMP4 else { return }
        guard trimStart.isFinite, trimEnd.isFinite, trimStart >= 0,
              trimEnd > trimStart, trimEnd <= duration else {
            previewError = "请输入录制时长以内的有效起点和终点。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "录制.mp4"
        exportingMP4 = true
        defer { exportingMP4 = false }
        let sourceID = selectedSource
        let start = trimStart
        let end = trimEnd
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let task = Task {
                try await RecordingVideoExporter.exportMP4(
                    session: session, sourceDirectory: coordinator.store.directory(for: session.id),
                    videoSourceID: sourceID, destination: url, trimStart: start, trimEnd: end)
            }
            exportTask = task
            defer { exportTask = nil }
            let output = try await task.value
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch is CancellationError { previewError = "导出已取消，原片仍保留。" }
        catch { previewError = "导出未完成，可重试：\(error.localizedDescription)" }
    }
}

/// Bind AVKit's native player directly; this also retains the AVPlayerView framework dependency.
struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player?.pause(); view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

extension RecordingPhase {
    var displayName: String {
        switch self {
        case .preparing: "准备录制"
        case .recording: "正在录制"
        case .paused: "已暂停"
        case .finalizing: "正在保存"
        case .ready: "原片已保存"
        case .interrupted: "录制中断，原片保留"
        case .failed: "录制未完成"
        }
    }
}
