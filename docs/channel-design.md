# Channel 能力设计（多平台统一抽象）

> 状态：📝 设计稿（尚未实现）
> 更新：2026-08-21
> 关联：docs/issue-runner-design.md（「远程驱动预留」章节）、.dsh/wiki/data-model.md、.dsh/wiki/modules/main.md、docs/milestones/M2-windows.md、docs/milestones/M3-linux.md、core/（共享核心）

## 1. 目标与范围

**Channel** 是 oh-my-dsh 壳层接入外部消息平台（微信、钉钉、飞书等）、收发消息，并把收到的消息驱动到 dsh 会话/项目、最后把结果回复回原平台的统一能力。

本设计第一原则是：**统一协议 + 平台适配器**。即平台差异（连接形态、消息编解码、鉴权）全部收敛到「适配器」层，上游的配置模型、分发路由、配置面板、会话驱动一律平台无关。这样后续新增钉钉、飞书等平台时，只实现一个适配器，不改任何上游逻辑，保证扩展性与设计一致性。

本文档为设计稿，不涉及实现代码。

## 2. 设计原则

1. **平台无关的统一抽象**：所有平台都归一为同一套事件模型、生命周期、回复模型；平台差异只体现在适配器内部。
2. **适配器可插拔**：每个平台一个 ChannelAdapter，自包含其平台 SDK；新增平台 = 新增适配器，不改上游。
3. **配置分层**：全局定义 Channel（平台无关 + 平台连接参数），项目下「引用」全局 Channel（平台无关），保证一处登录、多项目复用、且新平台接入时配置模型不变。
4. **确定性路由**：收到的消息一次路由到一个项目，规则可预期（显式绑定 > 关键词 > 默认）。
5. **复用既有能力**：消息分发复用 dsh 既有 session.create(workspaceId|cwd) + session.prompt(mode: queue) + 任务队列 core/lib/jobqueue.js（其 source 字段即为「远程驱动」预留）。
6. **凭据安全**：连接凭据不落 UserDefaults 明文，沿用 GitHub token 的「Keychain + 文件（chmod 600）」模式。

## 3. 统一抽象层

### 3.1 规范化事件模型（平台无关）

入站事件 ChannelEvent：

    {
      channelId: string;          // 全局 channel 实例 id（跨平台唯一）
      platform: "weixin-clawbot" | "dingtalk" | "feishu" | string;  // 平台标识
      conversationId: string;     // 会话标识：群聊 id 或私聊/单聊 id（平台无关归一化）
      sender: string;             // 发送者标识（可选）
      text?: string;              // 文本内容（可能来自语音转写）
      media?: {                   // 附件（图片/语音/视频/文件）
        type: "image" | "audio" | "video" | "file";
        filePath?: string;        // 本地已解密路径（如适用）
        url?: string;             // 远端 url（如适用）
        mimeType?: string;
        fileName?: string;
      };
      ts: number;                 // 时间戳
    }

回复模型 ChannelReply：

    {
      text?: string;               // 回复文本（支持 markdown，发送前转纯文本）
      media?: {                    // 回复媒体（可选）
        type: "image" | "video" | "file";
        url: string;
        fileName?: string;
      };
    }

### 3.2 统一生命周期与状态机

    disconnected → connecting → connected ⇄ reconnecting
                                    │
                                    ▼
                              auth-expired

- 平台侧各类鉴权失效统一归一为 auth-expired（微信 -14、钉钉 token 过期、飞书推送鉴权失败），适配器负责据此触发受控重连/重新登录。
- 面板据此展示统一的连接状态徽标。

### 3.3 ChannelAdapter 抽象接口

    interface ChannelAdapter {
      readonly platform: string;
      readonly channelId: string;
      async connect(): Promise<void>;                        // 建立连接（含登录态校验）
      async disconnect(): Promise<void>;                     // 断开
      onEvent(cb: (event: ChannelEvent) => void): void;      // 订阅入站消息
      async send(conversationId: string, reply: ChannelReply): Promise<void>; // 回复
      getState(): "disconnected" | "connecting" | "connected" | "reconnecting" | "auth-expired";
      dispose(): void;
    }

