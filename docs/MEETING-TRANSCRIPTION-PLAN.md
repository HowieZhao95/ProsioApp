# Prosio 会议转写实施计划

状态：正式项目已接入本地录音/字幕/文字、说话人分析、会议库及 Soniox Async 服务端链路；真实云端与长会议验收待配置和样本。当前实现与验证记录见 [MEETING-INTEGRATION.md](MEETING-INTEGRATION.md)。

独立技术 MVP 及当前验证结果见 [`tools/meeting-mvp/VALIDATION.md`](../tools/meeting-mvp/VALIDATION.md)。MVP 已验证本地录音、Apple 字幕/最终文字和 FluidAudio；合成中英夹杂音频中的英文术语被 Apple 明显误识别。Soniox 实际调用、真实会议 App 和真人中英混说仍待验证。

## 1. 产品决策

- 录音时一律使用 Apple `SpeechTranscriber` 生成本地实时字幕，并持续保存原始录音。会议不依赖网络或额度才能开始、继续和保存。
- 停止录音后，若用户允许云端处理且可用额度覆盖整场会议，使用 **Soniox `stt-async-v5` 一次**生成最终文字及说话人标签。首版不调用 Soniox Real-time，也不对同一录音同时调用两种 Soniox API。
- 录音停止并安全落盘后，会议立即可打开、可回放；Apple 完成尾段 flush 后，本地文字可用。FluidAudio 会后说话人分析作为独立后台任务运行。无额度、未登录、离线、未允许上传或 Soniox 失败时，这份本地稿仍是完整可用的最终稿。云端失败不扣用户会议额度。
- 不在会中自动切换转写来源；本地实时字幕可一直显示，最终稿生成后作为新版本呈现。用户编辑永远不被模型结果静默覆盖。
- 原始录音是事实来源；转写、降噪、单声道混音和说话人结果都是可重建的派生数据。

## 2. 完整链路

```text
开始会议
  → 权限及存储空间检查
  → 创建 MeetingSession（UUID、开始时间、状态）
  → 麦克风和系统音频分别采集，按同一单调时钟写入分段文件
  → 派生单声道识别流 → Apple SpeechTranscriber → 临时/最终字幕落盘
  → 停止：安全关闭音频分段，本地录音立即可回放；Apple 尾段 flush 后显示本地全文
  → 后台：FluidAudio 分析原始音频 → 补齐本地稿的说话人时间段
  → 同时，若允许云端且已登录：查询服务端额度并原子预留整场时长
      ├─ 预留成功：上传派生识别音频 → Soniox Async → 获取结果
      │                    → 保存独立的 Soniox 版本及说话人时间轴 → 结算额度
      └─ 不允许/不可用/失败：保持本地稿可用
  → 用户查看、回放、改名、编辑、导出
```

录音与后处理是两个独立生命周期。进程重启后扫描未完成会话：修复可读取的分段索引，保留已录音频，恢复尚未完成的本地或云端任务。用户可手动重试云端增强，重试使用同一会议 ID，避免重复扣费。

## 3. 客户端边界

### MeetingRecorder（macOS 专用）

- 新建会议音频采集器，不复用 `AudioCapture` 的短口述会话状态机。麦克风与系统音频保留独立轨道和设备/来源元数据。通过 ScreenCaptureKit 采集系统声音；麦克风可用现有 AVAudioEngine 组件或 ScreenCaptureKit 麦克风输出，但只能有一个麦克风采集源。
- 从首个采样开始建立单调时间轴；处理音频设备切换、睡眠、系统音频流重建和采样率变化。无法采集某轨时明确标记缺轨，另一轨继续录制。
- 小段顺序写盘并原子更新 manifest，不把整场 PCM 保存在内存。录制过程中不裁剪静音；派生音轨保留原始时间映射。限制磁盘占用，低空间时安全停止并保留已写入内容。
- 避免扬声器声音在麦克风轨与系统轨重复计入派生识别流；首版先用耳机/扬声器场景实测混音策略，再决定是否启用 AEC。FluidAudio 的降噪/AEC 不进入首版必经路径。
- Apple 与 Soniox 使用同一份从原始轨道派生的识别音频，保留与原始时间轴的映射。Soniox 每场只提交一份音频；混音前处理近端麦克风中的远端回声，避免重复计费和重复文字。

