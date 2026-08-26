# DingTalk 通道接入设计（dingtalk-stream 原生适配器）

> 状态：📝 设计稿（尚未实现）
> 更新：2026-08-26
> 关联：docs/channel-design.md（Channel 统一抽象）、docs/channel-dingtalk-plugin.md（对照：官方插件托管方案）、core/lib/channel.js、core/lib/channel-runner.js、platforms/macos/src/ChannelPanel.swift
> 依据：钉钉官方 Stream SDK open-dingtalk/dingtalk-stream-sdk-nodejs（npm dingtalk-stream，v2.1.x）源码 + 钉钉开放平台 device-code 应用注册接口
>
> 本文档描述**独立于官方 dsh-dingtalk 插件**的实现方案：直接用 dingtalk-stream SDK 在 core/ 内实现钉钉适配器，走与微信（weixin-clawbot）**完全同构**的「core 适配器 + channel-runner 子进程 + channel store」路线。**只描述设计，不包含实现代码。**

## 1. 目标与背景

把钉钉接入 Channel 面板的 Dingtalk 卡片，采用与微信 ClawBot **相同的架构形态**，从而让钉钉与微信共享**同一套面板模型**（扫码登录、连接状态、项目视图会话/消息、每会话跨项目路由），**彻底消除**「插件托管方案」带来的工作区语义不一致问题。

**核心架构决策：钉钉 = core/ 适配器（dingtalk-stream），非插件托管。**
- 在 core/lib/ 内实现 dingtalk-stream-transport.js + dingtalk.js 适配器，复用 channel.js 的统一抽象（ChannelEvent/Reply/状态机/Router）。
- 由 channel-runner.js 的 runDingTalkChannel 编排成独立子进程（与 runWeixinChannel 同构），写入**同一个 channel store**（~/.dsh/channels/<id>.sessions.json + 消息分桶 + state.json）。
- 面板复用微信的**扫码向导** + **项目视图**，零语义分歧。

> 与 docs/channel-dingtalk-plugin.md（官方插件托管）二选一，本文档为「原生适配器」路线；二者**接入体验一致**（都可扫码自动创建应用，复用钉钉 device-code 注册接口，见 §4），区别在运行时与工作区/路由能力（见 §7）。

## 2. dingtalk-stream SDK 能力（已核实）

dingtalk-stream（npm，v2.1.x，依赖 axios/ws/debug，Node ≥16，内置 node v24.19.0 ✓）：

- **连接**：new DWClient({ clientId, clientSecret, autoReconnect, keepAlive, debug }) → client.connect() / client.disconnect()；内置自动重连（指数退避 1s→60s）+ 心跳 + 事件去重。
- **收消息**：client.registerCallbackListener(TOPIC_ROBOT, cb)，TOPIC_ROBOT = '/v1.0/im/bot/messages/get'；回调收到 DWClientDownStream（.data 为 JSON 字符串，.headers.messageId）。机器人文本消息字段：{ msgId, conversationId, chatbotCorpId, chatbotUserId, senderNick, senderStaffId, sessionWebhook, sessionWebhookExpiredTime, createAt, conversationType, msgtype:'text', text:{content}, robotCode }。非 text（image/richText/file 等）需自行解析原始 .data 的扩展字段。
- **回消息**：POST sessionWebhook（消息自带的会话回复地址，有时效）携带 { at, text, msgtype }，header x-acs-dingtalk-access-token: <accessToken>。
- **access token**：client.getAccessToken() → GET https://oapi.dingtalk.com/gettoken?appkey=...&appsecret=...；需缓存并到期前刷新。
- **回执去重**：client.socketCallBackResponse(msgId, result) 返回响应，避免 60s 内服务端重推；长任务需先回执或按 msgId 去重（配合 seen store）。
- **卡片回调**：TOPIC_CARD = '/v1.0/card/instances/callback'（审批/互动卡片，本期可选）。
- **状态暴露**：.connected/.registered/.reconnecting 标志，映射到统一状态机。

## 3. 整体架构（与微信同构）

