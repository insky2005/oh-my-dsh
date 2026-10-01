# Terminal Panel Header 渲染问题修复

## 问题描述

在 oh-my-dsh.app 的终端面板中，顶部 header（灰色标题栏 + +/✕ 按钮）在浅色和深色模式下均不可见，整个面板顶部区域被白色覆盖。预览面板（PreviewPanel）的 header 渲染正常。

## 排查过程

### 1. 初步假设：DynamicFillView 嵌套问题

TerminalPanel 的 root view 和 header 都使用 `DynamicFillView`，怀疑嵌套导致子视图 `draw()` 不生效。尝试了多种方案均无效：
- 将 header 改为自定义 `TerminalHeaderView`（手动 draw 灰色背景）
- 将 root view 改为普通 `NSView()`
- 将 root view 改为 `TerminalRootView`（isOpaque=false）

### 2. 关键突破：隔离 TerminalView

将 `select()` 方法中的 `tab.termView`（TerminalView）临时替换为红色占位视图（`NSColor.systemRed`），发现 **header 正常渲染**。确认问题出在 TerminalView。

### 3. 根因定位

TerminalView 的两个属性组合导致了问题：

| 属性 | 值 | 影响 |
|---|---|---|
| `isOpaque` | `true` | 告诉 Core Animation "我完全填充我的区域" |
| `wantsLayer` | `false`（默认） | 没有独立的 backing layer |

在 layer-backed 窗口中，`isOpaque = true` 且没有独立 layer 的视图，其绘制内容会被合成到父视图的 layer 上。由于 contentContainer 也没有独立 layer，TerminalView 的白色背景绘制（`NSColor.textBackgroundColor`）溢出到了 root view 的 layer，覆盖了同级的 header 子视图。

PreviewPanel 之所以正常，是因为其内容区使用 `NSSplitView`，NSSplitView 自带独立 layer，天然隔离了子视图的绘制。

### 4. 尝试 TerminalView.wantsLayer = true（无效）

单独给 TerminalView 加 `wantsLayer = true` 无效。因为 TerminalView 有了独立 layer 后，其父视图 contentContainer 仍然没有独立 layer，合成路径问题未根本解决。

### 5. 最终修复

给 **contentContainer** 加 `wantsLayer = true` + `masksToBounds = true`：

```swift
contentContainer.wantsLayer = true
contentContainer.layer?.masksToBounds = true
```

- `wantsLayer = true`：contentContainer 获得独立的 backing layer，TerminalView 的绘制被限制在这个 layer 内，不会溢出到 root view 的 layer
- `masksToBounds = true`：强制裁剪子视图超出 bounds 的绘制内容，双重保险

## 最终代码变更

### TerminalPanel.swift

**TerminalView init**（第 925 行）：
```swift
super.init(frame: .zero)
wantsLayer = true  // 辅助修复
```

**buildUI() contentContainer 设置**（第 1485-1486 行）：
```swift
contentContainer.wantsLayer = true
contentContainer.layer?.masksToBounds = true
```

**TerminalRootView**（新增类）：
```swift
final class TerminalRootView: NSView {
    var kind: DynamicFillView.Kind = .window { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }  // 关键：不声明 opaque，强制合成所有子视图
    // ... draw() 与 DynamicFillView 相同的灰色背景绘制
}
```

## 经验总结

1. **layer-backed 窗口中，opaque 视图 + 无独立 layer = 合成陷阱**。`isOpaque = true` 会告诉 Core Animation 优化渲染，但如果视图没有独立 layer，其绘制可能溢出到父 layer，覆盖兄弟视图。

2. **隔离绘制区域用父容器的 wantsLayer，而非子视图的**。子视图的 `wantsLayer` 只解决自身的合成问题；要防止子视图绘制溢出影响兄弟视图，需要给父容器加 `wantsLayer = true`。

3. **NSSplitView 等系统视图自带 layer 隔离**。自定义视图替代 NSSplitView 时，需要手动添加 layer 隔离。

4. **二分法定位渲染问题**。通过替换可疑视图为占位视图，快速锁定问题来源。
