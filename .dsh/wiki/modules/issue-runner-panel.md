---
title: 模块：任务面板（Tasks / IssueRunner）
tags: [module, tasks, github, issue, queue, index, manual-task]
updated: 2026-10-01T15:57:16Z
sources: [platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/TasksCore.swift, platforms/macos/src/TasksStore.swift, platforms/macos/src/TasksWorkspaces.swift, platforms/macos/src/TasksRunner.swift, platforms/macos/src/TasksUI.swift, platforms/macos/src/TasksAPI.swift, platforms/macos/src/TaskCardView.swift, platforms/macos/src/TaskInlineForms.swift, platforms/macos/src/PanelSurface.swift, platforms/macos/src/DshWebRPC.swift, platforms/macos/src/BrowserAPI.swift, core/lib/tasks.js, core/lib/issues.js, core/lib/jobqueue.js, core/tests/tasks.test.js, tests/tasks-panel/, docs/design/panels/issue-runner-design.md, docs/design/shell/ui-color-scheme.md, docs/process/git-workflow.md, docs/design/panels/task-todo-skill-design.md, .dsh/skills/task-todo/SKILL.md, docs/design/panels/issue-runner-design.md, CHANGELOG.md, README.md, docs/process/dsh-version-impact.md]
manual: false
---

# 模块：任务面板（Tasks / IssueRunner）

## 一句话

任务台：**手动任务 + GitHub issue** 两种来源、**队列（泳道）** 严格串行执行，以**卡片列表**呈现。issue 任务点「处理」自动建一个**单任务队列**并跑完整闭环（切分支 → dsh 会话 → 提示词 → **只 commit**）；手动任务用「+」只填标题与描述（**面板内联表单，不弹对话框**），创建后落在**未入队**区，再从卡片上「加入队列 ▾」选已有队列或新建队列（同样是内联表单）。**push 与 PR 不在任务会话里**：队列跑完、开着「自动开 PR」且工作区是 GitHub 仓库时，运行器另起一个专门的「**开 PR 会话**」去做（见下）。

## 文件与分层

| 文件 | 职责 |
|---|---|
| `IssueRunnerPanel.swift` | 面板装配：卡片列表 / 队列头 / 内联表单接线 / 菜单 / 仓库识别 / issue 拉取 / GitHub REST / token |
| `TasksCore.swift` | **纯模型**：`TaskItem` / `TaskQueue` / `TaskBoard` / `TaskDraft` / `QueueChoice` / 分支命名 / 状态机（无 I/O、无 AppKit） |
| `TasksStore.swift` | `.dsh/tasks/` **四文件**读写（index / manual / queues / local），读侧容错、绝不删文件 |
| `TasksRunner.swift` | **运行器**：git 三步进入分支、dsh 会话、提示词、队列结束后的「开 PR 会话」、取消 · 重试 · 跳过、重启恢复（任务侧只 commit，不 push / 不开 PR） |
| `TasksUI.swift` | **视图模型**：`TaskCardModel` / `QueueHeaderModel` / `TasksSummaryModel` / `TasksEmptyStateModel` / `TaskComposerModel` / `QueueComposerModel`（纯 Foundation，可无头断言） |
| `TaskCardView.swift` | 视图：卡片 / 队列头 / 徽标 / 进度条 / 分节标题（只渲染与转发点击） |
| `TaskInlineForms.swift` | 视图：两张**内联表单**（新建·编辑任务 / 新建·设置队列）——无模态，字段与按钮状态由视图模型决定 |
| `TasksAPI.swift` | **纯模型**：任务面板的 localhost API 路由 `/api/tasks/list` 与 `/api/tasks/create`（请求解析、工作区解析、响应形状）；`BrowserAPIBridge` 的实现放在 `BrowserAPI.swift` |

