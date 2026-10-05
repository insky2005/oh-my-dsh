# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions below
`v1.8.0` are summarized from the git history (conventional commits).

## [Unreleased]

### Added

- **驳回提示词改写（2026-10-04）**：④带原因 / ⑤无原因统一为 `RequirementsCore.rejectPrompt(_:title:reason:)`——`REQ-xxx「标题」@路径，需求拆解已驳回。`（**有原因才多一行 `驳回原因：…`**）`请修改拆解方案。` + 三条注意（只拆不胀 / 重新提交待确认提案并调拆解器 API / 提交后等待用户确认『待确认提案』）；提议 API 那一行抽成 `proposeAPIHint`，② 与 ④⑤ 共用，避免两处漂移。移除 L10n `requirements.notify.rejected` / `rejectedWithReason`。模型测试 **114 → 120**。

- **确认拆解提示词改写（2026-10-04）**：`requirements.notify.confirmed` 改为 `REQ-xxx「标题」@.dsh/requirements/REQ-xxx.md，需求拆解已确认。` + `生成事项：WS-…。` + 两条注意（回复『收到』/ 列出事项清单）；main 的 `notifyBreakdownResolved` 改为取整张需求卡（拿 title + session）再拼提示词。设计 §5.7 ③ 同步。

- **拆解提示词改写（2026-10-04）**：`breakdownPrompt` 改为 `REQ-xxx「标题」@.dsh/requirements/REQ-xxx.md，需求已确认。` 开头，正文「根据需求，将需求拆解为可依次落地的事项。请给出拆解方案：每个事项的标题、边界、依赖顺序。」+ 三条注意（只拆不胀 / 调拆解器 API 提交待确认提案 / **提交后等待用户确认『待确认提案』**）；为此 `breakdownPrompt` 增加 `title` 参数，面板 `onBreakdown` 与 `sendBreakdownPrompt` 一起传标题。设计 §5.7 ② 同步。

- **细化提示词改写 + 面板提示词汇总（2026-10-04）**：`refinementPrompt` 改为以 `REQ-xxx「标题」@.dsh/requirements/REQ-xxx.md` 开头，随后「请和我一起细化这条需求…」+ 三条注意（只讨论不改代码 / 改卡走 `/update` 带 session / **细化后等待用户拆解**）；设计新增 **§5.7 面板发出的提示词（单一事实来源）**，把 ①细化 ②拆解 ③确认 ④驳回（带原因）⑤驳回（兜底）五条全文集中一处，改措辞时必须同步。模型测试 **110 → 112**。

- **驳回拆解：原因抽屉 + 原因带进提示词（2026-10-04）**：点「驳回」不再直接丢弃提案，而是弹一个必填的**原因抽屉**（`RequirementRejectView` + `RejectReasonModel`，`⌘↩` 提交 / `Esc` 取消，空原因禁用提交）；提交后清提案并把原因拼进写回该需求会话的提示词（`requirements.notify.rejectedWithReason`），让 agent **按原因改**而不是作废。测试模型 **103 → 110**。

- **需求池状态徽标改为下拉（2026-10-04）**：**状态徽标本身可点**——`RequirementStateControl` = `TaskBadgeView` 药丸 + 尾部 **`chevron.down` 指示符号**（hover 手型、tooltip 显示当前人工状态），点击直接弹出人工状态菜单（候选 / 评估中 / 挂起 / 丢弃）；`RequirementStateControl` 自己认领点击并加入 `RequirementHeaderView` 的 `hitTest` 白名单（否则 header 会吞掉点击、误触折叠卡片）；**去掉单独的 `circle.dashed` 状态按钮**。菜单对齐壳层既有约定（`IssueRunnerPanel` / `FilePanel`）向下弹出（`y: -6`），**不遮挡状态徽标本身**。

- **需求池「拆解」按钮：加图标 + 拆解后隐藏（2026-10-04）**：按钮标题前加 **`square.split.2x2` 图标**；并且**仅在尚未拆解时出现**——已有子事项、存在待确认提案、或需求已 `discarded` 时隐藏（驳回提案或回到候选后会重新出现）。

- **需求池卡片交互修正（2026-10-04）**：**每张卡各自折叠**（需求卡 → 事项卡 / 提案卡）：① 点每张卡**自己的标题行**切换，`chevron` 只是指示器（不是按钮）；② **事项卡**收起 = 头部，展开 = 追加 阶段 / 结果 / 路径；③ **提案卡**收起 = `标题 + 依赖`，展开 = 追加**内容（边界）**；④ 需求卡收起时隐藏正文（事项 / 提案列表），meta 仍显示 `待确认拆解 N 项`。

- **需求池卡片改用任务面板的卡片语法（2026-10-04）**：需求卡 = **raised 块**（圆角 8 + 一条 hairline，`TaskInk`）；标题行 = `▸ 类型glyph REQ-id 标题 [需求][N 个事项] … 状态徽标 [拆解][状态][✎]`，**状态只进徽标**（tone：候选 neutral / 评估中·已拆分 running / 挂起 warning / 已关闭 positive，直接复用 `TaskBadgeView`）；诉求常显（收起 3 行）；**点卡片空白处展开/收起**——展开后是 **recessed 的「已拆解事项」mini 卡**（`WS-* 标题 [阶段] ↗`）与 **recessed 的「待确认拆解」块**（每条提案一张 **raised mini 卡**：`标题 — 边界 [依赖 N]`，右上确认 / 驳回）。`TaskCardView.swift` 的 `TaskInk` / `TaskBadgeView` / `taskRowGlyph` 直接复用，**不新增颜色令牌**。

- **需求池面板：想法收件箱 + 需求池 + 拆解器（2026-10-04）**：AI 原生工作流从手动模式升级为壳层能力。新增右栏第 10 个面板（活动栏第 5 位、任务之前，`tray.full`，`⌥⌘I`）：卡片按**有效状态**（`discarded > closed > split > state`，派生）展示需求，列出拆出的 `WS-*` 子事项（点击在文件面板打开）；头部「＋」用**抽屉**（首行标题 / 其余行诉求）落成 `.dsh/requirements/REQ-*.md`（`state: candidate`），也可由内置技能 `requirement-pool` 经 API 落卡。**拆解器**走「agent 出方案 / 人确认」：面板「拆解」复制交接提示词，agent 经 `POST /api/requirements/breakdown/propose` 提交 1..N 事项提案，**人**在面板「确认拆解」才生成 `WS-*.md`（`requirement` 回指、`stage: planning`）并留下映射表，agent 绝不调 `confirm`（R10）。实现：纯模型 `RequirementsCore.swift`（frontmatter 解析 / 派生 / 原子写）、纯路由 `RequirementsAPI.swift`（`/api/requirements/*`）、面板 `RequirementsPanel.swift`、技能 `requirement-pool`；`closed` 只读 `delivery.outcome` 缓存、不联网（网络派生仍归 `derive-status.mjs`）。测试 `tests/requirements-panel`（模型 61 + API 42）。

- **需求池面板：创建需求改抽屉 + 使用说明（2026-10-04）**：头部「＋」不再弹 `NSAlert`，改用与任务面板「新建任务」同款的**表单抽屉**（复用 `TaskFormSheetView` / `TaskFormKit`）——一个输入框，**首行 = 标题、其余行 = 诉求**（单行则两者相同），`⌘↩` 提交、`Esc` 取消；视图模型 `RequirementComposerModel`（纯 Foundation，`platforms/macos/src/RequirementsUI.swift`）可无头断言。右上角新增 **`?` 使用说明**按钮：抽屉里是「创建需求 / 拆解事项」两节，每节分「在面板」「在对话」两条**操作**（只讲操作，不讲结果），**池为空时同一份说明直接铺在内容区**（不必先点帮助）。测试 `tests/requirements-panel` 模型 **61 → 75**。

- **需求池面板：建需求按钮移到工具栏右侧（2026-10-04）**：头部只留 `[⟳] [?] [✕]`，下面新增一行 32pt **工具栏**（含底部分隔线，与任务面板页签行同形），「＋ 新建需求」**右对齐**放在工具栏右侧；使用说明与设计 / 使用文档同步。

- **需求池卡片：显示诉求内容 + 状态徽标后移 + 可编辑（2026-10-04）**：卡片现在显示 `## 诉求` 正文预览（最多 4 行，tooltip 全文）——agent 落卡的内容不再只活在文件里；**状态徽标移到标题之后**；新增**「编辑」**按钮，复用同一个抽屉预填标题 + 诉求，保存走 `POST /api/requirements/update`（只改 frontmatter `title` 与 `## 诉求`，状态 / 拆解提案 / 子事项都不动）。测试 `tests/requirements-panel` 模型 **77 → 93**、API **42 → 49**。

- **需求池：同一需求的对话始终落在同一个会话（2026-10-04）**：所有写接口（create / update / state / propose / confirm / reject）都接受 `session`，每次写把 `REQ-id` 重绑到**发起这次写的会话**；面板「拆解」用绑定会话，没有 / 失败才回退当前会话并**重绑**；人在面板**确认 / 驳回后把结果回写**到该会话（「收到即可，不要自动开工」），并把该会话切到前台。这样从对话、落卡、调整、拆解到确认全程同一条对话。技能写操作全部带 `$DSH_SESSION_ID`。

- **需求池拆解：优先回到创建该需求的会话（2026-10-04）**：agent 用 `requirement-pool` 落卡时带上 `$DSH_SESSION_ID`，壳层把「REQ-id → 来源会话」写进 **ignored** 的 `.dsh/requirements/local.json`（运行时绑定，不进卡片）；面板点「拆解」时**优先把提示词发回来源会话**，没有才用当前会话，仍失败则回退复制。`POST /api/requirements/create` 新增 `session` 字段。测试 `tests/requirements-panel` 模型 **93 → 97**、API **49 → 51**。

- **需求池拆解：面板把提示词直接发进当前对话（2026-10-04）**：点卡片「拆解」不再只复制到剪贴板——用 `dshSession` 跟踪器上报的当前会话调 `DshSessionOps.sendPrompt`（`session/prompt`，与 wiki 生成 / 任务队列同一形状）把提示词**直接发进对话**；agent 随即调 `POST /api/requirements/breakdown/propose` 提出待确认方案。**没有打开的对话或发送失败时回退复制**并在状态行说明。另一入口不变：对话里运行 `/requirement-pool 拆解 <REQ-id>`。人工确认门（R10）不变：`confirm` 仍只在面板。

- **面板创建需求：「创建并细化」起一条细化会话（2026-10-04）**：面板「＋」建卡没有对话来源，抽屉底部提供 `[创建] [创建并细化] [取消]`——**普通「创建」只写卡**；点**「创建并细化」**时 main 在活动工作区 `session/create` → `session/rename`「细化 REQ-xxx」→ `session/prompt` 细化提示词（只讨论、只澄清、不改代码；改卡走 `/update`），并把卡片**绑定到该会话**、切过去；会话创建失败回退当前会话，再失败只留卡片并提示。这样面板创建的需求也满足「同一需求同一会话」。测试模型 **97 → 103**。

- **工作流硬规则：对话/需求阶段只读，开工唯一入口 = 已启动的任务队列（2026-10-04）**：`AGENTS.md` 工作流段、`.dsh/ai-native-workflow-spec.md`（新增 **R12** + AGENTS 模板）、内置技能 `requirement-pool` 三处都加这条——需求未落卡 / 事项未确认 / 队列未启动之前，只讨论、只澄清、只落卡，**不得修改代码或文件**；这是「避免 agent 在想法阶段直接开工」的软闸（覆盖所有会话；硬闸走 dsh 的 plan mode / 权限预设，另议）。使用说明常见坑同步。

### Fixed

- **英文界面修复：Agent 追加任务后壳层崩溃（2026-10-02，v1.18.0）**：`tasks.apiQueueAppended` 的中英文案占位符顺序相反（中文 `%@`→`%d`、英文 `%d`→`%@`），而 `L10n.tr` 把同一份参数列表交给当前语言的格式串；英文下 `%@` 拿到整数 `created.count`（3）被当成对象指针，`String(format:)` 内部对 `0x3` 调 `objc_opt_respondsToSelector` 直接 SIGSEGV（`KERN_INVALID_ADDRESS at 0x3`）。改用位置参数 `%1$@` / `%2$d`，两种语言各自保留自然语序。回归：`tests/l10n` 新增「中英格式参数必须一致」检查——改前先复现失败（精确命中该 key），改后通过。

## [1.18.0] - 2026-10-02

### Added

- **终端面板聚焦时自动切英文输入法、失焦还原（2026-10-01）**：终端想要拉丁键盘，否则中文/日文输入法会截走最初的按键。现在 `TerminalView.becomeFirstResponder/resignFirstResponder` 驱动一个纯状态机 `TerminalInputSourceGuard`：聚焦时记住当前输入法并切到 ASCII 源（`TISCopyCurrentASCIICapableKeyboardInputSource`），失焦时还原；使用中可随时手动切回中文，策略只在聚焦那一次切、不会反复拉回。**最初状态绝不被覆盖**：`savedID` 写一次，重复聚焦（鼠标移入即聚焦 + 点击）直接返回，还原被系统拒绝时也保留原始、下次再试；原本就是英文则不接管。系统层用 Carbon TIS 实现并隔离在 `InputSourceControlling` 协议后（本机实测「百度拼音 → ABC → 百度拼音」往返成功）。回归：`tests/terminal-panel` 新增 11 项，README/本文件/wiki 同步。

- **终端焦点光标：聚焦蓝色实心、失焦蓝色空心（2026-10-01）**：失焦后终端仍画蓝色实心块，看起来还像激活状态。现在 `TerminalView` 维护 `hasFocus`（`become/resignFirstResponder` + `NSWindow` key 通知，覆盖 Cmd-Tab 切走 App 的情形），`drawCursor` 聚焦时保持原来的 accent 实心块并在块上把字符重绘为白色，失焦时改画同色**空心描边框**、字符保留原色。回归：`tests/terminal-panel` 新增 3 项。

- **队列收尾优先复用来源会话（2026-10-01）**：队列在哪个会话里创建，就尽量在哪个会话里收尾——创建 / 验收 / 收尾同一条对话，不用在侧栏里另找一个「收尾：…」会话。手动创建的队列没有来源会话，才新建专门的收尾会话。来源会话是真实对话，所以提示词要求最后回一个**唯一完成标记**，壳层只采用带标记的那次汇报（避免把用户别的回合当成收尾结果）；来源会话不可用 / 忙到超时 / 已从 dsh 消失时**回退新建**，且**绝不取消**用户的会话。设计见 §14 决策 12。
  回归：tests/tasks-panel **1393 → 1405** 项（运行器 442→**454**）。

- **任务面板新增「使用说明」（2026-10-01）**：右上角**始终**有问号帮助按钮，点开是与「新建队列」同款的抽屉；没有任何队列 / 任务时，说明**还会直接铺在内容区**（跟空态一起）。内容由纯模型 TasksHelpModel 按 L10n 键生成——新建任务 / 队列 / Git 工作流 / 会话回传四节，中英成对，语言切换即时重渲染。空态只在**未筛选**时展示说明：筛选下没有匹配，出路是切回筛选，不该再铺一段说明。
  回归：tests/tasks-panel **1333 → 1363** 项（视图模型 349→**371** / 视图 235→**243**）。

- **任务队列的 Git 工作流可配置（2026-10-01）**：队列干完的活如何「落地」现在是一个显式设置，
  而不是写死的「开 PR」。四种模式：**pr**（推送分支 + 开/更新 PR）、**merge**（本地把队列分支合并进基线并推送基线）、
  **push**（直推当前分支）、**无**（不做任何收尾——非 git 项目，或明确不让它自动碰远端）；动作仍全部交给**收尾会话**执行（凭据与判断在会话侧，壳层不直接 merge/push），
  冲突尽量现场解决、拿不准就停下请用户介入、base 受保护如实报错。要点：
  - **默认工作流是按工作区的**，与 GitHub token 合并进同一个**设置抽屉**（面板右上齿轮；原来 token 是个 NSAlert，
    现在是和「新建队列」同款的抽屉），抽屉里给出**本工作区推荐**（GitHub → pr、普通 git → merge、非 git → 无，
    仅提示不强制），默认工作流是**单选按钮组**（不是下拉，四档同时可见）；
    存 ShellConfig 的「工作区路径 → 模式」映射（`tasksIntegrationByWorkspace`，不往用户仓库写文件），
    未设置过时用该工作区的推荐——所以首次打开抽屉默认选中的就是推荐那一档。
    需要「全局一份」的话属于**壳层设置**，不在任务面板；
  - **队列级覆盖**：队列表单「高级设置」里是**单选组**（跟随设置 + 四档），推荐工作区标在 caption 行上；
    `TaskQueue.integration` 存队列自己的选择（null = 跟随本工作区的默认）；
  - 队列卡「发布」按钮的**图标与文案跟着模式走**（开 PR / 合并到基线 / 直接推送；「无」时没有发布按钮）；
    收尾会话的结果（成功摘要首行或失败原因）写在队列卡上；`autoPR` 语义收敛为「完成后自动收尾（按 Git 工作流）」，
    而「无」会让 autoPR 也收尾无动作；
  - 新增 `QueueIntegration.recommended(isGit:hasGitHubRemote:)` 纯函数，以及 `TaskBoard.createQueue(integration:)` /
    `TasksRunner.createQueue(integration:)` / `createQueueWithTasks(integration:)` / `updateQueue(integration:)`。
  回归：`tests/tasks-panel` **1272 → 1333** 项（模型 201→**203** / 运行器 420→**433** / 视图模型 338→**349** /
  视图 200→**235** / 本地 API 113）。设计见 `docs/design/panels/tasks-queue-session-loop-design.md` §14 决策 8/11、§15。

- **设置菜单新增「打开数据文件夹」（⌘D，位于「打开日志文件夹」之前，2026-09-29）**：直接打开 `$DSH_HOME/oh-my-dsh/`（不存在则创建），方便查看 / 备份壳层工作数据与迁移回退说明 `ROLLBACK.md`；开发版打开的是 `~/.dsh-dev/oh-my-dsh/`。

- **任务队列的会话闭环（2026-09-30）**：`task-todo` 现在能把一次沟通落成「**等待态队列 + 批量任务**」，并可按用户指令启动；队列**跑到完成（`.done`）时把各任务的完成情况回传创建它的会话**（`session.prompt`），用户在同一个会话里验收、要求调整。要点：
  - 队列新增独立状态 **`.draft`（待启动）**——与「启动过但停了」的 `.paused` 分开；`.draft` 不会自己开跑，App 重启后也保持 `.draft`（只有 `.active` 会转 `.paused`）；
  - 新端点 **`POST /api/tasks/queue/create`**（建 `.draft` 队列 + 批量入队，`session` 记录来源会话）与 **`POST /api/tasks/queue/start`**（按 `queueId` 启动；缺省时启动「本会话创建的那个等待队列」，多个则返回 `409 ambiguous-queue` 让调用方消歧）；
  - 队列↔会话关联与「已回传」标记存在 `local.json`（`queueSessions` / `queueNotified`，机器私有）；**只有进入 `.done` 才回传**，失败 / 手动取消停在 `.paused` 不回传；回传失败也记标记（避免死循环），App 重启后在空闲 step 补发一次；
  - 回传文案要求收到它的 agent **只做简短确认**、不主动改代码；回传内容给每条任务的**完整汇报**（单条上限 1500 字，超出标注「已截断」）与失败前的汇报，队列分支 + 分支提交列表（非 git 仓库不显示）、耗时与 PR，**不含会话标识**；
  - 面板队列头在「有来源会话」时显示一枚 ↺（tooltip：完成后回传发起会话）；`queue/start` 也支持按 `name` 消歧；
  - 技能正文（内嵌常量 + 仓库副本字节一致）**默认**建「等待态队列 + 入队」，只有用户明确说「只建任务 / 先别入队 / 不要队列」时才只建裸任务，并补充启动话术；设计见 `docs/design/panels/tasks-queue-session-loop-design.md`。
  回归：`tests/tasks-panel` 1129 → **1226** 项（模型 188 / 运行器 410 / 视图模型 328 / 视图 199 / 本地 API 101）。

- **`task-todo` 可发起队列交付 + 任务 API 路径规范化（2026-10-01）**：任务 API 的资源段显式化——任务列表 / 创建改为 `POST /api/tasks/task/list` 与 `/api/tasks/task/create`（旧的 `/api/tasks/list`、`/create` 保留为 alias），队列仍在 `/api/tasks/queue/*`；新增 **`POST /api/tasks/queue/deliver`**，对**已完成**队列按 Git 工作流发起交付（与队列头「交付」按钮同一条 `startQueueIntegration` 路径；缺队列定位字段返回 `400 no-queue-target`，其余错误码 `not-deliverable` / `workflow-none` / `busy` / `no-branch` / `no-remote` / `session-failed` / `ambiguous-queue` / `no-queue`）。`task-todo` 技能文档加入交付能力与硬规则「仅用户明确要求且队列已完成时才交付」，仓库技能副本按内嵌字符串重新生成（byte-identical）。

### Changed

- **内置 dsh 升级到 `@deepseek-ai/dsh@0.1.7-rc.2`（2026-10）**：0.1.5-rc.3 → 0.1.7-rc.2。随附闭包锁
  `platforms/macos/runtime-locks/dsh-0.1.7-rc.2/`（`npm ci` + 构建期启动冒烟通过；273 个
  `@deepseek-ai/dsh-*` 全为该版本，闭包自洽）。**一处壳层适配**：0.1.7 删除了 `subagents/list` 端点，并把
  `session/follow` 等 Remote 流改由一条 WebSocket 承载，只 hook `window.fetch` 的
  `sessionTrackerScript` 会静默失效（切会话后终端/预览/wiki/tasks 的项目目录不跟随）——现同时 hook
  `WebSocket.prototype.send`（仅观察 `{type:"open"}` 帧、从 `SessionAddress` 取会话身份）并给 fetch 白名单
  补 `session/follow|page|projections`；新增 `tests/session-tracker/`（12 项）钉住两代传输。
  会话日志世代 v3 → v4（`session.v4.jsonl`）由 `review-log` 的「最大世代优先」天然覆盖；工作区存储仍 v2、
  技能四根/rank/frontmatter 键未变。npm `latest` 已是 `0.2.0-rc.2`，站内升级助手按 stepwise 会提示
  `0.2.0-rc.1`（预期）。完整审计：`docs/plans/dsh-017rc2-compat-audit.md`。

- **队列状态标签配色（2026-10-01）**：进行中 = 蓝、暂停 = 橙、完成 = 绿、失败 / 错误 = 红、**关闭 = 灰**（此前关闭是橙，和暂停/待启动混在一起）。待启动与「等待中」仍是橙（可行动的语气）。

- **队列改为「可追加的活泳道」+ 手动发布（2026-10-01）**：把队列从「一次性任务批」调整为可迭代的
  工作泳道，配合「主 Agent 拆任务 → 队列执行 → 回传验收 → 再追加」的循环：
  - 新增手动终态 **`.closed`**：队列头「关闭队列」（保留任务/分支/PR 记录，之后不再接收任务、不能启动或发布）；
  - **`.done` 只是「当前一批任务都结束」**：追加任务回到 `.draft` 并**重臂回传**（下一轮完成照常回传源会话）；
    `.paused`（有失败）追加保持 `.paused`；向已有队列追加任务**不再自动启动**（新建空队列的「加入即开始」不变）；
  - **PR/push 改为手动**：`autoPR` 成为队列配置、**默认关闭**（技能建的队列也不再默认自动开 PR）；
    队列头「发布」按解析出的 Git 工作流执行（PR 已存在时是「更新」，PR 链接另行保留，可随时打开）；
    **merge/push 都由收尾会话执行**，壳层不直接碰；
  - 队列区与「加入队列 ▾」改为**最新在前**（按 `createdAt` 倒序；老队列 / 无时间戳的排最后），
    新建的队列不再沉到最下面；
  - 任务会话在 dsh web 侧栏加前缀 **「TASK: 」**（如「TASK: 改 README」），一眼认出这是队列起的会话；
  - 面板：`.closed` 状态文案与按钮；`.done` 增加「关闭」入口；发布与 PR 链接拆成两个控件；
  - **新增 `POST /api/tasks/queue/append`**：`task-todo` 技能**默认**把新任务**追加到本会话已有的队列**
    （没有才新建；目标按 `queueId` / `name` / `session` 解析），不再要求用户明说「追加」——
    用户明确说「新建队列 / 另起一个」时才直接 create。
  回归：`tests/tasks-panel` 1129 → **1272** 项。

- **壳层工作数据收敛到 `$DSH_HOME/oh-my-dsh/`（2026-09-29）**：把壳层自己的工作数据从 `$DSH_HOME` 根迁到与 `projects/` 并列的新根 —— `shell/`（设置 / 状态 / 快照）、`browser/`（CEF profile；**去掉开发版 `browser-dev` 后缀**，正式版与开发版统一 `<DSH_HOME>/oh-my-dsh/browser`）、`repo-wiki/`、`channel-runtime/`、`channels/`、`tokens/` + `gh-token`、`browser-api.port` / `shell-api.port`。dsh 自有数据（`sessions/`、`storages/`、`settings.yaml` 等）与上游契约路径 `$DSH_HOME/skills/` 保持不动；`~/Library/{Logs,Caches}` 与 Application Support 运行时也不动。路径的单一事实来源为 Swift `ShellPaths` / core `shell-paths.js`；启动（以及显式 `--home` 的 CLI）做一次**幂等迁移**：源不存在或目标已存在即跳过、失败保留源并记 `app.log`，正式 home 与开发版 `~/.dsh-dev` 都覆盖；GitHub token 读取链保留旧路径只读兜底；迁移时在 `$DSH_HOME/oh-my-dsh/ROLLBACK.md` 落一份双语回退说明（实际迁移条目 + 时间/App 版本 + 退出后把子目录 `mv` 回根目录的脚本），供降级旧版或快速撤销时自助使用；本次确有搬迁时启动后弹一次**非模态提示**（说明 + 「查看回退说明」按钮打开 `ROLLBACK.md`），**全新安装不提示**。回滚快照排除表新增 `oh-my-dsh`（`core/lib/snapshot.js`）。设计见 `docs/design/shell/storage-layout-refactor.md`；回归：`core` 289 项（新增 `core/tests/shell-paths.test.js` 6 项）与 `tests/{shell-config,channel-panel,skills-panel,wiki-panel,snapshot-rollback,projects-panel,tasks-panel,skills,browser-panel}` 全绿。

- **队列「发布 / 收尾」统一改称「交付」（Deliver，2026-10-01）**：「发布」容易被理解成发版 / Release，又把推送 / 合并 / 开 PR 三种动作压成一个词，「收尾」不说明结果去哪。按钮 tooltip、会话名（统一「交付：<队列名>」）、状态行、错误、设置开关与说明、提示词全部对齐；代码标识（`QueueIntegration` / `finalize*`）不动。

### Fixed

- **任务面板设置全部按工作区隔离（2026-10-01）**：此前抽屉里只有「工作流默认」按工作区存，而「交付成功后自动关闭队列」写的是**全局键** `tasksAutoCloseOnPublish` —— 在一个工作区勾上，其余所有工作区打开设置也都是勾上的（用户反馈：几个从没设置过的项目里看到它默认就是开的）。现在该开关改存「工作区路径 → 布尔」映射 `tasksAutoCloseOnPublishByWorkspace`，未设置过的工作区默认关，且**只影响当前工作区**；抽屉说明与开关说明都明确「按工作区 / 只对当前工作区生效」。旧的全局键不再读取（该开关尚未发布，无需迁移）。回归：`tests/tasks-panel/run.sh` 新增源守卫，杜绝设置项再退回全局键。

- **终端输入法、焦点光标统一由键盘焦点驱动（2026-10-01）**：两者用同一个 `hasFocus` 信号——`becomeFirstResponder` / `resignFirstResponder` 与窗口 key 变化（⌘-Tab 切走/切回）→ 聚焦画实心块 + 切英文，失焦画空心框 + 还原原始输入法。鼠标移入即聚焦（切英文），移出不失焦所以维持不变；上一轮误加在 `mouseExited` 上的还原已移除（移出只保留诊断日志）。一次焦点变化只切一次，残留抖动由 0.12s 防抖兜底；`terminal focus:` / `terminal ime:` 日志写进 `app.log`。

- **终端聚焦时输入法来回闪（2026-10-01）**：上一版在 `become/resignFirstResponder` 上直接切/还原输入法，但输入源切换本身会扰动响应链、加上鼠标进出终端，`resignFirstResponder` 会成串到来——每次失焦都还原、每次聚焦又切英文，输入法连闪好几次。现在**还原带 0.12s 防抖**：`terminalDidBlur()` 只登记一次还原（generation 计数），期间若又 `terminalDidFocus()` 就取消，一串抖动收敛成一次切换；鼠标 tracking area 也改为**只安装一次**（`.inVisibleRect` 自动跟随），不再在每次 `updateTrackingAreas` 时 remove/add 反复补发 `mouseEntered`。回归：`tests/terminal-panel` 新增 3 项防抖断言。

