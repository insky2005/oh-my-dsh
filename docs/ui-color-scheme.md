# 壳层 UI 配色方案（oh-my-dsh 原生面板）

> 适用范围：`platforms/macos/src/` 下所有原生面板（文件 / 终端 / 浏览器 / Wiki /
> 任务 / 通道 / 审查 / 技能 / 工程脚手架）及其共享基件。
> **单一事实来源**：`platforms/macos/src/PanelSurface.swift`——改色只改这一个文件。
> 对应提交：`9cf1f1b`（面板底色）· `40a4377`（控件两档）· `5d659c5`（列表内容区修正）
> 最后更新：2026-09-21（纳入工程脚手架面板）

一句话：**壳层只用一套灰阶**——面板底色一档 + 控件两档（常态 / 高亮），全部取自
dsh web 的 `neutral bluish` 设计令牌，深浅两套主题一一对应。

---

## 1. 设计原则

1. **来自同一套设计令牌**：6 个表面色全部是 dsh web 调色板 `--dsw-static-neutral-bluish-*`
   里的档位，壳层与 dsh web 界面天然同调。
2. **两级表面 + 一档高亮**：面板底色（最底）→ 控件常态 → 控件高亮（hover / 按下 / 选中）。
   不再出现"每个面板各写一档灰"的历史局面（旧值 0.20/0.22/0.235/0.28/0.32/0.86/0.94/0.96…）。
3. **显式分档，不用动态系统色做自绘填充**：自绘 `draw(_:)` 一律用
   `PanelSurface.color(dark:)` / `PanelControl.fill(dark:highlighted:)` 按
   `effectiveAppearance` 显式取色——动态色在 layer-backed 窗口里解析不稳
   （见 [terminal-header-fix](terminal-header-fix.md)）；只有 `NSTextView` /
   `NSScrollView` / `PDFView` 这类系统视图才用 `*.dynamic` 动态色。
4. **CALayer 背景不吃动态色**：`layer.backgroundColor` 是 CGColor 快照，必须用
   `fill(dark:highlighted:)` 显式解析，并在 `viewDidChangeEffectiveAppearance` 里重设。
5. **语义色不属于表面色**：accent / 绿 / 橙 / 红 / 蓝气泡 / 链接仍是语义色，见 §5，
   不参与灰阶替换。
6. **系统绘制控件不强改**：NSButton bezel、NSSegmentedControl、NSSearchField、
   NSMenu、标题栏、表格隔行条纹仍由 AppKit 画，见 §6。

---

## 2. 颜色令牌

### 2.1 表面色（`PanelSurface.swift`）

| 令牌 | 语义 | 深色 | 浅色 | dsh 令牌名 |
|---|---|---|---|---|
| `PanelSurface.dark` / `.light` | **面板底色**：顶部区（header 40pt / toolbar / status bar）+ 内容区 | `#1B1B1C` | `#F9FAFB` | `--dsw-static-neutral-bluish-900` / `-50` |
| `PanelControl.darkNormal` / `.lightNormal` | **控件常态**：卡片 / 按钮 / 页签 | `#43454A` | `#FFFFFF` | `--dsw-static-neutral-bluish-750` / `-00` |
| `PanelControl.darkHighlight` / `.lightHighlight` | **控件高亮**：hover / 按下 / 选中（toggle on、当前页签、当前选择） | `#353638` | `#F1F3F5` | `--dsw-static-neutral-bluish-800` / `-75` |

两套取色 API：

| API | 用途 |
|---|---|
| `PanelSurface.color(dark:)` / `color(for:)` | 自绘 `draw(_:)`（显式分档） |
| `PanelSurface.dynamic` | 系统视图背景（`NSTextView` / `NSScrollView` / `PDFView` / `NSTableView`） |
| `PanelControl.fill(dark:highlighted:)` / `fill(for:highlighted:)` | 自绘控件、CALayer 背景（显式分档） |
| `PanelControl.dynamic(highlighted:)` | 需要动态色的系统视图 |

### 2.2 参考：dsh `neutral bluish` 灰阶（本项目用到的档位）

```
00 #FFFFFF   ← 浅色·控件常态
50 #F9FAFB   ← 浅色·面板底色
60 #F5F6F7
75 #F1F3F5   ← 浅色·控件高亮
100 #EBEEF2
150 #E9ECF2
200 #E1E5EE
300 #CFD3D6
400 #ADB2B8
500 #979DA6
600 #81858C
700 #61666B
750 #43454A  ← 深色·控件常态
800 #353638  ← 深色·控件高亮
850 #2C2C2E
875 #232324
900 #1B1B1C  ← 深色·面板底色
950 #151517
1000 #0F1115
```

