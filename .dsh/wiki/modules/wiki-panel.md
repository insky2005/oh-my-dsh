---
title: 模块：WikiPanel.swift（Repo Wiki 面板）
tags: [module, wiki, knowledge-base, rpc, skill]
updated: 2026-08-15T12:19:42Z
sources: [src/WikiPanel.swift, docs/repo-wiki-design.md, .dsh/skills/repo-wiki/SKILL.md]
manual: false
---

# 模块：WikiPanel.swift（Repo Wiki 面板）

约 1968 行。实现设计文档 `docs/repo-wiki-design.md`（M1–M3 已落地，见 §14）：仓库知识库的**生成**（触发 dsh 代理执行 `repo-wiki` skill）、**维护**（增量更新/陈旧检测/manual 保护/AGENTS.md 注册块/自动更新询问）、**浏览**（页面树 + markdown 渲染 + backlinks）。

## 组成（按文件内顺序）

| 类型 | 职责 |
|---|---|
| `WikiPaths` | UserDefaults 键（`wikiRootMode`/`wikiAutoRegenerate`/`wikiRegisterAgentsMd`）；`wikiRoot(for:)`（in-repo `.dsh/wiki` 或 `$DSH_HOME/repo-wiki/<hash12>`，hash = FNV-1a 64）；`stableHash` |
| `WikiFrontmatter` | YAML frontmatter 解析（`title/tags/updated/sources/manual` 键值对）与 bool/date 读取 |
| `WikiPage` | `path / title / tags / updated / sources / manual`，`displayName` 取 title |
| `WikiScanner` | 扫描 wiki 根：收集页面（排除 `_meta/` 与 `manual: true` 处理）、`computeStale`（页面 `updated` vs `sources` 最新 mtime）、`buildBacklinks`（扫描页内相对链接）、`signature`（路径→mtime 快照，供变更检测） |
| `WikiMarkdownRenderer` | 轻量 markdown → `NSAttributedString`：标题、粗/斜体、行内+围栏代码、有序/无序列表、链接、引用、分隔线；**软换行用 U+2028 行分隔符**（不触发 NSTextView 段落间距），列表项间补 `\n`；`internalURL` 生成 `dshwiki://` 页内链接 |
| `WikiSkill` | `ensureInstalled`：把内嵌的 `repo-wiki` SKILL.md 写入 `<repoRoot>/.dsh/skills/repo-wiki/SKILL.md` |
| `WikiPrompts` | 生成/更新/重建 index 的触发文案（中英），含 skill 缺失时的 `fallbackInstructions` |
| `WikiRPC` | `resolveWorkspaceId`（`workspace.list` 按规范化路径匹配工作区）、`createSession(port:cwd:workspaceId:)`（有匹配工作区传 `workspaceId`，否则回退 `cwd`）、`prompt(port:sessionId:text:)`（mode: queue）、`sessionRunning(port:sessionId:)`、`attachOrphans`（`workspace.insertSessionBefore` 把仓库未分组会话归入工作区，幂等 + 30s 节流）、`cancel(port:sessionId:)`（`session.cancel`），均走 `client-request` 信封 POST `/api/session.*` / `/api/workspace.*` |
| `WikiAgentsMD` | AGENTS.md 注册块**幂等**写入/移除（`<!-- repo-wiki:managed --> … <!-- /repo-wiki:managed -->`） |
| `WikiRootView` | 面板根视图（`isOpaque = false` 自绘背景，镜像 `TerminalRootView`） |
| `WikiPanelController` | 面板 UI 与生成链路（见下） |

## WikiPanelController 关键行为

