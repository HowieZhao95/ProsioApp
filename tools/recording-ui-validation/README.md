# 原生录制交互验收工具

独立运行生产录制工具栏、桌面选择浮层、录制控制和素材窗口。使用合成来源、假授权和假预览，不捕获屏幕、摄像头或麦克风，不请求隐私权限。摄像头卡片绑定空会话，因此黑色预览是预期现象。停止时用生产媒体写入器生成两秒测试素材。

需要 macOS 26、Xcode 和 XcodeGen。与正式 Prosio 使用不同 bundle ID `app.prosio.validation.immersive`，不替换已安装应用。

```sh
# 只构建；不自动启动。动态窗口 fixture 可省略。
tools/recording-ui-validation/run.sh /absolute/path/RecordingValidationFixture.app

# 同时执行无界面的合成素材完整解码检查。
tools/recording-ui-validation/run.sh /absolute/path/RecordingValidationFixture.app --smoke

# 不提供动态窗口 fixture，只构建屏幕／区域验收工具：
tools/recording-ui-validation/run.sh
```

动态窗口 fixture 由 `tools/recording-device-validation` 构建；工具校验它的 bundle ID、复制进 Helpers，并仅管理自己启动的子进程。没有 fixture 时不能验收窗口选择。脚本输出构建后的应用路径，使用原生应用工具或 Finder 打开。退出验收会等待当前写盘完成并结束自己启动的 fixture。

默认交互证据输出到 `/tmp/prosio-recording-complete-ui/state.json` 和 `events.jsonl`，素材保存到其中的 `sessions`。启动前可设置 `PROSIO_UI_VALIDATION_OUTPUT` 选择其他目录，`PROSIO_UI_FIXTURE_BINARY` 指定 fixture 可执行文件。解码检查输出到 `/tmp/prosio-recording-complete-ui-media/report.json`，每次素材使用新目录。

「测试窗口」菜单只聚焦已经存在的生产浮层，方便原生自动化在桌面浮层、工具栏、预览和保存提示之间切换；不会代替点击、拖动或录制操作。生产控制浮层禁止共享窗口画面，因此自动化截图可能显示透明背景；菜单与按钮应通过 AX 状态核验。真实桌面选择边框可直接截图观察。

## 手动交互清单

- 进入录制后悬停高亮屏幕，点击锁定、再次点击重新选择；切换屏幕／窗口／区域。
- 区域拖选、移动、八方向调整；最小区域仍能移动；未完成拖选不能开始。
- 窗口选择使用动态 fixture；关闭或隐藏窗口后不能沿用旧目标开始。
- 菜单选择最多两路摄像头，禁止重复物理设备；在菜单中按 Return／Escape 应只操作菜单。
- 切换麦克风、系统声音、指针；摄像头预览可拖动；取消后释放录制互斥。
- 倒计时取消不产生录制会话；开始后暂停／恢复／结束；录制期间隐藏预览保留原片。
- 停止后出现保存提示，查看素材、切换角度、裁剪及导出；重复开始／停止不残留浮层或锁。
- 模拟发现失败和启动失败，重试能恢复；启动失败保留选择。

合成工具不能证明真实设备画面、音画同步、系统权限弹窗、物理断连、连续互通稳定性、长录或编辑软件实际导入。这些必须使用真实设备验收工具和目标编辑软件另行测试。
