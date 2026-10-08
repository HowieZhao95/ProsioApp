import SwiftUI

struct AgentMonitorView: View {
    @Bindable var coordinator: AgentMonitorCoordinator
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in content }
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cpu").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent 任务").font(.title2.bold())
                    Text("查看已经在电脑上启动的任务").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.refreshing { ProgressView().controlSize(.small) }
                Button("刷新", systemImage: "arrow.clockwise") { Task { await coordinator.refresh() } }
                    .disabled(coordinator.refreshing)
                Button(coordinator.monitoring ? "暂停监控" : "开始监控") {
                    if coordinator.monitoring { coordinator.stop() } else { coordinator.start() }
                }
            }.padding(20)
            if let target = coordinator.voice.target, coordinator.voice.recording || coordinator.voice.finishing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("语音回复：\(target.taskTitle)", systemImage: "mic.fill")
                        Spacer()
                        Button("结束录音") { coordinator.voice.finish() }.disabled(!coordinator.voice.recording || coordinator.voice.preparing)
                        Button("取消") { coordinator.voice.cancel() }
                    }
                    Text(coordinator.voice.text.isEmpty ? "正在准备并识别语音…" : coordinator.voice.text)
                    Text("识别结果将进入此任务的回答框，检查后点击发送。切换任务不会改变语音目标。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(.quaternary.opacity(0.4)).padding(.horizontal, 20)
            }
            if let message = coordinator.voice.message {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                if !coordinator.voice.text.isEmpty {
                    Text(coordinator.voice.text).font(.caption).textSelection(.enabled).padding(.horizontal, 20)
                }
            }
            if let taskID = coordinator.latestCommandTaskID, let title = coordinator.latestCommandTaskTitle {
                HStack {
                    Text("\(title)：\(coordinator.sendingTaskIDs.contains(taskID) ? "正在发送…" : coordinator.commandReceipts[taskID]?.state.label ?? "正在核实…")")
                        .font(.caption).textSelection(.enabled)
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 8)
            }
            HStack {
                Circle().fill(coordinator.monitoring ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(coordinator.monitoring ? "监控已开启" : "监控已暂停 · 当前为上次读取结果")
                Text("· \(coordinator.snapshot.runtimeConnected ? "已连接运行实例" : "本地日志记录")")
                Spacer()
                Text(coordinator.snapshot.checkedAt, style: .time)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("任务范围", selection: $coordinator.filter) {
                        ForEach(AgentMonitorFilter.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(12)
                    if coordinator.visibleTasks.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyDescription))
                            .frame(maxHeight: .infinity)
                    } else {
                        List(coordinator.visibleTasks, selection: $coordinator.selectedID) { task in
                            taskRow(task).tag(task.id)
                        }.listStyle(.sidebar)
                    }
                }.frame(minWidth: 300, idealWidth: 340, maxWidth: 390)
                ScrollView {
                    if let task = coordinator.selectedTask { detail(task) }
                    else {
                        ContentUnavailableView("任务会自动出现在这里", systemImage: "cpu",
                            description: Text("先在 Codex 或 ChatGPT Work 桌面端启动本地任务，再刷新。"))
                            .padding(.top, 70)
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if let error = coordinator.openError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                ForEach(coordinator.snapshot.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                HStack {
                    Text("普通 ChatGPT 聊天及云端任务尚未接入。已连接任务可回答问题、补充要求或请求中断；审批在来源应用处理。")
                    Spacer()
                    Button("更换数据目录…") { coordinator.chooseDirectory() }.buttonStyle(.link)
                }
            }.font(.caption).padding(12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyTitle: String {
        coordinator.filter == .attention ? "没有确认需要处理的事项" : coordinator.filter == .active ? "没有确认执行中的任务" : "没有找到近期会话"
    }
    private var emptyDescription: String {
        coordinator.filter == .recent ? "读取最近 14 天目录中的最多 100 个会话。" : "可切换到最近会话查看历史记录及状态待确认的任务。"
    }
    private func color(_ state: AgentTaskState) -> Color {
        switch state {
        case .waiting: .orange
        case .running: .blue
        case .failed: .red
        case .completed: .green
        default: .secondary
        }
    }
    private func taskRow(_ task: AgentTask) -> some View {
        let state = task.displayedState(at: Date())
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Circle().fill(color(state)).frame(width: 7, height: 7).padding(.top, 5)
                Text(task.title).font(.headline).lineLimit(2)
            }
            Text(task.surface.label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(state == .waiting ? task.stateLabel : state.label).foregroundStyle(color(state))
                Spacer()
                if let date = task.updatedAt { Text(date, style: .relative).foregroundStyle(.secondary) }
            }.font(.caption)
        }.padding(.vertical, 7)
    }
    private func detail(_ task: AgentTask) -> some View {
        let state = task.displayedState(at: Date())
        return VStack(alignment: .leading, spacing: 20) {
            Text(task.title).font(.title.bold()).textSelection(.enabled)
            HStack {
                Label(state == .waiting ? task.stateLabel : state.label, systemImage: state == .waiting ? "person.crop.circle.badge.questionmark" : "circle.fill")
                    .foregroundStyle(color(state))
                Text(task.surface.label).foregroundStyle(.secondary)
            }.font(.subheadline)
            VStack(alignment: .leading, spacing: 8) {
                Text("最近活动").font(.headline)
                Text(task.activity).textSelection(.enabled)
                if let date = task.updatedAt {
                    Text("记录时间：\(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            if let question = task.question, state != .unknown, !task.waitingForApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前问题").font(.headline)
                    if task.decisions.isEmpty { Text(question).textSelection(.enabled) }
                    ForEach(Array(task.decisions.enumerated()), id: \.offset) { _, decision in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(decision.title).textSelection(.enabled)
                            ForEach(Array(decision.options.enumerated()), id: \.offset) { _, option in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button(option.label) {
                                        if task.decisions.filter({ $0.requestID == decision.requestID }).count == 1 {
                                            Task { await coordinator.sendAnswers(to: task, decision: decision, option: option.label) }
                                        } else {
                                            coordinator.answerDrafts[coordinator.answerKey(task: task, decision: decision)] = option.label
                                        }
                                    }.disabled(!coordinator.canAnswer(task, decision: decision) || coordinator.voice.recording || coordinator.voice.finishing)
                                    if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(.secondary) }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                            if coordinator.canAnswer(task, decision: decision) {
                                TextField("回答或补充条件，可用 Prosio 热键语音输入", text: Binding(
                                    get: { coordinator.answerDrafts[coordinator.answerKey(task: task, decision: decision)] ?? "" },
                                    set: { coordinator.answerDrafts[coordinator.answerKey(task: task, decision: decision)] = $0 }
                                ), axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                                Button("语音回答", systemImage: "mic") { coordinator.startVoice(task: task, decision: decision) }
                                    .disabled(coordinator.voice.recording || coordinator.voice.finishing)
                                Button("发送回答") { Task { await coordinator.sendAnswers(to: task, decision: decision) } }
                                    .disabled(coordinator.voice.recording || coordinator.voice.finishing || task.decisions.filter({ $0.requestID == decision.requestID }).contains {
                                        (coordinator.answerDrafts[coordinator.answerKey(task: task, decision: $0)] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    })
                            }
                        }
                    }
                    Text(task.controlRoute == .desktopIPC ? "点击单个问题的选项直接发送；多个问题请选好全部答案再发送。" : "请在来源应用中回答。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if state == .waiting && task.waitingForApproval {
                Text("Agent 正在等待操作审批。请在来源应用查看具体操作和权限范围。")
                    .foregroundStyle(.orange)
            }
            if state == .unknown {
                Text("现有记录不足以确认当前状态，请回到来源应用查看。")
                    .foregroundStyle(.secondary)
            }
            if task.truncated {
                Text("此会话仅解析了部分近期记录，较早的上下文可能缺失。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if task.state == .completed {
                Text("本轮结束表示 Agent 已停止本轮回复，不代表整个项目目标已完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("补充当前任务要求").font(.headline)
                if task.controlRoute == .desktopIPC {
                    Text("发送到此任务当前执行的轮次，收到后显示回执。不会批准待审批操作。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("输入补充要求，也可用 Prosio 热键语音输入", text: Binding(
                    get: { coordinator.drafts[task.id] ?? "" },
                    set: { coordinator.drafts[task.id] = $0 }
                ), axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                HStack {
                    Button("发送补充要求") { Task { await coordinator.sendSupplement(to: task) } }
                        .disabled(!coordinator.canSupplement(task) || (coordinator.drafts[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("语音补充", systemImage: "mic") { coordinator.startVoice(task: task) }
                        .disabled(!coordinator.canSupplement(task) || coordinator.voice.recording || coordinator.voice.finishing)
                    if task.live, coordinator.snapshot.runtimeConnected, task.turnID != nil,
                       state == .running || state == .waiting {
                        Button("请求中断本轮") { Task { await coordinator.requestInterrupt(task) } }
                            .disabled(!coordinator.canInterrupt(task))
                    }
                }
                if coordinator.sendingTaskIDs.contains(task.id) {
                    Label("正在发送到原任务…", systemImage: "arrow.up.circle")
                } else if let receipt = coordinator.commandReceipts[task.id] {
                    Text(receipt.state.label).font(.caption).foregroundStyle(.secondary)
                    if receipt.state == .uncertain || receipt.state == .accepted {
                        Button("核实原请求结果") { Task { await coordinator.reconcile(taskID: task.id) } }
                    }
                }
                if !coordinator.canSupplement(task) {
                    Text(task.controlRoute == .desktopIPC
                         ? "任务需在执行中才能补充要求；待回答问题请使用上方回答卡，审批请在来源应用处理。"
                         : "补充要求需要连接当前执行轮次。待回答问题和审批请在来源应用处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("中断不能撤回已经发生的操作。补充要求不会改变原任务的权限设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("项目", value: task.workspace.isEmpty ? "未提供" : URL(fileURLWithPath: task.workspace).lastPathComponent)
            LabeledContent("模型", value: task.model.isEmpty ? "未提供" : task.model)
            if task.parentID != nil { Label("这是一个子 Agent 会话", systemImage: "arrow.triangle.branch") }
            Button("打开来源应用", systemImage: "arrow.up.forward.app") { coordinator.openSource(for: task) }
            DisclosureGroup("数据来源") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("任务编号：\(task.id)").textSelection(.enabled)
                    Text(task.live ? "状态来自现有运行实例的查询。" : "状态来自本地会话日志；超过三分钟没有活动的执行／等待状态会降为待确认。")
                    Text("仅读取会话元数据、事件、标题及结构化问题，不保存完整聊天或读取登录凭证。")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}