- **布局**：头部（生成按钮「+」/ 在 Finder 显示 / 默认应用打开 / 关闭）+ 搜索工具行（标题过滤）+ `NSSplitView`（左：分组页面树 `NSOutlineView`；右：`NSTextView` 渲染页 + backlinks 页脚）+ 状态条（生成中/失败/服务未就绪）；
- **加载**：`ensureWikiLoaded` → `resolveAndLoad`（经 `DSHSessionRPC` 解析 repoRoot → `WikiPaths.wikiRoot`）；`serverReady(port:)` 门控（服务未就绪时延后加载/禁用生成）；`reloadRoot()` 供 `wikiRootMode` 切换；
- **变更监听**：2s 轮询 `WikiScanner.signature` 比对（`refreshIfChanged`）；`maybeAutoRegenerate`：≥3 页过期且距上次生成 > 1h 才自动触发（每小时最多一次，默认关）；
- **自动更新询问**（build 49→50）：首次生成成功且用户从未显式选过自动更新时，弹窗「开启自动更新知识库？」（开启/暂不），选择经 `onAutoUpdateSettingChanged` 同步设置菜单勾选；`serverReady` 时即使面板未打开也后台解析仓库根 → 2s 监控常驻——检测到「需要更新」时：设置**开** → 静默自动增量更新；设置**关** → 弹窗询问「检测到 %d 个页面可能过期，是否现在增量更新？」（同样每小时至多一次）；
- **生成链路**：`generateTapped` → `startGeneration(.generate/.update/.rebuildIndex)` → 确认 `WikiSkill` 已装 → `WikiRPC.resolveWorkspaceId`（把生成会话归入当前工作区，见上）→ `createSession(cwd:workspaceId:)` → `prompt(mode: "queue")` → `startPolling`（轮询 `session.list` 该会话 `running` 标志）→ 完成时刷新 + `attachOrphans`（归拢该仓库既有未分组会话）+ 可选 `WikiAgentsMD.register`（若设置开启）；**按仓库并发**（build 59→60）：在途生成存 `generations: [canonicalRepo: Generation]`，单个共享轮询定时器遍历结算（AGENTS.md 注册/首生成询问/失败提示只作用于被结算且当前可见的仓库），`syncGenerationUI()` 每次扫描/切换/生成事件调用——当前仓库在生成 → 遮罩 + 「+」禁用；别处在生成 → 无遮罩、状态条显示「正在为「仓库名」生成知识库…」、「+」可用；全部结束 → 隐藏状态条；
- **生成中浮层**（build 56→61 收敛）：历次实现（spinner 栈 / Core Graphics 自绘 `WikiCenteredLabel` / NSTextField 栈）要么渲染失败、要么清空阅读区后提示失败导致整片空白；最终方案——`showGenerating()` **不清空任何内容**，在阅读区上叠加半透明浮层（`WikiOverlayView`，随明暗 0.82 透明度背景、非 opaque、背景绘制失败自动退化透明）+ 居中 `NSTextField`「Generating…」（空态同款已验证渲染）；底部状态条每秒刷新已耗时（`wiki.generatingElapsed`）；生成期间 2s 轮询**不再跳过**——代理每写出一页，左侧树即实时出现该页；完成/失败/取消后 `scanAndReload` 清空子视图时浮层自动移除；「取消」走 `WikiRPC.cancel`（`session.cancel`）并显示「已取消」3 秒；失败/取消后都 `refresh()` 恢复内容区；
- **陈旧/手动标记**：树节点与页头显示「可能过期」（⚠）/「手动维护」（✎）；`manual: true` 页代理永不覆盖；
- **渲染与导航**：`showPage` 渲染 frontmatter 摘要条 + markdown 正文 + backlinks 区；`textView(_:clickedOnLink:)`：`dshwiki://` 页内跳转，其余交默认浏览器。

## 与其他模块的关系

- L10n 文案键 `wiki.*` 在 main.swift 的 `L10n.table`；设置菜单 wiki 组（自动更新 / AGENTS.md 注册块 / 根目录单选）由 AppDelegate 转发到 `WikiPaths` + `wikiPanel.reloadRoot()`；
- 复用 PreviewPanel.swift 的共享 UI 组件（`CustomIconButton`/`DynamicFillView`/`HeaderLabel` 等）；
- 生成由 dsh 代理执行（`session.create`/`session.prompt`），壳层只做触发 + 呈现，不解析代码；
- 会话切换时壳层调用 `reloadRoot()`（跟随共享 `ProjectDirectory` 重新解析根目录 + 重扫）。

## 已知取舍与修复（v1.7.0，设计文档 §14）

- `_meta/lock` 文件锁未实现（以面板内 `generating` 标志防重入，单窗口足够）；
- QMD 语义检索**暂不整合**（设计第 13 节，仅保留候选方案）；
- v1 搜索为标题过滤（无正文/语义检索）；
- §14 共记录 14 轮修复（build 43→61）：修复 1 顶栏合成、2 分割线/背景统一、3 生成体验（build 47→48）、4 工作区归组（48→49）、5 自动更新询问（49→50）、6 会话跟踪（50→51）、7 跟踪信号补强（51→53）、8 树宽 160（53→54）、9 U+2028 换行（54→55）、10 生成中提示渲染方式（56→57）、11 叠加浮层（57→58）、12 状态条合成溢出根因（58→59）、13 生成状态按工作区关联（59→60）、14 终端新会话目录跟随（60→61）；详见设计文档；
- 目录树宽度与预览面板统一：初始 160pt、拖动最小值 160pt（`applyInitialTreeWidthIfNeeded` + `constrainMin` 90→160）；
- markdown 换行（build 54→55）：段落内软换行改用 U+2028 行分隔符（`\n` 在 NSTextView 中是段落边界，会触发 `paragraphSpacing`），列表项间补 `\n`；单测新增「软换行非段落边界」「列表项分行」断言（39 → 41 项，已跑通 41/41）。