- **发布后队列卡不刷新 / 结果只有一行 / 状态行总说「开 PR」（2026-10-01）**：点发布后卡片像卡住了——错误提示还在、结果不出来；会话回写的结果只显示一行；运行状态行不论什么工作流都写「正在开 PR」。三处都修了：
  - 3 秒刷新的看板指纹（boardSignatureNow）现在包含队列的 prError / prUrl / integrationNote——发布恰好只改这几个字段，以前定时器判定「没变化」就不重绘；
  - 收尾会话的**整段汇报**（上限 4000 字）回写到 integrationNote；卡片默认显示第一行，多出「展开 / 收起」，展开后完整换行显示（折叠的队列仍会显示失败原因）；
  - 运行状态行按解析出的工作流说：正在合并到基线 / 正在推送 / 正在开 PR。
  回归：tests/tasks-panel **1378 → 1393** 项（运行器 441→**442** / 视图模型 374→**381** / 视图 247→**254**）。

- **非 GitHub 的 git 仓库：合并被误判成「开 PR」，且本地仓库根本发不出去（2026-10-01）**：测试一个 git 仓库（没有 GitHub 远端）时，点队列「发布」只看到泛泛的「开不了 PR」，还以为是代码去开 PR 了。两处都修了：
  - 「合并到基线」是**本地操作**，不再要求任何远端——没远端就只合并、不推送（提示词明确「不要尝试推送」，并让会话报「已合并到 X（无远端，未推送）」）；只有「直接推送」才必须有可推送的远端。merge 的发布按钮在本地仓库也会出现且能用；
  - 发布被拒时把**具体原因**显示出来（没分支 / 没有可推送的远端 / **已经有一个收尾会话在跑**——后者以前既不写错误也不说明，只报通用文案）；tasks.errPRStart / tasks.errPRNoRemote 改成「发布 / 远端」口径，不再一律说 PR；
  - 失败原因显示在**队列卡**上（红色警示行，折叠时也显示），**不再占用发布按钮的 tooltip**——按钮的 tooltip 永远只说明它做什么；新的一轮任务开始时会清掉上一轮的结果与失败原因。
  回归：tests/tasks-panel **1363 → 1378** 项（运行器 433→**441** / 视图模型 371→**374** / 视图 243→**247**）。

- **切换 dsh 会话卡顿（2026-10-01）**：在 dsh web 里每切一次会话，壳层就对当前工作区**重新 adopt**——`IssueRunnerPanel.adoptWorkspace` 在**主线程**同步 spawn `/usr/bin/git`（`detectGitHubRemote` / `isGitRepo` / `detectDefaultBaseBranch`），而 dsh web 就跑在同一线程的 WKWebView 里，于是切会话瞬间整窗口冻结（app.log 每次切换都有 `tasks: workspace adopted …`，即使路径没变）。现在 `workspaceChanged()` 走纯函数 `TaskWorkspaceRegistry.needsReadopt`：**同一（标准化后）工作区 + 有 runner 直接短路**，不再重探；真正的跨工作区切换照旧，工作区**形状变化**（任务跑了 `git init`）仍由 step 定时器上的 `recheckWorkspaceShape` 负责重建。回归：`tests/tasks-panel` 新增 5 项（同路径/尾斜杠/换路径/无 runner/无路径）。

- **终端面板：鼠标移入即取得输入焦点 + 中文标点不再被拉伸变形（2026-10-01）**：两处体验问题。① 终端内容视图此前只在 `mouseDown` 时 `makeFirstResponder`，移入后直接敲键盘没有反应，必须先点一下；现在 `TerminalView` 挂 `NSTrackingArea`（`.mouseEnteredAndExited` + `.activeInKeyWindow` + `.inVisibleRect`），`mouseEntered` 即把第一响应者设为自己（点击面板 chrome 聚焦的 `installClickMonitor` 保留）。② 宽字符渲染过去把每个宽字的自然字宽横向缩放到两格：等宽系统字体没有 CJK 字形，Core Text 默认回退对全角标点只给约 0.8 格、汉字约 1.6 格，于是标点被横向拉约 2.4 倍（`。`/`，`/`、` 变成扁椭圆）。现在 `drawWideGlyph` 改用真实全角字体（PingFang SC）并按 `2 × 单元格宽` 反推字号，使字形自然字宽正好两格（Hangul / 生僻字 / emoji 走级联回退后同样按实测字宽取字号），再按两字体 descender 差补偿基线，彻底不做横向缩放；字体按 (字符, 粗, 斜) 缓存。回归：`tests/terminal-panel` 新增 7 项（移入聚焦的 tracking area + `。，！（中国` 六个字形 natural advance 恰好两格），README「终端面板」一节同步。

- **预览拦截适配 dsh 0.1.7（2026-10-01）**：0.1.7 的 `[data-changed-files]` 卡与 `[data-presented-files-row]` 交付卡片交互变了——现在改动审阅卡按 `aria-describedby` 读取隐藏 span 的绝对路径并路由到壳层**原生预览面板**（不再弹 dsh 侧边栏，toggle 放行），交付卡片内 dsh 自带的「用应用打开 / 在 Finder 中显示」控件**不再被劫持**。`tests/preview-interceptor` 新增两项（第 17/18 项）。

- **运行中会话打不开的修复与自愈（2026-10-01）**：根因是实时 `$events` 打开帧里的 `assistantStream.activeAttempt.stream` 经 typert 解码后某个 chunk 不再是无损 JSON，客户端因此拒绝**整个会话**的打开（跑完没有这段快照，所以正常）。现在壳层在进页面之前用一个 `WebSocket` 包装脚本清空 `activeAttempt.stream`（保留 `attemptId` / `nextIndex`，后续实时帧照常接上），**第一次点即可正常加载**（不改 dsh 源码；生效时写 `app.log: webview: sanitize`）。另保留自动重开兜底（有界 3 次 / 3 秒窗口），dev 诊断的 rejection 记录补充 `cause` 与 `stack`。

- **队列终态与交付细节（2026-10-01）**：已关闭队列默认折起（与已完成一致）；关闭的队列不再作为「加入队列」的目标。

### Docs

- **文档按开发环节分类 + 面板说明独立成册（2026-10-02）**：`docs/` 从平铺改为按环节分目录——`process/`（流程 / 发布 / 升级）、`research/`（调研 / 产品化总纲）、`design/{shell,panels,channels}/`（壳层 / 面板 / 通道设计）、`fixes/`（排查记录）、`plans/`（实施计划）、`milestones/`（里程碑）、`usage/`（面向用户的使用说明）、`feedback/`、`raw/`、`screenshots/`，根目录只留 `README.md` 索引。面板使用说明并入 `docs/usage/panels.md`；README 的「特性一览」拆为**壳（全局）**与**面板**两节、面板按活动栏实际顺序排列，面板详述与截图同步更新；全部源码注释 / 文档交叉引用与 `.dsh/wiki/` 一同刷新。

## [1.17.2] - 2026-09-30

### Fixed

- **审查面板看不到文件变更（dsh 0.1.5-rc.3，2026-09-30）**：升级后审查面板能**列出**会话却显示「没有改动」——根因是 `run_code` 的**嵌套派发事件名换代**：dsh ≤0.1.2 写 `tool/code-dispatch[-start]`，0.1.5-rc.3 改写 `tool/ptc-dispatch[-start]`，而审计只认老名字，于是嵌套的 `write`/`edit`/`bash` 全被丢弃，`review audit` 的 `mutations`/`files`/`added`/`removed` 恒为 0（正常返回 JSON、不报错、不弹窗）。现在 `core/lib/review-log.js` 用 `DISPATCH_START_TYPES`/`DISPATCH_END_TYPES` 同时认两代事件名，老的 `code-dispatch` 日志不受影响。回归：`core/tests/review-log.test.js` 新增 2 项（ptc 嵌套 `write`/`edit` 能审计出 hunks 与统计；失败的 ptc dispatch 丢弃 pending content）；用内置 node 实测 0.1.5-rc.3 真实会话从 0 恢复为 4–13 个文件变更。影响清单见 `docs/process/dsh-version-impact.md` §4.5 / R7b。

## [1.17.1] - 2026-09-29

### Fixed

- **项目面板自动创建 projects 根目录，「更改…」定位到该根（2026-09-29）**：全新安装时面板显示「根目录不存在：<path>」，而「更改…」的文件夹选择器因为目标目录不存在也无法定位过去，等于第一次使用要先自己 `mkdir`。现在面板每次 `reload()` 都在后台调 `ProjectsCore.ensureDirectory(root)` 建根（`mkdir -p`，成功记 `app.log` 的 `projects: created the projects root …`；权限 / 卷未挂载导致失败时保持原来的空态提示），首次打开即是可写的根、`projects.rootMissing` 正常不再出现；面板头部「更改…」与设置窗口「选择…」两处选择器都改用 `ProjectsCore.existingDirectoryForPicker`，起始目录落在当前根（根仍不存在时退到最近的现存祖先，而不是掉进用户主目录）。回归：`tests/projects-panel` 模型 45 → **53**、控制器 **55**（合计 **108**）——新增建根与选择器起点各四例，原先「默认根不创建」的断言改为「加载即创建且不再出现 `rootMissing`」。设计文档 §2/§5/§8/§11/§12 与 `.dsh/wiki/modules/projects-panel.md` 同步。

- **终端面板首次打开会同时开出两个终端（2026-09-29）**：`setRightPanel(.terminal)` 在打开面板时先 `setWorkspaceDirectory(dir)` 采纳当前工作区、再 `ensureSession()` 兜底首个会话，而**两条路径都会**在「当前工作区没有可见会话」时各开一个：工作区切换的自动开启（#5 后续）与首次打开兜底。新建会话要先经 `DSHSessionRPC.resolveProjectDirectory` 异步解析 cwd，`ensureSession()` 运行时第一个页签还没进 `tabs`，`visibleTabs.isEmpty` 仍为真 → 同一帧内发出两次 spawn，两个 PTY（应用日志实测：`session 1` / `session 2` 相隔 8ms、cwd 相同）。触发条件是「预览/会话先把 `ProjectDirectory.current` 定好、终端的 `workspaceKnown` 仍为 false」，正是首次打开终端的情形。修复：`setWorkspaceDirectory` 只在实际的工作区**切换**（此前已采纳过工作区）时自动开启；**首次采纳不 spawn**，首个会话交给 `ensureSession()` 独有，`#5` 的「切到无终端工作区自动开启」保持不变。顺带删除该处遗留的、只赋值不读取的 `startedOnce`。回归：`tests/terminal-panel` 新增两项（首次打开只排队一个会话；后续切到无终端工作区仍自动开启 —— 在服务器未就绪时数 `deferredSpawns`，无需 PTY）。

- **项目面板首次打开时宽度塌成内容宽度（2026-09-29）**：项目面板的根视图被直接挂成 `NSSplitView` 右栏，却设置了 `translatesAutoresizingMaskIntoConstraints = false`。该栏因此退出 autoresizing 交给 Auto Layout，而它没有宽度约束，`NSSplitView.setPosition` 变成 no-op，面板被压到内容的 fitting 宽度（实测约 170–260pt），而不是记忆/默认宽度（示例：907 / 560pt）；其余八个面板的根视图都保持默认，只有项目面板漏了这一处。去掉该设置后，`setRightPanel(.projects)` 的 layout 日志从 `panel=170pt` 变为 `panel=907pt`，与文件面板一致。回归：项目面板单测新增「根视图保持 frame-based」守卫。

## [1.17.0] - 2026-09-29

### Added

- **终端面板支持输入法直输（macOS IME，中文/日文/韩文等，2026-09-29）**：这是 README 里挂了很久的 v1 已知限制 —— 终端是一个自绘的 `NSView`，只覆写了 `keyDown` 把 `event.characters` 直接写进 PTY，既没有声明 `NSTextInputClient` 也就拿不到 input context（AppKit 的 IME 整条链路都以 `conformsToProtocol:` 为准），输入法因此从不介入，切换成拼音后敲出来的还是字母，中文只能 `⌘V` 粘贴。现在 `TerminalView` 正式遵循 `NSTextInputClient`：`keyDown` 里 `⌘`/`⌃`/`⌥` 组合与方向键等特殊键照旧先走原来的直写路径（不被输入法截胡），其余按键与**候选期内的所有按键**交给 `interpretKeyEvents`；`insertText` 把上屏文本按 UTF-8 写进 shell（无输入法时与旧行为逐字节等价），`setMarkedText`/`unmarkText` 维护预编辑状态，`firstRectForCharacterRange` 把候选窗锚在光标处（组合期锚在预编辑文本末尾），`doCommandBySelector` 兜住输入法放行的键。预编辑文本（拼音串）在光标处**内联显示**并带下划线 + 细光标，组合期间不画原来的方块光标。回归：`tests/terminal-panel` 新增 10 项（`markedRange`/`selectedRange`/`hasMarkedText`、空串 unmark、`attributedSubstring` 的边界、无窗口时 `firstRect` 退化为 0、提交/取消清空组合），README「已知限制」移除 IME 一条并新增「输入法直输」说明，`docs/research/productization.md` §3.1 与总表同步。

- **内置技能 `task-todo`：把沟通结论批量写进任务面板（2026-09-27）**：用户和 Agent 在会话里聊完需求与方案，常常还要自己把结论一条条抄进任务面板——而 Agent 手里本来就有完整的任务描述。现在壳层的 localhost API 多了一组 **`/api/tasks/*`**（`GET list` / `POST create`，一次最多 50 条，返回 `created` 与逐条 `rejected` 原因），端口写 **`~/.dsh/shell-api.port`**（与 `browser-api.port` 同值——同一个服务、两块路由面：`/api/browser/*` 归浏览器面板，`/api/tasks/*` 归任务面板）；配套**第四个内置技能 `task-todo`**（`SkillInstaller` 内嵌常量 + 仓库 `.dsh/skills/task-todo/SKILL.md` 副本字节一致，App 启动安装到全局 `$DSH_HOME/skills/`），正文把边界写成硬规则：**只在用户明确要求时**执行、先 list 再建（面板内新建不去重）、**一次请求提交全部任务**（不逐条调）、**不启动任务 / 不建队列 / 不直接改 `.dsh/tasks/*.json`**，App 没运行就报错请用户打开。落盘复用面板自己的入口（`TasksRunner.createManualTask`，经 `BrowserAPIBridge` 派发到**主线程**——board 的读改写必须与 3 秒 step 定时器同一条线程，否则两个写者互相覆盖），任务一律「**待处理、未入队**」；`focus` 默认 true → 切到那个工作区并展开面板，状态行说一句「已由 Agent 创建 N 个任务」。工作区解析按「精确匹配 → **最近祖先**（Agent 的 cwd 常在 workspace 子目录里）→ 原样接受」三步，纯函数可无头测试；面板尚未 adopt 任何工作区时回 `400 no-workspace`，服务在而面板没接好回 `503 panel-unavailable`。回归：新增 `tests/tasks-panel/api-tests.swift`（**68 项**：路由命中与不吞 404、请求解析（字符串简写 / 对象 / 空标题 / 上限 50 / 部分成功）、工作区解析、响应形状），`tests/skills/run.sh` 自动覆盖第四个技能的安装/更新与字节一致断言，`tests/browser-panel/run.sh` 把同一服务上的任务路由面一起编译。设计见 `docs/design/panels/task-todo-skill-design.md`。

### Changed