> 需要新增档位（例如更强的分隔线）时，**优先从这个灰阶里挑**，而不是新写一个
> `calibratedWhite` 值。

---

## 3. 层级与方向

控件永远比它所在的表面**亮一档**；高亮永远是**比常态暗一档**（两套主题同向）。

| 主题 | 面板底色 | 控件高亮 | 控件常态 | 观感 |
|---|---|---|---|---|
| 深色 | `#1B1B1C` | `#353638` | `#43454A` | 底色最暗 → 控件凸起变亮 → 按下/选中压回中间 |
| 浅色 | `#F9FAFB` | `#F1F3F5` | `#FFFFFF` | 底色微灰 → 控件纯白凸起 → 按下/选中略灰 |

```
深色                                   浅色
┌──────────────────────────────┐       ┌──────────────────────────────┐
│ #1B1B1C  面板底色             │       │ #F9FAFB  面板底色             │
│  ┌────────────┐              │       │  ┌────────────┐              │
│  │ #43454A 卡片/按钮/页签·常态 │       │  │ #FFFFFF 卡片/按钮/页签·常态 │
│  │  ┌────────┐               │       │  │  ┌────────┐               │
│  │  │#353638 │ hover/选中    │       │  │  │#F1F3F5 │ hover/选中    │
│  │  └────────┘               │       │  │  └────────┘               │
│  └────────────┘              │       │  └────────────┘              │
└──────────────────────────────┘       └──────────────────────────────┘
```

---

## 4. 应用映射（谁用哪个令牌）

### 4.1 面板底色 `PanelSurface`

| 位置 | 实现 |
|---|---|
| 面板 header / toolbar / status bar | `DynamicFillView()`（`Kind` 默认 `.panel`），各面板 `buildUI()` |
| 面板根视图 | `TerminalRootView` / `WikiRootView` / `ChannelRootView` / `SkillsRootView` / `IssueRunnerRootView` / `ReviewRootView` / `BrowserRootView` / `ScaffoldRootView` |
| 面板内容容器 | `contentContainer`（终端 / 通道 / 技能 …），`DynamicFillView()` |
| 活动栏（最左图标条） | `main.swift` `activityBar` |
| 终端屏幕底 + 反色单元格默认色 | `TerminalView.draw` / `effectiveCell` |
| 浏览器页面底（about:blank 等透明页）+ DevTools 区 | `BrowserPanel.updatePageBackground`（layer 背景，显式解析） |
| 文件/预览：文本、图片、PDF、目录列表 | `NSScrollView.backgroundColor` / `NSTextView` / `PDFView`（`PanelSurface.dynamic`） |
| 代码编辑器（含行号栏底色） | `CodeEditorView` `NSTextView.backgroundColor` |
| Wiki 阅读区 | `WikiPanel.showPage`（scroll + textView） |
| Review「纸张」 | `ReviewInk.paper` |
| 列表内容区：任务列表 / Wiki 页面树 / 文件目录树 / 脚手架预览文件树 | `NSTableView` / `NSOutlineView.backgroundColor = PanelSurface.dynamic` |

### 4.2 控件两档 `PanelControl`

| 控件 | 常态 | 高亮（hover / 按下 / 选中） | 实现 |
|---|---|---|---|
| 图标按钮（各面板 header、活动栏、页签「+」/✕、通道解绑） | `#43454A` / `#FFFFFF` | `#353638` / `#F1F3F5` | `HoverButton`、`CustomIconButton`（`hoverColor` 覆盖保留，如页签关闭按钮的红色） |
| 页签标题（文件 / 预览 / 终端） | 常态档 | 选中（`state == .on`）或 hover → 高亮档 | `PanelTabButton`（无 bezel 的 `HoverButton`） |
| 浏览器多标签页签 | 常态档 | 活动或 hover → 高亮档 | `BrowserTabItemView` |
| 技能面板扁平页签（级别筛选 / registry 选择） | 常态档 | 选中或 hover → 高亮档（另加 accent 下划线标记选中） | `SkillTabItemView` |
| 卡片：技能卡（含候选卡 / registry 卡） | 常态档 | 选中卡 → 高亮档 + accent 边框 | `SkillCardView` |
| 卡片：通道 header 块、会话块 | 常态档 | 会话标题条 → 高亮档 | `RoundedBlockView`（`ChannelHeaderBlock` / `ChannelSessionRow`）/ `SessionTitleBar` |
| 卡片：通道配置卡 | 常态档 | — | `ChannelCardView` |
| 卡片：审查树 | session / turn 容器 → 常态档 | 最内层 block → 高亮档 | `ReviewInk.sessionFill` / `.turnFill` / `.blockFill` |
| 消息气泡（中性 / 出站） | — | 高亮档（落在卡片底色上仍有对比） | `MessageBubble` |
| 卡片：脚手架环节卡 / 设置行 / 首页配置卡 | 常态档 | 选中卡 → 高亮档 + accent 边框 | `ScaffoldStageCard` / `StageSettingsRow` / `PresetSettingsRow` / `WorkspaceStageCardView`（`ScaffoldColorScheme.cardFill` / `cardBorder`） |
| 步骤时间线胶囊（脚手架向导） | — | 当前步骤 → 高亮档 | `ScaffoldStepItem`（`ScaffoldColorScheme.stepPillFill`） |
| 环节编辑器的文件页签 | 常态档 | 选中 / hover → 高亮档 | `PanelTabButton`（同文件 / 预览 / 终端页签） |

