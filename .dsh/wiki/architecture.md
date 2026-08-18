---
title: 架构
tags: [architecture, layers, dataflow, deployment]
updated: 2026-08-18T15:30:00Z
sources: [platforms/macos/src/main.swift, platforms/macos/src/PreviewPanel.swift, platforms/macos/src/TerminalPanel.swift, platforms/macos/src/WikiPanel.swift, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/cef/CEFShim.h, platforms/macos/cef/CEFShim.mm, core/lib/issues.js, core/lib/tasks.js, docs/repo-wiki-design.md, docs/issue-runner-design.md, docs/git-workflow.md, .dsh/skills/repo-wiki/SKILL.md]
manual: false
---

# 架构

## 分层

```
┌────────────────────────────── oh-my-dsh.app（壳层，Swift）──────────────────────────────┐
│ AppDelegate（main.swift）                                                                │
│   ├─ ServerManager   服务探测/拉起/复用/停止；resolveNode/resolveDSHBin                   │
│   ├─ DSHUpdater      内置 dsh 检查与升级（node + npm-cli.js install）；版本检查经 CoreBridge 调共享核心│
│   ├─ CoreBridge      调共享核心 CLI（core/bin/ohmy-core.js，嵌入 runtime/core）；版本比较/最新版本查询   │
│   ├─ RegistryConfig  运行期 npm registry（默认国内源）                                    │
│   ├─ L10n            中/英文案表（跟随系统，DSH_LANG 可覆盖）                             │
│   ├─ DSHSessionRPC   经 HTTP RPC 解析会话 cwd（client-request 信封）                      │
│   ├─ ProjectDirectory 共享"活动项目目录"（跟随 dsh web 当前会话，见数据流 6）             │
│   └─ 右栏插槽 RightPanel { none, preview, terminal, wiki, tasks, browser }（五面板互斥）            │
│        ├─ PreviewPanelController（PreviewPanel.swift）                                           │
│        ├─ TerminalPanelController（TerminalPanel.swift）                                         │
│        ├─ WikiPanelController（WikiPanel.swift）                                                 │
│        ├─ IssueRunnerPanelController（IssueRunnerPanel.swift）                                   │
│        └─ BrowserPanelController（BrowserPanel.swift + BrowserCDP.swift，CEF 内核经 CEFShim）     │
│           └─ BrowserAPIServer（BrowserAPI.swift，127.0.0.1:3081 REST，Agent 驱动 + QA 端点）      │
│ WKWebView ← 加载 http://127.0.0.1:<port>（dsh web 界面）                                 │
└──────────────────────────────┬───────────────────────────────────────────────────────────┘
                               │ 复用或自拉起
                               ▼
        dsh web 服务（@deepseek-ai/dsh，DeepSeek Harness 源码不动）
        ├─ HTTP :3080（默认）— 页面 + /api/* RPC（session.* / host.openPath）
        └─ 代理会话（session.create / session.prompt，mode: queue）
```

原则：**壳层不解析代码、不改 dsh 源码**——面板内容（如 wiki）由 dsh 代理生成，壳层只做「触发 + 呈现」（见 `docs/repo-wiki-design.md` §3.1）。

## 模块依赖

