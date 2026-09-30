# 真实录屏设备验收工具

这是独立的 macOS 原生验收工具，不加载 Prosio 主应用、语音资源路由或全局快捷键，也不替换 `/Applications/Prosio.app`。工具和动态窗口 fixture 使用不同 bundle ID：

- 主工具：`app.prosio.validation.recording`
- 动态窗口：`app.prosio.validation.recording.fixture`

直接编译当前生产 RecordingEngine、完整 Platform、Domain、Storage 和引擎协议。没有替换生产采集后端。构建时保存源码快照及 SHA-256，报告包含实际编译的源文件身份。构建脚本在签名前检查包内 `Contents/Resources/validation-build.json` 与全部 15 份冻结源码相符；该文件缺失、损坏或身份字段不完整时，工具明确拒绝请求权限和开始捕获。

## 构建和审查

需要 macOS 26、Xcode 和 XcodeGen。

```sh
tools/recording-device-validation/run.sh --dry-run
tools/recording-device-validation/run.sh --test
```

默认只构建并签名两款独立应用，不启动任何应用，不请求权限、不启动 fixture、不进行捕获、不打开剪辑软件。`--test` 只运行无宿主合成媒体测试。

产物留在 `/tmp/prosio-recording-device-validation.*/build/Build/Products/Release/RecordingDeviceValidation.app`。fixture 打包在主工具的 `Contents/Helpers` 中，先签名 fixture 再签名主工具。默认 ad-hoc 签名；如已有稳定开发签名，可通过 `--identity "Prosio Local Development"` 指定。不会创建证书或更改系统信任。

只读预检可直接执行构建后的工具二进制：

```sh
"/absolute/path/RecordingDeviceValidation.app/Contents/MacOS/RecordingDeviceValidation" --preflight
```

该模式只读取权限状态和系统识别的摄像头、麦克风，不初始化 GUI、不请求权限、不创建录制会话、不启动 fixture、不捕获。

## 用户主动验收

启动必须显式指定：

```sh
tools/recording-device-validation/run.sh --open
```

启动后的工具只显示设备和权限状态。默认没有摄像头、麦克风或系统音频来源被选中，不自动请求权限、不创建动态窗口、不播放声音。

1. 选择零至两路不同摄像头，以及可选麦克风。iPhone 连续互通相机占用其中一个摄像头名额；需要系统已识别和满足 Apple 连续互通条件。
2. 如选择“系统声音与低音量测试提示音”，录制成功启动后 fixture 每五秒播放一次短提示音。该轨道也包含其他应用播放的系统声音，开始前可关闭不希望纳入的播放内容。默认不开启，也不会改变系统音量。
3. 选择 30 秒、2 分钟或 2 小时，然后亲自点击“开始验收”。工具按所选设备请求必要权限；系统要求重新打开工具才能生效时，先完成授权后再重新开始。
4. 工具启动自己拥有的 fixture 子进程，核对其 PID、bundle ID 和精确 windowID，再交给未修改的生产引擎。屏幕来源始终是该动态窗口，不录制用户桌面，不替换成其他窗口或显示器。
5. 可以暂停/继续，或手动拔插 USB 摄像头、采集卡和麦克风。独立来源断连按生产引擎实际行为继续其他来源，并记录警告、来源状态和时间线间隙。自动时长使用单调时钟并扣除暂停，系统日期调整不影响时长。
6. 可最小化再恢复动态窗口观察暂停来源行为；也可关闭它测试屏幕失联隔离。**关闭原窗口后其 windowID 消失，工具不会新建替代录屏目标；其他独立来源仍可继续，需手动停止本次验收。**
7. 到达时长或点击“停止验收”后，界面等待启动/重连操作、引擎停止、全部媒体写盘和媒体检查。正常退出同样等待收尾，只终止自己启动并持有的 fixture Process，不查杀用户应用或其他窗口。主工具异常退出时，fixture 每半秒核对自身父 PID；父进程消失或发生重挂后即停止音频并自行退出，不搜索或结束其他进程。

## 报告与验收层级

“查看报告与原片”定位本次 `validation-report.json`。默认保存在：

`~/Library/Application Support/ProsioRecordingDeviceValidation/<attempt UUID>/`

报告包含所选设备、授权快照、系统版本、编译源码身份、两个测试进程身份、精确窗口配置、单调主机时间事件、生产引擎实际警告/失败/来源状态、持久化清单、各原片可播放性与真实媒体尺寸/采样参数、每个来源的完成片段数和首尾时间、来源间隙、开始/结束及有效录制时长。

每个已配置来源都独立检查。选中来源没有完成片段会标为 `missing/notVerified`，不会因其他来源有文件而宣称完整通过。报告成功层级是 `mediaMetadataVerified`，只表示本次原片的元数据和可播放检查通过。原始片段、损坏文件、侧录和失败记录保留。

音轨前十秒可解码时会记录实际采样的幅度/RMS；这只能说明采样音轨是否存在非零声音。fixture 的 `scheduledTestPulse` 记录只是播放调度证据，**不证明该信号已被捕获，也不证明音画同步**。

30 秒/2 小时录制、时间戳一致或原片可播放都不能单独证明口型漂移指标。真实口型同步应拍摄可见打板/计时器与声音标记，在开始和结束位置测量偏差。四款剪辑软件的导入、多机位结构和音画对齐也仍需另行验收。该工具默认只测试固定窗口捕获；桌面、区域、多显示器权限及设备自身传输表现有各自验收边界。

本工具不读取/改写 TCC 数据库，不自动授予权限，不启动编辑器，不替换或重启 Prosio 主应用。所有真实捕获和测试提示音都依赖用户明确点击“开始验收”。
