---
title: 模块：main.swift（壳层核心）
tags: [module, main, server, appdelegate, menu]
updated: 2026-08-24T00:00:00Z
sources: [platforms/macos/src/main.swift, platforms/macos/src/SkillInstaller.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/ChannelPanel.swift, platforms/macos/src/ChannelStoreReader.swift, docs/builtin-skills-design.md, docs/channel-status.md, docs/channel-project-switch.md]
manual: false
---

# 模块：main.swift（壳层核心）

约 3600 行，程序入口（`NSApplication.shared` + `AppDelegate` + `app.run()`）。职责：日志、L10n、服务管理、dsh 升级、窗口/菜单、设置窗口（⌘,）、首次引导 onboarding、右栏插槽、WebView 注入、CoreBridge（调 core CLI）、channel runner 生命周期（`startConfiguredChannelRunners` / `runChannelLogin`）。另实现 `NSApplicationDelegate` + `NSWindowDelegate`（CEF 误关主窗口守卫、退出诊断）。

## 组成（按文件内顺序）

| 类型 | 职责 |
|---|---|
| `AppLog` | 写 `~/Library/Logs/oh-my-dsh/app.log`（串行队列、ISO8601 毫秒时间戳） |
| `L10n` | 中英文案表 + 语言解析（`DSH_LANG` > `appLanguage` > 系统语言）；`captureSystemLang` 启动时快照系统语言 |
| `HTTP` | 同步 GET 助手（信号量） |
| `VersionKit` | 语义化版本比较（支持 `x.y.z-rc.N`，rc 版本小于正式版） |
| `RegistryConfig` | 运行期 registry：`DSH_REGISTRY` > `dshRegistry` > 默认 `https://registry.npmmirror.com` |
| `SkillInstaller` | 内置 Skill 全局安装（见 [skill-installer](skill-installer.md)）：`installBuiltinSkills()` 启动时把三内置 skill 装到 `$DSH_HOME/skills/` + 旧名迁移 + 受管更新；Foundation-only |
| `DSHUpdater` | 内置 dsh 升级：`init` 要求 dshBin 路径含 `/Contents/Resources/runtime/`（只升内置）；`currentVersion`（读 package.json）、`latestVersion`（查 registry dist-tags）、`upgrade`（node npm-cli.js install） |
| `ServerManager` | 服务生命周期：`resolveNode`（`DSH_NODE` 显式覆盖 > 系统 node：PATH→nvm current→nvm default→nvm 最新→Homebrew 首个**通过版本门槛**者 > 内置 node 兜底）、`loginShellPath`（`/bin/zsh -ilc` 读一次登录 shell PATH，8s 超时兜底、结果缓存，失败保留继承值，赋给 dsh web 子进程）、`resolveDSHBin`（`DSH_CLI` > 内置 > npx 缓存/nvm/PATH/homebrew，最新 mtime 胜出）、`start`（复用 3080 → 或自拉起 + 90s 轮询就绪，含 1s 沉降校验防引导页假就绪；系统 node 启动失败回退内置 node 重试一次，`DSH_NODE` 显式指定不回退）、`stop`（SIGTERM → 3s → SIGKILL，只停自拉起的） |
| `ProjectDirectory` | 共享"活动项目目录"（`static var current`，standardized 路径去重）；由 `dshSession` 消息维护，供预览树/终端 cwd/wiki 根/任务面板工作区消费 |
| `DSHSessionRPC` | `fetchActiveSessionCwd`（POST /api/session.list，client-request 信封）+ `fetchSessionCwd(port:sessionId:)`（按会话 id 查 cwd）+ `resolveProjectDirectory`（优先返回 `ProjectDirectory.current`，否则后台实时查询并缓存） |
| `AppDelegate` | 生命周期/窗口/分割视图/活动栏/右栏插槽/菜单/升级/导航委托/下载/脚本消息；`applicationShouldTerminate`/`windowShouldClose` 用全局 `g_cefClosingWindow` 标记拦截 CEF 关页签时误关主窗口引发的退出（取消 + 0.3s 后恢复主窗口）；`windowWillClose` 记诊断日志；`uiDebug`（`DSH_UI_DEBUG=1` 或 `--ui-debug`）统一 QA 开关 |

## 关键行为

