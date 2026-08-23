---
title: 数据模型
tags: [data-model, userdefaults, rpc, frontmatter, state]
updated: 2026-08-22T05:54:00Z
sources: [platforms/macos/src/main.swift, platforms/macos/src/WikiPanel.swift, platforms/macos/src/TerminalPanel.swift, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/ChannelPanel.swift, core/lib/issues.js, core/lib/tasks.js, core/lib/channel.js, core/lib/channel-store.js, core/lib/channel-runner.js, core/lib/channel-sessions.js, docs/repo-wiki-design.md, docs/issue-runner-design.md, docs/channel-design.md, docs/channel-storage.md, docs/channel-status.md, docs/git-workflow.md]
manual: false
---

# 数据模型

本仓库无数据库：状态以 **UserDefaults** 持久化，进程间/代理间通信走 **HTTP RPC 信封**，磁盘上的"数据文件"是 wiki markdown 页（含 frontmatter）、任务关联索引（`.dsh/tasks/`）与日志。

## UserDefaults 键（壳层持久化状态）

| 键 | 含义 | 出处 |
|---|---|---|
| `appLanguage` | 显式语言选择（"zh"/"en"；删除 = 跟随系统） | `L10n` |
| `appTheme` | 主题（"system"/"light"/"dark"，设置窗口切换） | `AppTheme` |
| `hasCompletedOnboarding` | 首次引导 onboarding 已完成（一次性） | `showOnboardingIfNeeded` |
| `AppleLanguages` | 覆写 WebView 的 `navigator.language`（"zh-CN"/"en-US"） | AppDelegate |
| `dshRegistry` | 运行期 npm registry（删除 = 默认国内源） | `RegistryConfig` |
| `autoUpgradeDsh` | 自动升级开关（默认开） | AppDelegate |
| `lastAutoUpgradeCheck` | 自动升级 24h 节流时间戳 | `runAutoUpgradeIfNeeded` |
| `previewPanelState` | 右栏可见性（true = 打开） | `setRightPanel` |
| `rightPanelKind` | 右栏当前面板（"preview"/"terminal"/"wiki"/"tasks"/"browser"/"channel"） | `setRightPanel` |
| `previewPanelWidth` | 用户拖拽的面板宽度 | `splitViewDidResizeSubviews` |
| `browserLastURL` | 浏览器面板启动恢复的地址（默认 about:blank） | `BrowserPanelController` |
| `browserRenderMode` | 浏览器面板 CEF 渲染模式（"windowed" = 窗口化；删除/缺省 = OSR 离屏默认） | `startBrowserAPI`（`CEFShim.setWindowedMode`） |
| `wikiRootMode` | wiki 根模式（"in-repo" / "dsh-home"） | `WikiPaths` |
| `wikiAutoRegenerate` | wiki 自动更新开关（默认关） | `WikiPaths` |
| `wikiRegisterAgentsMd` | 写入 AGENTS.md 注册块开关（默认关） | `WikiPaths` |

> 凭据不走 UserDefaults：GitHub token 按仓库作用域存储，**读取优先文件**（免 Keychain 每次弹密码）、Keychain 兜底——解析顺序为 文件专属 `~/.dsh/tokens/<owner>-<repo>` → 文件通用 `~/.dsh/gh-token` → Keychain 专属（`oh-my-dsh.issuerunner.github-token.<owner>/<repo>`）→ Keychain 通用（`oh-my-dsh.issuerunner.github-token`）；面板保存时 Keychain 与文件**双写**（Keychain 条目设 `kSecAttrAccessibleAfterFirstUnlock`，文件 chmod 600，App 与外部工具/代理共用），见 [issue-runner-panel](modules/issue-runner-panel.md)。

## 领域模型（代码内）

