---
title: 模块：FilePanel.swift / CodeEditorView.swift（文件面板，预览+编辑+语法高亮）
tags: [module, file-panel, preview, code-editor, syntax-highlight, highlightr, edit, line-numbers, tree-menu, image-zoom, composer-reference]
updated: 2026-09-22T09:16:43Z
sources: [platforms/macos/src/FilePanel.swift, platforms/macos/src/FilePanelTreeMenu.swift, platforms/macos/src/ComposerReference.swift, docs/file-panel-composer-reference.md, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/EditorLoadPolicy.swift, platforms/macos/src/ImagePreviewView.swift, platforms/macos/src/ImageZoom.swift, platforms/macos/src/OpenWithApps.swift, platforms/macos/src/PreviewPanel.swift, platforms/macos/src/main.swift, platforms/macos/src/vendor/Highlightr/Highlightr.swift, platforms/macos/src/vendor/Highlightr/CodeAttributedString.swift, platforms/macos/src/vendor/Highlightr/Theme.swift, platforms/macos/build-app.sh, docs/ux-feedback.md, docs/plans/PREVIEW_PLAN-file-panel.md, platforms/macos/src/WorkspaceTabMemory.swift, platforms/macos/src/PanelSurface.swift, docs/ui-color-scheme.md, tests/file-panel/]
manual: false
---

# 模块：FilePanel.swift + CodeEditorView.swift（文件面板）

约 2358 + 500 行（2026-09-21 实测）。**右栏「预览」面板的现行实现**（`FilePanelController`）：在 PreviewPanel 的目录树 + 多标签页 + 图片/PDF/元数据预览基础上，新增**无后缀/点文件按文本预览、文件内编辑 + 行号、语法高亮、目录树右键菜单（新建/重命名/删除/在 Finder 中显示）、头部菜单按钮（打开项目 ▾ / 打开文件 ▾）、图片预览自适应 + 缩放、目录树宽度跨关闭恢复**。作为 PreviewPanel 的**强化分支**；PreviewPanel.swift 的**控制逻辑**零改动保留，仅作回滚对照（见 [preview-panel](preview-panel.md)），但其共享基件随全局配色统一与新控件一起演进（新增 `PanelMenuButton`）。

## 与 PreviewPanel 的关系（可回滚优先）

- 复制 `PreviewPanel.swift` 的 `PreviewPanelController` 改名 `final class FilePanelController`，保留对外契约：`view`、`onRequestHide`、`serverPortProvider`、`open(path:)`、`ensureTreeLoaded()`、`setProjectDirectory(_:)`、`refreshTooltips()`，并新增 `saveActiveTab()`/`closeActiveTab()`/`hasOpenTabs`/`onTabsChanged`；
- **共享类型不重复声明**：`DynamicFillView`/`CustomIconButton`/`HeaderLabel`/`BakedIconView`/`PanelMenuButton` 等仍来自 PreviewPanel.swift（`DynamicFillView` 已去掉 `final`，供 `FilePanelRootView` 继承），FilePanel 只自带 file-private 的 `TreeNode`/`DirRow`（避免符号重定义）；
- `main.swift` 接线仅 2 行：`previewPanel` 属性类型与初始化改为 `FilePanelController`；活动栏预览按钮与 dsh 文件点击拦截经同一属性自动切到 FilePanel；
- 回滚 = 还原这 2 行 + 删除 `FilePanel.swift`/`CodeEditorView.swift`/`ImagePreviewView.swift`/`vendor/Highlightr` 等新增文件（新文件无需登记编译清单，见 [conventions](../conventions.md)）。

## 新增能力