分层意图：**规则在模型与视图模型里，视图只摆控件** —— 于是「徽标写什么、给哪个按钮、按钮是否可用」都能在没有窗口的环境里回归（tests/tasks-panel 第三段）。

## 本地 API（`/api/tasks/*`）与技能 `task-todo`（2026-09-27）

壳层的 localhost REST 服务（`BrowserAPIServer`，127.0.0.1，端口写 `$DSH_HOME/oh-my-dsh/shell-api.port` 与 `$DSH_HOME/oh-my-dsh/browser-api.port`——同一个端口）上多了**第二块路由面**：`/api/browser/*` 归浏览器面板，`/api/tasks/*` 归任务面板（`TasksAPIRouter` 命中即返回，未命中返回 nil，原路由与 404 都不受影响）。

- `GET /api/tasks/list?workspace=<路径>` → 面板现有的任务与队列；
- `POST /api/tasks/create` `{workspace?, focus?, tasks:[{title, body?} | "标题"]}` → 批量创建（上限 50 条），返回 `created`（逐条 id/标题）与 `rejected`（逐条原因：`empty-title`/`not-an-object`/`too-many`）；
- **工作区解析**（`TasksAPIWorkspace.resolve`，纯函数）：请求路径与面板当前/已跟踪 board 精确匹配 → 用它；否则取**最近祖先**（代理的 cwd 常在 workspace 子目录里）；都不匹配则原样交给调用方判存在性；没传就用面板当前 board。面板尚未 adopt 工作区 → `400 no-workspace`；服务在而面板没接好 → `503 panel-unavailable`；
- **落盘走面板自己的那条路**：`TasksRunner.createManualTask`（唯一入口，自带 persist 与日志），并且必须经 `BrowserAPIBridge` 派发到**主线程**——board 的读改写与 3 秒 step 定时器同一条线程，否则两个写者互相覆盖。任务一律「**待处理、未入队**」：建任务不启动任何东西；
- `focus` 默认 true：切到该工作区 board 并展开面板（`onShowPanel` → `setRightPanel(.tasks)`），状态行说一句「已由 Agent 创建 N 个任务」（L10n `tasks.apiCreated`）。

配套**内置技能 `task-todo`**（App 启动安装到全局 `$DSH_HOME/skills/task-todo/SKILL.md`，见 [skill-installer](skill-installer.md)）规定：**只在用户明确要求时**执行、先 list 再建（避免重复）、一次请求提交全部任务、并写明「不启动任务 / 不建队列 / 不直接改 `.dsh/tasks/*.json`」；App 没运行就报错请用户打开。设计见 `docs/design/panels/task-todo-skill-design.md`，回归 `tests/tasks-panel/api-tests.swift`（68 项）+ `tests/browser-panel`（把这块路由面一起编译）。

## issue 任务与手动任务对齐（2026-09-27）

两种来源**共用同一份提示词要求**（`TaskPrompts.requirements(branch:queueName:base:shape:)`），只有「头」不同：issue 头给**编号 + 标题 + 标签 + 正文**（此前只给编号与标题，正文还得代理自己去 GitHub 拉），手动任务头给标题 + 描述。于是 issue 任务同样**只 commit、不提 push/PR**、同样按工作区形状出条目、同样带队列交接简报。

- **为什么对齐**：issue 侧此前走一段写死的 5 条并要求加载 `issue-resolve` 技能，而那个技能停在旧政策（任务自己 `git push`、「PR 由面板创建」）——同一个面板里两种行为；
- **自动队列同形**：`TaskQueue.auto(for:baseBranch:switchesBranch:opensPR:)` 与 `auto(forManual:)` 同语义（非 git 目录里不再派生 `fix/issue-N`、不再承诺 PR）；两个入口共用 `dropUnswitchableBranch(ofTask:)`，旧队列带着切不了的分支时启动前先去掉；
- **`issue-resolve` 退役**：见 [skill-installer](skill-installer.md) 的退役清理与 `docs/design/panels/issue-runner-design.md` §V2-14；
- **回归**：`tests/tasks-panel` 三节 —— 两种来源的要求逐行逐字相同、非 git 目录里的 issue 任务不派生分支且能跑完、旧队列的陈旧分支被去掉（运行器 362 项）。

