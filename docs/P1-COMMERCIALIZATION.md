# P1 商业化：分发、账户与支付验证

日期：2026-09-27。状态：完成本机能力对照和离线后端审计；以下为推荐路线，不表示商户账户、Apple 正式签名或支付已经开通。

## 决策

以保留当前跨应用输入、选区编辑、上下文和光标定位体验，以及降低首版维护成本为目标，建议：

**官网分发 + Developer ID 签名/公证 + 邮箱验证码登录 + Stripe 托管结账/订阅 + Prosio 后端权益与用量。**

根据用户后续选择，支付商确定为 Stripe；正式收款主体、商户开通和税务配置仍待实际验证。先做 UI 供用户确认，再实施生产功能。三版原型与执行计划见 [订阅 UI 计划](../design-demos/subscription/implementation-plan.md)。

第一版暂缓 Mac App Store、原生 Apple 登录、RevenueCat、多档套餐、加购额度和买断无限云端服务。首版仅一个月付套餐：US$9.90/月，每订阅月 600 分钟云端转录；用完自动切换本地听写。本地听写不限量，不能宣传成无限云端 AI。年付暂缓。独立改写、翻译和 Ask 的额度尚未定稿。

## 本机对照实测

复现入口：`python3 tools/distribution-probe/run.py`。原始输出位于 `.build/distribution-probe/`；可提交的精简证据为 [distribution-probe-2026-09-27.json](evidence/distribution-probe-2026-09-27.json)。

环境：macOS 26.3.1 (a)、Apple Silicon、Swift 6.3.3；同一源代码、同一本地签名身份，分别启用/关闭 App Sandbox。只使用专用 AppKit 测试文本框。

| 验证项 | 非沙盒 | 沙盒 |
|---|---|---|
| Accessibility 授权状态 | true | true |
| 创建并启用 Prosio 同类型全局事件 tap | 成功 | 成功 |
| 获取测试进程的 focused UI element | 成功，错误码 0 | 失败，-25204 / cannotComplete |
| 读取选中文字并匹配测试标记 | 成功 | 失败 |
| 向测试 PID 注入 Cmd+V 并观察粘贴结果 | 成功 | 成功 |
| 读取容器外的非敏感控制文件 | 成功 | 拒绝，257 / EPERM |

结论：在辅助功能授权为 true 的条件下，沙盒仍阻断了跨进程 AX 读取。该能力是 `FocusContextProvider` 的基础，会影响选区编辑、目标字段判断和光标上下文。完整功能版本应走非沙盒的正式分发路径。

边界：

- 探针由开发宿主启动，TCC 归属可能继承宿主。tap 和粘贴成功不是新安装商店应用可获授权、可过审的证明。
- tap 测试只验证创建/启用，不声称验证了真实用户热键的全部事件投递。
- 粘贴通过 `postToPid` 定向投递，避免抢占用户焦点；没有把它冒充 Prosio 全局 `post(tap:)` 的完整端到端测试。
- 初次原型未包含 Info.plist，沙盒进程在初始化容器时退出；该次运行作废，不用于结论。最终证据来自修正后的完整 .app 包。
- 当前应用未切换沙盒配置，未修改 TCC 数据库，未使用私有/临时例外权限。

