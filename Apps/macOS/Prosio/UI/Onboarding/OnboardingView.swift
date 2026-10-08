import AppKit
import ProsioCore
import SwiftUI

struct OnboardingView: View {
    let environment: AppEnvironment
    var onFinish: () -> Void
    var canvasSize: CGSize? = nil

    @State private var editor = OnboardingPracticeEditorState()
    @State private var mode: PracticeMode = .input
    @State private var settingsVisible = false
    @State private var permissionGuide: OnboardingPermission?
    @State private var permissionChecked = false
    @State private var requestingPermission = false
    @State private var accountVisible = false
    @State private var email = ""
    @State private var signingIn = false
    @State private var accountError: String?
    @State private var message: String?
    @State private var pointerBeforePractice: Bool?
    @State private var meetingStartedHere = false
    @State private var noteOpened = false
    @State private var captureCount = 0

    private var page: OnboardingPage { environment.onboarding.page }
    private var practicingVoice: Bool { PracticeTextRouting.isPractice(environment.controller.context) }
    private var voiceBusy: Bool {
        switch environment.controller.phase {
        case .idle, .finished, .failed: false
        default: true
        }
    }
    private var mediaBusy: Bool {
        environment.recording.blocksOtherCapture || environment.meeting.activeID != nil ||
        environment.meeting.starting || environment.meeting.finishingRecording || environment.capture.isBusy
    }