## 任务会话的收尾与卡片细节（2026-09-27 批次，PR #59 / #60）

- **汇报写回卡片**：任务结束（成功**或失败**）时壳层在收尾的后台步骤里取出代理在会话里的最后一段文字，写进 `TaskItem.report` 与 `local.json` 的 `reports`（机器作用域，**不写** `manual.json` / `index.json`）；卡片详情多一行「汇报」，队列里**下一棒的交接简报优先用它**（会话被删也还在，读不到才回落读会话日志），点「重试」会清掉上一轮的汇报；
- **队列信息只有一种抬头**：交接简报与开 PR 会话的上下文统一成 `## 队列信息`，字段顺序 = 队列（位次）→ 分支（基于 X）→ 分支上已有的提交 → 前面任务的汇报；
- **提示词按工作区形状现场生成**：`TaskRepoShape`（`.plain` / `.git` / `.github` 三态）在**写提示词的那一刻**重新探测（一次 `rev-parse --is-inside-work-tree`，是仓库才再问 `git remote -v`）——队列里前一个任务刚做的 `git init` / `git remote add`，后一个任务立刻就知道；要求条目按形状连续编号，token 条只在 GitHub 仓库出现；
- **「打开会话」点了没反应的根因**：`callAsyncJavaScript` 把参数变成**函数体里的局部变量**，而不带工作区名的调用（任务面板正是这种）没传 `workspaceName` → 页面抛 ReferenceError；现在 `workspaceName` **永远传**（没有就传空串）+ `typeof` 兜底，bridge 异常**立即**走 `reportOpenFailure`，并且说给**请求它的那个面板**（任务面板新增 `reportStatus(_:)`）；
- **卡片细节**：来源徽标（`手动` / `Issue #12`）排在**任务名后面**、状态徽标仍在最右；队列名前 `rectangle.stack`、任务名前 `checklist` 两枚静默行标（符号取不到时退化成 0 宽视图）；完成的 **issue** 任务主按钮是「打开 Issue」，完成的**手动任务没有主按钮**（`TaskCardModel.primaryKey/primaryAction` 因此变成可选）。

## 任务模型与状态机

- 状态：`pending`（不在任何队列）/ `queued` / `running` / `done` / `failed` / `cancelled` / `closed`（issue 已关闭）。v1 的 rawValue **全部保留**，旧 `index.json` 零迁移；
- id：github 任务 `issue-<N>`；手动任务 `manual-<8 位 hex>`；
- `TaskBoard` 是唯一真相：入队 · 移出 · 建/改/删队列 · 启动 · 完成 · 失败 · 取消 · 重试 · 跳过 · 重启恢复都经过它，面板只渲染与调用；
- **失败原因存 L10n 键**（`TaskFailure` 的 rawValue，如 `tasks.errDirtyTree`），显示时 `L10n.tr(error)` —— 语言切换与落盘索引都不会串味；旧索引里的本地化文本也能被 `L10n.tr` 原样返回；
- `TaskDraft` 校验新建任务的两个字段（标题、描述）都非空，空值给 `tasks.errName` / `tasks.errBody`。

## 队列（泳道）语义

