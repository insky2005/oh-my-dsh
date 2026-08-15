# 实现 oh-my-dsh 右侧活动栏「终端」面板

> 状态：✅ 已实现（v1.6.1 build 16）· 待手动 QA · 2026-08

## 目标与验收标准

把右侧活动栏的「终端」入口从占位（`terminalEntryTapped` 目前只打日志）实现为一个**真正可用的原生集成终端**：

- 点击活动栏终端图标 → 右侧面板打开，出现一个真实交互的 shell（默认 `$SHELL -l`，如 `/bin/zsh`），可在面板里执行命令、看到彩色输出、使用 vim/less 等全屏程序；
- 面板布局与预览面板一致（头部 + 可横向滚动的多标签页 + 内容区），支持多个终端会话标签页（+ 新建 / ✕ 关闭）；
- 预览面板与终端面板共用右侧同一个面板槽位：活动栏两个图标互斥切换（点已激活的图标收起面板），关窗 / `⌥⌘T` 菜单同理；
- 不修改任何 DeepSeek Harness 源码（仅改动壳层 Swift + 构建脚本）。

验收清单（手动 QA，见「测试与验收」）：命令可跑、方向键/历史、Ctrl 组合键、Cmd+C 复制或发 SIGINT、Cmd+V 粘贴、窗口缩放列数自适应（`tput cols`）、标签页增删、进程随关闭/退出被正确回收、中英文菜单文案齐全。

## 现状（已核实）

- `src/main.swift`：`terminalEntryTapped`（1660 行）是占位；活动栏按钮已建好（`terminalBarButton`，762 行）；`setPreviewVisible(_:)`（833 行）管理右侧面板显隐/宽度，`previewVisible` 布尔贯穿分割视图约束、`ensureWebViewWidth`、`splitViewDidResizeSubviews`、语言切换恢复等；L10n 表已有 `bar.terminal`（"终端"/"Terminal"）。
- `src/PreviewPanel.swift`：`PreviewPanelController`（右面板容器 + 头部 40pt + 标签栏 33pt + 内容区）、`HoverButton`、项目目录 RPC（`fetchActiveSessionCwd`，510 行）可复用。
- `build-app.sh` 第 191-196 行显式列出源文件编译，需新增 `TerminalPanel.swift`。
- 技术验证：本沙箱内 `fork()`/`posix_spawn` 可用，`forkpty` 可编译但运行被沙箱挡（`/dev/ptmx` 被拒）；App 本身无沙箱权限、ad-hoc 签名，正常运行不受限，故采用 `forkpty`（`Darwin` 的 `<util.h>`，Swift 可编译，只有 `fork()` 被 SDK 标 unavailable，forkpty 不受影响）。当前源码基线编译通过（仅既有 WebKit Sendable 警告）。

## 实现方案

### 1. 新增 `src/TerminalPanel.swift`（核心，约 900 行）

**`TerminalSession`（PTY 子进程管理）**
- `init?(shell:args:envp:cwd:rows:cols:)`：父进程先构造环境（继承 `ProcessInfo.processInfo.environment`，追加 `TERM=xterm-256color`、`COLORTERM=truecolor`）与 `winsize`，调 `forkpty(&master, nil, nil, &ws)`；子进程 `chdir(cwd)` 后 `execvpe`（带自定义 envp，避免 fork 后 setenv）；失败 `_exit(127)`。Shell 解析：`$SHELL` 可执行则用之，否则 `/bin/zsh`，参数 `["-l"]`（登录 shell，GUI 环境 PATH 很薄，登录 shell 才能拿到 brew 等工具链）。
- 读取线程：`DispatchQueue.global` 上 `select()` 轮询（200ms 超时 + 停止标志，避免跨线程关 fd 的竞态）；读到数据 → 维护 UTF-8 尾部残片（最多留 3 字节），`onOutput(String)` 回调派发到主队列；`read<=0`/EIO → 视为会话结束，`onExit(Int32)` 派发主队列。
- `write(_ data:)`：串行队列 + 循环处理部分写入；`resize(rows:cols:)` → `ioctl(TIOCSWINSZ)`；`terminate()`：`kill(-pid, SIGHUP)`（forkpty 使子进程为会话首领，进程组即 pid）→ `close(master)` → 后台 `waitpid` 回收防僵尸。

