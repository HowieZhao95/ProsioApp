import SwiftUI

struct PresentationMenuView: View {
    let coordinator: PresentationCoordinator
    let permissions: PermissionsManager

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        return VStack(alignment: .leading, spacing: 12) {
            MenuBarFeatureCard(
                title: coordinator.state.privacyStopped ? "隐私暂停中" : coordinator.state.phase == .idle ? "让演示更清楚" : coordinator.state.phase == .paused ? "演示视觉已暂停" : "正在演示",
                detail: "突出鼠标、显示快捷组合，并保持屏幕亮着。结束会话后保留手动开启的功能。",
                active: coordinator.state.phase == .running && !coordinator.state.privacyStopped
            )
            HStack {
                if coordinator.state.phase == .idle {
                    Button("开始演示") { coordinator.begin() }.buttonStyle(.borderedProminent)
                } else {
                    Button("结束会话") { coordinator.end() }.buttonStyle(.bordered)
                    Button(coordinator.state.phase == .paused ? "恢复视觉" : "暂停视觉") {
                        if coordinator.state.phase == .paused { coordinator.resume() } else { coordinator.pause() }
                    }.buttonStyle(.bordered)
                }
            }
            module("鼠标高亮", status: coordinator.pointerStatus, enabled: Binding(get: { coordinator.pointerEnabled }, set: { coordinator.setPointer($0) }), owned: coordinator.state.sessionOwnsPointer)
            module("按键显示", status: coordinator.keysStatus, enabled: Binding(get: { coordinator.keysEnabled }, set: { coordinator.setKeys($0) }), owned: coordinator.state.sessionOwnsKeys)
            Picker("按键模式", selection: $preferences.keyDisplayMode) {
                ForEach(PresentationPreferences.KeyDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if preferences.keyDisplayMode == .allKeys {
                Text("全部按键会显示普通打字；敏感输入前请使用隐私急停。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("测试键帽（显示 3 秒）") { coordinator.previewKeycap() }
                .buttonStyle(.link).font(.system(size: 11))
                .disabled(!coordinator.state.visualsAllowed)
            if coordinator.keysEnabled {
                Button("检查 / 授予输入监控权限…") { Task { await permissions.recoverInputMonitoring() } }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            Divider()
            HStack {
                Text("屏幕保活").fontWeight(.medium)
                Spacer()
                Text(awakeStatus).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button("\(minutes)分") { coordinator.startManualAwake(minutes: minutes) }
                }
                Button("无限") { coordinator.startManualAwake(minutes: nil) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            if coordinator.awake.leases[.manual] != nil {
                HStack {
                    if coordinator.awake.remaining(.manual) != nil {
                        Button("追加 15 分钟") { coordinator.awake.extendManual(by: 900) }
                    }
                    Button("停止手动保活") { coordinator.awake.stop(.manual) }
                }.buttonStyle(.link)
            }
            if let error = coordinator.awake.error { Text(error).foregroundStyle(.orange) }
            if coordinator.awake.leases[.session] != nil {
                Text("会话保活持续到结束会话；停止手动保活不会影响它。")
                    .foregroundStyle(.secondary).font(.system(size: 11))
            }
            Divider()
            Button("隐私急停") { coordinator.privacyStop() }
                .buttonStyle(.bordered).tint(.red)
            if coordinator.state.privacyStopped {
                Button("明确恢复视觉") { coordinator.resume() }.buttonStyle(.link)
            }
            Text("急停立即清空按键并停止视觉监听，保活继续。锁屏或休眠会停止保活，解锁后需明确恢复视觉。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("观众通常需要整屏共享才能看到浮层；请先在观众端确认。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.bottom, 14)
    }
    private var awakeStatus: String {
        _ = coordinator.revision
        guard coordinator.awake.isActive else { return "关闭" }
        let manual: String
        if let remaining = coordinator.awake.remaining(.manual) {
            manual = "手动 \(Int(ceil(remaining / 60))) 分钟"
        } else { manual = "手动无限" }
        if coordinator.awake.leases[.manual] != nil {
            return manual + (coordinator.awake.leases[.session] != nil ? " · 会话" : "")
        }
        return "会话保活中"
    }
    private func module(_ title: String, status: String, enabled: Binding<Bool>, owned: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if owned {
                Text("会话启用").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Toggle(title, isOn: enabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

struct PresentationSettingsView: View {
    let coordinator: PresentationCoordinator
    @State private var sample = PresentationOverlayContent()
    var body: some View {
        @Bindable var preferences = coordinator.preferences
        @Bindable var coordinator = coordinator
        Form {
            Section("演示会话预设") {
                Toggle("鼠标高亮", isOn: $preferences.sessionPointer)
                Toggle("按键显示", isOn: $preferences.sessionKeys)
                Toggle("保持屏幕亮着，直到结束会话", isOn: $preferences.sessionAwake)
                Text("修改预设用于下次会话；结束当前会话保留手动开启的功能。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("外观 · 即时生效") {
                Picker("按键模式", selection: $preferences.keyDisplayMode) {
                    ForEach(PresentationPreferences.KeyDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("鼠标", selection: $preferences.pointerStyle) {
                    Text("轮廓 · 静止后隐藏").tag(PresentationPreferences.PointerStyle.ring)
                    Text("仅点击反馈").tag(PresentationPreferences.PointerStyle.clicksOnly)
                }
                Picker("强调色", selection: $preferences.accent) {
                    ForEach(PresentationPreferences.Accent.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Slider(value: $preferences.pointerSize, in: 32...100) { Text("轮廓大小 \(Int(preferences.resolvedPointerSize))") }
                Slider(value: $preferences.keyLinger, in: 0.5...3) { Text("释放后显示 \(preferences.resolvedKeyLinger, specifier: "%.1f") 秒") }
                HStack {
                    PointerHalo(content: sample, preferences: preferences).frame(width: 110, height: 100)
                    PresentationKeycap(content: sample, preferences: preferences).frame(height: 72)
                }.onAppear { sample.keyLabel = "⌘ ⇧ S"; sample.keyPressed = true }
                Text("模拟预览无需权限。键帽显示在鼠标所在屏幕底部；默认仅显示快捷组合，全部按键模式会显示普通打字。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私") {
                TextField("排除应用 Bundle ID（逗号分隔）", text: $coordinator.excludedBundleIDs)
                Text("例如 com.apple.Terminal。Prosio 自身与系统安全输入自动排除；无法识别所有网页敏感输入，请主动使用隐私急停。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("恢复演示默认设置") { preferences.reset() }
        }
        .formStyle(.grouped)
    }
}
