# Prosio P0 骨架实施计划

## 目标
Mac 端 P0 可运行骨架：按住/轻点热键 → 录音 → 云端 `google/gemini-3.5-transcribe-live`（SMART）/本地 SpeechAnalyzer → 流光 HUD 实时预览 → 插入光标 → 历史/词典；Vercel 后端签发 Gateway 临时 token；SMART 中英评测脚本。

## 仓库结构与所有权（每个 agent 只能改自己拥有的路径）

| 路径 | Owner | 说明 |
|---|---|---|
| `Packages/ProsioKit/Sources/ProsioCore/Contracts/**` | architect | **冻结**，不得修改 |
| `Packages/ProsioKit/Package.swift` | architect | 需要改动请在报告中提出 |
| `Packages/ProsioKit/Sources/ProsioCore/**`（除 Contracts） + `Tests/ProsioCoreTests/**` | **core** | 状态机、Fallback、存储、设置、BackendClient |
| `Packages/ProsioKit/Sources/ProsioAudio/**`、`Sources/ProsioTranscription/**`、`Tests/ProsioTranscriptionTests/**`、`docs/gateway-ws-protocol.md` | **speech** | 录音、Gateway WS 引擎、SpeechAnalyzer 引擎 |
| `project.yml`、`Apps/macOS/Prosio/App/**`、`System/**`、`Resources/**` | **mac-system** | 组合根、权限、热键、插入、焦点上下文 |
| `Apps/macOS/Prosio/UI/**` | **mac-ui** | HUD（流光+玻璃胶囊）、菜单栏、设置、引导 |
| `server/**`、`eval/**` | **server** | Next.js on Vercel、SMART 评测 |

## 冻结接口
- Swift 契约：`ProsioCore/Contracts/Contracts.swift`，以及各 stub 文件中标注 `PUBLIC API FROZEN` / `INIT SIGNATURE FROZEN` 的公开签名。可以**新增** internal/private 成员，不得改动或删除已有 public 签名。
- 后端契约：`docs/API.md`。
- 需要契约变更：不要自己改，在最终报告的「契约变更请求」一节写明理由。

## 通用规则
- Swift 6 严格并发；App target 默认 MainActor 隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`）。最低 macOS 26，可用 macOS 26 新 API（`glassEffect`、SpeechAnalyzer 等）。
- 不引入第三方 Swift 依赖（P0 只用系统框架）。
- 构建隔离，避免并行冲突：
  - SwiftPM：`cd Packages/ProsioKit && swift build --scratch-path .build-<agent>` / `swift test --scratch-path .build-<agent>`
  - Xcode：`xcodegen generate && xcodebuild -project Prosio.xcodeproj -scheme Prosio -destination 'platform=macOS' -derivedDataPath build/dd-<agent> build`
- 别人的文件出现编译错误：可能是对方正在改，等 1–2 分钟重试；不要去改别人的文件。收尾时如仍失败，在报告中说明。
- 不做 git commit，不部署，不向外部服务发送数据（npm 安装包除外）。没有 AI Gateway key，涉及真实调用的部分写成「有 key 即可运行」并在报告中注明。
- 代码注释用英文，UI 文案用英文（海外优先）。

## 验收标准（architect 执行）
1. `swift build` + `swift test` 全绿（ProsioKit）。
2. `xcodebuild` 构建 Prosio.app 成功，无新增 warning 以外的错误。
3. `server`：`npm run typecheck`、`npm test`、`npm run build` 全绿；本地 `npm run dev` 后 `/api/health`、`/api/auth/dev`、`/api/transcribe/token`（无 key 时返回 502 结构化错误）、`/api/usage`、`/api/dictionary` 行为符合 `docs/API.md`。
4. 代码审查：只改了自己拥有的路径；冻结签名未变；无 TODO(core/speech/mac-system/mac-ui/server) 残留（刻意留给 P1 的用 `TODO(P1)`）。
5. 运行 App：菜单栏出现；DEBUG 菜单「HUD Showcase」能展示 listening/finalizing/finished/failed 各状态的流光与胶囊；截图检查。
6. 各 agent 报告中的「未验证项」汇总成风险清单交给用户。