**`TerminalEmulator`（网格模型 + ANSI 解析子集）**
- 模型：`scrollback: [[Cell]]`（上限 10_000 行）+ `screen: [[Cell]]`（rows 行）+ 光标 `(row, col)` + 属性（fg/bg `NSColor?`、bold/italic/underline/inverse）+ 光标可见标志 + 备用屏 `saved*`（`?1049h/l`、`?47h/l` 时切换/恢复，vim/top/less 必需）。`Cell` 含字符与 `isContinuation` 标记（宽字符占两列）。
- 状态机：ground → ESC → CSI（参数/中间字节/终结字节）→ OSC（到 BEL 或 ST）。支持：CR/LF/BS/TAB/BEL（`NSSound.beep()`）/VT/FF；ESC 7/8（存/取光标）、ESC c（RIS 复位）；CSI A/B/C/D（光标）、H/f（CUP）、G（CHA）、d（VPA）、E/F、J/K（擦除 0/1/2/3）、m（SGR：0/1/3/4/7/22/23/24/27、30-37/40-47/90-97/100-107、38;5;n/48;5;n、38;2;r;g;b/48;2;r;g;b）、h/l（SM/RM：`?25` 光标显隐、`?47`/`?1049` 备用屏，其余忽略）、s/u（存/取光标）、X（ECH）、P（DCH）、@（ICH）、L（IL）、M（DL）、S/T（SU/SD）；OSC 0/2 → `onTitle(String)`（更新标签页标题）。
- 已知限制（文档化）：DECSTBM 滚动区（r）解析但忽略；组合表情/零宽连接符按近似宽度处理。
- 调色板：固定 xterm 16 色 + 256 色（16-231 立方体 + 232-255 灰阶计算生成）+ 真彩色直接映射为 `NSColor`；默认前景/背景用动态 `textColor`/`textBackgroundColor`（跟随深浅色）。
- 宽字符宽度启发式（常见 CJK/emoji 区间 → 2），行尾自动换行，擦除/回退时连占位列一起处理。
- 提供渲染/选择接口：`line(at:)`、`totalLineCount`/`visibleLineCount`、`scrollOffset`/`maxScrollOffset`、`scroll(by:)`、光标位置、`selection`（绝对缓冲区坐标起止）、`selectAll()`、`clearScreen()`。

**`TerminalView`（自定义 NSView：渲染 + 输入）**
- 字体 `.monospacedSystemFont(ofSize: 13)`；`cellWidth = "M" 宽度`、`lineHeight = NSLayoutManager.defaultLineHeight(for:)`；`setFrameSize` 重算 rows/cols，变化时 `emulator.resize` + `session.resize`。
- 渲染 `draw(_:)`：`textBackgroundColor` 铺底；逐行构建 NSAttributedString（按 Cell 属性分段，bold/italic 用 `NSFontManager` 转字形，颜色/下划线照抄）绘制；选中单元格底色覆盖；光标画 accent 色块（隐藏时跳过）。滚动条由 `scrollWheel` 驱动 `scrollOffset`（滚到 0 = 跟随输出）。
- 输入：`acceptsFirstResponder = true`；`keyDown`：Ctrl+字母→0x01-0x1A；Option+键→ESC+字符；回车 `\r`、Tab `\t`、退格 `\x7f`、方向键 `\x1b[A/B/C/D`、Home/End `\x1b[H/F`、PgUp/PgDn `\x1b[5~/6~`、Delete `\x1b[3~`、F1-F12 基础映射；可打印字符 UTF-8 编码写入。Cmd 组合走响应链（见下），Cmd+K 在 keyDown 里清屏。
- 剪贴板（关键：Edit 菜单的 `copy:`/`paste:`/`selectAll:` 走 first responder 响应链，TerminalView 实现这三个 selector 即可被 Cmd+C/V/A 命中，WKWebView 行为不受影响）：`copy(_:)` 有选区→复制（逐行去行尾空白），无选区→写 `\x03`（SIGINT）；`paste(_:)` 读剪贴板，含换行时用括号粘贴 `\x1b[200~…\x1b[201~` 且 `\n→\r`，否则原样；`selectAll(_:)` 全选。
- 鼠标：mouseDown/Dragged/Up 拖拽选格；`isOpaque = true`。