1. **无后缀 / 点文件按文本预览**：`looksLikeText(_:)` 启发式——可 UTF-8 解码、无 NUL 字节、控制字符占比低（排除 \n/\r/\t，阈值 <8）即视为文本，与扩展名无关（`LICENSE`、`Makefile`、`.gitignore`、`.env`、`.npmrc` 均以文本显示）；
2. **文件内编辑 + 行号 + 保存**：文本/代码文件可在面板内编辑，左侧 `LineNumberGutterView` 行号栏（随滚动/行数刷新，宽随最大行号位数自适应），头部「保存」按钮 + **⌘S**，未保存标记（页签标题尾部 `*`），`Data.write(to:.atomic)` 原子写回；
3. **头部固定标题**：「文件 / Files」（复用活动栏键 `bar.preview`，语言切换经 `refreshTooltips()` 刷新），**不跟随当前文件路径**；路径放进页签 tooltip；
4. **面板配色**：页签标题走 `PanelTabButton`（`PanelControl` 两档），目录树 `NSOutlineView`、目录列表 `NSTableView` 与文本 / 图片 / PDF 预览的 `NSScrollView` 显式设 `backgroundColor = PanelSurface.dynamic`，见 `docs/ui-color-scheme.md`；
5. **语法高亮**：vendored **Highlightr**（MIT v2.3.0）+ highlight.js（180+ 语言）；`CodeEditorView.language(forExtension:)` 映射扩展名，未知回退纯文本；主题明暗跟随（xcode 浅 / atom-one-dark 深）。

## 头部菜单按钮（docs/ux-feedback.md #2 两轮返工后）

- 头部两个按钮改为共享控件 **`PanelMenuButton`**（PreviewPanel.swift，Core Graphics 自绘「图标 + 文字 + ▾」，hover/菜单打开期间高亮，窄面板自动退化为「图标 + ▾」chip）：**「打开项目 ▾」**（`files.openProjectButton`）与 **「打开文件 ▾」**（`files.fileMenuButton`）；
- **点击整颗按钮就是打开菜单**（不做「主区=上次选择 / chevron=菜单」的分裂按钮）；**⌥ 点击**才走 `onAction` 快捷动作（打开项目＝上次记住的方式 / 默认应用；打开文件＝默认应用打开）；菜单统一从按钮**下方**弹出（`popBelow(_:_:)`）；
- **打开项目菜单**：面板内打开 / Finder / 已安装的编辑器与 IDE（13 个）/ 已安装的终端（8 个）/「选择其它应用…」（文件选择器）。目录与安装探测的**纯模型**是 `OpenWithApps.swift` 的 `OpenWithCatalog`（按 bundle id 探测；非目录内应用按 `path:<app 路径>` 记忆）；记忆写入 `ShellConfig` 的 **`files.openProjectWith`**（`FilePanelController.openWithKey`），上次选择在菜单里打勾；
- **打开文件菜单**：默认应用打开 / 在 Finder 中显示 / 复制路径；仅在**选中了文件页签**时可用（`updateHeader(for:)` 用 `isDirectory(path)` 判定、`showEmptyState()` 兜底置灰，否则日志 `preview file menu: no file tab is selected`）——修掉此前「看着可用、点了没反应」的状态。

## 目录树右键菜单（新建 / 重命名 / 删除 / 在 Finder 中显示，#1）

判定的**纯模型**是 `FilePanelTreeMenu.swift`：`TreeMenuModel.entries(hasRoot:hasRow:isRoot:isFile:canReference:)` 返回 `[TreeMenuEntry(item:separatorBefore:enabled:)]`，菜单分四组：

| 组 | 条目 | 条件 |
|---|---|---|
| 加入对话 | 添加到对话 | 需 `hasRow` 且**能算出 `@` 引用**（`canReference`：非根、路径在工作区内、无引号/控制字符）且壳层已接线；**项目根**上置灰 |
| 新建 | 新建文件夹 → 新建文件 | 仅点**文件夹**（含空白处右键）时出现；点在**文件**上不显示 |
| 条目操作 | 重命名 → 删除 | 需 `hasRow`；**项目根目录**上置灰（不可改名/删除） |
| 定位 | 在 Finder 中显示 | 单独成组（不改动该条目） |

