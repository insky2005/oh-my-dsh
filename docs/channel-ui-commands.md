# Channel 面板 UI 交互 + 指令体系设计

> 状态：✅ 指令解析 v1 已实现（core）+ 会话/消息持久化已实现；📝 面板 v2 UI 待实现
> 更新：2026-08-21
> 关联：docs/channel-design.md（M2/M3 已实现）、platforms/macos/src/ChannelPanel.swift、core/lib/channel-runner.js

## 1. 目标

把 Channel 面板从「全局列表 + 项目引用列表」的朴素骨架，升级为**引导式 + 会话式**面板；并定义一套**微信/消息平台内的斜杠指令**，让用户在客户端（如微信）远程驱动 dsh 干活。

本文档先落地**设计**，再按优先级实现。

## 2. 面板 UI 交互（状态机）

### 2.1 面板状态机

```
┌──────────── 打开面板 ────────────┐
│  ① 无任何全局配置 → 引导页          │
│     显示「内置 Channel 卡片」        │
│     └ 点卡片 → 配置向导（分步）      │
│  ② 已有全局配置 → 项目视图          │
│     显示当前项目可用 Channel + 会话   │
└──────────────────────────────┘
顶部始终有「全局配置」按钮 → 切回①的配置页（可收起/重开）
```

### 2.2 ① 引导页（无全局配置时）

- **卡片列表**：内置平台卡片（微信 ClawBot / 钉钉 / 飞书），每张卡：图标 + 名称 + 一句话说明 + 状态徽标。
- **点微信卡片 → 配置向导（分步）**：
  1. **提示页**：「打开微信，准备扫码」+「继续」按钮；
  2. **扫码页**：显示二维码 + 状态「等待扫码…」；
  3. **成功页**：拿到 token → 存储到 `~/.dsh/channels/<id>.json` → 提示「绑定成功 ✅」。

### 2.3 ② 项目视图（有全局配置后，默认显示）

- 顶部 header：**「全局配置」按钮**（点回①，可收起/重开）+ 标题 + 关闭。
- **「当前项目可用 Channel」列表**：每个 Channel 一个开关（开启/关闭，写 `.dsh/channels.json`）。
- **会话区**：按 `Channel ▸ Session` 分组的消息列表，实时显示收到的消息和回复。

### 2.4 决策点

| # | 决策 | 建议 |
|---|---|---|
| A | 卡片渲染 | 原生绘制卡片（AppKit），图标 + 说明 |
| B | 二维码显示 | 面板内渲染二维码（vendor qrcode-terminal 画到 NSImage） |
| C | /new 语义 | /new 新建独立会话；其余在当前会话继续（conversationId→sessionId 映射持久化） |
| D | 即时「收到」应答 | 低优先，放 TODO |
| E | 消息持久化 | **落盘到项目下 .dsh 文件**（.dsh/channels/<channelId>.messages.json），按 Channel/Session 分组，重启保留 |

## 3. 消息路由到项目（设计细节）

### 3.1 路由目标

收到的消息要确定「发给哪个项目（workspace/cwd）」，并决定「在这个项目里用哪个 dsh 会话处理」。目标：**一条消息一次路由到一个项目**，规则可预期。

### 3.2 路由输入

- `ChannelEvent`：`{ channelId, conversationId(会话/群聊 id), sender, text, media?, contextToken }`；
- 全局 Channel 配置（`~/.dsh/channels/<id>.json`，含 token/状态）；
- **项目引用表**（各项目 `.dsh/channels.json` 的 `refs`）：`{ channelId, workspaceRoot, routing: { conversations[], keywords[], default } }`。

### 3.3 路由匹配优先级（确定性，一次命中）

| 优先级 | 规则 | 说明 |
|---|---|---|
| ① 显式会话绑定 | `routing.conversations` 含 `event.conversationId` | 某项目声明了该会话 |
| ② 关键词/前缀 | `routing.keywords` 匹配 `event.text`（如 `@projectA`） | 文本提示归属 |
| ③ 默认兜底 | 恰好一个项目 `routing.default=true` | 否则无匹配 |
| 冲突 | 命中多个 → 取最高优先级；同优先级取引用顺序第一 | 记录日志，确定性 |