**`TerminalPanelController`（面板容器，镜像 PreviewPanelController）**
- 结构：头部 40pt（左侧会话标题标签，右侧「+ 新建」「✕ 关闭面板」HoverButton）+ 标签栏 33pt + 分隔线 + 内容区；`static let minWidth: CGFloat = 300`。
- 标签页：`[TerminalTab]`（id/session/view/titleButton/closeButton/container），切换标签显示对应 `TerminalView` 并 `window?.makeFirstResponder`；关闭标签 → `session.terminate()` 并移除；全部关闭 → 空态（图标 + 「点击 + 新建终端」+ 按钮）。
- 首次打开面板时自动建第一个会话（懒启动，不拖慢 App 启动）；标题默认「终端」/「Terminal」，OSC 标题回调更新标签名。
- `shutdownAll()`：退出时终止全部会话。
- 会话工作目录：`newSession()` 在后台队列先经共享 `DSHSessionRPC.resolveProjectDirectory`（1.2s 预算）解析项目目录，失败/超时回退 `NSHomeDirectory()`，再 forkpty；完成后回主队列建标签页（典型耗时 <300ms）。

### 2. 修改 `src/main.swift`

- 新增共享枚举 **`DSHSessionRPC`**（`fetchActiveSessionCwd(port:)` + `resolveProjectDirectory(port:completion:)`，从 PreviewPanel 抽出），供两个面板共用。
- AppDelegate 重构右侧面板状态：`previewVisible: Bool` → **`rightPanel: RightPanel`**（`enum RightPanel { case none, preview, terminal }`）。
  - `setPreviewVisible(_:)` 主体改为 `setRightPanel(_ panel: RightPanel)`（保留原有宽度/`widenWindow`/异步重试守卫逻辑，`previewVisible` 判定处改 `rightPanel != .none`；显示 `.preview` 时仍调 `ensureTreeLoaded()`）。
  - 调用点更新：`togglePreviewPanel` → 在 `.preview`/`.none` 间切换；`terminalEntryTapped` → 在 `.terminal`/`.none` 间切换；两个面板的 `onRequestHide` → `.none`；`userContentController`（点文件链接）→ `.preview`；`setLanguage` 重建 WebView 后按 `rightPanel` 恢复；`splitViewDidResizeSubviews`/`ensureWebViewWidth`/`constrainMin/Max` 用 `rightPanel != .none`。
  - 分割视图右窗格改成一个容器 `rightPane`（只加一次），预览/终端两个面板视图用边距约束固定、按 `rightPanel` 互斥 `isHidden` 切换，宽拖拽记忆沿用 `previewPanelWidth` 键。
  - 活动栏两按钮的 state/tint 按激活面板设置；分隔条最小宽度取 `max(PreviewPanelController.minWidth, TerminalPanelController.minWidth)`。
  - 持久化：显隐沿用 `previewPanelState`，新增 `rightPanelKind`（"preview"/"terminal"，默认 preview）启动恢复。
  - `applicationWillTerminate` 追加 `terminalPanel.shutdownAll()`。
  - `buildWindow` 增加 QA 钩子：`DSH_TERMINAL_TEST=1` 启动即开终端面板（对应已有 `DSH_PREVIEW_TEST_PATH`）。
