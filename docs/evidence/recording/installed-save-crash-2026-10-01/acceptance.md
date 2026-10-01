# 正式应用双摄保存后崩溃 · 2026-10-01

用户实际使用的 `/Applications/Prosio.app` 在 13:07 双摄录制保存后退出。本次检查正式应用，不以独立验收工具的构建结果替代已安装应用。

## 原因与交付缺口

崩溃为主线程 SIGABRT，位于 `_AVKit_SwiftUI` 的 Swift 类元数据初始化。该时刻系统日志明确记录 `failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC': unknown error`。旧已安装 build 1 的 UUID 为 `0A3909B1-5457-3F2F-AB65-94998A75D83B`，仅链接 `_AVKit_SwiftUI`，没有直接 AVKit.framework 依赖。

生产源码此前已经把 SwiftUI VideoPlayer 换成直接绑定 AVPlayerView 的原生播放器，测试构建也通过，但没有更新仍在运行的已安装应用。这是交付验证遗漏。双摄保存之后的播放器路径触发了崩溃；报告没有表明两路摄像头采集线程导致此次退出。原录制的写入繁忙／跳帧告警独立保留，不将其归因或掩盖为播放器问题。

## 实际原片检查

录制清单已经是 ready，并有 endedAt。屏幕、两路摄像头、麦克风和系统声音共五份原片：AVFoundation 元数据检查 5/5 通过，ffmpeg 全部内容解码 5/5 通过，无解码错误。应用更新、启动之后逐份 SHA256 与更新前相同。没有删除、重写或上传原片，没有把用户摄像头画面／声音加入 Git。该检查不能证明音画同步或零丢帧。

## 正式应用更新

从已提交 `45bb35f` 隔离构建，只补显式 AVKit.framework 的应用／测试依赖，并把 CURRENT_PROJECT_VERSION 从 1 升到 2。已有未提交演示和服务器工作不纳入本次应用。使用原有 Prosio Local Development 证书签名，指定身份要求与旧应用完全一致；未更改系统隐私权限。

旧应用已经因崩溃退出，更新前再次确认没有运行实例。正式应用经过暂存与严格签名检查后替换，旧版完整保留在 install-receipt.json 记载的备份路径，可回退。更新后再次检查真实 `/Applications/Prosio.app`：build 2，UUID `5CC9148A-6EFD-3190-9F22-208840B115BD`，直接 AVKit.framework 链接、严格签名与旧身份匹配均通过。实际启动进程路径为 `/Applications/Prosio.app/Contents/MacOS/Prosio`，而非临时测试副本。

新增只读构建检查工具，逐架构核对 AVKit、UUID、版本、签名与可选原身份。旧安装应用实际被拒绝，新安装应用实际通过；8 项工具测试覆盖私有 overlay 误判、单架构遗漏、身份不匹配、超时、路径逃逸、异常元数据和签名失败。

同一隔离源码 Release 应用构建通过；播放器渲染、预览、协调与退出收尾四个 suite 共 25 个 Swift Testing 回归实际运行并通过，原生 AVPlayerView 渲染测试明确在日志中出现。此前 265 项全量回归保留，本轮没有把 0 个 XCTest 的外壳输出误当成 25 项 Swift Testing 未执行。

## 正式界面验收状态

**真实安装版的双摄复录、停止和预览尚待完成，未宣布这条端到端路径通过。** 新版进程运行，但菜单栏面板关闭时原生界面检查工具无法定位窗口（读取超时，进程未退出）。已请求用户点击 Prosio 菜单栏图标并保持面板打开；该请求是取得可操作界面，不是重新申请摄像头或麦克风权限。等待这一界面入口后继续检查历史素材的三个角度，以及新一次双摄保存闭环。

`crash-analysis.json`、`original-media-check.json`、`old-new-artifact-check.json`、`installed-artifact-check.json`、`test-and-build.json` 和 `install-receipt.json` 记录证据与范围。原始诊断和构建日志只读保留在本机；没有以新的合成编码长测代替这次正式应用崩溃验证。