- **issue 任务与手动任务对齐：一套要求、一份提示词（2026-09-27）**。同一个面板里两种来源此前有两种行为：手动任务的提示词由 `TaskPrompts.requirements(...)` 按工作区形状生成（非 git 目录没有分支条、非 GitHub 没有 token 条），**只 commit、不提 push/PR**；issue 任务却走一段写死的 5 条，第 1 条要求「加载 `issue-resolve` skill 并严格按其流程执行」—— 而那个技能停在旧世界：它让任务自己 `git push`、还说「PR 由面板创建」（PR 现在由队列结束后专门的「开 PR 会话」做）。于是 issue 任务会 push、手动任务不会。现在两种来源**共用同一份要求清单**，只有「头」不同：issue 头给**编号 + 标题 + 标签 + 正文**（此前只给编号与标题，正文还得代理自己去 GitHub 拉），手动任务头给标题 + 描述；要求条目按工作区形状逐条生成、都要自查与汇报、都带队列交接简报。自动队列的形状也统一：`TaskQueue.auto(for:baseBranch:switchesBranch:opensPR:)` 与 `auto(forManual:)` 同语义，非 git 目录里 issue 任务的单任务队列**不再派生 `fix/issue-N`**（此前写死分支与 autoPR，任务必然 `errNotGit`），两个入口共用 `dropUnswitchableBranch(ofTask:)`（旧队列带着切不了的分支，启动前先去掉再跑）。`issue-resolve` 技能随之**退役**：`BuiltinSkill` 去掉该 case，仓库删 `.dsh/skills/issue-resolve/`，`SkillInstaller.retiredSkills` 在启动时删除老用户机器上**受管**的旧副本（`.ohmy-dsh-managed`），用户自己改过或自装的同名技能保留并记日志（`issue-fix` 这个更早的名字也不再迁移）。回归：`tests/tasks-panel` 新增三节（两种来源的要求逐行逐字相同、非 git 目录里的 issue 任务不派生分支且能正常跑完、旧队列的陈旧分支在启动前被去掉；运行器 296 → **362** 项），`tests/skills` 覆盖退役副本的删除与用户副本的保留；设计决策见 `docs/design/panels/issue-runner-design.md` §V2-14。
- **卡片上不再有文字按钮「打开 PR」（2026-09-27）**：用户指出它没用 —— PR 是**队列**跑完之后由那个专门的会话开的（§V2-6），打开它自然也在**队列头**那一行（`arrow.up.right.justify` 图标 / PR 链接，且排在最右）。此前那张卡片上的按钮还常常是灰的：它要的 PR 属于队列，队列没开自动 PR、或那次开 PR 没成功时，卡片就只能灰着说「这次没有 PR」。现在：完成的 **issue 任务**主按钮是「打开 Issue」（与 `.closed` 同一个动作，那是这条任务自己的东西）；完成的**手动任务没有主按钮**（没有任何待办动作可做，汇报就在详情里）——`TaskCardModel.primaryKey/primaryAction` 因此变成可选，卡片行在没有主操作时从「打开会话 / 审查改动」开始，不留空槽。随之删掉 `PrimaryAction.openPR`、面板里的处理分支，以及两条失去引用的文案（`tasks.detailOpenPR` / `tasks.detailOpenPRNoPR`）。回归：视图模型（完成态主操作的新语义 ×2 处）、表单（已完成卡片里不再有「打开 PR」，主按钮是「打开 Issue」）。
- **来源页签顺序改成 全部 / 手动 / Issue（2026-09-27）**：用户要求把「手动」提到前面。顺带把顺序收进一处：页签标题由 `TaskSourceFilter.allCases` 生成（`titleKey` 就在枚举上），`rawValue` 与下标一一对应 —— 上一版那种「标题数组与枚举顺序各说各话」的错位从此不可能再发生。回归：视图模型 +4 项（标题顺序、每个 rawValue == 下标）。
- **队列头的「打开 PR」挪到这一行的最右（2026-09-27）**：它此前夹在中间（暂停/开始 之后、自动开 PR 开关之前）。现在无论是最初的图标形式，还是已经有 PR 时的链接形式，都是这一行的**最后一个控件** —— 队列的发布动作读起来是收尾，而不是设置里的一枚。回归：表单 +6 项（图标在最右、链接是最后一个 arrangedSubview、不越界）。
- **「打开会话」点了没反应的真正根因：bridge 调用漏了一个参数（2026-09-27）**。`callAsyncJavaScript` 会把参数变成**函数体里的局部变量**，而函数体写的是 `window.__dshOpenSession(sessionId, workspaceName)` —— 不带工作区名调用时（任务面板就是这种情况）`workspaceName` 根本没传进去，于是页面抛 **ReferenceError**，Apple 的桥把它报成「发生了JavaScript异常」。应用日志里写得明明白白，UI 上一片安静：`.failure` 分支只记日志，而且失败消息一律写进**项目面板**的状态行（项目面板每次都带工作区名，所以那条路一直是好的）。现在：`workspaceName` **永远传**（没有就传空串，页面脚本用 `if (workspaceName)` 判断），函数体本身也做了 `typeof` 兜底；bridge 异常**立即**走 `reportOpenFailure`（新增 `projects.openFailedBridge`：「打开会话失败（xxx…）：dsh web 页面报错，详见应用日志」），并且说给**请求它的那个面板**（任务面板新增 `reportStatus(_:)` 接住）。`tests/tasks-panel/run.sh` 增加两条源码守卫把这两半钉住。
- **顶部来源页签点错了内容：Issue 页签列出以手动任务命名的空泳道，「手动」页签什么都不显示（2026-09-27）**。判据本是 `autoCreated`（自动队列 = issue 队列），可**全部处理给手动任务建的也是自动队列**：于是点 Issue 看到一堆以手动任务命名的泳道（里面的卡片全被过滤掉，只剩空壳），点手动反而什么都没有（它只显示用户自建队列，而用户的手动任务都在自动队列里）。规则移出面板、进了纯模型 `TaskSourceFilter`：`matches` 决定卡片，`cards(of:in:)` 决定泳道里画什么，`shows(_:in:)` 决定这条泳道出不出现在这个页签下 —— **「全部」不落下任何一条泳道；「手动」= 用户自建的泳道（空的也在，下一个手动任务就放这里）＋ 装着手动任务的自动队列；「Issue」= 只显示装着 issue 任务的泳道**。回归：视图模型 +13 项（这条 bug 的四个组合都钉住了）。
- **来源徽标与任务名的顺序反了（2026-09-27）**：来源（`手动` / `Issue #12`）是任务名的注解，现在排在**任务名后面**；任务名前是行标，最右仍是状态徽标。布局断言同步改成「来源徽标 ≥ 标题左缘、且排在状态徽标左边」。
- **卡片上的行标：队列名与任务名前各一枚图标（2026-09-27）**：队列头在队列名前放 `rectangle.stack`（泳道 —— 与「新建队列」按钮同一个图标家族），任务卡在任务标题前放 `checklist`（与空态图标同一个）。都是静默的第三档灰（状态仍然只由那一枚徽标说），符号在当前系统上取不到时退化成 0 宽视图（不留洞、不崩），并带无障碍描述与可断言的 identifier。
- **「打开会话」点了有反应了，失败也说到用户眼前（2026-09-27）**：任务卡片上的 `arrow.up.forward.app` 点击后**立刻**在状态行说「正在打开会话…」（shell 查找 dsh web 侧栏带重试，一秒的沉默是正常的），而**失败的消息改说给请求它的面板**——此前 `reportOpenFailure` 一律写进**项目面板**的状态行，用户在任务面板里点一下自然就是「点了没反应」。顺带：那个「同一会话正在打开」的守卫带上了超时（bridge 调用万一不回话，不会再永久吞掉这个会话之后的所有点击），两个按钮的 tooltip 也从「在 dsh 中打开这个任务的会话 / 审查这个任务改了什么」缩短成「打开会话 / 审查改动」。
- **已完成的任务与队列不再可编辑 / 可删除（2026-09-27）**：用户的要求，也终于与 README 里一直写着的那句「运行中/已执行的任务与 github 任务不可编辑删除」一致 —— 代码此前给的是 `state != .running`，于是已完成的任务照样有 编辑 / 删除。现在判据收进 `TaskState.isEditable`：**只在还可能跑（或再跑）的状态**下成立 —— 未入队 / 队列中 / 失败 / 已取消（失败任务重试前改标题正是编辑按钮的用处），运行中属于代理、已完成属于记录，两者都没有。队列同理：`QueueState.done` 的队列不再显示 `gearshape` 队列设置与 `trash` 删除（改了设置也不会再跑），还有活在等的队列照旧。
- **队列的 PR 改由一个专门的「开 PR 会话」做，任务会话只 commit（2026-09-27，第三轮）**：按用户的要求 —— 「所有的具体任务会话中，只须完成本地 git commit 即可；若队列中所有任务完成了、且队列开启了 PR，则进行 push 及 PR，这个操作可以发起一个新会话，由其总结变动后再发起 PR」—— 任务提示词里不再出现 push / PR / 「远端必须有这些提交」/「不要 push」，`finish()` 里那条 `ls-remote` 推送校验（`BranchPushState` 三态、`tasks.errNoPush` 的产生路径）连同 `env.createPR` / `env.prText` 与面板直连 GitHub API 的 `createPR` 全部删除。取而代之的是 **`TasksRunner.startQueuePR(queueID)`**：队列最后一项完成、队列开着「自动开 PR」且工作区是 GitHub 仓库时，在仓库目录里新建一个 dsh 会话（名字「开 PR：<队列名>」，可像别的会话一样打开），提示词（`TaskPrompts.pullRequest`）要它先读真实改动（`git log/diff`）、**自己写** PR 标题与正文（要总结，不是模板）、推送分支、开或复用 PR，并在最后一行给出 PR 链接、不许改代码。运行器多出 `.startingPR` / `.openingPR` 两个相位，一样占用那个串行槽位（`isBusy` 真、`runningTaskID` 空、`openingPRQueueID` 指向队列），所以一次只有一个 PR 会话在飞；会话结束后在后台步骤里从它的汇报里搜出 `github.com/.../pull/N`，搜不到就用该分支上已有的 PR 兜底，都没有就把原因记在队列上（`tasks.errPR`）并把失败原因显示在队列头「开 PR」按钮的 tooltip 里——**队列保持已完成**，PR 开不出来从来不算任务失败。队列头的「开 PR」按钮走的也是这条路（点一下就是再来一次），不再直接调 API。
- **代理的汇报写回任务卡片（2026-09-27）**：任务结束（成功**或失败**）时，壳层在收尾的后台步骤里取出代理在会话里的最后一段文字，写到任务上（`TaskItem.report`）并落在 `local.json`（机器作用域：汇报是本机会话的产物，**不写进**随仓库走的 `manual.json` / `index.json`）。卡片详情里因此多一行「汇报」，队列里**下一棒的交接简报优先用它**（会话被删掉也还在，读不到才回落到读会话日志），点「重试」会清掉上一轮的汇报（那不是这一轮的结局）。提示词里对应那条也写明了：**必须**在结束时汇报改了什么、怎么验证、结果如何——这段话现在真的会被用起来。
- **两处「队列上下文」统一成一段 `## 队列信息`（2026-09-27）**：队列里下一棒的交接简报原本抬头是 `## 队列上下文（前面任务留下的状态）`，开 PR 会话那段是 `## 要发布的分支` —— 同一件事（这个队列、这条分支、前面发生了什么）两种抬头两种字段顺序。现在两处都用 `## 队列信息`，字段顺序也统一：**队列（位次）→ 分支（基于 X）→ 分支上已有的提交 → 前面任务的汇报**（最后一项只有下一棒才有）。顺带把 issue 任务提示词里那条分支 rail 也换成手动任务的新措辞（「本任务须在分支 X 上处理（若该分支不存在，须基于 base 分支新建）」，`TaskPrompts.issue` 因此也收了个 `base`）——同一件事不该有两种说法。
- **任务提示词按工作区状态「按需出条目」（2026-09-27）**：要求列表不再写死 1–6 条，而是按 `TaskRepoShape`（非 git 目录 / git 仓库但没有 GitHub 远端 / GitHub 仓库）生成并连续编号：非 git 目录**没有分支条**（commit 那条改成「不要求 commit；任务自己 `git init` 建了仓库就 commit」）；有仓库才有分支条（有分支 → 「本任务须在分支 X 上处理（若该分支不存在，须基于 base 分支新建）」；不切分支 → 「本队列不切分支：直接在主分支 base 上处理」）与「完成前 commit」；**token 条只在 GitHub 仓库出现**；「改完自查」一条同时照顾代码与文档（确实没有可跑测试的就说明）；「汇报」一条每个任务都要（`**必须**`，并说明会被写回卡片）；独立任务不再说「与其他任务共享」；队列里**前置任务的汇报整段移到所有要求之后**。
- **提示词按工作区的「形状」写在写提示词的那一刻（非 git / git / GitHub 三态）**：面板把工作区分成**三态** —— **非 git 目录 / git 仓库但没有 GitHub 远端 / GitHub 仓库** —— 而这三种状态下同一句 rail 的意思完全不同，`gitAvailable: Bool` 这种二态表达不了它，于是有两个真实症状：① 提示词里的形状是 `makeEnv` 建 env 时抄下来的，同一个队列里第一个任务跑了 `git init`（或 `git remote add origin …`）之后，**第二个任务的提示词还在说「这不是 git 仓库」** —— 队列在自己两项任务之间从不转入空闲，面板的重新识别（`recheckWorkspaceShape`）被「这个工作区有任务在跑」挡在门外；② 「有仓库但没有 GitHub 远端」这一档，rail 把「不开 PR」的原因写成「**这个队列没有开自动 PR**」—— 那是队列设置，真因是**没有远端**，而这时代理唯一有用的那一步（`git remote add origin <地址>`）一个字都没提。现在：**纯模型 `TaskRepoShape`**（`.plain` / `.git` / `.github`，`detect(isGit:hasGitHubRemote:)`，「不是仓库」压过一切）把三态收成一处；**面板在写提示词的那一刻重新探测**（`IssueRunnerPanel.repoShape(path:)`，一次 `rev-parse --is-inside-work-tree`，是仓库才再问一次 `git remote -v`；闭包跑在 runner 的后台队列上，不占 UI 线程），所以队列里前一个任务刚做的转换，后一个任务立刻就知道；`pushes` 也随之改成 `queue.autoPR && shape == .github`（队列的 PR 承诺与工作区事实同时成立才要求 push）。三种说法各自说真话：**非 git** →「壳层不会切分支、不会提交、不会推送，直接在当前目录改文件即可；任务要求建仓库／提交就照做」，并给出 `git init → git remote add origin <地址> → push` 这条转换路径（壳层随后会重新识别这个工作区）；**git 无远端** →「commit，但**不要 push**：这个仓库还没有 GitHub 远端，壳层不会开 PR」，并给出 `git remote add` 那一步；**GitHub 仓库** → 原样（队列会开 PR 就 push，否则只本地 commit）。回归：`tests/tasks-panel` 运行器 **323 项**（+9，新增「git 仓库但没有 GitHub 远端：说「没有远端」，不说「这个队列没有开自动 PR」」一节，含反向断言「GitHub 工作区不会念叨没有远端」），`tests/tasks-panel/run.sh` 增加**源码守卫**：提示词必须在 `promptText` 闭包里现场探测工作区形状，禁止再退回「建 env 时抄一份」。 ⚠️ 其中「两条转换路径」（`git init → git remote add → push`）的措辞在**同一轮的后续修正里被用户否掉**（「这种信息没必要」），与 push / 「不要 push」一起从提示词里删除 —— 见上面「任务提示词按工作区状态『按需出条目』」那条。
- **删除队列之后，失败的 / 被取消的任务再也进不了「全部处理」**：批量当时只收 `.pending`（理由是「失败历史一起自动重跑风险大于收益」），可**队列一删，那些任务就回到未入队、卡片上只剩「加入队列」一个一个点** —— 于是用户看到的是「失败的还在失败，而全部处理不认它们」。现在按「归不归队列管」划分：`.pending` ✓、**队列被删后的 `.failed` / `.cancelled`** ✓（批量给它们各建一个新的单任务队列重新跑，旧错误在重新开始时清掉）、仍**在队列里的**失败 / 取消任务 ✗（那是泳道自己的事：重试 / 跳过并继续，全局批量不该悄悄复活一个被暂停的队列）。选择与计数收在 `TasksRunAllModel.startable(in:)` 一处，面板按它取任务，确认框的数字也来自它 —— 两者不会各说各话。
- **每个任务都失败在 `tasks.errSession`（建会话）**：任务面板自己有一份私有的 `createSession`，只发 `{workspaceId}` 就完事 —— **没有 cwd 回退**。而 `workspaceId` 是从 dsh 持久化的 workspace store 里读的，**很容易是陈旧的**（工作区已被移除/归档，或 store 由另一份 DSH_HOME 写过）；dsh 于是回 `workspace/not-found`，而 `resolveMainWorkspaceId` 又会把这个 id 一路传下去 → **该工作区里每个任务都失败**，且日志只有一行 `could not start (tasks.errSession)`，看不出原因。文档里写的两步策略（先 workspaceId、被拒退 cwd）只实现在共享的 `DshWorkspaceOps.createSession` 里（`tests/dsh-rpc` 有它的回退用例）。现在面板改为**调用那个共享实现**，并在失败/成功时各写一行 `app.log`（带上 workspaceId 与 cwd）；`tests/tasks-panel/run.sh` 增加一条源码守卫，禁止面板再自己拼 `DshWebRPC.sessionCreate`。
> 实测（内置 dsh web 0.1.2-rc.1 + 真实 Swift 代码）：`{workspaceId:"ws-does-not-exist"}` → `workspace/not-found`；共享的两步实现拿同一个陈旧 id 会**回退到 cwd 并成功建出会话**；只发 workspaceId 的老写法 → nil（正是用户遇到的现象）。
- **任务离开队列之后还带着那条分支**：`task.branch` 是开跑时从队列抄下来的记录（用于卡片 meta 与提示词），而 `dequeue` / `removeQueue` / `detach` 都没清它 —— 于是「移出队列」后卡片仍显示 `feature/x`，看起来像这个任务还会跑在那条分支上。现在离开队列即交还分支（分支是队列的属性），并且**卡片优先显示队列的分支**（`queue?.branch ?? task.branch`），issue 任务的提示词也不再拿 `task.branch` 当兜底。
- **非 git 目录里「全部处理」必然失败（`tasks.errNotGit`）**：`TaskQueue.auto(forManual:)` 无条件从标题派生分支（日志里的 `feature/git`、`feature/hello-world`），而那个目录不是 git 仓库 —— 批次 1 定下的规矩是「非 git 目录的队列**不设分支**」（§V2-7），`全部处理` 这条新路径绕过了它。现在 runner 把「这个工作区能不能切分支」作为 `env.canSwitchBranches` 传下去：不能切的目录里，自动队列**不带分支**（流水线因此从不碰 git），提示词也换成「这不是 git 仓库：不要 git init、不要 commit / push」，而不是自相矛盾地要求 commit。**已存在的坏队列会被就地修好**：重试时先把它那条切不了的分支去掉并记日志，否则重试和第一次一样失败。「全部处理」的确认框也按三种情形分开说（git+GitHub：开 PR／git 无 GitHub：只切分支／非 git 目录：不切分支也不开 PR）。
- **「全部处理」不再只管 issue：手动任务也各自一个队列、一条分支、一个 PR**。它是三个工具栏按钮里唯一不「属于 GitHub」的：语义是「把所有还在等的任务跑起来」，只认 issue 纯属历史原因。现在 `TasksRunner.startManualTask` 给手动任务建和 issue 任务一样的**单任务自动队列**（`TaskQueue.auto(forManual:)`：队列名 = 任务标题，分支 = `feature/<标题 slug>`，纯中文标题退回 `feature/manual-<id4>`，基线用工作区默认分支，`autoCreated` + 完成时开 PR），所以**批量不会把互不相干的任务捆到一条分支上**；批量按**板面顺序**串行推进（新增 `focus(onQueue:)` 把 runner 指回第一个队列，否则「最后 resume 的那个」会先跑），>1 时先确认，结果写进状态行与日志。**确认框与 tooltip 的职责分开**：**tooltip 只说这个按钮做什么**（图标按钮没有文案，只能靠它），禁用时补一句「没有待处理的任务」；**计数与「各自一条分支 / 是否开 PR」这类业务规则移进确认框** —— 那是用户真要下决定的时刻（计数在统计卡第一行本来就看得见，工作区是不是 GitHub 头部那行也写着）。顺带修掉一个真 bug —— `L10n.tr(key, args)` 把 `[CVarArg]` 数组整个当成一个参数传给可变参函数，`%d` 打出来的是**数组地址**（界面上出现过「全部处理：7935328 个手动任务」），现在每种计数形态各自调用一次。顺带两处修好：`nextStartable` 在**当前活跃队列空了之后会落到下一个有活的活跃队列**（此前会卡住 —— 同一批里其余泳道显示「活跃」却永远不动）；新增 `runningQueueID`，面板据此把真正在跑的那条标「活跃」。
- **根因：任务运行器把 dsh web 的端口"冻"在了服务器启动之前**。`app.log` 的时间线是唯一的真相：**00:51:37.129** 面板 adopt 工作区（`makeRunner → makeEnv` 读 `server.port`）→ **00:51:38.563** 服务器才选定端口（`… port=64679`）→ **00:51:43.176** 「dsh web is up on …:64679」。也就是说建运行器的那一刻 `server.port` **还是默认的 3080**，这个值被捕获进 `TaskRunnerEnv` 的五个会话闭包；而 3080 上跑的恰好是**另一台** dsh web（本仓库的 harness GUI），拿本实例的 token 去换 cookie 只会得到 **401**（实测：`GET /?token=<外来 token> → 401`、`POST /api/session/create → 401 unauthorized`），于是 `session/create` 永远返回 nil。面板只在**工作区路径变化**时才重建运行器，所以这个错端口会一直用到本次启动结束；三个任务全部倒在这里，界面只有 `tasks.errSession`（同一时刻用 `curl` 打真正的 64679，`session/create` 一切正常 —— 这正是「curl 能通、App 不能通」的全部原因）。现在 `TaskRunnerEnv` 不再捕获端口，而是保留一个**在每次调用时求值**的 `portOf()`（`serverPortProvider` 本身就是弱引用 `self.server.port ?? 3080`，不构成环），会话相关五个闭包（建会话 / 改名 / 发提示词 / 查状态 / 取消）全部改成调用时取端口；顺带把 `workspaceId` 也改成**建会话时**才解析（工作区可能在板子加载之后才注册进 dsh）。回归：`tests/tasks-panel/run.sh` 增加源码守卫，禁止运行器环境再出现冻结端口的调用形状。
- **空仓库（刚 `git init`）里紧接着的那个任务也能进队列分支**：上一条让面板重新识别出「这现在是 git 仓库」之后，下一个任务就会走**正常**的分支进入序列 —— 而它在空仓库里必然失败：`git checkout main` 在 HEAD 未出生（一条提交都没有）时报 `pathspec 'main' did not match`（`tasks.errCheckout`），而 `git init` 之后留下的文件全是未跟踪的，「工作区脏」那条检查也会先一步拦住它。`TaskGit.enter` 现在先问一次 `hasCommits()`（`rev-parse --verify --quiet HEAD`）：**空仓库跳过「干净检查 → 切基线 → pull」三步，直接用 `checkout -b` 从尚未出生的 HEAD 开分支** —— 没有任何提交可以丢，任务的工作自然成为第一个提交。**有提交的仓库完全不变**（回归 6 项：空仓库只做一次 `checkout -b`、既不查 status 也不 pull；普通仓库照旧先查脏、先切基线、再 pull；脏仓库仍然被拦住）。
- **提示词不再禁止任务自己要求的事（「初始化 git 仓库」曾经和它打架）**：非 git 目录里的提示词写着「不要 git init」，本意是**壳层那一半** —— 管线不切分支、不提交、不推送（§V2-7），可它读起来成了对整个任务的禁令：用户派一个任务叫「初始化 git 仓库」，提示词却让代理不要做这件事。现在这类 rail 只说自己：**「这不是 git 仓库：壳层不会切分支、不会提交、不会推送。默认直接在当前目录修改文件即可；任务本身要求初始化仓库或提交时，照任务做」**（第 4 条同理：「默认不要 commit、不要 push……任务要求建立仓库／提交时才做」）。
- **任务改了自己的工作区之后，面板重新识别它**：面板在 adopt 时定下「这个目录是不是 git 仓库、有没有 GitHub 远端」，并把这两个事实交给运行器的 env（非 git 的队列连分支都不给）。一个 `git init` 任务会让它们全部过期 —— 头部继续说「非 Git 仓库」、队列表单继续不给分支字段、「全部处理」继续说不切分支，直到重启或切走再切回。现在**任务结束（或该工作区转入空闲）时重新探测一次**：新增纯模型 `TaskWorkspaceShape`（视图模型 8 项断言）判断「变成了 git 仓库 / 多了 GitHub 远端」，面板据此 `workspaces.invalidate(path)` 重建运行器（env 里的 `canSwitchBranches` 必须重新抄一遍）并 `adoptWorkspace` 刷新头部与表单，状态行说一句「这个目录现在是 git 仓库 —— 已重新识别工作区：新队列可以使用分支」。两条纪律写在 `TaskWorkspaceRegistry.invalidate` 上：**不动 `reconciled`**（板子还是这次运行的板子，重新对账会把在跑的任务判成「上次运行被中断」）、**只在该工作区没有任务在跑时重建**（两个运行器会各自 step 同一张板子）。顺带：探测只在「答案可能变了」时才问 git（已是仓库且已知 GitHub → 一条命令都不跑），所以稳态零成本。
- **原生 RPC 失败不再是"它就是没工作"（`DshWebRPC.lastFailure` + 启动自检）**：排查上面的 `errSession` 时，用户重跑**仍然**每个任务失败，而日志只有一行「建会话失败」——因为 `DshWebRPC.call` 把 401（没换到 cookie）、端点不存在、业务错误（如 `workspace/not-found`）、传输层根本没拿到响应这四种完全不同的失败**都压成 `nil`**。用同一台 dsh web（同端口、同 token）以 `curl` 与真 Swift 代码请求 `session/create` 全部成功，端口 / token / 载荷 / 服务端都不是原因，原因只能出在壳层这一次请求内部，却没有任何东西说得出它是什么。现在每次失败都留一行可读原因（`<method> HTTP <status> <error.code> <error.message>`，401 且手里没有 token 时补 `no launch token — a token-fenced /api can never authenticate`），成功即清空（失败不会继承上一次的故事），面板的「建会话失败」日志与它拼在一起；并在**装上 launch token 之后立刻后台自检一次** `session/list`，把结果写进 `app.log`（`native RPC self-test: ok` / `FAILED — <原因>`）——被 token 围栏挡住的 /api 从此在**启动第一秒**就写在日志里，而不是等到某个面板「点了没反应」。回归：`tests/dsh-rpc` 固定四种形状（401 无 token / 业务错误带服务端 code 与 message / 传输失败 `HTTP -1` / 成功清空），整套 68 项。
- **交接简报：一任务一会话 + 显式把上一棒交给下一棒**。队列里「一个任务一个会话」是有意的（上下文小、审查/取消/会话名都是任务级的），代价是下一棒没有记忆 —— 于是队列里**第 2 个任务起**，提示词里多一段（2026-09-27 起改名为 `## 队列信息`，见本段末尾的修正）：队列名与位次、前面每一棒的标题与结局（**失败 / 被取消的也算**，否则重试就是从零探索）、**它们在各自会话里的最后一段汇报（原样带上，不截断** —— 截断会失真）、分支上相对基线已有的提交（`git log --oneline base..HEAD`），并以「不要重做已完成的部分，只做本任务；发现前面留下的问题先说明再决定是否顺手修」收尾。汇报的读取复用壳层已有的会话日志通道：core 新增 `sessionReport()`（`core/lib/review-log.js`）+ CLI `ohmy-core brief report <sessionId> [--workspace <dir>]`，读出的是 `assistant/message` 事件里最后一条有文本的消息；读不到时简报写明「它没有留下汇报」。简报在**后台步骤**里构建（读会话日志 + 问 git 都是阻塞的），并把它的大小写进 `app.log`（不截断意味着它会随汇报长度线性增长，日志里看得见）。
- **任务面板变成跨工作区作业台：切走的工作区继续被跟踪**。此前面板只有一个 runner，而每次换工作区都会重建它并跑 `reconcileAfterRestart` —— 于是「在 A 派了任务 → 切到 B 看别的东西 → 回 A」看到的是一张「失败 · 上次运行被中断」的卡片，可那个 dsh 会话还在后台跑完、跑完也没有任何东西更新它。**而「切到别的项目去等」恰恰是任务台存在的意义。** 现在：① 新增 `TaskWorkspaceRegistry`（`TasksWorkspaces.swift`，无 AppKit、可无头测试）——**当前工作区 + 任何仍有任务在跑的工作区**各持一个 runner，非当前且仍在跑的一直被 tick（会话结束照常收尾、照常开 PR），空转的则被放下（板子在磁盘上，切回去重建）；② 对账（reconcile）**每次运行、每个工作区只做一次** —— 重复重建不再把在跑的任务判成中断、不再平白暂停队列；③ git 按工作树串行，所以不同工作区可以**同时**跑（A 改代码、B 跑测试）；④ 可见性三件套：活动栏小点 = 任意工作区在跑、面板头部一个「别的工作区有任务在跑」的图标（悬停列出「工作区 — 任务标题」，选中即切过去，走的是项目面板同一套 `adoptProjectDirectory`）、任务结束提醒带工作区名，且**在面板里也会用状态行说一句**（几个工作区同时跑时，只发生在日志里等于没发生）；⑤ **一次 tick 只查一次会话列表**（`beginSessionPoll` 快照），N 个在跑的工作区不会向 dsh 要 N 份同一列表。
- **任务跑起来之后，看得见也追得上**（批次 2 —— 可见性）。四项：① **活动栏「任务」图标加一个角落小点**（`ActivityBarButton.showsActivityDot`，独立于 `setActive` 的「当前面板」高亮），面板关着也知道有任务在跑；② 任务**在后台结束**时弹一下 Dock 图标并留下角标 `✓` / `!`（`NSApp.requestUserAttention` + `dockTile.badgeLabel`，聚焦即清 —— 用系统通知要多一道授权，这个不需要），用户主动取消的不打扰；③ **卡片直接给两条出口**：「打开会话」（把这个任务的会话切到 dsh web）与「审查改动」（`reviewPanel.setActiveSession` 直接把这个会话交给审查面板），两者都只调用壳层早就有的机器（`openDSHSession` 桥 / 审查面板的会话跟随），此前卡片上的「会话：xxx」是死文本；④ **运行中的卡片带时钟**（meta 行第一项「已运行 1:05」，超过一小时 `h:mm:ss`），并且 3 秒定时器的重绘指纹里带上这一分钟 —— 否则 `0:59` 会永远停在那里。
- **等待中的队列不再谎称「活跃」**：同时可以有好几个队列是 `.active`（对第二个点「开始」只是把 runner 指过去），而界面让它们全都显示「活跃」、同时又把「开始」按钮藏起来 —— 用户看到的是一个永远不动的活跃队列。现在只有**真正在被处理的**那个显示「活跃」，其余显示**「等待中」**（`QueueHeaderModel.isCurrent`，取自 `board.activeQueue()`）。
- **统计卡跟着来源筛选走**：切到「手动」时它还在报整张 board 的「队列 N · 排队 N · 运行 · 失败」，跟下面列出的泳道对不上。现在 `TaskBoard.summary(source:)` 与 `TasksSummaryModel.build(_:source:)` 按同一个筛选计数（队列数也只算「含有被显示任务」的队列）。
- **已完成的队列默认折叠成一行**（此前只有 issue 的自动队列这样），列表不再被历史泳道撑长。
- **失败任务终于能「跳过并继续」，而不是只有「重试」**。`TasksRunner.skip` 一直是死代码（全仓零调用者），而 README 与设计文档一直承诺「卡片给「重试 / 跳过并继续」」：队内任务失败后队列被暂停，用户只剩「重试同一个」或删任务 / 队列两条路。现在失败 / 取消任务的卡片上多了**「跳过并继续」**（保留这条失败记录、唤醒队列、跑下一个），并且只在**队里确实还有排队任务**时出现 —— 跳过一个没有后续的队列只会唤醒一个没活干的队列。队列头的 ▶ 在「暂停 + 有失败 + 还有排队」时，tooltip 也从「开始」改为**「继续：跳过失败的任务，跑下一个」**，因为它做的事从来不是「开始」。
- **灰掉的主按钮现在会解释自己**：已完成却没有 PR 的任务，主按钮「打开 PR」是灰的且此前没有任何说明，现在带 tooltip「这次没有 PR（建 PR 失败，或这个队列没开自动 PR）」。
- **项目面板（Projects，`⌥⌘P`，活动栏首位「项目」图标）：把「工作区 = 一个目录」变成壳层里的一等公民**。面板以可配置的**项目根目录**（默认 `$DSH_HOME/oh-my-dsh/projects`，可改成任意绝对路径，存 `shell/config.json` 的 `projectsRoot`）为范围，每个直属子目录就是一张工作区卡片：
  - **新建工作区**只需输入目录名：面板 `mkdir -p <root>/<name>` 后调 dsh 的 `workspace/create`（**幂等**、路径须已存在）注册；注册失败（dsh 未起来 / 旧版本）只标「未注册」并在下次操作重试，**目录保留**；名字规则在创建前拦截（空 / 含 `/` 或 `:` / 以 `.` 开头 / 超 64 字符）；同名目录已存在按「采用」处理，不报错；
  - **六个快捷入口**：文件 / 终端 / 知识库 / 任务 / 通道 / 审查——点一下即把壳层当前工作区切到它并打开对应面板（终端 cwd、文件树根、wiki 根、任务·通道·审查的工作区一起跟随）；
  - **新会话**：点 dsh web 侧栏**该工作区行自带的 `+`**（注入桥 `window.__dshNewSession(工作区名)`）——由 dsh 自己决定**复用该工作区已有的空会话**还是新建，然后打开它，壳层只是"替用户点了那一下"；**在 dsh 中打开**（点卡片名称）复用该工作区最近一条**可打开**的会话（`blank` 空会话在侧栏不可见，故跳过；运行中优先），没有则走「新会话」；另有在 Finder 中显示 / 复制路径；
  - **新建即选中（壳层 + dsh web 两侧）**：创建（或采用）工作区成功后 ① 面板立刻经 `onSelectWorkspace` → `adoptProjectDirectory` 把它变成**当前工作区**——卡片**高亮**、各面板重根到它，并把该卡片**自动滚进视野**（列表按名字排序，新卡片常在很下面；日志 `projects: selected the new workspace …`）；② 注册成功后 `onWorkspaceRegistered(path)` → **dsh web 也切到该工作区**（点它侧栏行的 `+`：dsh 复用该工作区的空会话或新建，然后打开，侧栏行还会滚进视野）——这也正是 dsh 自己「添加工作区」的行为（`WorkspacePickFlow.onPick` → `startSession`）：**一行工作区行不等于"当前工作区"**，没有会话的 workspace 在 web 里没有可选中项，不这么做页面会一直停在上一条会话上。被名字规则拒绝的名称不建目录、也不改变当前工作区；
  - **单一真相**：当前工作区始终是壳层的 `ProjectDirectory`，重根收口到新抽出的 `AppDelegate.adoptProjectDirectory(_:)`（`dshSession` 跟随、面板快捷入口与新建工作区共用同一个原语，面板只做高亮——**不引入第二个"面板内选中项"**）；该原语带 `fileExists` 守卫，拒绝把面板重根到已消失的目录（旧代码会照常重根）；
  - **侧边栏延迟**：刚注册的工作区由 dsh 自己的**工作区流**送达客户端侧栏（实测 **~0.17 秒**出现在侧栏 DOM，**不需要刷新、更不需要重连**）；「新会话」的桥内部重试 12×150ms 等工作区行出现，「在 dsh 中打开」失败后 1.5s 再试一次，仍失败就**放弃**并写面板状态行——**永不自动重载页面**（旧版的失败重载 + `didFinish` 重放会形成每 ~10s 一轮的死循环刷新，已在 `ed989ac` 删除）；
  - **未注册的目录不联动**：项目根目录下某个目录若不在 dsh web 的 workspace 里，卡片就不提供 dsh 动作（「新会话」禁用、点卡片只在状态行提示），六个**本地**面板入口（文件/终端/知识库/任务/通道/审查）照常可用，并在徽标后面多出一个 **folder+ 图标按钮「添加工作区 / Add workspace」**（与 dsh web 同词；幂等注册 → 徽标翻「已注册」、dsh 动作解锁）；**已注册**的卡片则在徽标后面显示 **`+` 图标「新会话 / New Session」**（两个按钮互斥，都在标题行）；
  - 实现：`platforms/macos/src/ProjectsCore.swift`（纯模型：根目录解析 / 命名规则 / 目录列举 / 与 dsh 注册表按 canonical 路径合并）、`ProjectsPanel.swift`（面板：卡片三行 + 头部 + 根目录行 + 空态 + 结果行 + 取名 sheet）、`DshWebRPC.swift` 新增 `workspaceCreate` 端点与 `DshWorkspaceOps`（注册 / 建会话 / 按工作区挑会话）、`main.swift` 接线与设置窗口「项目」区块（路径字段 + 选择…/保存/恢复默认）；测试 `tests/projects-panel/`（模型 45 项 + 控制器无头 49 项 = **94 项**）与 `tests/dsh-rpc/` 新增 14 项（整套 54 项），均已接入 CI 与 `scripts/local-ci.sh`；设计见 `docs/design/panels/projects-panel-design.md`。
  - 顺带修正 `DshWorkspaceStore.canonical`：改用 `realpath(3)`，让 macOS 目录列举给出的 `/private/var/...` 与用户/dsh 存写的 `/var/...` 归一到同一条工作区（此前两种写法互不相等，面板会把已注册工作区标成「未注册」）。

- **Files 面板：目录树右键「添加到对话」把文件/文件夹作为 `@` 引用插进 dsh web 的输入框**：在文件或文件夹上右键 → **添加到对话** → 输入框末尾出现该条目（文件夹带尾斜杠，含空格的路径走 dsh 的 `@"…"` 引号语法）的引用 chip —— 与用户自己敲 `@` 从候选里选出来的是**同一种节点**，提交时序列化成同一段 `@相对路径` 文本。项目根与空白处不提供（没有「相对的自己」）；未打开会话时条目禁用并提示。**不改 dsh 源码**：壳层把 chip 节点直接写进 dsh web 的 Lexical 编辑器（`window.__dshInsertFileReference`），不伪造按键也不依赖焦点。新增纯模型 `platforms/macos/src/ComposerReference.swift`（引用语法 + 相对路径，无头单测 `tests/file-panel/composer-reference-tests.swift`）与目录树菜单规则/用例更新；真 WKWebView 实测与 dsh 升级核对项见 `docs/process/dsh-version-impact.md` B9 与 `docs/design/panels/file-panel-composer-reference.md`；QA 钩子 `DSH_COMPOSER_TEST_PATH` / `DSH_COMPOSER_TEST_SESSION`。

### Changed

- **重启之后的「刚才发生了什么」不再只写在日志里**：上次运行中被中断的任务会变成「失败 · 上次运行被中断」、活跃队列会被暂停 —— 这两件事此前只进 `app.log`，界面看上去就是莫名多了几条失败。现在面板开机会用状态行说一句「上次运行被中断：N 个任务已标为失败、M 个队列已暂停（不会自动重跑）」（10 秒后自动收起）。
- **「处理」按钮挪到工具栏第一位，并改成按「有没有待办」启用**：它是这个面板的主操作（开始干活），也是三个按钮里唯一在任何工作区都能用的那个（刷新 / Token 仍然只在 GitHub 工作区可用）。没有待处理任务时禁用并说明原因，不再是一个点了没反应的按钮。
- **任务面板顶部：工作区信息并进标题行，非 git 与 非 GitHub 分开说，GitHub 专属按钮不可用时置灰**。此前「目录名 · 非 GitHub 仓库」独占一条 28pt 工具栏行（整行为一行短文案，而审查面板同一条行放的是控件），而且不管目录**根本不是 git 仓库**还是**只是没有 GitHub 远端**都只说「非 GitHub 仓库」。现在：① 工作区行并入标题行（头部 40pt → 46pt 两行，净省 22pt 给列表），三种说法分开 —— GitHub 仓库 `owner/repo`、git 仓库无 GitHub 远端 `目录名 · 非 GitHub 仓库`、非 git 目录 `目录名 · 非 Git 仓库`；② 新增纯模型 `TaskWorkspaceModel` 决定这行文案与三个 GitHub 专属按钮（**配置 GitHub Token** / 刷新 Issues / 全部处理）的可用性 —— 非 GitHub 工作区里它们本来就 guard 掉了 repo、点了什么都不会发生，现在置灰并给出原因 tooltip；③ 新增 `FittingHeaderLabel`（`PreviewPanel.swift`）：`HeaderLabel` 用 `NSString.draw(at:)` 画字，既不清除也不省略（实测 165pt 的文案在 90pt 的 frame 里会向右侧多画 1004 个像素点），长目录名会画到旁边按钮底下 —— 这个子类在每次布局时把文字按自身 frame 截断成「…」，tooltip 保留全文。回归：离屏渲染新增 10 项（框内有墨 / 框外 0 像素 / 朴素 HeaderLabel 确实越界这条前提 / 无宽度时先不画 / 重复 fit 收敛），视图模型新增 11 项（三种工作区说法 + 按钮可用性 + 没有工作区时的文案）。
- **表单抽屉背后加了一层虚化背景（抽屉与内容区分层）**。抽屉和内容区用的是同一套面板底色，表单打开时只是"列表里多了一张卡"。现在 `TaskFormSheetHostView` 里有一层 `NSVisualEffectView`（`material = .hudWindow` + `blendingMode = .withinWindow` + `.active`）：模糊同一窗口里它背后的内容，并叠一层半透明暗色（即使模糊不生效也不会退化成看不见，列表照样被压到后面）。它铺满整个内容区、**在抽屉之下列表之上**，随抽屉一起淡入淡出（同一个动画组，0.22s easeOut；连续创建时不重播），没有表单时 `isHidden` 且宿主照旧点击穿透。回归断言：静止不出现 / 材质与混合方式 / 打开后铺满内容区 / 层级在抽屉之下 / 关闭后收起。离屏 `cacheDisplay` 渲染不出虚化，视觉以真机为准。
- **队列头的三个操作从 ⋯ 菜单里放出来，成为行上的图标按钮；PR 相关项跟着工作区可用性走**。队列设置（`gearshape`）/ 完成后自动开 PR（`checkmark.circle.fill` 开 · `circle` 关，开着用强调色）/ 删除队列（`trash`，仍走确认框）现在都在队列头第一行上，`⋯` 与其菜单整个删除（`tasks.queue.more` 文案键随之删除）。**非 GitHub 工作区不再给一个点了也没用的「完成后自动创建 PR」**：`QueueHeaderModel.prAvailable`（= 面板的 `repo != nil`，与队列表单同一判据）为假时，还没开的队列整块不显示该开关，**已经开着**的队列仍显示但不可点、tooltip 说明原因（状态不隐藏）；`canOpenPR` 也要求 `prAvailable`。`CustomIconButton` 新增常驻图标色 `tintColor`（nil = 原行为），开关"开着"用它表达。回归：视图模型三态 + 视图断言（行上有 gear/trash、没有 ellipsis、开关随状态与工作区切换、300pt 最小宽度下不撑破）。
- **「加入队列 ▾」下拉换成文件面板「打开项目 ▾」那一个控件，并把新建队列排到第一项**。此前卡片上的 加入队列 是普通 NSButton（点了就执行），菜单锚在**卡片左上角**（盖住卡片自己），按钮上也看不出有下拉。现在：① 控件用壳层的 `PanelMenuButton`（图标 + 文案 + chevron + hover/打开高亮，窄了自动退化成图标 + chevron 小片）—— 与文件面板是同一个控件；② 菜单落在**按钮正下方**（`at: NSPoint(x: 0, y: -6), in: button`，与 `FilePanel.popBelow` 同写法），空间不够时 AppKit 自行上翻；③ 下拉项由新的纯模型 `QueuePickerItem.build(choices)` 生成，**第一项固定是「新建队列…」**，其后才是按创建顺序排的已有队列（行里带分支），空 board 时只有这一项；卡片 `hitTest` 放行 `PanelMenuButton`（否则点击会被卡片吞掉去展开/收起）。
  回归：视图阶段断言「未入队卡片只有一个下拉、文案 加入队列、onShowMenu 把按钮自己交给面板」「已入队卡片是普通 NSButton、没有下拉」；视图模型阶段断言下拉顺序。