新平台接入 = 实现该接口 + 声明其「连接/登录」表单字段，上游配置/路由/面板零改动。

### 3.4 跨平台复用分层约束（与 M2/M3 对齐）

本项目为「平台壳层 + 共享核心」双层架构（macOS 现为 Swift/WebKit；Windows（M2，WinUI 3 + WebView2）与 Linux（M3，GTK4 + WebKitGTK）复用 `core/` 共享核心）。Channel 逻辑须遵循同样分层，保证三平台复用、不重复实现：

**可跨平台复用（放入 `core/`，Node，平台无关）：**
- 规范化事件模型 ChannelEvent / ChannelReply / 生命周期状态机（纯逻辑，无 UI）；
- ChannelAdapter 抽象接口 + **各平台适配器本体**（微信/钉钉/飞书 SDK 均为 Node，与 OS 无关）；
- 消息分发 Router（路由匹配、项目引用解析——纯逻辑）；
- dsh 会话驱动（session.create/prompt/cancel 走 HTTP RPC，本就跨平台）；
- 串行队列 jobqueue（已在 `core/lib/jobqueue.js`）。

**平台相关、各平台壳层实现（仅薄适配，不重写核心）：**
- Channel 配置面板 UI（Swift AppKit / C# WinUI / Rust GTK 各自实现，但只渲染平台无关列表 + 委托适配器渲染连接表单）；
- 凭据读取：macOS 用 Keychain + 文件；Windows/Linux 无 Keychain，直接用文件（chmod 600）——文档的「文件优先」方案天然跨平台；
- 扫码登录的二维码渲染（各平台图形库）。

**硬约束：** 新增平台只移植壳层薄层，禁止把核心逻辑（事件/状态机/适配器/路由/会话驱动）写进平台壳层导致三份重复。核心逻辑变更须在 `core/` 内一处修改、三平台同步生效。这与终端面板「模拟器共享 + PTY 适配层隔离」、M2/M3「复用共享核心」的既定模式一致。

## 4. 配置模型（全局 + 项目引用）

### 4.1 全局 Channel（UserDefaults + Keychain 凭据）

    interface Channel {
      id: string;
      platform: "weixin-clawbot" | "dingtalk" | "feishu" | string;
      name: string;                 // 用户可读名称
      enabled: boolean;
      state: "disconnected" | "connecting" | "connected" | "reconnecting" | "auth-expired";
      connection: PlatformConnection; // 平台特定连接参数（适配器驱动表单）
    }

- 元数据（id/platform/name/enabled/state）存 UserDefaults（键形如 channel.global.<id>）。
- **连接凭据不落 UserDefaults 明文**：沿用 GitHub token 模式——Keychain 专属 + 文件（~/.dsh/channels/<channelId>，chmod 600）双写，App 与外部工具/代理共用；读取优先文件、Keychain 兜底。

**凭据读写决策（2026-08-21 记录，沿用既有 GitHub token 实现）：**
- **读取硬性约束：绝不因读取弹密码/授权框。** 运行时一律**文件优先**（`~/.dsh/channels/<channelId>`），仅在文件缺失时兜底读 Keychain。正常路径全程零弹窗。
- **写入双写**（Keychain + 文件 chmod 600）。Keychain 条目用 `kSecAttrAccessibleAfterFirstUnlock` **且不设 per-app ACL**（对应 `IssueRunnerPanel.swift` 既有 `saveToken` 注释：token 为低敏感凭据，每次读取弹 ACL 提示对后台 shell 不可接受）——因此写入不弹「App 想要访问钥匙串」授权框。
- **为何保留 Keychain（而非纯文件）**：① 兼容存量（老版本/命令行 `security` / 外部代理写入的条目）；② 文件被删/损坏时的恢复备份；③ 系统托管、防文件篡改。文件仍是唯一读取权威，Keychain 仅为兜底备份，不影响零弹窗体验。
- **简化候选（后续可按需采纳）**：若弹窗问题复现，可改为**纯文件方案**（仅 `~/.dsh/channels/<channelId>`，chmod 600，完全不碰 Keychain），读取=写读同一份，零双写；代价是失去系统级备份。