- 同一队列的任务**共享一个分支、按 FIFO 顺序执行** → 后一个任务看得到前一个的 commit（**依赖关系由分支累积表达**，替代 v1 靠 checkout 失败碰运气）；
- **全局严格串行**：一个工作树同一时刻只能在一个分支上，所以队列之间也不并行；
- 队内任务失败 / 取消 → **暂停该队列**，后续任务留在 `queued`，卡片给「重试 / 跳过并继续」；
- 切到另一个队列前要求**工作区干净**（`git status --porcelain` 非空 → 拒绝启动、卡片标 `tasks.errDirtyTree`）；
- 队列分支：默认 `feature/<slug>`（纯中文 / emoji 名 slug 为空时回退 `feature/queue-<id 前 4 位>`），用户可改、可留空（= 不切分支）；
- issue 任务的「处理」= 自动建**单任务队列**（`autoCreated`，分支走 `fix/issue-N` / `feature/issue-N`；**非 git 目录不派生分支**，形状由 `TaskQueue.auto(for:baseBranch:switchesBranch:opensPR:)` 统一给）；重试复用同一个自动队列；
- 「全部处理」= 给**每个待办**各建一个单任务队列（**手动任务同样如此**——不再只管 issue），再按板面顺序串行跑（`focus(onQueue:)` 把运行器指回第一个队列）；>1 条时先弹确认框，**计数与「各自一条分支 / 是否开 PR」的说明只在确认框里**，tooltip 只说按钮做什么。判据收在一处：`TasksRunAllModel.startable(in:)` = 未入队 + **队列被删后的失败 / 已取消**（仍在队列里的失败不算——那是泳道自己的事）；
- **开 PR 会话**（2026-09-27 起，任务会话与 PR 彻底分家）：队内任务的提示词里**不再出现 push / PR**，运行器也不再校验 `git ls-remote`（`tasks.errNoPush` 与 `env.createPR` / 面板直连 GitHub API 的 `createPR` 一并删除）。队列最后一项完成、队列开着「自动开 PR」且工作区是 GitHub 仓库时，`TasksRunner.startQueuePR` 在仓库目录新建名为「**开 PR：<队列名>**」的 dsh 会话（相位 `.startingPR` / `.openingPR`，同样占用那个串行槽位），`TaskPrompts.pullRequest` 要它先读真实改动（`git log/diff`）、**自己写**标题与正文、push 分支、开或复用 PR，并在最后一行给链接；运行器从它的汇报里搜 `github.com/…/pull/N`，搜不到就用该分支已有的 PR 兜底，都没有就把原因记在队列上（`tasks.errPR` / `errPRNoBranch` / `errPRNoRemote` / `errPRSession`，显示在队列头「开 PR」按钮的 tooltip 里）——**队列保持已完成**，PR 开不出来从来不算任务失败。队列头的「开 PR」按钮走的也是这条路。

## 持久化（`<repo>/.dsh/tasks/`）

| 文件 | 作用域 | 内容 |
|---|---|---|
| `index.json` | **提交** | github 任务 ↔ issue / 分支 / PR / 状态（v1 形状，`version: 1`） |
| `manual.json` | 本机 | 手动任务：标题 / 描述 / 状态 / 队列 / 分支 / 错误 / 时间戳 |
| `queues.json` | 本机 | 队列：名 / 分支 / 基线 / `taskIds`（FIFO）/ 状态 / `autoCreated` / `autoPR` / `prUrl` |
| `local.json` | 本机 | `sessions`（task id → sessionId）+ `activeQueueId` / `runningTaskId` |

- **session 不入任务本体**：会话只在一台机器上有效，所以 github 与手动任务共用 `local.json` 这一份 overlay；
- `local.json` 的 session 键读侧**兼容 v1 的纯数字键**（`"6"` 视为 `issue-6`），写侧一律 task id —— 历史文件零迁移、读取时也不重写；
- `queue.taskIds` 是队列成员的唯一真相，任务上的 `queueId` 是冗余副本，载入时 `reindexQueueMembership()` 重新导出，两者不会漂移；
- 读取全程容错：文件缺失或损坏只得到空状态，**绝不删除或重写**。

## UI（卡片列表）