- **任务创建改成一个框：首行是标题、其余行是描述（单行则两者都是）**。此前「新建任务 / 编辑任务」是标题 + 描述两个字段，描述还是必填项 —— 于是只想记一句话的任务也要把同一句话写两遍。现在只有一个内容框（多行编辑器，默认 160pt、随输入长高、上限 260pt 后内部滚动），切分与回落全在纯模型 `TaskDraft` 里：`composed(from:)` 把首行当标题、其余行当描述（非首行全空白 = 单行），单行时这一行**同时**是标题与描述；`combined(title:body:)` 是它的逆运算，编辑回填进同一个框（描述就是标题时回到单行，不会写两遍）；`effectiveBody` 让「没有独立描述」的草稿在存储层自动用标题兜底，所以 `createManualTask` / `updateManualTask` 落到 board 的任务永远带着一段可发给代理的正文。
随之：**只有标题是必填的**（空框报 `tasks.errName`，`tasks.errBody` 删除）；单行任务的描述 == 标题，通用提示词与卡片详情都不再重复打印这句话；**Enter 改为换行**（首行/其余行都要靠它分行），**⌘↩ 提交**、Esc 关闭，信息行写明了规则；文案键 `tasks.new.name` / `nameHint` / `body` / `bodyHint` 删除，新增 `tasks.new.content`（任务内容）与 `tasks.new.contentHint`（占位文案）.
回归：`tests/tasks-panel` 四阶段 **562 项**（拆行 / 往返 / 单行兜底 / 编辑回填单行 / 面板与提示词不重复 / 空框报错 / 单框尺寸与长高），表单阶段改用 `type()` 直接往那个框里输入。
- **任务面板卡片样式对齐审计面板（同一套方块语法）**：圆角 8 + **一条发丝线**（浅 0.80 / 深 0.38@0.7），底色改由**嵌套层级**决定而不是交互状态 —— 队列泳道 = 抬起档（白 / #43454A）、**队内任务卡 = 下沉档**（#F1F3F5 / #353638）、未入队卡片（直接站在面板上）= 抬起档，正好是审计面板「会话 → 对话 → 文件」的白 → 白 → 灰阶梯；
队列头与卡片都改用审计面板的 chevron **符号**（`chevron.right`/`chevron.down`，11pt semibold，14pt 槽位；队列头此前是文本 `▸/▾`，卡片此前没有 chevron）；头部内边距统一 8/7，泳道子卡片缩进 12/10、上 6 下 8；标题下的元信息行改为 10pt tertiary —— 与审计面板块标题下的 id/时间/prompt 行同槽同字号；
**唯一的强调色收敛到「当前」**：运行中的任务卡用审计面板「dsh web 当前会话」的那一套 accent 淡填充（浅 0.20 / 深 0.40）+ accent 边框（0.45/0.55），队列状态（活跃 / 失败 / 已完成）与卡片展开态**不再染边框或改底色** —— 泳道边框不再按状态着色、展开态不再换成强调边，状态一律回到徽标里；**hover 提亮去掉**（卡片底色现在只表达层级，不表达交互）；
刻意保留：标题行的来源/状态徽标（审计面板在同一槽位放等宽 10pt 摘要）、展开后的详情与操作按钮行。
验证：把审计面板的方块参数离屏复刻，与队列泳道/任务卡并排渲染浅色 + 深色两版比对（`/tmp/card-style-light.png` / `-dark.png`）；`tests/tasks-panel` 四阶段 529 项（新增 `TaskCardModel.isNested`「队内卡片下沉 / 未入队卡片抬起」两问，泳道高度断言由写死的 150pt 改成相对断言）。
- **任务面板布局对齐审查面板：统计信息从工具栏搬进内容区、标题与状态合并到同一行**（顶部保持「标题行 + 两行工具栏」，只是工具栏再不放计数）。
顶栏仍是 40pt 标题行（任务 + 刷新 / 全部运行 / 配置 / 关闭）与 28pt 工作区行 + 32pt 来源页签行；四枚计数胶囊从工作区那行**移出**，改由**内容区第一行**的 `TaskSummaryCardView` 承担 —— 整宽圆角卡（抬起档底色 + 发丝描边 + 11pt 文字，与任务卡同 12pt 内边距对齐），一行 `队列 12 · 排队 5 · 运行 1 · 失败 1`，**只有失败 > 0 时那一段变红**（`TaskSummaryPart.tone`），位置与滚动行为跟审查面板的摘要卡一致（列表第一行，随列表滚动）；
任务卡的**标题与状态徽标合并到同一行**：`[来源徽标] 标题 [spacer] 状态徽标`，栈对齐用 `.top` 而**不是** `.centerY`，因此长标题折到两行时徽标仍贴在**首行**（`.centerY` 会把徽标浮在两行中间）；徽标压缩阻力置 required、标题降档并带全文 tooltip，窄面板先截断标题；
顺带修掉一个一直存在的徽标截断：`TaskBadgeView` 的固有宽度少算了自身内边距（6pt × 2），凡是让 Auto Layout 按固有宽度排徽标的地方都会被裁掉一两个字（实测「队列中 #2」只剩「队列中 #」、「手动」只剩「手」，进度 `0/2` 也短一截）——现在固有宽度 = 标签 + 内边距；
顺带：`refreshTooltips()`（语言切换）现在会在有 board 时**重跑 `render()`**，卡片与摘要卡的文案不再停在旧语言（此前只有工具栏胶囊被重建）；清掉不再引用的 `tasks.summary` 键；卡片 / 泳道 / 摘要卡共用的两条发丝灰度收进 `TaskInk`。
回归保护：`tests/tasks-panel/` 新增「标题与状态同一行」（走查两枚徽标的坐标：来源在标题左、状态在标题右、两者都落在标题首行的高度带里）与「统计信息卡」（撑满宽度 / 一行 / 四个计数齐全 / 零失败中性、有失败变红）；视图阶段 95 → **117 项**、视图模型阶段 128 → **130 项**，四个阶段合计 **527 项**。
- **任务面板：新建/编辑任务、新建队列、队列设置全部改成面板内的内联表单（不再弹 NSAlert），整体样式对齐其他面板**。
此前 `+ 新建任务`、卡片「编辑…」、「加入队列 ▾ → 新建队列…」都靠 NSAlert + accessoryView：对话框盖住整个列表、挪不动、关掉即丢值，也没法和它作用的对象对上位置。
现在它们都是**从内容区顶部下拉的抽屉**（新文件 `TaskInlineForms.swift` + `TasksUI.swift` 里的纯模型 `TaskComposerModel` / `QueueComposerModel`），入口是**页签行右侧右对齐的两个图标按钮**「＋」= 新建任务、「▣＋」= 新建队列（标签在 tooltip；空态另给文字按钮「新建任务」）：
抽屉横跨整个面板、顶部距内容区 8pt、往下滑出（**输入框宽度 = 面板宽度 − 48**，此前作为列表卡片只有约 256pt），宿主透明、masksToBounds、**点击穿透**，滑入过程只在工具条以下可见、也不挡列表点击；高度上限 = 内容区高度 − 16，超出时先压缩描述框并让它滚动，**表单按钮永远在可见区**（底部抽屉会遮住按钮）；从卡片「加入队列 ▾ → 新建队列…」建队时顺手把这一个任务入队；队列「⋯ → 队列设置」用同一张抽屉改队列名 / 分支 / 基于分支 / PR 开关（重命名与改分支两个对话框随之消失）。
输入框整体放大：单行框 `controlSize = .large` + `roundedBezel`、高 30pt、字号 13pt，描述框默认 120pt。
**队列分支文案（2026-09-25l）**：分支框的占位文案此前是一句混合语义的"留空 = 自动生成（不带分支则不切分支）"——它把**新建**与**队列设置**两种相反的含义挤在一行（新建时留空 = 按队列名派生一个分支，队列照常切分支；队列设置里留空 = 不切分支、在当前分支上跑），只在纯中文名（无法派生 slug）时才显示，最容易误解。现在按模式分开说：新建占位是"留空 = 按队列名自动生成"（能派生时直接显示 `feature/<slug>`），队列设置占位是"留空 = 不切分支（在当前分支上跑）"；无法派生时提示语写"自动生成（如 feature/queue-1a2b）"。

**抽屉高度改成纯约束驱动（2026-09-25k，最终做法）**：前两次修的都是"事后测量再加回调"的补丁，对布局时序太脆弱（实测在真实点击下仍会滞后一整拍）。现在**没有任何测量**：抽屉自己用一条约束跟随表单的高度（`TaskFormSheetView.setContent` 内 `sheet.height == form.height` @999），面板只加一条"不高于内容区"的上限（required）。于是表单内部长高（展开高级设置、描述框变长）在**同一个布局回合**里就把抽屉撑开——不依赖 frame、不依赖回调、也就没有滞后可言；表单太高时上限生效，表单保持自身高度、内部滚动。`idealHeight()` / `preferredHeight()` / `onHeightChanged` / `syncFormSheetHeight()` 全部删除。

**抽屉滞后一格（2026-09-25j）**：上一版的修复在真实点击下仍然晚一拍——展开时抽屉不动、再点一次（收起）抽屉才长高。原因是测量读的是**视图的 frame**，而 frame 只跟得上**上一次**布局：
点击后立刻测量拿到的是变化前的高度。现在表单按自己的内容测高（`TaskFormCardView.preferredHeight()` 用内部列栈的 fittingSize + 上下内边距），不依赖 frame，点下去立刻就是新高度（上/下内边距都要算，少算一个会让抽屉比表单矮十几点、又冒出滚动条）。

**抽屉没跟着表单长高（2026-09-25i）**：展开「高级设置」后抽屉高度不变、多出来的字段只能滚动 —— 真正的原因是抽屉只在**面板布局**时重新测量，而"表单内部长高"（高级设置展开、描述框变高）根本不触发布局。现在表单自己上报高度变化（`TaskFormCardView.onHeightChanged`），面板收到后重新测量并带动画把抽屉撑开（0.16s ease-out），尺寸在下一帧生效前补一次布局（否则滑入动画会用旧高度）。

**队列抽屉的高级设置（2026-09-25h）**：展开「高级设置」后抽屉变高，在常见面板高度下会顶到上限而出现滚动条。改法是把这张表单压短：分支 / 基于分支改为**标签在左、输入框在右**的横排（原来是标签在上，三行共省 ~36pt），高级设置内部间距 8 → 6，抽屉高度向上取整避免"差半个点"就闪一条滚动条。展开态从 314pt 降到 **274pt**，实测内容区 ≥290pt 时**整表单显示、无滚动条**（600/400/340/300pt 都不滚动；260pt 以下才回落到滚动）。

**抽屉的点击（2026-09-25g）**：表单打开时抽屉所在区域**不再穿透到列表**——此前宿主视图统一"点击穿透"，于是点表单周围的空白（或从表单上方划过的点击）会落到背后的任务卡片上，把卡片展开/收起。现在没有表单时宿主仍然穿透（列表照常可点），一旦表单打开就整块吞掉点击（宿主自身收到点击不做任何事），关闭表单后恢复穿透。

**描述框（2026-09-25f）**：之前的 "多行 NSTextField" 是假的——可编辑 NSTextField 的 cell 对任何高度都只报一行（实测 `cellSize(forBounds:)` 恒为 30pt），所以那只是一个加高的单行框。现在描述是**真正的 NSTextView**，与单行框一起住进**同一个自绘输入框**（`TaskFieldBox`：圆角 6、下沉底色、发丝边框；单行框改为无 bezel 的 NSTextField 放在里面），两者样式由构造保证一致；文本按可见宽度换行、整个区域可点，高度随输入增长（120 → 最大 260），超过最大高度时文本视图继续长高并**内部滚动**（不会把内容藏起来）；空态有 placeholder 提示。

**描述框与队列表单的第二轮修复**：
- **任务描述**换成与单行框同款的多行 `NSTextField`（同 bezel / controlSize / 字号）：此前是 NSTextView 套滚动视图，一是边框样式与单行框不一致，二是它的文档视图会自我压缩到一行（实测高 54pt、只有第一行可点、换行后看不到）；现在默认 **120pt** 且**随输入长高**，**最小 88pt**；
- **表单不再"缩小自己"去适配矮面板，改成抽屉内部滚动**：抽屉高度按表单的自然高度设定（上限 = 内容区高度 − 16，实测 600/420/366/320pt 面板都是整表单显示），超出时表单在抽屉里滚动，描述框始终保持 120pt（最小 88pt）—— 之前是压缩描述框到 54pt，文本框无法换行；
- **队列表单简化**：只有「队列名」是必填，**分支 / 基于分支 / 完成后创建 PR 收进「高级设置」**（新建时默认折叠，队列设置时默认展开），折叠状态下用一行「将使用分支：feature/<slug>」说明结果，分支框的 placeholder 就是将要使用的分支；
- **PR 勾选框**在工作区不是 GitHub 仓库时**整个隐藏**，改为一行说明（队列只切分支 + 推送，不创建 PR）—— 之前是一个灰掉点不动的勾选框。

**输入框宽度修复**：表单每行此前是"贴合内容宽度"的（垂直栈 .leading 对齐 + 空文本框固有宽度几乎为 0），实测输入框只有约 25pt 宽、placeholder 被截成一个字；现在除按钮行外的每一行都钉到表单宽度，输入框 = 面板宽度 − 48（430pt 面板 → 398pt），描述框同时改为按可见宽度换行（原来它的文档视图比可视区宽 318pt，长行被裁掉而不是折行）。
提交按钮跟随字段的合法性，Enter 提交、Esc /「完成」收起并卸载；**新建任务提交后抽屉保持打开并清空**（连续录入），编辑保存后关闭；面板头的 `+` 与队列分区头的「新建队列」删除（同一动作只留一个入口）；**只剩破坏性确认框**（删除任务 / 删除队列 / 评论并关闭 issue）。
样式同时按 `docs/design/shell/ui-color-scheme.md` 与其它面板重做：卡片圆角 8 + 与技能卡一致的描边、hover 提亮、展开态与运行态各一档强调边框、标题 13pt semibold、元信息 11pt；
**队列改画成容器**（审计面板的树体例）：泳道底色比卡片暗一档、边框随队列状态着色，队列头与队内卡片同处一块、队内卡片**再向内缩进一层**且保持抬起底色 —— 队列与任务的包含关系一眼可辨；队列头两行（名称 + 状态徽标 + **图标按钮** 开始/暂停/开 PR/⋯ ／ 分支 → 基线 + **进度条** + n/m + 失败数）；
工具栏拆两行（工作区／来源筛选**扁平页签**，页签在窄面板下让位、按钮不压缩）；分节标题 12pt bold + 发丝线；空态 = 图标 + 文案 + 动作按钮。（四个计数胶囊 2026-09-25 起搬进内容区第一行，见上方条目。）
顺带修掉两个真实缺陷：卡片/队列头**此前没有宽度约束**（各自贴合固有内容宽度，不撑满列表），以及列表 documentView 只钉了宽度、缺 leading/top 钉接。
回归保护：`tests/tasks-panel/` 的**视图阶段 95 项**（无窗口 AppKit 驱动两张表单的字段/按钮/提示与提交流程，并断言「320pt 宽下卡片与队列恰好 320pt」以及「队内卡片左缩进大于泳道头、右缘不越出泳道」），视图模型阶段 **128 项**（内联表单校验、空态、计数、进度比例），四个阶段合计 **503 项**（两者后来分别增至 117 / 130 项，见上方布局条目的 527 项）。

- **活动栏图标顺序调整：「浏览器」从第 4 位挪到末位「技能」之前**（新顺序：项目、文件、终端、知识库、任务、通道、审查、浏览器、技能）。九个图标互斥切换与快捷键（⌥⌘B 等）全部不变，只是「浏览器」（`globe`）与「技能」（`puzzlepiece`）相邻，方便排查网页问题时顺手切技能面板；**「视图」菜单项顺序同步对齐**（此前菜单里「浏览器」排在第 6 位、与活动栏并不一致，现在两处顺序相同、一列到底）。

- **视图菜单「显示/隐藏 预览面板」正名为「显示/隐藏 文件面板」，快捷键由 `⌥⌘P` 改为 `⌥⌘F`**：该面板的实现从 v1.7 起已由 `FilePanel.swift` 承担，活动栏（`bar.preview` = 文件 / Files）、面板头部与 README 里也一直叫「文件」，只有视图菜单还留着旧名「预览」。同时把 **`⌥⌘P` 空出来给即将落地的「项目」面板**（本提交只做让位，面板本身单独评审）。L10n 键同步改名 `menu.togglePreview` → `menu.toggleFiles`（避免留一个名不符实的死键），设置窗口的快捷键清单同步更新为 ⌥⌘F。

### Fixed

- **对话末尾的「交付文件」卡片点击不再进 dsh 自带侧栏，改在壳层文件面板打开（2026-09-29）**。dsh ≥ 0.1.5 的 turn tail 有两组文件 UI：`read`/`write`/`edit` 工具行与「Files changed」产出文件行此前已被点击捕获层覆盖，但 `present` 工具的**交付文件卡片**（`[data-presented-files-row]` 里的 60pt 圆角卡片）漏了：整卡遮罩按钮与卡上的「打开」按钮都走 `openFile` → dsh 自带侧栏。现在点击捕获层把这类卡片也纳入——路径取卡内带 `title` 的遮罩按钮（「打开」按钮没有 `title`，从卡内取）；卡片右侧的 chevron（`aria-haspopup="menu"` = 用默认应用打开 / 在 Finder 中显示）明确放行给 dsh。回归：`tests/preview-interceptor` +4 例（遮罩点击、无 `title` 的「打开」按钮从卡内取路径、chevron 放行、host 状态重试按钮放行；共 15 例），`DSH_PREVIEW_DEBUG=1` 探针新增合成交付卡片的命中/吞事件自检，README 文件面板小节与 `docs/process/dsh-version-impact.md` B7 同步。

- **终端：中文/宽字符显示错位、光标只压住半个汉字**。等宽字体（SF Mono）没有 CJK 字形，Core Text 回退到一个全宽字面；字号 13pt 时它的 advance 实测只有 12.9pt，而终端网格给宽字符留的是两格 = 16.07pt（约 1.6 格）—— 汉字因此比自己的格子窄，后面的文本与光标又都按格子定位，看起来就是「错位」；光标块又固定一格宽，停在汉字上时只压住半个字。现在：① 宽字符从 run 里单独拿出来，用 CTM 横向缩放到正好两格（`drawGlyph`），后续 run 也固定在自己的格子上；② 光标块按 `cursorGlyphSpan` 跨整字（停在 continuation 格时回到 lead 格、宽 2 格），汉字以同样方式缩放画在光标底色上。回归：`tests/terminal-panel` 新增 5 项（宽字前进两格，光标在宽字 / continuation / 窄格上的跨度）。

- **终端：vi/vim 里用方向键滚到底行时画面不动（DECSTBM 滚动区此前被丢弃）**。终端模拟器把 `CSI top;bottom r` 解析后**直接忽略**（旧文档化的 v1 限制），而 vim/vi 正是靠这个滚动区把文本区与状态行分开：它先设 `1;(rows-1)r`，再在区域底行用换行 / `ESC S` / `ESC L` 滚动。忽略区域时，区域底行的 `\n` 只把光标下移一格（于是落进状态行），文本却纹丝不动 —— 这正是「方向键移到最后一行、文件不整体移动」，而 PageDown/PageUp 因为整屏重绘看起来正常的原因。现在 Swift 实现与共享核心 JS 端口都实现 DECSTBM：LF/IND、RI、IL/DL、SU/SD **全部限制在 `[scrollTop, scrollBottom]` 内**滚动，区域外的行（状态行）不受影响；`CSI r`（全默认）恢复全屏区域、设置有效区域时按规范归位光标；只有**全屏**区域滚出的行才进 scrollback（vim 文本区回滚不污染历史）；RIS / resize / 备用屏进出时区域复位。回归：`core/tests/ansi.test.js` 新增 6 项、`tests/terminal-panel` 新增 9 项（区域只滚区域、状态行不动、部分区域不进 scrollback、RI/IL/DL/SU/SD、`CSI r` 复位），README「已知限制」移除 DECSTBM 并把它写进渲染能力，`docs/research/productization.md` §3.1 与总表同步。

- **「全部处理」按钮在建任务后不点亮（它的可用状态从来没人重算）**：按钮的可用状态是**「有没有待办」**——那是 **board** 的事实，可它只在 `updateLabels()` 里算过一次，而 `updateLabels()` 只在**工作区变化**（adopt / 语言切换）时跑；新建一个任务（正是让「有待办」成立的那件事）走的是 `syncFromBoard()` → `render()`，那里只重画列表，不碰按钮 —— 于是按钮一直灰着，直到用户切走再切回来。动作本身从来没坏（`runAllTapped` 自己会重新算 model，点了也能跑），坏的是按钮不肯说自己能用了。现在把这段收成一处 `updateRunAllButton(githubAvailable:)`，由**两个**入口调用：`updateLabels()`（工作区事实：git / GitHub 可用性）与 `syncFromBoard()`（board 事实：新建 / 入队 / 开始 / 完成 / 删除）—— 按钮亮灭与列表内容从同一个 board 推出，不会再各说各话。回归：`tests/tasks-panel/run.sh` 增加源码守卫，`syncFromBoard()` 里必须重新推导 处理 按钮。
- **默认基线分支不再写死 `main`**：issue 任务的自动队列 `baseBranch` 一律 `main`，流水线第一步就是 `git checkout main` —— 默认分支是 `master` / `develop` 的仓库，**第一个 issue 任务必然失败**（「切换分支失败」）。现在采纳工作区时探测：推送远端（`github` > `origin` > 首个远端）的 `HEAD` → 本地 `main` → 本地 `master` → 当前分支 → 兜底 `main`（决策链在 `TaskBranch.defaultBaseBranch`，无头可测）；自动队列与队列表单的「基于分支」（预填 + 留空回落 + 占位）都用它。
- **任务超时从硬编码 30 分钟改为 60 分钟，并且写在卡片上**：30 分钟曾静默掐掉长任务；现在默认 **60 分钟**（`TasksRunner.defaultTimeout`），运行中的卡片显示「已运行 1:05（上限 60 分钟，到点会取消会话）」，可在壳层设置里用 `tasksTimeoutMinutes`（5–1440 分钟）覆盖。
- **推送策略改掉：「只有会开 PR 的队列才 push」**。此前每个任务收尾都要校验「分支是不是在远端」，而 `git ls-remote` 自己失败（私有 / 内部远端没缓存凭据、网络抖一下）被当成「代理没推送」→ **明明干完的活被判成「分支未推送到远端（代理未 push？）」**。现在判据只有一个：`queueWantsPR = 队列的自动开 PR && 工作区有 GitHub 远端`。为真 → 提示词要求 push、收尾校验分支确实在远端（校验仍是**三态**：`pushed` / `notPushed` / `unknown`，`unknown` 只记日志并继续尝试开 PR，绝不判失败）；为假 → **只做本地 commit、完全不 push**（提示词里明说「不要 push」），也不做任何推送校验，`finish` 只记一行「keeps its work local」。
- **会话状态从 Bool 改成三态，不再把「问不到」当成「跑完了」**。`sessionRunning` 把「RPC 失败」和「会话不在列表里」都表达成 false，而 `step()` 把 false 当「任务结束」—— **一次瞬时 RPC 失败就会把正在跑的任务判成已完成**（随后还可能踩上一条的推送误判）。现在 `SessionState { running, idle, unknown, missing }`：`unknown` 什么都不假设（继续等，日志节流提示）；`missing`（会话被删 / dsh 重启过）要**连续 10 次轮询（≈30 秒）**才判失败，并且用新的 `tasks.errSessionGone`（「会话已经不在 dsh 里了……没人知道它做到哪一步」），而不是假装完成。
- **issue 任务的自动队列把自己的任务装了两次（进度 / 卡片 / 计数全部翻倍）**。`TaskQueue.auto` 已经预置 `taskIds: [task.id]`，`startIssueTask` 紧接着又调 `board.enqueue`，而 enqueue 只防「已经在这个队列里」—— 此时任务的 `queueId` 还是 nil，于是同一个 id 被追加第二次。后果在**每一次**「处理 / 全部处理」里都出现：展开那个队列会看到**同一张卡片出现两次**、队头进度是 `0/2`（永远到不了 1/1）、删除确认框写「队列内 2 个任务会回到未入队」。修法：自动队列改成从空开始（任务只经 `enqueue` 一个入口加入 —— 那里是成员关系的唯一写者），`enqueue` 自己也加一条「同一个 id 只存一次」的防线，`reindexQueueMembership` 在加载时清掉重复项 —— **已经写在 queues.json 里的旧队列下次加载自动修正**，不需要迁移。
- **两处「假成功」与一处「点了毫无反应」**：① 编辑任务时若任务在这期间被 runner 拉起（上一个任务跑完、定时器启动下一个 queued），`updateManualTask` 会拒绝 `.running` 的任务，而面板**丢弃返回值并无条件报「已更新任务「X」」**、还关掉表单 —— 用户敲的字静默丢失；现在失败会报「任务已经开始运行，改动没有保存」，**表单保持打开**（那些字是唯一的副本）。队列设置表单同型（队列没了却报「已更新队列」），一并改成按返回值说话。② 删除手动任务 / 删除队列被拒（有任务在跑）时同样是静默无反应，现在分别报「任务已经开始运行，没有删除」与「队列里有任务在运行：先取消它，再删队列」。
- **「取消任务」在启动中 / 收尾中是死按钮**：任务在 `phase = .starting` 之前就已经是 `.running`（卡片于是给出「取消任务」），而 `cancelRunning()` 只在 `.active` 时工作 —— 点下去返回 false，面板还顺手隐藏状态行，看起来像卡死。现在 `cancelRunning()` 返回 `CancelOutcome`：`.starting` 期间把请求**记住**，会话一建好立刻取消（不再让代理白跑）；`.finishing`（推送 / 开 PR）明确回答「已经在收尾，没有可取消的东西了」；两者都在状态行说出来。
- **「评论并关闭」里清空评论再点确定 = 弹窗消失、什么都没发生**。现在 OK 按钮在评论为空时是禁用的（跟着文本框实时变化），万一走到空评论分支也会在状态行说一句。顺带：**已完成但没有 PR 的 issue 任务不再失去「评论并关闭」** —— 它本来只需要一个 token（`canCommentClose` 从前还要求 `prUrl != nil`，于是正好在 PR 建失败时把整条动作藏掉），评论模板也按有没有 PR 分两种。
- **删除队列后，失败的任务卡片先给「重试」——点了却什么也没重试（只是把任务变回待处理），要再点一次才出现「加入队列」**。根因是卡片主操作只看**任务状态**：`failed` 一律给重试，而 `TaskBoard.retryAndResume` 在任务没有队列时只能把它改回 `pending` —— 于是「重试」实际是「先 reset、再让用户点第二次」。现在主操作由**队列成员关系 + 状态**一起决定：队列还在 → 重试（`retry(clearsBranch:)`，分支进不去的那条老路仍在）；队列没了（被删）→ 手动任务直接给 **加入队列**（下拉，选一个队列即入队开跑），issue 任务给 **处理**（重建它的自动单任务队列）。顺带把「面板按状态猜动作」改成**按卡片模型给出的 `TaskCardModel.PrimaryAction` 执行**：状态区分不了这两种情形，模型可以。回归：视图模型 +20（失败任务在队列里 vs 队列被删的对照、取消任务同理、issue 自动队列被删、各状态的动作枚举）、表单 +3（队列没了的失败卡片带的是那个下拉，且没有只会 reset 的重试按钮）、模型 +5（失败任务的队列可删、失败记录与原因保留、只解除队列归属）。
- **非 git 工作区其实跑不了任务：新建队列的「留空」是派生分支，不是在说「不切分支」**。运行器和 board 一直支持非 git 目录（无分支的队列从不碰 git、无 remote 时跳过推送校验，设计见 §V2-7），但**表单表达不了「不切分支」**：新建队列时分支字段留空的语义是「按队列名派生 `feature/<slug>`」（只有**队列设置**里留空才是「不切分支」）。于是非 git 目录里：新建任务 → 加入队列 → 新建队列（高级设置默认折叠、分支字段是空的）→ 队列拿到 `feature/<slug>` → 入队即启动 → 第一个任务必定以 `tasks.errNotGit` 失败；卡片上只有「重试」，而重试必然同样失败，出路是用户自己发现「队列设置 → 清空分支 → 重试」这条三步绕路。修正三处：① 面板记住工作区是不是 git（此前 `isGitRepo` 算完只写日志）；② `QueueComposerModel` 新增 `skipsBranch` / `gitAvailable`，非 git 工作区的新建表单**默认就是「不切分支」**、分支字段停用、提示写明原因，git 仓库里老行为不变但多了一个**创建时就能勾的「不切分支」开关**（此前只有编辑模式能表达）；③ 因非 git 失败的任务，卡片主按钮变成**「不切分支并重试」**——点一下先清掉该队列的分支再 retry，并把 `tasks.errNotGit` 文案从「无法切分支 / 建会话」（会话其实一直建得出来）改成说清出路。回归：`tests/tasks-panel` 新增运行器「非 git 目录无分支队列照常跑完 / 有分支队列报 errNotGit 且不浪费会话」、视图模型「默认不切分支 / git 里派生不变 / 开关压过已填分支 / 编辑不静默丢分支 / errNotGit 卡片给一键修好」、表单「非 git 开关开着且不可点 + 提交显式空分支」。
- **修复任务卡片主按钮显示原始 key：`tasks.queue.add` 从未加进 `L10n.table`**。手动任务卡片的「加入队列」按钮文案由 `TaskCardModel.primaryKey` **当数据**传给视图，再经 `L10n.tr()` 取词 —— 旧 lint 只扫字面量 `L10n.tr(…)`，看不到模型里携带的 key，于是这个键漏配后一路以 `tasks.queue.add` 的形态显示出来。现在补上中英文（加入队列 / Add to Queue），并给 `tests/l10n/lint.py` 加了同一类检查：`primaryKey` / `stateKey` / `messageKey` / `headingKey` / `submitKey` / `infoKey` / `problemKey` / `problem` / `key` 这些槽位里的字面量必须存在于表里（形状过滤成小写点分，避免误伤 `channel.global.list` 这类 UserDefaults 键，也避开 `forKey:` / `NSLocalizedDescriptionKey`）。**反向验证过**：把新键删掉，lint 立刻以 `keys carried by the view models but missing from L10n.table: tasks.queue.add (TasksUI.swift:primaryKey)` 失败；
  同时把 `docs/design/panels/issue-runner-design.md` §V2-9 里那份**规划期**的键清单换成实际存在的键（`tasks.queue.addPick` / `.progress` / `.idle` / `.pendingCount` / `.unnamed` 等从未落地 —— 正是这份清单让漏配看起来像是已经做过了）。