- **`RightPanel` 枚举**（main.swift）：`none / preview / terminal / wiki / tasks / browser / channel`——右栏插槽互斥状态；
- **`ProjectDirectory`**（main.swift）：壳层共享的"活动项目目录"（`static var current`），跟随 dsh web 当前会话（见 `sessionTrackerScript` 数据流），`resolveProjectDirectory` 优先返回它；
- **`L10n.table`**：`[String: (zh: String, en: String)]` 文案表，`L10n.tr(key)` 按 `lang` 取文案并填充 `%@/%d`；
- **`WikiPage`**（WikiPanel.swift）：`path / title / tags / updated / sources / manual`，由 frontmatter 解析而来；
- **`WikiScanner.Index`**：`pages`、`backlinks`（页面绝对路径 → 引用它的页面列表）、`repoRoot`、`signature`（路径 → mtime，用于变更检测）；
- **`WikiMarkdownRenderer`**：软换行用 Unicode `U+2028` 行分隔符（紧排换行、不产生段落间距；`\n` 在 NSTextView 中会触发段落间距），列表项之间补 `\n`；
- **`TerminalEmulator.Cell`**：`ch / fg / bg / bold / italic / underline / inverse / continuation`；`ParserState`（ground/escape/csi/osc/dcs 等）驱动 ANSI 解析；
- **`TerminalSession.State`**：`running / exited(code) / terminated`；
- **`WikiPanelController.generations`**（内存态，build 59→60）：`[canonicalRepo: Generation]`——生成状态按仓库根（`WikiRPC.canonical` 规范化路径）关联，多仓库可并发各一个生成；`syncGenerationUI()` 据此让 UI 只反映当前仓库；
- **`TreeNode`**（PreviewPanel.swift）：`name / path / isDir / children?`（懒加载）；FilePanel 内另有 file-private 同名 `TreeNode`/`DirRow`（[file-panel](modules/file-panel.md)）；
- **Channel 域模型**（core/lib/channel.js）：`ChannelEvent`（`{channelId, platform, conversationId, sender, text?, media?, ts}`）、`ChannelReply`（`{text?, media?}`）；五态状态机 `CHANNEL_STATES`（disconnected/connecting/connected/reconnecting/auth-expired）；路由优先级 `ROUTE_PRIORITY`（显式会话绑定 3 > 关键词 2 > 默认 1）；`normalizeEvent` / `createRouter` / `createChannelManager`；
- **`JobQueue`**（core/lib/jobqueue.js）：串行任务队列状态机 `createQueue()`——任务含 `source`（"remote" = 通道远程驱动，issue-runner 为另一来源）/`state`（pending/running/done/failed/cancelled）等字段，`enqueue`/`peek`/`markRunning`/`complete`/`fail`/`cancel`/`retry`/`snapshot`/`removeFinished` 操作（IssueRunner 面板用它串行执行「切分支→会话→推送→PR」流水线，见 [issue-runner-panel](modules/issue-runner-panel.md)）；
- **`TaskIndex`**（IssueRunnerPanel.swift，与 core/lib/tasks.js 结构一致）：`.dsh/tasks/` 关联索引读写——`loadIndex`/`mergeTask`/`findTask`/`rememberSession`/`sessionForIssue`；index.json 写 `{"version": 1, "tasks": [...]}`（任务条目可含 `title`，startTask 起写入），local.json 写 `{"sessions": {issue: {sessionId, updatedAt}}}`；
- **任务状态机（IssueRunnerTask.State）**：`pending / running / done / failed / cancelled`，与 JobQueue 的 state 字段一致；`IssueRunnerTask` 另含 `body`（issue 正文 markdown，cb13c97 起由 `parseIssues`/`fetchIssues` 取）；交互为**行内展开详情**（`expandedIssue` 手风琴，c852894 起替代 NSAlert 弹窗）——展开行 168pt 高、详情区可滚动（4576dd2），单元格按钮按状态给动作（pending→Process、running→Cancel Task、done→Open PR、failed/cancelled→Retry，均带 Close；done 且有 PR 额外「评论并关闭 Issue」）；工作区切换到**不同仓库**（owner/repo 变化）时 `applyRepo` 先清空任务列表——issue 号按仓库归属。

## RPC 信封（与 dsh web 通信）

所有 `/api/*` 调用使用 `client-request` 信封（与 web 客户端同协议，见 main.swift `DSHSessionRPC`、WikiPanel.swift `WikiRPC`）：

```json
POST /api/session.list
{ "type": "client-request", "rpcId": "<uuid>", "method": "session.list", "payload": {} }
→ { "result": { "ok": true, "value": { "items": [ { "id": "...", "cwd": "...", "running": true, "updatedAt": 0, "blank": false } ] } } }
```

已用到的 method：`session.list`（cwd 解析、wiki 轮询 running）、`session.create`（payload 可含 `workspaceId` 或 `cwd` 创建会话）、`session.prompt`（payload: sessionId + mode "queue" + content）、`session.cancel`（payload.sessionId 取消生成会话，`WikiRPC.cancel`）、`workspace.list`（`WikiRPC.resolveWorkspaceId` 按规范化路径匹配工作区）、`host.openPath`（被 JS 拦截，不走原生打开）。曾用 `workspace.insertSessionBefore` 的 `WikiRPC.attachOrphans`（把未分组会话归入工作区）已移除（修复 15，build 61→62）：RPC 无 attach 接口，`insertSessionBefore` 只能移动**已入账**会话。

**会话跟随**：`rebuildWebView` 注入 `sessionTrackerScript`，监听 web 客户端 RPC 请求体中的 `payload.sessionId`（`session.history/prompt/rename/selectModel`）与 `payload.parentSessionId`（`subagent.list`），id 变化时经 `dshSession` message handler 上报；壳层 `DSHSessionRPC.fetchSessionCwd(port:sessionId:)` 按 id 查 `session.list` 取 cwd 更新 `ProjectDirectory`，随后**无条件**触发 `tasksPanel.workspaceChanged()`（即使 fetch 失败 cwd 为 nil 也触发——面板解析器回退扫描 `workspace.list`）。

## Wiki 页面数据格式（frontmatter）

每页 YAML frontmatter（`docs/repo-wiki-design.md` §4.3 规范 + `.dsh/skills/repo-knowledge/SKILL.md`）：

