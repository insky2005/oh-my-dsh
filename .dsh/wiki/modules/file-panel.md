---
title: 模块：FilePanel.swift / CodeEditorView.swift（文件面板，预览+编辑+语法高亮）
tags: [module, file-panel, preview, code-editor, syntax-highlight, highlightr, edit, line-numbers]
updated: 2026-09-12T09:09:44Z
sources: [platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/vendor/Highlightr/Highlightr.swift, platforms/macos/src/vendor/Highlightr/CodeAttributedString.swift, platforms/macos/src/vendor/Highlightr/Theme.swift, platforms/macos/src/main.swift, platforms/macos/build-app.sh, docs/plans/PREVIEW_PLAN-file-panel.md, platforms/macos/src/WorkspaceTabMemory.swift, tests/file-panel/]
manual: false
---

# 模块：FilePanel.swift + CodeEditorView.swift（文件面板）

约 1246 + 388 行。**右栏「预览」面板的现行实现**（`FilePanelController`）：在 PreviewPanel 的目录树 + 多标签页 + 图片/PDF/元数据预览基础上，新增**无后缀/点文件按文本预览、文件内编辑 + 行号、语法高亮**。作为 PreviewPanel 的**强化分支**，PreviewPanel.swift 本身**零改动**保留，仅作回滚对照（见 [preview-panel](preview-panel.md)）。

## 与 PreviewPanel 的关系（可回滚优先）

- 复制 `PreviewPanel.swift` 的 `PreviewPanelController` 改名 `final class FilePanelController`，保留对外契约：`view`、`onRequestHide`、`serverPortProvider`、`open(path:)`、`ensureTreeLoaded()`、`setProjectDirectory(_:)`、`refreshTooltips()`，并新增 `saveActiveTab()`/`closeActiveTab()`/`hasOpenTabs`/`onTabsChanged`；
- **共享类型不重复声明**：`DynamicFillView`/`CustomIconButton`/`HeaderLabel`/`BakedIconView` 等仍来自 PreviewPanel.swift，FilePanel 只自带 file-private 的 `TreeNode`/`DirRow`（避免符号重定义）；
- `main.swift` 接线仅 2 行：`previewPanel` 属性类型与初始化改为 `FilePanelController`；活动栏预览按钮与 dsh 文件点击拦截经同一属性自动切到 FilePanel；
- 回滚 = 还原这 2 行 + 删除 `FilePanel.swift`/`CodeEditorView.swift`/`vendor/Highlightr` + 移除 build-app.sh 登记。

## 新增能力

1. **无后缀 / 点文件按文本预览**：`looksLikeText(_:)` 启发式——可 UTF-8 解码、无 NUL 字节、控制字符占比低（排除 \n/\r/\t，阈值 <8）即视为文本，与扩展名无关（`LICENSE`、`Makefile`、`.gitignore`、`.env`、`.npmrc` 均以文本显示）；
2. **文件内编辑 + 行号 + 保存**：文本/代码文件可在面板内编辑，左侧 `LineNumberGutterView` 行号栏（随滚动/行数刷新，宽随最大行号位数自适应），头部「保存」按钮 + **⌘S**，未保存标记（页签标题尾部 `*`），`Data.write(to:.atomic)` 原子写回；
3. **头部固定标题**：面板头部显示固定的面板名「文件 / Files」（复用活动栏键 `bar.preview`，语言切换经 `refreshTooltips()` 刷新），**不跟随当前文件的路径**；路径改放在**头部标题的悬停 tooltip**（活动页签的完整路径）与页签自身的 tooltip 里。
4. **语法高亮**：开源组件 **Highlightr**（MIT v2.3.0）vendored 进 `platforms/macos/src/vendor/Highlightr/`，底层 highlight.js 支持 180+ 语言；`CodeEditorView.language(forExtension:)` 映射扩展名 → highlight.js 语言名（swift/js/ts/py/go/rust/cpp/md 等），未知回退纯文本；主题明暗跟随（xcode 浅 / atom-one-dark 深）。

## 可编辑前置条件（防数据损坏）

