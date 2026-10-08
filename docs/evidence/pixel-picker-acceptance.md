# 截图像素放大镜与取色

用户要求：截图过程中放大鼠标指向的位置，显示颜色并可复制；参考图包含坐标、RGB/HEX、C 复制和 Shift 切换。

验收目标：冻结原图像素采样，按原图左上角显示像素坐标，明确标记中心像素；浮层跟随鼠标并避边。框选前、自由拖选和选区边缘调整时显示，常规编辑隐藏。单独 C 复制颜色且不结束截图，单独轻按 Shift 切换格式，保留 Cmd+C 和文本输入行为。

实现：缓存一次 sRGB RGBA 原图；11×11 像素格与中心标记、坐标、色块、HEX/RGB、短时复制反馈。默认 HEX。浮层为 Canvas 绘制，不截获鼠标事件，明暗外观随编辑主题。

验收结果（2026-09-28）：
- 纯采样/格式/布局/键路由 6 项通过：`/tmp/prosio-loupe-pure-r1-20260928.xcresult`。
- 原生 Canvas 17 项通过：`/tmp/prosio-loupe-native-r1-20260928.xcresult`；复制使用注入 writer，未改系统剪贴板。覆盖 C、Shift、Cmd+C、文本输入、拖拽、边缘、工具栏避让及已有编辑行为。
- 合成 NSView 图片：`/tmp/prosio-capture-loupe-native-evidence-20260928/`。根代理目视浅色初始取色及暗色工具栏避让，信息完整、无重叠。合成图片不等同于外部应用实机截图。
- 签名构建成功、严格验签通过：`/tmp/prosio-picker-build/Build/Products/Debug/Prosio.app`。
- 已安装 `/Applications/Prosio.app`，旧版保留 `build/Prosio-before-pixel-picker-20260928.app`。18:15:09 新进程 PID 13721 启动，辅助功能/输入监控 granted，hotkey healthy=true。
- 安装与构建 SHA-256 一致：`42488251a6bce97a67cfbbfdcb760cb712001de20d88302f2402fbfd7294e7d9`。