    var body: some View {
        OnboardingLayout(page: page, experienced: environment.onboarding.experienced,
                         navigate: navigate, later: finish, finish: finish, canvasSize: canvasSize) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    pageHeading
                    pageContent
                    if let message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, (canvasSize ?? OnboardingStyle.windowSize).width < 900 ? 32 : 46)
                .padding(.top, 42)
                .padding(.bottom, 28)
            }
        }
        .task {
            captureCount = environment.capture.store.assets.count
            while !Task.isCancelled {
                environment.permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: environment.capture.store.assets.map(\.id)) { _, ids in
            if ids.count > captureCount { environment.onboarding.markExperienced(.capture) }
            captureCount = ids.count
        }
        .onChange(of: environment.controller.phase) { _, phase in
            guard practicingVoice else { return }
            if case .finished(let outcome) = phase, outcome != .failed {
                environment.onboarding.markExperienced(.voice)
            }
        }
        .onDisappear { cleanUpPractice() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title == "Prosio · 开始使用" {
                cleanUpPractice()
            }
        }
        .popover(isPresented: $settingsVisible) { voiceSettings }
        .popover(isPresented: $accountVisible) { accountSettings }
        .sheet(item: $permissionGuide) { permission in
            permissionInstructions(permission)
        }
    }

    @ViewBuilder private var pageHeading: some View {
        switch page {
        case .voice:
            OnboardingHeading(title: "说出来，写下来。", detail: "输入、翻译、改写，开口即可。")
        case .capture:
            OnboardingHeading(title: "截下来，说明白。", detail: "框选、标注、复制，一气呵成。")
        case .notes:
            OnboardingHeading(title: "想到了，就记下。", detail: "灵感与待办，随手留在桌面。")
        case .tools:
            OnboardingHeading(title: "还有这些顺手的事。", detail: "录下来、讲清楚、看看任务进展。")
        case .ready:
            OnboardingHeading(title: "用得上时，就在这里。", detail: "点击菜单栏的 Prosio，继续你的工作。")
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .voice: voicePractice
        case .capture: capturePractice
        case .notes: notesPractice
        case .tools: toolsPractice
        case .ready: readyPractice
        }
    }

    private var voicePractice: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 24) {
                ForEach(PracticeMode.allCases) { item in
                    Button { changeMode(item) } label: {
                        VStack(spacing: 9) {
                            Text(item.title)
                                .font(.system(size: 14, weight: mode == item ? .semibold : .regular))
                                .foregroundStyle(mode == item ? OnboardingStyle.ink : Color.secondary)
                            Rectangle().fill(mode == item ? OnboardingStyle.accent : .clear).frame(height: 2)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                }
                Spacer()
            }
            .overlay(alignment: .bottom) { Rectangle().fill(OnboardingStyle.line).frame(height: 1).zIndex(-1) }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(mode.prompt).font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    if practicingVoice && environment.controller.phase == .listening {
                        OnboardingLevelView(levels: environment.controller.levelHistory)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 21)
                ZStack(alignment: .topLeading) {
                    if editor.text.isEmpty {
                        Text("文字会出现在这里")
                            .font(.system(size: 21)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 24).padding(.top, 20)
                            .allowsHitTesting(false)
                    }
                    OnboardingPracticeEditor(state: editor)
                }
                .frame(height: 174)
                HStack(spacing: 8) {
                    Text(practiceStatus).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !editor.text.isEmpty && !voiceBusy {
                        Button("清空") { editor.text = "" }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 13)
                .background(OnboardingStyle.canvas)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(OnboardingStyle.line))

            HStack(spacing: 16) {
                Button(voiceButtonTitle, action: toggleVoice)
                    .buttonStyle(OnboardingPrimaryButton())
                    .disabled((mediaBusy || voiceBusy) && !(practicingVoice && environment.controller.phase == .listening))
                Button("设置") { settingsVisible = true }
                    .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                Text("\(keyLabel) 开始 · 再按结束")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let issue = voiceIssue {
                HStack(spacing: 8) {
                    Text(issue).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button(environment.permissions.allRequiredGranted ? "调整" : "开启") { settingsVisible = true }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(OnboardingStyle.accent)
                }
            } else if !environment.isSignedIn {
                Button("登录以使用智能整理与翻译") { accountVisible = true }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var capturePractice: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingCaptureIllustration()
            HStack(spacing: 16) {
                Button("试着截一张") {
                    if environment.permissions.screenCaptureGranted { environment.capture.start(.region) }
                    else { showPermissionGuide(.screenCapture) }
                }
                    .buttonStyle(OnboardingPrimaryButton())
                    .disabled(voiceBusy || mediaBusy)
                if let hotkey = environment.capture.hotkey, hotkey.shortcut != .off {
                    Text(hotkey.shortcut.label).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !environment.permissions.screenCaptureGranted {
                permissionRow(title: "屏幕录制", detail: "用于获取截图", granted: false) {
                    showPermissionGuide(.screenCapture)
                }
            }
            if environment.capture.hotkey?.shortcut == .optionEitherSide,
               environment.permissions.statuses[.inputMonitoring] != .granted {
                permissionRow(title: "输入监控", detail: "用于独立截图快捷键", granted: false) {
                    showPermissionGuide(.inputMonitoring)
                }
            }
            if let captured = environment.capture.store.assets.first, environment.onboarding.experienced.contains(.capture) {
                Button("查看截图") { environment.capture.openEditor(captured) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(OnboardingStyle.accent)
            }
            if let reason = environment.capture.message {
                Text(reason).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var notesPractice: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingNotesIllustration()
            HStack(spacing: 16) {
                Button("打开便签") {
                    environment.notes.show()
                    noteOpened = true
                }.buttonStyle(OnboardingPrimaryButton())
                Button("保存位置") { environment.notes.chooseDirectory() }
                    .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                Text("无需权限").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            if noteOpened {
                Text(environment.notes.status).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .onChange(of: environment.notes.text) { _, text in
            if noteOpened && !text.isEmpty { environment.onboarding.markExperienced(.notes) }
        }
    }

    private var toolsPractice: some View {
        VStack(spacing: 0) {
            toolRow(symbol: "record.circle", title: "屏幕录制", detail: "记录操作，分享过程。", action: "试用") {
                if environment.permissions.screenCaptureGranted { environment.recording.showSelection() }
                else { showPermissionGuide(.screenCapture) }
            }
            Divider().overlay(OnboardingStyle.line)
            toolRow(symbol: "waveform", title: "录音转写", detail: "留下声音，回看文字。", action: meetingStartedHere && environment.meeting.activeID != nil ? "结束" : "试用") {
                let stopping = meetingStartedHere && environment.meeting.activeID != nil
                if !stopping {
                    guard !mediaBusy && !voiceBusy else { message = "请先结束当前录制。"; return }
                    guard environment.permissions.statuses[.microphone] == .granted else {
                        showPermissionGuide(.microphone); return
                    }
                    meetingStartedHere = true
                }
                Task {
                    if stopping {
                        await environment.meeting.stop()
                        meetingStartedHere = false
                        environment.onboarding.markExperienced(.tools)
                    } else {
                        await environment.meeting.start()
                        if !meetingStartedHere { await environment.meeting.stop() }
                        else { meetingStartedHere = environment.meeting.activeID != nil }
                    }
                }
            }
            if meetingStartedHere {
                Text(environment.meeting.liveMicrophoneText.isEmpty ? "录音中…" : environment.meeting.liveMicrophoneText)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
            Divider().overlay(OnboardingStyle.line)
            toolRow(symbol: "cursorarrow.rays", title: "演示辅助", detail: "突出光标，讲清重点。", action: pointerBeforePractice == nil ? "试用" : "结束") {
                if let previous = pointerBeforePractice {
                    environment.presentation.setPointer(previous)
                    pointerBeforePractice = nil
                } else {
                    pointerBeforePractice = environment.presentation.pointerEnabled
                    environment.presentation.setPointer(true)
                    environment.onboarding.markExperienced(.tools)
                }
            }
            Divider().overlay(OnboardingStyle.line)
            toolRow(symbol: "square.stack.3d.up", title: "Agent 任务", detail: "进展与待办，一眼知道。", action: "打开") {
                AgentMonitorCoordinator.shared.show()
            }
            if let reason = environment.meeting.message {
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
        }
    }

    private var readyPractice: some View {
        VStack(alignment: .leading, spacing: 30) {
            OnboardingMenuBarIllustration()
            VStack(spacing: 0) {
                readyRow("语音输入", ready: environment.permissions.allRequiredGranted && environment.hotkeyStatus == .ready)
                readyRow("屏幕截图", ready: environment.permissions.screenCaptureGranted)
                readyRow("桌面便签", ready: true)
            }
            Toggle("登录 Mac 时启动", isOn: Binding(get: { environment.launchAtLogin }, set: { environment.launchAtLogin = $0 }))
                .font(.system(size: 14)).toggleStyle(.switch).controlSize(.small)
            Text("没设置的，第一次使用时再开启。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func readyRow(_ title: String, ready: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            Text(ready ? "已就绪" : "稍后设置")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(.vertical, 13).overlay(alignment: .bottom) { OnboardingStyle.line.frame(height: 1) }
    }

    private func toolRow(symbol: String, title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 17) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
                .foregroundStyle(OnboardingStyle.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action, action: perform).buttonStyle(OnboardingSecondaryButton())
                .disabled(action != "结束" && (mediaBusy || voiceBusy))
        }.padding(.vertical, 18)
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("准备语音输入").font(.system(size: 21, weight: .semibold))
            VStack(spacing: 0) {
                permissionRow(title: "麦克风", detail: "听见你的声音", granted: environment.permissions.statuses[.microphone] == .granted) {
                    showPermissionGuide(.microphone)
                }
                Divider()
                permissionRow(title: "辅助功能", detail: "写入当前应用", granted: environment.permissions.statuses[.accessibility] == .granted) {
                    showPermissionGuide(.accessibility)
                }
            }
            HStack {
                Text("快捷键").font(.system(size: 14))
                Spacer()
                Picker("快捷键", selection: Binding(get: { environment.settings.triggerKey }, set: {
                    environment.settings.triggerKey = $0
                    environment.hotkey?.resetCaptureOptionGesture()
                })) {
                    ForEach(TriggerKey.allCases, id: \.self) { Text(label(for: $0)).tag($0) }
                }.labelsHidden().frame(width: 135)
                .disabled(voiceBusy)
            }
            if environment.settings.triggerKey == .fn {
                HStack(alignment: .top, spacing: 12) {
                    Text("Fn 系统动作设为「不执行任何操作」。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("键盘设置") { openKeyboardSettings() }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(OnboardingStyle.accent)
                }
            } else if environment.settings.triggerKey == .rightOption && environment.capture.hotkey?.shortcut == .optionEitherSide {
                Text("右 Option 与截图快捷键重复，请更换其中一个。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !environment.isSignedIn {
                Button("登录智能服务") { settingsVisible = false; accountVisible = true }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(OnboardingStyle.accent)
            }
            Button("完成") { settingsVisible = false; editor.focus() }.buttonStyle(OnboardingPrimaryButton())
        }.padding(28).frame(width: 370)
    }

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("智能服务").font(.system(size: 21, weight: .semibold))
            if environment.isSignedIn {
                Text(environment.signedInEmail ?? "已登录").font(.system(size: 14)).foregroundStyle(.secondary)
                Button("完成") { accountVisible = false }.buttonStyle(OnboardingPrimaryButton())
            } else {
                Text("用于整理、翻译与改写。").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("邮箱", text: $email).textFieldStyle(.roundedBorder).onSubmit(signIn)
                if let accountError { Text(accountError).font(.system(size: 12)).foregroundStyle(.secondary) }
                Button(signingIn ? "登录中…" : "登录", action: signIn)
                    .buttonStyle(OnboardingPrimaryButton()).disabled(signingIn || email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 340)
    }

    private func permissionRow(title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("已开启").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Button("开启", action: request).buttonStyle(OnboardingSecondaryButton())
            }
        }.padding(.vertical, 12)
    }

    private var keyLabel: String { label(for: environment.settings.triggerKey) }
    private func label(for key: TriggerKey) -> String {
        switch key { case .fn: "Fn"; case .rightCommand: "右 ⌘"; case .rightOption: "右 ⌥"; case .rightControl: "右 ⌃" }
    }
    private var voiceIssue: String? {
        if !environment.permissions.allRequiredGranted { return "先开启麦克风与辅助功能。" }
        switch environment.hotkeyStatus {
        case .fnKeyConflict: return "Fn 与系统动作冲突。"
        case .tapDisabled: return "快捷键正在恢复，可先点击试用。"
        case .missingAccessibility: return "辅助功能尚未开启。"
        case .ready: return nil
        }
    }
    private var voiceButtonTitle: String {
        if practicingVoice && environment.controller.phase == .listening { return "结束说话" }
        if practicingVoice && voiceBusy { return "处理中…" }
        return environment.permissions.allRequiredGranted ? "试着说一句" : "设置并体验"
    }
    private var practiceStatus: String {
        guard practicingVoice else { return "练习区" }
        switch environment.controller.phase {
        case .listening: return environment.controller.previewText.isEmpty ? "正在聆听…" : environment.controller.previewText
        case .finalizing, .composing, .inserting: return "正在处理…"
        case .finished(let outcome): return outcome == .copiedToClipboard ? "已复制，可粘贴到这里" : "已写入"
        case .failed(let error):
            switch error {
            case .notSignedIn: return "请先登录智能服务。"
            case .emptyTranscript: return "没听清，再试一次。"
            case .microphonePermissionDenied: return "请开启麦克风。"
            case .network: return "服务暂不可用，请重试。"
            case .cancelled: return "已取消"
            default: return "未完成，请重试。"
            }
        default: return "练习区"
        }
    }

    private func changeMode(_ value: PracticeMode) {
        guard !voiceBusy else { return }
        mode = value
        if value == .edit && editor.text.isEmpty { editor.text = "我们明天下午三点召开会议，一起讨论新方案，请大家记得参加。" }
        editor.focus(selectAll: value == .edit)
    }
    private func toggleVoice() {
        if practicingVoice && environment.controller.phase == .listening { environment.controller.stop(); return }
        guard !voiceBusy && !mediaBusy else { return }
        guard environment.permissions.allRequiredGranted else { settingsVisible = true; return }
        if mode != .input && !environment.isSignedIn { accountVisible = true; return }
        editor.focus(selectAll: mode == .edit)
        if mode == .translate {
            // Use the spoken one-off translate instruction; persistent translation preferences
            // remain the user's own, and the hotkey exercises the same production route.
            message = "说「翻译成英文」，再接上你的内容。"
        } else { message = nil }
        guard let target = editor.textView, target.practiceAvailable else { return }
        environment.focus.withPracticeTarget(target) {
            environment.controller.start(trigger: .toggle, intent: mode == .edit ? .edit : nil)
        }
    }
    private func showPermissionGuide(_ permission: OnboardingPermission) {
        settingsVisible = false
        permissionChecked = false
        permissionGuide = permission
    }

    private func permissionInstructions(_ permission: OnboardingPermission) -> some View {
        let granted = permission.isGranted(statuses: environment.permissions.statuses,
                                           screenCapture: environment.permissions.screenCaptureGranted)
        return VStack(alignment: .leading, spacing: 24) {
            OnboardingHeading(title: "开启\(permission.title)", detail: permission.purpose)
            VStack(alignment: .leading, spacing: 18) {
                permissionStep("1", "打开系统设置", detail: permission.settingsPath)
                permissionStep("2", "开启 Prosio", detail: "找到 Prosio，打开右侧开关；按系统提示验证。")
                permissionStep("3", "返回这里", detail: "若系统要求退出并重新打开，请照做。导引会保留进度。")
            }
            Text(permission.missingAppHint).font(.system(size: 12)).foregroundStyle(.secondary)
            if granted {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(OnboardingStyle.accent)
            } else if permissionChecked {
                Text("尚未检测到。确认已开启 Prosio；必要时退出并重新打开。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                if granted {
                    Button("返回体验") { permissionGuide = nil; editor.focus() }
                        .buttonStyle(OnboardingPrimaryButton())
                } else {
                    Button(requestingPermission ? "等待系统…" : permission == .microphone && environment.permissions.statuses[.microphone] == .notDetermined ? "开启权限" : "打开系统设置") {
                        requestPermission(permission)
                    }.buttonStyle(OnboardingPrimaryButton()).disabled(requestingPermission)
                    Button("我已开启") { environment.permissions.refresh(); permissionChecked = true }
                        .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(OnboardingStyle.accent)
                }
                Spacer()
                Button("稍后") { permissionGuide = nil }.buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(32).frame(width: 550)
    }
    private func permissionStep(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 13)).monospacedDigit().foregroundStyle(OnboardingStyle.accent)
                .frame(width: 25, height: 25).background(OnboardingStyle.selected, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func requestPermission(_ permission: OnboardingPermission) {
        guard !requestingPermission else { return }
        requestingPermission = true
        Task {
            defer { requestingPermission = false }
            if let kind = permission.kind {
                if kind == .microphone && environment.permissions.statuses[kind] == .denied {
                    environment.permissions.openSystemSettings(for: kind)
                } else {
                    await environment.permissions.request(kind)
                    if environment.permissions.statuses[kind] != .granted {
                        environment.permissions.openSystemSettings(for: kind)
                    }
                }
            } else {
                environment.permissions.requestScreenCapture()
                if !environment.permissions.screenCaptureGranted { environment.permissions.openScreenCaptureSettings() }
            }
        }
    }
    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func signIn() {
        guard !signingIn else { return }
        signingIn = true; accountError = nil
        Task {
            defer { signingIn = false }
            do { try await environment.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines)); accountVisible = false }
            catch { accountError = "登录未完成，请检查邮箱与服务连接。" }
        }
    }
    private func navigate(_ target: OnboardingPage) {
        guard !voiceBusy || !practicingVoice else { message = "请先结束说话。"; return }
        guard !meetingStartedHere else { message = "请先结束录音。"; return }
        if let previous = pointerBeforePractice { environment.presentation.setPointer(previous); pointerBeforePractice = nil }
        environment.onboarding.select(target)
        message = nil
    }
    private func finish() {
        cleanUpPractice()
        environment.onboarding.dismiss()
        onFinish()
    }
    private func cleanUpPractice() {
        if practicingVoice && voiceBusy { environment.controller.cancel() }
        if let previous = pointerBeforePractice { environment.presentation.setPointer(previous); pointerBeforePractice = nil }
        if meetingStartedHere {
            meetingStartedHere = false
            Task { await environment.meeting.stop() }
        }
    }
}

private enum PracticeMode: Int, CaseIterable, Identifiable {
    case input, translate, edit
    var id: Int { rawValue }
    var title: String { switch self { case .input: "输入"; case .translate: "翻译"; case .edit: "改写" } }
    var prompt: String {
        switch self {
        case .input: "试着说：明天下午四点见。"
        case .translate: "试着说：翻译成英文，我们明天下午见。"
        case .edit: "选中文字，再说：简短一点。"
        }
    }
}

struct OnboardingLayout<Content: View>: View {
    let page: OnboardingPage
    let experienced: Set<OnboardingPage>
    var navigate: (OnboardingPage) -> Void
    var later: () -> Void
    var finish: () -> Void
    var canvasSize: CGSize? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 205)
            OnboardingStyle.line.frame(width: 1)
            VStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                navigation
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: (canvasSize ?? OnboardingStyle.windowSize).width,
               height: (canvasSize ?? OnboardingStyle.windowSize).height)
        .tint(OnboardingStyle.accent)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .medium))
                Text("Prosio").font(.system(size: 19, weight: .semibold))
            }.padding(.leading, 24).padding(.top, 31).padding(.bottom, 42)
            Text("开始探索").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.leading, 24).padding(.bottom, 15)
            VStack(spacing: 5) {
                ForEach(OnboardingPage.allCases) { item in
                    Button { navigate(item) } label: {
                        HStack(spacing: 13) {
                            Text(item.number).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(page == item ? OnboardingStyle.accent : Color.secondary.opacity(0.75))
                            Text(item.title).font(.system(size: 14, weight: page == item ? .medium : .regular))
                            Spacer()
                            if experienced.contains(item) {
                                Image(systemName: "checkmark").font(.system(size: 10)).accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(page == item ? OnboardingStyle.ink : Color.secondary)
                        .padding(.horizontal, 13).frame(height: 42)
                        .background(page == item ? OnboardingStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                        .accessibilityValue(experienced.contains(item) ? "已体验" : "")
                }
            }.padding(.horizontal, 12)
            Spacer()
            Button("稍后设置", action: later).buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.leading, 25).padding(.bottom, 27)
        }.background(OnboardingStyle.sidebar)
    }
    private var navigation: some View {
        VStack(spacing: 0) {
            OnboardingStyle.line.frame(height: 1)
            HStack {
                if let previous = OnboardingPage(rawValue: page.rawValue - 1) {
                    Button { navigate(previous) } label: { Label("上一步", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if let next = OnboardingPage(rawValue: page.rawValue + 1) {
                    Button { navigate(next) } label: { HStack(spacing: 10) { Text("下一步"); Image(systemName: "chevron.right").font(.system(size: 10)) } }
                        .buttonStyle(OnboardingPrimaryButton()).keyboardShortcut(.defaultAction)
                } else {
                    Button("开始使用", action: finish).buttonStyle(OnboardingPrimaryButton()).keyboardShortcut(.defaultAction)
                }
            }.padding(.horizontal, (canvasSize ?? OnboardingStyle.windowSize).width < 900 ? 32 : 46).frame(height: 81)
                .overlay {
                    Text("\(page.rawValue + 1) / \(OnboardingPage.allCases.count)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct OnboardingHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 35, weight: .semibold)).tracking(-1.1)
            Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}

enum OnboardingStyle {
    static var windowSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1100, height: 800)
        return CGSize(width: max(720, min(1000, available.width - 48)),
                      height: max(540, min(650, available.height - 72)))
    }
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.65, green: 0.73, blue: 0.88, alpha: 1)
            : NSColor(red: 0.29, green: 0.36, blue: 0.52, alpha: 1)
    })
    static let buttonInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.12, green: 0.15, blue: 0.21, alpha: 1) : .white
    })
    static let ink = Color.primary
    static let line = Color.primary.opacity(0.085)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color.primary.opacity(0.025)
    static let selected = Color.primary.opacity(0.055)
}

struct OnboardingPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(OnboardingStyle.buttonInk)
            .padding(.horizontal, 20).frame(height: 40)
            .background(OnboardingStyle.accent.opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct OnboardingSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).foregroundStyle(OnboardingStyle.accent)
            .padding(.horizontal, 14).frame(height: 32)
            .background(OnboardingStyle.selected.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}
struct OnboardingLevelView: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.suffix(12).enumerated()), id: \.offset) { _, value in
                Capsule().fill(OnboardingStyle.accent).frame(width: 3, height: 3 + CGFloat(value) * 19)
            }
        }.frame(height: 22).accessibilityLabel("麦克风输入音量")
    }
}