- 列表 = `NSScrollView + NSStackView`（项目面板体例），按**队列分区**：用户队列（队列头 + 队内卡片，默认展开）+ issue 任务的自动队列（默认折成**一行**，点开即展开）+ **未入队区**；
- 工具栏两行：第一行 = 工作区名 + 四个**计数胶囊**（队列 / 排队 / 运行 / 失败，全 0 时整条不显示，失败 > 0 变红）+ 工具行 `▶` **全部处理（第一位）** · `⟳` 刷新 · `⚙` GitHub Token · `✕` 关闭（另有「别的工作区有任务在跑」图标，仅在有任务时出现；计数胶囊**随来源筛选一起算**，`TaskBoard.summary(source:)`）；第二行 = 来源筛选**扁平页签**（**全部 / 手动 / Issue**，顺序只在 `TaskSourceFilter.allCases` 一处定义、标题由它生成）+ 右侧 `＋` 新建任务 / `▣＋` 新建队列两个图标按钮；
- 卡片：来源徽标（`Issue #12` / `手动`）+ 状态徽标（待处理 / 队列中 #n / 运行中 / 已完成 / 失败 / 已取消 / 已关闭）+ 标题（13pt semibold）+ 「标签 · 分支 · PR 短链」；**点卡片（非按钮处）展开 / 收起**详情（队列名 / 会话 / 错误 / 正文）与操作行（主操作文字按钮 + 编辑/删除**图标按钮**）；圆角 8、hover 提亮、展开与运行各一档强调边框；
- 队列头两行：名称 + 状态徽标 + **图标按钮**（开始 / 暂停 / 开 PR / `⋯`）／分支 `→` 基线 + **进度条** + `n/m` + 失败数；**不透明** highlighted 填充（`SessionTitleBar` 体例，不是半透明卡）；
- **宽度纪律**：卡片与队列块一律 `widthAnchor == listStack.widthAnchor - 20`（撑满列表），内部控件不得反向撑宽（可截断），由 `tests/tasks-panel/form-tests.swift` 的无窗口布局断言钉住（320pt 宽 → 恰好 320pt）；
- **队列 = 容器**（`TaskQueueBlockView`，审计面板树体例）：泳道用**下沉档**底色（`PanelControl.fill(highlighted: true)`）、边框随队列状态着色；队列头贴泳道内边距 10，队内卡片**再缩进一层**（18 / 12）并保持**抬起档**底色。折叠时泳道就只有它的头一行。测试断言"卡片左缩进 > 泳道头缩进、右缘不越出泳道"；
- **抽屉高度 = 纯约束跟随（不要再改成测量）**：`TaskFormSheetView.setContent` 里是 `sheet.heightAnchor == form.heightAnchor`（@999），面板只加"不高于内容区"的上限（required）。表单内部长高（高级设置展开、描述框变长）**在同一个布局回合**就把抽屉撑开；表单太高时上限生效、表单保持自身高度并内部滚动。**不要**回到"测量 frame / fittingSize + 回调"的写法：frame 只反映上一次布局，实测会滞后一整拍（展开时抽屉不动、收起时才长高）；
- **表单是内容区顶部的下拉抽屉（无 NSAlert，2026-09-25b/c）**：新建任务 / 编辑任务、新建队列 / 队列设置都是**从内容区顶部往下滑出的抽屉**（`TaskFormSheetView` + `TaskFormSheetHostView` + `TaskInlineForms.swift` 的内容视图 + `TasksUI.swift` 的 `TaskComposerModel` / `QueueComposerModel`）。宿主透明、`masksToBounds`；**点击策略随状态切换**（`blocksClicksBelow`）——没有表单时点击穿透（hitTest 落在宿主自身时返回 nil，列表照常可点），表单打开时整块吞掉点击（宿主自身收到点击不做任何事），避免点到抽屉背后被展开的任务卡片，只覆盖工具条以下、抽屉滑入时不画到相邻分栏也不挡列表点击；顶部距内容区 8pt，高度由内容决定并**硬上限 = 内容区高度 − 16**（超出时先压缩描述框并让其滚动，按钮永远在可见区）。**输入框：`controlSize = .large` + `roundedBezel`、高 30pt、字号 13pt，宽度 = 面板宽度 − 48**（每行都钉到表单宽度——空文本框的固有宽度几乎为 0，行贴合内容时输入框只有约 25pt）；
**输入框统一自绘框 `TaskFieldBox`**（圆角 6、下沉底色、发丝边框）：单行框是无 bezel 的 `NSTextField`，描述是**真正的 `NSTextView`**（同一只框），两者样式由构造保证一致。可编辑的 `NSTextField` **不能**当多行用——它的 cell 对任何高度都只报一行（实测 `cellSize(forBounds:)` 恒为 30pt，"加高的多行框"只是加高的单行框）。描述默认 120pt、随输入长高（上限 260pt），超过上限时文本视图自身长高并内部滚动；文本按可见宽度换行（文档视图宽度 == clip 宽度）、高度 ≥ clip 高度（否则只有一行可点）；
- **表单永不"缩小自己"，矮面板靠抽屉滚动**：抽屉（`TaskFormSheetView`）内含一个滚动视图，高度 = 表单自然高度（`idealHeight()` 测量，宿主每次 layout 重算），上限 = 内容区高度 − 16；超出即滚动，描述框保持 120pt。**不要**把抽屉高度约束到文档视图：AppKit 会让文档视图不低于 clip 高度，那条链会让上限失效（实测 240pt 内容区里塞进 304pt 表单）；
分支框的**空值语义分两种模式**（文案也必须分开，不要合成一句）：**新建**时空值 = 按队列名派生分支（`feature/<slug>`，无 ASCII slug 时 `feature/queue-<id4>`），队列照常切分支；**队列设置**里空值 = 不切分支（在当前分支上跑）。对应 L10n：`tasks.queue.branchPlaceholderCreate` / `tasks.queue.branchAuto` / `tasks.queue.branchPlaceholderEdit`。