### 4.2 项目引用（.dsh/channels.json）

项目目录下（跟随仓库提交）的 .dsh/channels.json，引用全局 Channel + 该项目专属路由/会话约定：

    {
      "version": 1,
      "refs": [
        {
          "channelId": "<全局 channel id>",
          "workspaceRoot": "<该项目根路径>",     // 归属该项目，会话 cwd 来源
          "routing": {                         // 该项目内路由（平台无关）
            "conversations": ["<conversationId>"], // 显式绑定到该项目
            "keywords": ["@projectA"],           // 关键词/前缀
            "default": false                     // 是否作为默认兜底项目
          }
        }
      ]
    }

字段平台无关，仅 channelId 背后的全局 channel 带 platform。这样：一处全局登录，多个项目各自引用并定义路由。

## 5. Channel 配置面板

- 作为右栏新面板（沿用 PanelController 基件、rightPanelKind 插槽、build-app.sh 编译清单、L10n.table 中英成对文案）。
- **全局视图**：Channel 列表（平台/名称/启停/连接状态徽标），新增/编辑/删除；「连接/登录」表单由当前 platform 适配器驱动（扫码/输入凭证/webhook 地址/回填事件地址）。
- **项目视图**：展示该项目启用的全局 Channel（来自 .dsh/channels.json），可增删引用、配置路由。
- 面板不感知平台细节——只渲染平台无关列表 + 委托适配器渲染连接表单，保证新平台接入后面板一致。

## 6. 消息分发（收到的消息 → 不同项目）

路由是**平台无关**的，统一作用于 ChannelEvent：

1. **路由解析**：按 channelId 找到所有启用了该 channel 的项目引用（来自各项目 .dsh/channels.json）。
2. **匹配优先级**（一次只命中一个项目）：
   - ① conversationId 显式绑定：某项目引用声明了该会话；
   - ② 关键词/前缀：某项目引用声明了匹配 text 的关键词（如 @projectA）；
   - ③ 默认兜底：恰好一个项目引用声明 default: true。
   - 若命中 0 个 → 回复「未绑定项目的提示」；命中 1 个 → 路由；命中 >1 个（规则冲突）→ 取最高优先级且记录日志（确定性优先）。
3. **会话驱动**：session.create(workspaceId=<该项目 workspace> 或 cwd=<workspaceRoot>) → session.prompt(mode: queue, content=<消息文本>) → 轮询 running → 结束后把结果经 adapter.send(conversationId, reply) 回复回原平台。
4. **串行/并发**：沿用 core/lib/jobqueue.js（source: "remote"），同一 conversation 内串行，跨 conversation 可并发；超时/失败/取消各有状态。

> 备注：本设计复用 JobQueue.source（issue-runner-design.md「远程驱动预留」），把「远程消息」与「GitHub issue」视为同一任务队列的不同来源，架构一致。

## 7. 平台矩阵与对比

| 维度 | 微信 ClawBot | 钉钉 | 飞书 |
|---|---|---|---|
| 连接形态 | 个人账号**长轮询** getUpdates（无需公网） | 官方开放平台 + 机器人 **webhook/事件订阅** | 开放平台 + **事件订阅**（长连接/回调） |
| 会话标识 | 微信会话 conversationId | 群/单聊（群 key / openId） | chat_id / open_id |
| 鉴权失效 | -14 token 失效 | access_token 过期 | 推送鉴权 / token 过期 |
| 归一化 | 统一为 ChannelEvent + 状态机 auth-expired | 同左 | 同左 |
| SDK | weixin-agent-sdk（Node） | 官方开放接口（HTTP） | 官方开放接口（HTTP/长连接） |

结论：三者形态不同，但都能无损映射到统一抽象；钉钉/飞书作为后续适配器，可用本设计的一致性回归用例验证。