- **浏览器面板打开某些页面直接崩掉 App（`EXC_BREAKPOINT`，线程 `DispatchQueue: oh-my-dsh.browser-cdp`）**。复现：打开 `https://cas.dev2.supwisdom.com/cas/login`——页面一发 console 日志就崩。根因是 CDP 事件里的**控制台参数渲染直接喂了 `JSONSerialization`**：`Runtime.consoleAPICalled` 的 `args[].value` 对 JS 标量就是 String / NSNumber / NSNull，而 `data(withJSONObject:)` **只接受顶层容器**，传标量抛的是 ObjC 异常 `NSInvalidArgumentException`——Swift 的 `try?` 接不住 ObjC 异常，进程遂 SIGTRAP（`main.swift` 里同样写法的 `try?` 不崩，差别只在顶层是不是容器，所以此前没暴露）。也就是说**任何页面一句 `console.log(0)` / `console.log(null)` 都能崩掉 App**。修复：把参数渲染收口到新的 `BrowserCDPClient.consoleArgumentText(_:)`——先用 `isValidJSONObject([value])` 预检（顺带挡掉 NaN / ±Infinity 这类同样会抛异常的取值），再包成单元素数组序列化、剥掉外层方括号，兜底 `String(describing:)`，任何取值都不可能再走到抛异常的路径；回归测试 `tests/browser-panel/browser-tests.swift` 增 `testConsoleArgumentText`（13 例：字符串/数字/布尔/null/数组/对象/嵌套/空对象/NaN/Infinity）。

- **项目面板「新会话」每次都要 dsh web 重连，而且新会话根本不出现（实际已经建了）**。根因有两层，都在"壳层替 dsh web 建会话"这个做法上：① dsh web 侧栏对会话有一条**可见性规则**——*Ordinary sessions are visible; among blank sessions, only the current one is visible*（`dsh-client-ui-workspace/lib/client.js` 的 `sessionVisible`；`blank` = 从未发过消息的会话）。壳层用 `session/create` 建的正是 blank 会话，而它不是页面的当前会话，于是**侧栏里连这一行都没有**；壳层切页面的唯一手段是点行，于是「新会话」永远切不过去，还每点一次就多留一条谁也打不开的空会话（`app.log` 里 `workspaceRow=yes` + `sessionRows` 不增长、`session/list` 里空会话越积越多）。② 为了掩盖①，旧代码每次先 `nudgeDSHWebCaches()`——派发合成的浏览器 `offline`→`online` 让客户端重连，这就是用户看到的**每次点都重连**。现在「新会话」改走 dsh 自己的入口：注入桥新增 `window.__dshNewSession(工作区名)`（`sessionOpenerScript`），在侧栏找到该工作区行并点它行内自带的 `+`（`dsh-client-ui-workspace` 的 `ProjectRowItem`；行内按钮固定 [工作区菜单, 新建会话]，取最后一枚；hover 才显示但 `click()` 有效，实测可用），于是 dsh 自己执行 `connectWorkspace` 的语义——**复用该工作区已有的 blank 会话，没有才建，然后 open**（会话成为当前会话，blank 行随之以本地化的「新会话 / New Session」出现在侧栏）。结果：不重连、不堆空会话、完全复用 dsh 的语义；壳层经 `dshSession` 追踪器跟随页面切过去的会话。侧栏 DOM 变样时（B10）保留兜底：走 RPC 建会话 + 状态行 `projects.newSessionFallback` 提示去侧栏该工作区行点「+」（那一步会复用这条空会话），**不再 nudge、也不再点行**。配套：`DshWorkspaceOps.newestSessionId` 跳过 `blank == true` 的会话（「在 dsh 中打开」不会再选中一条打不开的空会话，只剩空会话时改为走「新会话」由 dsh 复用）；`onWorkspaceRegistered` 不再 nudge（实测新工作区经 dsh 的工作区流 1–2 秒内自己出现在侧栏）。新增无头套件 `tests/injected-scripts/`（注入 dsh web 的所有 JS 必须可解析、每个 `window.__dshX` 桥名都必须有脚本安装它、不许出现会被 Swift 吃掉的转义——历史上这类错误的表现就是"按钮点了没反应"），`tests/dsh-rpc/` 补 3 例守 blank 跳过；两套均已接入 `scripts/local-ci.sh` 与 CI。
- **项目面板新建工作区后没有任何「选中」反馈（要自己在列表里找那张新卡片）**。以前创建**不**切换当前工作区（当时的顾虑是"用户没点任何入口，右栏内容就跳走"），代价是反直觉：刚在这里建完项目，卡片却不亮、也不一定在视野里。现在**创建即选中**：`createWorkspace` 成功后立刻经新回调 `onSelectWorkspace` → `adoptProjectDirectory` 把它变成当前工作区（卡片高亮 = `ProjectDirectory.current`，面板**不引入**第二个选中态），并记 `pendingScrollPath`，下一次渲染把该卡片 `scrollToVisible` 滚进视野；同名目录按「采用」处理时同样选中，被名字规则拒绝的名称则**既不建目录也不改变当前工作区**。控制器无头测试补 3 例（非法名不选中 / 新建选中 / 采纳选中）。
- **项目面板建完工作区后，dsh web 还停在原来那条会话上（没切到新工作区）**。新工作区的**侧栏行**确实自己出现了（dsh 的工作区流推送，实测 ~0.17s），但**"有行"不等于"是当前工作区"**：dsh web 的"当前工作区"是由**当前会话**决定的，而一个刚建的空目录还没有任何会话，于是没有任何东西可被选中，页面继续显示旧会话——壳层卡片亮了，web 那边没动。dsh 自己的「添加工作区」正是为此在选完文件夹后立刻 `startSession(workspaceId)`（`WorkspacePickFlow.onPick`）。现在壳层照做：注册成功后 `onWorkspaceRegistered(path)` → `dshWebFollowNewWorkspace` → **点该工作区侧栏行自带的 `+`**（复用「新会话」那条桥，dsh 复用空会话或新建并打开），并把该行 `scrollIntoView` 滚进视野。卡片 folder+（采纳一个已存在但未注册的目录）走同一条回调，行为一致。控制器无头测试补 2 例（新建注册后回传路径 / folder+ 注册后回传路径）。
## [1.16.5] - 2026-09-28

### Fixed

- **修复：文件打开点击层漏了工具调用（read / write / edit）里的文件链接**。v1.16.4 的点击捕获层只匹配了对话正文的内联文件链接（`<code>` 内按钮 / `class*=fileMention`）与「Files changed」产出文件行（`[data-produced-files-row] button[title]`）；但 `read` / `write` / `edit` 工具行渲染的是 `ToolRow` 的 `<button class="…fileLink…">`——**没有 `title`，路径只存在于按钮文本里**（工作区相对路径，主目录下缩成 `~`），所以这些链接仍会落入 dsh 自带文件面板。现在点击层把 `fileLink` 作为第三类文件链接处理：取按钮文本作为路径，原生侧按项目目录解析相对路径、`standardizingPath` 展开 `~`（因此 `~/.dsh/...` 也能打开）。回归：`tests/preview-interceptor` 新增 3 例（工具行文本 / `~` 保留 / 空文本放行，共 11 例），`tests/file-panel` 新增 `~` 展开 1 例；`DSH_PREVIEW_DEBUG=1` 探针也新增工具行合成点击自检。

## [1.16.4] - 2026-09-28

### Fixed

- **修复：内置 dsh 推进到 0.1.5-rc.3 后，点会话里的文件链接不再在壳层文件面板打开**。0.1.5 给 dsh 加了自带文件面板，
  `dsh-client-ui-chat` 的 `openFile` 从 0.1.2 的 `remote.session.openWorkspacePath({path: resolveWorkspacePath(cwd, path)})`
  改成页面内的 `ctx.sidebarRight.openResource(fileAddressFor(sessionId, cwd, path))`——**不再发任何 HTTP 请求**，
  壳层只 hook `window.fetch` 的 `previewInterceptorScript` 因此彻底失效（点链接改开 dsh 自带面板，原生面板收不到路径）。
  修复：给拦截脚本加**点击捕获层**，在 document 捕获阶段识别内联文件链接（`<code>` 内的按钮 / `button[class*=fileMention]`）
  与「Files changed」产出文件行（`[data-produced-files-row] button[title]`），把 `title`（原样路径）发给原生面板并吞掉事件；
  原 `fetch` 层保留以兼容 ≤0.1.4 与未来的 host RPC 面。相对路径由原生侧按当前项目目录解析
  （`FilePanelController.resolveIncomingPath`，等价于 0.1.2 客户端发送前做的 `resolveWorkspacePath(cwd, path)`），
  因此**工作区相对路径的文件链接也能打开**（此前只会被 fetch 层按绝对路径过滤掉）。回归用例：`tests/preview-interceptor/`
  （直接抽取注入脚本用 DOM stub 运行，覆盖点击 + 两种 fetch 形状）与 `tests/file-panel` 的路径解析用例；`DSH_PREVIEW_DEBUG=1`
  探针也新增合成点击自检。根因与审计漏洞复盘见 `docs/process/dsh-version-impact.md` B7/R3 与
  `docs/plans/dsh-015rc2-compat-audit.md` §7.1c。

## [1.16.3] - 2026-09-27

### Changed

- **内置 dsh 版本推进到 `@deepseek-ai/dsh@0.1.5-rc.3`**（0.1.2-rc.1 → 0.1.5-rc.3；`build-app.sh` 的
  `DSH_PACKAGE_SPEC` 默认值（两处）与打印行同步，构建期仍可用 `DSH_PACKAGE_SPEC` 覆盖），并随附该 spec 的
  运行时闭包锁 `platforms/macos/runtime-locks/dsh-0.1.5-rc.3/`（584 个条目，构建据此走 `npm ci` 复现闭包，装完做启动冒烟）。
  这次推进就是 2026-09-23 那份兼容审计（`docs/plans/dsh-015rc2-compat-audit.md`）中「已审计、暂缓执行」的动作：
  当时的暂缓理由是**会话日志换代且上游没有降级通道**，而**会话快照 + 回退已在 v1.16.2 上线**，不可逆迁移的安全网就位。
  - **为什么是 rc.3 而不是审计当时的 rc.2**：两者是**同一份代码**（见下「无冲突」证据），但 rc.2 有两个实操上的坏处——
    ① 它只钉住顶层包：dsh 用 caret 声明同族子包，所以 `npm install @deepseek-ai/dsh@0.1.5-rc.2` 解出的闭包里
    **230 个子包其实是 `0.1.5-rc.3`**，产物是「rc.2 顶层 + rc.3 子包」的混合体；② 壳层的版本事实读顶层
    `package.json`，于是**站内升级助手会一直提示「有 0.1.5-rc.3 可升级」**（实测 `nextStepTarget('0.1.5-rc.2') = '0.1.5-rc.3'`），
    而那个升级几乎是空操作。改用 rc.3 后闭包**完全自洽**（231 个 `@deepseek-ai/dsh-*` 全部 rc.3），提示也随之消失。
  - **为什么可以放心用 rc.3（它不是"野生"版本）**：上游仓库里 `dsh-v0.1.5-rc.3` **有 tag**，npm 上 `latest` 就是它，
    0.1.7-rc.1 的发行说明也把 `v0.1.5-rc.3` 当作比较基线（`Full Changelog: dsh-v0.1.5-rc.3...dsh-v0.1.7-rc.1`）——
    只是它**漏发了 GitHub Release 页面**（Releases 列表从 `0.1.6-alpha.1` 直接跳到 `0.1.5-rc.2`）。
  - **无冲突的证据（rc.2 与 rc.3 逐项对比）**：① RPC 端点集合**零增、零删**，参数包裹字段（`_request` /
    `request` / `parentSessionId`）**零变化**（用 0.1.2-rc.1 / 0.1.5-rc.2 / 0.1.5-rc.3 三棵树做全量端点提取比对）；
    ② 六个耦合面所在的包**逐字节相同**（`dsh-client-connection`、`dsh-web-app`、`dsh-workspace`、
    `dsh-session-format`、`dsh-skill-filesystem`、`dsh-client-ui-sidebar`、`dsh-session-persistence-jsonl`）；
    ③ 反而更安全：rc.3 把 cordis 工具链**钉成精确版本**（`@deepseek-ai/cordis 4.0.2`、`cordis-plugin-hmr 1.0.17`…），
    而 rc.2 用的是 caret 范围——正是 R8「运行时闭包漂移」的成因。
  - **兼容性结论（复核后仍成立）**：RPC 端点**只增不减**、参数包裹字段与 `dsh-auth-*` cookie、就绪自报行
    `dsh web: <带 token 的 URL>`、`workspace.json` 的 domain `workspace` v2、技能四根与 rank、frontmatter 规范键
    **均未变**；**唯一断裂面**是会话日志的**世代命名**（0.1.5 起新建会话写 `session.v3.jsonl.zstd`），其修复已在
    v1.16.2 落地（`core/lib/review-log.js` 的 `parseSessionLogName` / `sessionLogCandidates`，按规范名枚举 +
    世代最大者优先）。**（更正：这句「不需要新的壳层代码改动」不成立）**升级到 0.1.5-rc.3 实际需要一处壳层适配——
    文件链接改走 dsh 自带面板、不再发 RPC，见 [Unreleased] 的修复；原结论错在只比对了端点集合与六个耦合包，
    未覆盖 `dsh-client-ui-chat` 点击链接的客户端行为。
  - 验证：新运行时**启动冒烟通过**、core 单测与面板/swift 套件全绿，端到端实测新会话的活日志为
    `session.v3.jsonl.zstd` 且壳层读取器能发现并审计它；执行与证据见 `docs/plans/dsh-015rc2-compat-audit.md` §七。

## [1.16.2] - 2026-09-23

### Added

- **会话快照与回退（Session Snapshots，设置菜单 →「会话快照…」）**：dsh 升级会把会话日志换成新世代（0.1.5 起新建会话写 `session.v3.jsonl.zstd`，被迁移的老会话把原文件留成冻结归档），而**上游只有升级链、没有降级通道**——这是一次不可逆的数据迁移。壳层现在在**任何 App / 内置 dsh 版本组合变化之前**自动留一份可回退的快照：
  - **数据快照**：`$DSH_HOME/sessions/ + storages/`，APFS clonefile（实测 306 MB / 246 会话 = **0.124 s**、几乎不占额外空间），最多保留 3 份；裁剪时保护「当前数据所属组合 / 最近一次回退目标 / `forCombo` 等于当前组合」三份；
  - **树池**：`runtime/dsh` 整树**按 dsh 版本去重**存一份（实测 256 MB / 24,872 文件 = 5–6 s、约 14 MB），每次启动自查补齐——**这一步是必需的**：装新 pkg 会把旧 bundle 连同旧 `runtime/dsh` 一起替换掉，事后再抓来不及；
  - **触发时机**：① 功能首次启用（`bootstrap` 基线）② App/dsh 组合变化 ③ **App 内升级 dsh 之前（强制，`performApply` 里接线）** ④ 用户点回退时的现场快照（`pre-rollback`，使回退可撤销）。顺序铁律是**先快照、再起 dsh**——dsh 一打开会话就会补写 `session/end-seed`，晚一步就抓不到干净状态；组合未变时启动只读一次状态文件（实测 **0.059 s**）；
  - **回退并退出**：预览「将恢复 N 条（并移除其新世代日志）/ 将隔离 M 条 / 内置 dsh 换回 X」→ 二次确认 → 停自拉起的 dsh web → 现场整体停放到 pre-rollback 快照 → 恢复目标数据 → 快照之后新建的会话**移入隔离区而不是删除**（带清单） → 换回旧 dsh 树（池内 rename，**离线瞬时**；缺则提示联网补装或改重装旧 App） → 写回 `dataCombo` 并**钉住自动升级** → 退出 App（活着的 dsh 会立刻把会话再迁移回去，所以必须退出）。事务带 `rollback-journal.json`：中途崩溃或「数据与树版本不一致」会在下次启动给出提示，可**续做/撤销**；
  - **边界**：这是数据回退，不是 App 回退（pkg 装不了旧版本）——「问题出在 App 本身」时走「只回退数据 + 提示安装旧版 App」，快照 meta 记着当时的 App 版本供提示使用；凭据（`credentials*`）、壳层自身状态与 token（`shell/`，含 `dsh-web.json` 里那把 launch token）、通道绑定（`channels/`）、CEF profile（`browser*/`）**一律不进快照、不回退**；
  - 实现：`core/lib/snapshot.js`（纯决策：触发判定 / 回退计划 / 裁剪保护 / 事务状态机）、`core/lib/snapshot-io.js`（落盘：clonefile、树池、隔离、裁剪）、`ohmy-core snapshot …` CLI、`platforms/macos/src/SnapshotModel.swift` + `SnapshotWindow.swift` 与启动前钩子；测试 `core/tests/snapshot*.test.js`（21 例）、`tests/snapshot-rollback/run.sh`（端到端，含升级路径与崩溃拒绝）、`tests/snapshot-panel/run.sh`（窗口模型），均已接入 CI。设计与九类场景演绎：`docs/design/shell/session-snapshot-rollback-design.md`。
- **升级核对专用 QA 钩子（仅开发/QA）**：`DSH_PANEL_TEST="files,terminal,wiki,tasks,browser,channel,review,skills"` 在启动后按序切到每个面板（配 `DSH_UI_DEBUG=1` 每个面板各落一张 `panel-<name>-debug.png`）——此前只有六个单面板钩子，且缺的恰是**没有菜单快捷键、脚本点不到**的 tasks 与 channel；`DSH_PREVIEW_DEBUG=1` 的文件打开探针同时演练**新旧两种请求形状**（`host.openPath` 与 `session/openWorkspacePath` + `payload.args.request.path`），拦截器只认老形状时会当场失败，而不是在 UI 里静默。

### Fixed

- **修复：快照的树池会收下「从没启动成功过」的树，回退时把坏树换回来**（用户实测踩到：升级到 0.1.5 正常 → 回退到升级前快照后启动即报同一个 HMR 错）。原因：启动钩子在 **spawn dsh web 之前**就抓树，于是"构建坏了但 App 起来了"的状态下，池里存下的是漂移闭包（`cordis-plugin-hmr 1.0.19`）；回退把这份坏树换回 bundle → 再次启动失败。三处修复：① **抓树改到页面加载完成之后**（`captureRuntimeTree()` 挂在 `didFinish`，一次/启动）——只有**已经证明能启动**的树才进池；`snapshot launch` 增加 `--no-tree`（启动前的数据快照不变）；② **闭包校验**：新增 `snapshot tree` 子命令与 `captureTree` 的 `--expected-lock` 守卫——与提交的 lock 指纹不一致的树**拒绝入池**，池里已有的不一致副本会被替换；回退换树前同样校验，不一致则**拒绝换入**并回报 `needsTreeInstall`（让壳层用 lock 重新 `npm ci`）；③ **补装走 lock**：`DSHUpdater.installVersion` 在 App 带着该版本的提交 lock 时改用 `npm ci`，`runtime-locks/` 随 App 一起分发。
- **修复：新构建的 App 因运行时依赖漂移而无法启动（`dsh: user patch-layer watching requires the Cordis HMR service`）**。只钉 `DSH_PACKAGE_SPEC` **不够**——dsh 用 caret 范围声明它的 cordis 工具链（`^1.0.17` 等），所以 `npm install @deepseek-ai/dsh@0.1.2-rc.1` 会装上**当天最新的 1.x**：实测重建得到 `cordis-plugin-hmr 1.0.19`（已安装的生产包是 1.0.17），而新版 HMR 插件在 0.1.2-rc.1 的 loader 下无法实例化 → profile 的 `patchReload: "live"` 走到 `watchUserPatches` 直接抛错、`dsh web` 打印入口 URL 后立刻退出（App 表现为启动失败/白屏）。单独把 `hmr` 钉回 1.0.17 仍报错——漂移是整组的。现在：① 仓库为每个受支持的 spec 提交一份**已知可启动**的闭包锁 `platforms/macos/runtime-locks/<spec>/{package.json,package-lock.json}`（0.1.2-rc.1 那份从真能启动的生产运行树导出，583 个包），构建改用 **`npm ci`** 复现闭包；② 没有 lock 的 spec 走老路并打印警告；③ 装完做**启动冒烟**（`smoke_runtime`：起一次 `dsh web`，40 秒内必须打出入口 URL 且进程存活，否则**构建失败**并打印日志；跨架构 stage 自动跳过；可用 `DSH_SKIP_RUNTIME_SMOKE=1` 临时跳过）；④ runtime 缓存键加入 lock 指纹，改锁即重建。排查与结论记入 `docs/process/dsh-version-impact.md` E7 / R8 详解。
- **审查面板预先适配 dsh 的「会话日志世代命名」（为后续 dsh 升级铺路；当前内置 dsh 仍是 0.1.2-rc.1，日常行为不变）**：dsh 按 **Session 格式世代**给会话日志命名——世代 0 是 `session.jsonl`，之后每代带 `.vN`（`session.v3.jsonl`），压缩存储再加 `.zstd`。**dsh 0.1.5 起新建会话直接写 `session.v3.jsonl.zstd`**；被迁移过的老会话则把原来的 `session.jsonl.zstd` 留作冻结归档、活日志换成新世代名（实测同一会话：归档 19 条事件、活日志 22 条，之后的新事件只进活日志）。壳层读取器原先只认世代 0 的两个文件名，一旦内置 dsh 升级就会**新会话一条都列不出来、老会话永远停在迁移前的旧内容**——面板不报错，只是空或旧（`app.log` 里表现为 `review: listed 0/N sessions` + `review: audit FAILED`）。现在 `core/lib/review-log.js` 按**规范文件名**枚举（`^session(\.v[1-9][0-9]*)?\.jsonl(\.zstd)?$`，`.v0`/大写/前导零/临时后缀等非规范名一律拒绝），**取世代号最大的那一份**（迁移会话因此读活日志而不是归档），同代压缩优先；新增 `sessionLogCandidates()` 暴露完整候选顺序。`core/tests/review-log.test.js` 增 6 条用例（新世代会话可被发现并审计、迁移会话读活日志、非规范名忽略、世代 0 向后兼容、压缩与非压缩两种新世代文件）。
  - 内置 dsh 的版本推进（0.1.2-rc.1 → 0.1.5-rc.2）**兼容审计已完成、暂缓执行**：五个耦合面的逐项实测记录见 `docs/plans/dsh-015rc2-compat-audit.md`（端点只增不减、参数包裹字段与鉴权 cookie 未变，唯一断裂点就是上面这条），通用清单 `docs/process/dsh-version-impact.md` 已补 D6/D8/D9、R7 详解与两条 SOP 核对项。**待「会话快照 + 回退」功能上线后再推进**——那次升级会让会话日志换代且无法回退到旧版 dsh，必须先有安全网。

## [1.16.0] - 2026-09-21

### Added

- **技能面板（Skills / `⌥⌘S`，活动栏「技能」）：在壳层里查找 / 安装 / 移除 agent 技能，并管理调用开关**。面板分「已安装」与「可安装」两个页签：**已安装**扫描 dsh 的四个技能根（`<工作区>/.dsh/skills`、`<工作区>/.agents/skills`、`$DSH_HOME/skills`、`~/.agents/skills`），按 dsh 的 rank 去重并逐行标出**级别** —— `内置` / `用户级` / `共享级` / `项目级`（同名被压住的标「被遮蔽」）；**可安装**按当前 registry 渲染清单或按关键字搜索，支持清单勾选安装、从地址安装与手动导入本地目录。**内置技能只读**（开关禁用、无移除入口、不可被安装覆盖——App 启动时按内嵌内容同步，字节一致性不变，故 `SkillInstaller.swift` 零改动）；**共享级**（外部 skills CLI 管理的 `~/.agents/skills`）可看可改开关、但不在面板里移除；**用户级 / 项目级**可改开关、可移除。
  - **调用开关写回 SKILL.md frontmatter**：`用户可调用` → `user-invocable`、`模型可调用` → `disable-model-invocation`（关闭即写 `true`）；**切回默认值会删掉该键**，从而字节还原原文件；只增删改这两行，键序/注释/引号/CRLF/正文全部原样保留（不是 YAML 往返）。**只写规范键**——dsh 对旧的驼峰键（`userInvocable` 等）会直接忽略整个技能。改完 dsh 自动发现，无需重启；重启后开关仍在（记录在壳层 `$DSH_HOME/shell/skills.json`，面板重装同一技能时按记录重放）。
  - **安装目标**：默认 **用户级** `$DSH_HOME/skills/<name>/`（所有工作区通用），可选 **项目级** `<工作区>/.dsh/skills/<name>/`（rank 100、优先级最高，写用户仓库前会提示 git diff）；同名已存在先确认，目标是内置同名技能则拒绝；技能目录**整目录复制**（SKILL.md + 附件），拒绝路径穿越、仅接受 https、失败不留半成品。
  - **registry 是可配置项**（`shell/skills.json` 的 `registries`，默认预置 skills.sh）：`owner/repo` 或 GitHub 地址 → **列出该仓库的技能清单**（浅克隆后本地扫描，避开 GitHub API 限流）；well-known 地址 → 读 `/.well-known/skills/index.json` 清单；其他 URL → 视为 skills.sh 兼容的搜索接口（模板 `{q}`/`{limit}`）。**skills.sh 只提供关键字搜索、没有全量清单接口**（实测 `/api/leaderboard`、`/api/skills` 均 404，站点榜单是 HTML）——因此该 registry 未配清单来源时，列表区明确提示「按关键字搜索」，不做 HTML 抓取。
  - 新增 `platforms/macos/src/SkillsPanel.swift`（右栏面板）、`SkillsCore.swift`（纯 Foundation 模型：frontmatter 读写、四根扫描与级别判定、壳层技能记录 `shell/skills.json`）、`SkillSources.swift`（地址解析、registry 清单与搜索、拉取/安装/移除，传输可注入）与 `tests/skills-panel/`（无头模型单测，已接入 `scripts/local-ci.sh` 与 CI swift job）；`tests/skills/` 的内置技能字节断言保持不变。
  - 设计、四档级别判定与 registry 模型：`docs/design/panels/skills-manager-design.md`；dsh 升级核对项见 `docs/process/dsh-version-impact.md` D2/D2b/D2c/D2d。