- 实现：`treeOutline.menu` + `clickedRow` 定位目标目录（`clickedTreeItem()`）、`NSMenuDelegate.menuNeedsUpdate` 动态构建；**新建** `promptForNewItem(isDir:)` → `createTreeItem(named:isDir:in:)`（重名 / 非法名 / 失败都有可见反馈，成功后展开并选中新节点，文件自动开页签）；**重命名** `renameTreePath(_:to:)` → `moveTreeEntry(at:to:)`（输入框预填原名整段选中），成功后 `repointTabs(from:to:)` 把已打开页签（含被改名文件夹下的所有文件）指向新路径，未保存的编辑继续有效；**删除** `trashTreeEntry(at:)` 移到废纸篓（不做不可恢复 unlink），被删条目下的页签 `closeTabs(under:)` 自动关闭；系统回收站不可写则拒绝删除并保留文件与页签；
- 文案键：`files.addToConversation` / `files.addToConversationNoSession` / `files.addToConversationFailed` / `files.newFile` / `files.newFolder` / `files.newItemLocation` / `files.newFilePlaceholder` / `files.newFolderPlaceholder` / `files.create` / `files.invalidName` / `files.alreadyExists` / `files.createFailed` / `files.revealInTree` / `files.rename(Action)` / `files.renameFailed` / `files.delete(Action)` / `files.deleteFileMessage` / `files.deleteFolderMessage` / `files.deleteFailed`（中英成对，见 [conventions](../conventions.md)）；
- **待定**：拖拽移动未做。

## 目录树右键「添加到对话」→ dsh web 输入框的 `@` 引用（B9）

右键文件/文件夹 → **添加到对话** → dsh web 输入框末尾出现该条目的**引用 chip**（与用户敲 `@` 从候选中选出来的是**同一种节点**），光标留在输入框末尾可直接续写。

- **语法/相对路径是纯模型** `ComposerReference.swift`（`ComposerReferenceFormatter.mention(path:root:isDirectory:)`）：引用相对**工作区根**（dsh 在会话 cwd 下解析 `@`），文件 `@src/foo.ts`、目录 **`@src/`（尾斜杠 = 目录）**、含空格走引号（目录是**不闭合**的 `@"my dir/`，dsh 的补全靠它继续下钻）；工作区根自己、工作区之外、名字含 `"`/控制字符 → **无引用**（菜单置灰，不编坏 token）；
- **面板只决定「加哪一个」**：`onAddToConversation: ((ComposerReference) -> Void)?`（无监听方即置灰），壳层 `insertComposerReference()` 负责页面；
- **壳层把 chip 节点直接写进 dsh web 的 Lexical 编辑器**（`composerReferenceScript` → `window.__dshInsertFileReference(mention,label,appearance)`）：取 `[data-composer-input].__lexicalEditor` → `editor._nodes.get('reference-chip').klass`（chip 类模块私有，只能从这里拿）→ 在 `editor.update()` 里 `root.selectEnd().insertNodes([可选空格, chip, 空格])`；**不伪造按键、不依赖焦点**。提交时由 source codec 序列化成 `ref` = `@path`，即模型读到的文本；
- **失败都不静默**：桥接函数回 `{ok,reason}`（`bridge-unavailable` / `no-composer` / `no-editor`（启动页无会话）/ `unknown-composer` / `throw:…`），壳层弹非阻塞提示 + `app.log`；`DSH_UI_DEBUG=1` 的注入桥健康检查新增 `composer` / `composerEditor` 两个字段；
- **QA 钩子**：`DSH_COMPOSER_TEST_PATH`（要引用的条目，绝对路径或相对项目目录）+ `DSH_COMPOSER_TEST_SESSION`（先打开的会话，因为新页面停在启动页没有 editor）——走的是**与右键同一条**格式化 + 注入路径，结果进 `app.log`；
- **dsh 耦合**：输入框槽位标记、Lexical 实例挂载点、节点登记表、`reference-chip` 类型名与字段全部是 dsh 私有细节 —— 升级核对项见 `docs/dsh-version-impact.md` **B9** 与 `docs/file-panel-composer-reference.md`（含 WKWebView 实测记录）。