**无匹配** → 回复「该会话未绑定任何项目（/route 或面板配置）」；不静默丢弃。

### 3.4 会话归属（conversationId → sessionId 映射）

- 每个（channelId, conversationId）在路由到的项目里维护一个「当前 dsh 会话」；
- 映射持久化：`~/.dsh/channels/<id>.sessions.json`（`{ version, sessions: [{ conversationId, channelId, sessionId, projectRoot, name, createdAt, updatedAt }] }`），重启可恢复，跨平台；
- `/new` → 新建会话并**更新映射**（该 conversationId 改指向新会话）；`/switch` → 切换当前会话（改映射）；
- 无映射 → 首次消息自动建会话并记映射。

### 3.5 消息处理流程（含指令）

```
收到消息(ChannelEvent)
  ├─ 先 parseCommand(text)
  │   ├─ 是指令 → 执行指令 handler，回复（带 context_token）——不建项目会话
  │   └─ 非指令 → 进入项目路由
  ├─ Router.match → 命中一个项目（否则回复未绑定提示）
  ├─ 会话映射：查 conversationId→sessionId
  │   ├─ 有 → 复用该会话（同会话继续对话）
  │   └─ 无 → create session(workspaceId/cwd=项目) + 记映射
  ├─ session.prompt(mode:queue, text) → 轮询 running → 取回复
  └─ 回复（带 context_token）→ adapter.send 回客户端
```

### 3.6 与 dsh 会话的关系（重要约束）

- **每个 conversationId 在项目内对应一个 dsh 会话**（多轮对话续接），不是每条消息建会话；
- `/new` 显式开新会话 = 在项目内另起一个 dsh 会话并切过去；
- 跨 conversation（不同群/人）在**同一项目**内可各有一个会话，互不干扰；
- 会话创建沿用 `session.create(workspaceId=cwd)`（归主项目 workspace，无分组错乱——issue-runner-design 已实证）。

### 3.7 失败与边界

| 场景 | 行为 |
|---|---|
| 路由无匹配 | 回复未绑定提示 |
| 会话创建失败 | 回复失败原因，不静默 |
| prompt 超时 | 标记失败，保留会话可追溯，可重试 |
| token 失效(-14) | 归一到 auth-expired，提示重新扫码 |
| 并发消息 | 同 conversation 串行（jobqueue），跨 conversation 可并发 |

### 3.8 消息持久化（决策 E：落盘项目 .dsh）

- 路径：<projectRoot>/.dsh/channels/<channelId>.messages.json（{ version, messages: [{ channelId, conversationId, sessionId, dir: "in"|"out", text, ts }] }）；
- 每收/发一条消息追加一条记录（追加写，控制文件上限：单文件 ≤ 2 MB / 最多保留最近 N=1000 条，超出滚动丢弃最旧）；
- 用途：面板「Channel ▸ Session」消息分组展示、重启保留会话上下文；
- 与仓库内 .dsh/channels.json（引用配置）不同：消息文件含用户消息内容，不入 git（参照 .dsh/tasks/local.json 的 gitignore 惯例，.gitignore 忽略 **/.dsh/channels/）。

### 3.9 workspace 代号 + #tag 路由（消息路由到项目）

**目标**：让用户用简短的代号或 workspace 名，把消息路由到某个项目（workspace）。

- **代号分配**：/workspaces（或别名 /wks）列出所有 dsh workspace，按 path 排序，分配代号 w1、w2…（不区分大小写）：
  w1 指向 path/a、w2 指向 path/b…；
- **#tag 路由**：消息内容中含 #w1（代号）或 #<workspace名>（workspace 的 path/name 片段）→ 消息路由到该项目：
  - 解析优先级：#wN 代号精确匹配 > #<name> 匹配 workspace path/name；
  - 多个 tag 取第一个有效；无有效 tag 则回退（见下）；
  - tag 仅作路由指示，#w1 本身从发往会话的文本中剥离。
- **回退规则**（未指定 #tag 时）：
  1. 沿用「最近一次提到的 workspace」（按 conversationId 记录最近路由目标）；
  2. 若无最近记录则选第一个 workspace（/workspaces 列表第 1 个）。

