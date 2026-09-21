---
title: 模块：TerminalPanel.swift（终端面板）
tags: [module, terminal, pty, ansi, emulator, workspace-tabs, selection]
updated: 2026-09-21T08:44:52Z
sources: [platforms/macos/src/TerminalPanel.swift, platforms/macos/src/TerminalWorkspaceTabs.swift, platforms/macos/src/WorkspaceTabMemory.swift, platforms/macos/src/PanelSurface.swift, platforms/macos/src/main.swift, docs/ui-color-scheme.md, docs/ux-feedback.md, docs/terminal-input-fix.md, docs/terminal-header-fix.md, tests/terminal-panel/, tests/terminal-emulator/]
manual: false
---

# 模块：TerminalPanel.swift（终端面板）

约 2180 行（2026-09-21 实测）。右栏集成终端：原生 PTY 会话 + 自研轻量 ANSI/VT 模拟器，支持多标签页，且**标签页按 workspace（dsh 会话工作目录）隔离与记忆**。

## 层次结构

### `TerminalSession`（PTY 会话）

- `resolveShell()`：`$SHELL` 存在则用，否则 `/bin/zsh`；`buildEnv()`：默认 `TERM=xterm-256color`，强制 `LANG/LC_ALL/LC_CTYPE=en_US.UTF-8`（防非 UTF-8 locale 下渲染 `<ffffffff>` 占位）；
- 启动：`forkpty` 创建 PTY，子进程 `exec` shell（参数经 `strdup` + `execve`）；
- 读写：读在后台队列（`poll` + 4096B 缓冲，UTF-8 感知的 `decodeChunk`，半字符挂起等待）；**写入用 `data.withUnsafeBytes` 循环 `Darwin.write`**（文档化坑：`&bytes[off]` 会写出 Swift 数组对象头——见 `docs/terminal-input-fix.md`）；`writeQueue` 串行化；
- `resize(rows:cols:)`：`TIOCSWINSZ` 转发（行列夹在 2…200）；
- 退出：正常 exit 或 `terminate()`（杀整个进程组）→ `reap` 回收；`State: running / exited(code) / terminated`。

### `TerminalEmulator`（ANSI/VT 状态机）

- 网格：`Cell { ch, fg, bg, bold, italic, underline, inverse, continuation }`；`screen` + `scrollback`；
- 解析器：`ParserState { ground, escape, swallow, csi, osc, oscST, dcs, dcsST }`；`feed(_ text:)` 逐字符驱动；
- 支持子集：光标寻址（CUU/CUD/CUF/CUB/CUP/CNL/CPL/CHA/VPA）、SGR 颜色（16/256/truecolor）、擦除（ED/EL/ECH）、删插（DCH/ICH/IL/DL）、滚动、**备用屏**、**OSC 标题**（`finishOSC` → `onTitle`）、DECAWM、RIS 复位；
- **模式跟踪**：`applicationCursorKeys`（`CSI ? 1 h/l`）与 `bracketedPaste`（`CSI ? 2004 h/l`）——决定方向键编码与粘贴包封；
- 选择/复制：`Selection` 模型 + `selectedText`；`displayWidth` 处理宽字符/零宽连接符（近似宽度）。

### `TerminalView`（绘制与输入）

- `isOpaque = true` + `wantsLayer = true`（配合 `contentContainer.wantsLayer + masksToBounds` 修复 header 合成问题，见 `docs/terminal-header-fix.md`）；底色为 `PanelSurface.dynamic`（不再用 `.textBackgroundColor`）；
- 绘制：按行画 run（字体/前景/背景/粗斜下划线）、光标（块）、选区高亮；
- **滚动方向对齐面板语义（#3）**：`scrollWheel(with:)` 改为 NSScrollView 语义——正的 `scrollingDeltaY` → 显示**更早**的行（与文件树/网页一致）。灵敏度：触控板**精确 delta 4 点 = 1 行**（保留小数累加器），动量阶段的衰减 delta 自然表现为「先快后慢」的惯性；鼠标滚轮（非精确 delta）一格 = 一行；
- **选择（#4）**：`mouseDown` 按 `event.clickCount` 分支——**双击选词**（词内字符含路径/URL 的 `/ - . _ :` 等，保证路径与参数完整）、**三击选整行**；**双击/三击后带着「选择单位」继续拖拽**按整词/整行扩选，普通拖拽仍逐格选择（`wordDragSelection(to:)`）；`mouseUp` 结束拖选时 `copySelectionIfAutoCopy()`；
- **选中即复制（#4）**：开关 `TerminalView.autoCopyKey` = **`terminal.autoCopy`**（`ShellConfig`，默认**开**，「设置菜单 → 终端：选中文本即复制」`settings.terminalAutoCopy` 切换）；**无选区时 ⌘C 发 SIGINT 的既有语义不变**；
- 输入：`keyDown` 映射特殊键（方向/功能键/退格等，`specialKey(for:)`）；`copy`/`paste`（多行走括号粘贴）/`selectAll`/⌘K 清屏。