---

## 5. 语义色（**非**表面色，保持系统语义）

| 用途 | 取值 | 位置 |
|---|---|---|
| 选中 / 强调（当前页签下划线、技能选中卡边框、Review「当前会话」标记） | `NSColor.controlAccentColor`（跟随系统强调色） | `SkillCardView` / `SkillTabItemView` / `ReviewInk.currentSession*` |
| 通道状态点 | `.systemGreen` 已连接 · `.systemOrange` 重连 · `.systemGray` 未配置（另配 tooltip 文案，颜色不是唯一信号） | `ChannelCardView.updateStatusDot` |
| diff / 失败 | `.systemGreen` 新增 · `.systemRed` 删除 · 任务失败标题 `.systemRed` | `ReviewInk.added/removed`、`IssueRunnerPanel.populateCell` |
| 入站消息气泡（对方） | 深 `rgb(0.16,0.30,0.55)` · 浅 `rgb(0.84,0.91,1.00)` | `MessageBubble` |
| 链接 | `.linkColor` | Wiki markdown 渲染 |
| 正文 / 次要 / 弱化文字 | `.labelColor` / `.secondaryLabelColor` / `.tertiaryLabelColor` | 各面板标签 |
| 自绘 header 文字 | 深 白 0.78 · 浅 黑 0.38 | `HeaderLabel` |
| 自绘图标（按钮 glyph） | 深 白 0.90 · 浅 黑 0.25 | `CustomIconButton` |
| 活动栏 / 面板图标 | 深 白 0.80 · 浅 黑 0.30–0.35 | `BakedIconView` / `ActivityBarButton` |
| 卡片描边 | 技能卡 深 白 0.38@0.7 · 浅 黑 0.18；通道 header 深 白 0.42@0.5 · 浅 黑 0.30@0.6；会话卡 深 白 0.38@0.5 · 浅 黑 0.22@0.7；通道卡 深 白 0.35@0.6 · 浅 黑 0.20@0.8 | 各卡片 `draw` |
| 审查树分隔线 | 深 白 0.38@0.7 · 浅 黑 0.20 | `ReviewInk.hairline` |
| Wiki「生成中」遮罩 | 深 黑 0.15@0.82 · 浅 白 0.97@0.82 | `WikiOverlayView` |
| 终端 ANSI | xterm 16 色 + 256 色立方 + 灰阶（默认前景 `textColor`，默认背景 = 面板底色） | `TerminalEmulator.basePalette` / `palette256` |
| 代码高亮 | Highlightr 主题 `atom-one-dark`（深）/ `xcode`（浅） | `CodeEditorView` |
| 启动遮罩 | `.windowBackgroundColor` | `main.swift` `buildStatusOverlay` |
| 脚手架：步骤徽标 / 勾选徽标 | 未到 `.systemGray` · 当前 / 勾选 `.controlAccentColor` · 已完成 `.systemGreen` · 报错 `.systemRed` | `ScaffoldColorScheme.stepBadgeFill` / `checkTint` |
| 脚手架：环节类型徽标 | 自定义·已修改 `.systemOrange` · 自定义·新建 `.systemBlue`（内置走次级文字档） | `ScaffoldColorScheme.typeBadgeTint` |
| 脚手架：步骤标题 / 卡片描边 | 标题 深 白 0.78 / 0.95 / 0.80 · 浅 黑 0.38 / 0.12 / 0.30（未到 / 当前 / 已完成）；卡片描边 深 白 0.35@0.6 · 浅 黑 0.20@0.8，选中 = accent | `ScaffoldColorScheme.stepTitle` / `cardBorder` |