- `main.swift` 持有五个面板 controller（`previewPanel`/`terminalPanel`/`wikiPanel`/`tasksPanel`/`browserPanel`），通过 `setRightPanel` 把活动面板根视图挂为 NSSplitView 右 pane（`subviews[1]`），隐藏时把 divider 推到最右；浏览器面板的 REST API（`BrowserAPIServer`）随 App 启动/停止，`BrowserAPIBridge` 闭包把 `setRightPanel` 与 QA 诊断（debugDump/debugState/debugHierarchy）接给 AppDelegate；
- 四个面板复用 `PreviewPanel.swift` 中定义的共享 UI 组件：`HoverButton`、`DynamicFillView`、`ActivityBarButton`、`PanelIconButton`、`HeaderLabel`、`CustomIconButton`、`BakedIconView`；
- 所有 L10n 文案集中在 `main.swift` 的 `L10n.table`；
- 面板通过 `serverPortProvider` 闭包取当前端口，`serverReady(port:)` 在服务就绪后获得门控通知；
- **共享项目目录**：`ProjectDirectory`（main.swift）保存当前活动项目目录，四处消费——预览树、终端新会话 cwd、wiki 根解析（`resolveProjectDirectory` 优先返回它，其次实时查询并缓存）、任务面板工作区识别（`tasksPanel.workspacePath` 优先返回 `ProjectDirectory.current` 且**权威**：非 GitHub 仓库 → 诚实空态、不替换其他工作区；仅启动早期未解析时才回退 `workspace.list` 解析并重试，见数据流 4b）；
- 任务面板把 issue→branch→PR→state 关联持久化到 `.dsh/tasks/`：`core/lib/tasks.js`（Node）+ `IssueRunnerPanel.swift` 的 `TaskIndex`（Swift，结构一致）双实现；index.json 随仓库提交、local.json 本机覆盖（gitignore）；
- **Node 选择策略（系统优先、内置兜底，含版本门槛）**：`resolveSystemNode()`（PATH→nvm current→nvm default→nvm 最新→Homebrew 首个**通过版本门槛**者，低于 22.0.0 跳过，`DSH_NODE_MIN` 可覆盖）优先，`DSH_NODE` 显式覆盖无条件优先；仅当系统 node 缺失/过旧、或用它启动 dsh web 失败（提前退出 / 90s 未服务）时才回退内置 node（`start()` 内 try/fallback，轮询含 1s 沉降校验防引导页假就绪）；dsh web 环境**不做内置目录 PATH 注入**，但经 `loginShellPath()`（`/bin/zsh -ilc` 读一次、8s 超时兜底、缓存）合并登录 shell PATH，使 dsh web 的 bash 可用用户全局工具；About 面板经 `refreshFacts(node:)` 显示实际运行 dsh web 的 node；
- 构建依赖：`platforms/macos/build-app.sh` 显式列出编译源文件，新增文件必须登记（v1.7.0 加入了 `WikiPanel.swift`，v1.8.0 加入 `IssueRunnerPanel.swift`）。

## 关键数据流