- **技能面板的「可安装」列表：整张卡片可点看详情 + 悬停才出现安装按钮**：点击卡片用**系统默认浏览器**打开该技能的页面（只接受 http(s)，不用内置浏览器面板）——skills.sh 型 registry 打开 `https://www.skills.sh/<source>/<skill>`，GitHub 清单打开仓库内技能目录，well-known 打开该技能的 `SKILL.md`，裸 git 打开远端，本地路径改为在 Finder 中显示；**「安装」按钮改为鼠标移入卡片时才出现**，移出即隐藏，平时列表保持干净；「可安装」页签进入即默认显示**热门列表（按安装量降序，前 30）**，输入关键字切换为搜索结果。
- **文件面板：目录树右键菜单与头部菜单按钮（#1 #2 UI 返工）**：目录树右键菜单按对象给项 —— 目录上「新建文件夹 → 新建文件 ｜ 重命名 → 删除 → 在 Finder 中显示」，**文件上不提供新建项**，「在 Finder 中显示」单独分组；新建在当前目录下创建并进入命名，重命名 / 删除（移到**废纸篓**，可恢复）后页签跟随改名或关闭。面板头部改为「**打开项目 ▾ / 当前文件 ▾**」两个菜单按钮（点击总是打开菜单，不再出现「点了没反应」），「打开文件」按钮**仅在选中文件时可用**；项目目录可用外部应用打开。
- **文件面板：图片预览自适应窗口 + 手动缩放（#8）**：打开图片时按比例**适应窗口**（等比、以较紧的一边为准、不放大超过 100%），支持触控板**捏合**、`⌘+` / `⌘−` / `⌘0`、`⌘`+滚轮、**双击**（适应窗口 ↔ 100%）与放大后拖拽平移，缩放范围 5%–1600%、单步 ×1.25，右下角浮动百分比角标；新增 `ImagePreviewView.swift` 与纯模型 `ImageZoom.swift`（缩放数学可无头测试）。
- **终端面板：滚动方向 / 选中即复制 / 页签按 workspace 隔离（#3 #4 #5）**：滚动方向对齐其余面板的语义；**双击选词**、**选中文本即复制**（新增设置项「终端：选中文本即复制」可关）；终端页签**按 workspace 隔离并记忆**，在 dsh web 切换工作区时同步联动、切到没有终端的工作区自动开启；并恢复触控板滚动惯性。
- **壳层：页面刷新自愈 + 「视图 → 重新加载页面」`⌘R`（#6）**：长时运行后 WebView 手里那份 cookie 可能不再被接受（页面只显示纯文本 `dsh web authentication required…`，而面板照常可用），此前的右键「重新载入」走的是 WebKit 默认菜单、等价于裸 `reload()`，救不回来。现在：① 视图菜单新增**「重新加载页面 `⌘R`」**，刷新改走 `server.entryURL`（带启动 token 的入口地址，303 重新落一份 cookie）而不是裸 reload；② **主框架 401 / 加载失败自动自愈一次**——自己拉起的 dsh web 若已死则重拉；③ `ServerManager.stop()` 清空 `entryURL`/`process` 并新增 `isRunning`，补刷新与 cookie 诊断日志（此前的刷新不留任何日志，复现过也查不到）。成因收敛过程见 `docs/feedback/ux-feedback.md` #6。

### Changed

- **面板配色统一为单一灰阶令牌**：面板顶部/内容区底色统一为 `#1B1B1C`（浅色 `#F9FAFB`），卡片 / 按钮 / 页签底色统一为控件两档 `#43454A` / `#353638`（浅色 `#FFFFFF` / `#F1F3F5`）——六色全部取自 dsh web 的 `neutral bluish` 设计令牌，壳层与 web 界面天然同调，取代「每个面板各写一档灰」的历史局面。**单一事实来源 `platforms/macos/src/PanelSurface.swift`，改色只改这一个文件**；方案见 `docs/design/shell/ui-color-scheme.md`（含两套取色 API、CALayer 不吃动态色的注意事项、语义色与系统绘制控件的边界）。
- **文件面板：大文件保留语法高亮（分块着色）**：不再按行数 / 大小关闭高亮，改为**分块着色**，3000+ 行的文件打开后依然有高亮且不卡 UI。
- README 面板数量文案与目录树同步为八个面板。

### Fixed

- **面板顶部条/标签被同色不透明兄弟视图覆盖（技能面板的标题与按钮不可见）**：`DynamicFillView` 是不透明视图，原实现按 `dirtyRect` 填充，而 AppKit 可能给不透明视图传入**大于其自身 bounds** 的脏矩形——于是内容容器（先添加、层级更低的兄弟）会把它上方的头部条、标签条整条刷成自己的底色，看起来就是"顶部空白/被遮住"。改为 `bounds.intersection(dirtyRect).fill()` 只填自己拥有的区域；技能面板同时把内容容器放到最底层、头部最后添加（双重保险）。新增无头绘制回归测试（`tests/skills-panel/render-tests.swift`：真实 `DynamicFillView`/`HeaderLabel` 离屏渲染后断言头部条有内容、且不透明兄弟不会越界覆盖），已验证**去掉该修复后测试会失败**。
- **Tasks 面板内容区未吃到面板底色**：`NSTableView` 自身背景盖住了面板底色，改为跟随配色令牌。

- **技能面板的改动现在会被 dsh web 立即看到（对话输入框 `/` 的技能菜单不再需要手动刷新）**：dsh 客户端按会话缓存技能目录，且只在 `connection/reset`（连接重连）或切换 agent preset 时失效；技能文件变化不是会话事件、服务端不会推送，所以此前改完 `user-invocable` / 安装 / 移除都必须手动刷新页面。现在面板在**改开关 / 安装 / 移除**后通知壳层，由壳层向 web 页注入 JS 派发**浏览器 offline → online 事件**，触发客户端自身重连并发出 `connection/reset`，各客户端插件缓存（含技能目录）随之清空并重取——与手动刷新等效但不重载文档。1.5s 节流；`DSH_SKILLS_NO_NUDGE=1` 可关闭。

- **可用列表滚动后"划过的技能全部保持高亮"**：AppKit 的 tracking area 只在指针移动时触发 enter/exit，内容从静止指针下滚过时不会触发 `mouseExited`，于是划过的卡片一直亮着、也不还原。现在面板监听 clip view 的滚动通知，每次滚动按**当前指针位置**重算唯一 hover 的卡片（`SkillHoverResolver`，纯函数 + 4 条单测：命中/落在卡片间隙/已被滚出可视区/指针在列表外）。

- **修复「新建的会话在审查面板里只有一行会话、看不到里面改的文件」**：面板的审计结果**按 sessionId 缓存后永不失效**——而新建会话一诞生（成为 dsh web 当前会话）就会被审一次，那会儿日志里只有会话头，于是「0 文件 / 本会话没有记录到文件变更」被**永久钉住**：后面改了多少文件都不会再读一次（点刷新也只重列会话，不动审计缓存）。会话日志是**活文档**（dsh 每落盘一批追加一个独立可解压的 Zstandard 帧，只增不减），因此缓存必须按**日志身份**而不是 id 认账：
  - `ReviewLogModel.ReviewLogStamp`（size + mtime，纯 Foundation）+ `ReviewLogModel.auditNeedsRefresh(cached:onDisk:)`：只有日志与审计时所读的**仍是同一份**才复用缓存；日志路径未知（尚未出现在列表里）时判为「无法判断」，保留缓存而不是反复重读；
  - 审计前先打戳、读完落盘该戳：审计**进行中**追加的帧仍然比戳新，因此下个 tick 会再读一次，不会漏掉最后一批；失败（含解码失败）同样记录戳，坏会话不会每 5 s 重试一次；
  - **打开面板即重列**（`ensureLoaded()` 不再只列一次）：打开面板本就是在问「自上次看看它改了什么」；重列期间**不擦内容**（先把现有树画出来，数据到了再替换）——沿用「刷新不清屏」的既有约定；
  - **可见时轮询**：面板在屏上时每 5 s 给已展开会话的日志做一次 `stat`，只有**真的变了**才跑一次 `review audit`（未变化时零 CLI 调用）；面板收起/切走即停（隐藏只把分隔线宽度收成 0、视图仍挂在树上，所以可见性判定不能只看 `superview`）；
  - 回归测试 `tests/review-panel/controller-tests.swift`（无头驱动真控制器 + 假 core CLI）：新建会话第一次读 → 如实显示「0 文件 / 无变更」→ 日志增长后**不需要任何操作**自动重读并列出文件，且日志不再变化时**不会**重复审计；对修复前的代码实测 6 例 FAIL（`tests/review-panel/run.sh` 已接入 `scripts/local-ci.sh`）。

- **文件面板：关闭再打开后目录树宽度变成上限 420（#9，第三版才修好）**：关闭面板时壳层把右侧窗格宽度收成 0，`contentSplit` 随之被压扁，再次打开时 NSSplitView 从 0 重新分配、把目录树推到允许的最大值 420。前两版用「0 → N 宽度转变」+ 事件监视器恢复**从未执行过**（拿真实 `app.log` 对照确认：既没有恢复记录，也从未记住过宽度）——根因是 `NSSplitView` 拖分隔条时跑的是**它自己的 event-tracking loop**，这类事件不经过 `NSEvent.addLocalMonitorForEvents`。第三版改为：新增 `TreeDividerSplitView: NSSplitView` 子类 override `mouseDown(with:)`（`super` 返回即「拖拽结束」），据此**准确**区分「用户拖拽」与「程序重排」——拖拽结束记录宽度、非拖拽的宽度变化一律纠正回记住的宽度，另有「关闭面板」「面板切走」两个兜底记录点，所以从未拖过也能正确回到默认 160。`tests/file-panel/` 用**真实 NSWindow + 真实 split view** 跑完整序列（拖到 300 → 收成 0 → 恢复 900 → 断言仍是 300），并断言「框架自己重排到 420 必须被纠正且不会被记成用户选择」。
- **文件面板：打开图片即崩溃**：百分比角标原会按文本测量并 `invalidateIntrinsicContentSize()`，而缩放是在 `layout()` 里应用的，于是 magnify 的 KVO 回调可能在**一次布局过程中**触发角标改尺寸、崩在 `-[NSView _invalidateIntrinsicContentSizeDirtyingConstraints:]`。三处一起改：角标改为**固定尺寸**（54×18，文本变化只 `needsDisplay`）、KVO 回调**推迟到下一个 runloop**、`applyFit()` 数值未变时不再重复设置 magnification。
- **文件面板：图片预览不居中 + 拖动面板宽度时缩放反复跳变**：新增 `CenteringClipView`（`constrainBoundsRect` 里把小于视口的文档居中，NSScrollView 默认把文档钉在左下角 → 图片贴在左下角）+ `ImageZoom.padding`(16pt) 内边距，fit 按「视口 − 2×边距」计算；缩放跳动则是因为 fit 误用 `contentView.bounds`（开启动量缩放后它是**文档坐标**）作视口，形成「设 magnification → 视口值变 → 重新 fit」的振荡，改用 clip view 的 **frame**（屏幕点）后二者互不影响，并在视口退化（live resize 中间帧）时跳过、设置 magnification 时用 `CATransaction` 关闭隐式动画。
- **文件面板：大文件（3000+ 行）磁盘变更后重新加载把应用卡住（#7）**：改为**异步读取 + 单次高亮 + 稳定性窗口**，代理改写大文件后不再卡 UI。
- **终端面板（#3 #4 #5 后续）**：恢复滚动惯性、双击后**按词扩选**、在 dsh web 切换 workspace 且目标工作区没有终端时自动开启一个。

### Docs

- 新增 `docs/design/shell/ui-color-scheme.md`（面板配色方案：六色令牌表、两套取色 API、CALayer 与动态色的坑、语义色边界）。
- `docs/feedback/ux-feedback.md`：记录 9 条使用问题（Files 新建/外部打开、目录树宽度、大文件重载、图片缩放；Terminal 滚动/选词/页签；WebView 刷新 401），逐条补实现位置与验证结论；#6 收敛到「面板正常 → 仅 WebView 那份 cookie 被拒」并给出 ⌘R 与右键 Reload 一致化方案。
- `.dsh/wiki/` 同步：技能面板（Skills Manager）、审查面板日志新鲜度、面板配色统一、UX 反馈修复。

### Tests

- 新增 `tests/file-panel/`（模型 28 例 + 真面板 38 例，含真窗口复现「关闭/重开面板丢目录树宽度」、`image-zoom-tests.swift` 17 条缩放断言）、`tests/skills-panel/`（模型单测 + 控制器冒烟 + 离屏绘制回归）、`tests/terminal-panel/`、`tests/wiki-panel/panel-header-tests.swift`，全部接入 `scripts/local-ci.sh` 与 CI swift job。

## [1.15.0] - 2026-09-13

### Added

- **审查面板（Review / `⌥⌘R`，活动栏「审查」）：只读回答「这个会话里代理到底改了哪些文件、改成什么」**：直接读 dsh 自己落盘的会话日志（`$DSH_HOME/sessions/<workspace>/<session>/session.jsonl[.zstd]`），**不写任何文件、不发任何请求、不改 dsh**。面板按 **会话 → 对话（turn）→ 文件 → 变更内容** 的树展示，每层可展开/收起，对话用该轮的用户消息做摘要；会话只在**第一次展开**时才真正审计（列表只读日志头，展开才解码全量日志并缓存）。每个文件的**逐次改动都标出来源**：`已应用`（顶层 `write`/`edit` 工具结果里的 hunk，与 dsh web 的 diff 卡片同源）、`参数还原`（由调用参数还原——`run_code` 嵌套调用没有 hunk 元数据）、`全文写入`/`新建`（日志只记了写入内容），嵌套调用另标 `嵌套调用`；`bash` 直改（`sed -i`、`>`、`rm`、`git checkout` …）没有结构化的前后内容记录，单列为「shell 命令」并按「可能写文件」启发式打标（默认只显示可疑项，可关掉过滤看全部）；失败/被拒的调用单列「失败的调用（未改动）」，不计入变更统计；读取诊断（Zstandard 尾部未完成帧、无法解析的行）一律显式列出，**不静默丢数据**。**跟随 dsh web**：在 web 里切换会话时面板展开同一 sessionId（按 id 解析，跨工作区也能定位）并标为「当前会话」；工作区切换只重列会话、不清审计缓存。**只读边界**：日志里没有的东西不会显示——`bash` 直改与尚未落盘的部分只标注「需人工核对」。
  - 审计折叠逻辑放在 **core**（`core/lib/review-log.js`）：dsh 的 JSONL 后端把日志写成**多个独立可解压的 Zstandard 帧的拼接**（每次落盘一批一帧），一次性解压只能拿到第一帧；Apple 的 Compression 框架在这套 SDK 上**没有 zstd 算法**，Swift 侧无法自行解码。因此 core 自带 `scanZstdFrames()` 逐帧解码，壳层经 `CoreBridge.run(…, preferBundledNode: true)` 调用（**必须用内置 Node**，用户自装的 Node 18/20 没有 zstd），且**不依赖 dsh 的私有模块**——不新增升级耦合面；
  - 新增 `platforms/macos/src/ReviewPanel.swift`（右栏面板）、`ReviewLogModel.swift`（展示模型：JSON 解码 + 文件分组 / diff 折叠，纯 Foundation，可无头测试）、`core/bin/ohmy-core.js review sessions|audit|audit-file`（CLI 契约）与 `tests/review-panel/`（模型层单测），已接入 `scripts/local-ci.sh` 与 CI swift job；
  - 覆盖矩阵（哪些改动能被看到、哪些只能「需人工核对」、为什么不做回滚）见 `docs/design/panels/review-panel-design.md`。
- **文件面板（Files）页签按工作区记忆与恢复**：切换工作区（在 dsh web 切到另一工作区的会话）时，先把原工作区的已打开页签（顺序 + 当前选中项）记入内存并**关闭全部页签**——释放编辑器 / 语法高亮 / 预览内容，不再把旧工作区的文件挂在新工作区上；切回原工作区时按原顺序重开并还原选中项，磁盘上已消失的文件自动跳过。**未保存修改先询问**：保存并切换 / 不保存——**面板始终跟随工作区**（dsh web 已经切过去了，不存在「留在原工作区」这个答案，否则两边显示不一致）；保存失败的页签**保留在页签栏**（既不静默丢弃改动、也不掉队），面板不可见（无人可问）时同样保留并照常跟随。点面板右上角「关闭」按钮 = 关闭全部页签**并清空全部工作区的记忆**（彻底回收）；切到其它面板不算关闭。**关闭时若还有未保存修改会先问**（页签 ✕ / ⌘W 与面板 ✕ 同一套提示：保存并关闭 / 不保存 / 取消，取消 = 不关；保存失败则中止关闭并保留缓冲）。记忆仅存在于本次进程，不落盘。新增 `platforms/macos/src/WorkspaceTabMemory.swift`（纯逻辑）与 `tests/file-panel/run.sh`（模型 28 例 + 真面板 38 例），已接入 `scripts/local-ci.sh` 与 CI swift job。

### Changed

- **面板头部改为固定标题（文件 / 终端 / 知识库）**：文件面板头部固定「文件 / Files」（不再跟随当前文件显示路径）、终端面板头部固定「终端 / Terminal」（不再跟随会话标题 / 已结束状态）、知识库面板头部固定「知识库 / Wiki」（不再跟随当前页面名）；三者都复用活动栏同名键（`bar.preview` / `bar.terminal` / `bar.wiki`），语言切换时随 `refreshTooltips()` 刷新。信息没有丢——文件面板的路径、终端面板的会话标题/已结束状态、知识库面板的页面名都改放进**头部标题的悬停 tooltip**（终端「会话已结束」仍在内容区叠加提示里；页面名在树与页头上本来就有），页签 tooltip 也一直带着。新增 `tests/terminal-panel/`（无头，不建 PTY）与 `tests/wiki-panel/panel-header-tests.swift`（无头，不扫目录）：标题固定 / 语言切换后仍固定 / 关会话后不被清空。

### Fixed

- **审查面板首轮体验问题成批修掉（空面板 / 宽度 / 跨工作区 / 会话名 / 主题）**：① **消除「刚打开时面板一片空」**（工作区兜底 + 预取 + 不擦内容）与**面板宽度不跟手**（根视图误入 Auto Layout，改回手动布局并把滚动条换成覆盖式）；② **跨工作区切换后只显示目标工作区的会话**（不再把上一个工作区的会话钉在首位）；③ 会话列表**点行展开后不再重列**、只展开当前会话、当前会话改用**高亮**标出（去掉 `current` 文字），Turn 标题不再被长内容挤掉；④ **会话名不再显示 sessionId hash**——标题改为**打开面板时**独立读取 + 失败重试（去掉启动期抓取与页面就绪钩子），无标题的会话显示为 dsh web 的「新会话 / New Session」；⑤ 内容区 / 圆角块**跟随浅色 / 深色主题**。

- **修复「core 单测整套挂死」**：个别用例泄漏的 runner / 打开句柄会让 `node --test` **永不退出**（本机表现为整套测试挂住、CI 超时才失败）。现在核心套件统一加 `--test-timeout=60000`（用例泄漏后 60s 判失败，而不是把整轮拖死；README / CONTRIBUTING / CI 同参数），并修掉泄漏 runner 的用例本身。

- **修复「dsh 认证 cookie 无限累积 → 启动后 WebView 报 Failed to load plugins」**：`dsh >= 0.1.2` 用 launch token 换浏览器 cookie 做鉴权，而 **cookie 名由 authority（`host:port`）派生**——`cookieName(authority) = "dsh-auth-" + base64url(sha256(authority))`；cookie 本身**不区分端口**（RFC 6265 按 domain+path 匹配），WKWebView 的 cookie 存储又按 bundle id 持久化。于是壳层**每次启动都自拉起一个新端口的 dsh web** = 每次多一只 ~226 B 的新 cookie（30 天 TTL，实测开发版已累积 **68 只**），且**永不复用、永不覆盖**、只增不减。链路唯一被压垮的是 **client-modules 的 application batch**：45 个插件拼成**同一条 ~2.1 KB 的 combo URL**，而 node http 默认 `maxHeaderSize` 是 16 KiB——累积 `Cookie:` 头一旦超过 ~14.1 KB（**第 63 只**），请求行 + cookie 头整体超限，服务端回 **431 Request Header Fields Too Large**（空 body）→ `<script src>` 触发 **element 的 error 事件**（不是 JS 异常）→ client-modules 抛 `bundle script … failed to load` → 界面显示 **Failed to load plugins**；而紧挨着的 bootstrap（路径仅 ~80 B）仍 200，所以外壳能渲染、只有插件全挂。逐项实测：68 只 cookie → 431、40 只 → 200（3,718,152 B）、1 只 → 200；阈值扫描 62 只(14,134 B) → 200、**63 只(14,362 B) → 431**；换一个全新 cookie 存储（同二进制、同服务器）立刻恢复正常。处置：
  - 新增 **`platforms/macos/src/DshWebCookieJanitor.swift`**：复刻 dsh 的 cookie 名派生（含 `authority(port:)`），**启动时在加载入口 URL 之前**清掉所有 `dsh-auth-*` 里**非本次 authority** 的（保留当前那只，中途重载无 token 的 `webView.url` 不会掉凭据），**退出时**清掉本次留下的
  - （`applicationWillTerminate`，异步 + 泵 run loop 有界等待，超时 1.5 s，best effort——真正的保证是启动清理）；
  - spawn dsh web 时给 `NODE_OPTIONS` 追加 `--max-http-header-size=65536` 作保险带（用户/环境已显式设置则原样保留，不覆盖不重复）；
  - 清理**只碰 `dsh-auth-*`**：UI 偏好在 localStorage、会话/工作区在 `$DSH_HOME`、壳层配置在 `$DSH_HOME/shell/config.json`、Browser 面板（CEF）另有自己的 cookie 存储，均不受影响；
  - 新增 `tests/dsh-auth-cookies/run.sh`（无头，纯逻辑 22 例：用**真实抓到的 cookie 名**做向量钉住派生规则、启动/退出清理选择、68 只堆积必须清空、NODE_OPTIONS 追加规则），已接入 `scripts/local-ci.sh` 与 CI swift job。详见 docs/process/dsh-version-impact.md §6.3（R6）。

- **修复「未保存提示点取消后，反复切换工作区 Files 面板再无反应」**：页签记忆首次落地时用一个「已拒绝的目标」标记（`declinedSwitchTarget`）避免同一目标重复询问，但该标记只在**另一个**工作区到来时才清除——取消后面板仍停在原工作区（树根没变），于是对同一工作区的后续每次切换请求都被**静默吞掉**，面板永久卡在不再跟随的工作区上（`app.log` 实测：`cancelled by user` 之后每次都是 `stays declined`）。现在取消/中止**只延迟、不拉黑**：不再记标记，下一次请求（= dsh web 里真实的会话切换）照常询问；同时把「已有询问在途」由「忽略新请求」改为**最新请求优先**（`supersedePendingSwitchPrompt` 结束旧 sheet，杜绝卡死）。回归测试见 `tests/file-panel/panel-switch-tests.swift`（`a later switch to the same workspace is attempted again`，对修复前的 `FilePanel.swift` 实测失败）。

- **修复「未保存提示取消后，Files 面板与 dsh web 显示不同工作区」**：提示原本给了「取消」——但工作区切换是在 dsh web 里先发生的，取消只会让面板永久停在旧工作区，与 web 不一致。现在提示只问**是否保存**（保存并切换 / 不保存），面板**无条件跟随**；改动无法落定时（保存失败、面板不可见、ESC 等未识别响应）把相关页签**留在页签栏**（不关、不记忆），既不丢改动也不掉队；并发请求改为**最新优先**（`switchRequestGeneration` + `supersedePendingSwitchPrompt`）。测试改为钉住不变量：`an unsaved tab stays open when there is nobody to ask` / `the panel follows the workspace anyway` / `the saved tab was handed over to the workspace it left`。

- **修复「切换工作区提示框按钮显示成 `preview.switchDiscard`」**：上一轮把两个 L10n 键改成动作中性名（`preview.switchUnsavedTitle`→`preview.unsavedTitle`、`preview.switchDiscard`→`preview.discard`）时，只改了新写的关闭提示调用点，工作区切换提示的两处**漏改**——而 `L10n.tr` 的兜底是 `table[key] ?? (key, key)`，于是标题与按钮直接把键名当文案显示。已修正两处调用点，并新增 **`tests/l10n/` 键名 lint**（`lint.py`，接入 `local-ci.sh` 与 CI swift job）：扫出所有 `L10n.tr("…")` 字面量键与 `L10n.table` 比对——**缺失键 / 重复键 / 中英缺一**一律 FAIL（对修复前的 `FilePanel.swift` 实测报出 `preview.switchDiscard, preview.switchUnsavedTitle`），表里无人引用的键只告警（有 `wizardL10n` 这类运行时拼键）。

- **修复「关闭页签 / 关闭面板会静默丢弃未保存修改」**：页签 ✕ 与 ⌘W 调用的 `close(_:)` 直接关页签、面板 ✕ 直接 `closeAllTabs()`，两者都不问一句——面板里完全可以停着未保存的编辑。现在两条路径统一走 `askAboutUnsaved` + `saveTabs`：**保存并关闭 / 不保存 / 取消**（取消 = 不关；保存失败 → 中止关闭、保留缓冲并报 `preview.saveFailed`；无窗口无人可问 → 一律不关，绝不静默丢弃）。工作区切换的提示与关闭提示共用 `pendingPromptAlert`，新的切换请求会让在途提示失效。L10n 更名两键为动作中性：`preview.switchUnsavedTitle`→`preview.unsavedTitle`、`preview.switchDiscard`→`preview.discard`，新增 `preview.closeUnsavedMessage` / `preview.closeSave`。

- **修复正式版点 Wiki 面板「生成/更新知识库」无反应、起不出 dsh 会话（复用别人的 dsh web 导致原生 RPC 全 401）**：正式版（非开发版）启动时若 3080 上已经有一个 dsh web，会走「复用」分支——而该分支写死 `entryURL = http://127.0.0.1:3080`（**不带 `?token=`**），于是 `server.webToken == nil` → `DshWebRPC.token = nil` → 独立 ephemeral session 换不到 cookie → `session/create`、`session/prompt` 一律 401 → `WikiRPC.createSession` 返回 nil，而旧的失败路径「还没有在途生成」时什么都不做，表现就是点了没反应。三层根因叠加：① 3080 上是**壳层自己上次异常退出留下的孤儿**（实测 `lsof`：`stdout/stderr = ~/Library/Logs/oh-my-dsh/server.log` + `cwd = HOME`，正是 `ServerManager` 拉 dsh web 的写法；同机另有 5 个同类残留），而 `applicationWillTerminate` 只停「本次自拉的」服务、复用过的实例永远收不掉；② 就绪探针 `isDSHServing()` 用 `URLSession.shared`，它共享 app 持久 cookie 存储里一张**未过期**的 `dsh-auth-*`（authority `127.0.0.1:3080`，30 天），使裸 GET 返回 200 + 含 `__DSH_BOOT__` 的真页面，被误判成「老版本、无需鉴权、可以复用」（磁盘缓存同理可骗）；③ 该 3080 实例其实是 dsh 0.1.2，`/api` 只认 token。处置：
  - `ServerManager.start()` **彻底删除复用分支**（连同 `DSH_NATIVE_FORCE_SPAWN` 开关）：永远自拉起自己的 dsh web（3080 被占自动换空闲端口），保证拿到 launch token；同 `DSH_HOME` 下数据本就共享，自拉起不丢任何东西；
  - 就绪探针改用**专用 session**（`httpCookieStorage = nil`、`httpShouldSetCookies = false`、`.reloadIgnoringLocalCacheData`、`urlCache = nil`），不再被持久 cookie / 磁盘缓存欺骗；
  - 新增 **`reapRecordedOrphan()`**：拉起时把 `{pid, port, token}` 记到 `$DSH_HOME/shell/dsh-web.json`，下次启动若该实例仍在（用 token 探活证明还是自己那台，绝不误杀别的进程）就先回收再拉起——「上次没关干净」不再累积；正常退出时清除记录；
  - `app.log` 在 `webToken == nil` 时明确告警「native RPC cannot authenticate (401)」，不再静默；
  - Wiki 面板：会话压根没起来时状态条显示「生成失败（详见日志）」并写 `app.log`（端口/仓库/workspaceId），不再是一次无效点击；
  - `DshWebRPC`：只有端点真的不存在（HTTP 404/405）才降级为点号方法——此前**任何**失败（超时/401/业务错误）都会把该端点永久钉成 legacy，一次抖动就让本次运行内所有后续调用打到 0.1.2 根本没有的端点；cookie 换成功才记为已认证；`WikiRPC.createSession` 在 workspaceId 被拒时回退 `cwd` 建会话（保证「能在对应 workspace 起出会话」），create/prompt 超时 6s→15s。详见 docs/process/dsh-version-impact.md §4.4（含完整证据链）。