---

## 6. 系统绘制、未纳入本方案

这些由 AppKit 按系统外观 / 强调色自行绘制，壳层不覆盖（要覆盖就得换成自绘控件，
属于独立工作量）：

- `NSButton(.rounded)` / `.checkbox`：审查面板展开折叠、通道向导主次按钮、
  任务行内按钮、终端「新建 / 重启」；
- `NSSegmentedControl`（技能面板安装态切换）、`NSSearchField`（Wiki 搜索）；
- 表格**隔行条纹** `usesAlternatingRowBackgroundColors`（文件 / 预览的目录列表）；
- `NSMenu`、窗口标题栏、滚动条、`NSAlert`、文本光标与选区。

---

## 7. 落地规则（新面板 / 新控件必读）

**取色**

1. 面板根视图、header、toolbar、status bar、内容容器 → `DynamicFillView()`（默认 `.panel`）；
2. 系统文档视图（`NSTextView` / `NSScrollView` / `PDFView`）→ `PanelSurface.dynamic`；
3. **列表内容区（`NSTableView` / `NSOutlineView`）必须显式
   `backgroundColor = PanelSurface.dynamic`**——表格自带不透明的
   `controlBackgroundColor`（浅色纯白 / 深色近黑）会盖住面板底色，而
   `scrollView.drawsBackground = false` 只让滚动的**外壳**透明，管不到表格本身；
4. 卡片 / 按钮 / 页签 → `PanelControl.fill(dark:highlighted:)`；自定义按钮直接继承
   `HoverButton`（NSButton 系）或 `CustomIconButton`（自绘 glyph 系）即自动获得两档；
   页签标题用 `PanelTabButton`；
5. CALayer 背景：`PanelControl.fill(dark:highlighted:).cgColor`，
   并在 `viewDidChangeEffectiveAppearance()` 里重设 + `needsDisplay = true`。

**绘制陷阱**

6. 不透明自绘视图必须 `bounds.intersection(dirtyRect).fill()`——AppKit 会递上比
   bounds 更大的 dirtyRect，直接 fill 会盖住 z 序更低的兄弟视图（技能面板 header
   消失过，见 `tests/skills-panel/render-tests.swift`）；
7. opaque 且无独立 layer 的视图，绘制会溢出到父视图 layer（见
   [terminal-header-fix](terminal-header-fix.md)：contentContainer 需
   `wantsLayer + masksToBounds`）；
8. 新增令牌一律加在 `PanelSurface.swift`，不要在面板里写死灰度；
9. 面板内的"哪个控件用哪一档"就近收敛成一张纯函数表，别散在各自的 `draw(_:)` 里
   （审查面板 `ReviewInk`、脚手架面板 `ScaffoldColorScheme`）——这样能无头断言，
   也不会再出现同一面板卡片深浅不一的情况。

---

## 8. 验证

- `tests/skills-panel/run.sh` 的离屏渲染回归（真实 `DynamicFillView` / `HoverButton`）：
  断言 6 个令牌的取值、按外观取档、以及 `.panel` / 按钮常态 / 按钮选中**实际渲染**出的
  像素颜色等于令牌值（深浅两种外观各一条）；
- `scripts/local-ci.sh swift`：全部无头面板用例 + `swiftc` 全量编译检查；
- `tests/scaffold-panel/run.sh` 的「配色」段：断言脚手架面板的取色映射
  （面板底色 = `PanelSurface`、卡片常态 / 选中 = `PanelControl` 两档、语义色不参与灰阶替换、
  深色走白档 / 浅色走黑档）——改这些映射时测试会先失败。

---

## 9. 待定事项

| 项 | 说明 |
|---|---|
| 目录列表隔行条纹 | 文件 / 预览面板的目录列表仍开 `usesAlternatingRowBackgroundColors`（行级样式），若要求内容区是纯面板底色可关掉 |
| 系统 bezel 控件 | 见 §6；如需统一需改自绘按钮 / 分段控件 |
| 文字与描边尚未令牌化 | 目前散落在各面板（§5 后几行）；建议后续收敛为共享的 `PanelInk`（文字 / 图标 / 描边各两档）——审查 / 脚手架面板已各自收敛成面板内的 ink 表（`ReviewInk` / `ScaffoldColorScheme`） |
| 深色下"高亮比常态暗" | 按既定取值实现（`#43454A` → `#353638`）；若希望高亮更亮，改 `PanelControl.darkHighlight` 一处即可 |
| 终端 ANSI / 代码高亮主题 | 有意不纳入灰阶方案（属于内容语义色） |
