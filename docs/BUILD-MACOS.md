# macOS 开发构建与录屏验收入口

当前工程部署目标为 macOS 26。已在 Xcode 26.6、macOS 26.3.1 上验证。需安装 Xcode 命令行工具和 XcodeGen。

## 从独立检出构建

在仓库根目录执行：

```sh
./scripts/bootstrap-fluidaudio.sh
xcodegen generate --spec project.yml
xcodebuild build -project Prosio.xcodeproj -scheme Prosio -destination 'platform=macOS'
```

录音转写使用固定 FluidAudio revision `20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14`。bootstrap 会获取并核对这个版本，保存到忽略的 `.vendor/FluidAudio`；仓库不提交本机符号链接或第三方 checkout。录屏媒体采集、保存与导出均在本机进行。

工程使用本机 `Prosio Local Development` 签名身份，设置方式见 [开发签名说明](DEV_SIGNING.md)。签名固定用于保持开发重建后的权限身份。仅需编译诊断时可向 xcodebuild 添加 `CODE_SIGNING_ALLOWED=NO`；实际权限与设备验收应使用正确签名的应用。

## 不启动主应用的回归

```sh
xcodebuild test -project Prosio.xcodeproj -scheme ProsioValidation -destination 'platform=macOS'
```

`ProsioValidation` 运行 hostless 回归，不启动 Prosio 或安装事件监听。录屏界面测试创建测试进程自己的离屏窗口；媒体测试使用合成画面和音频，不录制桌面或摄像头。

录屏模块也可独立验证：

```sh
xcodegen generate --spec tools/recording-validation/project.yml
xcodebuild test -project tools/recording-validation/RecordingValidation.xcodeproj -scheme RecordingValidation -destination 'platform=macOS'
```

持续编码工具、已通过证据及真实机位/剪辑软件的待验收项目，分别见 [压力测试工具](../tools/recording-stress/README.md) 和 [录屏验收记录](evidence/recording/implementation-acceptance.md)。合成运行与实际设备、剪辑软件导入分别验收。

实际设备验收使用[独立验收工具](../tools/recording-device-validation/README.md)，先构建审查，再由用户选择来源并开始。该工具复用生产采集后端，报告逐来源原片、状态和间隙；窗口捕获通过也不能替代桌面/区域、口型同步和四款编辑器验收。已发布原片可再用[只读媒体审计](../tools/recording-media-audit/README.md)核对。
