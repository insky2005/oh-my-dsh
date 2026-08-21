# 文件预览强化 — 以新 FilePanel 落地（可回滚）

> 状态：📄 设计文档已落地 · 代码阶段（阶段二）待用户确认后执行 · 2026-08

## 背景与目标

oh-my-dsh 右侧的「文件」预览面板当前实现在 `platforms/macos/src/PreviewPanel.swift`（`PreviewPanelController`），能力为：目录树 + 多标签页 + 文本/图片/PDF/元数据预览。本次强化三项能力，且**以高可回滚的方式交付**：

1. **支持查看无后缀文件 或 `.xxx` 点文件**（如 `LICENSE`、`Makefile`、`.gitignore`、`.env`、`.npmrc`）。
   - 现状：`showFile` 只靠 `pathExtension` 判断类型。无后缀文件 `ext==""` → `UTType=nil` → 落「元数据」页；点文件（`.gitignore` 等）的 `pathExtension` 也返回 `""`，同样被当成元数据，无法看内容。
   - 目标：内容可被 UTF-8 解码且非二进制的文件，一律按文本预览，与扩展名无关。
2. **文件编辑 + 显示行号**。
   - 现状：`showText` 用只读 `NSTextView`（`isEditable=false`），无行号，无保存。
   - 目标：文本/代码文件可在面板内编辑，左侧有行号栏，头部有「保存」按钮 + `Cmd+S`，有未保存标记（dirty 圆点），可原子写回磁盘。
3. **代码类文件显示更友好**。
   - 现状：纯等宽黑字，无高亮、无横向滚动、行号缺失。
   - 目标：语法高亮（多语言）+ 行号 + 不自动换行（长行横向滚动）+ 等宽字体 + 跟随明暗主题。

## 验收标准

- 打开无后缀文本、点文件、`.py/.swift/.js/.ts/.md` 等均能查看；
- UTF-8 且在 2MB 上限内的文件可编辑、行号随内容/滚动刷新、保存写回成功并给出反馈、dirty 圆点正确出现/消失；
- 二进制 / 超限文件保持只读并提示；
- 明暗模式切换高亮主题跟随；universal（arm64 + x86_64）构建均正常；
- **PreviewPanel.swift 零改动**；回滚仅需还原 main.swift 接线 + 删除新文件 + 移除编译登记。

## 核心架构决策（可回滚优先）

- **不修改 `PreviewPanel.swift`**：把现有实现完整复制为**新文件 `FilePanel.swift`**（类名 `FilePanelController`），所有优化只落在此新类中。PreviewPanel 原文件与编译登记**原样保留**，仅作为回滚对照/兜底。
- **main.swift 只改两处接线**：活动栏预览按钮 + dsh web 文件点击拦截，都指向新的 FilePanel。二者当前都汇流到同一个 `previewPanel` 属性，因此接线 = 改该属性的类型声明与初始化（2 行）。

### 已核实的接线点（main.swift）

| 位置 | 作用 | 现状 |
|---|---|---|
| `main.swift:1173` | 右栏控制器属性声明 | `private var previewPanel: PreviewPanelController!` |
| `main.swift:1367` | 属性初始化 | `previewPanel = PreviewPanelController()` |
| `main.swift:1404` | 活动栏预览按钮 | `previewBarButton = makeActivityButton(symbol:"doc.on.doc", …)` → `setRightPanel(.preview)` |
| `main.swift:1485` | 右栏槽位返回 | `.preview: return previewPanel.view` |
| `main.swift:2479-2486` | dsh web 文件点击拦截 | `dshPreview` 消息 → `previewPanel.open(path:)` |

其它引用（`ensureTreeLoaded` 1567、`setProjectDirectory` 2503、`refreshTooltips` 2710、调试 1642/1658、自检 1333）都走该属性，类型换成新控制器后自动跟随，无需改动。

**接线方案（最小、可回滚）**：把 `previewPanel` 属性类型改为 `FilePanelController`、初始化改为 `FilePanelController()`（共 2 行）。活动栏按钮与点击拦截通过同一属性自动切换到 FilePanel。
**回滚路径**：还原这 2 行 → 删除 `FilePanel.swift`/`CodeEditorView.swift`/`vendor/Highlightr` → 从 `build-app.sh` 移除登记。PreviewPanel.swift 始终未动。

## 关键技术约束

- 构建是纯 `swiftc` 直接编译 `SWIFT_SOURCES` 列表（`build-app.sh`），**无 SwiftPM**。引入第三方 = **把源码 vendored 进仓库并登记进编译清单**，资源文件由构建脚本复制进 .app。
- 新 Swift 文件必须登记进 `build-app.sh` 的 `SWIFT_SOURCES`（AGENTS.md 约束）。
- 文案必须中英双语成对（`main.swift` 的 `L10n.table`）。
- 开发先切分支 `feature/file-panel`（本文档已在其上落地）。

### 共享类型去重（关键，决定 FilePanel.swift 结构）