## 图片预览（自适应 + 手动缩放，#8）

- 视图 `ImagePreviewView.swift`：`NSScrollView`（内容视图换成 `CenteringClipView`，`constrainBoundsRect` 里把小于视口的文档**居中**）+ 文档视图「图片 + `ImageZoom.padding`(16pt) 内边距」+ 右下角浮动百分比角标；打开时/面板尺寸变化时按比例**适应窗口**（不放大超过 100%，小图标不糊）；
- 缩放操作：**⌘+ / ⌘− / ⌘0**、**⌘+滚轮**、触控板**捏合**、**双击**（适应窗口 ↔ 100%）、放大后拖拽平移；范围 5%–1600%（`ImageZoom.minMagnification`/`maxMagnification`），单步 ×1.25（`stepRatio`）；用户手动缩放后不再自动重新适应，直到 ⌘0 / 双击 / 重新打开；
- **数学抽成纯模型** `ImageZoom.swift`（`fitMagnification(imageSize:viewport:padding:)` / `clamped(_:)` / `stepped(_:direction:)`），视图只管 AppKit；
- **三个坑（均已修）**：① fit 必须用 clip view 的 **frame**（屏幕点）而不是 `contentView.bounds`——开启动量缩放后 bounds 是文档坐标（frame ÷ magnification），用 bounds 会「设置 magnification → 视口变化 → 重新 fit」振荡；② 视口退化（live resize 中间帧）时**跳过**而不是回落 100%；③ 角标必须**固定尺寸**（`ZoomBadgeView.size` = 54×18）且 KVO 回调推迟到下一个 runloop——否则在一次布局过程中改尺寸会崩在 `invalidateIntrinsicContentSize`；
- 悬停提示 `preview.imageZoomHint`（中英成对）。

## 大文件重载不再卡死（#7）：分块高亮 + 稳定性窗口

纯策略放在 `EditorLoadPolicy.swift`（可单测）：

- **写文件稳定性窗口 0.6s**（`reloadStabilityWindow` / `isStable(mtime:now:window:)`）：`refreshOpenTabsIfChanged()` 对「还在被写」的文件先不重载且**不吃掉**这次变化——agent 连续写文件只会在写完后重载**一次**；
- **分块着色**：`highlightChunkLines` 300 行 / `highlightChunkBytes` 32 KB，切分是纯函数 `highlightChunk(in:from:maxLines:maxBytes:)`（整行切分、不切行；超长单行独占一片），`CodeEditorView.highlightInChunks()` 每片之间 `DispatchQueue.main.async` 让出主线程 → 大文件自上而下渐进上色；切换深浅色主题的重着色同样走这条路；
- **正常源文件一律保留语法高亮**（不再「超过 N 行就关高亮」）；安全阀只留给极端文件：> 4 万行（`maxHighlightedLines`）或 > 4 MB（`maxHighlightedBytes`）；
- **一次重载只有一次高亮**：`reloadFromDisk()` 用 vendored Highlightr 的**本地新增** `CodeAttributedString.setLanguage(_:automaticallyHighlighting:)` 抑制「替换文本触发的段落高亮 + `language` didSet 的全文高亮」两条自动路径，再 `beginEditing/endEditing` 一次性替换文本；
- **读取在后台线程**：主线程不再 `Data(contentsOf:)`；用 generation 计数保证「最后一次请求胜出」，慢读不会把旧内容塞回编辑器。

## 目录树宽度跨关闭保持（#9）

现象：关闭面板再打开后目录树宽度变成上限 420pt 而非用户拖出来的值。根因与修法（三版迭代，最终版）：