- **修复「内置浏览器面板一片空白（页签/地址栏照常更新）+ 右键菜单弹错位」**：两处根因叠加，都落在 **OSR（离屏帧自绘）渲染路径**上。
  - **触发（1.14.0 设置搬家丢了用户取值）**：1.14.0 把壳层设置从 `UserDefaults` 搬进 `$DSH_HOME/shell/config.json`（`ShellConfig`）时**没有迁移已有取值**——用户显式设过的 `browserRenderMode = windowed`（窗口化渲染，见 docs/plans/BROWSER_PLAN-browser-panel.md §十一的既定默认）留在 plist 里再没人读，于是回落到代码里的 `osr` 分支，而 OSR 路径（下述）本身是坏的。现在 `ShellConfig` **首次加载时一次性把旧 UserDefaults 里壳层自有键搬进 config.json**（只搬本文件尚无取值的键，`legacyUserDefaultsMigratedAt` 标记保证只做一次、显式值永远优先；browserRenderMode / appTheme / previewPanelWidth / channel.global.list 等一并保住），并把**代码默认改回文档记载的 `windowed`**（要 OSR 需显式设 `osr`）。
  - **OSR 自绘帧画在被盖住的层上（空白的直接原因）**：帧原来写进 `BrowserOSRView`（容器，父层）的 `layer.contents`，而容器的子视图 `pageView`（页面区，铺满容器且垫着不透明黑/白背景）的 layer 画在父层 contents **之上**，整帧被盖住 → 内容区永远只剩背景色。CEF 本身没问题：标题、地址栏、console、CDP 截图全部正常，所以只靠 REST API 排查发现不了。现在帧**画在 `pageView` 自己的 layer 上**（同层：背景色在 contents 之下做兜底，窗口化模式不受影响）。详见 docs/fixes/browser-blank-panel-fix.md。
  - **右键菜单位置（“点右键，左边有反应”）**：OSR 下 CEF 给的菜单坐标与宿主视图坐标系不一致（视口按 `GetScreenInfo.device_scale_factor` 走设备像素：帧回调 1814×2174 对应 907×1087 点），按视图坐标换算得到的点落到窗口右下之外，AppKit 只能把它塞回屏幕边缘 → 表现为“点下面弹上面、点右边跑到左边”。现在**以当前鼠标的屏幕坐标为准**（右键必来自鼠标），CEF 参数只作键盘唤起菜单时的兜底，两者差异写 `app.log`。
  - **OSR 帧派发错配**：帧回调原来按 `tab.id` 找页签，而 CEF 给的是 shim 的 `browserId`（DevTools 子浏览器同吃同一计数器，开过 DevTools / 关过页签后必然错位）→ 改为按 `browserId` 认页签，DevTools 子浏览器的帧进 `devtoolsContent`（不再画进主页面区）。
  - 回归测试：`tests/browser-panel/` 新增帧落点（pageView 而非容器）、按 browserId 派发、DevTools 帧进 DevTools 区、菜单锚点（共 71 例，对修复前的代码实测 4 例 FAIL）；新增 `tests/shell-config/`（旧 UserDefaults 迁移 / 只做一次 / config.json 优先 / 不搬无关键，13 例）。两套均已接入 `scripts/local-ci.sh` 与 CI。

### Docs

- **审查面板**：新增 `docs/design/panels/review-panel-design.md`（目标 / 非目标、数据来源的三类记录、覆盖矩阵、为什么审计逻辑在 core 而不在 Swift、CLI 契约），并在 `.dsh/wiki/modules/` 下新增模块页 `review-panel.md`。
- **浏览器面板空白事故**：新增 `docs/fixes/browser-blank-panel-fix.md`（OSR 帧落点、菜单锚点、帧派发的根因与排查手段、回归测试）；`docs/process/dsh-version-impact.md` 补写 **§6.3「R6 详解」**（dsh-auth cookie 累积：cookie 名派生规则、431 的 ~14 KB 阈值实测、启动/退出清理时机与升级时的验证命令）。
- **wiki 增量同步**：审查面板模块页、文件面板工作区页签记忆、工作区切换的取消语义、dsh 认证 cookie 清理与 ShellConfig 旧设置迁移、浏览器面板渲染默认（windowed）与 1.14.0 空白事故、v1.15.0 版本线与用例基线。
- **README / CONTRIBUTING 同步本次发布**：README 修正浏览器面板渲染**默认已改回 windowed**（原文写「默认 OSR」，与代码不符）、WebView 最小宽度（1050 → 1100pt）与「右侧六个面板」（→ 七个）的表述，并在「特性一览」补审查面板、在「目录」补 `ShellConfig.swift` / `DshWebRPC.swift` / `DshWebCookieJanitor.swift` / `WorkspaceTabMemory.swift`；CONTRIBUTING 补齐本次新增与既有但漏列的测试套件（`review-panel` / `file-panel` / `l10n` / `shell-config` / `dsh-auth-cookies` / `terminal-panel` / `terminal-emulator`）与 `tests/` 结构说明。

## [1.14.0] - 2026-09-11

### Added

- **钉钉原生适配器（`dingtalk-stream`）**：通道面板新增**钉钉自建应用机器人**接入，走官方 Stream 模式长连接（无需公网回调 / 内网穿透），与微信共享同一套面板模型（接入向导 / 连接状态 / 项目视图会话消息 / 每会话跨项目路由）。core 新增独立适配器模块（`core/lib/dingtalk.js`、`dingtalk-stream-transport.js`、`dingtalk-device.js`、`dingtalk-access.js`）与配套单测（`core/tests/dingtalk*.test.js`），面板侧完成向导接线与生命周期（启动拉起 runner、退出关闭）；设计与边界见 `docs/design/channels/channel-dingtalk-stream.md`。
- **钉钉绑定向导（device-code 扫码）+ owner-binding 安全门**：向导内完成 device-code 绑定——`init/begin` 得二维码 → 面板内渲染 → 手机钉钉扫码**自动创建企业内部应用 + 机器人** → 本地 `poll` 拿 AppKey/AppSecret 写入 store（chmod 600）；不便于扫码时提供「在浏览器中打开」链接。绑定完成后**只有本机管理员能驱动 dsh**：未绑定前机器人**拒绝所有人**（防任何组织成员经机器人操作本机 bash/文件/token），用 `/bind <口令>` 绑定（口令本机生成、见面板与运行日志），且**串行化处理——只有第一个发送正确口令的人能绑定**（修掉并发 last-writer-wins）；绑定成功回两条消息（确认 + 完整 `/help`）。绑定状态落 `~/.dsh/channels/<channelId>.binding.json`（chmod 600）；已配置的钉钉通道重开向导**不再重复扫码**（否则会重复创建应用），并自动恢复 `/bind` 口令；向导任一步「返回」都会取消在途 login 子进程。
- **通道面板交互增强**：全局配置新增**解绑**（清空该通道配置并停掉 runner）；平台卡片状态点支持**悬浮提示**（不再只靠颜色传达状态，对色觉障碍友好）；微信绑定页展示「**已配置**」状态 + 显式「重新登录」（避免误替换已绑定 token）；钉钉无「正在输入」能力，以文字 ack 代替 sendTyping。
- **dsh 升级改为「分步 + 分阶段 + 二次确认」**：不再一步升到 dist-tags.latest，每次只升到**紧邻的下一个发布候选**（stable/rc，排除 alpha/beta/dev；从 registry versions 取号，选步逻辑入共享 core 的 nextStepTarget，Swift 与 core 同一规则）。手动「检查并升级」为三段式：① 检测并提示「当前 vA → 可升 vB」→ 用户确认；② 后台把 vB 预热进共享 npm 缓存（不改动线上 dsh 树、可取消）；③ 下载完成**再次确认**后才原地安装 + 重启。自动升级（启用时）**先起服务不再阻塞启动**，24h 节流到达后在后台检测并下载，下载完成后弹窗请用户确认才正式升级（prefetch / apply 拆分见 core/lib/upgrade.js 与 main.swift 的 DSHUpdater）。
- **dsh 升级备份与失败自动回滚**：正式升级前整树快照 runtime/dsh 到 ~/Library/Caches/oh-my-dsh/upgrade-backups/（只留最近一份）；安装失败或安装后版本校验不符自动回滚到备份并给出提示。新增调试钩子 `DSH_AUTO_UPGRADE_NOW=1`（忽略 24h 节流、每次启动都跑自动升级，便于验证该流程）。

### Changed

- **内置 dsh 版本推进到 `@deepseek-ai/dsh@0.1.2-rc.1`**（0.1.1 → 0.1.1-rc.2 → 0.1.2-rc.1，`build-app.sh` 的 `DSH_PACKAGE_SPEC` 默认值与打印行同步；构建期可用 `DSH_PACKAGE_SPEC` 覆盖）。壳层与内置 dsh **同步移动**：0.1.2 改了 `/api` 的鉴权（每实例 launch token → cookie）与 RPC 形状（斜杠端点 + `payload.args`），并移除了 `workspace.list` / `session.list` 的旧形态，本版全部兼容改动都围绕这些变化（见下方 Fixed）；升级影响清单、五个耦合面与执行 SOP 见 `docs/process/dsh-version-impact.md`，逐项兼容审计与验证记录见 `docs/plans/` 下的 0.1.2 文档。

### Fixed

- **dsh 私有 workspace 存储读取加护栏（R4）**：`workspace.list` 在 dsh 0.1.2 被移除后，壳层只能读 dsh 自己持久化的 `$DSH_HOME/storages/workspace.json` 来枚举工作区——那是 `defineDomain({ name: "workspace", version: 2 })`（`dsh-workspace/lib/invariant.js`）定义的**私有带 schema 存储**，还带 `pendingMutation` 这类中断恢复标记，上游随时可能改字段/搬文件/升版本，读不懂时会让 5 处功能（频道 `/wks`、门控、`/ses`、面板项目目录、wiki/issue-runner 的工作区归属）**静默变空**。本次不加新数据源（0.1.2 已无 `workspace.list`，`workspace/follow` 是流式），而是把这条兜底变得可观测、可收口：
  - core 与 Swift 两侧读取器都校验 `unit.name/unit.version`；版本对不上仍**尽力解析**但明确报出（`[workspace-store] … is domain workspace v3, this build understands v2 — read best-effort`），形状意外报 `unexpected shape`，**文件缺失保持安静**（0.1.1 本就正常没有它）；
  - 日志出口：core → 频道 runner 日志，Swift → `app.log`；
  - **单一实现收口**：原先有三份各自解析该私有格式的代码（core `workspace-store.js`、Swift `DshWorkspaceStore`、`main.swift` 的 `persistedWorkspacePath`），现在 `main.swift` 改为调用 `DshWorkspaceStore`，只剩 core 与 Swift 两处；
  - 只读不写；补 core 4 条 + Swift 4 条用例（版本不匹配/形状意外/缺失安静 + 解析顺序与字段）。
  - docs/process/dsh-version-impact.md 新增 §6.2「R4 详解」（依赖的具体结构、五个静默断裂点、三个次要坑、升级时的验证命令）。
- **修复「面板点会话行定位到 dsh web」在 dsh 0.1.2 下静默失效（R3 实测坏点）**：注入的 `sessionOpenerScript` 固定发 `POST /api/session/list`，但 body 里仍是点号 `method:"session.list"` 且 payload 未包 `args`，0.1.2 服务端直接拒绝（`gateway/bad-request: method "session.list" does not match endpoint "session/list"`）；0.1.1 上该斜杠路径又不存在，等于**写死单版本形状、两个世代各坏一次**。改为运行时双面：先按 0.1.2 形状（`session/list` + `payload.args._request`）请求，失败再回退点号（`/api/session.list` + `payload`），失败原因打 `[dsh-opener]` 日志。另外 `DSH_UI_DEBUG=1` 新增页面加载后的注入桥自检（`dsh injected bridges: {tracker, opener, preview, rows}`），让这类「成功时无感、失败时无声」的脚本至少有可观测信号；docs/process/dsh-version-impact.md 新增 §6.1 详解 R3 的三个脚本各自依赖什么、坏了什么症状、升级时怎么验。
- **外部已启动的 dsh 0.1.2 实例不再「悄悄」被忽略**：0.1.2 起的实例会用 401 + `authentication required` 回应裸请求，壳层因此判为不可复用而另起一个实例——这是**按设计**的：token 每进程随机且只存在于该进程 stdout，拿不到；而只要 `DSH_HOME` 相同，壳层自拉起的实例与外部实例就是同一份数据（workspaces / 会话 / settings / channels 全在 `$DSH_HOME` 下），复用只省一个进程。现在这个判断会写进 `app.log`（`existing dsh web on 3080 wants its launch token … not adopting`），不再出现「怎么又起了一个实例」无从解释的情况；唯一的注意点是同一个 `DSH_HOME` 不要长期并行跑两个 dsh web（两者持久化同一批文件）。见 docs/process/dsh-version-impact.md A3/R2。
- **修复内置 dsh 0.1.2 下壳层原生 RPC 全部失效（wiki 生成、issue-runner 流水线、会话目录跟随）**：`WikiRPC`（WikiPanel）、`IssueRunnerPanel` 的会话/工作区调用与 `DSHSessionRPC`（main.swift）此前只会讲 dsh ≤0.1.1 的老接口——点号方法名、payload 直接是参数、且**不带任何鉴权**；0.1.2 起 `/api` 只认 launch token 换来的 cookie、端点改斜杠、参数包进 `payload.args.<request|_request>`，于是这些原生调用全部 401/404（wiki 点「生成」拿不到 sessionId、issue-runner 建会话/发消息失败、workspace.list 扫描为空；只有 `DSHSessionRPC` 有磁盘兜底不至于完全失灵）。修复为新增共享的 `platforms/macos/src/DshWebRPC.swift`：
  - **双面调用**：先按 0.1.2 斜杠端点 + `payload.args.<request|_request>` 试，失败再回退点号方法，并**按端点**记忆所选接口面（同一服务有 `session/list` 却没有 `workspace/list`，按服务记忆会互相污染）；`modernExtras` 只在 0.1.2 面注入（如 session/prompt 必填的 requestId）；
  - **鉴权**：用一个独立 **ephemeral URLSession** 访问 dsh web 自报的 `/?token=…` 种下 `dsh-auth-*` cookie（WebView 的 cookie 在 WebKit 自己的数据存储里、与 URLSession 的 `HTTPCookieStorage` 互不共享，只能自行换取），每端口只换一次，401 时自动重换一次并重试；
  - **工作区列表**：0.1.2 已无 `workspace.list`，回退读 dsh 持久化的 `$DSH_HOME/storages/workspace.json`（`DshWorkspaceStore`，与 core 同一份契约，按 `global.workspaceIds` 保序）；
  - token 由 `ServerManager.webToken`（dsh web 自报的带 token 入口地址）在服务就绪时注入，**不落日志**；
  - 消费者全部改接：`WikiRPC`（createSession/prompt/sessionRunning/cancel/workspaceList/resolveWorkspaceId）、`IssueRunnerPanel`（会话 + 工作区）、`DSHSessionRPC`（会话 cwd 两条路径，保留磁盘兜底）。
  - **测试**：新增 `tests/dsh-rpc/run.sh`（headless，注入 HTTP 假传输：信封形状、斜杠/点号回退、按端点记忆、token 换取与 401 重换、workspace.json 解析），接入 `ci.yml` 与 `scripts/local-ci.sh`；wiki 面板测试的编译清单补上该文件。
- **修复开发版（内置 dsh 0.1.2-rc.1）下 Channel 指令全部失效 —— 微信发 /wks 回「没有可用的 workspace」，而面板里明明有已启用的 workspace（C1）**：channel runner（core）此前只讲 dsh ≤0.1.1 的老接口——点号方法名（/api/workspace.list、/api/session.list…）、payload 直接是参数、且不带任何鉴权。0.1.2 起 dsh 换了两处：① /api 被**每实例 launch token 换来的 cookie** 挡住（裸 POST 一律 401）；② 方法名改为**斜杠端点**、参数包在 payload.args 里，并且**彻底移除了 workspace.list**（工作区改由 workspace/follow 流式下发）。于是 runner 的每次调用都失败：列不出工作区（/wks「没有可用 workspace」）、列不出会话（/ses 空）、普通消息与 /new 也建不了会话。修复为：
  - core 新增 **dsh 版本无关的 RPC 传输层**（core/lib/dsh-rpc.js）：先按 0.1.2 的斜杠端点 + 信封尝试，端点不存在（404）再回退老的点号方法，且**按端点（而非按服务）记忆**所选接口形态，避免 workspace/list 的 404 连带把 session/list 也拖回老接口；
  - 新增 **launch token → browser cookie 交换**：GET `/?token=…` 取 dsh-auth-* Cookie 并缓存，之后带 cookie 调 /api（无 token 时静默退回旧版行为，不破坏 0.1.1）；
  - **工作区列表磁盘兜底**（core/lib/workspace-store.js）：0.1.2 没有 workspace.list，改读 dsh 自己持久化的 $DSH_HOME/storages/workspace.json（与壳层 B 方案同一个文件，按 global.workspaceIds 保序，取 workspaceId/path/title/sessionIds），因此 /wks 即便没拿到 token 也能列出工作区；
  - **会话读取/回推适配**：会话列表改走 session/list；最后一条回复改由 session/page 按 session/list 给出的 projection cursor（projections.asOfSeq）回放；prompt 补上 0.1.2 必填的 requestId；
  - **壳层把 token 传给 runner**：ServerManager 记住 dsh web 自报的带 token 入口地址（entryURL/webToken），启动 `channel run` 时以 `--dsh-token` 传入（不落日志）；CLI 同时支持环境变量 DSH_WEB_TOKEN；
  - **修正 channel runner 启动时机**：原先在 `startServer()`（异步）之后立即启动，runner 可能拿到默认端口 3080 且拿不到 token，现改为服务就绪（端口与 token 都已知）后再启动。
- **修复开发版读不到保存的面板宽度（ShellConfig 早期缓存错误 home）**：ShellConfig 在 applyDevIsolation 注入 DSH_HOME 之前被首次访问，按旧路径（~/.dsh/shell/config.json，不存在）载入并把"已加载"置真，之后一直返回空缓存 → 读不到保存宽度、回退默认 560。改为"按路径感知重载"（缓存记录载入路径，DSH_HOME 变化即重新加载）。
- **面板宽度逻辑修正**：560 现在是面板**最小宽度**（此前被当作"默认宽度"，导致点面板总缩回 560）；用户拖动的宽度会被记住，**程序化布局不再回写覆盖**（切面板替换 subviews[1] 时的等分宽度不再被保存）。切面板时**按目标宽度预置新面板视图 frame + 零时长无动画**，消除"先等分(WebView≈1000)再扩到 1100"的中间帧。冲突策略（WebView 优先）：窗口 < 约1709pt 放不下"面板≥560 + WebView≥1100"时自动隐藏面板，保 WebView ≥1100。
- **ShellConfig 写入防抖异步**：改为 0.3s 防抖、后台线程经 core CLI 持久化（失败回退直写），退出时 flushNow，避免高频（面板拖动）同步 spawn 子进程阻塞主线程。
- **壳层配置改为语言无关的文件存储（core 单一实现）**：新增共享 core 的 settings 模块（core/lib/settings.js + ohmy-core settings get/set/unset/list/path），把壳层自有配置存成 UTF-8 JSON：$DSH_HOME/shell/config.json（dev → ~/.dsh-dev/shell/config.json）。Swift 侧新增 ShellConfig 门面：读直接读该 JSON（快、无子进程），写委托 core CLI（写入/合并/原子化语义单一实现，失败时回退直写）。已迁移 ~12 个自有 key（appLanguage/appTheme/dshRegistry/autoUpgradeDsh/nextAutoUpgradeCheck/hasCompletedOnboarding/preview*/rightPanelKind/browserLastURL/browserRenderMode/channel.global.list/wiki*）。仍留在原生 UserDefaults 的仅系统/框架强制项：AppleLanguages、NSWindow Frame。dev 隔离注入（applyDevIsolation）提前到任何配置读取之前。
- **开发版使用独立 bundle id（com.ohmydsh.app.dev）→ 独立 UserDefaults 域**：此前 dev 与正式版共用 com.ohmydsh.app，导致 dev 的偏好/状态与正式版共享——例如 Channel 面板「全局配置」的通道列表 channel.global.list（含缓存状态/连接）会显示正式版那份。改为 dev 构建时 bundle id 加 .dev 后缀，dev 拥有自己的 UserDefaults 域（channel.global.list、auto-upgrade 节流、语言/registry/主题等全部独立），可与正式版并存。
- **所有家目录级 ~/.dsh 硬编码统一改走 DSH_HOME（开发版不再误读正式 ~/.dsh）**：
  - ChannelPanel 三处硬编码 ~/.dsh/channels（channel 运行状态、项目关联 workspaces.json、项目开关）→ 复用 env-aware 的 ChannelStoreReader.channelsDir()；
  - IssueRunnerPanel 的 GitHub token 路径（~/.dsh/gh-token、~/.dsh/tokens/<owner>-<repo>）→ 按 $DSH_HOME 解析；
  - core：channel-runner 的 channel-runtime 目录与 ohmy-core 的 --dsh-home 默认值 → 优先 process.env.DSH_HOME；
  - 内置技能文档（web-dev-tools 的 browser-api.port、issue-resolve 的 token 路径）→ 改为 ${DSH_HOME:-$HOME/.dsh}（dev/prod 通吃；内嵌文本与仓库副本保持字节一致，skills 测试通过）。
  - 保持不变的：项目内 <repo>/.dsh（tasks/channels.json/wiki）与有意保留常量（dev home、旧 browser-dev 迁移源）。
- **适配 dsh 0.1.2-rc.1 的预览打开文件（D3）**：0.1.2 把文件打开从 host.openPath 迁到会话控制器的 session/openWorkspacePath（端点 /api/session/openWorkspacePath，路径在 payload.args.request.path —— 实测抓包确认）。预览拦截脚本改为同时匹配新旧端点，并按 payload.args.request.path → args.path → payload.path 依次取路径，恢复「消息流里点文件 → 在预览面板打开」。
- **修复 dsh 0.1.2-rc.1 下切换会话不跟随切换项目目录（会话跟踪）**：0.1.2 客户端把 RPC method 从点号改为斜杠（如 subagents/list）并把 sessionId 放到 payload.args.*，壳层注入的 session 跟踪脚本按旧的点号 method 与 payload.sessionId 匹配会全部落空，导致 webView 切会话不通知壳层、项目目录不跟随。修复为同时识别新旧两种 method 名，并从 payload.args（parentSessionId/agentId/sessionId/request.sessionId）回退到旧的 payload.* 取 sessionId。配合 B（workspace.json 磁盘映射）即可在切换会话后更新终端/预览/wiki/tasks 的项目目录。
- **恢复 dsh 0.1.2-rc.1 下的会话 workspace / 项目目录读取（DSHSessionRPC）**：0.1.2-rc.1 移除并改了 /api/session.list（改为 token + 控制器 RPC），壳层读当前会话 cwd/workspace 会 401/404 而失败。修复为当 live API 取不到时，回退读取 dsh 持久化的 $DSH_HOME/storages/workspace.json（磁盘、无需鉴权）：按 sessionId 找到所属 workspace 的 path，否则取最近更新的 workspace path，用于终端/预览/wiki/tasks 的项目目录定位。
- **适配 dsh 0.1.2-rc.1 的 Web token 鉴权（升级到该版本后启动失败）**：dsh 0.1.2-rc.1 起给 Web 界面加了每实例 token + cookie 鉴权，裸 GET 根路径返回 401、无 __DSH_BOOT__，而 oh-my-dsh 原先用裸 GET 根路径判就绪、并直接加载根路径，导致升级到 0.1.2-rc.1 后 App 判定「dsh web 启动失败」。修复为：启动时读取 dsh web 自己打印的服务地址（含 token，来自其日志行 dsh web: http://127.0.0.1:<port>/?token=...），据此做就绪判定，webView 也直接加载该带 token 地址（WKWebView 跟随 303 种 cookie 后正常显示）；无 token 的旧版本回退到原 __DSH_BOOT__ 探测。见 ServerManager.start() / servedEntryURL()。
- **自动升级节流时间戳改为「本轮跑完才写」+「稍后提醒」**：不再在开始检测时就消耗 24h 窗口（秒退/中途退出不会吞掉窗口，下次启动会重试）；自动检测下载完成后若用户选「稍后」，则把下次自动检查推到约 2 小时后并定时提醒，用户仍可随时手动升级；离线/下载失败按 ~2h 重试，无需升级/已升级按 ~24h 节流。
- **开发版（DSH_DEV_BUILD=1）运行隔离**：开发版构建现在自拉起**独立 dsh 实例**（不复用已在 3080 运行的实例，3080 被占时自动取空闲端口），并使用**独立 DSH_HOME（默认 ~/.dsh-dev）**，使 dsh 会话/配置/skills/channel 与正式 ~/.dsh 完全隔离；同时错开 CEF CDP（9333→9433）与 Browser API（3081→4081）端口，可与正式版并存测试（均尊重用户显式 DSH_HOME / DSH_CDP_PORT / DSH_BROWSER_PORT 覆盖）。旧开发版 CEF profile ~/.dsh/browser-dev 会**自动迁移**到新隔离目录 ~/.dsh-dev/browser-dev（幂等，目标已存在则跳过）。shell 侧 channel token 读写路径统一改为按 $DSH_HOME 解析，开发版不再写入正式 ~/.dsh。
- **自动升级进行中「检查并升级 dsh」菜单置灰**：当自动升级开启且后台正在检测/下载/安装时，Settings 菜单里的「检查并升级 dsh…(⌘U)」自动置灰不可点，避免与自动流程并发；手动流程下载/安装期间同样置灰。Settings 窗口内按钮在忙碌时点按会提示「已有升级流程正在进行」。
- **升级流程不再用全窗口状态浮层盖住整个界面**：手动/自动「检查、下载、安装」阶段均在后台静默执行，不再调用会铺满主窗口（白底+转圈）的 showStatus 浮层，避免点 Settings 的 Check & Upgrade 时整个 App 闪屏；只在每步完成时弹确认/结果框（真正重启服务那一下仍走启动浮层）。
- **自动升级 dsh 失败（exit 127）**：App 内自动升级用打包 node 的绝对路径启动 npm，但 npm 执行依赖包 lifecycle 脚本（如 `@deepseek-ai/dsh-subprocess-local` 的 postinstall `node ensure-spawn-helper.mjs`）时通过 shell 按 `PATH` 找 `node`；GUI 启动的 App 继承 launchd 的精简 PATH 通常没有 `node`，报 `sh: node: command not found`、升级中断。修复为给升级子进程前置注入打包 node 所在目录到 `PATH`。
- **升级后未重启服务 / WebView 未重载**：自动/手动升级跑完后运行中的 dsh web 仍在内存里跑旧代码（只刷新版本事实、没重启服务），新版本要等下次启动才生效。修复为升级成功后停止 App 自己拉起的服务并重新拉起 + 重载 WebView（含首次启动失败的场景）。
- **钉钉 Stream 连接长期停在「连接中」**：连接就绪判定改用 SDK 语义的「socket 已打开（connected）」（不再等一个永远不会来的回调）、以原始 ticket 建连、并补上明确的连接超时——修掉绑定成功后卡片一直显示 connecting 的状态。
- **通道消息分桶修正**：命令 / 系统类消息（`/help`、`/status` 等，无项目上下文）固定进**通道级全局桶**，只有 dsh 会话消息才按 workspace 归属——此前这类消息会被记到某个工作区下，项目视图与路由错乱。
- **通道「启用」只由项目开关决定**：归档（archive）通道不再把它自动重新启用（迁移只播种一次）。
- **`/wks <N>` 按序号切换工作区**（对齐 `/ses <N>`），不再只支持带内容形式。
- **解绑按钮不再误打开绑定向导**：把该按钮从卡片点击手势中排除（改用 NSGestureRecognizer 委托，替换原先按点击坐标的脆弱判断）。
- **重开绑定向导的状态修正**：step 0/1 不再显示 `/bind` 口令行，恢复为「已绑定」后正确显示「已完成」。

