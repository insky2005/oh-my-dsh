---
title: 模块：main.swift（壳层核心）
tags: [module, main, server, appdelegate, menu]
updated: 2026-08-17T12:17:48Z
sources: [platforms/macos/src/main.swift]
manual: false
---

# 模块：main.swift（壳层核心）

约 2850 行，程序入口（`NSApplication.shared` + `AppDelegate` + `app.run()`）。职责：日志、L10n、服务管理、dsh 升级、窗口/菜单、设置窗口（⌘,）、首次引导 onboarding、右栏插槽、WebView 注入、CoreBridge（调 core CLI）。

## 组成（按文件内顺序）

| 类型 | 职责 |
|---|---|
| `AppLog` | 写 `~/Library/Logs/oh-my-dsh/app.log`（串行队列、ISO8601 毫秒时间戳） |
| `L10n` | 中英文案表 + 语言解析（`DSH_LANG` > `appLanguage` > 系统语言）；`captureSystemLang` 启动时快照系统语言 |
| `HTTP` | 同步 GET 助手（信号量） |
| `VersionKit` | 语义化版本比较（支持 `x.y.z-rc.N`，rc 版本小于正式版） |
| `RegistryConfig` | 运行期 registry：`DSH_REGISTRY` > `dshRegistry` > 默认 `https://registry.npmmirror.com` |
| `DSHUpdater` | 内置 dsh 升级：`init` 要求 dshBin 路径含 `/Contents/Resources/runtime/`（只升内置）；`currentVersion`（读 package.json）、`latestVersion`（查 registry dist-tags）、`upgrade`（node npm-cli.js install） |
| `ServerManager` | 服务生命周期：`resolveNode`（`DSH_NODE` 显式覆盖 > 系统 node：PATH→nvm→Homebrew 首个可用 > 内置 node 兜底）、`resolveDSHBin`（`DSH_CLI` > 内置 > npx 缓存/nvm/PATH/homebrew，最新 mtime 胜出）、`start`（复用 3080 → 或自拉起 + 90s 轮询就绪；系统 node 启动失败回退内置 node 重试一次，`DSH_NODE` 显式指定不回退）、`stop`（SIGTERM → 3s → SIGKILL，只停自拉起的） |
| `ProjectDirectory` | 共享"活动项目目录"（`static var current`，standardized 路径去重）；由 `dshSession` 消息维护，供预览树/终端 cwd/wiki 根/任务面板工作区消费 |
| `DSHSessionRPC` | `fetchActiveSessionCwd`（POST /api/session.list，client-request 信封）+ `fetchSessionCwd(port:sessionId:)`（按会话 id 查 cwd）+ `resolveProjectDirectory`（优先返回 `ProjectDirectory.current`，否则后台实时查询并缓存） |
| `AppDelegate` | 生命周期/窗口/分割视图/活动栏/右栏插槽/菜单/升级/导航委托/下载/脚本消息 |

## 关键行为

- **启动序列**：`captureSystemLang` → 覆写 `AppleLanguages`（让 WebView 语言跟随壳）→ `installSignalHandlers`（SIGTERM/SIGINT/SIGHUP → `NSApp.terminate`）→ `buildMenu` → `buildWindow` → `startServer`；
- **WebView 注入**（`rebuildWebView`）：① `navigator.language/languages` 覆写脚本；② `previewInterceptorScript`——覆写 `window.fetch` 拦截 `/api/host.openPath`，把 `payload.path` 经 `messageHandlers.dshPreview.postMessage` 发给原生，并返回伪造 `server-response {ok:true}`，其余请求原样放行；③ `sessionTrackerScript`——覆写 `window.fetch` 解析会话 RPC 请求体（`session.history/prompt/rename/selectModel` 的 `payload.sessionId`、`subagent.list` 的 `payload.parentSessionId`），id 变化时经 `messageHandlers.dshSession.postMessage({sessionId})` 上报（`session.open()` 幂等不可靠，`subagent.list` 是每次切换必走的可靠信号）；注册 message handler `dshPreview`（收到后 `setRightPanel(.preview)` + `previewPanel.open(path:)`）与 `dshSession`（收到后 `fetchSessionCwd` → **先** `ProjectDirectory.set`（cwd 与当前不同才设）→ `previewPanel.setProjectDirectory` + `wikiPanel.reloadRoot`，随后**无条件**调用 `tasksPanel.workspaceChanged()`——fetch 失败 cwd 为 nil 也触发，面板回退扫描 `workspace.list`）；
- **右栏插槽**：`RightPanel` 枚举 + `setRightPanel`（活动面板根视图直接挂为 NSSplitView 右 pane `subviews[1]`；隐藏 = divider 推到最右；状态持久化 `previewPanelState`/`rightPanelKind`；宽度持久化 `previewPanelWidth`）；`applyRightPanelLayout` 是唯一布局例程（加宽窗口 + 重设 divider）；`minWebViewWidth = 1100` 防 dsh 侧栏折叠（1024pt 断点）；
- **菜单**：App 菜单、编辑菜单（让 ⌘C/V/X/A/Z 路由到 WKWebView 首响应者）、视图菜单（⌥⌘P / ⌥⌘T / ⌥⌘W / ⌥⌘J 四面板切换）、设置菜单（dsh 设置/升级/registry/自动升级/wiki 设置组/日志/语言子菜单）；语言切换重建菜单 + 重建 WebView + 重载页面；
- **About 面板**：自定义窗口显示版本、build、dsh 版本、运行时来源、Node 版本+路径（合并为一行，如 `Node: v22.23.2 (/usr/local/bin/node)`）、registry；
- **导航策略**：非 localhost 链接一律交默认浏览器（`NSWorkspace.open`）；不可显示 MIME 走 `WKDownload`（原生另存为对话框）；JS alert/confirm/prompt 桥接为 NSAlert；
- **调试钩子**：`DSH_PREVIEW_TEST_PATH` / `DSH_TERMINAL_TEST` / `DSH_WIKI_TEST` / `DSH_UI_DEBUG`（层级 dump + 截图）/ `DSH_PREVIEW_DEBUG`（fetch 拦截探针 + 视口/侧栏状态上报）/ `DSH_SESSION_DEBUG`（会话跟踪器 dump `__dshSessionSeen`）；
- **升级触发**：`runAutoUpgradeIfNeeded`（24h 节流、静默失败）与手动 `upgradeDSH`（NSAlert 展示结果）。

## 与其他模块的关系

- 持有 `PreviewPanelController` / `TerminalPanelController` / `WikiPanelController` / `IssueRunnerPanelController` 实例；四个面板只通过 `onRequestHide`/`serverPortProvider`/`serverReady(port:)` 与壳通信（wiki 面板另有 `onAutoUpdateSettingChanged` 回调 → 重建菜单，让「设置」勾选状态与面板首生成弹窗的选择同步；任务面板另有 `workspacePath` 闭包取当前工作区路径）；
- 提供共享 UI 组件文件是 `PreviewPanel.swift`（非 main.swift）；
- wiki 设置（`toggleWikiAutoRegenerate`/`toggleWikiRegisterAgentsMD`/`setWikiRootMode`）操作 `WikiPaths`/`WikiAgentsMD` 并转发 `wikiPanel.reloadRoot()`。
