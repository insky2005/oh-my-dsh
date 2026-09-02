# oh-my-dsh AppKit UI 布局规范（持续积累）

> **目标读者**：在 platforms/macos/src/*.swift 里写面板 / 控件布局的每一个人。
>
> 本文件是**会随真实 bug 不断追加的活文档**。每踩到一个布局 / 图层 / 遮罩问题，
> 修复后把「症状 + 根因 + 修复 + 防复发」追加到对应小节，并登记到 §7——而不是只记在
> 当事人心里。它既是新手的避坑清单，也是老手的「复发记忆」。
>
> 相关：docs/terminal-header-fix.md（layer 合成陷阱原始排障）、
> .dsh/wiki/conventions.md（工程约定，「面板 UI 约定」一节与本文件互相引用）。

---

## 0. 一页速查（TL;DR）

写任何面板布局前先过这 6 条，能挡掉大部分越界 / 遮罩 / 点不到的问题：

1. **容器默认要裁**：凡「内容区容器 / 可能塞进大尺寸子视图的容器」，统一
   wantsLayer = true + layer?.masksToBounds = true。Auto Layout 约束只决定「放哪」，
   **不阻止视图内容画出自己的 bounds** —— 裁剪要显式开。
2. **系统控件记得关 autoresizing**：NSButton / NSTextField 等的
   translatesAutoresizingMaskIntoConstraints **默认 true**。给它们加显式约束前必须设
   false（否则弹簧约束与显式约束冲突 → 视图跑到你意想不到的位置，见 §3.1）。
3. **「显示瞬间」不要塞复杂子视图**：view.isHidden = false 的**同一行**不要 addSubview
   一个含默认大 frame（如 NSTextView 600×300）的子视图。先 layoutSubtreeIfNeeded() 让父
   容器 frame 就位再嵌，或父容器 masksToBounds 兜底（§2）。无头测试（stub 空视图）
   **测不到这一帧** —— 必须真实渲染验证（§5.3 / §6）。
4. **隔离绘制用父容器的 wantsLayer，不是子视图的**（§1.2 / docs/terminal-header-fix.md）。
5. **根视图 isOpaque = false**（自绘背景，镜像 TerminalRootView 及各面板 RootView 模式），
   不向 Core Animation 谎报「我完全填充」（§1.3）。
6. **滚动 doc 高度要手动驱动**：FlippedWorkspaceView 作 documentView 时，内容高度靠
   stack.fittingSize 回填 doc frame；漏掉 → 内容能画出来但 **hitTest 落在陈旧 bounds 外
   → 按钮存在却点不到**（§3.2）。

---

## 1. 图层合成（layer-backed）—— 越界与遮罩的总根源

### 1.1 frame / 约束 vs 绘制：两套独立系统

Auto Layout 解出每个视图的 frame（「应放哪」），但**视图绘制由 backing layer / draw()
承担，两者不绑定**。普通 NSView 默认**不裁剪子视图**；裁剪是 NSScrollView / NSClipView
这类专用控件自带的。

**推论**：约束完全正确 ≠ 内容不会画到 bounds 外。任何子视图以「大于父容器当前 bounds」
的 frame 渲染，内容就外溢——若无裁剪就盖到兄弟视图上。这是越界 / 遮罩类 bug 的
**第一大来源**，且**只在真实渲染出现**（frame dump 永远抓不到）。

**真实现场**（round 10，Scaffold 环节编辑器 ScaffoldPanel.swift）：新建 / 编辑环节打开
编辑器时，CodeEditorView（内含 NSTextView，默认 frame 600×300）在其父容器
editorContent **尚未完成首次布局的同一瞬间**被嵌入，内容越界向上画到编辑器顶部 header
（‹ 返回 / 标题 / 保存）与文件标签栏之上——视觉上「顶部控件行消失，只见外层标题 + 空内容框」。
修复：给 editorContent 加 wantsLayer + masksToBounds，把内容裁在内容区内。

### 1.2 opaque + 无独立 layer = 合成陷阱

layer-backed 窗口里，isOpaque = true 且没有独立 layer 的视图，绘制会被合成到
**父视图的 layer** 上。若父容器也无独立 layer，内容就溢出到更上层，盖住同级兄弟视图。

**规范**（来自 docs/terminal-header-fix.md，Terminal 面板曾整头被白块盖住）：
- 隔离绘制区域用**父容器的** wantsLayer = true + masksToBounds = true；单独给子视图
  wantsLayer = true 治不了（父仍无 layer，合成路径不变）。
- 根视图用 isOpaque = false 的自绘背景视图（TerminalRootView / 各面板 RootView 模式）。
- **经验推广**：任何「平时隐藏、生成 / 状态变化时才显示」的 opaque 无 layer 视图（如 wiki
  面板底部状态条）都可能触发同类溢出——显示前先给视图自身 wantsLayer = true +
  masksToBounds = true。

### 1.3 面板根视图清单（isOpaque=false，新增面板照抄）

platforms/macos/src/*.swift 里现有 isOpaque = false 的根 / 自绘视图：BrowserPanel、
ChannelPanel、IssueRunnerPanel、ScaffoldPanel（多处）、TerminalPanel、WikiPanel
（两处）。**新增面板的根视图必须走同一模式**，不要默认继承 NSView 的 opaque。

---

## 2. 布局时序：视图在「显示瞬间」被塞入复杂子视图

### 2.1 本质

AppKit 是「先有 frame、后靠约束重排」。当「父容器 isHidden = false」与「子视图
addSubview」发生在**同一个 runloop 迭代**时，父容器 frame 可能还是旧值 / 零值；子视图以
初始 frame（很多系统控件带默认尺寸）先画一帧，下一轮 layout 才排正。这个「错位的一帧」在
无裁剪容器里就外溢。

### 2.2 规范

- **先排好再嵌**：显示后调一次 view.layoutSubtreeIfNeeded()，再 addSubview 复杂子视图。
- 或父容器 masksToBounds，让那一帧即使越界也被裁掉（§0.1）。
- 嵌入用 **Auto Layout 约束**（leading/trailing/top/bottom = 父容器），不要用 frame，让
  后续重排自动收敛。
- **无头测试测不到**：stub（空视图）没有默认大 frame，复现不了「那一帧」。这类问题必须在
  真实渲染 / 真实运行验证（§5.3 / §6）。

---

## 3. 两套定位体系混用（Auto Layout vs autoresizing）与滚动 doc

### 3.1 系统控件默认还开着 autoresizing mask

NSButton / NSTextField / NSSegmentedControl 等的 translatesAutoresizingMaskIntoConstraints
**默认 true**（历史遗留）。给它们加显式约束却不关掉它，系统会同时生成「弹簧 / 支柱」约束
→ 冲突 → 视图跑到你以为之外的坐标（重叠 / 被盖 / 位置错乱）。

**真实现场**（round 9）：环节管理设置界面多个按钮重叠——若干 ActionButton 忘了设 false。
修复收敛到工厂统一处理（工厂第一行设 b.translatesAutoresizingMaskIntoConstraints =
false），调用点不再手写。

**规范**：
- 自定义控件的「工厂 / 初始化」统一关 autoresizing，不要在调用点每处手写。
- 新控件子类若用闭包回调（如 ActionButton.onAction 而非 target/action），按钮默认按压
  反馈要自行处理，别依赖系统行为。
- 凡用显式约束的视图，统一 translatesAutoresizingMaskIntoConstraints = false。

### 3.2 翻转容器 + 手动驱动文档高度

FlippedWorkspaceView（isFlipped = true）作滚动 documentView 时，内容比视口短时贴顶。
但内容高度**不会自动算出**——内容重建后必须用 fittingSize 回填 doc frame。核心序列：
stack.invalidateIntrinsicContentSize()，然后在 DispatchQueue.main.async 里取
stack.fittingSize，若高度>0 则把 stack 与 doc 的 frame 宽高都 setFrameSize 为
(max(fitting.width, scroll.contentView.bounds.width), fitting.height)，最后
view.layoutSubtreeIfNeeded()。

**真实现场**（round 9）：设置列表行按钮全部点不到——内容能画出来（容器不裁所以看得到），
但 doc 高度没被 fittingSize 驱动 → hitTest 落在陈旧 bounds 外 → 命中失败。修复：存
settingsDoc 引用 + 重建列表后异步回填。

**规范**：凡 FlippedWorkspaceView / 自绘 NSView 作滚动 documentView，内容重建后
**必须**驱动 doc 高度，否则「看得见点不到」。把这段封装成公共 helper，不要每处复制
（见 §7 待办）。

---

## 4. 可复用 / 反直觉的模式速查

| 场景 | 反直觉点 | 正确做法 |
|---|---|---|
| 容器裁剪 | 约束 ≠ 裁剪 | 内容容器 wantsLayer + masksToBounds |
| layer 隔离 | 子视图 wantsLayer 没用 | 隔离用**父容器**的 wantsLayer |
| isOpaque | 谎报「全填充」会溢出 | 根视图 isOpaque = false |
| 系统控件约束 | autoresizing 默认 true | 工厂统一设 false |
| 首次嵌入 | 显示瞬间塞子视图 | 先 layout 或父容器加裁剪 |
| 滚动 doc 高度 | fittingSize 不自动 | 手动回填 doc frame |
| 行宽拉伸 | 约束不撑满 | 子视图 widthAnchor == stack.widthAnchor |

---

## 5. 排查方法论（按性价比排序）

1. **替换二分**：把可疑视图换成纯色占位（NSView + 红底），看问题是否消失 → 锁定「哪个
   视图在溢出 / 被盖」（terminal-header-fix 用过）。
2. **父容器裁剪测试**：给「上一级容器」临时加 masksToBounds；问题消失 → 是子视图越界
   外溢；依旧 → 是合成 / 层级 / 约束定位问题。
3. **离屏真实渲染定位**：无头 stub 复现不了绘制问题。构造面板真实实例放进 NSWindow
   （可 off-screen），用 bitmapImageRepForCachingDisplay + 像素行扫描看「某 y 高度该是
   什么」——本次 Scaffold 编辑器 header 消失即由此定位。⚠️ 无标题窗口 contentView 上
   cacheDisplay 可能全黑，需真实 orderFront 或给背景视图喂色（见 §6）。
4. **frame dump 与渲染分开信**：frame dump 只证明「约束解出的逻辑位置」，证明不了「绘制
   是否越界」。二者矛盾时以真实渲染为准。
5. **约束冲突日志**：Auto Layout 打印 Unable to simultaneously satisfy constraints，
   看哪两条在打架（常是 autoresizing 没关）。

---

## 6. 离屏真实渲染定位工具（沉淀方向）

> 目标：把「构造控制器 → 放进窗口 → 渲染成 PNG → 像素扫描」沉淀成可复用脚本，避免每次
> 现场重写。当前位于 /tmp（未入库），建议抽到 scripts/ 或 tests/ui-render/。

要点：
- 实例化真实面板控制器，view 用约束 pin 到 NSWindow.contentView。
- cacheDisplay(in:to:) 需窗口真正合成过才非黑（styleMask 带内容、必要时 orderFront）。
- 像素扫描：每行平均亮度 + 方差（var 超阈值 ≈ 有文字 / 按钮），判断某 y 带该是什么。
- 无头测试的 stub 只保证「引擎逻辑 + 编译」，不保证「绘制不越界」。
- 复用素材：诊断用 stubs 见 tests/terminal-emulator/stubs.swift；离屏渲染要补
  CodeEditorView 桩或用真实 CodeEditorView.swift + vendor/Highlightr/*.swift。

---

## 7. 待办 / 持续积累区

> 新踩的坑、新提炼的规范：追加到对应章节，并在此登记一条（编号递增）。

- [ ] 把 §3.2 的 doc 高度驱动封装成公共 helper，替换 workspace / params / settings 三处手写。
- [ ] 把 §6 的离屏真实渲染定位脚本抽成可复用工具入库。
- [ ] 审视 FilePanel / WikiPanel / ChannelPanel 是否也有「显示瞬间嵌 CodeEditorView」/ 无
      裁剪内容容器，按 §0.1 统一补 masksToBounds。
- [ ] 全仓库扫描「addSubview 复杂子视图与 isHidden = false 同行」的写法，按 §2 治理。

---

## 8. 版本 / 来源

| 来源 | 涉及 |
|---|---|
| round 10 —— Scaffold 编辑器 header 被 CodeEditorView 内容覆盖 | §1.1、§2、§5.3、§6 |
| round 9 —— Scaffold 环节管理三 UI bug（按钮重叠 / 列表点不到 / 标题被盖） | §3.1、§3.2 |
| docs/terminal-header-fix.md —— Terminal header 被白块盖住 | §1.2、§5.1 |
| 各面板 isOpaque = false 根视图 | §1.3 |
