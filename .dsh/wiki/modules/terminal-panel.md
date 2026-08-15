---
title: 模块：TerminalPanel.swift（终端面板）
tags: [module, terminal, pty, ansi, emulator]
updated: 2026-08-15T15:31:24Z
sources: [platforms/macos/src/TerminalPanel.swift, docs/terminal-input-fix.md, docs/terminal-header-fix.md]
manual: false
---

# 模块：TerminalPanel.swift（终端面板）

约 1875 行。右栏集成终端：原生 PTY 会话 + 自研轻量 ANSI/VT 模拟器，支持多标签页。

## 层次结构

### `TerminalSession`（PTY 会话）

- `resolveShell()`：`$SHELL` 存在则用，否则 `/bin/zsh`；`buildEnv()`：默认 `TERM=xterm-256color`，强制 `LANG/LC_ALL/LC_CTYPE=en_US.UTF-8`（防非 UTF-8 locale 下渲染 `<ffffffff>` 占位）；
- 启动：`forkpty` 创建 PTY，子进程 `exec` shell（参数经 `strdup` + `execve`）；
- 读写：读在后台队列（`poll` + 4096B 缓冲，UTF-8 感知的 `decodeChunk`，半字符挂起等待）；**写入用 `data.withUnsafeBytes` 循环 `Darwin.write`**（文档化坑：`&bytes[off]` 会写出 Swift 数组对象头——见 `docs/terminal-input-fix.md`）；`writeQueue` 串行化；
- `resize(rows:cols:)`：`TIOCSWINSZ` 转发（行列夹在 2…200）；
- 退出：正常 exit 或 `terminate()`（杀整个进程组）→ `reap` 回收；`State: running / exited(code) / terminated`。

### `TerminalEmulator`（ANSI/VT 状态机）

- 网格：`Cell { ch, fg, bg, bold, italic, underline, inverse, continuation }`；`screen` + `scrollback`（滚动历史）；
- 解析器：`ParserState { ground, escape, swallow, csi, osc, oscST, dcs, dcsST }`；`feed(_ text:)` 逐字符驱动；
- 支持子集：光标寻址（CUU/CUD/CUF/CUB/CUP/CNL/CPL/CHA/VPA）、SGR 颜色（16/256/truecolor，`palette256`/`rgb`）、擦除（ED/EL/ECH）、删插（DCH/ICH/IL/DL）、滚动、**备用屏**（`enterAltScreen`/`exitAltScreen`，vim/top/less 用）、**OSC 标题**（`finishOSC` → `onTitle` 更新标签名）、DECAWM 自动换行、RIS 复位；
- **模式跟踪**：`applicationCursorKeys`（`CSI ? 1 h/l`）与 `bracketedPaste`（`CSI ? 2004 h/l`）——决定方向键编码（应用模式 `\x1bOA`，普通 `\x1b[A`）与粘贴包封（`\x1b[200~…\x1b[201~`）；
- 选择/复制：`Selection` 模型 + `selectedText`；`displayWidth` 处理宽字符/零宽连接符（近似宽度）。

### `TerminalView`（绘制与输入）

- `isOpaque = true` + `wantsLayer = true`（配合 `contentContainer.wantsLayer + masksToBounds` 修复 header 合成问题，见 `docs/terminal-header-fix.md`）；
- 绘制：按行画 run（字体/前景/背景/粗斜下划线）、光标（块）、选区高亮；`scrollWheel` 滚动历史（`followOutput` 跟随输出）；
- 输入：`keyDown` 映射特殊键（方向/功能键/退格等，`specialKey(for:)`）；`copy`（无选区时 ⌘C 发 SIGINT）、`paste`（多行走括号粘贴）、`selectAll`、⌘K 清屏；
- 鼠标拖拽选中 + ⌘C 复制。

### `TerminalPanelController`（多标签面板）

- `minWidth = 300`；标签页默认命名「终端 1/2/3…」，OSC 标题自动改名；`⌘1-9` 直切、`⌘⇧[`/`⌘⇧]` 循环、`+` 新建、`✕` 关闭；
- `serverReady(port:)` 门控：服务就绪后新会话以**当前查看的工作区目录**为 cwd 启动——`newSession()`/`spawnWithCwd()` 调 `DSHSessionRPC.resolveProjectDirectory`（优先共享 `ProjectDirectory.current`=当前工作区，未设置时回退实时查询并缓存；不再用 running/最近更新启发式，build 60→61 修复 14），失败回退 `~`，`armSpawnFallbackTimer` 兜底；
- `exit` / `⌃D` → 正常结束自动关标签页（最后一个标签退出则收起面板）；异常退出（信号杀死）→ 保留「会话已结束 + 重启」态；
- `shutdownAll()`：App 退出时终止所有会话（main.swift `applicationWillTerminate` 调用）。

## 已知限制（README）

- v1 不支持输入法直接打字（中文等经 ⌘V 粘贴输入）；
- DECSTBM 滚动区未实现（个别全屏程序显示异常）；
- 组合表情/零宽连接符按近似宽度渲染；
- 会话不跨 App 重启保留。