Apple [审核规则 2.4.5](https://developer.apple.com/app-store/review/guidelines/) 要求 Mac App Store 应用沙盒化；[App Sandbox 文档](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) 将辅助类应用使用 Accessibility API 列为不兼容功能。测试与官方文档一致。不能依赖“另一个应用在商店里”或添加未受支持的 entitlement 作为首版发行前提。

## 登录路线修正

上一轮讨论中“官网分发仍可直接用原生 Apple 登录”过于宽泛，应修正：Apple DTS 明确表示 Developer ID 应用不支持该原生 capability，见[官方答复](https://developer.apple.com/forums/thread/793244)和[macOS capability 表](https://developer.apple.com/help/account/reference/supported-capabilities-macos)。

网页 Apple 登录是另一路径，需要 Services ID、回调域名、密钥，并关联启用 Apple 登录的主 App ID；不是把原生按钮搬过去就可用，见[网页配置要求](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web)。本次未持有正式 Apple 账户配置，未进行真实登录。

最小账户实现建议沿用已有 Next.js / Postgres：用 Better Auth 的 [Email OTP](https://better-auth.com/docs/plugins/email-otp) 管理短期验证码和会话，不自己发明认证协议。配置发送邮件、过期、单次使用、尝试次数、发送频率和注销撤销；明确原生客户端的会话凭证存储和刷新方式。此项为下一阶段实现建议，尚未安装依赖或改变现有 JWT 协议。

界面：输入邮箱 → 输入验证码 → 登录；账户页显示套餐、剩余额度、管理订阅、退出与删除账户。用户内部 UUID 为主键；支付 customer ID 绑定该 UUID，不依据结账邮箱自动归并账户。

## 支付方案比较

| 路线 | 对 Prosio 第一版的判断 |
|---|---|
| App Store + StoreKit 2 | 支付/更新集中，但当前完整功能存在 AX 与沙盒冲突，不选作首发路线 |
| 官网 + Paddle | 原始比较中的备选，当前不接入；托管结账、订阅门户及 MoR 销售税处理，减少自建账单页面和多国销售税工作 |
| 官网 + Lemon Squeezy | 可作商户准入或运营条件不合适时的备选；大陆不在当前银行打款列表中，不能预设大陆银行卡可收款 |
| 官网 + Stripe 直接收款 | 用户已选；采用托管结账与订阅门户，仍需确认主体与税务配置 |

Paddle 官方当前标准价格为 **5% + US$0.50 / 每笔结账交易**，低于 US$10 的产品建议联系其确认定价，见[价格页](https://www.paddle.com/pricing)。MoR 处理其销售环节的税款，不等于免除开发者自身收入的税务责任。

Paddle [商户支持地区](https://www.paddle.com/help/start/intro-to-paddle/which-countries-are-supported-by-paddle)未将中国大陆列为排除地区；[身份核验](https://www.paddle.com/help/start/account-verification/what-is-identity-verification)包含个人/sole trader 情形，但仍须完成实际审核和打款验证。

中国用户的支付宝订阅可通过 Paddle 支持，但需额外批准，结账商品要以 CNY 计价、买家地址为中国，并有续费金额条件，见[Alipay 文档](https://developer.paddle.com/concepts/payment-methods/alipay/)。不要在未开通时对用户承诺支付方式。

Lemon Squeezy 的银行/PayPal 打款按其[支持国家](https://docs.lemonsqueezy.com/help/getting-started/supported-countries)分别确认。本轮仅检查官方可用性，没有注册账户、提交身份材料或进行真实扣款。

## 后端商业化审计：4 个可复现阻断项

执行（在 `server/`）：

```sh
npx vitest run --config scripts/commercialization-audit.config.ts
```

审计入口 `scripts/commercialization.audit.ts` 不匹配日常 `*.test.ts`，避免把尚未实现的 P1 要求混入 P0 回归结果。该命令目前应退出非零：**5 项中 4 项失败、1 项通过**。失败是待修复问题，不是“审计通过”。所有模型调用用本地模拟，不产生云端请求；使用 MemoryStore，未声称验证真实 Postgres 并发。

| 要求 | 实际复现 | 修复方向 |
|---|---|---|
| 请求不能超过剩余额度 | 已使用 3599 秒，提交 2 秒录音仍返回 200 | 在模型调用前原子预留额度；比较 used + reserved + requested；成功结算、失败释放 |
| 重试不能重复产生模型费用 | 同一 sessionID 提交两次，模型被调用两次，用量只记一次 | 以 userID + operationID 做请求级幂等；校验请求指纹，完成后复用结果，并发中只执行一次 |
| 客户端不能抢先写入权威用量 | 先 POST /usage 上报同 sessionID 的 0 秒，再转写 1 秒，用量仍为 0 | 云端账本只允许服务端写入；客户端遥测拆表或拆命名空间，不能影响付费额度 |
| 改写/Ask 必须有限额和成本记录 | 连续 3 次改写成功，模型调用 3 次，当前唯一用量账本仍为 0 | 增加 Compose 计量/额度以及并发、频率限制；不把模型调用无限挂靠到音频剩余额度 |
| 生产关闭开发登录 | 未设置 PROSIO_DEV_AUTH 时返回 404 | 此检查已通过；正式部署仍需确保不启用该开关 |

另有代码级待实现项：真实邮箱验证、可撤销会话、订阅/交易/通知持久化、删除账户、退款/欠费/取消续费处理；当前 30 天 JWT 和固定 trial 不能直接承担付费权益系统。

## 建议实施顺序与验收

1. **P1-A：正式分发基础。** 保留非沙盒；Release 移除仅供本地测试使用的 `disable-library-validation`；配置 Developer ID、Hardened Runtime、公证与安装包。在干净用户环境验证首次辅助功能/麦克风授权、升级后授权稳定。当前机器只有本地自签开发身份，正式签名和公证未实测。
2. **P1-B：真实用户。** 邮箱验证码、服务端会话、撤销/退出、删除账户；关闭生产 dev auth。验收验证码过期、重复使用、错误次数、发送频率及重新登录。
3. **P1-C：先修额度与去重。** 四个审计项转绿；补实际 Postgres 的并发预留/结算、跨用户幂等隔离测试。Compose 的新账本落地后，将审计中的临时音频账本断言改为 Compose 权威账本断言。
4. **P1-D：单一支付商。** 商户批准后接托管 checkout 和 portal；仅服务端创建结账会话并绑定当前用户。验签 webhook，以事件 ID 去重，应对乱序并从支付商取权威状态；不能靠浏览器“支付成功”回调授予权益。
5. **P1-E：订阅生命周期。** 用支付沙盒验证首次购买、续费、主动取消但当期仍有效、到期、退款、欠费、重复/乱序通知及换设备。首版仅月付，按订阅账期发放额度，定义月底和闰年的重置规则；免费体验不做可通过重装反复领取。

正式上线验收包括：真实签名、公证、干净安装、真实邮件收发、测试支付全生命周期、数据库恢复/并发及 webhook 重放。上述外部账户步骤尚未执行，不能用本次本地测试替代。
