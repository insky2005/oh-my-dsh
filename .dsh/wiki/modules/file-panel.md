---
title: 模块：FilePanel.swift / CodeEditorView.swift（文件面板，预览+编辑+语法高亮）
tags: [module, file-panel, preview, code-editor, syntax-highlight, highlightr, edit, line-numbers]
updated: 2026-08-21T14:30:00Z
sources: [platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/vendor/Highlightr/Highlightr.swift, platforms/macos/src/vendor/Highlightr/CodeAttributedString.swift, platforms/macos/src/vendor/Highlightr/Theme.swift, platforms/macos/src/main.swift, platforms/macos/build-app.sh, docs/plans/PREVIEW_PLAN-file-panel.md]
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
3. **语法高亮**：开源组件 **Highlightr**（MIT v2.3.0）vendored 进 `platforms/macos/src/vendor/Highlightr/`，底层 highlight.js 支持 180+ 语言；`CodeEditorView.language(forExtension:)` 映射扩展名 → highlight.js 语言名（swift/js/ts/py/go/rust/cpp/md 等），未知回退纯文本；主题明暗跟随（xcode 浅 / atom-one-dark 深）。

## 可编辑前置条件（防数据损坏）

- 仅当内容 **UTF-8 可解码** 且 `data.count <= textCap`（`2 * 1024 * 1024`，未截断）时才进入可编辑态——避免用截断缓冲区覆盖文件、避免编码往返损坏；
- 超限 / 非 UTF-8 / 二进制 → `showReadOnlyText` 只读 + `preview.tooLarge`/`preview.unreadable` 提示；二进制仍落元数据页；
- 保存 IO/权限失败：`NSAlert`（`preview.saveFailed`）+ `AppLog`，保留 dirty 状态与缓冲区不丢。

## CodeEditorView（代码编辑器视图）

- `CodeEditorView: NSView`：横向+纵向 `NSScrollView` 内含并排两个 `NSTextView`——左行号栏（只读、不可聚焦）+ 右代码区（`isEditable=true`、`isRichText=false`、等宽字体 `monospacedSystemFont(12)`）；
- 行号栏 `LineNumberGutterView`：直接由代码视图实时布局（`visibleRect` + `layoutManager` + `enumerateLineFragments`）推导可见行，数字总对齐、无第二滚动视图可失步；flipped y 原点匹配 NSTextView；Core Graphics 绘制（与面板头部同管线）；
- 代码区：`widthTracksTextView=false` + 大容器 → 长行不换行、横向滚动；启用 undo、查找栏；
- **Highlightr 初始化守卫**：`Highlightr()` 显式构造并判 nil（`CodeAttributedString()` 会 force-unwrap `Highlightr()`! 而崩溃）；`highlightingAvailable()` 校验 4 个资源文件（`highlight.min.js` + `pojoaque.min.css` + `xcode.min.css` + `atom-one-dark.min.css`）在 **Bundle.main 根**存在（Highlightr 用 `Bundle(for:)` + `path(forResource:)` 无子目录加载），缺失则退化为纯文本不崩溃；
- 明暗跟随：`viewDidChangeEffectiveAppearance` 切换 highlight.js 主题（触发重高亮）。

## 与壳层 / 构建的数据流

- 入口与 PreviewPanel 相同：main.swift 的 `previewInterceptorScript` 拦截 `/api/host.openPath` → `setRightPanel(.preview)` + `previewPanel.open(path:)`；
- **菜单**：新增「文件 File」菜单（`menu.file`/`menu.save` L10n 键）——`保存 Save`（⌘S → `saveActiveFile` → `previewPanel.saveActiveTab()`）与「关闭页签」（⌘W → `closeActiveFileTab`，无页签时禁用，⌘W 落到关窗）；`updateCloseTabMenuState()` 由 `onTabsChanged` 驱动；
- **L10n 新增键**：`preview.saveHint`（保存当前文件）、`preview.saveFailed`（保存失败：%@）、`menu.file`、`menu.save`；
- `build-app.sh` `SWIFT_SOURCES` 追加：`FilePanel.swift`、`CodeEditorView.swift`、`vendor/Highlightr/{CodeAttributedString,Highlightr,Theme,HTMLUtils,Shims}.swift`；并把 4 个 highlight.js 资源文件 `cp` 到 `$APP/Contents/Resources/` **根**（Highlightr 按无子目录路径加载）；缺失给 WARNING 不影响构建；
- `local-ci.sh` 与 `ci.yml` 的 swiftc 编译检查清单同步追加上述新文件。

## 已知限制

- 2MB 上限内可编辑；`looksLikeText` 对「碰巧为合法 UTF-8 的二进制」存在极罕见误判（可接受，真二进制仍走元数据）；
- 保存为**覆盖式**写回（原子写）；磁盘文件被外部改动时直接覆盖（先记录 mtime、可选「文件已变更」增强暂未实现，设计见 PREVIEW_PLAN）；
- 大文件（>256KB）设计上禁用实时重高亮避免 JSContext 卡顿（编辑器内降级纯文本样式，保存后整段高亮）。