- L10n 表新增键（中/英）：`menu.toggleTerminal`（"显示/隐藏 终端面板"/"Toggle Terminal Panel"）、`terminal.new`/`terminal.newHint`、`terminal.closeTab`、`terminal.empty`、`terminal.sessionEnded`、`terminal.restart`、`terminal.title`；菜单「视图」追加「显示/隐藏 终端面板」`⌥⌘T`（选中态跟随）。`showAbout` 的版本回退串同步新版本号。

### 3. 修改 `src/PreviewPanel.swift`（行为不变的小重构）

- 删除私有 `resolveProjectDirectory`/`fetchActiveSessionCwd`（498-548 行），改为调用共享 `DSHSessionRPC`；`openProjectDirectory`/`ensureTreeLoaded` 两处调用点同步更新。

### 4. 修改 `build-app.sh` 与 `README.md`

- 编译命令（196 行）追加 `"$SRC/TerminalPanel.swift"`；版本号 `VERSION=1.6.1`、`BUILD=16`（`dist/` 已有 1.6.0，About 面板需可区分）。
- README 增补「终端面板」一节：功能、快捷键（Cmd+C/V/A、Cmd+K）、限制（v1 不支持输入法直接打字——中文可 Cmd+V 粘贴；DECSTBM 滚动区不支持；会话不跨重启保留）。

## 边界情况与失败处理

- shell 不存在/exec 失败 → `onExit(127)` → 标签页显示「会话已结束」+「重启」按钮（重启 = 关闭旧会话建新会话）。
- 面板隐藏但会话存活（与 Terminal.app 一致）；关标签页/退出 App 才终止进程；`waitpid` 回收防僵尸。
- 窗口缩放 → TIOCSWINSZ + SIGWINCH，shell 自动重排；列/行数钳制（cols≤500、rows≤200）防病态输出；滚动缓冲上限 10_000 行。
- UTF-8 跨读取分片 → 尾部残片缓冲拼接；宽字符行尾换行、擦除连占位列。
- 输出洪峰：读线程批量累积后按主队列派发（每批一次重绘，不逐字符刷）。
- 杀掉会话进程组（`kill(-pid, SIGHUP)`）而非仅 kill 单个 pid，覆盖前台进程组。

## 测试与验收

- **编译验证**（本环境可做）：`swiftc -O -swift-version 5 -module-cache-path .build/module-cache -framework AppKit -framework WebKit -framework PDFKit -o /tmp/t src/main.swift src/PreviewPanel.swift src/TerminalPanel.swift` 零错误（PTY 运行态无法在本沙箱验证——`/dev/ptmx` 被拒，但 App 正常运行不受限）。
- **构建**：`./build-app.sh` 产出 `dist/oh-my-dsh.app`（1.6.1）。
- **手动 QA 清单**（用户运行 App 验收）：① 点终端图标开面板出现 zsh 提示符；② `ls`/`echo`/`cd`/`git status` 彩色输出；③ `vim`/`less`/`top` 备用屏正常、退出恢复；④ 拖拽窗口边缘 `tput cols` 变化；⑤ `+`/`✕` 增删标签页，`ps` 确认进程被杀；⑥ 方向键历史、Ctrl+C、Cmd+C（有选区复制/无选区 SIGINT）、Cmd+V（多行粘贴不自动执行）；⑦ 活动栏预览/终端互斥切换、`⌥⌘T`、面板宽拖拽记忆、重启后恢复上次面板；⑧ 中文文件名 `ls` 渲染正常、中文经 Cmd+V 粘贴可输入；⑨ 退出 App 无残留 zsh 进程；⑩ `DSH_TERMINAL_TEST=1` 启动直开终端面板。

## 明确假设

