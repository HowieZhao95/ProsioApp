# Prosio Agent 监控 · 第一阶段设计与实施

> 本文记录第一阶段的历史交付范围。当前阶段 2 / 3 的连接能力、交互边界与验收进度见 [实施计划](AGENT-INTERACTION-PLAN.md) 和 [验收记录](evidence/agent-interaction/acceptance.md)。以下“只读”描述不代表当前全部实现。

## 交付范围

读取已经存在的 OpenAI 本地 Agent 会话，直接集成到 Prosio 系统菜单栏。状态栏图标显示执行中或待处理数量（待处理优先），弹出菜单中的「Agent」页显示计数和最多五条任务，点击任务进入详情窗口。应用启动后每五秒读取，关闭详情窗口继续监控；显式暂停会被记住，退出应用停止读取。扫描不运行模型，不启动新的 Agent，不向原任务发送输入。

支持本地 Codex Desktop、ChatGPT Work / Codex 桌面来源、Codex CLI、Codex IDE 会话。来源根据实际元数据识别；桌面 originator 优先于 source，避免 `codex_work_desktop` 同时记录 `source=vscode` 时被误标为 IDE。**普通 ChatGPT 聊天和纯云端任务未接入**，不得将本地会话能力泛化到全部 ChatGPT 产品。

本次交付覆盖原四阶段中的「接入与状态观察」。回答、暂停 Agent、语音回传和 Apple Watch 属于后续阶段，窗口明确标注当前只读。

## 体验

- 任务范围：需要处理、执行中、最近会话。默认先看已确认的待回答问题和失败事项。
- 每条任务显示名称、来源、状态和最近活动时间；详情显示当前工具活动、结构化问题及选项、项目、模型和子 Agent 标记。
- 使用真实状态名称：执行中、等待你回答、本轮已结束、已中断、执行失败、空闲、状态待确认。
- `task_complete` 只表示本轮结束，不表示项目目标完成。普通助手消息中的问号不能自行升级成待决策事项。
- 异步提问工具立即返回的只是受理结果，不能当作用户回答；本版不根据它推断执行阻塞，等待状态以同步提问或运行实例标志为依据。
- 从日志推导的执行／等待状态三分钟没有可确认活动后降为状态待确认。实例查询得到的状态在本次查询时有效。
- 查看信息不触发确认。用户需要回答时回到来源应用；打开应用不承诺自动定位具体会话。
- 暂停监控明确显示「当前为上次读取结果」，取消中的旧扫描不得覆盖新结果。

## 接入结构

`AgentObserving` 是观测接口；`AgentTask`、`AgentTaskState` 和 `AgentSurface` 是统一数据层。Codex 接入单独负责事件格式，UI 不直接读取 JSONL。后续 Cursor / WorkBuddy 实现各自的观测适配器即可复用展示层。

控制能力未来采用独立接口和能力声明，不将「已接入」等同于「支持回答／审批／暂停」。任务的稳定标识需包含 provider 与设备；目前单 provider、单本机。

### 运行实例查询

仅尝试连接已有的 `.codex/app-server-control/app-server-control.sock`，不创建服务，不调用 `thread/resume`。允许的 RPC 为 initialize、thread/loaded/list、thread/read；后者 `includeTurns=false`。

已加载不等于执行中，读取 `thread.status` 和 activeFlags 判断执行、等待审批／输入、空闲和错误。未知状态保守显示待确认。最多读取 32 个已加载会话，整次查询最多四秒；失败即回退日志，旧实例状态不会继续冒充当前状态。

使用 Unix WebSocket，校验握手摘要、屏蔽 SIGPIPE、限制消息一 MiB和总接收八 MiB。支持分片、Ping/Pong；不回应审批或其他服务器请求。连接结束直接释放本客户端，不改变现有 Agent 执行。

### 本地记录

默认使用进程 `CODEX_HOME` 或 `~/.codex`，用户可选择其他目录。只读取 sessions 下最近十四天的日期目录、最多一百个最近会话，以及 session_index.jsonl 中的标题。

每文件首次读元数据头部（最多 64 KiB）和近期尾部（最多 512 KiB），后续只读新增字节。大型记录、追赶过快、截断和替换均有界处理；不完整末行保留到下次读取。删除的文件移出列表；读取失败不得继续报告执行中。文件符号链接不读取，标题文件最多读取近期二 MiB。

原始聊天仅在解析单个块期间短暂存在，不保存完整聊天、工具参数、工具输出和登录凭证。只保留任务元数据、当前工具名和结构化问题。标题／问题仍可能含私人内容，在本机菜单和详情中显示。监控跟随菜单栏应用运行，用户可在菜单中暂停。

## 验收与测试

独立无宿主测试项目位于 `tools/agent-monitor-validation`，不启动或替换用户的 Prosio 应用。覆盖来源识别、旧 turn 回执、问题绑定、过期状态、未知事件、增量读取、部分行、大文件、截断／删除、符号链接、取消扫描、列表过滤和实例只读协议。

Unix Socket 测试使用自己的临时假服务，验证分片、Ping、审批请求不被回答、恶意握手、大消息和超时；校验调用清单中没有 resume/start/steer/interrupt。

界面使用独立原生预览程序和人工构造任务渲染浅色／深色，避免在截图中暴露真实会话。真实本机验证仅输出计数、来源类型和读取性能，不输出用户对话内容。

## 资料与已知边界

- [Codex App Server 官方文档](https://learn.chatgpt.com/docs/app-server)
- [Codex Status Bar 的本地监控实现](https://github.com/Jas952/codex-status-bar/blob/main/hooks/ui-monitor.js)
- [codex-monitor 的现有实例发现](https://github.com/lucianlamp/codex-monitor/blob/main/src/target.rs)

实现是独立编写的，不复制社区项目代码。本地日志与套接字均需随 Codex 版本验证；当前机器未发现该控制套接字，因此真实运行实例查询未完成真机验证，协议路径由假服务覆盖。本地日志可能批量写入，所以不能承诺所有执行步骤即时可见。窗口明确提供来源、时间和降级提示。

下一阶段门槛：在具有可用控制接口的真实版本中确认原线程和回执，再开放向原任务回复。Apple Watch 必须等双向闭环、问题版本和重复提交处理完成。