**队列表单只问一件事**：只有「队列名」必填；分支 / 基于分支 / PR 开关在「高级设置」里（新建默认折叠、队列设置默认展开），**展开后仍有 274pt、正常面板高度下不出现滚动条**（分支/基于分支是"标签在左"的横排，高级设置内部间距 6；抽屉高度向上取整，避免差半个点闪出滚动条），折叠时用一行「将使用分支：feature/<slug>」讲结果，分支框 placeholder 即将要使用的分支；PR 开关在工作区非 GitHub 仓库时**隐藏**并换成一行说明（不再给灰掉点不动的勾选框）。新建任务提交后抽屉保持打开并清空（连续录入，「完成」/ Esc 收起），编辑保存后关闭；问题提示只在按过提交后出现；**只剩破坏性确认框**（删除任务 / 删除队列 / 评论并关闭 issue）；菜单仍有「加入队列 ▾」与队列头 `⋯`（队列设置… / 完成后自动创建 PR / 删除队列…）；
- **两个创建入口是页签行右侧的图标按钮**（右对齐）：「＋」= 新建任务、「▣＋」（`rectangle.stack.badge.plus`）= 新建队列，标签在 tooltip 里；面板头的 `+`、队列分区头的「新建队列」已删除（同一动作只留一个入口）；页签条对小宽度让位（`SkillTabStrip.setCompressible`），按钮不压缩；
- 列表重建用**指纹比对**（任务状态 + PR + 队列状态），3 秒的步进定时器不会打断滚动或关掉已弹出的菜单；展开状态记在控制器（`expandedTaskID` / `queueToggle`），卡片每次重建都不丢。

## GitHub token（按仓库作用域，只走文件）