PreviewPanel.swift 已声明并被其它面板共享的类型：`DynamicFillView`、`CustomIconButton`、`HeaderLabel`、`BakedIconView`（以及 `HoverButton`/`PanelIconButton`/`ActivityBarButton`，仅 PreviewPanel/main 使用）。

因此 **FilePanel.swift 不得重复声明这些共享类型**（否则符号重定义、编译失败），而是**复用**它们。FilePanel.swift 只需自带：
- 文件私有 `private final class TreeNode`（目录树节点）与 `private struct DirRow` —— file-private，与 PreviewPanel 内同名的私有声明不冲突；
- `final class FilePanelController`（控制器本体，含全部优化）。

## 阶段划分

- **阶段一（本文档）**：只落设计文档，不改任何代码。✅ 已完成。
- **阶段二（待用户确认执行）**：按本文档实现 FilePanel 全部功能，含 build 变更与 main.swift 接线。

## 阶段二实现设计

### 1) 新建 `platforms/macos/src/FilePanel.swift`（登记进 build-app.sh SWIFT_SOURCES）

从 `PreviewPanel.swift` 的 `PreviewPanelController` 复制主体 → 重命名 `final class FilePanelController`，保留其对外契约：
`let view: DynamicFillView`、`var onRequestHide`、`var serverPortProvider`、`open(path:)->Bool`、`ensureTreeLoaded()`、`setProjectDirectory(_:)`、`refreshTooltips()`，并新增 `saveActiveTab()`。

复用共享类型（不重复声明）；仅自带 file-private 的 `TreeNode`/`DirRow`。全部优化落在此类内。

### 2) 需求 1 — 无后缀/点文件可查看

- 新增 `private static func looksLikeText(_ data: Data) -> Bool`：`String(data:encoding:.utf8)` 成功，且 `data` 不含 `0x00`，且控制字符占比低（排除 \n、\r、\t）。
- 改 `showFile(_:)` 判定：`isText = isMarkdown || type.conforms(to:.text) || textExtensions.contains(ext) || Self.looksLikeText(data)`。
- 二进制但碰巧为合法 UTF-8 的极罕见误判可接受；`showMetadata` 仍保留给真正的二进制。

### 3) 需求 2 — 编辑 + 行号（新增 `CodeEditorView.swift`，登记 build-app.sh）

`CodeEditorView: NSView`：
- 横向 + 纵向 `NSScrollView`，内含并排两个 `NSTextView`：**行号栏**（只读、`isSelectable=false`、不可聚焦）+ **代码编辑区**（`isEditable=true`、`isRichText=false`、等宽字体）。
- 行号栏：监听代码视图 `NSViewBoundsDidChangeNotification` 同步滚动；随文本行数变化刷新（`didChangeText` / `textStorageDidProcessEditing`）；栏宽随最大行号位数自适应。
- 代码区：`textContainer.widthTracksTextView=false`、容器宽度设大 → 长行不换行、横向滚动；启用 `undoManager`、`usesFindBar`（可选）。
- 主题：背景/行号用 `.textBackgroundColor` / `.secondaryLabelColor`，明暗自适应。
- 保存：`func writeBack() -> Bool`，用 `Data.write(to:options:.atomic)` 写回 UTF-8；失败返回错误供上层弹窗；提供 `onDirtyChange: ((Bool)->Void)?` 与 `isDirty`。
- 语言判定：按 `pathExtension` 映射到 highlight.js 语言名（`swift/js/ts/py/…`）；未知回退纯文本样式。

**可编辑前置条件**：仅当内容为合法 UTF-8 且 `data.count <= textCap`（未截断）时才进入可编辑态，避免用截断缓冲区覆盖文件、避免编码往返损坏。

### 4) 需求 3 — 语法高亮（开源组件 Highlightr，MIT v2.3.0）

> 开源选型结论：语法高亮用 **Highlightr**（github.com/raspu/Highlightr，MIT，v2.3.0，1868★，维护中）。提供 `CodeAttributedString: NSTextStorage`，可挂到任意 `NSTextView`，底层 highlight.js 支持 180+ 语言。行号栏+可编辑视图无契合的现成小组件（zunda-pixel/CodeEditor 已下架 404；STTextView 为 TextKit2、体积大、与 swiftc 直编冲突；SwiftUI 版与全 AppKit 可靠性取向不符），故用薄薄一层自研 AppKit 视图承载，只把最难的语法高亮外包给 Highlightr。

Vendored 到 `platforms/macos/src/vendor/Highlightr/`：
- 源码：`src/classes/*.swift`（`CodeAttributedString.swift`、`Highlightr.swift`、`Theme.swift`、`HTMLUtils.swift`、`Shims.swift`）。
- 资源：`src/assets/highlighter/highlight.min.js`（~1.5MB）+ 两个主题 css（`xcode.min.css` 浅色 / `atom-one-dark.min.css` 深色）——只带 2 个主题控制体积。
- 许可：`LICENSE` + 归属 `NOTICE` 一并放入 vendor 目录。