### Docs

- **dsh 升级影响清单**：新增 `docs/process/dsh-version-impact.md`（五个耦合面 A–F + 每次升级的执行 SOP + 0.1.1 → 0.1.2-rc.1 实例复盘），并补写 §6 的 **R3 详解（注入脚本）** 与 **R4 详解（`workspace.json` 私有存储兜底）**，明确「当前唯一还在静默失效风险里」的面与升级时的验证命令。
- **钉钉**：新增 `docs/design/channels/channel-dingtalk-stream.md`（原生适配器设计：独立于微信、device-code 绑定、owner-binding 门控、Stream 长连接语义），并更新 `docs/design/channels/channel-status.md` / 通道面板文档（绑定 / 解绑 / 指令状态）；allowlist 与群聊拒绝配额等留作后续迭代。
- **README / CONTRIBUTING 同步本次发布**：README 更新「内置 dsh 版本 = 0.1.2-rc.1」、dsh 升级改为「分步 + 二次确认 + 备份回滚/自动升级后台化」、开发版隔离（独立实例 / 独立 `DSH_HOME` / 独立 bundle id / 端口错开）、壳层设置改存 `$DSH_HOME/shell/config.json` 与 `DSH_AUTO_UPGRADE_NOW`；CONTRIBUTING 补 `tests/dsh-rpc` 套件、core 模块说明与 `swift-sources.sh` 单一来源约定。
- **Wiki 同步**：dsh 0.1.2 兼容收尾（R4 存储护栏 / R3 注入脚本双面 / 外部 0.1.2 实例不复用）与钉钉原生适配器、通道绑定 / 解绑文档刷新，并记录 216 用例测试基线。

## [1.13.0] - 2026-08-24

### Added

- **Channel 面板 ↔ dsh web 会话双向联动**：点击面板项目视图会话行（单一手势）同时展开/收起其消息并定位到 dsh web 对应会话（经注入的 `sessionOpenerScript` 驱动）；反过来 dsh web 切换会话时面板自动展开对应会话、其余行收起（无对应则会话列表仍显示、仅行收起）。**以 sessionId 对应，不用 name**。设计见 `docs/design/channels/channel-web-session-link.md`。
- **Channel 指令体系 v2**：`/workspaces`(`/wks`) 与 `/sessions`(`/ses`) 支持**带内容切换**（无内容只列出、有内容即切到对应项，等同 `#wN`/`#sN`）、`/new` **统一回复**（无内容建占位 `New Session` 等首条消息激活、有内容 prompt=内容并回推答案）、移除 `/switch`；`/new` 无内容不再固定 dsh 会话标题（交由 dsh web 自动命名）。
- **Channel 项目开关落地（门控路由）**：全局 workspace 关联存 `~/.dsh/channels/<channelId>.workspaces.json`（project=workspace），开关**真正门控**——普通消息/`/new` 路由到未启用该通道的 workspace 回「该项目未启用该通道」、不建会话；`/workspaces` 只列已启用项；`#wN`/`#sN` 按目标/当前 workspace 是否启用门控（导航放行、仅拦截实际路由）。
- **Channel 异步应答 + 官方 sendTyping**：先 ack「处理中」、后台生成、结果回推；在途时后续消息回「请等待」不入队；用官方 `sendTyping`（getConfig 拿 typing_ticket）替换「处理中」文字 ack，生成时回微信原生「正在输入…」。
- **Channel 项目视图对话回复后实时刷新**：轻量重读全局 store，仅当内容签名变化时全量重建（保留折叠/展开状态），不随轮询抖动。
- **Channel 项目视图读全局 store 展示会话消息**（E 里程碑）：落地 Channel-Message-Session 关联 A/B/C/D（会话复用/工作区归属/路由统一/全局存储）；store 保留会话历史、面板显示全部会话（`/new` 不再覆盖旧会话）；`/new` 后绑定会话到 conversation、下一条普通消息复用而非新建；优化项目视图布局（通道标题栏/会话区块/对话气泡与宽度比例）。
- **Channel runner 日志**：runner stdout/stderr 路由到 `~/Library/Logs/oh-my-dsh/channel-runner-<id>.log`，暴露 core 调试日志。
- **内置 Skill 全局化 + 重命名**：三个面板配套 Skill 改为 **App 启动时安装到全局 `$DSH_HOME/skills/`**（缺失即装、App 托管下内容不一致自动覆盖更新、用户改过不覆盖），并重命名为 `web-dev-tools`（浏览器面板）/ `repo-knowledge`（Repo Wiki 面板）/ `issue-resolve`（IssueRunner 面板）；启动时自动把旧名 `shell-browser`/`repo-wiki`/`issue-fix` 迁移到新名；移除面板「按仓库安装」逻辑；新增 `tests/skills/` 无头单测（含内嵌 SKILL.md 与仓库副本字节一致断言）。
  - **frontmatter 用合法键**：`modelInvocable`/`userInvocable`（驼峰）是 dsh 弃用键会导致 skill 被忽略，已改为省略（默认 model 可调用）+ `user-invocable: false`（kebab）表达「仅 model 可调用」；`web-dev-tools` 为 model+user 双可调用。
- **macOS 源码清单单一事实来源**：新增 `platforms/macos/swift-sources.sh`（glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，排除独立工具 `MakeIcon.swift`）；`build-app.sh` / `scripts/local-ci.sh` / `ci.yml` 三方共用，新增 Swift 文件不再需要逐个登记，彻底消除「新增文件遗漏 local-ci.sh」的问题。
- **开发版构建支持**：构建时 `DSH_DEV_BUILD=1` 打包开发版（Info.plist 写入 `DSHDevBuild=1`），或直接 `./scripts/local-ci.sh dev`（等价 full，但 build 用 `DSH_DEV_BUILD=1`）；开发版运行时自动使用独立 CEF profile（`~/.dsh/browser-dev`）并跳过单实例退出，可与已安装正式版并存测试；未来如需隔离端口/channel 等资源，在 `main.swift` 的 `isDevBuild` 覆盖处快速追加。

### Fixed

- **文件面板打开文件实时刷新**：已打开的页签在磁盘内容变化后自动刷新——代理（或其他进程）改写打开的文件时，可编辑页签经 CodeEditorView.reloadFromDisk() 保留滚动位置、且不覆盖未保存的本地编辑（dirty 页签跳过），只读文本/图片/PDF/元数据页签直接重渲染；与 Wiki 面板已有的 2s 轮询刷新保持一致，打开即所见最新内容。
- **单实例约束（修复双实例争抢 CEF profile）**：App 启动时按 bundle id 检测是否已有其他实例在跑，若有则聚焦已有实例并立即退出，避免两个副本共用 `~/.dsh/browser` 导致 Chromium 异常退出（`Chromium didn't shut down correctly.`）。
- **Channel 双向联动交互**：点击会话行单一手势展开/收起并定位 dsh web、统一「手动切换 vs web 跟随」展开状态（不再互斥冲突）、会话未匹配时保持会话列表可见（仅行收起）。
- **Channel 项目开关门控修正**：开关关闭后刷新不再被重新开启（迁移只播种一次）；门控改为「按目标 workspace」——`#wN`/`#sN` 导航放行，仅拦截实际路由。
- **release 发布幂等化**：`github-publish.sh` curl 路径幂等化（中断可重跑，release 已存在则复用并只补传缺失资产）+ 逐资产进度输出。

### Docs

- **README**：Channel 面板章节补充「项目开关门控语义 + sendTyping 异步应答」与「dsh web 会话双向联动」；文件面板补「打开文件实时刷新」；AGENTS.md 增补「README 更新直接在当前分支提交，不切分支/不开 PR」。
- **Wiki 同步**：Channel 项目开关 / Channel-Message-Session 关联模型 / v1.13.0 内置 Skill 全局化与 swift-sources 单一来源等页面刷新。
- **发布决策固化**：`docs/process/release-process.md` 增补「CI CEF prepare 暂不修复」「暂不使用 gh CLI（发布统一走 curl API）」与已知坑；`docs/channel-*` 设计/实施记录更新（E 里程碑完成、Channel-Message-Session 关联模型核查）。

## [1.12.0] - 2026-08-22

### Added

- **通道面板（微信远程驱动 dsh）**（活动栏通道图标 + 菜单）：绑定微信个人号（官方 iLink 协议），在微信里发消息/斜杠指令远程驱动 dsh 干活——消息路由到项目会话、结果回复回微信；已跑通「扫码登录 → 长轮询收消息 → 指令/路由 → dsh 会话 → 回复回微信」**全链路**（真实微信 + 真实 dsh web 端到端验证）。
  - **配置面板**：全局配置视图 + 项目引用开关（写 `.dsh/channels.json`）；内置平台卡片（微信 ClawBot / 钉钉 / 飞书，带**实时连接状态徽标**）；微信扫码登录**在面板内渲染二维码**（CIQRCodeGenerator，不弹浏览器），登录态落 `~/.dsh/channels/<id>.json`（文件优先，chmod 600）；统一 40pt HeaderLabel 样式，顶部「全局配置」随时重开；
  - **项目视图**：Channel 行默认展开 Sessions + 原生 NSSwitch（灰绿）开关 + 展开区显示真实会话；行占满整宽、从内容区顶部渲染；
  - **微信内斜杠指令**：`/help`（分组排序）、`/ping`、`/status`（新格式）、`/workspaces`(`/wks`，代号+标题+`~`路径)、`/new`（无内容只创建标记 pending 等待首条消息激活、有内容创建并立即 prompt，落 workspaceId）、`/sessions`(`/ses`，工作区头+最近 5 条)、`/switch`；快捷指令 `#w1`/`#s1...`（切项目/会话，未找到有明确提示）与 #tag 路由（如 `#w1 帮我看看`）；
  - **会话驱动**：conversationId → dsh 会话映射（多轮续接，`/new` 另起），经 `session.create` + `session.prompt`（queue）驱动，回复回传微信；通道级全局状态（lastWorkspace / 会话映射 / activeSession）持久化 `~/.dsh/channels/<id>.state.json`（重启可恢复，写失败尽力不抛错）；
  - **生命周期**：启动自动拉起已配置 channel runner、退出关闭；绑定成功后自动启动 listener；SIGTERM 立即退出不留僵尸进程；runner 去重（同 channelId 不重复启动）。
- **通道核心入 `core/`（跨平台复用）**：统一抽象层（ChannelEvent / ChannelReply / 状态机 / Router / 管理编排）+ 微信 ClawBot 适配器（transport **重写为纯官方 iLink 协议**，由 `@tencent-weixin/openclaw-weixin` 2.4.6 官方源码推导）+ CLI（`channel login` / `listen` / `reply` / `run`，vendor qrcode-terminal）+ 单测（指令 / 路由 / 会话 / 传输层，全绿）。
- **文件面板升级为预览 + 编辑器**（`⌥⌘P` / 活动栏「文件」图标）：UTF-8 且 ≤2MB 的代码/文本文件面板内直接编辑，**行号栏随滚动严格对齐**（gutter 逐行按实际字形基线绘制）、**语法高亮**（vendored Highlightr，180+ 语言，明暗自适应）；未保存页签显示 `*`；`File ▸ 保存`（⌘S）原子写回，`File ▸ 关闭页签`（⌘W / Ctrl+W）；保存图标 + File 菜单置于 Edit 前；设计文档 `docs/plans/PREVIEW_PLAN-file-panel.md`（rollback-first）。
- **CI / 测试补齐**：local-ci 与 GitHub swiftc 编译清单登记 FilePanel / CodeEditorView / Highlightr / ChannelPanel；channel 单测并入 `node --test core/tests/`；clawbot 测试 mock 只返回一次消息、移除依赖真实 dsh web 的 e2e（避免残留临时会话/目录）。

### Fixed

- **通道消息重复回复**：轮询改**严格串行 while 长轮询**（对齐官方 monitor）——setInterval 破坏 `get_updates_buf` 游标推进导致同一消息被反复处理/重复回复（根因与验证见 `docs/fixes/channel-issues.md`）。
- **通道路由/状态**：通道级状态写入加内存缓存，避免 onState 与 setActiveSession 并发写 state 文件互相覆盖；`/new` 创建后立即用 /new 文本 prompt（会话非 blank、dsh web 可见）；快捷指令未找到提示更新（`#wN` → 未找到工作区、`#sN` → 未找到会话）；`/wks` 显示 workspace title + `~` 缩短路径不泄露用户目录；加载全局通道过滤历史坏 id；`channel run` 默认 dshHome=~/.dsh 使 CLI 可用。
- **面板 v2 UI**：分隔线位置修正（去掉标题/工具条之间、保留工具条/内容区之间）；工具条清空（无文字无线）+ 引导标题/卡片改纯 Auto Layout 左对齐；项目视图从内容区顶部渲染（FlippedStackView）、行占满整宽、展开手势移回 Channel 名（不再吞开关点击）。
- **代码编辑器**：Highlightr() init 崩溃防护；行号栏滚动去同步/末行缺失/越界/首布局漂移——按每行实际字形基线绘制、布局稳定后重绘。
- **终端启动目录**：解析忽略系统临时目录会话（`chan-e2e-*` 测试残留），终端不再默认落在测试临时目录。
- **CI 编译清单**：补齐 ChannelPanel.swift（修复 ChannelPanelController 未定义）与 FilePanel/CodeEditorView/Highlightr。

### Docs

- **通道文档**：`docs/design/channels/channel-design.md`（能力设计：统一抽象 + 微信/钉钉/飞书多平台扩展 + ClawBot 可行性）、`docs/design/channels/channel-commands.md`（指令清单）、`docs/design/channels/channel-status.md`（完成状态总览）、`docs/design/channels/channel-storage.md`（存储全局化设计）、`docs/fixes/channel-issues.md`（重复回复根因排查）。
- **文件面板**：`docs/plans/PREVIEW_PLAN-file-panel.md` 设计文档（预览增强，rollback-first）；README「预览面板」小节改为「文件面板」（预览 + 编辑 + 高亮）。
- **发布流程固化**：`docs/process/release-process.md`（四步发布：CHANGELOG → tag → local-release → 版本推进）；AGENTS.md 增补发布指引与 GitHub token 位置；SECURITY.md Supported Versions 同步步骤。
- **README / CONTRIBUTING 覆盖本次发布内容**：新增 Channel 面板介绍（右栏面板 + 特性一览 + 截图）；项目结构/测试清单补 channel 模块与文件面板组件；wiki 同步（channel-panel / file-panel 模块页、架构/数据模型/任务/构建脚本刷新）；README 增加 app 截图。

## [1.11.0] - 2026-08-21

### Added

- **浏览器面板（Chromium/CEF 内核）**（活动栏 globe / `⌥⌘B`）：多标签浏览器，每标签一个 Chromium 渲染进程（五 helper app：base/Alerts/GPU/Plugin/Renderer，名字承重）；地址栏导航（无 scheme 自动补 `https://`）、后退/前进/刷新·停止；控制台抽屉（CDP 捕获 console/异常/全部网络请求 + JS 求值 + 清空）；DevTools 按钮在系统浏览器打开完整 Chromium DevTools；`use-mock-keychain` 不弹钥匙串密码框；profile 收在 `~/.dsh/browser/`。
- **浏览器 REST API**（`127.0.0.1:3081`，`DSH_BROWSER_PORT` 覆盖，端口文件 `~/.dsh/browser-api.port`）：`status`/`open`/`tabs`/`back`/`forward`/`reload`/`stop`/`eval`/`console`/`console/clear`/`screenshot`/`hide`，CORS 放行；Agent 驱动自动展开面板；配套技能 `.dsh/skills/shell-browser/SKILL.md`（modelInvocable）。
- **DevTools 工具条可拖动调高**（150–700pt，主窗口联动压缩）：拖动条悬停显示上下拖拽光标；拖动中主页面/DevTools 两 CEF 视图完全静止（frame/视口不动）、全程禁用 autoresizing、跳过 layout 钩子、抑制逐帧 notifyResize，松手统一对齐并恢复页面滚动位置（CDP 记录 scrollY、松手 scrollTo）；80ms resize 节流消除逐帧重排导致的页面抖动上移（详见 `docs/fixes/devtools-drag-fix.md`）。
- **视图菜单「外观」切换**（`feat(#6)`）：浅色/深色/系统三态，与设置窗口外观双向同步。
- **App 体积精简**（约减 ~138M）：slim app bundle（移除重复 node ~116M、node-pty win32 prebuilds），见 `docs/plans/APP_SLIM-app-size.md`。
- **活动栏图标顺序与文案调整**：Files(重叠文件图标)/Terminal/Browser/Wiki/Tasks，tooltip 固定英文。
- **CEF 构建管线**（`platforms/macos/build-cef.sh`）：版本固定 + sha1 校验 + `.cache` 缓存；wrapper/shim/helper 编译；五 helper 组装与由内向外签名；`build-app.sh`/CI 接入。
- **本地发布/CI 工具链**：`local-release.sh` 支持 `pack` 子命令（只打包不发布）；发布模式强制版本一致性（版本单一来源 git tag，不一致即阻断）；runtime 缓存按架构分目录、双架构 release 不再互相覆盖重建；CEF 缓存 key 改用稳定绝对路径。
- 测试：`tests/browser-panel/`（日志缓冲/URL 规范化/HTTP 解析/REST 路由，56 断言）；CI 编译清单与浏览器测试步骤登记。
- 设计文档：`docs/plans/BROWSER_PLAN-browser-panel.md`（含根因修正：CEF 148+ 需五 helper，缺 `(Renderer)` 导致 renderer 静默失败——曾误判为签名问题）。

### Fixed

- **DevTools 拖动条导致 CEF 视图上移/底部空白**：根治为 contentsScale 同步 + CEF 视图 frame 统一由 layout() 同步（去手动/AutoLayout 竞争）、frame origin 强制为零；拖动中禁用 pageView/devtoolsContent 的 autoresizesSubviews、完全跳过 layout 钩子、抑制 notifyResize（此前每帧 WasResized 致页面缓慢上移），松手统一刷新——消除页面顶部反复重排跳动与累积上移。
- **CEF 覆盖式启动卡死**：覆盖式约束改用 activate 数组激活（init 里 `isActive=true` 曾致启动卡 buildWindow/Starting）；回退覆盖式约束并修 `CEFShim.shutdown` 未初始化时泵循环空指针；覆盖式切换后把主 CEF 视图钉回顶部全高（Chromium 会把 CEF 底部对齐致顶部空白）+ 视口一次 resize。
- **DevTools WebSocket 连不上**：CEF 默认拒绝带 Origin 的连接，加 `--remote-allow-origins=*` 放行；ws 获取改实时 `/json` 按 URL 匹配当前页签（CDP targetId 陈旧/误配导致 WebSocket 连不上）。
- **浏览器面板**：浅色外观页签背景调浅；DevTools 关闭闪退（窗口关闭拦截缺失）。
- **i18n**：语言切换后刷新各面板头部操作按钮与活动栏 tooltip（此前只重建菜单，tooltip 停留旧语言）；补 `terminal.closePanel` 文案、浏览器面板标题跟随语言切换；活动栏 tooltip 恢复系统语言切换（bar.preview 文案改为 文件/Files）。
- **IssueRunner 面板**：issue 关闭后标记实际状态 closed 并适配操作按钮。
- **dsh web 自拉起**：加 `--no-open`，避免默认浏览器被自动打开。
- **发布/CI**：`$VER` 统一加花括号 `${VER}` 修复 UTF-8 locale 下 unbound variable；local-ci.sh swift 阶段补齐 browser 面板测试与 CEF 编译。

### Docs

- `docs/fixes/devtools-drag-fix.md`：DevTools 拖动条导致 CEF 视图上移问题分析与修复方案。
- `docs/plans/BROWSER_PLAN-browser-panel.md`：浏览器面板设计（含 CEF 五 helper 根因修正）。
- wiki 同步：浏览器面板 OSR/Chromium 演进、五面板结构、发布/CI 工具链、per-arch 缓存。
- 合并规范：PR 合并一律用 `--no-ff`（merge commit）。

## [1.10.0] - 2026-08-18

### Added

- **系统优先 node 选择策略**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），内置 node 仅作兜底；`DSH_NODE` 显式覆盖仍无条件优先（无回退）。
- **About 面板显示实际 node**：显示实际运行 dsh web 的 node 版本与路径，合并为一行。
- **dsh web 环境合并登录 shell PATH**：App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；不再向 PATH 注入内置目录。
- **GitHub token 按仓库作用域**：解析优先级 Keychain 专属（`<owner>/<repo>`）→ `~/.dsh/tokens/<owner>-<repo>` → Keychain 通用 → `~/.dsh/gh-token`；多工作区各用各的 token（App 与外部工具/代理共用同一份）。
- **GitHub token 双写保存**：面板保存时 Keychain + `~/.dsh/tokens/<owner>-<repo>` 文件（chmod 600）双写，清空时双清。
- **GitHub token 文件优先读取**：token 读取改为文件优先（免 Keychain 密码提示），Keychain 写入设 `kSecAttrAccessibleAfterFirstUnlock` 免每次弹密码。
- **issue 处理按统一分支规范**：feature 类 issue 切 `feature/issue-N`，bug/其他切 `fix/issue-N`（按 label 判定）；issue-fix skill 分支说明同步。
- **issue-fix skill 自动安装**：任务开始时 `ensureIssueFixSkillInstalled` 写入 `<repoRoot>/.dsh/skills/issue-fix/`（内嵌副本与仓库字节一致、幂等），全新工作区也能处理 issue。
- **`scripts/git-remote.sh`**：push 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。
- **文档**：`docs/process/git-workflow.md`（统一分支与发布规范：main 只合并/只打主版本，feature/fix/release 分支模型，patch 版本同步回 main 走 PR）；AGENTS.md 补充分支提交强制规范与 GitHub token 位置；`.dsh/wiki` 知识库同步刷新。

### Changed

- **Node 选择策略反转（系统优先、内置兜底，含版本门槛）**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），但**低于版本门槛（默认 22.0.0，`DSH_NODE_MIN` 可覆盖）的系统 node 会被跳过**——dsh rc.6 实际需要 Node ≥ 22（`node:zlib` 的 zstd ESM 导出、`Promise.withResolvers`、`node:module.stripTypeScriptTypes`，Node 20 全部缺失，实测 v20 启动 dsh web 会崩在插件树加载）；仅当系统 node 缺失/过旧、或用它启动 dsh web 失败时才回退内置 node；`DSH_NODE` 显式覆盖仍无条件优先（无回退）；启动轮询增加 1s 沉降校验，避免"引导页含 `__DSH_BOOT__` 但随后崩溃"的假就绪。
- **dsh web 环境不做 PATH 注入，但合并登录 shell PATH**：移除启动与升级路径的内置目录 PATH 置顶；App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；About 面板的 Node 版本显示实际运行 dsh web 的 node。
- **CI action 升级**（dependabot）：`actions/upload-artifact` 4→7、`actions/setup-node` 4→7、`actions/cache` 4→6、`actions/download-artifact` 4→8。
- **版本 fallback 推进到 1.10.0**（v1.9.0 发布后的开发线版本）。

### Fixed

- **Tasks 面板跟随工作区切换**：dshSession 切换时无条件触发 `tasksPanel.workspaceChanged()`（不再依赖 ProjectDirectory 变化）；切换顺序修正为先 `ProjectDirectory.set` 再触发；`workspacePath` 非空时严格按当前会话判断（GitHub 仓库→显示 issues，非 GitHub→诚实显示 not a GitHub repo，不再 fallback 到其他 workspace），仅启动早期 ProjectDirectory 未解析时才用 `workspace.list` 兜底；Ungrouped 会话切回也能正确识别。
- **token 读取文件优先**（免 Keychain 密码提示）：顺序为文件专属 → 文件通用 → Keychain 专属 → Keychain 通用；配置框文案更正为按仓库双写（`~/.dsh/tokens/<owner>-<repo>`），配置按钮图标改齿轮。
- **壳层内嵌 repo-wiki skillMarkdown 同步**：补规则 8 提交指令（与仓库 SKILL.md 字节一致），修复 `ensureInstalled` 每次用旧内嵌版覆盖仓库文件导致提交规则丢失。
- **nvm 解析**：系统 node 解析 honor nvm default alias、prefer nvm current（最后一次 `nvm use`）。
- **git remote 名检测**：`git push` 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。

## [1.9.0] - 2026-08-16

### Added

- **IssueRunner 任务面板**（活动栏「任务 / Tasks」、⌥⌘J）：GitHub issue 驱动的串行任务流水线——
  - 仓库自动识别（git remote）+ open issues 拉取（REST，过滤 PR；私有仓库 Keychain token）；
  - 处理流程：切分支 `fix/issue-N` → 新建 dsh 会话（归主工作区）→ 会话改名可追溯 → issue-fix skill 修复 → 推送 → 开 PR；
  - 串行队列、行内展开详情（状态/标签/分支/PR/正文，滚动区 + 底部按钮）、取消/重试/打开 PR；
  - 完成后的 issue 支持「评论并关闭」（用户触发，POST comment + PATCH close）；
  - 任务关联索引落地 `.dsh/tasks/`（index.json 随仓库提交，local.json 本机 session 映射），重启可恢复；
  - 共享核心：`core/lib/issues.js`（issues/PR/comment-close/remote 检测）、`core/lib/jobqueue.js`（串行队列）、`core/lib/tasks.js`（关联索引）；
  - skill：`.dsh/skills/issue-fix/SKILL.md`。
- **Wiki 自动提交**：更新完成后由代理（repo-wiki skill 规则 8）`git add .dsh/wiki` + commit（不 push，message 概括实际变更）；面板 `WikiAutoCommit` 兜底。

### Changed

- 版本单一来源：`scripts/version.sh` fallback 推进到 1.9.0（发布后立即推进开发线版本，避免与已发布版本混淆）。

### Fixed

- IssueRunner：仓库识别兜底（workspace.list 解析）、gitBranchPushed 按 remote 名解析、恢复任务标题/正文显示、行内详情滚动与按钮固定。

## [1.8.0] - 2026-08-15

### Added

- 里程碑 M1（产品化基础，P1）全部交付（详见本里程碑文档 `docs/milestones/M1-productization-foundation.md`）：
  - 开源就绪：MIT LICENSE、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、CODEOWNERS、AGENTS.md、Issue 模板（bug/feature）；
  - CI：`.github/workflows/ci.yml`（macOS arm64/x64/Universal 矩阵 + 单测 + swiftc 编译检查 + `.cache/` 缓存）、`nightly.yml`、dependabot；
  - 发布：`.github/workflows/release.yml`（tag 触发 → 构建 → `.dmg`/`.pkg` + SHA-256SUMS → GitHub Release）；
  - 版本单一来源：`build-app.sh` 的 VERSION/BUILD 由 git tag / CI 运行号驱动（`scripts/version.sh`）；
  - 共享核心 `core/`（Node 模块）：ANSI 模拟器（42 用例全绿）/ 端口与服务管理 / 升级 / 会话 RPC 从 Swift 抽出，`core/bin/ohmy-core.js` CLI；
  - 设置窗口（语言 / registry / 升级 / 主题 / 快捷键，⌘, 打开）与首次引导（onboarding）；
  - 平台骨架 `platforms/macos/` 迁移（src/ + build-app.sh + make-pkg.sh，git mv 保留历史）。

### Changed

- `build-app.sh` 支持 `DSH_ARCH=arm64|x86_64|universal` 交叉构建（swiftc `-target` + universal lipo）。

### Fixed

- 构建脚本 `TMPDIR` 在清理 `.build` 后未重建导致 swiftc 失败的隐患。

## [1.7.1] - 2026-08-15

### Added

- Repo Wiki 知识库面板：生成/维护/浏览 + 多工作区跟随（`feat(wiki)`）；
- `docs/research/productization.md` 产品化方案与里程碑目标文档；
- 知识库增量更新流程与 `.dsh/wiki/` 结构。

### Fixed

- 终端多字节输入乱码（`docs/fixes/terminal-input-fix.md`：`Darwin.write` 传数组缓冲区必须用
  `withUnsafeBytes`）；
- 终端/Wiki 面板 header 合成溢出（`docs/fixes/terminal-header-fix.md`：父容器 `wantsLayer` +
  `masksToBounds`）。

## [1.6.28] - 2026-08-14

### Added

- 原生 macOS 壳首个可分发版本（`b4bceba`）：自包含运行时（内置 Node + dsh）、
  端口探测/复用/自拉起、预览面板、集成终端面板（PTY + ANSI 模拟器）、中英双语、
  dsh 手动/自动升级、registry 配置、退出清理。

---

[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html