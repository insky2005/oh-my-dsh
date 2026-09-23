---
title: 模块：PreviewPanel.swift（预览面板，回滚基线）
tags: [module, preview, file-tree, tabs, rollback]
updated: 2026-09-21T09:43:26Z
sources: [platforms/macos/src/PreviewPanel.swift, platforms/macos/src/main.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/SkillsPanel.swift, tests/skills-panel/, docs/plans/PREVIEW_PLAN-file-panel.md, platforms/macos/src/PanelSurface.swift, docs/ui-color-scheme.md, docs/ux-feedback.md, CHANGELOG.md]
manual: false
---

# 模块：PreviewPanel.swift（预览面板，回滚基线）

1765 行（2026-09-21 实测）。右栏预览面板的**回滚基线**：`feature/file-panel` 已把现行预览实现改为其强化分支 [FilePanel](file-panel.md)（`FilePanelController`），仅作回滚对照/兜底。面板**行为**未变，但其中的共享基件已随 2026-09-17 的面板配色统一一并修改（`DynamicFillView.Kind` 收敛为 `.panel`/`.custom`、`HoverButton`/`CustomIconButton` 改走 `PanelControl`、新增 `PanelTabButton`）——它不再是「逐字节未改」的代表，配色令牌见 `docs/ui-color-scheme.md`。本文档描述 PreviewPanel 原始能力（FilePanel 继承其大部分）：点击 dsh web 对话中的文件链接（工具产物）不再弹系统默认应用，而是在面板内预览；左侧为项目目录树。同时是**共享 UI 组件库**。

## 共享 UI 组件（其他面板复用）

| 组件 | 说明 |
|---|---|
| `PanelMenuButton` | 头部**菜单按钮**（Core Graphics 自绘「图标 + 文字 + ▾」，无 cell、无 NSImage tint）：hover / 菜单打开期间高亮，窄面板自动退化为「图标 + ▾」chip；**点击整颗按钮就是打开菜单**（`onShowMenu`），⌥ 点击走 `onAction`（上次记住的方式 / 默认动作）。文件面板的「打开项目 ▾」「打开文件 ▾」用它（见 [file-panel](file-panel.md)）；`PreviewPanel.swift` 自身仍用图标按钮 |
| `HoverButton` | 无边框图标按钮：hover 高亮 + 手型光标 + 选中态高亮；底色改由 `PanelControl.fill(dark:highlighted:)` 统一（常态档，hover / `state == .on` 时高亮档） |
| `PanelTabButton` | 页签标题按钮（`HoverButton` 子类）：无边框、按面板控件两档着色，并额外给标题留 16pt 横向内边距 + 24pt 最小高（无边框 NSButton 否则紧贴标题）。文件 / 预览 / 终端三个面板的页签共用 |
| `DynamicFillView` | 自绘背景视图（`kind: .panel`（默认，面板底色）/ `.custom(NSColor)`；**已去掉 `final`**，文件面板的 `FilePanelRootView` 继承它以拿到「重新挂载到窗口」钩子），深浅色自动跟随（动态填充，非固定 CGColor；色值来自 `PanelSurface`）。⚠️ **只填自己拥有的区域**：`draw(_:)` 用 `bounds.intersection(dirtyRect).fill()`——AppKit 可能给不透明视图传入**大于其 bounds** 的脏矩形，直接 `dirtyRect.fill()` 会越过自身边界、刷掉**层级更低的同色兄弟视图**（技能面板的头部标题与标签条正是这样整条消失的，2119bb1 修复；回归测试 `tests/skills-panel/render-tests.swift` 用真实 `DynamicFillView`/`HeaderLabel` 离屏渲染钉住） |
| `ActivityBarButton` | 活动栏图标按钮，图标颜色烘烤进图片（`BakedIconView`）保证深色可见 |
| `PanelIconButton` | 面板头部图标按钮（按深浅色刷新 tint；样式继承 `CustomIconButton`，故常态即面板控件常态档） |
| `HeaderLabel` | 自绘文本标签（深浅色自适应颜色） |
| `CustomIconButton` | 自绘图标按钮（`onAction` 闭包、hover、enabled 态；`Glyph` 枚举：plus/close/folder/openInApp/reveal/play/stop + `symbol(String)`——b7c5407 起支持 SF Symbol 字形（tinted 系统图片，15pt 居中绘制，如任务面板刷新按钮 `arrow.clockwise`），refresh 手绘圆形箭头随之移除）；可配 `size`（默认 26）、`hoverColor`（hover 高亮色；仅页签关闭按钮用 `systemRed` 特例）；常态/高亮底色走 `PanelControl`（`showsBackground` 已删除） |