```
钉钉开放平台（机器人应用, AppKey/AppSecret）
  │  Stream 长连接（出站、免公网）
  ▼
core/lib/dingtalk-stream-transport.js（DWClient 封装：connect/收/回/去重/token）
  ▼
core/lib/dingtalk.js（ChannelAdapter：onEvent/send/getState/connect/disconnect，仿 weixin-clawbot.js）
  ▼
core/lib/channel-runner.js（runDingTalkChannel，仿 runWeixinChannel）
  ├─ createChannelManager（Router + SessionDriver，复用）
  ├─ createSessionDriver（session.create/prompt/…，HTTP RPC，复用）
  ├─ createChannelSessions（消息/会话持久化 → channel store，复用）
  ├─ createCommandRunner（/help /new /sessions /wks #wN/#sN，复用）
  └─ jobqueue（串行，复用）
  ▼
~/.dsh/channels/<id>.sessions.json + 消息分桶 + state.json（channel store，复用）
  ▼
ChannelPanel.swift 项目视图（ChannelStoreReader，与微信完全一致）
```

**复用点（零改动或极小改动）**：createChannelManager、createSessionDriver、createChannelSessions、createCommandRunner、createQueue、resolveWorkspaceTag、createChannelRuntimeStore、channel-store.js。新增点集中在 transport + adapter + runner 的 dingtalk 分支。

## 4. 接入 / 扫码创建应用（device-code）

`dingtalk-stream` SDK 本身**没有**「扫码创建应用」能力，但可复用钉钉开放平台 **device-code 注册**接口在面板内完成扫码自动创建（见下）。

**扫码创建应用时序**：

```
 用户(手机钉钉)     面板(ChannelPanel)     本地子进程(channel login)      钉钉开放平台           channel store
      │                  │                        │                        │                  │
      │  ① 点击钉钉卡片    │                        │                        │                  │
      │─────────────────►│                        │                        │                  │
      │                  │  ② spawn channel login  │                        │                  │
      │                  │────────────────────────►│                        │                  │
      │                  │                        │ ③ init {source}          │                  │
      │                  │                        │───────────────────────►│                  │
      │                  │                        │ ④ begin {nonce}          │                  │
      │                  │                        │───────────────────────►│                  │
      │                  │                        │◄── device_code+二维码URL │                  │
      │                  │                        │                        │                  │
      │                  │ ⑤ stdout 打印二维码URL  │                        │                  │
      │                  │◄───────────────────────│                        │                  │
      │                  │ ⑥ qrImage 渲染二维码    │                        │                  │
      │                  │                        │                        │                  │
      │ ⑦ 手机钉钉扫码授权 │                        │                        │                  │
      │◄─────────────────│                        │                        │                  │
      │                  │                        │ ⑧ 轮询 poll{device_code} │                  │
      │                  │                        │── WAITING/FAIL/SUCCESS ─►│                  │
      │                  │                        │◄─ SUCCESS:client_id/sec  │                  │
      │                  │                        │                        │                  │
      │                  │                        │ ⑨ 写 AppKey/AppSecret   │                  │
      │                  │                        │───────────────────────►│ (chmod 600)      │
      │                  │                        │                        │                  │
      │                  │ ⑩ 回告成功 → 起 runner  │                        │                  │
      │                  │◄───────────────────────│                        │                  │
```

**扫码创建应用可复用（已实证）**：钉钉开放平台提供 **device-code 设备码注册**接口，可直接用于自动创建应用：
- `init`/`begin` 对**任意 source 都返回 errcode:0** 并下发 device_code + 二维码（实测无效 source 同样成功），**接口层不校验 source**；
- 二维码指向 **`https://open-dev.dingtalk.com/openapp/registration/openClaw`**——这是钉钉**标准应用注册流程**的路径（DeepSeek Harness 钉钉插件文档同样使用该地址），`source` 只是可选的归属标签（如 `DING_DSH`），**不构成复用障碍**。
- 扫码后在手机钉钉授权 → 自动创建「企业内部应用 + 机器人」→ 轮询 `poll` 得 **AppKey(AppId) + AppSecret**，交由持有 device_code 的调用方使用。

**结论：独立适配器采用扫码创建应用（主路径）+ 手动填凭据（备选）**：
- 面板走与微信一致的**扫码向导**：调用 `init/begin` 得二维码 → `onQRUrl` → 面板 `qrImage(from:)` 渲染 → 用户手机钉钉扫码 → 后台轮询 `poll` 得 AppKey/AppSecret。
- 凭据写入 channel-store.js 的 <id>.json（chmod 600，文件优先；Keychain 兜底可复用既有模式）。
- 备选：已有钉钉应用时，面板手动填 AppKey/AppSecret。

### 4.1 本地轮询职责（device-code poll）