### LocalMeetingTranscriber

- 新建基于 `SpeechTranscriber` 的长会议引擎；现有 `SpeechAnalyzerEngine` 使用 `DictationTranscriber(.shortDictation)`，保持给短口述使用。
- 按 Apple 音频时间范围保存 volatile 与 final 事件；volatile 只更新字幕，不作为最终稿。将已确认段持续落盘，停止时完成 analyzer flush。
- 对本地语言模型不可用、未安装、下载失败提供清楚状态；录音仍继续，会议结束后可重新转写录音。
- 首版重点验收 `zh-CN` 和 `en-US`；本地语言不受支持时明确提示实时字幕不可用，不承诺免费的本地文字结果。

### MeetingStore / MeetingProcessor

- 独立于 `HistoryStore`，使用 `Application Support/Prosio/Meetings/<UUID>/` 保存 `manifest.json`、分段音频、转写版本和编辑记录。列表只加载摘要，长录音按需读取。
- 内部统一结构：`MeetingSession`、`AudioTrack`、`TranscriptVersion`、`Utterance(start,end,text,speakerID,source,status)`、`Speaker(label,confirmedName?)`。所有时间戳使用录音开始后的秒数；说话人 ID 只在本次会议内有效。
- 本地稿与 Soniox 稿是两个独立版本；云端完成后提示可切换到增强稿，不自动替换用户正在查看或编辑的内容。用户编辑建立在选中版本之上。说话人姓名须用户确认，不自动把声纹推断当作姓名。
- FluidAudio 首版仅做会后离线 diarization，作为每场会议的本地后台任务；云端上传和推理不会阻塞它。先按音轨识别近端/远端，再对远端多人及同室多人进行说话人分析；时间重叠要允许两人同时发言，无法可靠判断时标为未知。

## 4. 云端与额度边界

- 新增会议专用 API，不扩大现有 `/api/transcribe` 的 600 秒限制，也不改变其口述计费规则。建议接口：`POST /api/meetings/jobs`（按实际时长预留额度并返回上传信息）、`POST /api/meetings/jobs/:id/submit`、`GET /api/meetings/jobs/:id`、`POST /api/meetings/jobs/:id/cancel`。所有接口要求登录并按用户 ID 隔离。
- 额度必须在数据库事务中按 `userID + billingPeriod + meetingID` **原子预留**整场时长；不能沿用现有“先读已用量、响应后写 usage”的逻辑。`meetingID` 是幂等键。成功获取并持久化 Soniox 结果后结算；上传/供应商失败时释放；客户端失联时由过期任务清理。取消后的供应商实际成本单独记录，不向用户重复扣额度。
- 长录音不以 base64 经 Vercel 函数上传。首选 S3 兼容私有对象存储：服务端给 Mac 签名分片上传信息，客户端断线后可续传；上传完成并校验对象大小/类型后，由服务端生成有效期足够 Soniox 拉取文件的签名读取 URL，提交 Soniox Async `audio_url`。Soniox 长期 API 密钥只在服务端。对象与 Soniox 任务完成后尽快清理；失败和过期任务也要清理。
- Soniox 任务配置 `stt-async-v5`、`enable_speaker_diarization`、语言提示与词汇上下文；返回的 token 时间戳和 speaker label 转换成统一 `Utterance`。任务状态由服务端持久化；Webhook 只触发服务端查询和更新，Mac 通过状态 API 轮询/恢复。
- 云端任务创建前检查 Soniox 文件时长限制（当前 300 分钟）和产品额度。超过限制的会议保持本地可用；后续再设计长会分段云处理，不在首版静默截断。
- 云端请求失败、额度不足或 Soniox 无结果时保留 Apple 字幕并启动 FluidAudio 本地完成稿。服务端区分 `quota_exceeded`、`upload_failed`、`provider_failed` 等稳定错误码。

