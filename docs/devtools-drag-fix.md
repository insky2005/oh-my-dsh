# DevTools 拖动条导致 CEF 视图上移问题分析与修复

> 日期：2026-08-19
> 状态：已实施（`platforms/macos/src/BrowserPanel.swift`，分支 `feature/browser-panel`）

## 问题描述

BrowserPanel 中，页签内打开页面 → 打开 DevTools → 拖动 DevTools 标题条上下调整
两个窗口的高度时，CEF 主页面视图**慢慢上移**，最终顶部被面板头部遮住。

## 视图嵌套结构

```
BrowserRootView (layer-backed)
├── header (40pt)
├── tabBarRow (33pt)
├── toolbar (36pt)
└── contentContainer (masksToBounds, 钉底)
    └── BrowserOSRView (×N，每 tab 一个)
        ├── pageView (主页面区)
        │   └── [CEF NSView]  ← 窗口化模式，CEF 自建 NSView
        │       autoresizingMask = [.width, .height]
        └── devtoolsArea (高度约束 0↔150~700)
            ├── devtoolsBar (28pt，拖动条)
            └── devtoolsContent
                └── [CEF NSView]  ← DevTools 子浏览器
```

约束关系：
- `pageView.topAnchor = BrowserOSRView.topAnchor`（顶部固定）
- `pageView.bottomAnchor = devtoolsArea.topAnchor`（底部跟着 devtoolsArea 走）
- `devtoolsArea.bottomAnchor = BrowserOSRView.bottomAnchor`（底部固定）
- `devtoolsArea` 高度约束：hidden=0 / 显示=150~700（拖动调整）

## 排查过程

### 排除的假设

通过日志（`onDrag` 中每帧打印 pageView.frame / bounds / cefFrame）确认：

| 检查项 | 结果 |
|--------|------|
| `pageView.bounds.origin` | 始终 `(0, 0)` ✓ 无偏移 |
| `pageView.frame.origin.x` | 始终 `0` ✓ |
| `cefFrame.origin` | 始终 `(0, 0)` ✓ |
| `cefFrame.size` | 始终匹配 `pageView.bounds.size` ✓ |
| `pageView.height + devtoolsArea.height` | 始终 = 容器总高度 ✓ 守恒 |

**所有 NSView frame/bounds 完全正确，没有任何累积偏移。**

排除的假设：
- ~~`contentsScale` 不匹配~~ → 已修复但无效
- ~~autoresizing 与 Auto Layout 竞争导致 frame 漂移~~ → 日志否定
- ~~pageView bounds.origin 偏移~~ → 日志否定
- ~~CEF 视图 frame origin 偏移~~ → 日志否定
- ~~网页 scrollY 累积偏移~~ → frame 正确说明不是这个问题

### 确认的根因

**`WasResized()` 触发 Chromium 内部页面重排导致渲染内容偏移。**

调用链：
```
onDrag 每 80ms
  → notifyResize()
    → CEFShim.resizeBrowser()
      → SetViewSize() + WasResized()
        → Chromium 重新布局页面
          → 页面滚动位置发生不可控偏移
```

证据：frame 完全正确但视觉内容在移动 → 唯一解释是 CEF 渲染的**像素内容**
在偏移，而能触发这个偏移的只有 `WasResized()`。

## 修复方案：拖动期间不动 CEF 视图

### 核心思路

拖动只改 pageView 的**裁剪边界**，CEF 视图 frame 保持不动、不调 `WasResized()`。

```
拖动前：                          拖动中（devtoolsArea 增大）：

┌──────────────────┐             ┌──────────────────┐
│                  │             │                  │
│   CEF View       │             │   CEF View       │  ← frame 不变
│   (不动)         │             │   (不动)          │     不调 WasResized
│                  │             │                  │
├─ pageView 裁剪 ──┤             ├─ pageView 裁剪 ──┤  ← 只是裁剪区变小
│░░░░░░░░░░░░░░░░░│             │░░░░░░░░░░░░░░░░░│
│ devtoolsArea     │             │ devtoolsArea     │  ← z-order 更高，
│ ┌─devtoolsBar──┐ │             │ ┌─devtoolsBar──┐ │     盖住 CEF 溢出
│ │ devtoolsCont │ │             │ │ devtoolsCont │ │
│ └──────────────┘ │             │ └──────────────┘ │
└──────────────────┘             └──────────────────┘
```

### 实现要点

**onDrag 中：**

1. 首次拖动时设 `pageView.autoresizesSubviews = false`（锁定 CEF 视图 frame）
2. 只改 devtoolsArea 高度约束 + `layoutSubtreeIfNeeded()`
3. **不调** `notifyResize()`，**不调** `WasResized()`

**onDragEnd 中：**

1. 恢复 `pageView.autoresizesSubviews = true`
2. 一次性更新 CEF 视图 frame：`v.frame = (0, 0, pageView.bounds.size)`
3. 调一次 `notifyResize()`（WasResized 只触发一次）
4. DevTools 子浏览器一并 resize

**layout() 中：**

拖动期间（`isDraggingDevTools = true`）跳过 CEF 子视图 frame 同步和 `notifyResize()`。

### 防串窗口分析

拖动中 CEF 视图 frame 不变，pageView 裁剪区变化。两个方向：

**向上拖（devtoolsArea 缩小）：**
- pageView 变大，CEF 视图比 pageView 小
- CEF 视图底部在 devtoolsArea 上方 → 不溢出 → 无串窗口 ✓

**向下拖（devtoolsArea 增大）：**
- pageView 变小，CEF 视图比 pageView 大
- CEF 视图底部溢出到 devtoolsArea 区域
- 但 `devtoolsArea` 在视图层级中添加在 `pageView` 之后（z-order 更高），
  完全盖住溢出部分 → 无串窗口 ✓

**唯一注意点：** `devtoolsContent` 必须有不透明背景，否则溢出的 CEF
内容可能透过透明的 `devtoolsContent` 显示：

```swift
devtoolsContent.layer?.backgroundColor = NSColor.black.cgColor  // 或匹配 DevTools 背景色
```

### scrollY 恢复（松手时）

松手时只触发一次 `WasResized()`，scroll 偏移可控：

```
onDragEnd:
  1. 同步保存 scrollY（CDP evaluate "window.scrollY"）
  2. 更新 CEF 视图 frame + WasResized()
  3. 等待 CEF 处理完 resize（~100ms）
  4. 恢复 scrollY（CDP evaluate "window.scrollTo(0, saved)"）
```

因为只触发一次 `WasResized()`，偏移量小且可预测，恢复可靠。

## 优势

| 对比项 | 旧方案（每帧 WasResized） | 新方案（拖动不动 CEF） |
|--------|--------------------------|----------------------|
| 拖动中页面重排 | 每 80ms 一次，持续抖动 | 零次，丝滑 |
| scroll 偏移 | 累积数十次，不可控 | 松手时一次，可恢复 |
| 串窗口风险 | 无 | 无（devtoolsArea z-order 盖住） |
| 视觉连续性 | 页面反复跳动 | 裁剪区平滑变化，页面内容不动 |
