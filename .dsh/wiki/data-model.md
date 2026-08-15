---
title: 数据模型
tags: [data-model, userdefaults, rpc, frontmatter, state]
updated: 2026-08-15T14:22:31Z
sources: [src/main.swift, src/WikiPanel.swift, src/TerminalPanel.swift, docs/repo-wiki-design.md]
manual: false
---

# 数据模型

本仓库无数据库：状态以 **UserDefaults** 持久化，进程间/代理间通信走 **HTTP RPC 信封**，磁盘上唯一的"数据文件"是 wiki markdown 页（含 frontmatter）与日志。

## UserDefaults 键（壳层持久化状态）

| 键 | 含义 | 出处 |
|---|---|---|
| `appLanguage` | 显式语言选择（"zh"/"en"；删除 = 跟随系统） | `L10n` |
| `AppleLanguages` | 覆写 WebView 的 `navigator.language`（"zh-CN"/"en-US"） | AppDelegate |
| `dshRegistry` | 运行期 npm registry（删除 = 默认国内源） | `RegistryConfig` |
| `autoUpgradeDsh` | 自动升级开关（默认开） | AppDelegate |
| `lastAutoUpgradeCheck` | 自动升级 24h 节流时间戳 | `runAutoUpgradeIfNeeded` |
| `previewPanelState` | 右栏可见性（true = 打开） | `setRightPanel` |
| `rightPanelKind` | 右栏当前面板（"preview"/"terminal"/"wiki"） | `setRightPanel` |
| `previewPanelWidth` | 用户拖拽的面板宽度 | `splitViewDidResizeSubviews` |
| `wikiRootMode` | wiki 根模式（"in-repo" / "dsh-home"） | `WikiPaths` |
| `wikiAutoRegenerate` | wiki 自动更新开关（默认关） | `WikiPaths` |
| `wikiRegisterAgentsMd` | 写入 AGENTS.md 注册块开关（默认关） | `WikiPaths` |

## 领域模型（代码内）

- **`RightPanel` 枚举**（main.swift）：`none / preview / terminal / wiki`——右栏插槽互斥状态；
- **`ProjectDirectory`**（main.swift）：壳层共享的"活动项目目录"（`static var current`），跟随 dsh web 当前会话（见 `sessionTrackerScript` 数据流），`resolveProjectDirectory` 优先返回它；
- **`L10n.table`**：`[String: (zh: String, en: String)]` 文案表，`L10n.tr(key)` 按 `lang` 取文案并填充 `%@/%d`；
- **`WikiPage`**（WikiPanel.swift）：`path / title / tags / updated / sources / manual`，由 frontmatter 解析而来；
- **`WikiScanner.Index`**：`pages`、`backlinks`（页面绝对路径 → 引用它的页面列表）、`repoRoot`、`signature`（路径 → mtime，用于变更检测）；
- **`WikiMarkdownRenderer`**：软换行用 Unicode `U+2028` 行分隔符（紧排换行、不产生段落间距；`\n` 在 NSTextView 中会触发段落间距），列表项之间补 `\n`；
- **`TerminalEmulator.Cell`**：`ch / fg / bg / bold / italic / underline / inverse / continuation`；`ParserState`（ground/escape/csi/osc/dcs 等）驱动 ANSI 解析；
- **`TerminalSession.State`**：`running / exited(code) / terminated`；
- **`WikiPanelController.generations`**（内存态，build 59→60）：`[canonicalRepo: Generation]`——生成状态按仓库根（`WikiRPC.canonical` 规范化路径）关联，多仓库可并发各一个生成；`syncGenerationUI()` 据此让 UI 只反映当前仓库；
- **`TreeNode`**（PreviewPanel.swift）：`name / path / isDir / children?`（懒加载）。

## RPC 信封（与 dsh web 通信）

所有 `/api/*` 调用使用 `client-request` 信封（与 web 客户端同协议，见 main.swift `DSHSessionRPC`、WikiPanel.swift `WikiRPC`）：

```json
POST /api/session.list
{ "type": "client-request", "rpcId": "<uuid>", "method": "session.list", "payload": {} }
→ { "result": { "ok": true, "value": { "items": [ { "id": "...", "cwd": "...", "running": true, "updatedAt": 0, "blank": false } ] } } }
```

已用到的 method：`session.list`（cwd 解析、wiki 轮询 running）、`session.create`（payload 可含 `workspaceId` 或 `cwd` 创建会话）、`session.prompt`（payload: sessionId + mode "queue" + content）、`session.cancel`（payload.sessionId 取消生成会话，`WikiRPC.cancel`）、`workspace.list`（`WikiRPC.resolveWorkspaceId` 按规范化路径匹配工作区）、`host.openPath`（被 JS 拦截，不走原生打开）。曾用 `workspace.insertSessionBefore` 的 `WikiRPC.attachOrphans`（把未分组会话归入工作区）已移除（修复 15，build 61→62）：RPC 无 attach 接口，`insertSessionBefore` 只能移动**已入账**会话。

**会话跟随**：`rebuildWebView` 注入 `sessionTrackerScript`，监听 web 客户端 RPC 请求体中的 `payload.sessionId`（`session.history/prompt/rename/selectModel`）与 `payload.parentSessionId`（`subagent.list`），id 变化时经 `dshSession` message handler 上报；壳层 `DSHSessionRPC.fetchSessionCwd(port:sessionId:)` 按 id 查 `session.list` 取 cwd 更新 `ProjectDirectory`。

## Wiki 页面数据格式（frontmatter）

每页 YAML frontmatter（`docs/repo-wiki-design.md` §4.3 规范 + `.dsh/skills/repo-wiki/SKILL.md`）：

```yaml
---
title: <标题>
tags: [a, b]
updated: 2026-08-15T07:19:55Z   # ISO8601 UTC，代理最近触碰时间
sources:                        # 依据的相对路径，供陈旧检测
  - src/main.swift
manual: false                   # true = 用户手改，代理永不覆盖
---
```

- 目录规范：`index.md / overview.md / architecture.md / modules/<name>.md / data-model.md / conventions.md / tasks.md`（+ `_meta/backlinks.json` 与 `_meta/lock`，设计稿；lock 未实现，v1.7.0 以面板内 generating 标志防重入）；
- 上限：初始生成 ≤ 20 页、单页 ≤ 200 行 / 20 KB、wiki 总量 ≤ 2 MB（超出标「已截断」）。

## 日志与配置文件

- `~/Library/Logs/oh-my-dsh/app.log` — 壳层行为（`AppLog`，串行队列写盘，ISO8601 时间戳）；
- `~/Library/Logs/oh-my-dsh/server.log` — 自拉起的 `dsh web` 进程 stdout/stderr；
- `$HOME/.dsh`（默认 `DSH_HOME`）— 传给 `dsh web`，首次使用自动初始化 web profile；
- 调试面板截图：`~/Library/Logs/oh-my-dsh/panel-<label>-debug.png`（`DSH_UI_DEBUG=1` 时产出）。