## 5. UI 与权限

- 会议入口独立于 Fn 短口述：开始/暂停或停止、录音时长、麦克风/系统声音状态、实时字幕、剩余空间提示。不要复用口述 HUD 的“停止即插入光标”行为。
- 开始前显示音频来源、预计可用付费时长和云端处理策略；用户可选“仅本机”。录制中显示付费剩余时长的估计和“超过后整场使用本地稿”的提示，不中断录音。实际额度仍以停止后服务端原子预留为准。云端稿处理时显示“本地稿可用 / 云端处理中”，失败时给重试入口。
- 麦克风或系统声音权限缺失时允许已获授权的音轨单独录制，并在开始前和录制中明确显示缺失来源。两轨都不可用时才阻止开始。会议录音期间短口述热键不启动第二个麦克风会话，并给出清楚提示。
- 会议详情包含音频回放、同步高亮、说话人改名、逐段编辑、导出。输出纪要和任务提取属于后续阶段，不阻塞转写首版。
- 更新麦克风与屏幕/系统音频权限说明，以及 `NSMicrophoneUsageDescription` 文案；录音状态始终可见。

## 6. 实施顺序与验收门槛

1. **会议数据与录音**：建独立 MeetingSession/Store/Recorder。验收：2 小时录音内存不随时长线性增长；杀进程、睡眠、拔麦、断系统音频、磁盘不足后可找回已录内容；本机两轨时间误差有测量记录。
2. **Apple 实时字幕**：接 `SpeechTranscriber`，持续落盘 final 事件。验收：1 小时会议样本、纯中文、纯英文、中英混说及长静音；字幕无重复/明显时间漂移，离线启动和模型缺失路径可恢复。
3. **FluidAudio 本地最终稿**：离线说话人分析并与 Apple 时间轴对齐。验收：2/4/6 人、远端加近端、重叠发言、相似音色；统计说话人错误和未知比例；不确定处不自动命名。
4. **会议云端链路与额度**：私有对象上传、Soniox Async、原子预留/结算/释放、幂等恢复。验收：并发提交不能超额；重复提交/重试不重复扣费；5xx、断网、上传中断、Soniox 失败、Webhook 丢失都能恢复或回退本地；客户端永不持有 Soniox 长期密钥。
5. **会议 UI 与端到端验收**：录音、字幕、处理状态、回放、编辑、导出。验收：停止后无需等待 Soniox 即可打开并回放本地稿；额度用尽、断网、仅麦克风、仅系统声音均能完成录音；云端完成时不覆盖用户编辑；完整两小时线上会议和同室会议各一次，检查音频完整性、时间戳、说话人、额度与云端对象清理；短口述及截图回归通过。

## 7. 首版明确不做

- Soniox Real-time、Soniox Async 对同一会议双跑；按低置信度自动切云端；跨会议自动认人；会议中实时 FluidAudio diarization；把 FluidAudio AEC 当作默认处理；自动生成纪要/行动项。

## 8. 外部 API 依据（实施时复核）

- [Apple SpeechAnalyzer 会议与长录音用例](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Soniox 模型用途](https://soniox.com/docs/stt/models)；[Async 文件流程](https://soniox.com/docs/stt/async/async-transcription)；[说话人区分](https://soniox.com/docs/stt/concepts/speaker-diarization)
- [Soniox 临时密钥用途](https://soniox.com/docs/guides/temporary-api-keys)；[Async 权限与文件权限](https://soniox.com/docs/guides/api-key-permissions)
- [FluidAudio diarization 选型](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)
