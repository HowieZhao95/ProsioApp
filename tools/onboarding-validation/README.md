# 原生启动导引验证

用户已选定 B，方向记录位于 `design-demos/onboarding/direction-approved.md`。

```sh
xcodegen generate
xcodebuild -project Prosio.xcodeproj -scheme Prosio -configuration Debug -derivedDataPath .build-onboarding build
xcodebuild -project Prosio.xcodeproj -scheme ProsioValidation -configuration Debug -derivedDataPath .build-onboarding -only-testing:ProsioTests/OnboardingTests -only-testing:ProsioTests/AXCoordinateConverterTests -only-testing:ProsioTests/HotkeyStateMachineTests test
.build-onboarding/Build/Products/Debug/Prosio.app/Contents/MacOS/Prosio --onboarding-render docs/evidence/onboarding/native-light
.build-onboarding/Build/Products/Debug/Prosio.app/Contents/MacOS/Prosio --onboarding-render docs/evidence/onboarding/native-dark --dark
.build-onboarding/Build/Products/Debug/Prosio.app/Contents/MacOS/Prosio --onboarding-render docs/evidence/onboarding/native-compact --compact
```

渲染入口仅存在于 Debug，使用生产 View 与临时数据目录、独立偏好，不启动快捷键、媒体服务或监控。

原生点击验证副本位于 `build/ProsioOnboardingPreview.app`，其独立 bundle ID 为 `app.prosio.onboarding.preview`。副本的 Info.plist 必须带 `ProsioOnboardingValidation = true`，保证系统再次启动且无命令行参数时仍隔离数据。副本将原生窗口固定为 760 × 610，默认不启动服务。它用于操作与排版检查；功能端到端测试应运行常规应用并由用户配置权限。

检查：逐页前进、返回、侧栏跳转；设置面板开关；改写自动选文与输入替换；完成关闭；拒绝权限不显示成功。不要为界面验证授予权限、登录、采集媒体或更改真实用户偏好。

最终安装版已更新；退出应用和主动关闭导引已区分。完整回归执行 `xcodebuild -project Prosio.xcodeproj -scheme ProsioValidation -configuration Debug -derivedDataPath .build-onboarding test`、`swift test --package-path Packages/ProsioKit`、在 server 目录执行 `npm test` 与 `npm run typecheck`。安装、测试与真人云端转写的边界见验收报告。