struct OnboardingCaptureIllustration: View {
    var body: some View {
        ZStack {
            Color.primary.opacity(0.025)
            VStack(alignment: .leading, spacing: 17) {
                Text("明天下午四点").font(.system(size: 23, weight: .medium))
                Text("一起讨论新方案。").font(.system(size: 16)).foregroundStyle(.secondary)
                HStack(spacing: 17) {
                    ForEach(["pencil.tip", "rectangle", "arrow.up.right", "textformat", "checkmark"], id: \.self) { symbol in
                        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(OnboardingStyle.accent)
                    }
                }.padding(.top, 12)
            }
            .frame(width: 340, alignment: .leading).padding(28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(OnboardingStyle.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topLeading) { Text("操作示意").font(.system(size: 12)).foregroundStyle(.secondary).padding(17) }
    }
}
struct OnboardingNotesIllustration: View {
    var body: some View {
        ZStack {
            OnboardingStyle.canvas
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("今天").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("先记下来，\n慢慢想明白。").font(.system(size: 25, weight: .regular)).lineSpacing(9)
                HStack(spacing: 10) { Image(systemName: "circle").font(.system(size: 12)); Text("一个值得做的想法").font(.system(size: 14)) }.foregroundStyle(.secondary)
            }.frame(width: 330, alignment: .leading).padding(25)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OnboardingStyle.line))
                .shadow(color: .black.opacity(0.035), radius: 16, y: 8)
        }.frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topLeading) { Text("便签示意").font(.system(size: 12)).foregroundStyle(.secondary).padding(17) }
    }
}
struct OnboardingMenuBarIllustration: View {
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 20) {
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
                Image(systemName: "waveform").font(.system(size: 19, weight: .medium))
                    .foregroundStyle(OnboardingStyle.accent)
                    .padding(8).background(OnboardingStyle.selected, in: RoundedRectangle(cornerRadius: 7))
                Text("Prosio").font(.system(size: 13, weight: .medium))
            }.padding(.horizontal, 25).frame(height: 58)
                .background(OnboardingStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
            Text("语音与屏幕，随手可用。")
                .font(.system(size: 16)).foregroundStyle(.secondary)
        }.padding(.vertical, 20)
    }
}
