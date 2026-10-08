import AppKit
import ProsioCore
import SwiftUI

/// Menu bar popover. INIT SIGNATURE FROZEN.
/// Voice and screenshot have separate panes; capture begins directly in region selection.
struct MenuBarContentView: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var selectedPane: MenuBarPane = .voice
    @State private var showingHelp = false

    var body: some View {
        MenuBarShell(selectedPane: $selectedPane) { pane in
            Group {
                switch pane {
                case .voice: voicePane
                case .capture: capturePane
                case .meeting: meetingPane
                case .presentation: PresentationMenuView(coordinator: environment.presentation, permissions: environment.permissions)
                case .recording: recordingPane
                case .agents: AgentMenuPane(coordinator: .shared)
                }
            }
        } footer: {
            footer
        }
    }

    private var voiceBusy: Bool {
        if AgentMonitorCoordinator.shared.voice.recording || AgentMonitorCoordinator.shared.voice.finishing { return true }
        switch environment.controller.phase {
        case .idle, .finished, .failed: return false
        default: return true
        }
    }

    private var isListening: Bool { environment.controller.phase == .listening }

    private var voiceTriggerName: String {
        switch environment.settings.triggerKey {
        case .fn: "Fn（🌐）"
        case .rightOption: "右 Option（⌥）"
        case .rightCommand: "右 Command（⌘）"
        case .rightControl: "右 Control（⌃）"
        }
    }

    private var voiceCardTitle: String {
        if environment.recording.selectionActive { return "正在准备屏幕录制" }
        if environment.recording.isBusy { return "屏幕录制进行中" }
        if environment.meeting.starting { return "正在准备录音转写" }
        if environment.meeting.finishingRecording { return "正在保存录音" }
        if environment.meeting.activeID != nil { return "会议录音中" }
        return switch environment.controller.phase {
        case .listening: "正在聆听"
        case .finalizing, .composing, .inserting: "正在处理语音"
        case .answering: "语音回答已就绪"
        default: "说出来，直接写入。"
        }
    }

    private var voiceCardDetail: String {
        if environment.recording.blocksOtherCapture { return "退出录制准备或结束录制后可继续使用语音输入。" }
        if environment.meeting.starting || environment.meeting.finishingRecording { return "录音准备和保存期间，语音输入会暂停。" }
        if environment.meeting.activeID != nil { return "结束会议录音后可继续使用语音输入。" }
        let trigger = voiceTriggerName
        if isListening { return "再按 \(trigger) 结束语音输入，按 Esc 取消本次。" }
        if voiceBusy { return "当前语音任务尚未结束，结束后即可截图。" }
        return "按 \(trigger) 开始说话，再按一次结束；文字会返回正在使用的应用。"
    }

    private var voicePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("语音输入")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            MenuBarFeatureCard(title: voiceCardTitle, detail: voiceCardDetail, active: isListening)
            if !environment.permissions.allRequiredGranted {
                Button("授予语音所需权限…") { environment.showOnboarding() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 11)
            }
            voiceHotkeyStatus
            Divider().padding(.vertical, 14)
            Text("语音偏好")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TranslateRow(
                enabled: Binding(
                    get: { environment.settings.translateEnabled },
                    set: { environment.settings.translateEnabled = $0 }
                ),
                target: Binding(
                    get: { environment.settings.translateTarget },
                    set: { environment.settings.translateTarget = $0 }
                )
            )
            .padding(.horizontal, -14)
            AccountRow(isSignedIn: environment.isSignedIn)
                .padding(.horizontal, -14)
            Divider().padding(.vertical, 8)
            RecentHistorySection(
                items: Array(environment.history.items.prefix(3)),
                hasMore: true,
                onCopy: { copy($0) },
                onCopyTranscript: { copy($0, useTranscript: true) },
                onDelete: { try? environment.history.delete(id: $0.id) },
                onClearAll: { try? environment.history.clear() },
                onShowAll: {
                    NotificationCenter.default.post(name: .prosioOpenSettingsHistoryTab, object: nil)
                    openSettings()
                }
            )
            .padding(.horizontal, -14)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var voiceHotkeyStatus: some View {
        switch environment.hotkeyStatus {
        case .ready: EmptyView()
        case .missingAccessibility:
            statusLine("辅助功能权限未开启，语音快捷键暂不可用。", buttonTitle: "打开设置") {
                environment.permissions.openSystemSettings(for: .accessibility)
            }
        case .tapDisabled:
            Text("语音快捷键暂不可用，正在恢复…")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 8)
        case .fnKeyConflict:
            statusLine("Fn 正由系统听写使用。", buttonTitle: "键盘设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func statusLine(_ message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(message).foregroundStyle(.orange)
            Button(buttonTitle, action: action).buttonStyle(.link)
        }
        .font(.system(size: 11))
        .padding(.top, 8)
    }

    private var capturePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if voiceBusy {
                MenuBarVoiceBusyBanner(isListening: isListening)
                    .padding(.bottom, 14)
            }
            Text("屏幕截图")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            MenuBarFeatureCard(
                title: "框选，标注，完成。",
                detail: "在冻结画面上直接标注，复制或保存后返回原应用。"
            )
            Divider().padding(.vertical, 14)
            Button { startCapture() } label: {
                Label("截图", systemImage: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 31)
            }
            .buttonStyle(.borderedProminent)
            .disabled(voiceBusy || environment.capture.isBusy || environment.recording.blocksOtherCapture)
            .accessibilityHint(voiceBusy ? "结束语音后可截图" : "框选屏幕并原地标注")
            if let hotkey = environment.capture.hotkey {
                HStack(spacing: 4) {
                    Text("快捷键：\(hotkey.shortcut == .off ? "已关闭" : hotkey.shortcut.label)")
                    Text("· 在设置中修改")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                if environment.settings.triggerKey == .rightControl,
                   hotkey.shortcut == .controlShift2 || hotkey.shortcut == .controlShift3 {
                    Text("截图使用左 Control；右 Control 用于语音。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
                if hotkey.conflictMessage != nil {
                    Text("截图快捷键不可用，请在设置中更换。")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 5)
                }
                if hotkey.shortcut == .optionEitherSide {
                    optionCaptureStatus
                        .font(.system(size: 11))
                        .padding(.top, 5)
                }
            }
            if environment.capture.isBusy {
                Button("取消截图") { environment.capture.cancel() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 8)
            }
            if let message = environment.capture.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
            }
            if !environment.permissions.screenCaptureGranted {
                Button("打开屏幕录制权限设置…") { environment.permissions.openScreenCaptureSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 8)
            }
            Divider().padding(.vertical, 14)
            HStack {
                Text("最近截图")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") { environment.capture.showLibrary() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            if environment.capture.store.assets.isEmpty {
                Text("还没有截图")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 11)
            } else {
                ForEach(environment.capture.store.assets.prefix(2)) { asset in
                    Button {
                        dismiss()
                        environment.capture.openEditor(asset)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.sourceName).lineLimit(1)
                                Text(asset.createdAt, style: .relative)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(voiceBusy || environment.capture.isBusy)
                }
            }
            if !environment.capture.drafts.assets.isEmpty {
                Button("恢复未完成截图（\(environment.capture.drafts.assets.count)）") {
                    environment.capture.showLibrary()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(.top, 7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var optionCaptureStatus: some View {
        switch environment.optionCaptureAvailability {
        case .ready: EmptyView()
        case .voiceKeyConflict:
            Text("语音已使用右 Option；请在设置中更改其中一个快捷键。")
                .foregroundStyle(.orange)
        case .needsAccessibility:
            Button("授予辅助功能权限…") { environment.permissions.openSystemSettings(for: .accessibility) }
                .buttonStyle(.link)
        case .needsInputMonitoring:
            Button("授予输入监控权限…") {
                Task { await environment.permissions.recoverInputMonitoring() }
            }
                .buttonStyle(.link)
        case .tapUnavailable:
            Button("键盘监听暂不可用 · 检查辅助功能权限…") { environment.permissions.openSystemSettings(for: .accessibility) }
                .buttonStyle(.link)
        }
    }

    private func startCapture() {
        dismiss()
        environment.capture.start(.region)
    }

    private var recordingPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if environment.recording.isBusy {
                RecordingControlView(coordinator: environment.recording, compact: true)
            } else {
                MenuBarFeatureCard(
                    title: "画面与声音，分别保存。",
                    detail: "屏幕、最多两个机位与独立音频，录完直接进入剪辑。"
                )
                Button {
                    dismiss()
                    environment.recording.showSelection()
                } label: {
                    Label("开始录制…", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(voiceBusy || environment.capture.isBusy || environment.meeting.activeID != nil || environment.meeting.starting || environment.meeting.finishingRecording)
            }
            if let message = environment.recording.message, !environment.recording.isBusy {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("最近录制").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") { dismiss(); environment.recording.showWindow() }
                    .buttonStyle(.link)
            }
            if environment.recording.store.sessions.isEmpty {
                Text("还没有录屏素材").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(environment.recording.store.sessions.prefix(3)) { session in
                Button {
                    dismiss()
                    environment.recording.showWindow(sessionID: session.id)
                } label: {
                    HStack {
                        Image(systemName: "video").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(.system(size: 12, weight: .medium))
                            Text(session.phase.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var meetingPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarFeatureCard(
                title: environment.meeting.activeID == nil ? "记录整场会议" : "正在录制会议",
                detail: "本机保存麦克风和系统声音；结束后生成文字及说话人标签。",
                active: environment.meeting.activeID != nil
            )
            if environment.meeting.activeID != nil {
                Button("结束录音并转写") { Task { await environment.meeting.stop() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("开始会议录音") { Task { await environment.meeting.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(environment.meeting.processing || environment.meeting.starting || voiceBusy || environment.recording.blocksOtherCapture || environment.capture.isBusy)
            }
            if environment.meeting.processing { ProgressView("正在生成本地文字与说话人…") }
            if environment.meeting.starting { ProgressView("正在准备实时字幕…") }
            if environment.meeting.activeID != nil {
                if !environment.meeting.liveSystemText.isEmpty {
                    Text("系统声音：\(environment.meeting.liveSystemText.suffix(180))")
                        .font(.system(size: 12)).lineLimit(4)
                }
                if !environment.meeting.liveMicrophoneText.isEmpty {
                    Text("麦克风：\(environment.meeting.liveMicrophoneText.suffix(180))")
                        .font(.system(size: 12)).lineLimit(4)
                }
            }
            if let message = environment.meeting.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle("结束后上传 Soniox 增强", isOn: Binding(
                get: { environment.meeting.cloudEnabled },
                set: { environment.meeting.cloudEnabled = $0 }
            ))
            .font(.system(size: 12))
            .disabled(!environment.isSignedIn)
            Text("关闭时仅在本机处理；云端失败也保留本地稿。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !environment.permissions.screenCaptureGranted {
                Button("开启屏幕录制权限以录入系统声音…") {
                    environment.permissions.requestScreenCapture()
                    environment.permissions.openScreenCaptureSettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Divider()
            HStack {
                Text("最近会议").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("查看全部") { dismiss(); environment.meeting.showLibrary() }
                    .buttonStyle(.link)
            }
            if environment.meeting.store.records.isEmpty {
                Text("还没有会议录音").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(environment.meeting.store.records.prefix(3)) { record in
                Button {
                    dismiss()
                    environment.meeting.showLibrary()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(.system(size: 12, weight: .medium))
                            Text(record.phase == .ready ? "本地文字已就绪" : record.phase == .recording ? "录音中" : record.phase == .processing ? "处理中" : "录音或转写中断")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func copy(_ item: HistoryItem, useTranscript: Bool = false) {
        let text = (useTranscript ? item.transcript : nil) ?? item.text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Button { environment.notes.show(); dismiss() } label: {
                    HStack { Label("便签", systemImage: "note.text"); Spacer(); Text(environment.notes.shortcut.selection.label).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).font(.system(size: 13))
                Button("便签设置…") {
                    openSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NotificationCenter.default.post(name: .prosioOpenSettingsNotesTab, object: nil)
                    }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(height: 26)
            Divider()
        HStack(spacing: 12) {
            SettingsLink { Text("设置…") }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
            Button("启动导引") { dismiss(); environment.showOnboarding() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
            Button("帮助") { showingHelp = true }
                .buttonStyle(.plain)
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 6) {
                        if selectedPane == .voice {
                            HowToUseSection(triggerKeySymbol: voiceTriggerName)
                                .environment(\.howToUseDefaultExpanded, true)
                        } else if selectedPane == .capture {
                            Text("屏幕截图")
                                .font(.system(size: 13, weight: .semibold))
                            Text("点击截图或使用当前快捷键，在冻结画面上框选并标注。复制或保存后返回原应用。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else if selectedPane == .presentation {
                            Text("演示与专注").font(.system(size: 13, weight: .semibold))
                            Text("在设置中调整下次会话预设。暂停视觉保留保活；急停清空按键。整屏共享后请在观众端确认浮层。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if selectedPane == .recording {
                            Text("屏幕录制").font(.system(size: 13, weight: .semibold))
                            Text("选择屏幕与最多两个机位，麦克风和系统声音独立保存。结束后可预览、裁剪导出，或将原片与项目交给剪辑软件。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if selectedPane == .agents {
                            Text("Agent 任务").font(.system(size: 13, weight: .semibold))
                            Text("菜单栏显示执行和待处理数量，点击任务查看详情。关闭详情窗口后继续监控；暂停监控可停止读取。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            Text("会议转写")
                                .font(.system(size: 13, weight: .semibold))
                            Text("开始录音后保持 Prosio 运行。结束后会在本机生成文字和说话人标签。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
                }
            Spacer()
            Menu {
                #if DEBUG
                Button("HUD 演示") { environment.hud?.showcase() }
                Divider()
                #endif
                Button("退出 Prosio") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        }

    }
}

// MARK: - How to use

/// Expanded by default until the user has completed 10 sessions (a rough proxy: history entries),
/// then collapsed — unless the user has explicitly toggled it themselves, in which case that
/// choice always wins from then on (remembered in `UserDefaults`/`@AppStorage`).
private struct HowToUseSection: View {
    var triggerKeySymbol: String

    @AppStorage("prosio.howToUseExpanded") private var expandedStored = true
    @AppStorage("prosio.howToUseHasUserOverride") private var hasUserOverride = false
    @Environment(\.howToUseDefaultExpanded) private var defaultExpanded

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            VStack(alignment: .leading, spacing: 10) {
                HowToRow(icon: "keyboard", title: "听写", example: "按 \(triggerKeySymbol) 开始说话，再按一次结束")
                HowToRow(icon: "pencil", title: "改写", example: "选中文字，再说出修改要求")
                HowToRow(icon: "sparkles", title: "提问", example: "说“提问，…”或直接提出问题")
                HowToRow(icon: "globe", title: "翻译", example: "说“翻译成英文：…”")
                HowToRow(icon: "square.and.pencil", title: "代写", example: "说“帮我回复他说明天可以…”")
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        } label: {
            Text("使用方法")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { hasUserOverride ? expandedStored : defaultExpanded },
            set: { newValue in
                hasUserOverride = true
                expandedStored = newValue
            }
        )
    }
}

/// Test seam: real usage reads live session history via `HowToUseDefaultExpandedKey`'s default
/// (`environment.history.items.count < 10`, wired in `MenuBarContentView`'s `.environment`
/// modifier below); previews can override it directly without needing a populated `HistoryStore`.
private struct HowToUseDefaultExpandedKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var howToUseDefaultExpanded: Bool {
        get { self[HowToUseDefaultExpandedKey.self] }
        set { self[HowToUseDefaultExpandedKey.self] = newValue }
    }
}

private struct HowToRow: View {
    var icon: String
    var title: LocalizedStringKey
    var example: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(example)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Translate row

/// Fixes the previous clipped/white toggle: an inline `Label` inside a `.switch`-style `Toggle`
/// at `.mini` size doesn't lay out cleanly. This uses `.small` with `.labelsHidden()` and a plain
/// leading `Text`, matching a normal settings-row layout.
private struct TranslateRow: View {
    @Binding var enabled: Bool
    @Binding var target: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("翻译为")
                .font(.system(size: 12))
            Picker("", selection: $target) {
                ForEach(TranslateLanguages.all) { language in
                    Text(language.shortCode).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            // Deliberately NOT disabled when off — the user should be able to pick a target
            // language before ever turning translation on, without it looking greyed-out/broken.
            Spacer()
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("语音输入时翻译")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Account

/// A single subtle row, shown only when signed out — nothing when signed in, per the redesign
/// (no persistent "signed in" chrome needed).
struct AccountRow: View {
    var isSignedIn: Bool

    var body: some View {
        if !isSignedIn {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("登录以启用云端润色")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Text("登录")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Recent (history)

struct RecentHistorySection: View {
    var items: [HistoryItem]
    var hasMore: Bool
    var onCopy: (HistoryItem) -> Void
    var onCopyTranscript: (HistoryItem) -> Void
    var onDelete: (HistoryItem) -> Void
    var onClearAll: () -> Void
    var onShowAll: () -> Void

    @State private var confirmClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近语音记录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button("清空") { confirmClearAll = true }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if items.isEmpty {
                Text("还没有语音记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HistoryRowView(item: item, onCopy: { onCopy(item) }, onCopyTranscript: { onCopyTranscript(item) }, onDelete: { onDelete(item) })
                    }
                }
                if hasMore {
                    Button("查看全部…", action: onShowAll)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.bottom, 4)
        .confirmationDialog("清空最近语音记录？", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("全部清空", role: .destructive, action: onClearAll)
            Button("取消", role: .cancel) {}
        }
    }
}

// `HistoryRowView` + `AppIconCache` live in `UI/Support/HistoryRowView.swift`, shared with
// Settings ▸ History.

extension Notification.Name {
    /// Posted by the menu bar's "Show all…" to ask `SettingsRootView` to switch to the History tab.
    static let prosioOpenSettingsHistoryTab = Notification.Name("prosio.openSettingsHistoryTab")
}

#if DEBUG
/// A pure preview of the shared native shell. It never constructs AppEnvironment.
private struct MenuBarPreviewScenario: View {
    @State var selectedPane: MenuBarPane
    let listening: Bool

    var body: some View {
        MenuBarShell(selectedPane: $selectedPane) { pane in
            VStack(alignment: .leading, spacing: 12) {
                if pane == .capture, listening {
                    MenuBarVoiceBusyBanner(isListening: true)
                }
                if pane == .voice {
                    MenuBarFeatureCard(
                        title: listening ? "正在聆听" : "说出来，直接写入。",
                        detail: listening ? "再次按 Fn 结束语音输入。" : "按 Fn 开始说话，再按一次结束。",
                        active: listening
                    )
                } else {
                    MenuBarFeatureCard(title: "框选，标注，完成。", detail: "在冻结画面上直接标注，复制或保存后返回原应用。")
                    Button("截图") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(listening)
                    Text(listening ? "结束语音后可截图" : "快捷键：⌃⇧2 · 在设置中修改")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        } footer: {
            HStack {
                Text("设置…")
                Text("帮助")
                Spacer()
                Text("更多")
            }
            .font(.system(size: 12))
        }
    }
}

#Preview("语音 · 待机") { MenuBarPreviewScenario(selectedPane: .voice, listening: false) }
#Preview("语音 · 聆听") { MenuBarPreviewScenario(selectedPane: .voice, listening: true) }
#Preview("截图 · 待机") { MenuBarPreviewScenario(selectedPane: .capture, listening: false) }
#Preview("截图 · 语音进行中") { MenuBarPreviewScenario(selectedPane: .capture, listening: true) }
#endif
