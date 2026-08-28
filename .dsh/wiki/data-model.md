---
title: 数据模型
tags: [data-model, userdefaults, rpc, frontmatter, state]
updated: 2026-09-21T08:45:10Z
sources: [platforms/macos/src/SkillsCore.swift, platforms/macos/src/SkillSources.swift, platforms/macos/src/SkillInstaller.swift, docs/skills-manager-design.md, tests/skills-panel/, core/lib/review-log.js, core/lib/settings.js, platforms/macos/src/ShellConfig.swift, platforms/macos/src/DshWebCookieJanitor.swift, tests/shell-config/, tests/dsh-auth-cookies/, platforms/macos/src/ReviewPanel.swift, platforms/macos/src/ReviewLogModel.swift, docs/review-panel-design.md, platforms/macos/src/main.swift, platforms/macos/src/DshWebRPC.swift, platforms/macos/src/WikiPanel.swift, platforms/macos/src/TerminalPanel.swift, platforms/macos/src/TerminalWorkspaceTabs.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/OpenWithApps.swift, platforms/macos/src/EditorLoadPolicy.swift, platforms/macos/src/ImageZoom.swift, docs/ux-feedback.md, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/ChannelPanel.swift, platforms/macos/src/ChannelStoreReader.swift, core/lib/issues.js, core/lib/tasks.js, core/lib/channel.js, core/lib/channel-store.js, core/lib/channel-runner.js, core/lib/channel-sessions.js, core/lib/dingtalk-access.js, core/lib/dingtalk-device.js, core/lib/dsh-rpc.js, core/lib/workspace-store.js, docs/repo-wiki-design.md, docs/issue-runner-design.md, docs/channel-design.md, docs/channel-storage.md, docs/channel-status.md, docs/channel-association-model.md, docs/channel-project-switch.md, docs/channel-dingtalk-stream.md, docs/git-workflow.md, docs/dsh-version-impact.md]
manual: false
---

# 数据模型

本仓库无数据库：壳层设置以 **`$DSH_HOME/shell/config.json`**（JSON，`ShellConfig` / `core/lib/settings.js`）持久化（少量系统级项仍在 **UserDefaults**），进程间/代理间通信走 **HTTP RPC 信封**，磁盘上的"数据文件"是 wiki markdown 页（含 frontmatter）、任务关联索引（`.dsh/tasks/`）、技能记录（`$DSH_HOME/shell/skills.json`）与日志。

## 壳层设置键（`$DSH_HOME/shell/config.json`，`ShellConfig`）

语言无关的 JSON 键值（可由外部工具/代理直接读写：写入经 core CLI `ohmy-core settings set|unset|list` 合并 + 原子落盘，壳层侧 0.3s 防抖异步、退出前 `flushNow()`；读取直读 JSON）；开发版用 `~/.dsh-dev/shell/config.json`（独立 `DSH_HOME`）。

