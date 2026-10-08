# Prosio 菜单 B「标签切换」独立验收

日期：2026-09-28。状态：独立静态审查及最终签名构建核对完成；真实菜单交互待验。

依据：`design-demos/menu-hierarchy/spec.md`、选定 B 原型、现有 `MenuBarContentView.swift`、`AppEnvironment`、`CaptureCoordinator`、快捷键/权限/语音与截图历史接口。本文只记录菜单整合验收，不把原型或编译当作实际权限/UI 通过。

## 验收要点

| 范围 | 需要确认 |
| --- | --- |
| 信息架构 | 顶部「语音输入 / 屏幕截图」等宽切换；当前页只显示对应动作、偏好与记录；截图只有一个区域截图入口，不能回退到区域/窗口/显示器的分类菜单。切换不改变正在进行的语音会话。 |
| 语音页 | Fn 使用说明与当前触发键一致；聆听/处理状态明确归语音。翻译绑定现有 `AppSettings.translateEnabled/translateTarget`；说明、语音历史、登录提示与语音权限/快捷键故障恢复仍可达。不要添加无法工作的“开始录音”按钮。 |
| 截图页 | 单一截图动作调用现有 `CaptureCoordinator.start(.region)`；Ctrl-Shift-2（或用户设置值/Off）显示正确；快捷键冲突与修改入口仍可达。语音活动时截图按钮禁用且原因可见；语音权限缺失不能成为截图总开关；屏幕权限缺失有可行恢复入口。 |
| 历史 | 语音记录走现有 `HistoryStore`，复制/删除/清空及「查看全部」仍可达；截图记录走 `CaptureAssetStore`/素材窗口，可打开并复用编辑，不把两类记录混为一个 JSON。空列表状态明确。 |
| Footer | 设置、帮助、更多及退出有明确入口；开发调试不占正常菜单。键盘操作、辅助功能标签、浅/深色及缩小屏幕高度下标题/切换/页脚可见。 |
| 回归 | 主 App target 通过最终签名构建；已稳定的 hostless ProsioTests/语音/Core 测试不因仅菜单改动无故重跑。不得启动、安装或终止用户应用，不改 TCC。 |

## 审查结论

| 项目 | 只读检查结果 |
| --- | --- |
| 两页及主动作 | `MenuBarShell` 以等宽 SwiftUI Button 实现「语音输入 / 屏幕截图」切换，并为选中项添加辅助功能状态；仅截图页的单个按钮调用 `capture.start(.region)`，没有模式菜单。菜单内容滚动、footer 固定，宽 352pt，最大高度按可见屏幕限制。|
| 语音归属 | 聆听、处理及回答状态位于语音卡；截图页在语音忙时显示语音横幅，截图按钮和最近截图重开按钮均禁用。语音卡是说明，不伪装成录音启动按钮；当前右侧 Option/Command/Control 键名现明确写“右”。|
| 语音功能 | 翻译开关和目标语言仍绑定现有 `AppSettings`，未复制状态。说明在 footer「帮助」内；登录入口、语音权限/热键故障入口保留。最近语音记录沿用原 `HistoryRowView` 的复制、复制原话、删除及清空回调，超过三项时有「查看全部」。|
| 截图功能 | 截图页仍有当前快捷键/关闭状态、冲突提示、取消、错误消息、屏幕录制权限入口、最近截图/查看全部及草稿恢复入口。快捷键 Picker 已迁至 `GeneralSettingsView`，在 `AppEnvironment.launch()` 创建热键对象后可用；设置中仍可选择关闭或另一个组合。截图权限由 `screenCaptureGranted` 单独判断，没有被语音权限总状态挡住。|
| 外观和本地化 | 新 shell 使用系统材质、语义色及原生分段 Picker，没有写死深色背景；静态上具备浅/深色适配。`HistoryRowView` 源码中的 Copy / Copy What I Said / Delete / Copied 均有 `Localizable.xcstrings` 的简体中文翻译，英文源码不构成实际显示缺陷。|
| 构建与变更检查 | 最终布局相关源码修改时间为 14:26:42；实施者的签名 App 构建 `/tmp/prosio-menu-tabs-build-final5.log` 于 14:27 报 `BUILD SUCCEEDED`，覆盖该版源码。独立 `git diff --check` 无空白错误。|

## 待实机确认

- 两个等宽切换按钮在真实菜单中的视觉、浅/深色的对比度，以及低屏高时标题、切换和 footer 是否始终可见。当前只做源码布局检查，未启动或安装 Prosio，也未将纯 SwiftUI 预览当成完整菜单验收。
- 首次点击语音「查看全部…」时，代码先发 `prosioOpenSettingsHistoryTab` 通知，再 `openSettings()`；如果设置视图此前未挂载，通知可能错过。该顺序与改版前一致，列为既存实机待核对，不推断它一定失败。
- 真正的屏幕权限、Carbon 截图热键冲突、语音活动时菜单刷新、焦点恢复、最近截图重开及 VoiceOver 操作需在签名应用中交互确认；本轮没有修改 TCC，也没有触碰用户正在运行的应用。

本轮未增加菜单测试目标或重跑 88 项截图编辑测试：三个菜单/设置文件没有 hostless 测试注入点，且截图模型、语音/Core 生产逻辑未因排版改动而更改。之前 M2 的 88 项 hostless 测试及 32 项语音/Core 回归结果见 `docs/evidence/capture-m2/independent-test-report.md`，它们不构成本轮菜单 UI 的运行时证明。

## 主任务安装与进程核对

- 最终 final5 签名构建通过，主任务再次验证 `codesign --verify --deep --strict`。
- 正常请求旧应用退出后确认旧进程结束；未使用 force kill。
- 旧版本保留在 `build/Prosio-before-menu-tabs-20260928.app`。
- 新版本安装到 `/Applications/Prosio.app` 并重启；新 PID 为 99906。
- 已安装可执行文件与最终构建的 SHA-256 均为 `d1192166c3747ab244949a4f685cc342aa1db9d6e3751dcae958985c2ee2698a`。
- 原生共用 Shell/FeatureCard/BusyBanner 的离屏截图由主任务目视确认两标签等宽满行；示例正文并非完整运行菜单。此轮未重新执行真实语音、截图或系统权限交互。
