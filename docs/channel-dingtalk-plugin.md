# DingTalk 通道接入设计（官方插件托管）

> 状态：📝 设计稿（尚未实现）
> 更新：2026-08-26
> 关联：docs/channel-design.md（Channel 统一抽象）、docs/channel-status.md（面板完成状态总览）、core/lib/channel.js、platforms/macos/src/ChannelPanel.swift
> 依据：官方插件仓库 [DingTalk-Real-AI/dsh-dingtalk](https://github.com/DingTalk-Real-AI/dsh-dingtalk)（@dingtalk-real-ai/dsh-dingtalk）源码 + 钉钉开放平台文档
>
> 本文档把「官方钉钉连接器整合进 oh-my-dsh Channel 面板 Dingtalk 卡片」的设计落地成文，作为后续实现的依据。**本文档只描述设计，不包含实现代码。**

## 1. 目标与背景

把官方钉钉连接器（@dingtalk-real-ai/dsh-dingtalk）整合进 oh-my-dsh 的「Channel」右栏面板的 **Dingtalk** 卡片，让用户在熟悉的 Channel 面板里一站式完成钉钉通道的**安装、扫码创建应用、连接状态查看、会话查看**，与已有的微信（weixin-clawbot）扫码流程体验对齐。

**核心架构决策：钉钉 = 插件托管通道。**
面板只做「编排 + 观测」，**不**在 core/ 里重写 Stream、**不**起独立的 channel-runner 子进程、**不 fork 插件**。运行时归插件（运行在 dsh web 内部），面板负责安装编排、扫码引导、状态读取、会话罗列与打开。

> 与设计文档 docs/channel-design.md §7/§10 的历史假设不同：钉钉**不是**「webhook/事件订阅」形态，而是 **Stream 长连接（WebSocket 出站、免公网）**；也不是 core/ 里的适配器，而是 **DSH Cordis 插件**。详见 §2。

## 2. 插件本质（已核实）

官方插件是 **DSH 的 Cordis 插件**（name: dingtalk-channel），通过以下方式接入：

- **安装**：dsh plugin --profile web add @dingtalk-real-ai/dsh-dingtalk@latest，装进 dsh web profile（dsh web 内部运行）。已确认内置 dsh plugin 子命令可用。
- **连接**：用 dingtalk-stream SDK（DWClient WebSocket）建立 **Stream 长连接**，**出站、无需公网入口/回调地址**。
- **运行时**：注入 dsh 的 agents / workspaceRegistry / sessionPersistence 服务，直接驱动 **原生 DSH 会话**（与 weixin 的 HTTP RPC 会话驱动不同）。
- **运行环境**：Node ^22.19.0 || >=24.0.0；oh-my-dsh 内置 node **v24.19.0** ✓。
- **凭据**：存于 $DSH_HOME/.credentials.yaml（默认账号 DINGTALK_CLIENT_ID / DINGTALK_CLIENT_SECRET；多账号用 DINGTALK_ACCOUNT_<ID>_CLIENT_ID 等）。clientId(AppKey)/clientSecret(AppSecret) 是钉钉应用凭据。
- **状态文件**：默认账号 ~/.dsh-dingtalk/runtime.json，其它账号 ~/.dsh-dingtalk/accounts/<id>/ 下：runtime.json（{stream:{status,observedAt}}，status ∈ connecting/connected/reconnecting/stopped）、owner.json（绑定态）、capabilities.json、bindings.json、seen.json、workspaces.json。
- **诊断**：dsh-dingtalk doctor --json 返回按账号的 {result, checks[]}，code 含 stream.connected/reconnecting/stale/not-connected、credentials.missing/verified/rejected、owner.missing/configured、ai-card.* 等。
- **多账号**：一个 dsh web 可同时跑多个机器人，各账号独立凭据、Stream 连接、绑定与状态文件；账号缺凭据/重复 clientId 会被自动 skip（不拖垮其它机器人）。
  - **一个 account = 钉钉开放平台上一个独立应用（机器人）**：各账号用自己的 clientId/clientSecret（AppKey/AppSecret）各建一条 Stream 连接；重复 clientId 会被拒绝，故每个账号必须是不同应用。
  - **多账号默认共享同一个 dsh 工作区**：所有账号用同一个 `config.workspace`（默认 `~/dsh-dingtalk-workspace`），WorkspaceLinker 解析/创建同一个工作区；各账号的会话是独立的原生 DSH 会话，但默认都归属该共享工作区。每个账号的 `/cd` 覆盖与会话映射（bindings.json）**按账号隔离**（各自状态目录），因此可把不同账号 `cd` 到不同工作区。对面板的含义：DingTalkSessionLoader 按工作区列会话时，同一工作区会混入多个账号的会话，需用各账号 bindings.json 区分会话归属（影响 D4/DingTalkSessionLoader 作用域）。
- **能力**：AI Card 流式回复 / Markdown / 文本降级、原生 DSH 会话持久化、模型切换、工作区切换（/cd）、取消与排队、管理员绑定（/bind）、敏感操作审批（文字确认码 / 互动卡片）、图片输入、可选 DWS 工具。

## 3. 扫码创建应用机制（已核实 onboard.ts）

扫码创建钉钉应用 = 纯 HTTP **device-code** 流程（面板可对齐微信扫码体验）：

```
POST oapi.dingtalk.com/app/registration/init  { source: "DING_DSH" }        -> nonce
POST oapi.dingtalk.com/app/registration/begin { nonce }                     -> device_code, verification_uri_complete(二维码内容), expires_in, interval
POST oapi.dingtalk.com/app/registration/poll  { device_code }               -> status: WAITING|SUCCESS|FAIL|EXPIRED
```

- 用户手机钉钉扫码 verification_uri_complete → 自动创建**组织内应用 + 机器人**。
- 轮询到 SUCCESS 时返回 **clientId + clientSecret**（钉钉应用凭据）。
- 超时/失败/过期按 device-code 语义处理（expires_in 默认 7200s，interval 默认 5s）。

**关键约束（决定接入方式）**：扫码拿到凭据后的**落盘在插件内部**（.credentials.yaml 扁平/v1 布局检测 + DSH 写锁 + web-profile upsert），且插件 CLI **没有**非交互的「注册 + 写凭据」子命令（bin.ts 仅 setup/doctor；机器 setup --apply --json 路径刻意排除私密凭据/绑定步骤，属 awaiting_private_credentials 状态）。因此面板**不应自行复刻凭据落盘逻辑**。

## 4. 扫码接入路径（决策项 D5）

### D5-Path1（推荐）：面板渲染二维码 + 插件 CLI 负责写凭据
- 应用 spawn 插件的引导式 setup（可放 TerminalPanel），捕获其 stdout 中的「扫码链接：<verification_uri_complete>」（onboard.ts 的 defaultOnboard 会打印，格式可解析）。
- 面板用微信同款 onQRUrl → qrImage(from:) **在面板内渲染钉钉注册二维码**。
- 用户在手机钉钉扫码；插件子进程自行轮询 poll 并把 clientId/clientSecret 写入 .credentials.yaml + web-profile；面板实时显示状态。
- 二维码之后的步骤（访问策略 / 管理员绑定 / 重启提示）在可见终端完成，或面板按默认值推进。
- **优点**：不重写凭据存储、不 fork、健壮；**缺点**：其余引导步骤仍需终端可见。

### D5-Path2（备选）：纯面板扫码、无终端
- App 自己调 oapi.dingtalk.com/app/registration/* 三接口、面板扫码并轮询拿 clientId/clientSecret，然后**自行写入** .credentials.yaml（需复刻扁平/v1 布局检测 + 写锁 + atomic write + web-profile upsert）——**脆弱、随 DSH 版本变化**；或请插件上游暴露非交互 register --set-credentials 子命令（上游 feature 请求）。
- 仅当坚持「全程不进终端」时选此路，需接受上述代价。

## 5. 数据模型变更

GlobalChannel 增加 kind: "adapter" | "plugin"（默认 "adapter" 兼容现微信）：

- platform == "dingtalk" → kind = "plugin"，id = 插件 **accountId**（默认 default）。
- connection 只存**非机密**元数据：accountId、clientId（AppKey，仅展示）、ownerBound、senderAccess / groupAccess、workspacePath、replyMode 等。**绝不存 Client Secret**。
- loadGlobalChannels / saveGlobalChannels（channel.global.list）兼容旧记录（缺 kind 视为 adapter）。

## 6. 分系统改动

### 6.1 core/（最小改动）
钉钉是插件托管，**不新增 Stream 适配器**。可选新增 core/lib/dingtalk-state.js：纯 Node 读 ~/.dsh-dingtalk/**/runtime.json / owner.json，把 status 归一化为 CHANNEL_STATES，供未来 Windows/Linux 壳层复用（macOS Swift 直接读文件亦可）。若采纳，在 core/lib/channel.js 或独立模块导出，并加 core/tests/dingtalk-state.test.js。

### 6.2 Swift：ChannelPanel.swift
- **卡片分发**（cardTapped）：weixin-clawbot 走现有扫码向导；dingtalk 走**新「扫码配置向导」**（D5-Path1：面板内 QR + 后台插件 setup）；feishu 维持 beep（仍待实现）。
- **DingTalk 向导步骤**：0 介绍 → 1 检查/安装插件 → 2 扫码创建应用（面板 QR，复用 qrImage）→ 3 凭据/绑定/重启（可见终端或默认）→ 4 完成。
- 新增 **DingTalkStateReader**（Foundation 纯读，仿 ChannelStoreReader）：读 runtime.json 的 stream.status + owner.json，映射 GlobalChannel.State；凭据缺失/账号被 skip → authExpired。liveState(for:) 按 kind 分流（plugin → 读钉钉状态文件；adapter → 读 <id>.state.json）。
- **项目视图（数据来源关键点，见 §6.2.1）**：钉钉的对话信息**不能**走既有 ChannelStoreReader（它读通道 store ~/.dsh/channels/<id>.sessions.json，钉钉插件不写该 store）。新增 DingTalkSessionLoader 改用 **dsh RPC** 读取原生 DSH 会话：列会话用 workspace.list + session.list（core 已有 listWorkspaceSessions），消息气泡用 session.history；会话↔钉钉聊天的标注可交叉读插件 bindings.json（conversationId→sessionId）。点会话 → onOpenSession（既有）。

### 6.2.1 项目视图数据来源（钉钉是否会显示不出对话信息？）

**按现状会**：面板项目视图经 ChannelStoreReader.loadSessions(channelId, projectRoot) 读**通道 store**（~/.dsh/channels/<id>.sessions.json + 消息分桶），这套文件由**微信 runner** 写入。钉钉插件不写该 store——它用 agents.create/resume 驱动**原生 DSH 会话**，把「钉钉聊天↔session」映射持久化在自己的 ~/.dsh-dingtalk/accounts/<id>/bindings.json，消息历史存 DSH 会话内部。因此若不改造，钉钉通道在项目视图会显示 0 会话、无对话信息。

**可修复（数据都取得到）**：原生 DSH 会话可通过 dsh RPC 读取——workspace.list + session.list 列会话（core 已有 listWorkspaceSessions），session.history 取会话完整消息（user/assistant，content[].text）以渲染 in/out 气泡，bindings.json 交叉标注钉钉聊天身份。即项目视图数据源应从「通道 store」换成「dsh RPC + 插件 bindings.json」。

**⚠️ 工作区归属（按 D3 决策化解）**：插件会话落在**插件自己的工作区**（config.workspace，默认 ~/dsh-dingtalk-workspace），**不等于 oh-my-dsh 面板的 active workspace（currentRoot）**。按 D3「钉钉跟随当前工作区」处理：App 在项目切换/启用时把插件 config.workspace 同步为当前活动项目（写 config + /cd），使机器人所在工作区 ≈ 面板 currentRoot。DingTalkSessionLoader 以**插件 config.workspace** 为作用域读取（读 config.workspace / 插件 workspaces.json），必要时与面板 currentRoot 交叉。

### 6.3 Swift：main.swift（应用侧编排）
- runDingTalkSetup（新增）：spawn node <runtime-node> <dsh bin> plugin --profile web add @dingtalk-real-ai/dsh-dingtalk@latest（离线本地 registry）→ 成功后引导插件 setup（D5 定路径）；stdout 捕获「扫码链接」→ 回调面板 onQRUrl。
- cardTapped → channelLoginRunner 分发：微信走 runChannelLogin（保留）；钉钉走新路径（不扫码登录微信、不起 runner）。
- startConfiguredChannelRunners / startChannelRunner：**跳过 kind == plugin** 的通道（钉钉不在子进程里 long-poll，连接归 dsh web 内插件）。
- 重启 dsh web：应用拉起的服务可自动/提示重启（决策 D1）。
- 复用既有 resolveNode / CoreBridge.coreCLIPath / rpcPost 模式。

### 6.4 L10n（中英成对，main.swift 的 L10n.table）
- 更新 channel.card.dingtalkDesc（当前「钉钉机器人事件订阅（待实现）」→ Stream 连接器描述）。
- 新增钉钉向导文案：安装插件、扫码创建应用、凭据安全写入、管理员绑定、重启、状态/故障提示等（全部中英成对）。

### 6.5 文档
- 更新 docs/channel-design.md §7 平台矩阵与 §10 M4（见 §8 的交叉引用更新）。
- 更新 docs/channel-status.md 增补「插件托管通道」的状态来源（见 §8）。

## 7. 安全约束（硬性）

- **面板/App 永不采集或持久化 Client Secret**；凭据只存于 .credentials.yaml（插件写入）。
- 凭据落盘必须走插件（D5-Path1 天然满足）；面板只读 runtime.json / owner.json 等状态文件，不读 .credentials.yaml。
- 扫码二维码 URL 可在面板展示（属本机私密终端等价场景），但 /bind 口令等仍走终端。
- 面板不打印 doctor 中未脱敏内容（doctor 输出本身已脱敏）。

## 8. 开放决策（待确认）

以下决策尚未定稿，均在本文档记录推荐默认值：

| 决策 | 问题 | 推荐默认 |
|---|---|---|
| **D5** | 扫码接入路径 | **Path1**（面板内二维码 + 插件 CLI 后台写凭据，其余步可见终端） |
| **D1** | 插件装完是否自动重启 dsh web | 应用自动重启（服务为应用拉起）；或一键提示 |
| **D2** | 钉钉会话/对话信息在面板内如何展示 | 数据源改用 dsh RPC（session.list/workspace.list 列会话、session.history 渲染气泡、bindings.json 标注聊天），不再依赖通道 store；v1 可先「列表 + 在 dsh web 打开」，气泡后加 |
| **D3** | 钉钉通道的工作区语义 | **推荐：钉钉通道跟随面板当前工作区（currentRoot），即微信的「当前工作区」语义**。启用开关保留微信原义（该项目是否启用该通道）；App 在项目切换/启用时把插件 config.workspace 同步为当前活动项目（写 config + /cd），机器人运行在用户当前所在的 dsh 工作区。**不做**微信的「每会话跨项目路由」（需插件支持每会话工作区路由，见下） |
| **D4** | 是否允许多账号 | **推荐：v1 限制单账号（default）**，全局配置无需改动（仅 DingTalk 卡片管理一个机器人）；多账号（1 bot = 1 项目）作为 v2，需全局配置增补账号增删/每账号状态与绑定 UI |

**关于钉钉工作区语义与「1 账号 ↔ 1 工作区」的取舍**：

- **为何不能简单「1 账号 = 1 工作区」**：这会与微信模型不一致、引发歧义。微信是「1 账号跨多项目 + 每会话路由」——项目视图的启用开关 = 该项目是否启用该通道；若钉钉改成「1 账号钉死 1 项目」，同一开关在钉钉上含义就变了（不能多项目启用），用户会困惑。
- **一致的做法（推荐）：钉钉采用微信的「当前工作区」语义**。微信对无绑定消息本就以「当前工作区（currentRoot）」为准（见 channel-association-model.md）；钉钉复用这一定位：机器人运行在用户当前所在的 dsh 工作区，App 在项目切换/启用时把插件 config.workspace 同步为当前活动项目（写 config + /cd）。启用开关保持原义（该项目是否启用），不做跨项目路由。
- **与微信的差异（v2/上游依赖）**：微信 runner 支持「每会话跨项目路由」（会话 A 钉在项目 1、会话 B 在项目 2，即使当前在项目 2）；钉钉插件只有单一 config.workspace，**无法做每会话路由**。v1 明确只支持「当前工作区」模式（文档注明）；若要全对齐，需插件上游支持每会话工作区路由。
- **多账号（v2）**：单账号够用时限制为 default；需要「每项目一个机器人」时放开多账号，每账号一个工作区，全局配置增补账号增删/每账号扫码/状态/绑定 UI。

## 9. 边界与失败处理

| 场景 | 行为 |
|---|---|
| 插件未安装 | 向导第 1 步提供安装；状态显示 disconnected + 原因 |
| 扫码超时 / 失败 | 面板 QR 失效提示重试；插件 poll FAIL / EXPIRED 转成提示 |
| dsh web 未运行 / 需重启 | 提示重启（应用拥有服务） |
| 凭据缺失 / 被跳过 | runtime.json 无记录 / 账号 skip → authExpired，提示走 setup/扫码 |
| Stream 断线 | runtime.json status=reconnecting → 状态机 reconnecting |
| 多账号重复 clientId | 插件自动 skip 并打日志；面板按账号各自显示 |
| dsh 版本过旧（dsh_upgrade_required） | 从 doctor 读 code，提示升级 |

## 10. 测试与验收

- **Swift 无头单测**（tests/channel-panel/channel-tests.swift）：DingTalkStateReader 解析 runtime.json / owner.json、状态映射、多账号目录、文件缺失降级。
- **core 单测**（若采纳 dingtalk-state.js）：node --test core/tests/dingtalk-state.test.js。
- 新增 DingTalkStateReader.swift 由 swift-sources.sh glob 自动收录（仅顶层代码才需显式排除）。
- **手动验收**：面板点钉钉 → 安装 → **面板内显示钉钉注册二维码** → 手机扫码 → 凭据写入 → 重启 → runtime.json connected → 项目视图列出工作区 DSH 会话 → 点会话在 dsh web 打开 → 钉钉私聊真实消息闭环。
- 提交前保持既有测试全绿；CI 自动跑。

## 11. 明确不在本次范围

- 不在 core/ 实现钉钉 Stream 适配器、不起钉钉 channel-runner 子进程（尊重插件托管）。
- 不改插件本体（不 fork @dingtalk-real-ai/dsh-dingtalk；如需非交互注册子命令，作为上游 feature 请求）。
- feishu 通道维持现状（待实现）。