1. **启动**：`applicationDidFinishLaunching` → `L10n.captureSystemLang()`（在改写 AppleLanguages 前快照系统语言）→ `installSignalHandlers` → `buildMenu` → `buildWindow` → `startServer`。`ServerManager.start()`：先查 3080 是否已是 dsh web（`isDSHServing`，页面含 `__DSH_BOOT__`）→ 复用；否则解析 node/dsh 入口、`node <bin> web --port <n>` 自拉起，轮询直到就绪（90s 超时，含 1s 沉降校验——进程存活且再次可服务才判 up，防引导页假就绪；进程提前退出则抛错）。就绪后 `webView.load`，并通知终端/面板 `serverReady(port:)`。
2. **文件预览拦截**：`rebuildWebView` 注入两段用户脚本——① 覆写 `navigator.language/languages` 跟随壳语言；② `previewInterceptorScript` 覆写 `window.fetch`，拦截 `/api/host.openPath` RPC，把路径经 `window.webkit.messageHandlers.dshPreview.postMessage` 发给原生层，并回一个假的 `server-response` 成功（页面不会打开系统默认应用）。AppDelegate `userContentController` 收到后切换/打开预览面板 `previewPanel.open(path:)`。
3. **项目目录解析**：`DSHSessionRPC.fetchActiveSessionCwd(port:)` POST `/api/session.list`（`client-request` 信封：`{type, rpcId, method, payload}` → `{result:{ok, value}}`），取 running 会话优先、按 `updatedAt` 最新的非 blank 会话 cwd。预览树、终端新会话、wiki 根解析都基于它。
4. **Wiki 生成**：面板「+」→ `WikiRPC.createSession(cwd: repoRoot)` + `promptSession(mode: queue)` 触发代理执行 `repo-wiki` skill → 代理写 `.dsh/wiki/**`；面板轮询 `session.list` 的 running 标志显示「生成中」——内容区**叠加半透明浮层**（`WikiOverlayView`，0.82 透明度背景 + 居中「Generating…」NSTextField），页面与树全程可见、布局不消失（build 57→58）；底部状态条每秒刷新已耗时（`wiki.generatingElapsed`）；**生成状态按仓库根关联**（`generations: [canonicalRepo: Generation]`，build 59→60，可多仓库并发各一个生成，`syncGenerationUI` 只让 UI 反映当前仓库）；文件监听（2s 轮询 + 签名比对）驱动刷新与陈旧标记（生成期间代理每写出一页，左侧树即实时出现该页）；完成/失败/取消后都 `refresh()` 恢复内容区；取消走 `WikiRPC.cancel`（`session.cancel {sessionId}`）。**提交**：主路径由维护代理按指令执行（`git add .dsh/wiki` + commit，message 概括实际变更，**不 push**；repo-wiki skill 现行规则已不含提交步骤，末条为汇报）；面板 `WikiAutoCommit` 仅**兜底**（代理未提交且仍有变更时，`commitMessage(status:diff:)` 从 diff 提取实际内容生成 message），提交后 `refresh()` 刷新树（mtime 更新、陈旧标记消除）。**工作区归组**（build 48→49）：`WikiRPC.resolveWorkspaceId` 用 `workspace.list` 按规范化路径匹配当前仓库工作区，`createSession` 优先传 `workspaceId`（否则回退 `cwd`）——新会话直接归入工作区；曾有的 `attachOrphans`（把既有未分组会话经 `workspace.insertSessionBefore` 挂入工作区，幂等 + 30s 节流）因 RPC 无 attach 接口、对未分组会话必然失败（`workspace-move-invalid: not accounted`），已于 build 61→62（修复 15）**移除**——已存在的未分组会话无法经 API 移动，UI 的 Ungrouped 仅为浏览器本地聚合。
4b. **任务流水线（IssueRunner，v1.8.0）**：`IssueRunnerPanelController` 经 `git remote -v` 识别 GitHub 远端（`workspacePath` 提供的活动目录**权威**：是 GitHub 仓库 → 显示其 issues；非 GitHub（Ungrouped/非 git 会话 cwd）→ 诚实空态、**不替换其他已注册工作区**；仅启动早期 `ProjectDirectory` 未解析时才回退 `listWorkspacePaths` 从 `workspace.list` 取第一个 GitHub 仓库并 1s 间隔重试 ≤10 次；`applyRepo` 检测到切换到不同仓库先清空旧任务列表——issue 号按仓库归属）→ 拉 open issues（含 body；私有仓库按仓库作用域解析 token：**文件优先**——文件专属 `~/.dsh/tokens/<owner>-<repo>` → 文件通用 `~/.dsh/gh-token` → Keychain 专属 → Keychain 通用（免 Keychain 弹密码），保存双写 Keychain + 文件）→ 用户单击行**行内展开详情**（`expandedIssue` 手风琴，替代 NSAlert 弹窗：状态/标签/分支/PR/错误 + 正文滚动区，动作按钮 Process/Retry/Open PR/Cancel/Close 明确点击才执行，done 且有 PR 额外「评论并关闭 Issue」→ POST comment + PATCH close，杜绝误触）→ 串行队列（`core/lib/jobqueue.js`）：`git checkout main → pull → checkout -b <branchForIssue>`（label 含 feature/enhancement → `feature/issue-N`，否则 `fix/issue-N`，`docs/git-workflow.md` 统一分支规范）→ `session.create`（当前工作区）+ `session.rename` + `session.prompt`（issue-fix skill，mode queue）→ 轮询 running → 校验 `git ls-remote` 分支已推送（remote 名按 github>origin>首个 remote 解析，`pushRemoteName`）→ `POST /pulls` 开 PR（head=分支、base=main，feature/fix 回 main 一律走 PR）；失败/超时/取消各有状态，分支与会话保留可续跑；**关联索引**：任务开始时 `TaskIndex.mergeTask` 写 index.json（branch/state/title/startedAt），会话创建后 `TaskIndex.rememberSession` 写 local.json（sessionId），done/failed 时更新 prUrl/error/finishedAt；重启后 `restoreFromIndex` 按 index.json + local.json 重建任务列表与会话关联（`reloadIssues` 对已存在任务刷新 title/labels/body，6d265a5）；GitHub token 按仓库作用域存储（Keychain 专属 + 文件双写，不落 UserDefaults，详见 [issue-runner-panel](modules/issue-runner-panel.md)）。
5. **会话切换跟随（build 50→53）**：`rebuildWebView` 注入 `sessionTrackerScript`——监听 dsh web 的会话 RPC 请求体（`session.history/prompt/rename/selectModel` 的 `payload.sessionId`；`session.open()` 幂等不可靠，改以 `subagent.list {parentSessionId}` 作为每次切换的可靠信号），会话 id 变化时经 `dshSession` message handler 上报。壳层收到后 `DSHSessionRPC.fetchSessionCwd(port:sessionId:)` 查 cwd → **先**更新 `ProjectDirectory`（cwd 与当前不同才 set，保证任务面板等消费者读到新路径）→ `previewPanel.setProjectDirectory(cwd)`（只重设树根，不动已开页签）+ `wikiPanel.reloadRoot()`（重解析 + 重扫），随后**无条件**调用 `tasksPanel.workspaceChanged()`（4a7de43/40288d1：fetch 失败 cwd 为 nil 也触发——面板解析器回退扫描 `workspace.list`，修复切回 helloharness 面板不刷新的问题）；终端新标签页启动目录自动取新目录（build 60→61：`newSession()`/`spawnWithCwd()` 改用 `DSHSessionRPC.resolveProjectDirectory`——优先共享 `ProjectDirectory.current`=当前查看的工作区，未设置时回退实时查询并缓存，home 兜底保留）。
5b. **浏览器面板（CEF/Chromium，Agent 驱动）**：右栏 `browserPanel.ensureLoaded()` 懒建首 tab（恢复 `browserLastURL`）；每 tab = `BrowserCEFTab`（`BrowserOSRView` 容器 + CEF 浏览器（shim `CEFShim`，默认 OSR 离屏渲染帧回调自绘；`browserRenderMode` 可切窗口化）+ `BrowserCDPClient`（CDP 端口 9333，`DSH_CDP_PORT` 覆盖））；页面状态/console/网络日志由 CDP 事件写入 per-tab `BrowserLogBuffer`，Agent 经 `BrowserAPIServer`（127.0.0.1:3081，`DSH_BROWSER_PORT` 覆盖，生效端口写 `$DSH_HOME/browser-api.port`）curl 驱动：`open` 自动展开面板、`eval`/`screenshot` 取证、`debug`/`hierarchy` 拉 QA 诊断；CEF 消息泵由 main.swift 8ms 定时器驱动（`external_message_pump`），CDP target 拉取必须在后台线程（与消息泵互斥死锁）；关闭页签异步 `closeBrowser` + `g_cefClosingWindow` 守卫防 CEF 误关主窗口触发退出；退出 `applicationWillTerminate` → `browserPanel.shutdownAll()` + `browserAPIServer.stop()` + `CEFShim.shutdown()`（不调 `CefShutdown`，见 [browser-panel](modules/browser-panel.md)）。
6. **退出**：SIGTERM/SIGINT/SIGHUP → `NSApp.terminate`；`applicationWillTerminate` → `terminalPanel.shutdownAll()`（终止全部 PTY 会话进程组）+ `browserPanel.shutdownAll()`（关浏览器 + 断开 CDP）+ `browserAPIServer.stop()` + 停 CEF 消息泵 + `CEFShim.shutdown()`（泵 20 轮收尾，不调 `CefShutdown`）→ `server.stop()`（**只停自拉起的**服务：`terminate()` 后等 3 秒，未退出则 SIGKILL；复用的外部服务绝不动）；`applicationShouldTerminate` 拦截 CEF 引发的误退出（`g_cefClosingWindow` 置位期间取消并恢复主窗口）。