| 键 | 含义 | 出处 |
|---|---|---|
| `appLanguage` | 显式语言选择（"zh"/"en"；删除 = 跟随系统） | `L10n` |
| `appTheme` | 主题（"system"/"light"/"dark"，设置窗口切换） | `AppTheme` |
| `hasCompletedOnboarding` | 首次引导 onboarding 已完成（一次性） | `showOnboardingIfNeeded` |
| `AppleLanguages` | 覆写 WebView 的 `navigator.language`（"zh-CN"/"en-US"） | AppDelegate |
| `dshRegistry` | 运行期 npm registry（删除 = 默认国内源） | `RegistryConfig` |
| `autoUpgradeDsh` | 自动升级开关（默认开） | AppDelegate |
| `nextAutoUpgradeCheck` | 下次允许自动升级的时间戳（24h 节流；`DSH_AUTO_UPGRADE_NOW=1` 忽略节流，测试钩子） | `runAutoUpgradeIfNeeded` |
| `previewPanelState` | 右栏可见性（true = 打开） | `setRightPanel` |
| `rightPanelKind` | 右栏当前面板（"preview"/"terminal"/"wiki"/"tasks"/"browser"/"channel"/"review"/"skills"） | `setRightPanel` |
| `previewPanelWidth` | 用户拖拽的面板宽度 | `splitViewDidResizeSubviews` |
| `files.openProjectWith` | 文件面板「打开项目」的目标（`"panel"` / `"finder"` / bundle id / `"path:<应用路径>"`；缺省或记住的应用已卸载 → 改为弹菜单） | `FilePanelController.openWithKey` |
| `terminal.autoCopy` | 终端「选中文本即复制」开关（**默认开**；无选区时 ⌘C 仍发 SIGINT） | `TerminalView.autoCopyKey` |
| `browserLastURL` | 浏览器面板启动恢复的地址（默认 about:blank） | `BrowserPanelController` |
| `browserRenderMode` | 浏览器面板 CEF 渲染模式（**默认窗口化**：判定 `!= "osr"`，删除/缺省即窗口化；显式设 `osr` 才走离屏帧自绘，2026-09-13 起） | `startBrowserAPI`（`CEFShim.setWindowedMode`） |
| `legacyUserDefaultsMigratedAt` | 旧 UserDefaults 取值迁移标记（时间戳；写入即表示一次性合并已做，不再重复） | `ShellConfig.migrateLegacyUserDefaultsIfNeeded` |
| `wikiRootMode` | wiki 根模式（"in-repo" / "dsh-home"） | `WikiPaths` |
| `wikiAutoRegenerate` | wiki 自动更新开关（默认关） | `WikiPaths` |
| `wikiRegisterAgentsMd` | 写入 AGENTS.md 注册块开关（默认关） | `WikiPaths` |

> 凭据不走 UserDefaults：GitHub token 按仓库作用域存储，**读取优先文件**（免 Keychain 每次弹密码）、Keychain 兜底——解析顺序为 文件专属 `~/.dsh/tokens/<owner>-<repo>` → 文件通用 `~/.dsh/gh-token` → Keychain 专属（`oh-my-dsh.issuerunner.github-token.<owner>/<repo>`）→ Keychain 通用（`oh-my-dsh.issuerunner.github-token`）；面板保存时 Keychain 与文件**双写**（Keychain 条目设 `kSecAttrAccessibleAfterFirstUnlock`，文件 chmod 600，App 与外部工具/代理共用），见 [issue-runner-panel](modules/issue-runner-panel.md)。

> 上表中仅 `AppleLanguages`（WebView 语言覆写，`UserDefaults.standard` 写入以影响系统组件）等系统级项仍走原生 UserDefaults；其余键均由 `ShellConfig` 落到 `$DSH_HOME/shell/config.json`（开发版 `~/.dsh-dev/shell/config.json`），对外与 UserDefaults 同形（`object/string/bool/double/data(forKey:)`、`set`、`removeObject`），便于跨语言工具读写。

> **旧 UserDefaults 取值一次性迁移（2026-09-13，407ccb1）**：1.14 把这些键从 `UserDefaults` 搬进 `config.json` 时**没有搬运已有取值**——用户显式设过的值留在 plist 里再没人读，壳层静默回落到代码默认（这正是 v1.14.0「浏览器面板一片空白」的一半根因：`browserRenderMode=windowed` 丢失后回落到当时损坏的 OSR 路径）。现在 `ShellConfig.loadIfNeeded()`（持锁）内做一次合并：`legacyUserDefaultsKeys` 列出的 16 个壳层自有键（`appLanguage`/`appTheme`/`dshRegistry`/`browserRenderMode`/`browserLastURL`/`previewPanelState`/`previewPanelWidth`/`previewLastDirectory`/`rightPanelKind`/`hasCompletedOnboarding`/`autoUpgradeDsh`/`nextAutoUpgradeCheck`/`channel.global.list`/`wikiRootMode`/`wikiAutoRegenerate`/`wikiRegisterAgentsMd`）**只搬本文件尚无取值的键**（显式值永远优先），写完在文件里落 `legacyUserDefaultsMigratedAt` 标记保证只做一次；迁移直接原子写文件而不走 `flush()`（在锁内，避免自锁），并记日志 `shellconfig: legacy UserDefaults merge (moved N: …) -> <path>`。回归测试 `tests/shell-config/`（13 例）。

## 技能数据（skills.json + SKILL.md frontmatter）