注册的**轮询完全在本地 Node 子进程**（`channel login`，App spawn）内完成，面板只做两件事：spawn 该进程 + 从 stdout 捕获二维码 URL 渲染。本地轮询要点：
- 用 `begin` 返回的 **device_code** 作为 `poll` 凭据（面板/其它端不保存）。
- 每 **`interval`**（实测约 2s）轮询一次 `POST /app/registration/poll`：
  - `WAITING` → 继续轮询；
  - `SUCCESS` → 取出 **client_id(AppKey)/client_secret(AppSecret)**，写入 channel store（chmod 600）；
  - `FAIL` → 取 `fail_reason` 报错；
  - `EXPIRED` → 超时提示重扫；
  - 瞬时网络错误 → 2 分钟重试窗口内继续；
  - 总超时以 `expires_in`（默认 7200s）为界。
- 成功后结束子进程，回告面板成功/失败。

## 5. 分系统改动

### 5.1 core/lib/dingtalk-stream-transport.js（新增）
实现 transport 契约（对齐 weixin-clawbot-transport.js 的接口，便于 adapter 复用同一套状态机/事件路径）：
- connect()：校验 clientId/clientSecret → DWClient.connect()；错误映射到状态机。
- 事件驱动收消息：注册 TOPIC_ROBOT 回调，把原始消息归一化为 { conversationId, sender, text, msgId, sessionWebhook, ts, msgtype }；非 text 降级为文本提示。
- sendMessage(reply)：getAccessToken()（缓存+刷新）→ POST sessionWebhook → socketCallBackResponse(msgId, result) 回执。
- sendTyping：钉钉无「正在输入」指示，可 no-op 或发一条「🫡 收到，处理中…」文字 ack（见 §7 取舍）。
- onError / 状态上报；seen 去重（msgId，TTL，避免服务端 60s 重推重复处理）。
- 依赖：构建期把 dingtalk-stream（及 axios/ws/debug）打入 runtime npm（自包含原则）。

### 5.2 core/lib/dingtalk.js（新增，适配器）
仿 weixin-clawbot.js 实现 ChannelAdapter：platform='dingtalk'、onEvent/send/connect/disconnect/getState/onState/dispose；内部包 transport + createStateMachine；接入失效（gettoken 失败/连接断开/凭据失效）归一到 auth-expired / reconnecting。

### 5.3 core/lib/channel-runner.js（扩展）
新增 runDingTalkChannel，**镜像 runWeixinChannel 的编排**：
- buildDingTalkAdapters：按 refs/ensureChannelId 建 adapter（transport + 账号凭据来自 loadChannelAccount）。
- 复用 createChannelManager、createSessionDriver、createChannelSessions、createCommandRunner、createQueue、createChannelRuntimeStore、workspace-tag 路由、busy 门、dispatchGeneration（把 sendTyping 换成钉钉的 ack/no-op）。
- **工作区语义 = 微信完全一致**：由 runner 自身做**每会话跨项目路由**（refs 绑定 + workspace-tag + 当前工作区），**不依赖**插件单工作区；因此插件方案 §6.2.1 里「项目视图数据源需改用 dsh RPC」的问题**不存在**——钉钉 runner 写 channel store，面板项目视图直接可显示会话与消息。

### 5.4 面板（ChannelPanel.swift + main.swift）
- cardTapped：dingtalk 走与微信**相同的扫码向导**（非 beep）；feishu 维持 beep。
- channelLoginRunner 分发：微信走 runChannelLogin（weixin 扫码）；钉钉走 runDingTalkLogin（device-code 扫码：init/begin → 面板 QR → poll → 写 channel store）。
- startConfiguredChannelRunners：钉钉 channel 照常启动 runDingTalkChannel 子进程（与微信一致，**不**跳过）。
- 面板项目视图、全局配置、状态徽标（读 <id>.state.json）**零改动复用**。

### 5.5 L10n / 文档 / 构建
- L10n：更新 channel.card.dingtalkDesc（「待实现」→ Stream 连接器描述）+ 扫码向导文案（中英成对）。
- 构建：dingtalk-stream 依赖打入 runtime npm（swift-sources.sh 不涉及，仅 npm 打包）。
- 文档：更新 docs/channel-design.md §7 矩阵钉钉行（Stream 连接、AppKey/AppSecret、dingtalk-stream SDK）；本方案与 channel-dingtalk-plugin.md 并列，注明二选一。

## 6. 数据流（入站 → 分发 → 会话 → 回复）