- **单实例约束 + 启动序列**：`applicationDidFinishLaunching` 最先做**单实例检查**（非开发版且同 bundle id 已有其他实例在跑 → 聚焦它并 `exit(0)`，此时尚未拉起 dsh web/CEF/channel、不碰共享 profile，防双实例争抢 CEF profile 致 Chromium 异常退出）→ `captureSystemLang` → 覆写 `AppleLanguages`（让 WebView 语言跟随壳）→ `installSignalHandlers`（SIGTERM/SIGINT/SIGHUP → `NSApp.terminate`）→ `buildMenu` → `SkillInstaller.installBuiltinSkills()`（best-effort，dsh web 启动前就绪）→ `buildWindow` → `startServer`；
- **WebView 注入**（`rebuildWebView`）：① `navigator.language/languages` 覆写脚本；② `previewInterceptorScript`——覆写 `window.fetch` 拦截 `/api/host.openPath`，把 `payload.path` 经 `messageHandlers.dshPreview.postMessage` 发给原生，并返回伪造 `server-response {ok:true}`，其余请求原样放行；③ `sessionTrackerScript`——覆写 `window.fetch` 解析会话 RPC 请求体（`session.history/prompt/rename/selectModel` 的 `payload.sessionId`、`subagent.list` 的 `payload.parentSessionId`），id 变化时经 `messageHandlers.dshSession.postMessage({sessionId})` 上报（`session.open()` 幂等不可靠，`subagent.list` 是每次切换必走的可靠信号）；注册 message handler `dshPreview`（收到后 `setRightPanel(.preview)` + `previewPanel.open(path:)`）与 `dshSession`（收到后 `fetchSessionCwd` → **先** `ProjectDirectory.set`（cwd 与当前不同才设）→ `previewPanel.setProjectDirectory` + `wikiPanel.reloadRoot`，随后**无条件**调用 `tasksPanel.workspaceChanged()`——fetch 失败 cwd 为 nil 也触发，面板回退扫描 `workspace.list`）；
- **右栏插槽**：`RightPanel` 枚举（`none/preview/terminal/wiki/tasks/browser/channel`，六面板）+ `setRightPanel`（活动面板根视图直接挂为 NSSplitView 右 pane `subviews[1]`；隐藏 = divider 推到最右；状态持久化 `previewPanelState`/`rightPanelKind`——新增 `"channel"` 映射；宽度持久化 `previewPanelWidth`）；`applyRightPanelLayout` 是唯一布局例程（加宽窗口 + 重设 divider）；`minWebViewWidth = 1100` 防 dsh 侧栏折叠（1024pt 断点）；
- **菜单**：App 菜单、**文件菜单（`menu.file`/`menu.save`）**——「保存 Save」⌘S（`saveActiveFile` → `previewPanel.saveActiveTab()`，保存当前可编辑页签）与「关闭页签」⌘W（`closeActiveFileTab`，无页签时禁用、⌘W 落到关窗，由 `onTabsChanged`→`updateCloseTabMenuState` 驱动）、编辑菜单（让 ⌘C/V/X/A/Z 路由到 WKWebView 首响应者）、视图菜单（⌥⌘P / ⌥⌘T / ⌥⌘W / ⌥⌘J / ⌥⌘B 五面板切换）、设置菜单（dsh 设置/升级/registry/自动升级/wiki 设置组/日志/语言子菜单）；语言切换重建菜单 + 重建 WebView + 重载页面；
- **About 面板**：自定义窗口显示版本、build、dsh 版本、运行时来源、Node 版本+路径（合并为一行，如 `Node: v22.23.2 (/usr/local/bin/node)`）、registry；
- **导航策略**：非 localhost 链接一律交默认浏览器（`NSWorkspace.open`）；不可显示 MIME 走 `WKDownload`（原生另存为对话框）；JS alert/confirm/prompt 桥接为 NSAlert；
- **通道（Channel）集成**：`applicationDidFinishLaunching` 末尾 `startConfiguredChannelRunners()`——按已启用全局 channel（读 `~/.dsh/channels/*.json` 账号）逐个拉起 runner 子进程（同 channelId 去重）；`runChannelLogin(channelId:onQRUrl:completion:)` 把扫码登录桥到 core CLI（`channel login --save`），面板内 `CIQRCodeGenerator` 渲染二维码后自动拉起 runner；退出 `applicationWillTerminate` 关闭 channel runner（runner SIGTERM 立即退出，208e618）；`startChannelRunner` 把 runner 的 stdout/stderr 路由到 `~/Library/Logs/oh-my-dsh/channel-runner-<channelId>.log`（逐个创建 + seekToEnd 追加，暴露 core 调试日志，见 [channel-panel](channel-panel.md)）；**PR #30**（2026-08-23）`startChannelRunner` **删除**读/写项目 refs 与「强制补 ref」逻辑，改用 `channel run <id> <port> [] --project-root <activeRoot>`（runner 重读该通道全局 `~/.dsh/channels/<id>.workspaces.json` 判定「项目开关」启用）；L10n 新增 `channel.notEnabledInProject`（「未在项目启用」，见 [channel-panel](channel-panel.md)「项目开关」）；终端启动目录解析忽略系统临时目录会话（如 `chan-e2e-*` 测试残留，261cdd9），避免默认落在测试临时目录；
- **调试钩子**：`DSH_PREVIEW_TEST_PATH` / `DSH_TERMINAL_TEST` / `DSH_WIKI_TEST` / `DSH_BROWSER_TEST`（启动即开对应面板）；`DSH_UI_DEBUG=1` 或 `--ui-debug`（统一 `uiDebug`：打开浏览器面板 + 面板层级 dump（浏览器 maxDepth=8）+ 截图 `panel-*-debug.png`）/ `DSH_PREVIEW_DEBUG`（fetch 拦截探针 + 视口/侧栏状态上报）/ `DSH_SESSION_DEBUG`（会话跟踪器 dump `__dshSessionSeen`）；
- **浏览器 QA 遮挡诊断**：`dumpBrowserHierarchyJSON()`（`POST /api/browser/hierarchy` 拉取）——`NSApp.windows` 全清单 + split panes + 面板层级 JSON（class/frame/layer 属性 + superlayer 链）+ 面板/内容区中心 `hitTest` + `writeScreenshot`（`cacheDisplay` → `/tmp/window-shot.png`、`/tmp/panel-browser-shot.png`）；`hierarchyJSON` 递归 ≤8 层；`dlog` 同写 AppLog 与 stdout；
- **CEF 初始化**：`startBrowserAPI` 附近——渲染模式按 UserDefaults `browserRenderMode`（`defaults write com.ohmydsh.app browserRenderMode -string windowed` 切窗口化，默认 OSR 离屏）；CEF profile 根 `dshHome + "/browser"`（开发版 `isDevBuild` 用独立 `~/.dsh/browser-dev`，可与正式版并存不争抢）；`use-mock-keychain` + 软件渲染兜底开关；`cleanStaleCEFSingleton` 清陈旧单例锁；退出 `applicationWillTerminate` → 面板 `shutdownAll()` + `browserAPIServer.stop()` + 停消息泵 + `CEFShim.shutdown()`（不调 `CefShutdown`，见 [browser-panel](browser-panel.md)）；
- **升级触发**：`runAutoUpgradeIfNeeded`（24h 节流、静默失败）与手动 `upgradeDSH`（NSAlert 展示结果）。