- **壳层技能记录** `$DSH_HOME/shell/skills.json`（版本化 JSON，原子写，`SkillStore`；与 `shell/config.json` 同目录但**不走 `ShellConfig`**——值是结构化对象、成批变更，独立文件避免每个键一次 node 子进程；缺失/损坏按空配置处理不抛错）：
  `registries`（`[{id,label,enabled,searchURL?,catalog:{kind:none|wellKnown|githubRepo,url},popularQueries}]`，默认预置 skills.sh）、`invocation.<name>`（`baselineUserInvocable` / `baselineDisableModelInvocation` / `userInvocable` / `disableModelInvocation` / `updatedAt`）、`installed.<name>`（`source` / `sourceType` / `sourceUrl` / `ref` / `path` / `level` / `baseUserInvocable` / `baseDisableModelInvocation` / `contentHash` / `installedAt` / `updatedAt`）；
- **技能的持久态在 SKILL.md 本身**：调用开关只认 frontmatter 键 `user-invocable`（默认 true）与 `disable-model-invocation`（默认 false），面板改开关是**只增删改这两行**的文本编辑（切回基线值即删键、字节还原），不是 YAML 往返；旧驼峰键（`userInvocable` 等）会让 dsh **抛错并忽略整个技能**；
- **发现的四个根与优先级**（rank 小者同名优先）：`<工作区>/.dsh/skills`(100) > `<工作区>/.agents/skills`(200) > `$DSH_HOME/skills`(400，跳过 `.system`) > `$DSH_AGENTS_HOME`/`~/.agents/skills`(500)；见 [skills-panel](modules/skills-panel.md) 与 `docs/dsh-version-impact.md` D2/D2b/D2c/D2d。

## dsh 浏览器认证 cookie（WKWebsiteDataStore）

- **名字即身份**：dsh ≥ 0.1.2 的浏览器会话 cookie 名 = `"dsh-auth-" + base64url(sha256(authority))`，`authority` = 该实例的 `host:port`（壳层只加载 `http://127.0.0.1:<port>/`，因此 `authority(port:) == "127.0.0.1:<port>"`，换成 `localhost` 会得到另一族 cookie）；
- **cookie 本身不含端口**（RFC 6265 按 domain+path 匹配），WKWebView 的 cookie 存储又按 bundle id 持久化且 30 天 TTL ⇒ 每次自拉起新端口的 dsh web 就多一只 ~226 B 的新 cookie、**永不复用覆盖、只增不减**；累积到第 63 只（`Cookie:` 头 ~14.1 KB）时超出 node 默认 16 KiB header cap，2.1 KB 的插件 combo bundle 请求回 **431** → 界面 **Failed to load plugins**；
- 因此壳层把 cookie 存储当成**有生命周期的缓存**：启动加载入口 URL 前清掉非本次 authority 的 `dsh-auth-*`、退出清掉本次的（`DshWebCookieJanitor`，只碰该前缀，见 [main](modules/main.md)），并在 spawn 时给 `NODE_OPTIONS` 追加 `--max-http-header-size=65536` 作保险带。

## 领域模型（代码内）

