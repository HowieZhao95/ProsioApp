# 默认全屏预选与双击复制

用户要求：无明确内容候选时默认整屏预选；单击确认当前预选；双击复制退出；未确认前直接拖动使用新的截图框。

交互约定：候选优先，否则当前显示器整图。预选不是已确认裁剪，5pt 拖动阈值前保留预选，超过后自由框选。双击沿现有复制输出流程，成功后退出；文字标注双击编辑仍保留。

2026-09-28 最终验收：
- 原生 Canvas 定向回归 18 项，零失败、零跳过：`/tmp/prosio-click-native-r2-20260928.xcresult`。真实 down/up 两次点击事件序列验证候选/整屏输出范围、仅一次 copy 和 finish；底部确认点不被工具栏覆盖且 hitTest 命中 Canvas，边角第二击不误触 resize。自由拖选、放大镜及文字编辑回归通过。复制使用测试输出接口，未写真实剪贴板。
- 根代理目视合成图 `synthetic-single-click-full-display.png`：底部确认后工具栏置顶，整屏裁剪边界与手柄完整。证据目录 `/tmp/prosio-capture-snapping-native-evidence-20260928/`。
- 签名构建成功、严格验签通过：`/tmp/prosio-snipaste-flow-build/Build/Products/Debug/Prosio.app`。已安装 `/Applications/Prosio.app`，旧版备份 `build/Prosio-before-snipaste-flow-20260928.app`。
- 18:30:15 新进程 PID 16119 启动，辅助功能与输入监控 granted，快捷键监听 healthy=true。
- 安装与构建 SHA-256 相同：`4dd8cd6ed76c58d3a0355ffd6bcbf172ffc5b5862185cad9a1d0ec2597260a19`。

限制：本轮为合成原图和原生事件回归，不代表已逐一实测外部应用的内容识别。