## 8. 微信 ClawBot 接入可行性分析（重点）

### 8.1 生态与方案对比

| 方案 | 语言/形态 | 说明 | 适配建议 |
|---|---|---|---|
| **wong2/weixin-agent-sdk** | Node/TS | 基于腾讯 tencent-weixin/openclaw-weixin 改造（非官方，学习交流用）；login() 扫码 → start(agent) → Bot（sendMessage 主动发）；Agent.chat(ChatRequest) → ChatResponse；长轮询 getUpdates 无需公网；多类型消息；~/.openclaw/ 断点续传 | **首选**：Node 栈与内置 runtime 一致，事件模型与 ChannelAdapter 天然对应 |
| **SiverKing/weixin-ClawBot-API** | Python | 直连 OpenClaw Weixin HTTP 接口；getupdates/sendmessage；DeepSeek provider；-14 失效受控重连 | 备选/参考：HTTP 协议细节与重连策略可作为 SDK 方案的行为基线 |
| **腾讯官方 OpenClaw Weixin（iLink Bot）** | 官方开放 | 扫码登录微信个人账号，官方开放接口 | 若官方 SDK 提供 Node 绑定，作为首选替换 |

### 8.2 技术契合度

- **运行时**：内置 node **v24.19.0**（≥22），满足 SDK 的 Node ≥ 22 要求。
- **接入形态**：SDK 的 Agent.chat(ChatRequest{conversationId,text,media}) 与统一 ChannelAdapter.onEvent/send 一一对应，适配器实现成本低。
- **无需公网**：长轮询即可收消息，适合纯本机 App 壳层。
- **消息类型**：文本/图片/语音(转WAV)/视频/文件/引用均可在适配器内解码后归一化。

### 8.3 自包含打包

- SDK 需经 npm 装入 Contents/Resources/runtime/（构建期），自包含原则不变；不依赖本机全局安装。

### 8.4 扫码登录 UX 与账号状态持久化

- 面板提供「扫码登录」步骤（二维码/链接），登录成功后 ~/.openclaw/ 保存连接状态（断点续传），重启复用；-14 触发受控重新扫码。
- 连接状态归一到统一状态机，面板展示。

### 8.5 风险与缓解

| 风险 | 缓解 |
|---|---|
| SDK 非官方（学习交流） | 版本锁定 + 内部评审；官方 SDK 可用时替换 |
| 微信个人账号风控/封号风险 | 明确提示用户自担风险；不鼓励批量/营销使用 |
| 单账号模式（每次 login 覆盖） | 面板明确「每 channel 单账号」限制；多号用多 channel 实例 |
| 主动发送依赖 context_token（有时效，24h） | 依赖「至少收到过一条入站消息」+ 定时刷新；过期后提示 |
| -14 断线/过期 | 受控重连（冷却后恢复）+ 状态机 auth-expired |
| 语音转写依赖 silk-wasm 等 | 构建期纳入 runtime；缺失时优雅降级为提示 |

## 9. 数据流（入站 → 分发 → 会话 → 回复）

    平台(微信/钉钉/飞书)
      │ 入站消息
      ▼
    ChannelAdapter.onEvent ──► ChannelEvent{channelId, conversationId, text, media, ts}
      │
      ▼
    Router（平台无关）: 按 channelId 收集项目引用 → 路由规则匹配 → 命中一个项目
      │
      ▼
    dsh session: session.create(workspaceId=cwd) → session.prompt(mode:queue, 消息文本)
      │ 轮询 running
      ▼
    结果 ChannelReply{text/media} → adapter.send(conversationId, reply) → 回复回原平台

## 10. 分阶段实施