- **`RightPanel` 枚举**（main.swift）：`none / preview / terminal / wiki / tasks / browser / channel / review / skills`——右栏插槽互斥状态（`rightPanelKind` 持久化，含 `"review"` / `"skills"`）；
- **`ProjectDirectory`**（main.swift）：壳层共享的"活动项目目录"（`static var current`），跟随 dsh web 当前会话（见 `sessionTrackerScript` 数据流），`resolveProjectDirectory` 优先返回它；
- **`L10n.table`**：`[String: (zh: String, en: String)]` 文案表，`L10n.tr(key)` 按 `lang` 取文案并填充 `%@/%d`；
- **`WikiPage`**（WikiPanel.swift）：`path / title / tags / updated / sources / manual`，由 frontmatter 解析而来；
- **`WikiScanner.Index`**：`pages`、`backlinks`（页面绝对路径 → 引用它的页面列表）、`repoRoot`、`signature`（路径 → mtime，用于变更检测）；
- **`WikiMarkdownRenderer`**：软换行用 Unicode `U+2028` 行分隔符（紧排换行、不产生段落间距；`\n` 在 NSTextView 中会触发段落间距），列表项之间补 `\n`；
- **`TerminalWorkspaceTabs`**（TerminalWorkspaceTabs.swift，**纯内存、不落盘**）：终端页签的 workspace 归属模型——`workspaceByTab`（tabId → workspace key，key 复用 `WorkspaceTabMemory.key(for:)`）+ `globalTabs`（无法解析项目目录时 spawn 的兜底页签，处处可见）+ `forgottenTabs`（已关闭的 id 必须消失）+ `lastSelectedByWorkspace`（每个 workspace 上次选中的页签）；切换 workspace 只**隐藏**页签、不终止 shell，切回按记录恢复选中；见 [terminal-panel](modules/terminal-panel.md)；
- **文件面板内存态**（不落盘）：`WorkspaceTabMemory`（工作区 → 已关闭页签路径 + 选中项，换根时记忆/恢复）、`rememberedTreeWidth`（用户拖出来的目录树宽度，关闭面板再打开时恢复，区间 160–420pt 且给内容区留 ≥240pt）、图片预览的 `followsViewport`（用户捏合后不再自动 fit）；见 [file-panel](modules/file-panel.md)；
- **`OpenWithEntry`**（OpenWithApps.swift，纯模型）：`{id, title, bundleIdentifier?, l10nKey?, group(panel|finder|editor|terminal)}`——「用外部应用打开项目目录」的目录项；记忆值就是 `id`（bundle id 或 `path:<应用路径>`）；
- **`EditorLoadPolicy`**（EditorLoadPolicy.swift，纯常量与纯函数，非持久数据）：分块高亮 300 行 / 32 KB、安全阀 4 万行 / 4 MB、写文件稳定性窗口 0.6s；
- **`TerminalEmulator.Cell`**：`ch / fg / bg / bold / italic / underline / inverse / continuation`；`ParserState`（ground/escape/csi/osc/dcs 等）驱动 ANSI 解析；
- **`TerminalSession.State`**：`running / exited(code) / terminated`；
- **`WikiPanelController.generations`**（内存态，build 59→60）：`[canonicalRepo: Generation]`——生成状态按仓库根（`WikiRPC.canonical` 规范化路径）关联，多仓库可并发各一个生成；`syncGenerationUI()` 据此让 UI 只反映当前仓库；
- **`TreeNode`**（PreviewPanel.swift）：`name / path / isDir / children?`（懒加载）；FilePanel 内另有 file-private 同名 `TreeNode`/`DirRow`（[file-panel](modules/file-panel.md)）；
- **Channel 域模型**（core/lib/channel.js）：`ChannelEvent`（`{channelId, platform, conversationId, sender, text?, media?, ts}`）、`ChannelReply`（`{text?, media?}`）；五态状态机 `CHANNEL_STATES`（disconnected/connecting/connected/reconnecting/auth-expired）；路由优先级 `ROUTE_PRIORITY`（显式会话绑定 3 > 关键词 2 > 默认 1）；`normalizeEvent` / `createRouter` / `createChannelManager`；
- **`JobQueue`**（core/lib/jobqueue.js）：串行任务队列状态机 `createQueue()`——任务含 `source`（"remote" = 通道远程驱动，issue-runner 为另一来源）/`state`（pending/running/done/failed/cancelled）等字段，`enqueue`/`peek`/`markRunning`/`complete`/`fail`/`cancel`/`retry`/`snapshot`/`removeFinished` 操作（IssueRunner 面板用它串行执行「切分支→会话→推送→PR」流水线，见 [issue-runner-panel](modules/issue-runner-panel.md)）；
- **`TaskIndex`**（IssueRunnerPanel.swift，与 core/lib/tasks.js 结构一致）：`.dsh/tasks/` 关联索引读写——`loadIndex`/`mergeTask`/`findTask`/`rememberSession`/`sessionForIssue`；index.json 写 `{"version": 1, "tasks": [...]}`（任务条目可含 `title`，startTask 起写入），local.json 写 `{"sessions": {issue: {sessionId, updatedAt}}}`；
- **任务状态机（IssueRunnerTask.State）**：`pending / running / done / failed / cancelled`，与 JobQueue 的 state 字段一致；`IssueRunnerTask` 另含 `body`（issue 正文 markdown，cb13c97 起由 `parseIssues`/`fetchIssues` 取）；交互为**行内展开详情**（`expandedIssue` 手风琴，c852894 起替代 NSAlert 弹窗）——展开行 168pt 高、详情区可滚动（4576dd2），单元格按钮按状态给动作（pending→Process、running→Cancel Task、done→Open PR、failed/cancelled→Retry，均带 Close；done 且有 PR 额外「评论并关闭 Issue」）；工作区切换到**不同仓库**（owner/repo 变化）时 `applyRepo` 先清空任务列表——issue 号按仓库归属。

