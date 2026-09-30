import AppKit
import AVKit
import SwiftUI

struct MeetingLibraryView: View {
    let coordinator: MeetingCoordinator
    @State private var selectedID: UUID?
    @State private var showCloud = false
    @State private var player: AVPlayer?
    @State private var playingID: UUID?

    private var selected: MeetingRecord? {
        coordinator.store.records.first { $0.id == selectedID } ?? coordinator.store.records.first
    }
    private var displayed: [MeetingUtterance] {
        guard let selected else { return [] }
        return showCloud && !selected.cloud.isEmpty ? selected.cloud : selected.local
    }

    var body: some View {
        NavigationSplitView {
            List(coordinator.store.records, selection: $selectedID) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.headline)
                    Text(record.phase == .ready ? "本地稿已就绪" : record.phase.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(record.id)
            }
            .navigationTitle("会议")
            .frame(minWidth: 210)
        } detail: {
            if let record = selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(.title2).bold()
                            if let endedAt = record.endedAt {
                                Text("时长：\(Int(endedAt.timeIntervalSince(record.startedAt))) 秒 · \(displayed.count) 段文字")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("打开录音文件夹") { coordinator.reveal(record) }
                        Button(playingID == record.id ? "停止播放" : "播放录音") { togglePlayback(record) }
                            .disabled(record.playbackFile == nil && record.systemFile == nil && record.microphoneFile == nil)
                        Button("复制全文") { copy(record) }
                            .disabled(displayed.isEmpty)
                    }
                    HStack {
                        Picker("文字版本", selection: $showCloud) {
                            Text("Apple 本地稿").tag(false)
                            Text("Soniox 增强稿").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .disabled(record.cloud.isEmpty)
                        if record.cloudStatus == "processing" { ProgressView("云端处理中") }
                        if record.cloudStatus != "ready" && record.phase == .ready {
                            Button("上传到 Soniox") { coordinator.retryCloud(record) }
                                .disabled(record.cloudStatus == "processing")
                        }
                        if record.phase == .failed, record.microphoneFile != nil {
                            Button("重新生成本地稿") { coordinator.retryLocal(record) }
                                .disabled(coordinator.processing)
                        }
                    }
                    if let error = record.cloudError {
                        Text("Soniox：\(error)").font(.caption).foregroundStyle(.orange)
                    }
                    if let error = record.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                    if displayed.isEmpty {
                        ContentUnavailableView("还没有文字", systemImage: "waveform",
                                               description: Text("录音文件保存在会议文件夹中。"))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(displayed) { segment in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(time(segment.start)).monospacedDigit()
                                            .foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(segment.speaker ?? segment.source)
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(segment.text).textSelection(.enabled)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("还没有会议", systemImage: "waveform")
            }
        }
        .onDisappear { player?.pause(); player = nil; playingID = nil }
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }

    private func copy(_ record: MeetingRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayed.map {
            "[\(time($0.start))] \($0.speaker ?? $0.source): \($0.text)"
        }.joined(separator: "\n"), forType: .string)
    }

    private func togglePlayback(_ record: MeetingRecord) {
        if playingID == record.id {
            player?.pause()
            player = nil
            playingID = nil
            return
        }
        guard let name = record.playbackFile ?? record.systemFile ?? record.microphoneFile else { return }
        player?.pause()
        let next = AVPlayer(url: coordinator.store.directory(for: record.id).appending(path: name))
        player = next
        playingID = record.id
        next.play()
    }
}
