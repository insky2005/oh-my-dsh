# 使用问题记录（UX 反馈）

> 用途：记录日常使用中发现的体验问题与改进点，逐条跟踪到实现与验收。
> 记录日期：2026-09-21 · 版本基线：当前 `main` 后的开发分支
> 状态图例：🔲 待处理 · 🔧 进行中 · ✅ 已完成 · 💬 待讨论

## 汇总

| # | 面板 | 问题 | 类型 | 优先级 | 状态 |
|---|---|---|---|---|---|
| 1 | Files | 目录树缺少「新建文件夹 / 新建文件」入口 | 功能缺失 | 中 | 🔲 |
| 2 | Files | 右上角「在面板中打开当前项目目录」应支持用外部应用打开 | 交互改进 | 中 | 🔲 |
| 3 | Terminal | 滚轮滚动方向与其他面板相反 | Bug | 高 | 🔲 |
| 4 | Terminal | 双击不能选词；拖选后需再按 ⌘C 才能复制 | 交互改进 | 中 | 🔲 |
| 5 | Terminal | 终端页签未按 workspace 隔离/记忆 | 交互改进 | 低 | 💬 |

---

## 1. Files 面板目录树：新建文件夹 / 新建文件

**现象**：目录树只能浏览，无法就地新建文件或文件夹，必须切到 Finder 或外部编辑器。

**期望**：
- 树节点右键菜单（以及空白区右键）提供「新建文件」「新建文件夹」；
- 新建项插入在被点节点内部（点文件则插入其同级目录），选中新节点并进入重命名编辑态；
- 同级重名给出提示或自动加序号；创建失败（无权限）给出可见反馈。

**相关代码**：
- `platforms/macos/src/FilePanel.swift` —— `treeOutline`（NSOutlineView，L67）、`TreeNode` / `loadChildren`、`setTreeRoot`（L592）；
- 目前该文件内没有任何 `NSMenu`/`menu(for:)` 实现（已 grep 确认），右键菜单需要从零加。

**待定**：是否同时做重命名 / 删除 / 拖拽移动（范围问题，实现前先确认）。

---

## 2. Files 面板右上角按钮：可选外部应用打开项目目录

**现象**：右上角按钮是固定行为「在面板中打开当前项目目录」，想用外部工具打开项目时只能另开 Finder / IDE。

**期望**：
- 点击展开下拉菜单，列出可选外部应用：Finder、VS Code / Cursor / Windsurf 等编辑器、JetBrains 系列、iTerm2 / Terminal.app 等终端；
- 未安装的应用不出现或置灰；记住上次选择作为默认动作（下次单击直接用它）。

**相关代码**：
- `platforms/macos/src/FilePanel.swift` —— `projectButton`（L165-170）、`openProjectDirectory`（L521）、`revealInFinder`（L425）；
- `platforms/macos/src/PreviewPanel.swift` —— 同名按钮（L549-554、L839），需一并考虑（面板基件约定）；
- 文案：`platforms/macos/src/main.swift` 的 `L10n.table`，已有 `preview.openProject` / `preview.openProjectHint`（L165-166），新增 key 必须中英成对。

**实现思路**：按已知 bundle id 用 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 探测安装情况；`NSWorkspace.open(_:withApplicationAt:configuration:)` 打开目录；选择持久化到 `ShellConfig`（如 `openProjectWithApp`）。

**验收**：Finder / 至少一个 IDE / 一个终端能正确打开当前项目目录；重启 App 后记忆生效。

---

## 3. Terminal 面板滚动方向与其他面板相反

**现象**：终端面板上下滚动方向和其他面板（dsh web / 文件树等）相反。

**相关代码**：`platforms/macos/src/TerminalPanel.swift` `scrollWheel(with:)`（L1125-1141）。

**疑点**：实现只读 `event.scrollingDeltaY` 并直接换算步长，未考虑 `isDirectionInvertedFromDevice`（自然滚动开关）与系统滚动语义；而其他面板走 NSScrollView 的标准行为，二者因此不一致。源码注释也留了「If QA finds the direction inverted, flip this sign」。

**验收**：触控板（自然滚动开/关）与鼠标滚轮两种设备下，终端滚动方向与文件树一致：内容朝向与手势方向一致（即手势「上滑看下文」）。

---

## 4. Terminal 面板：双击选词 + 选中自动复制

**现象**：双击无法快速选中单词；拖选文本后仍需 ⌘C 才能复制粘贴。

**期望**：
- 双击选中单词（路径/URL 类文本建议把 `/ - . _ :` 等视作词内字符），三击选中整行；
- 拖选结束（mouseUp）自动写入剪贴板，可直接 ⌘V 粘贴，无需 ⌘C；
- 自动复制提供开关（默认开），避免污染剪贴板、也兼容无选区时 ⌘C 发 SIGINT 的既有语义。

**相关代码**：
- `mouseDown/mouseDragged/mouseUp`（L1164-1191）：目前只做单点锚定 + 拖选，`mouseUp` 仅在原地点击时清空选区，未使用 `event.clickCount`；
- `copy(_:)`（L1200-1213）：有选区复制、无选区发 `\x03`（SIGINT）——自动复制不能破坏这个无选区语义。

**验收**：双击选词、三击选行；拖选后直接 ⌘V 得到刚选中的文本。

---

## 5. Terminal 面板页签按 workspace 隔离 / 记忆

**现象**：终端页签是全局的，切换 workspace（session）后各项目的终端混在同一排页签里。

**期望**：像 Files 面板一样按当前 workspace 过滤显示；切走时隐藏但不销毁会话（进程继续存活），切回后瞬间恢复原页签与滚动位置。

**相关代码**：
- 参照 `platforms/macos/src/FilePanel.swift` `setProjectDirectory(_:)`（L538）—— 收到 dsh 会话/workspace 变化回调时只重指目录树，已打开的预览页签保持不动；
- 终端侧 `TerminalPanel.swift` 目前没有对应钩子，需在 `TerminalPanelController` 增加 `setWorkspace(id:path:)` 之类入口，并在 shell 的 dshSession 处理器（`main.swift`）里调用。

**待定**：隐藏期间会话保活的数量上限与内存占用策略；是否需要「会话随 workspace 关闭而回收」开关。

---

## 备注

- 本文件仅记录问题清单，**未改代码、未开分支**；开始实现时按 `docs/git-workflow.md` 先切 `feature/*` 或 `fix/*` 分支。
- 每项完成后把状态改为 ✅，并在该条目下补一行实现位置（文件 + 函数）与验证结论。