- **事件监视器拿不到分隔条拖拽**——`NSSplitView` 拖拽分隔条跑的是它**自己的 event-tracking loop**，`NSEvent.addLocalMonitorForEvents` 从不触发（前两版据此写的记忆逻辑一次都没执行过）。最终做法：`TreeDividerSplitView: NSSplitView` 子类 override `mouseDown(with:)`（`super.mouseDown` 返回即「拖拽结束」），拖拽中实时记录、结束时落定并打日志 `preview tree width remembered: Npt`；
- **非拖拽导致的宽度变化一律纠正回来**：`splitViewDidResizeSubviews` → `restoreTreeWidthIfDisturbed()`，日志 `preview tree width corrected: 420pt -> Npt (remembered Npt)`；`isRestoringTreeWidth` 防递归；
- **兜底记录点**：关闭面板（`hidePanel`）与面板被切走时（`FilePanelRootView.viewDidMoveToWindow` / `onUnmounted`），所以从未拖过也能回到默认 160pt；重开后按 0 / 0.12s / 0.4s 三次幂等纠正；
- **夹取规则**是纯函数 `FilePanelController.restoredTreeWidth(_:splitWidth:)`：区间 160–420pt，且窄面板下至少给内容区留 240pt；分隔条上下限常量与 `constrainMin/MaxCoordinate` 共用。

## 工作区页签记忆（切换 / 恢复 / 关闭回收）

页签集合**跟随工作区**（= 面板的目录树根）：切换工作区时旧工作区的页签被关闭并记忆，切回时按原顺序重开。

- **收口点 `setTreeRoot(_:thenOpen:)`**：面板唯一的换根入口；根变为**不同目录**时转 `beginWorkspaceSwitch(from:to:thenOpen:)`；`treeRoot == nil` 的首次解析**不关任何页签**；同路径重指不触碰页签；
- **`beginWorkspaceSwitch`**：面板始终跟随工作区（切换已在 dsh web 发生）。无 dirty 页签直接交接；有则 `NSAlert` **二选一**——**保存并切换**（失败的经 `preview.saveFailed` 报错并保留在页签栏）/ **不保存**。**问不到人就不猜**：面板不可见、ESC 等未识别响应 → 相关页签留在页签栏并照常跟随。并发请求**最新优先**（`switchRequestGeneration` + `supersedePendingSwitchPrompt`）；
- **`performWorkspaceSwitch(…, keeping:)`**：记忆旧根页签（`tabMemory.remember`）→ `closeTabs`（释放内容，不清记忆）→ `applyTreeRoot` → `restoreTabs(for: 新根)` → 最后才执行 `thenOpen`；
- **`restoreTabs`**：按记录顺序重开（文件夹页签同样重开），磁盘上已消失的路径跳过并记日志；记忆的选中项仍在则恢复选中；
- **记忆键**：`WorkspaceTabMemory.key(for:)`（`standardizingPath` + 去尾斜杠，不解析符号链接）；
- **关闭按钮 = 彻底回收**：`closeAllTabs()` = `supersedePendingPrompt()` + `closeEveryTab()` + `tabMemory.forgetAll()`；切到其它面板**不算**关闭；
- **关闭时的未保存提示**（`askAboutUnsaved` + `saveTabs`，页签 ✕ / ⌘W 与面板 ✕ 共用）：**保存并关闭 / 不保存 / 取消**（关闭是面板内动作，「取消」是正当答案）；保存失败 → 中止关闭、保留缓冲；**无窗口（无人可问）→ 一律不关**；
- **不落盘**：记忆仅存在于进程内（`WorkspaceTabMemory` 为 struct），不记录展开状态与滚动位置；
- **与回滚基线分叉**：PreviewPanel.swift 仍是「只重设树根、不动页签」。

## 可编辑前置条件（防数据损坏）