- **只走文件（2026-09-24 起）**：Keychain 的读写代码已全部删除（`readKeychain` / `tokenService(for:)` / `SecItemAdd` / `SecItemDelete` 与两个 service 常量），`platforms/macos/src/` 下不再出现 `SecItem` / `kSecClass`；
- **解析顺序**：① 文件专属 `$DSH_HOME/oh-my-dsh/tokens/<owner>-<repo>` → ② 文件通用 `$DSH_HOME/oh-my-dsh/gh-token`；多工作区各用各的 token；
- **保存**：只写文件 —— 有当前仓库写专属文件，无仓库（非 GitHub 工作区）写通用文件；原子写 + `chmod 600`；清空即删文件；
- **兼容性**：旧版面板是「文件 + Keychain 双写」，通过面板保存过的 token 早已在文件里；仅更老构建或手工 `security add-generic-password` 写进钥匙串的条目不再被读取，需重填一次。

## 面板设置（全部按工作区隔离，2026-10-01）

面板的「⚙ 面板设置」抽屉把三类设置收在一处（L10n `tasks.settings.*`），**每一项都按工作区存**——同一个面板同时服务差异很大的目录（GitHub 仓库想要 PR、临时目录要直接推送、演示仓库绝不能自动关闭），一份全局值不可能都对。GitHub token 是唯一例外：它按**仓库**（同一仓库即同一凭据）。

| 设置 | 键（ShellConfig `config.json`） | 作用域 |
|---|---|---|
| 工作流默认（队列自身未覆盖时用它交付） | `tasksIntegrationByWorkspace`（工作区路径 → `QueueIntegration`） | 按工作区；队列自身的 `integration` 仍优先 |
| 交付成功后自动关闭队列 | `tasksAutoCloseOnPublishByWorkspace`（工作区路径 → Bool，未设置默认关） | 按工作区；旧全局键 `tasksAutoCloseOnPublish` 已弃用、不再读取（该开关未发布，无需迁移） |
| GitHub Token | `$DSH_HOME/oh-my-dsh/tokens/<owner>-<repo>` / `gh-token`（只走文件） | 按**仓库** |

- 路径键统一经 `workspaceSettingsKey(_:)` 归一化（`standardizingPath` + 去尾斜杠），带尾斜杠 / `..` 的写法不会生出第二条记录；
- `submitSettings` 保存时除落盘外还显式 `runner?.setDefaultIntegration` / `runner?.setAutoCloseOnPublish`——运行器的 env 在 adopt 工作区时快照，须告知本工作区的新值；因此改动只影响**当前工作区**，不泄漏到别的工作区；
- 抽屉说明与开关 tooltip 均写明「按工作区 / 只对当前工作区生效」（`tasks.settings.info` / `tasks.settings.hint` / `tasks.settings.autoCloseHint`）；
- 回归：`tests/tasks-panel/run.sh` 新增**源码守卫**——`IssueRunnerPanel.swift` 必须含 `tasksAutoCloseOnPublishByWorkspace` / `storedAutoCloseOnPublish(forWorkspace` / `workspaceSettingsKey`，且不得再出现全局键 `tasksAutoCloseOnPublish`，杜绝设置项退回全局。

## 集成点（main.swift）

- `RightPanel.tasks`（活动栏第 4 个图标 `checkmark.circle`、视图菜单 ⌥⌘J、`rightPanelKind` 持久化 `tasks`）；
- `tasksPanel.workspacePath` 跟随 `ProjectDirectory.current`；会话切换时壳层无条件调 `workspaceChanged()`；`serverReady(port:)` → 仓库识别 + issue 加载；
- **QA 钩子**：`DSH_TASKS_TEST=1` 启动即开面板；`DSH_PANEL_TEST="…,tasks,…"` 全量核对；`DSH_UI_DEBUG=1` 落 `~/Library/Logs/oh-my-dsh/panel-tasks-debug.png`；
- L10n：`tasks.*` 一组双语键（约 100 个，含 `tasks.source.*` / `tasks.card.*` / `tasks.queue.*` / `tasks.new.*` / `tasks.err*`）。