## 与其他模块的关系

- 持有 `FilePanelController`（预览/文件面板，`feature/file-panel` 起 `previewPanel` 属性类型与初始化由 `PreviewPanelController` 改为 `FilePanelController`，见 [file-panel](file-panel.md)）/ `TerminalPanelController` / `WikiPanelController` / `IssueRunnerPanelController` / `BrowserPanelController` / `ChannelPanelController` 实例；面板只通过 `onRequestHide`/`serverPortProvider`/`serverReady(port:)` 与壳通信（wiki 面板另有 `onAutoUpdateSettingChanged` 回调 → 重建菜单，让「设置」勾选状态与面板首生成弹窗的选择同步；任务面板另有 `workspacePath` 闭包取当前工作区路径；浏览器面板另由 `BrowserAPIBridge` 桥接——`showPanel`/`hidePanel`/`isPanelVisible` 闭包接 `setRightPanel`，`debugDump`/`debugState`/`debugHierarchy` 闭包接 QA 诊断（`dumpPanelDebugInfo`/`browserPanel.debugState()`/`dumpBrowserHierarchyJSON`），REST API 服务 `BrowserAPIServer` 在 `applicationDidFinishLaunching` 启动、`applicationWillTerminate` 停止）；
- 提供共享 UI 组件文件是 `PreviewPanel.swift`（非 main.swift）；
- wiki 设置（`toggleWikiAutoRegenerate`/`toggleWikiRegisterAgentsMD`/`setWikiRootMode`）操作 `WikiPaths`/`WikiAgentsMD` 并转发 `wikiPanel.reloadRoot()`。