- **M0**：本文档（设计稿）。✅
- **M1**：统一抽象层（ChannelEvent/Reply/状态机 + ChannelAdapter 接口）+ 消息分发 Router 骨架，**全部落入 `core/`（Node，平台无关）** + 配置面板（全局 + 项目引用）+ 全局配置模型与凭据存储。
- **M2**：微信 ClawBot 适配器（`core/` 内首个实现，验证抽象）。✅——适配器 weixin-clawbot.js + transport weixin-clawbot-transport.js，**纯官方 iLink Bot 协议**（@tencent-weixin/openclaw-weixin 2.4.6 官方源码直接推导：ilinkai.weixin.qq.com、登录/收/发/媒体/通知全部按官方实现，不参考任何非官方逆向）。
- **M3**：消息分发路由（项目引用匹配 + 会话驱动 + 回复回传，`core/`）。✅——Router + SessionDriver 已在**真实 dsh web** 上端到端验证（见 §11）。
- **M4**：钉钉/飞书适配器（复用统一抽象，验证一致性与扩展性）。📋 待实现。
- **跨平台**：Windows（M2 里程碑）/ Linux（M3 里程碑）壳层仅实现配置面板 UI + 凭据文件层，直接复用 `core/` 全部 channel 核心（见 §3.4）。

## 11. 测试与验收

- **模型层单测**（参照 tests/wiki-panel/ 无头模式）：路由匹配、状态机、配置模型读写（UserDefaults/Keychain 文件）。
- **适配器一致性回归用例**：用一个「假平台适配器」（mock 平台驱动同一 ChannelAdapter 接口）跑统一回归，保证每个新平台通过同一套用例——这是设计一致性的硬约束。
- **Swift 无头单测** + build-app.sh 编译清单登记。
- **跨平台复用验证**：channel 核心逻辑单测在纯 Node 环境运行（`node --test core/tests/*.test.js`，与现有 issues/jobqueue/tasks 单测同规），保证 Windows/Linux 壳层无需改核心即通过——这与 M2/M3「复用共享核心」验收一致。
- **端到端验证（2026-08-21）**：core/tests/e2e-channel.test.js 在**真实 dsh web**（127.0.0.1:3080）上跑通全链路——mock ClawBot transport → ChannelManager → Router（conversation 绑定）→ SessionDriver（create/rename/prompt/轮询/取回复）→ 回复经 adapter.send 回传；session run CLI 为纯会话链路调试命令（不涉微信）。共 99 用例全绿。
- **真实微信双向收发验证（2026-08-21）**：channel login 扫码登录拿 bot_token → getupdates 收到用户入站消息（含 context_token）→ sendmessage 回传 context_token 回复，用户确认收到——官方 iLink 协议收/发/登录全链路在真实微信上跑通；印证主动发送须带 context_token（无 token 的主动发不被投递）。
- **手动 QA**：面板增删 channel、扫码登录、项目引用路由、消息→会话→回复闭环、断线/鉴权失效恢复。

## 12. 边界与失败处理

| 场景 | 行为 |
|---|---|
| 断网/连接断开 | 状态机 reconnecting，指数退避，面板显示 |
| 鉴权失效（-14/token 过期） | 归一到 auth-expired，受控重新登录/扫码 |
| 并发消息 | 同一 conversation 串行（jobqueue），跨 conversation 并发 |
| 无匹配路由 | 回复「该会话未绑定任何项目」的提示 |
| 多项目规则冲突 | 按优先级取最高并记日志（确定性） |
| 代理会话失败/超时 | 标记失败，保留会话可追溯，可重试 |
| 附件类型不支持 | 适配器解码失败时降级为文本提示，不送入会话 |
| 安全与脱敏 | 凭据走 Keychain/文件 chmod 600；日志不落明文 token；消息内容按需脱敏 |

## 13. 明确不在本次范围

- 本设计不实现任何代码（Swift/Node 均不写），不改 main.swift/build-app.sh/wiki 页面；
- 钉钉/飞书仅作扩展设计与一致性验证基线，不在本期实现；
- 不 push、不开 PR。

## 迭代预留

- 平台 SDK 官方化后替换非官方适配器；
- 多账号支持（当前单账号/单 channel 实例）；
- 消息的富媒体双向回传增强；
- 与 issue-runner 的 JobSource 进一步融合（统一「远程任务来源」抽象）。
