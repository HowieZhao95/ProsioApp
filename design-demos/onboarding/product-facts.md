# 产品事实与参考

核对日期：2026-10-04（用户时区）。

## Prosio 本地事实
- AppEnvironment.launch() 当前不自动打开 OnboardingView；菜单栏语音权限入口调用 showOnboarding()。
- 原导引为 520 × 420、英文、6 步；只覆盖语音权限与单个输入框。
- PermissionsManager.allRequiredGranted 只要求 microphone 与 accessibility；screenCaptureGranted 独立管理。
- TriggerKey 默认 fn，支持 rightOption / rightCommand / rightControl。独立 Option 截图可能需要输入监控且会与 rightOption 语音冲突。
- 菜单包含 voice / capture / meeting / presentation / recording / agents；便签是现有独立能力。
- backend 使用现有会话与开发邮箱登录，不能在新导引中承诺未实现的 Google / Apple 登录。
- 原有工作树含多项进行中的修改，本阶段仅新增 design-demos/onboarding，不改动生产源码。

## Typeless 官方参考
来源：https://www.typeless.com/help/installation-and-setup
实际打开并读取：设置流程包括登录、辅助功能、麦克风、输入测试，再体验 Dictate / Translate / Ask anything；权限帮助含手动授权及系统要求重启后的继续步骤。

来源：https://www.typeless.com/help/quickstart
实际打开并读取：按 Dictate / Translate / Ask anything / Personalization / History & Dictionary / Settings 组织快速上手帮助。

设计推导：先看到功能价值、权限原因随操作出现、用有引导的试用理解能力。Prosio 另有截图/录制/演示/便签，所以不照搬 Typeless 的产品结构。
