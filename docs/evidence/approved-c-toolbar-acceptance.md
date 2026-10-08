# 已选 C 工具栏原生对齐

用户反馈：原生截图工具栏没有采用已选 C 柔和悬浮原型，并要求单行、能用图标的操作不显示文字，主题与颜色调整不放在截图工具栏。

依据：`design-demos/capture/direction-approved.md`、`c-inline-light.png` 和 `c-inline-dark.png`。原生工具栏现为浅/深两套胶囊浮层，常用选区、矩形、箭头、文字、画笔、像素化、撤销/重做、复制、保存、退出单行排列；椭圆、高亮、纯色遮挡、模糊保留在“更多”菜单。复制为醒目的圆形图标。工具栏没有主题、颜色、线宽调整；截图外观设置在应用的“设置 → Screenshot”。已选方向要求的八手柄、边界避让和底图不随主题变色继续保留；用户之后要求的蓝色选区边框优先于原型中的暖灰边框。

2026-09-28 验收：
- 原生 Canvas 18 项测试通过、零失败，包含单行高度（≤54pt）、工具变更不增高、浅深主题底图一致、窄窗口浮层留屏及既有复制/拖选交互：`/tmp/prosio-approved-c-native-r3-20260928.xcresult`。
- 目视检查实际 NSView 合成截图 `docs/evidence/capture-m2/synthetic-native/synthetic-native-light.png` 和 `synthetic-native-dark.png`：单行胶囊、分组线、主复制按钮与已选 C 原型结构一致。截图底图为合成颜色，不是外部应用实景。
- 签名构建 `/tmp/prosio-approved-c-toolbar-build/Build/Products/Debug/Prosio.app` 通过严格验签；已安装 `/Applications/Prosio.app`，旧版保留 `build/Prosio-before-approved-c-toolbar-20260928.app`。
- 新进程 PID 22542 于 19:06:03 启动，辅助功能/输入监控 granted，快捷键监听 healthy=true。安装与构建 SHA-256 一致：`8fcede52cd9edd9a532dda4fb71bb939114ca650bc38e3fab8274c51f85101df`。
