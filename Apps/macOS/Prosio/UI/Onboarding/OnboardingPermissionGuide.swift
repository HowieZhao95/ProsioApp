import Foundation

enum OnboardingPermission: String, Identifiable, CaseIterable {
    case microphone, accessibility, screenCapture, inputMonitoring
    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: "麦克风"
        case .accessibility: "辅助功能"
        case .screenCapture: "屏幕与系统音频录制"
        case .inputMonitoring: "输入监控"
        }
    }
    var purpose: String {
        switch self {
        case .microphone: "让 Prosio 听见你的声音。"
        case .accessibility: "将文字写入你正在使用的应用。"
        case .screenCapture: "用于截图、录屏与系统声音。"
        case .inputMonitoring: "让独立截图快捷键响应按键。"
        }
    }
    var settingsPath: String { "系统设置 → 隐私与安全性 → \(title)" }
    var missingAppHint: String {
        switch self {
        case .microphone: "没有 Prosio？先点「开启权限」，让系统显示申请。"
        case .accessibility, .screenCapture, .inputMonitoring:
            "没有 Prosio？点「＋」，选择「应用程序」中的 Prosio。"
        }
    }
    var kind: PermissionKind? {
        switch self {
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .screenCapture: nil
        case .inputMonitoring: .inputMonitoring
        }
    }
    func isGranted(statuses: [PermissionKind: PermissionStatus], screenCapture: Bool) -> Bool {
        if let kind { return statuses[kind] == .granted }
        return screenCapture
    }
}
