# 菜单原生共享组件快照

运行 `zsh render.sh`，使用 SwiftUI + AppKit 离屏渲染生产文件 `MenuBarShell.swift` 中的 `MenuBarShell`、`MenuBarFeatureCard`、`MenuBarVoiceBusyBanner`，输出 `images/shared-shell-*.png`。不安装、启动或重启 Prosio.app；不创建 `AppEnvironment`、读取历史或请求麦克风/截屏权限。图片中的正文和底栏由 `PreviewMain.swift` 提供固定、非用户数据，仅用于检视共享组件在语音页、截图页、聆听中及明暗外观下的版式。

这些图片**不能证明** `MenuBarContentView` 中依赖 `AppEnvironment` 的完整正文、实际快捷键状态、历史与交互。离屏窗口处于非激活状态，系统强调色按钮的颜色也可能与真实激活的菜单不同。真实菜单的完整验收需在安全的专用运行环境中进行。

已渲染：语音页深/浅、截图页深/浅、截图页聆听中深色。每张图片的像素宽度 720（360pt × 2），由实际系统字体和 SF Symbols 绘制。