## PreviewPanelController 职责

- **Tab 管理**：`open(path:)` 创建或激活页签；`select`/`close`/`navigate`；页签标题来自文件名；右上「关闭页签」；
- **内容渲染**（`render` → 按类型分发）：
  - 目录：`showDirectory` 表格（名称/大小/修改时间/类型列），双击进入；
  - 文本/代码/Markdown：`showText` 纯文本显示，**保留原始换行**（markdown 有意不渲染，避免软换行被合并）；超大文件只预览前 N MiB 并提示；
  - 图片：`showImage`；PDF：`showPDF`（PDFKit）；
  - 未知类型/二进制：`showMetadata` 图标 + 元数据（名称/大小/类型/创建/修改/路径/上一级）；
- **项目目录树**：`TreeNode` 懒加载子节点（`children == nil` 表示未加载）；`resolveProjectDirectory` 经 `DSHSessionRPC` 解析活动会话 cwd（优先共享 `ProjectDirectory`），失败回退 `pickDirectoryFallback`（手动选文件夹）；`startTreeWatcher` 每 2s 轮询 mtime，变化即刷新；树宽可拖拽（初始宽度 160pt，拖动最小值 160pt）；`setProjectDirectory(_:)` 由壳层在会话切换时调用——只重设树根，已打开的预览页签不受影响；
- **头部操作**：打开项目目录（`⌥⌘F` 同入口）、在默认应用中打开、在 Finder 中显示、关闭面板；
- `minWidth = 260`（面板最小宽）；面板宽由分割条控制并持久化（`previewPanelWidth`，AppDelegate 侧）。

## 与壳层的数据流

- 入口是 main.swift 的 JS 拦截：`window.fetch` 拦截 `/api/host.openPath` → `postMessage` → AppDelegate `userContentController` → `setRightPanel(.preview)` + `previewPanel.open(path:)`；
- 拦截器伪装成功响应（`{type:"server-response", result:{ok:true, value:{opened:true}}}`），页面不会打开系统应用，客户端 promise 正常 resolve；
- 调试：`DSH_PREVIEW_DEBUG=1` 时探针（`previewDebugProbeJS`）验证拦截器安装/命中/伪响应；`DSH_PREVIEW_TEST_PATH` 启动自测。

## 已知行为/限制

- 文本解码失败（非 UTF-8）→ `preview.unreadable` 提示；文件过大 → 截断提示；
- 树变更轮询为 2s 间隔（轻量 mtime 比对），非 FSEvents；
- 目录树根失败时提供手动选文件夹兜底（RPC 失败场景）；
- **不透明自绘视图的绘制契约**：内容容器要放到**最底层/最先添加**，头部条最后添加；即使如此也不能依赖「脏矩形不会越界」——见上表 `DynamicFillView` 与 `docs/terminal-header-fix.md` 的合成陷阱（同源问题的另一面）；
- 当前实际接入壳层的是 FilePanel（`previewPanel` 类型为 `FilePanelController`），本文件不再被实例化，仅保留作为回滚基线与共享 UI 组件来源；
- **分叉提示**：FilePanel 已进一步演进——本文件的 `setProjectDirectory` 仍是「只重设树根、不动已开页签」，而 FilePanel 会在换根时按工作区**记忆并关闭 / 重开页签**；本文件的头部仍是纯图标按钮（功能靠 tooltip），「打开项目 ▾ / 打开文件 ▾」菜单按钮与 `OpenWithCatalog` 只接在 FilePanel 上（见 [file-panel](modules/file-panel.md)）；回滚到大基线时这些能力随之消失。