```
钉钉机器人消息（Stream） → transport 归一化 ChannelEvent{channelId, conversationId, sender, text, ts}
  → adapter.onEvent → Router（refs 绑定/关键词/默认，跨项目）→ 命中项目
  → createSessionDriver（session.create(workspaceId|cwd) → prompt → poll → lastMessage）
  → createChannelSessions 写 channel store（会话/消息分桶）
  → adapter.send → POST sessionWebhook（access token）+ socketCallBackResponse 回执
  → 面板项目视图经 ChannelStoreReader 实时显示（与微信一致）
```

## 7. 与「官方插件托管」方案对比

| 维度 | 原生适配器（本文档） | 官方插件托管（channel-dingtalk-plugin.md） |
|---|---|---|
| 运行时 | core/ 适配器 + 独立 runner 子进程 | dsh web 内 Cordis 插件 |
| 面板模型 | 与微信完全同构（同 store/同扫码/同项目视图） | 需额外改造项目视图数据源 |
| 工作区/路由 | runner 自己做每会话跨项目路由（=微信能力全对齐） | 插件单 config.workspace，v1 仅「当前工作区」 |
| 富特性（AI Card 流式/审批卡/图片/DWS） | 需自行实现（v1 用文本/Markdown 回复） | 插件自带（AI Card、互动卡片、图片、DWS） |
| 维护成本 | 自行维护 transport（重连/去重/token/媒体） | 插件维护；面板只编排/观测 |
| 依赖 | 新增 npm 依赖 dingtalk-stream | 装官方插件到 web profile |

**取舍**：原生适配器换取**面板一致性与微信能力全对齐**（含每会话路由、项目视图零改造），代价是**不直接用插件的富交互特性**（v1 以文本/Markdown 回复为主，AI Card/互动审批卡/图片/DWS 视需要后续补齐或并行用插件）。

## 8. 决策项（待确认）

| 决策 | 问题 | 推荐默认 |
|---|---|---|
| E1 | 选原生适配器还是官方插件托管 | 本文档（原生适配器）：面板一致性优先；若更看重 AI Card/审批卡/DWS 等富特性可改选插件方案 |
| E2 | 回复载体 | v1 用文本/Markdown（POST sessionWebhook）；AI Card 流式留作增强 |
| E3 | 长任务去重 | 收到即回执 + msgId seen 去重（避免 60s 重推重复处理） |
| E4 | 多账号 | 与微信一致：1 个 GlobalChannel = 1 个钉钉应用；面板可建多个钉钉通道（各自扫码） |
| E5 | 工作区语义 | 与微信一致：runner 每会话跨项目路由，无「1 账号 1 工作区」歧义 |
| E6 | 应用凭据获取 | **扫码自动创建（device-code，主路径）+ 手动填 AppKey/AppSecret（备选）**，与微信扫码体验一致 |

## 9. 边界与失败处理

| 场景 | 行为 |
|---|---|
| clientId/clientSecret 缺失 | 扫码创建应用 / 手动填凭据；未配置时状态 disconnected，登录失败提示 |
| gettoken 失败 / access_token 过期 | 缓存+刷新；失败归一到 auth-expired，受控重连 |
| Stream 断线 | DWClient 自动重连；adapter 状态 reconnecting |
| 服务端 60s 重推 | 收到即回执 + msgId seen 去重 |
| 非 text 消息（图片/文件） | 降级为文本提示；如需媒体走后续增强 |
| sessionWebhook 过期 | 消息自带时效，过期重扫或提示重新触发 |
| 并发消息 | 复用 jobqueue（source: remote）同会话串行 |

## 10. 测试与验收

- **core 单测**：core/tests/dingtalk.test.js（适配器/状态机）、core/tests/dingtalk-stream-transport.test.js（mock Stream/HTTP：入站归一化、sessionWebhook 回发、gettoken 缓存刷新、msgId 去重、非 text 降级）——参照 e2e-channel.test.js 的 mock 方式。
- **Swift 无头单测**：面板扫码向导/登录分发（仿 weixin 用例）。
- **手动验收**：面板点钉钉 → 面板内扫码二维码 → 手机扫码创建应用 → 凭据写入 → runner 起连 → Stream connected → 钉钉私聊发消息 → 路由到项目 → dsh 会话生成 → 回复回钉钉 → 面板项目视图显示会话与消息 → 每会话跨项目路由验证。
- 提交前保持既有测试全绿；CI 自动跑。

## 11. 明确不在本次范围

- 不实现 AI Card 流式 / 互动审批卡 / 图片 / DWS（留作后续增强，或并行采用官方插件）。
- 不 fork 官方插件、不依赖 @dingtalk-real-ai/dsh-dingtalk。
- feishu 通道维持现状（待实现）。