## 部署形态

- 单 `.app`（ad-hoc 签名，`codesign --force --deep --sign -`），自包含运行时在 `Contents/Resources/runtime/`（`node` + `npm/` + `dsh/` 依赖树 + `core/` 共享核心）；
- 发布物：`.pkg`（preinstall 先删旧版再装到 /Applications）+ `.dmg`（拖拽安装），由 `platforms/macos/make-pkg.sh` 生成；
- About 面板展示运行时事实：dsh 版本、Node 版本+路径（合并为一行）、运行时来源（内置/系统）、registry；
- dsh 升级只作用于内置运行时（`DSHUpdater.init` 要求路径含 `/Contents/Resources/runtime/`），绝不碰系统安装；升级会改写包内文件使 ad-hoc 签名失效（README 明示，本地运行不受影响）。

## 布局约束（窗口）

- `minWebViewWidth = 1100`：dsh web 低于 1024pt 会折叠左侧会话栏，壳层钳制 WebView 宽度（`splitView constrainMin/MaxCoordinate`、`applyRightPanelLayout`、`widenWindow`），窗口过窄时自动隐藏右栏；
- 右栏默认宽 560pt（`rightPanelDefaultWidth`），用户拖拽宽度记忆在 `previewPanelWidth`；
- 右栏最小宽 = 三个面板 minWidth 的最大值（`rightPanelMinWidth`）。