## dsh 会话日志（审查面板数据源，只读）

- **位置**：`$DSH_HOME/sessions/<workspace-slug>/<session-id>/session.jsonl`（压缩时 `.jsonl.zstd`），一行一事件；
- **格式要点**：dsh 的 Zstandard 后端把日志写成**多个独立可解压帧的拼接**（每批落盘一帧），一次性解压只拿得到**第一帧**（实测真实日志仅返回 214 字节的会话头）；`core/lib/review-log.js` 的 `scanZstdFrames()` 只走帧头/块头逐帧解码。Apple 的 Compression 框架在这套 SDK 上**没有 zstd 算法**，Swift 侧无法自行解码——这是审计逻辑放在 core、且必须用**内置** Node（v24，含 `zlib.zstdDecompressSync`）的原因（`CoreBridge.run(…, preferBundledNode: true)`）；
- **审计读取的三类记录**：① `tool/result` → `data.meta.diffs`（已应用 hunk，**仅顶层** `write`/`edit`）；② 顶层 `tool/call` / 嵌套 `tool/code-dispatch-start` → `arguments`（参数还原，覆盖 `run_code` 嵌套调用与新建文件全文）；③ `tool/call name=bash` → 命令文本（无前后内容）。turn 归属来自 `turn/start` + `tool/call.turn`（嵌套派发**继承父调用**的 turn）；
- **缓存身份 `ReviewLogStamp`（Swift，`ReviewLogModel.swift`）**：`{size, mtimeMs}`，由 `ReviewLogStamp.read(path)` 从文件属性取；`auditNeedsRefresh(cached:onDisk:)` 只在两者相等时复用缓存，`onDisk == nil`（路径未知/文件消失）判为「无法判断」保留缓存。因为日志**只增不减**，同一份日志上的审计结果永远有效——这是「新建会话不再只显示会话、看不到文件」的关键（PR #49）；
- **输出契约**（`node core/bin/ohmy-core.js review sessions|audit|audit-file`）与每条 entry 的字段（`surface/status/category/path/hunks/added/removed/command/suspicion/note`）见 [review-panel](modules/review-panel.md) 与 docs/review-panel-design.md §5；读取失败（帧解压失败 / 尾部未完成帧 / 无法解析的 JSONL 行）一律进 `diagnostics` 显式报出，不静默丢数据。

## RPC 信封（与 dsh web 通信）

所有 `/api/*` 调用使用 `client-request` 信封（与 web 客户端同协议，见 main.swift `DSHSessionRPC`、WikiPanel.swift `WikiRPC`）：

```json
POST /api/session.list
{ "type": "client-request", "rpcId": "<uuid>", "method": "session.list", "payload": {} }
→ { "result": { "ok": true, "value": { "items": [ { "id": "...", "cwd": "...", "running": true, "updatedAt": 0, "blank": false } ] } } }
```

已用到的 method：`session.list`（cwd 解析、wiki 轮询 running）、`session.create`（payload 可含 `workspaceId` 或 `cwd` 创建会话）、`session.prompt`（payload: sessionId + mode "queue" + content）、`session.cancel`（payload.sessionId 取消生成会话，`WikiRPC.cancel`）、`workspace.list`（`WikiRPC.resolveWorkspaceId` 按规范化路径匹配工作区）、`host.openPath`（被 JS 拦截，不走原生打开）。曾用 `workspace.insertSessionBefore` 的 `WikiRPC.attachOrphans`（把未分组会话归入工作区）已移除（修复 15，build 61→62）：RPC 无 attach 接口，`insertSessionBefore` 只能移动**已入账**会话。