- 仅当内容 **UTF-8 可解码** 且 `data.count <= textCap`（`2 * 1024 * 1024`，未截断）时才进入可编辑态——避免用截断缓冲区覆盖文件、避免编码往返损坏；
- 超限 / 非 UTF-8 / 二进制 → `showReadOnlyText` 只读 + `preview.tooLarge`/`preview.unreadable` 提示；二进制仍落元数据页；
- 保存 IO/权限失败：`NSAlert`（`preview.saveFailed`）+ `AppLog`，保留 dirty 状态与缓冲区不丢。

## 工作区页签记忆（切换 / 恢复 / 关闭回收）

页签集合**跟随工作区**（= 面板的目录树根）：切换工作区时旧工作区的页签被关闭并记忆，切回时按原顺序重开。此前页签跨工作区常驻——旧工作区文件挂在新工作区上，且后台继续持有编辑器 / 高亮 / 预览内容。

- **收口点 `setTreeRoot(_:thenOpen:)`**：面板唯一的换根入口（`setProjectDirectory` 工作区跟随 / 项目目录按钮 / 目录选择器）。根变为**不同目录**时转 `beginWorkspaceSwitch(from:to:thenOpen:)`；`treeRoot == nil` 的首次解析**不关任何页签**（点文件链接可能先于树根开出页签）。同路径重指不触碰页签；
- **`beginWorkspaceSwitch`**：**面板始终跟随工作区**（切换已在 dsh web 发生，没有「留在原工作区」这个答案，否则两边不一致）。无 dirty 页签直接交接；有则 `NSAlert` **二选一**——**保存并切换**（逐个 `CodeEditorView.writeBack()`；失败的经 `preview.saveFailed` 报错并**保留在页签栏**）/ **不保存**。**问不到人就不猜**：面板不可见（`view.window == nil`，含无头 QA）、ESC 等未识别响应 → 相关页签**留在页签栏**（不关、不记忆）并照常跟随。并发请求**最新优先**：`switchRequestGeneration` 让被 `supersedePendingSwitchPrompt` 结束的旧 sheet 回调自动失效；回调里还校验「根未被更新的请求改走」；
- **`performWorkspaceSwitch(…, keeping:)`**：把「要离开的页签」`tabMemory.remember(paths:selectedPath:for: 旧根)` → `closeTabs(它们)`（释放内容区，**不清记忆**）→ `applyTreeRoot(新根)` → `restoreTabs(for: 新根)` → 最后才执行 `thenOpen`（调用方"顺带打开这个目录"的页签必须在交接**之后**开，否则会被记到旧工作区）；`keeping` 里的页签（未保存改动无法落定）留在页签栏且不写入记忆，交接后若一个页签都不剩则 `resetContentArea()`，若选中项已关闭则改选剩下的最后一个；
- **`restoreTabs`**：按记录顺序重开（文件夹页签同样重开），磁盘上已消失的路径跳过并记日志；记忆的选中项若仍在则恢复选中，否则停在最后打开的那个；
- **记忆键**：目录树根路径经 `WorkspaceTabMemory.key(for:)`（`standardizingPath` + 去尾斜杠；不解析符号链接，与 `open(path:)` 的归一化一致）；
- **关闭按钮 = 彻底回收**：`closeAllTabs()` = `supersedePendingPrompt()` + `closeEveryTab()` + `tabMemory.forgetAll()`；切到其它面板（活动栏）**不算**关闭，页签保留；
- **关闭时的未保存提示**（`askAboutUnsaved` + `saveTabs`，页签 ✕ / ⌘W 与面板 ✕ 共用）：**保存并关闭 / 不保存 / 取消**——取消 = 什么都不关（这里「取消」是正当答案，因为关闭是面板内的用户动作，与工作区切换不同）；保存失败 → 中止关闭、保留缓冲并报 `preview.saveFailed`；**无窗口（无人可问）→ 一律不关**，绝不静默丢弃。关闭提示与切换提示共用 `pendingPromptAlert`：新的切换请求会让在途的关闭提示失效（该提示的回调按第三键处理 = 不关）；
- **不落盘**：记忆仅存在于进程内（`WorkspaceTabMemory` 为 struct，面板持有一个实例），**不**记录目录树展开状态与滚动位置（重开时按磁盘内容重新渲染）；
- **与回滚基线分叉**：PreviewPanel.swift 仍是「只重设树根、不动页签」，本节行为仅存在于 FilePanel；
- **测试**：`tests/file-panel/run.sh` —— `WorkspaceTabMemory` 模型 28 例 + 真实 `FilePanelController`（无窗口、无 dsh 服务）驱动 41 例（首次根不关页签 / 关旧开新 / 顺序与选中恢复 / 文件夹页签 / 文件消失跳过 / 同路径 no-op / 尾斜杠等价 / 关闭按钮清记忆 / 有未保存改动时仍跟随且页签保留 / 保存后正常交接 / 关页签与关面板遇未保存不静默丢弃 / 头部固定标题且路径进 tooltip），已接入 `scripts/local-ci.sh` 与 `ci.yml` swift job。

