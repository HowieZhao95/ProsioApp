# 已选 C · 原型验收

2026-09-27。用户选定 C，方向与原话见 direction-approved.md。当前入口 index.html，主要真实截图 c-inline-light.png / c-inline-dark.png / index.png。

## 已验证

- 裁剪及调整按钮已删除；八手柄分别使用真实指针拖动，四边与四角均改变对应几何。选中工具后拖动绘制矩形；Esc 后拖内部移动，语义明确。
- 内部决策列表块吸附：原点 (471.398,431.398)；指针进入 4px 距离时两轴吸附，继续移至偏离 8px 仍保持；偏离 20px 时原锁释放。辅助线真实渲染于 c-block-snap.png。所有示例标题/小标题/段落通过 querySelectorAll 收集，不只有首块。
- 四角从距安全边界 10px 的预置测试位置真实拖到边界：左上/右上工具条 below；左下/右下 above；所有十个按钮的中心 elementFromPoint 命中自身或子元素。
- 24×24 极小选区 below、满屏 clamped（选区内）、竖向大选区 right/left、中央贴底 above，全部按钮可达。900×760 四角、极小及满屏（含工具属性打开）全部可达。工具条宽度独立于选区，无 overflow 裁掉。
- 浅/深主题底图 note、标题、段落与侧栏的 computed color/background/font/尺寸完全一致，interaction-evidence.json 的 themeUnchanged=true。修复了初次标题继承暗色主题的问题，重新渲染两图。
- 标注为视口全局坐标。真实移动与左上手柄 resize 前后，图形实际屏幕 bounds 最大偏差 0.0078125 CSS px，属于浏览器 1/64 子像素取整；宽高不变。0.02 CSS px 容差下 alignedAfterMove/Resize=true，保留原始测量值供审核。
- 撤销/重做、非文字输入状态 Return 复制退出通过。页面运行错误 0。录屏本轮不扩大范围。

完整数据：interaction-evidence.json。可复现测试源：qa-approved.mjs（使用当时已授权的 Ego 空间6；已 finished，不能未经授权重新接管）。本轮最后只重渲两张主题图和首页，不追加全量重复验证。

## 限制

这里是 HTML 原型：示例底图模拟冻结，标注/复制/保存为模拟；无真实屏幕捕获、媒体导出或任意网页内容块识别。文字工具是固定示例，未验证真实文本输入期间 Enter/Cmd-C 行为；生产实现需将文本编辑快捷键优先交给文本控件。主题验证证明示例 DOM 样式不变，不宣称已测试原生像素缓存。

只编辑 design-demos/capture，未提交、部署或改生产文件。Ego 空间6完成后保留已选方案首页。
