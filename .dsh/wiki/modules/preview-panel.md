---
title: 模块：PreviewPanel.swift（预览面板）
tags: [module, preview, file-tree, tabs]
updated: 2026-08-15T11:25:07Z
sources: [src/PreviewPanel.swift, src/main.swift]
manual: false
---

# 模块：PreviewPanel.swift（预览面板）

约 1445 行。右栏预览面板：点击 dsh web 对话中的文件链接（工具产物）不再弹系统默认应用，而是在面板内预览；左侧为项目目录树。同时是**共享 UI 组件库**。

## 共享 UI 组件（其他面板复用）

| 组件 | 说明 |
|---|---|
| `HoverButton` | 无边框图标按钮：hover 高亮 + 手型光标 + 选中态高亮 |
| `DynamicFillView` | 自绘背景视图（`kind: .window / .control`），深浅色自动跟随（动态填充，非固定 CGColor） |
| `ActivityBarButton` | 活动栏图标按钮，图标颜色烘烤进图片（`BakedIconView`）保证深色可见 |
| `PanelIconButton` | 面板头部图标按钮（按深浅色刷新 tint） |
| `HeaderLabel` | 自绘文本标签（深浅色自适应颜色） |
| `CustomIconButton` | 自绘图标按钮（`onAction` 闭包、hover、enabled 态） |

## PreviewPanelController 职责

- **Tab 管理**：`open(path:)` 创建或激活页签；`select`/`close`/`navigate`；页签标题来自文件名；右上「关闭页签」；
- **内容渲染**（`render` → 按类型分发）：
  - 目录：`showDirectory` 表格（名称/大小/修改时间/类型列），双击进入；
  - 文本/代码/Markdown：`showText` 纯文本显示，**保留原始换行**（markdown 有意不渲染，避免软换行被合并）；超大文件只预览前 N MiB 并提示；
  - 图片：`showImage`；PDF：`showPDF`（PDFKit）；
  - 未知类型/二进制：`showMetadata` 图标 + 元数据（名称/大小/类型/创建/修改/路径/上一级）；
- **项目目录树**：`TreeNode` 懒加载子节点（`children == nil` 表示未加载）；`resolveProjectDirectory` 经 `DSHSessionRPC` 解析活动会话 cwd（优先共享 `ProjectDirectory`），失败回退 `pickDirectoryFallback`（手动选文件夹）；`startTreeWatcher` 每 2s 轮询 mtime，变化即刷新；树宽可拖拽（初始宽度 160pt，拖动最小值 160pt）；`setProjectDirectory(_:)` 由壳层在会话切换时调用——只重设树根，已打开的预览页签不受影响；
- **头部操作**：打开项目目录（`⌥⌘P` 同入口）、在默认应用中打开、在 Finder 中显示、关闭面板；
- `minWidth = 260`（面板最小宽）；面板宽由分割条控制并持久化（`previewPanelWidth`，AppDelegate 侧）。

## 与壳层的数据流

- 入口是 main.swift 的 JS 拦截：`window.fetch` 拦截 `/api/host.openPath` → `postMessage` → AppDelegate `userContentController` → `setRightPanel(.preview)` + `previewPanel.open(path:)`；
- 拦截器伪装成功响应（`{type:"server-response", result:{ok:true, value:{opened:true}}}`），页面不会打开系统应用，客户端 promise 正常 resolve；
- 调试：`DSH_PREVIEW_DEBUG=1` 时探针（`previewDebugProbeJS`）验证拦截器安装/命中/伪响应；`DSH_PREVIEW_TEST_PATH` 启动自测。

## 已知行为/限制

- 文本解码失败（非 UTF-8）→ `preview.unreadable` 提示；文件过大 → 截断提示；
- 树变更轮询为 2s 间隔（轻量 mtime 比对），非 FSEvents；
- 目录树根失败时提供手动选文件夹兜底（RPC 失败场景）。