## CodeEditorView（代码编辑器视图）

- `CodeEditorView: NSView`：横向+纵向 `NSScrollView` 内含并排两个 `NSTextView`——左行号栏（只读、不可聚焦）+ 右代码区（`isEditable=true`、`isRichText=false`、等宽字体 `monospacedSystemFont(12)`）；
- 行号栏 `LineNumberGutterView`：直接由代码视图实时布局（`visibleRect` + `layoutManager` + `enumerateLineFragments`）推导可见行，数字总对齐、无第二滚动视图可失步；flipped y 原点匹配 NSTextView；Core Graphics 绘制（与面板头部同管线）；
- 代码区：`widthTracksTextView=false` + 大容器 → 长行不换行、横向滚动；启用 undo、查找栏；
- **Highlightr 初始化守卫**：`Highlightr()` 显式构造并判 nil（`CodeAttributedString()` 会 force-unwrap `Highlightr()`! 而崩溃）；`highlightingAvailable()` 校验 4 个资源文件（`highlight.min.js` + `pojoaque.min.css` + `xcode.min.css` + `atom-one-dark.min.css`）在 **Bundle.main 根**存在（Highlightr 用 `Bundle(for:)` + `path(forResource:)` 无子目录加载），缺失则退化为纯文本不崩溃；
- 明暗跟随：`viewDidChangeEffectiveAppearance` 切换 highlight.js 主题（触发重高亮）。

## 与壳层 / 构建的数据流

- 入口与 PreviewPanel 相同：main.swift 的 `previewInterceptorScript` 拦截 `/api/host.openPath` → `setRightPanel(.preview)` + `previewPanel.open(path:)`；
- **菜单**：新增「文件 File」菜单（`menu.file`/`menu.save` L10n 键）——`保存 Save`（⌘S → `saveActiveFile` → `previewPanel.saveActiveTab()`）与「关闭页签」（⌘W → `closeActiveFileTab`，无页签时禁用，⌘W 落到关窗）；`updateCloseTabMenuState()` 由 `onTabsChanged` 驱动；
- **L10n 新增键**：`preview.saveHint`（保存当前文件）、`preview.saveFailed`（保存失败：%@）、`menu.file`、`menu.save`；未保存提示另加 `preview.unsavedTitle`（标题，两处共用）、`preview.switchUnsavedMessage` / `preview.switchSave`（切换工作区；**没有**「取消切换」这一项——面板必须跟随）、`preview.closeUnsavedMessage` / `preview.closeSave` / `preview.discard`（关闭页签 / 关闭面板，第三键复用 `btn.cancel`）；
- `build-app.sh` `SWIFT_SOURCES` 追加：`FilePanel.swift`、`CodeEditorView.swift`、`vendor/Highlightr/{CodeAttributedString,Highlightr,Theme,HTMLUtils,Shims}.swift`；并把 4 个 highlight.js 资源文件 `cp` 到 `$APP/Contents/Resources/` **根**（Highlightr 按无子目录路径加载）；缺失给 WARNING 不影响构建；
- `local-ci.sh` 与 `ci.yml` 的 swiftc 编译检查清单同步追加上述新文件。

## 已知限制

- 2MB 上限内可编辑；`looksLikeText` 对「碰巧为合法 UTF-8 的二进制」存在极罕见误判（可接受，真二进制仍走元数据）；
- 保存为**覆盖式**写回（原子写）；磁盘文件被外部改动时直接覆盖（先记录 mtime、可选「文件已变更」增强暂未实现，设计见 PREVIEW_PLAN）；
- 大文件（>256KB）设计上禁用实时重高亮避免 JSContext 卡顿（编辑器内降级纯文本样式，保存后整段高亮）。