**/new #w1，开始和我对话**：在 w1 项目下创建新会话并继续对话；/new 后未指定 #tag 则按上述回退规则选项目。

**实现**：core/lib/channel-workspaces.js（workspace 列表 + 代号分配 + #tag 解析，平台无关可单测），接进 runner（会话映射的 projectRoot 据此解析）。

## 4. 指令体系（客户端内斜杠指令）

### 3.1 判定规则

- 消息**整体以 `/` 开头**且**能匹配已知指令** → 当指令处理；
- 否则（如 `/Users/foo` 路径）→ 当普通消息，不误判。
- 指令解析放 `core/lib/channel-commands.js`（Node，平台无关，可单测），接进 `channel-runner`。

### 3.2 第一优先级（MVP，本轮实现）

| 指令 | 作用 | 参数 | 回复示例 |
|---|---|---|---|
| `/help` | 列出指令 | — | 指令清单 |
| `/new [名称]` | 新建独立会话 | 可选会话名 | 已新建会话：xxx |
| `/sessions` | 列出当前项目所有会话 | — | 会话列表（id/名称/时间） |
| `/switch <名称/编号>` | 切换当前会话 | 会话名或编号 | 已切换到：xxx |
| `/status` | 查连接/项目/会话状态 | — | 连接状态/项目/当前会话 |
| `/ping` | 连通性测试 | — | pong（耗时 Nms） |
| `/workspaces` (`/wks`) | 列出 workspace 并分配代号 w1/w2… | — | w1 → path/a |

### 3.3 第二优先级（后续）

| 指令 | 作用 |
|---|---|
| `/commit [message]` | git status → 提交 |
| `/test` | 跑测试 |
| `/issue #123 ...` | 复用 IssueRunner jobqueue 处理 issue |
| `/repo <owner>/<name>` | 绑定/切换仓库 |
| `/clear` | 清空当前会话上下文 |
| `/route <会话> <项目>` | 手动绑定会话→项目 |
| `/pwd` | 显示当前路由项目 |

## 5. core 层实现要点（channel-commands.js + 会话映射）

### 4.1 解析器

```ts
parseCommand(text): { kind: "command", name, args } | { kind: "text", text }
```

- 拆词：第一个空白分隔的词是命令名，其余是参数。
- 只识别已知命令表（`help/new/sessions/switch/status/ping`）；未知 `/xxx` 回「未知指令，/help 查看」。
- 非 `/` 开头 → 普通消息。

### 4.2 命令处理器（依赖注入）

```ts
createCommandRunner({ getSessions, createSession, switchSession, getStatus })
  -> (text) => Promise<string>  // 返回要回复的文本
```

- `getSessions`：列当前项目会话（来自会话索引）
- `createSession`：`/new` 时建 dsh 会话并记 conversationId→sessionId
- `switchSession`：`/switch` 切换当前会话
- `getStatus`：`/status` 返回连接/项目/会话

### 4.3 接入 channel-runner

在 runner 的 `onEvent` 里：先 `parseCommand(event.text)`（见 §3.5 流程）：
- command → 执行 handler，把回复经 adapter.send 发回（带 context_token）；
- text → 走原有 Router → dsh 会话逻辑。

## 6. 实施顺序

1. **本文档**（✅）。
2. **core：channel-commands.js** + 单测（✅ 本轮）。
3. **core：channel-runner 接入指令**（✅ 本轮，含指令优先路由）。
4. **core：channel-sessions.js**（会话映射 + 消息持久化，落项目 .dsh，决策 E）（✅ 本轮）。
5. **macOS 面板 v2 状态机**（引导卡片 + 项目视图 + 全局配置重开）——后续里程碑。
6. 即时「收到」应答、会话消息分组 UI 展示——后续。

## 7. 明确不在本轮

- **已实现（本轮）**：指令解析与执行（/help /new /sessions /switch /status /ping）、channel-runner 指令优先路由、会话映射 + 消息持久化（落项目 .dsh）。
- 面板 v2 UI（卡片/引导/项目视图）——设计已定，代码未实现（后续里程碑）。
- 第二/三优先级指令（/commit /test /issue /repo /clear /route /pwd）——后续。
- 即时「收到」应答——后续（低优先）。
