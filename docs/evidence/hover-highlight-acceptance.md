# 悬停亮起与单击框选验收

2026-09-28：未建立选区时，悬停已识别的内容块或窗口会恢复该区域原画面亮度，外部保留柔和遮罩，完整蓝色外框预览；按下至 5pt 拖动阈值前保留预选，单击选择整个候选。明确拖动进入自由框选，继续复用外边界吸附。已建立选区后不因悬停其他候选而切换选区。

- 15 项 Canvas 测试通过，零失败：`/tmp/prosio-hover-tests-r2-20260928.xcresult`。
- 根代理目视确认合成 NSView 图片 `/tmp/prosio-capture-snapping-native-evidence-20260928/synthetic-hover-full-frame.png`：完整蓝框、内部原画面亮度、外部遮罩。
- 签名构建及安装严格验签通过。安装位置 `/Applications/Prosio.app`，旧版备份 `build/Prosio-before-hover-highlight-20260928.app`。
- 17:36:44 启动 PID 9904；辅助功能、输入监控 granted，快捷键监听 healthy=true。
- 安装与构建二进制 SHA-256：`74ce6c8fa59b7fbae82a8b2171661224aaa344491ae1f7f6be2ebb56adeaa63d`。

范围：这次验证候选的呈现与交互，不新增任意网页 DOM 读取能力；识别覆盖仍受系统可访问性与画面检测能力限制。图片为合成底图，不是外部应用实测证据。