```yaml
---
title: <标题>
tags: [a, b]
updated: 2026-08-15T07:19:55Z   # ISO8601 UTC，代理最近触碰时间
sources:                        # 依据的相对路径，供陈旧检测
  - platforms/macos/src/main.swift
manual: false                   # true = 用户手改，代理永不覆盖
---
```

- 目录规范：`index.md / overview.md / architecture.md / modules/<name>.md / data-model.md / conventions.md / tasks.md`（+ `_meta/backlinks.json` 与 `_meta/lock`，设计稿；lock 未实现，v1.7.0 以面板内 generating 标志防重入）；
- 上限：初始生成 ≤ 20 页、单页 ≤ 200 行 / 20 KB、wiki 总量 ≤ 2 MB（超出标「已截断」）。

## 任务关联索引（`.dsh/tasks/`）

任务面板把 issue ↔ branch ↔ PR ↔ state 关联持久化到仓库根 `.dsh/tasks/`（`docs/issue-runner-design.md`「关联索引」章节），两文件分工：

- **`index.json`**（随仓库提交）：仓库级共享关联，`{"version": 1, "tasks": [{ "issue", "branch", "title"?, "prUrl"?, "state", "startedAt"?, "finishedAt"?, "error"? }]}`（按 issue 号升序，upsert 合并）；
- **`local.json`**（`.gitignore` 忽略）：本机级覆盖，`{"sessions": { "<issue>": { "sessionId", "updatedAt" } }}`——dsh 会话 id 是本机实例特有的，不入共享索引。

定位规则：issue→branch 读 index.json（或按 label 约定 `feature/issue-N` / `fix/issue-N`，见 `docs/git-workflow.md`）；issue→session 运行中读内存、重启后读 local.json；issue→PR 读 index.json `prUrl`。App 重启后面板 `restoreFromIndex` 先按两文件重建任务列表与关联，再以 open issues 刷新标题。

## Channel 数据与文件布局（通道 / 消息平台）

通道凭据、通道级状态与项目引用（docs/channel-design.md §4、docs/channel-storage.md）：

| 数据 | 路径 | 写入方 | 说明 |
|---|---|---|---|
| 凭据/账号 | `~/.dsh/channels/<channelId>.json`（chmod 600） | `channel-store.js`（saveChannelAccount） | 文件优先读、Keychain 兜底（零弹窗）；含 botToken/accountId/userId/baseUrl |
| 通道级状态 | `~/.dsh/channels/<channelId>.state.json` | `channel-runner.js` | lastWorkspace / 会话映射 / activeSession，重启可恢复；面板读它显示连接徽标（不轮询） |
| 会话映射（v1） | `<项目根>/.dsh/channels/<channelId>.sessions.json` | `channel-sessions.js` | 落项目目录（存储全局化改造后迁 `~/.dsh/channels/`） |
| 消息日志（v1） | `<项目根>/.dsh/channels/<channelId>.messages.json` | `channel-sessions.js`（appendMessage） | 记录 `{channelId, conversationId, sessionId, dir: in\|out, text, ts}`，MAX_MESSAGES=1000 滚动；gitignore 忽略 |
| 项目引用/路由 | `<项目根>/.dsh/channels.json` | ChannelPanel 开关 / main.swift | `{"version":1,"refs":[{channelId, workspaceRoot, routing…}]}`；当前旧路径文件**未跟踪**（迁移到 `.dsh/channels/channels.json` 并提交是 channel-storage.md 的待办） |

> 存储全局化改造（docs/channel-storage.md，2026-08-22 定稿、未实现）：消息/会话迁至全局 `~/.dsh/channels/`，按 `channelId.workspaceKey.sessionId.messages.json` 分桶（无会话消息入 `system` 桶），`channelId.workspaces.json` 登记 workspaceKey ↔ projectRoot 消歧；含惰性迁移 + `ohmy-core.js channel migrate` CLI。

## 日志与配置文件

- `~/Library/Logs/oh-my-dsh/app.log` — 壳层行为（`AppLog`，串行队列写盘，ISO8601 时间戳）；
- `~/Library/Logs/oh-my-dsh/server.log` — 自拉起的 `dsh web` 进程 stdout/stderr；
- `~/Library/Logs/oh-my-dsh/channel-runner-<channelId>.log` — channel runner（core/Node，`channel run`）的 stdout/stderr（含 `[weixin-clawbot]` getConfig/sendTyping 等日志；main.swift startChannelRunner 路由到文件而非丢弃）；
- `$HOME/.dsh`（默认 `DSH_HOME`）— 传给 `dsh web`，首次使用自动初始化 web profile；其下另有 `~/.dsh/gh-token`（通用 token 文件）与 `~/.dsh/tokens/<owner>-<repo>`（按仓库作用域的 token 文件，chmod 600）——均**不**在仓库内，不入 git；
- 调试面板截图：`~/Library/Logs/oh-my-dsh/panel-<label>-debug.png`（`DSH_UI_DEBUG=1` 时产出）。