## 边界与失败处理

| 场景 | 行为 |
|---|---|
| 工作区不是 GitHub 仓库 | issue 区显示空态（不替换为其他已注册工作区）；**手动任务与队列照常可用**，开 PR 会话不启动（`tasks.errPRNoRemote`） |
| 工作区不是 git 仓库 | **任务照常能跑**：自动队列不派生分支（`env.canSwitchBranches=false`），提示词按 `TaskRepoShape.plain` 只说「壳层不切分支 / 不提交 / 不推送，直接在当前目录改文件即可；任务要求建仓库或提交就照做」；旧队列带着切不了的分支时启动前先去掉（`dropUnswitchableBranch`），卡片也给「不切分支并重试」 |
| 脏工作区 + 切队列 | 拒绝启动，任务 failed（`tasks.errDirtyTree`），队列暂停 |
| checkout / 拉取失败 | failed（`tasks.errBranch` / `tasks.errPull`），队列暂停（v1 会静默忽略这两个失败） |
| 建会话 / 提示词失败 | failed（`tasks.errSession` / `tasks.errPrompt`）；会话已建时仍把 sessionId 记进 board，可追溯 |
| 超时（**60 分钟**，`TaskRunnerEnv.defaultTimeout`，卡片元行里写明） | `session.cancel` + failed（`tasks.errTimeout`）+ 队列暂停 |
| PR 开不出来 | **不算任务失败**：队列保持已完成，原因记在队列上（`tasks.errPR` 一族），队列头的「开 PR」可再试一次 |
| App 重启 | 读四文件；上次 `running` 的任务标「已中断」（`tasks.errInterrupted`）、`active` 队列暂停、**不自动开跑**（须点「开始」） |
| 删除队列 | 未开始的任务回到未入队；**队列中有运行中任务时拒绝删除**；`QueueState.done` 的队列不再显示设置 / 删除 |
| 删除任务 | 手动任务在 `TaskState.isEditable`（未入队 / 队列中 / 失败 / 已取消）时可改可删，**运行中与已完成都不能**；github 任务不删（issue 才是记录） |

## 测试

- `tests/tasks-panel/run.sh` **1129 项**（五段：模型 176 + 运行器 362 + 视图模型 324 + 视图 199 + **本地 API 68**，2026-09-27 本机实测全绿），运行器段用**假 git + 假 dsh** 驱动完整流水线（含非 git 目录两问：无分支队列照常跑完 / 有分支队列报 `errNotGit`）；`run.sh` 另有**源码守卫**：建会话必须走 `DshWorkspaceOps`、运行器环境不许冻结端口、提示词必须现场探测工作区形状、两种来源共用同一份要求清单、开 PR 会话的参数写全；
- `core/tests/tasks.test.js` **18 项**（四文件读写 + 会话键兼容 + 队列入队/移出）；
- 已登记 `scripts/local-ci.sh` 的 `stage_swift` 与 `.github/workflows/ci.yml`（两处清单必须一致）。

## 已知问题 / 待办

- `.gitignore` 需含 `.dsh/tasks/manual.json` 与 `.dsh/tasks/queues.json`（本机文件，不应提交）；
- 阶段 2 预留：已完成队列归档 / 隐藏、队列模板、issue 任务进共享队列、PR 复用后追加评论、跨机器共享手动任务与队列（见 docs/design/panels/issue-runner-design.md §V2-13）。

## 历史（v1，v1.8.0+，方案 E）

issue 一行内展开、面板自己 `startTask` 切分支 / 建会话 / 轮询 / 开 PR、Swift 版 `TaskIndex` 写 index + local 两文件、token 曾「文件 + Keychain 双写」、列表是 `NSTableView`。决策过程见 docs/design/panels/issue-runner-design.md 的前半章（保留作历史记录）。