- **dsh ≥ 0.1.2 的两种接口面**（core/lib/dsh-rpc.js）：一元 RPC 仍是 `POST /api/<endpoint>` + 同一 client-request 信封，但**端点改斜杠**且参数包在 `payload.args.<request|_request>`（session/list 用 `_request`；session/create、session/rename、session/prompt、session/cancel、session/page 用 `request`），并且 `/api` 只认 **cookie**——`GET /?token=<launch token>` 换 `dsh-auth-*` Cookie（token 每次进程随机，壳层从 dsh web 自报的入口地址取、经 `channel run --dsh-token` 传给 runner）。0.1.2 **没有 workspace.list**（改读 `$DSH_HOME/storages/workspace.json`）、没有 session.history/search（末条回复走 session/page，`throughSeq` 取 session/list 的 `projections.asOfSeq`）。传输层按端点记忆接口面，先试斜杠端点、404 再回退点号方法，两种版本通吃。

- **持久化 workspace store 是 dsh 的私有域存储（2026-09-10 加护栏，R4）**：0.1.2 无 `workspace.list` 后，枚举工作区只能读 `$DSH_HOME/storages/workspace.json`——`unit: {name:"workspace", version:2}` + `global.workspaceIds`（顺序）+ `tables.workspaces`（`{path,title,sessionIds,createdAt,updatedAt}`），由 dsh 的 `defineDomain({name:'workspace',version:2})`（`@deepseek-ai/dsh-workspace/lib/invariant.js`）定义、带 zod 校验与 `pendingMutation` 中断恢复标记，**不是 API**，上游可随时改字段/搬文件/升版本。core（`core/lib/workspace-store.js`，导出 `SUPPORTED_DOMAIN`/`describeStore`）与 Swift（`DshWebRPC.swift` 的 `DshWorkspaceStore.readStore` → `StoreRead`）两侧读取器都校验域名与版本并给出原因：`ok` / `missing`（**安静**，0.1.1 本就正常没有该文件）/ `unreadable` / `unexpected`（无 `tables.workspaces` 或域名不符）/ `version`（版本不符，仍**尽力解析**）；非 ok 的原因经 `describeStore()`（core）/ `StoreRead.diagnostic`（Swift）报出——core 走频道 runner 日志（`channel-runner.js` 传 `log: m => console.log(m)`）、Swift 走 `AppLog`（`app.log`），形如 `[workspace-store] persisted workspace store … is domain workspace v3, this build understands v2 — read best-effort`。**只读不写**；`main.swift` 的 `persistedWorkspacePath` 已改为调用 `DshWorkspaceStore`（原先三份各自解析该私有格式的代码收口为 core + Swift 两份）。受影响的五个静默断裂点与升级验证命令见 docs/dsh-version-impact.md §6.2。

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

通道凭据、通道级状态、会话/消息归档与项目引用（docs/channel-design.md §4、docs/channel-storage.md、docs/channel-association-model.md）：

