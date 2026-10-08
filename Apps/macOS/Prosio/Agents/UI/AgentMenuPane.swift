import SwiftUI

struct AgentMenuStatusLabel: View {
    let coordinator: AgentMonitorCoordinator
    private var count: Int { coordinator.attentionCount > 0 ? coordinator.attentionCount : coordinator.runningCount }
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: !coordinator.monitoring ? "waveform" : coordinator.attentionCount > 0
                  ? "person.crop.circle.badge.exclamationmark" : coordinator.runningCount > 0 ? "cpu" : "waveform")
            if coordinator.monitoring && count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityLabel("Prosio")
        .accessibilityValue(coordinator.monitoring ? "\(coordinator.runningCount) 个任务执行中，\(coordinator.attentionCount) 个需要处理" : "Agent 监控已暂停")
        .help(coordinator.monitoring ? "Prosio · \(coordinator.runningCount) 执行中 · \(coordinator.attentionCount) 需要处理" : "Prosio · Agent 监控已暂停")
    }
}

struct AgentMenuPane: View {
    @Bindable var coordinator: AgentMonitorCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent 任务").font(.headline)
                Spacer()
                if coordinator.refreshing { ProgressView().controlSize(.mini) }
                Button(coordinator.monitoring ? "暂停监控" : "开启监控") {
                    if coordinator.monitoring { coordinator.stop() } else { coordinator.start() }
                }.buttonStyle(.link).font(.caption)
            }
            HStack(spacing: 8) {
                counter("执行中", count: coordinator.runningCount, color: .blue)
                counter("需要处理", count: coordinator.attentionCount, color: .orange)
            }
            Text(coordinator.monitoring ? "\(coordinator.snapshot.runtimeConnected ? "已连接运行实例" : "本地日志同步") · 每 5 秒更新" : "监控已暂停 · 显示上次读取结果")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("查看全部任务…") { dismiss(); coordinator.filter = .recent; coordinator.show() }.buttonStyle(.link)
                Spacer()
                Button("刷新") { Task { await coordinator.refresh() } }.buttonStyle(.link).disabled(coordinator.refreshing)
            }.font(.caption)
            Divider()
            if coordinator.menuTasks.isEmpty {
                Text(coordinator.refreshing ? "正在读取已有任务…" : "尚未发现近期本地任务")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(coordinator.menuTasks) { task in
                Button {
                    dismiss(); coordinator.show(taskID: task.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                        HStack {
                            Text(task.displayedState(at: Date()) == .waiting ? task.stateLabel : task.displayedState(at: Date()).label)
                            Spacer()
                            Text(task.surface.label).lineLimit(1)
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(task.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            if let warning = coordinator.snapshot.warnings.first {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("当前只读 · 普通 ChatGPT 云端任务尚未接入")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.bottom, 14)
    }
    private func counter(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count)").font(.title2.bold()).foregroundStyle(color).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
