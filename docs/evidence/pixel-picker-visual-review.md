# 像素放大镜原生视觉验收

2026-09-28。目视检查 `/tmp/prosio-capture-loupe-native-evidence-20260928/` 六张合成证据：`synthetic-loupe-before-selection-light.png`、`synthetic-loupe-edge-light.png`、`synthetic-loupe-copy-feedback.png`、`synthetic-loupe-rgb-dark.png`、`synthetic-loupe-during-drag.png`、`synthetic-loupe-toolbar-avoidance.png`。均由实际 `CaptureEditingCanvas` 离屏绘制，底图为测试生成的冻结渐变像素，不含用户屏幕。

结论：通过。明暗浮层与既有柔和悬浮风格一致；11×11 网格中心像素标记明确。坐标、色块、HEX/RGB 数值和 C/Shift 提示清晰且互不相撞；“已复制颜色”反馈可读。右下角内收后浮层完整，拖选中持续可见，靠近工具栏时移至其上方，两者操作均未被遮挡。没有必须修的视觉问题。

原生 Canvas 测试 17/17 通过，纯逻辑测试 6/6 通过。截图仅证明合成像素与离屏状态；C 复制的实际写入行为由测试验证，不从静态图片推断真实系统剪贴板或屏幕捕获行为。