- 终端与预览共用右侧面板槽位（互斥），依据 README「点击切换预览面板，后续可扩展终端等入口」的既定设计。
- 会话不跨 App 重启保留；关闭面板不杀会话。
- 默认登录 shell（`$SHELL -l`，回退 `/bin/zsh`），`TERM=xterm-256color`，会话起始目录优先项目目录（RPC 1.2s 超时）否则用户主目录。
- App 以无沙箱 ad-hoc 签名运行，`/dev/ptmx` 可访问（本开发沙箱的 EPERM 仅为环境限制，不影响产物）。
- v1 不含输入法（IME）直接打字，中文输入通过 Cmd+V 粘贴；滚动区（DECSTBM）与组合表情宽度为已知限制，列入 README。

---

## 实施记录（2026-08）

**已完成的改动**
- 新增 `src/TerminalPanel.swift`（约 1500 行）：`TerminalSession`（forkpty + poll 读取循环 + UTF-8 残片拼接 + TIOCSWINSZ + 进程组 SIGHUP 清理）、`TerminalEmulator`（滚动缓冲 + 屏幕网格 + ANSI 子集：光标/擦除/插入删除/SGR 16·256·真彩色/备用屏 ?47·?1049/OSC 标题/宽字符两列/备用屏）、`TerminalView`（逐行 run 渲染、光标、鼠标拖选、scrollWheel 回看历史、键盘映射、copy/paste/selectAll 响应链、括号粘贴、Cmd+K 清屏）、`TerminalPanelController`（头部 + 标签栏 + 多会话标签页 + 空态/会话结束态 + 重启）。
- `src/main.swift`：新增共享 `DSHSessionRPC`（session.list → 项目目录）；`previewVisible` 重构为 `rightPanel: RightPanel {none, preview, terminal}` 与 `setRightPanel(_:)`（沿用宽度/加宽窗口/异步重试守卫）；活动栏两按钮互斥；`⌥⌘T` 菜单；`previewPanelState` + 新增 `rightPanelKind` 持久化；退出时 `shutdownAll()`；`DSH_TERMINAL_TEST=1` QA 钩子；L10n 新增 terminal.* 键。
- `src/PreviewPanel.swift`：`resolveProjectDirectory`/`fetchActiveSessionCwd` 改用共享 `DSHSessionRPC`（行为不变）。
- `build-app.sh`：编译加入 `TerminalPanel.swift`；版本 1.6.0→1.6.1、build 15→16。
- `README.md`：新增「集成终端面板」特性说明与已知限制；产物版本号更新。

**关键修复（自测发现）**
- Unicode 字形簇规则把 `\r\n` 合并为一个 Character，导致 CR/LF 落入 putChar —— `feed` 改为按 unicode scalar 逐码点处理（终端本就是码点模型）。
- `FD_ZERO`/`FD_SET`/`WIFEXITED` 等 C 宏在 Swift 不可用 —— 改用 `poll(2)` 与手写 wait 状态解码。
- `deleteChars` 尾列残留 —— 重写为标准 DCH 平移。

**测试结果**
- 三个源文件 `swiftc -O` 全量编译零错误（仅既有 WebKit Sendable 警告）。
- 终端模拟器 46 项无头单元/集成测试全部通过（文本/CRLF/退格/制表/SGR 16·256·真彩色/光标寻址/擦除/插删/宽字符/自动换行/滚动缓冲/全选复制/备用屏往返/RIS/DCS/OSC 标题/缩放保持/clear 清滚动区/模拟会话与 vim 场景）。
- 待手动 QA（PTY 运行态受本开发沙箱限制无法自动化）：见下方清单。

**1.6.2 / 1.6.3 修复记录**
- 1.6.2：收起面板再展开后终端内容只剩 2 列碎片 —— 面板收起时右窗格被压到 0 宽，`updateGridSize` 把模拟器与 PTY 缩到 2 列，shell 按 2 列重排且残留在滚动缓冲。修复：视图不可见（`isHiddenOrHasHiddenAncestor`）或宽 <48pt/高 <32pt 时不下发尺寸变更，展开后按真实尺寸重新排版。
- 1.6.3：App 首次启动（服务现拉起）时终端会话启动目录落到 ~ —— `buildWindow` 先于 `startServer` 执行，目录 RPC 在服务就绪前查询必然失败。修复：TerminalPanelController 增加服务就绪门控（`serverReady(port:)` 由 AppDelegate 在服务就绪后回调，挂起的生成排入 `deferredSpawns` 并在就绪后补齐，另有 10s 兜底定时器保证服务起不来时终端仍可用）。

