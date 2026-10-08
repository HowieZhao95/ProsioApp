# 截图吸附：原生 Canvas 视觉验收

2026-09-28。四张 PNG 由 `Apps/macOS/ProsioTests/CaptureNativeCanvasTests.swift` 的宿主外测试生成：实际 `CaptureEditingCanvas` 绘制到离屏 `NSWindow`，测试向 `CaptureEditingSession` 注入带同一冻结快照 UUID 的窗口及内容块候选。底图为合成的两块高对比矩形，不含用户屏幕、网页文字或历史。此目录保存测试输出副本，原始输出在 `/tmp/prosio-capture-snapping-native-evidence-20260928/`。

目视复验：

- `synthetic-hover-window.png`：外层合成窗口被细蓝框和“窗口 480 × 320”标签预选；未产生选区。
- `synthetic-hover-content.png`：鼠标进入内部较小矩形后，预选切换到“可见内容块 160 × 110”，边框贴合内容块。
- `synthetic-drag-snap-guides.png`：`mouseDragged` 尚未松开时，右边及下边有蓝色吸附线；白色选区与八个手柄可见。
- `synthetic-click-content-toolbar.png`：单击内容块后生成对应选区，八个手柄和整条就地工具栏均留在 640 × 480pt Canvas 视口内，Copy/Save 等操作未被裁切。

目标原生 Canvas 与几何测试已通过（30 tests / 4 suites）；四图均为实际 Canvas 的离屏像素，不是 HTML 仿制。它们验证合成候选的显示与交互路径，**不**证明系统可识别任意网页 DOM 内容块，也不代表真实用户屏幕。此验收过程未安装或启动 Prosio.app、未请求系统截屏或麦克风权限。
