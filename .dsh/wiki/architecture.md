---
title: 架构
tags: [architecture, layers, dataflow, deployment]
updated: 2026-08-15T14:22:31Z
sources: [src/main.swift, src/PreviewPanel.swift, src/TerminalPanel.swift, src/WikiPanel.swift, docs/repo-wiki-design.md]
manual: false
---

# 架构

## 分层

```
┌────────────────────────────── oh-my-dsh.app（壳层，Swift）──────────────────────────────┐
│ AppDelegate（main.swift）                                                                │
│   ├─ ServerManager   服务探测/拉起/复用/停止；resolveNode/resolveDSHBin                   │
│   ├─ DSHUpdater      内置 dsh 检查与升级（node + npm-cli.js install）                     │
│   ├─ RegistryConfig  运行期 npm registry（默认国内源）                                    │
│   ├─ L10n            中/英文案表（跟随系统，DSH_LANG 可覆盖）                             │
│   ├─ DSHSessionRPC   经 HTTP RPC 解析会话 cwd（client-request 信封）                      │
│   ├─ ProjectDirectory 共享"活动项目目录"（跟随 dsh web 当前会话，见数据流 6）             │
│   └─ 右栏插槽 RightPanel { none, preview, terminal, wiki }（三面板互斥）                  │
│        ├─ PreviewPanelController（PreviewPanel.swift）                                   │
│        ├─ TerminalPanelController（TerminalPanel.swift）                                 │
│        └─ WikiPanelController（WikiPanel.swift）                                         │
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

- `main.swift` 持有三个面板 controller（`previewPanel`/`terminalPanel`/`wikiPanel`），通过 `setRightPanel` 把活动面板根视图挂为 NSSplitView 右 pane（`subviews[1]`），隐藏时把 divider 推到最右；
- 三个面板复用 `PreviewPanel.swift` 中定义的共享 UI 组件：`HoverButton`、`DynamicFillView`、`ActivityBarButton`、`PanelIconButton`、`HeaderLabel`、`CustomIconButton`、`BakedIconView`；
- 所有 L10n 文案集中在 `main.swift` 的 `L10n.table`；
- 面板通过 `serverPortProvider` 闭包取当前端口，`serverReady(port:)` 在服务就绪后获得门控通知；
- **共享项目目录**：`ProjectDirectory`（main.swift）保存当前活动项目目录，三处消费——预览树、终端新会话 cwd、wiki 根解析（`resolveProjectDirectory` 优先返回它，其次实时查询并缓存）；
- 构建依赖：`build-app.sh` 显式列出编译源文件，新增文件必须登记（v1.7.0 加入了 `WikiPanel.swift`）。

## 关键数据流

1. **启动**：`applicationDidFinishLaunching` → `L10n.captureSystemLang()`（在改写 AppleLanguages 前快照系统语言）→ `installSignalHandlers` → `buildMenu` → `buildWindow` → `startServer`。`ServerManager.start()`：先查 3080 是否已是 dsh web（`isDSHServing`，页面含 `__DSH_BOOT__`）→ 复用；否则解析 node/dsh 入口、`node <bin> web --port <n>` 自拉起，轮询直到就绪（90s 超时，进程提前退出则抛错）。就绪后 `webView.load`，并通知终端/面板 `serverReady(port:)`。
2. **文件预览拦截**：`rebuildWebView` 注入两段用户脚本——① 覆写 `navigator.language/languages` 跟随壳语言；② `previewInterceptorScript` 覆写 `window.fetch`，拦截 `/api/host.openPath` RPC，把路径经 `window.webkit.messageHandlers.dshPreview.postMessage` 发给原生层，并回一个假的 `server-response` 成功（页面不会打开系统默认应用）。AppDelegate `userContentController` 收到后切换/打开预览面板 `previewPanel.open(path:)`。
3. **项目目录解析**：`DSHSessionRPC.fetchActiveSessionCwd(port:)` POST `/api/session.list`（`client-request` 信封：`{type, rpcId, method, payload}` → `{result:{ok, value}}`），取 running 会话优先、按 `updatedAt` 最新的非 blank 会话 cwd。预览树、终端新会话、wiki 根解析都基于它。
4. **Wiki 生成**：面板「+」→ `WikiRPC.createSession(cwd: repoRoot)` + `promptSession(mode: queue)` 触发代理执行 `repo-wiki` skill → 代理写 `.dsh/wiki/**`；面板轮询 `session.list` 的 running 标志显示「生成中」——内容区**叠加半透明浮层**（`WikiOverlayView`，0.82 透明度背景 + 居中「Generating…」NSTextField），页面与树全程可见、布局不消失（build 57→58）；底部状态条每秒刷新已耗时（`wiki.generatingElapsed`）；**生成状态按仓库根关联**（`generations: [canonicalRepo: Generation]`，build 59→60，可多仓库并发各一个生成，`syncGenerationUI` 只让 UI 反映当前仓库）；文件监听（2s 轮询 + 签名比对）驱动刷新与陈旧标记（生成期间代理每写出一页，左侧树即实时出现该页）；完成/失败/取消后都 `refresh()` 恢复内容区；取消走 `WikiRPC.cancel`（`session.cancel {sessionId}`）。**工作区归组**（build 48→49）：`WikiRPC.resolveWorkspaceId` 用 `workspace.list` 按规范化路径匹配当前仓库工作区，`createSession` 优先传 `workspaceId`（否则回退 `cwd`）——新会话直接归入工作区；曾有的 `attachOrphans`（把既有未分组会话经 `workspace.insertSessionBefore` 挂入工作区，幂等 + 30s 节流）因 RPC 无 attach 接口、对未分组会话必然失败（`workspace-move-invalid: not accounted`），已于 build 61→62（修复 15）**移除**——已存在的未分组会话无法经 API 移动，UI 的 Ungrouped 仅为浏览器本地聚合。
5. **会话切换跟随（build 50→53）**：`rebuildWebView` 注入 `sessionTrackerScript`——监听 dsh web 的会话 RPC 请求体（`session.history/prompt/rename/selectModel` 的 `payload.sessionId`；`session.open()` 幂等不可靠，改以 `subagent.list {parentSessionId}` 作为每次切换的可靠信号），会话 id 变化时经 `dshSession` message handler 上报。壳层收到后 `DSHSessionRPC.fetchSessionCwd(port:sessionId:)` 查 cwd → 更新 `ProjectDirectory` → `previewPanel.setProjectDirectory(cwd)`（只重设树根，不动已开页签）+ `wikiPanel.reloadRoot()`（重解析 + 重扫）；终端新标签页启动目录自动取新目录（build 60→61：`newSession()`/`spawnWithCwd()` 改用 `DSHSessionRPC.resolveProjectDirectory`——优先共享 `ProjectDirectory.current`=当前查看的工作区，未设置时回退实时查询并缓存，home 兜底保留）。
6. **退出**：SIGTERM/SIGINT/SIGHUP → `NSApp.terminate`；`applicationWillTerminate` → `terminalPanel.shutdownAll()`（终止全部 PTY 会话进程组）→ `server.stop()`（**只停自拉起的**服务：`terminate()` 后等 3 秒，未退出则 SIGKILL；复用的外部服务绝不动）。

## 部署形态

- 单 `.app`（ad-hoc 签名，`codesign --force --deep --sign -`），自包含运行时在 `Contents/Resources/runtime/`（`node` + `npm/` + `dsh/` 依赖树）；
- 发布物：`.pkg`（preinstall 先删旧版再装到 /Applications）+ `.dmg`（拖拽安装），由 `make-pkg.sh` 生成；
- About 面板展示运行时事实：dsh 版本、Node 版本、运行时来源（内置/系统）、registry；
- dsh 升级只作用于内置运行时（`DSHUpdater.init` 要求路径含 `/Contents/Resources/runtime/`），绝不碰系统安装；升级会改写包内文件使 ad-hoc 签名失效（README 明示，本地运行不受影响）。

## 布局约束（窗口）

- `minWebViewWidth = 1100`：dsh web 低于 1024pt 会折叠左侧会话栏，壳层钳制 WebView 宽度（`splitView constrainMin/MaxCoordinate`、`applyRightPanelLayout`、`widenWindow`），窗口过窄时自动隐藏右栏；
- 右栏默认宽 560pt（`rightPanelDefaultWidth`），用户拖拽宽度记忆在 `previewPanelWidth`；
- 右栏最小宽 = 三个面板 minWidth 的最大值（`rightPanelMinWidth`）。