| 数据 | 路径 | 写入方 | 说明 |
|---|---|---|---|
| 凭据/账号 | `~/.dsh/channels/<channelId>.json`（chmod 600） | `channel-store.js`（saveChannelAccount） | 文件优先读、Keychain 兜底（零弹窗）；含 botToken/accountId/userId/baseUrl |
| 通道级状态 | `~/.dsh/channels/<channelId>.state.json` | `channel-runner.js` | lastWorkspace / 会话映射 / activeSession，重启可恢复；面板读它显示连接徽标（不轮询） |
| 会话映射（全局） | `~/.dsh/channels/<channelId>.sessions.json` | `channel-sessions.js`（setSession） | **channel 作用域全局**（2026-08-22 起）；按 sessionId 保留全部会话，`/new` 重绑定 conversation 不删历史；记录含 conversationId/sessionId/projectRoot/workspaceKey/name/updatedAt |
| 会话消息归档（全局） | `~/.dsh/channels/<channelId>.<workspaceKey>.<sessionId>.messages.json`（sessionId 缺省入 `system` 桶） | `channel-sessions.js`（appendMessage） | 分桶记录 `{channelId, conversationId, sessionId, dir: in\|out, text, ts, projectRoot}`，MAX_MESSAGES=1000 滚动；`<channelId>.workspaces.json` 登记 workspaceKey ↔ projectRoot（同名加 6 位路径哈希消歧）；**项目目录不再产生消息/会话文件** |
| 项目开关/启用关联 | `~/.dsh/channels/<channelId>.workspaces.json` | ChannelPanel `setChannelEnabled` / channel-sessions `setWorkspaceEnabled` | **全局**（2026-08-23 随 PR #30 落地，docs/channel-project-switch.md）：`{"<workspaceKey>":"<projectRoot>"}`（chmod 600，key 用 `ChannelStoreReader.workspaceKey(for:)` 派生）；某 projectRoot 出现 = 该工作区启用了该通道（「项目开关」ON）；旧 `<项目>/.dsh/channels.json` refs 不再作为启用来源（仅 ChannelPanel 一次性惰性迁移播种）；`registerProjectRoot` 只作消息桶 key 推导 |
| 钉钉管理员绑定 | `~/.dsh/channels/<channelId>.binding.json`（chmod 600） | `dingtalk-access.js`（runChannel 的 owner-binding 安全门） | 存 /bind 绑定状态：未绑定管理员前**拒绝所有**消息，仅绑定管理员可驱动本机 dsh；并发 /bind 经 `withBindLock` 串行锁（PR #40）——仅首个持正确口令者绑定成功，防 last-writer-wins 覆盖 owner；见 docs/channel-dingtalk-stream.md |
| 钉钉应用凭据 | `~/.dsh/channels/<channelId>.json`（chmod 600，含 AppKey/AppSecret） | `dingtalk-device.js`（device-code 扫码注册）/ 手动填写 | 与微信共用 channel-store.js 凭据文件；扫码创建应用走 `channel login-dingtalk`（init/begin → poll 得 AppKey/AppSecret） |

## Channel 关联模型（channel ↔ message ↔ session，2026-08-22 落地）

- **Channel(1) ──(N)── Conversation**：一个微信账号对应一个 channel（channelId 全局唯一），一个通道下多个会话/群；
- **(Channel, Conversation) ──(1)── Session**：会话映射绑定到唯一 dsh 会话（`runtime.setSession(conversationId, {sessionId, projectRoot})`），多轮对话复用；`/new`/`/switch` 重绑定；
- **Session ──(N)── Message**：会话内往返消息（dir: in/out）；
- **Session ──(1)── Workspace**：会话归属某工作区（workspaceId / cwd / workspaceKey）；
- **三粒度状态**：通道级当前工作区（lastWorkspace，channel 作用域）、每 conversation 会话绑定（(channelId,conversationId)→sessionId，路由权威）、通道级 active 会话（activeSessionId，服务 /status、/new 激活、#sN）；
- **路由语义（B）**：resolveRefBinding（conversation/keyword 显式绑定）优先，否则 workspace-tag（#tag>last>first）兜底；普通消息解析出 workspace 后以 **workspaceId** 创建/复用会话（C）。

## 日志与配置文件

- `~/Library/Logs/oh-my-dsh/app.log` — 壳层行为（`AppLog`，串行队列写盘，ISO8601 时间戳）；
- `~/Library/Logs/oh-my-dsh/server.log` — 自拉起的 `dsh web` 进程 stdout/stderr；
- `~/Library/Logs/oh-my-dsh/channel-runner-<channelId>.log` — channel runner（core/Node，`channel run`）的 stdout/stderr（含 `[weixin-clawbot]` getConfig/sendTyping、`[dingtalk]` 等日志；main.swift startChannelRunner 路由到文件而非丢弃）；
- `$HOME/.dsh`（默认 `DSH_HOME`）— 传给 `dsh web`，首次使用自动初始化 web profile；其下另有 `~/.dsh/gh-token`（通用 token 文件）与 `~/.dsh/tokens/<owner>-<repo>`（按仓库作用域的 token 文件，chmod 600）——均**不**在仓库内，不入 git；
- 调试面板截图：`~/Library/Logs/oh-my-dsh/panel-<label>-debug.png`（`DSH_UI_DEBUG=1` 时产出）。