用法：`let storage = CodeAttributedString()`，`storage.language = <lang>`，`storage.theme = Theme(name: dark ? "atom-one-dark" : "xcode")`，`textView.textStorage = storage`。资源从 `Bundle.main.url(forResource:…, subdirectory:"highlightr")` 加载。`import JavaScriptCore` 为 macOS 自动链接框架，无需额外链接配置，arm64/x86_64 均可用。

性能策略：初始高亮在后台队列跑，完成后主线程替换；>256KB 的大文件**禁用实时重高亮**（编辑时退化为纯文本样式，避免 JSContext 卡顿），保存后再整段高亮；上限内仍受 2MB 只读截断保护。

### 5) 构建（build-app.sh）

- `SWIFT_SOURCES` 追加：`FilePanel.swift`、`CodeEditorView.swift`、`vendor/Highlightr/*.swift`。
- 新增一步（在 [4/7] runtime 嵌入之后）：`ditto src/vendor/Highlightr/assets "$APP/Contents/Resources/highlightr"`，并写一条构建日志。
- vendor 流程**版本固定与校验**：下载 v2.3.0 源码/资源时记录 SHA-256，放入 `.cache` 以便离线/CI 复用（沿用现有 `--prefetch` 缓存惯例）。

### 6) main.swift（阶段二才改）

- `L10n.table` 新增双语对：`preview.save`/`preview.saveHint`（保存/Save）、`preview.saved`（已保存/Saved）、`preview.saveFailed`（保存失败：%@/Save failed: %@）、`preview.dirty`（有未保存更改/Unsaved changes）、`preview.readonlyLarge`（文件过大，仅预览（只读）/File too large — read-only preview）、`preview.readonlyBinary`（二进制或不可安全编辑，只读/Binary or not safely editable — read-only）。
- 应用菜单加「保存」项（`Cmd+S`）→ `previewPanel.saveActiveTab()`。
- 头部加「保存」`CustomIconButton`（glyph `.symbol("square.and.arrow.down")`），仅当前页签可编辑且有改动时可用/高亮；`refreshTooltips()` 同步新按钮 tooltip。
- `Tab` 结构体加 `isEditable`/`isDirty`/`editor: CodeEditorView?`；`select`/`close`/`closeAllTabs` 同步保存按钮可用态与页签 dirty 圆点。

## 边界与失败模式

- **超 2MB**：只读 + 现有 `preview.tooLarge` 提示，绝不进入可编辑态（避免用截断缓冲区覆盖文件）。
- **非 UTF-8 / 二进制**：只读；`looksLikeText` 判定为文本但 `String(data:encoding:.utf8)` 失败的一律只读。
- **保存 IO/权限失败**：`NSAlert` 展示 `preview.saveFailed`，保留 dirty 状态与缓冲区。
- **磁盘文件被外部改动**（如 agent 重写）：保存会覆盖；先记录 mtime，若磁盘 mtime 晚于打开时且内容不同，可弹「文件已变更，是否覆盖」（可选增强；默认先实现覆盖 + 记录日志）。
- **高亮卡顿**：大文件禁用实时高亮（见 §4）；初始高亮后台线程。
- **universal 构建**：Highlightr + JavaScriptCore 两架构均需通过；构建脚本下载/校验失败给出明确报错。
- **共享类型去重**：FilePanel.swift 复用而非重复声明共享类型，避免符号重定义。
- **L10n 遗漏**：新增文案必须成对，否则视为缺陷。

## 测试与验收

- 现有 `node --test core/tests/` 保持全绿（本次不改 core，仅 UI）。
- 手工验证矩阵：
  - 无后缀文本文件、`.gitignore`/`.env`/`.npmrc` → 以文本显示；
  - `.py/.swift/.js/.ts/.md/.json` → 语法高亮 + 行号 + 长行横向滚动；
  - 编辑 → 行号随内容刷新 → 保存写回 → 出现「已保存」反馈 → dirty 圆点消失；
  - >2MB 文本 → 只读 + 提示；二进制文件 → 元数据页；
  - 明暗模式切换高亮主题跟随；`DSH_PREVIEW_DEBUG=1` 布局自检通过。
- CI：macOS arm64 构建（含新源码与 vendored Highlightr）必须通过；release.yml 的 x86_64 交叉编译在打 tag 时验证。

## 流程与交付

- 分支：`feature/file-panel`；conventional commit（`feat(file-panel): …`）。
- 交付物：`FilePanel.swift`、`CodeEditorView.swift`、`vendor/Highlightr/**`、`build-app.sh` 改动、`main.swift`（接线 2 行 + L10n + 保存菜单）。
- 完成后开 PR 合并回 `main`（CI 全绿 + review）。

## 假设

- 接受通过 vendored **Highlightr** 引入 ~1.5MB highlight.js 资源并加一步资源嵌入（用开源组件而非自研的代价，符合「不得已不自研」倾向）；若需要更轻量方案（仅行号 + 等宽 + 横向滚动、无高亮），阶段二可将 §4 降级为纯样式增强。
- 编辑会真实写回磁盘（原子写入）；仅 UTF-8 且未截断的文件可编辑。
- FilePanel.swift 复用 PreviewPanel.swift 的共享类型（不重复声明）。