**1.6.4 / 1.6.5 修复与增强记录**
- 1.6.4：所有面板顶部统一 —— 新增共享 `DynamicFillView`（动态背景色，随明暗重解析），预览/终端面板头部改为显式 `windowBackgroundColor` 背景条（40pt 布局一致），头部图标按钮统一改用 `.secondaryLabelColor`（与活动栏一致、深浅色均可见）并显式 `isTemplate`；活动栏背景由固定 `cgColor` 改为动态填充；`setRightPanel` 显示面板时强制 `needsDisplay`（防隐藏/显示后图层残留）。附带在离屏渲染下验证了按钮在深色模式为白色可见（截图分析确认用户侧为头部按钮深色不可见）。
- 1.6.5：多标签页增强 —— 标签默认编号「终端 1/2/3…」（OSC 标题仍可覆盖），`⌘1-9` 直接切标签、`⌘⇧[`/`⌘⇧]` 循环切换；`exit`/`⌃D` 正常退出后自动关闭该标签页（最后一个标签页退出则收起面板），异常退出（信号/exec 失败 127）保留「会话已结束 + 重启」态。

**最终修复：终端顶部被遮住（根因与解决）—— 详见 `docs/terminal-header-fix.md`**

- 根因：layer-backed 窗口中，`TerminalView` 的 `isOpaque = true` 且无独立 backing layer，其背景绘制被合成进父（contentContainer 无 layer）进而溢出到面板根 layer，盖住了同级的 header。
- 修复：`contentContainer.wantsLayer = true` + `layer?.masksToBounds = true` 隔离绘制区域；`TerminalView.wantsLayer = true` 辅助；面板根改为 `TerminalRootView`（`isOpaque = false`，绘制灰色背景）。预览面板本就正常（内容区用 NSSplitView，自带 layer 隔离）。
- 经验：opaque 视图 + 无独立 layer = 合成陷阱；隔离子视图绘制用父容器的 `wantsLayer`，而非子视图自身。
- 验证通过后已打包 **1.6.23**：`dist/oh-my-dsh-1.6.23-arm64.pkg` / `.dmg`（DMG 校验 VALID）。

**1.6.28 最终修复：粘贴混乱 + 方向键失效（根因在写入 API）**

- 根因：`TerminalSession.write` 用 `Darwin.write(fd, &bytes[off], count)` 写 Swift `[UInt8]`——该写法写出的是**数组对象头部**而非元素字节（pipe 往返十六进制验证：`hello world` 只写出首字节 `68`，其余为 `04 00 00 00…`）。多字节输入（方向键 `\x1bOA`、粘贴文本）首字节 `\x1b` 之后的字节全是垃圾 → zsh 蜂鸣/`<ffffffff>`；单字符打字（1 字节写）恰好正常，掩盖了此 bug。
- 修复：改用 `data.withUnsafeBytes { … Darwin.write(fd, base.advanced(by: off), …) }`，逐字节正确。
- 辅助：emulator 跟踪 DECCKM（`?1h` → 方向键 `\x1bOA`）与括号粘贴（`?2004h` → 粘贴加 `\x1b[200~…\x1b[201~`）；PTY 强制 `LANG/LC_ALL=en_US.UTF-8`。
- 验证通过后已打包 **1.6.28**：`dist/oh-my-dsh-1.6.28-arm64.pkg` / `.dmg`（DMG 校验 VALID）。

**详细总结文档：`docs/terminal-input-fix.md`** —— 终端粘贴混乱 & 方向键失效的完整排查过程、Pipe 往返十六进制证据、三层修复思路（写入 API 修正 + 模式跟踪 + UTF-8 locale）与经验教训。