- 仅当内容 **UTF-8 可解码** 且 `data.count <= textCap`（`2 * 1024 * 1024`，未截断）时才进入可编辑态；超限 / 非 UTF-8 / 二进制 → `showReadOnlyText` 只读 + `preview.tooLarge`/`preview.unreadable` 提示；二进制仍落元数据页；
- 保存 IO/权限失败：`NSAlert`（`preview.saveFailed`）+ `AppLog`，保留 dirty 状态与缓冲区不丢。

## 与壳层 / 构建的数据流

- 入口与 PreviewPanel 相同：main.swift 的 `previewInterceptorScript` 拦截 `/api/host.openPath` → `setRightPanel(.preview)` + `previewPanel.open(path:)`；
- **菜单**：「文件 File」菜单（`menu.file`/`menu.save`）——`保存 Save`（⌘S）+「关闭页签」（⌘W，无页签时禁用）；`updateCloseTabMenuState()` 由 `onTabsChanged` 驱动；
- 编译清单由 `platforms/macos/swift-sources.sh` glob 自动收录（`src/*.swift`），新增文件无需登记；Highlightr 的 4 个 highlight.js 资源文件由 `build-app.sh` `cp` 到 `$APP/Contents/Resources/` **根**（Highlightr 按无子目录路径加载），缺失给 WARNING；
- `Highlightr()` **初始化守卫**：显式构造并判 nil（`CodeAttributedString()` 会 force-unwrap），`highlightingAvailable()` 校验 4 个资源存在，缺失则退化为纯文本不崩溃。

## 测试与验证

`tests/file-panel/run.sh`（每个测试文件都改名 `main.swift` 单独编译，无窗口、无 dsh 服务）：

| 测试文件 | 覆盖 |
|---|---|
| `workspace-tab-tests.swift` | `WorkspaceTabMemory` 模型 28 例（归一化 / 记忆 / 恢复顺序与选中） |
| `open-with-tests.swift` | `OpenWithCatalog` 目录与记忆规则（未装应用不命中 / `path:` 形态） |
| `tree-menu-tests.swift` | `TreeMenuModel.entries` 分组、顺序、置灰与「文件不显示新建」、`canReference` 与根/无监听方禁用 |
| `composer-reference-tests.swift` | `ComposerReferenceFormatter` 19 项（引号与目录尾斜杠 / `..` 归一 / 工作区外与非法字符拒绝 / label 与 appearance） |
| （`run.sh` 内联 lint）| `composerReferenceScript` 必须**零反斜杠转义**——Swift 字面量会吃掉单反斜杠，整段 JS 解析失败 → 桥接函数不存在 → `bridge-unavailable`（`docs/file-panel-composer-reference.md` §4.5） |
| `image-zoom-tests.swift` | `ImageZoom` 17 项（适应比例 / 夹取 / 单步 / 边界收敛） |
| `editor-load-policy-tests.swift` | `EditorLoadPolicy` 23 项（行数 / 分块不重不漏不切行 / 安全阀边界 / 稳定性窗口） |
| `panel-switch-tests.swift` | 真实 `FilePanelController` + **真实 NSWindow / split view**：页签交接、头部按钮启用态、宽度夹取、角标固定尺寸、图片居中盒子 |

2026-09-21 本机实测整套 EXIT=0（与 `tests/terminal-panel/run.sh` 一并全绿）；已接入 `scripts/local-ci.sh` 与 `ci.yml` swift job。**待手动 QA**：Finder/IDE/终端各打开一次项目目录并重启验证记忆；3000+ 行文件边写边看是否卡顿；图片缩放与平移；拖宽目录树 → 关闭 → 重开宽度保持。

## 已知限制

- 2MB 上限内可编辑；`looksLikeText` 对「碰巧为合法 UTF-8 的二进制」存在极罕见误判；
- 保存为**覆盖式**写回（原子写）；磁盘文件被外部改动时直接覆盖（mtime 记录与「文件已变更」提示仍未实现，设计见 PREVIEW_PLAN）；
- 目录树 watcher 每 2s 对所有可见目录做 `stat` + 列举（主线程），超大仓库下仍可能偏重，可后续异步化。