### `TerminalPanelController`（多标签面板）

- **头部固定标题**：「终端 / Terminal」（复用活动栏键 `bar.terminal`），**不跟随会话**；会话标题（OSC 标题 / 已结束状态）留在页签与头部 tooltip；
- 根视图 `TerminalRootView` 自绘面板底色（`.panel`，`isOpaque = false`）；页签标题用 `PanelTabButton`（见 `docs/ui-color-scheme.md`）；
- `minWidth = 300`；标签页默认命名「终端 1/2/3…」，OSC 标题自动改名；**⌘1-9 直切、⌘⇧[ / ⌘⇧] 循环只在当前 workspace 的可见页签间进行**；`+` 新建、`✕` 关闭；
- `serverReady(port:)` 门控：服务就绪后新会话以**当前查看的工作区目录**为 cwd 启动（`newSession()`/`spawnWithCwd()` 调 `DSHSessionRPC.resolveProjectDirectory`，优先共享 `ProjectDirectory.current`，失败回退 `~`，`armSpawnFallbackTimer` 兜底）；
- `exit` / `⌃D` → 正常结束自动关标签页（最后一个标签退出则收起面板）；异常退出（信号杀死）→ 保留「会话已结束 + 重启」态；
- `shutdownAll()`：App 退出时终止所有会话（main.swift `applicationWillTerminate` 调用）。

## 页签按 workspace 隔离 / 记忆（#5）

**纯模型** `TerminalWorkspaceTabs.swift`（无 AppKit，`tests/terminal-panel/` 直接驱动）：`workspaceByTab`（页签 → workspace key）、`globalTabs`、`forgottenTabs`、`lastSelectedByWorkspace`；`assign(tabId:workspacePath:isGlobal:)` / `forget(tabId:)` / `forgetAll()` / `isVisible(tabId:current:)` / `visibleIds(_:current:)` / `rememberSelection(tabId:current:)` / `lastSelectedId(current:among:)`。

- **隐藏而不终止**：终端是**活进程**，切走 workspace 只隐藏页签、shell 继续跑（与 Files 面板的「关页签释放编辑器」取舍不同）；切回时同一批页签原样回来并重新选中上次的那个；
- **key 归一化**：`TerminalWorkspaceTabs.key(for:)` 复用 `WorkspaceTabMemory.key(for:)`（`standardizingPath` + 去尾斜杠），`/repo` 与 `/repo/` 视为同一 workspace；
- **全局页签**：无法解析项目目录时（服务启动中 / RPC 失败回退 home）spawn 出来的页签标为 **GLOBAL**，在**每个** workspace 都可见——用户确实拿到过一个可用的 shell，不能因为切走就丢掉它；同理**从未登记过的 id 不隐藏**，而 `forget()` 过的（已关闭）必须消失；
- **壳层接线**：`main.swift` 的 `dshSession` 处理器在更新 `ProjectDirectory`/`previewPanel` 之后调用 `terminalPanel.setWorkspaceDirectory(cwd)`；「打开终端面板」（活动栏 / ⌥⌘T）时若 `ProjectDirectory.current` 已知也先同步，避免页签栏显示的是 home 默认那批；
- **切换时自动开一个（QA 后续）**：切到「没有活终端」的 workspace 且终端面板**确实在屏上**（`isPanelOnScreen` = `!view.isHidden && view.window != nil`）时自动 `newSession()`，不用再手动点 `+`；面板不可见则不开（避免用户只是路过就白白拉起 shell）；
- **`syncTabVisibility()`**：只显示当前 workspace 的页签，选中项不可见时依次尝试「上次选中 → 第一个可见 → 空态」；
- **待定**：隐藏期间会话数量上限与内存占用策略（当前不设上限，与「不杀会话」的取舍一致）。

## 测试

`tests/terminal-panel/run.sh`（无头，**不建 PTY**：只实例化 controller 断言头部与模型层状态）：

- 编译清单 = `stubs.swift`（L10n/AppLog/ShellConfig/共享 UI 基件）+ `TerminalPanel.swift` + `PanelSurface.swift` + `TerminalWorkspaceTabs.swift` + `WorkspaceTabMemory.swift` + `panel-tests.swift`（改名 `main.swift`）；
- 覆盖：头部固定标题（语言切换后仍固定、关会话后不被清空）+ `TerminalWorkspaceTabs` 的可见性/记忆规则（同 workspace 可见、尾斜杠等价、切换换页签、每页签独立 key、全局页签处处可见、切回恢复选中、已关闭不恢复）+ **选中即复制默认开且随设置变化**；
- 会话路径（真实 shell 输入输出、滚动、选择）靠手动 QA，见 .dsh/wiki/tasks.md。

## 已知限制（README）

- v1 不支持输入法直接打字（中文等经 ⌘V 粘贴输入）；
- DECSTBM 滚动区未实现（个别全屏程序显示异常）；
- 组合表情/零宽连接符按近似宽度渲染；
- 会话不跨 App 重启保留；切走 workspace 时隐藏的会话仍在后台存活（无数量上限）。
