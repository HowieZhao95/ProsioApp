# Prosio · 49 秒品牌片

1920 × 1080，30 fps，49 秒。以 Typeless 官网的留白、黑灰文字层级和动作结果演示为视觉参考；所有画面、示例内容和合成音乐为本项目制作。不复用 Typeless 素材或性能数字。片头和片尾写明开源免费。画面是听写、截图、便签、录屏和会议。音轨仍是原来的连续文件，片尾可能和画面错位。

## 预览和编辑

```bash
npm ci
npm run preview
```

打开 `http://127.0.0.1:3211`。播放器支持播放、暂停、音量、全屏和章节跳转。源码改变后重启此命令重新编译。
可用 `?frame=1418` 定位到具体帧，审阅点击与状态变化。

需要逐帧或编辑单镜头时运行 `npm run dev`，打开 `http://localhost:3210/ProsioLaunch`。主时间线及每个独立镜头均在 Studio 注册。首版以画面文案、音乐和操作音效传达信息，无旁白。

## 结构

- `design/brief.json`：导演方案、时间线、视觉依据与事实来源。
- `design/references/`：2026-10-08 浏览的 Typeless 官网参考截图，仅用于研究。
- `src/Film.tsx`：完整 1470 帧时间线和本地音轨。
- `src/scenes/`：片头、语音、截图、便签、录屏、会议、片尾。
- `src/components.tsx`、`src/theme.ts`：品牌、排版、原生窗口、指针与动效基础。
- `src/interaction.tsx`：鼠标、按键、拖拽和界面状态共用的操作时间线；坐标以鼠标尖端为准。
- `src/native-ui.tsx`、`public/ui-symbols/`：AppKit 导出的原生 SF Symbols 与 App 界面参数。
- `design/*-evidence.json`：六段界面对照的实际源码、原生截图、控件尺寸与操作依据。
- `design/interaction-events.json`：42 个实际操作事件，同时用于鼠标检查与音效合成。
- `scripts/build_audio.py`：确定性原创合成器乐与音效，需 NumPy、ffmpeg。
- `public/audio/soundtrack.json`：音轨测量记录。原文件仍是 60 秒，画面已改为 49 秒。
- `scripts/render-stills.mjs`：一次打包后渲染关键帧进行视觉检查。

已安装的音频 Python 环境位于 `/Users/guest01/.codex/environments/motion-design`，可用该目录下的 `bin/python` 运行合成脚本。

## 检查与输出

```bash
npm run lint
npm run check:interactions
npm run build
npm run stills
```

静帧脚本可通过 `REMOTION_BROWSER_EXECUTABLE` 指定已有 Chromium，否则使用 Remotion 的默认浏览器。输出位于忽略 Git 的 `out/`。需要导出时，Studio 的 Render 按钮可生成 H.264 MP4；也可以运行 `npm run render`。

修改操作帧后先运行 `npm run check:interactions`，再运行 `scripts/build_audio.py` 重建音轨。精修验证记录在 `design/verification.json`；关键帧和浏览器实测点击位置保存在 `out/refinement/`。

## 内容口径

- 片中交互按当前 App 源码和原生截图重建：语音练习区与胶囊 HUD、截图工具条、便签与月历、录屏控制条与素材窗口、会议窗口。示例内容为虚构项目；处理等待经过剪辑。
- 语音为 Fn 单次开始、再次结束；截图为轻按 Option；会议为录音、转写、回放，不是自动纪要。
- 片头与片尾写明「开源免费」。成片没有订阅价格、套餐或 Agent 提醒。
- 画面功能为听写、截图、便签、录屏和会议。

关键项目证据：`../../docs/P1-COMMERCIALIZATION.md`、`../../docs/RELEASE-AUDIT-2026-10-04.md`、`../../docs/evidence/capture-translation/installed-app-test-report.md`。
