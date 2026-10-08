import AppKit
import SwiftUI

/// Synthetic content wrapped in the production MenuBarShell / FeatureCard / BusyBanner.
/// It is useful for visual checks of those shared components, but it is not a snapshot
/// of the live MenuBarContentView or the user's history/settings.
private struct SharedShellScenario: View {
    let pane: MenuBarPane
    let listening: Bool

    var body: some View {
        MenuBarShell(selectedPane: .constant(pane)) { selected in
            if selected == .voice { voiceContent } else { captureContent }
        } footer: {
            HStack(spacing: 12) {
                Text("设置…")
                Text("帮助")
                Spacer()
                Label("更多", systemImage: "ellipsis")
            }
            .font(.system(size: 12))
        }
        .tint(Color(red: 0.35, green: 0.52, blue: 0.89))
    }

    private var voiceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("语音输入")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            MenuBarFeatureCard(
                title: listening ? "正在聆听" : "说出来，直接写入。",
                detail: listening
                    ? "再按 Fn 结束语音输入，按 Esc 取消本次。"
                    : "按 Fn 开始说话，再按一次结束；文字会返回正在使用的应用。",
                active: listening
            )
            Divider().padding(.vertical, 14)
            Text("语音偏好")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("翻译至")
                Text("英语").foregroundStyle(.secondary)
                Spacer()
                Text("关闭").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.vertical, 12)
            Divider().padding(.vertical, 8)
            Text("最近语音")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("没有语音记录")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 11)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if listening {
                MenuBarVoiceBusyBanner(isListening: true)
                    .padding(.bottom, 14)
            }
            Text("屏幕截图")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            MenuBarFeatureCard(
                title: "框选，标注，完成。",
                detail: "在冻结画面上直接标注，复制或保存后返回原应用。"
            )
            Divider().padding(.vertical, 14)
            Button {} label: {
                Label("截图", systemImage: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 31)
            }
            .buttonStyle(.borderedProminent)
            .disabled(listening)
            Text(listening ? "结束语音后可截图" : "快捷键：⌃⇧2 · 在设置中修改")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Divider().padding(.vertical, 14)
            HStack {
                Text("最近截图")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("查看全部")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
            }
            Text("还没有截图")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 11)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

@main
@MainActor
struct MenuNativePreviewMain {
    static func main() throws {
        let directory = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for pane in MenuBarPane.allCases {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                try SnapshotRenderer.write(
                    SharedShellScenario(pane: pane, listening: false),
                    name: "shared-shell-\(pane == .voice ? "voice" : "capture")-\(suffix).png",
                    appearance: appearance,
                    output: directory
                )
            }
        }
        try SnapshotRenderer.write(
            SharedShellScenario(pane: .capture, listening: true),
            name: "shared-shell-capture-listening-dark.png",
            appearance: .darkAqua,
            output: directory
        )
    }
}
