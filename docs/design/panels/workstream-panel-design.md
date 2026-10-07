# 事项面板设计（Workstream Panel · 全新独立面板）

> 状态：**已落地**（2026-10-06 实现落地；2026-10-07 交付接线与文档同步收口）· 日期：2026-10-07
> 关联（上游模型）：`docs/research/ai-native-workflow-architecture.md`（§2 / §3.1 / §4 / §7 原则 5 / §9 Q2·Q11）、`.dsh/ai-native-workflow-spec.md`（R1 / R5 / R6 / R10 / R12）
> 关联（存储 / 面板体例）：`docs/design/panels/requirements-workstream-store-design.md`（REQ/WS/REG schema、Phase A/B 写权）、`docs/design/panels/requirements-pool-panel-design.md`、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/design/panels/planning-template-design.md`、`docs/design/panels/task-completion-verification-design.md`
> 参考（交互样板，**不复用其代码**）：`docs/design/panels/issue-runner-design.md`、`docs/design/panels/tasks-queue-session-loop-design.md`
> 讨论来源：2026-10-06 会话（需求池面板完成后的方案复审：各阶段是否收敛到任务面板下）
> 修订（2026-10-06 二次）：队列粒度定为**一事项一队列**；任务**直连事项 + 阶段**；启动分**事项级 / 阶段级**；任务运行态回写事项 / 阶段；执行阶段走**自有 runner**，`workstream-panel` 技能可发起各阶段任务。见 §2 A3·A9·A12–A14 / §3 / §4 / §5 / §6 / §9 D16–D19 / §10。
> 修订（2026-10-07）：补**焦点（A15）+ 主场会话（A16）**模型与**切换矩阵**——面板 ↔ 对话的双向切换由 `focus`（注意力单向往面板）与 `workstreamSessions`（每事项至多一条绑定会话）两条通道承载。见 §2 A15·A16 / §5 / §6.1 / §10。
> 修订（2026-10-07 三次）：把「推进一张事项卡」的三件事固化成 **§5.1**——**拆分任务 = 会话提示词（按首个未处理阶段）**、**确认 = 阶段上的人工门**、**启动 = 阶段上的「启动阶段」或技能 `queue/start`**；A3 / A14 / D19 与 §4 / §5 / §6 同步交叉明确；补「默认只展开首个未处理事项」规则。
> 修订（2026-10-07 四次）：**启动收口**——阶段卡去掉「启动阶段」按钮（`onStartStage` / `startStage` 入口连同 `workstreams.stage.start` L10n 移除），**事项卡「启动事项」成为面板唯一启动入口**；事项级启动的 runner 改为按**阶段 canonical 顺序**（规划 → 设计 → 执行 → 验收 → 交付，同阶段内按入队序）取任务，不再纯按队列插入序。
> 修订（2026-10-07 六次）：**队列 id 展示位置修正**——WS.queues 的队列 id 由「挂在当前阶段卡」改为**只以中性徽标出现在事项主卡标题行**：WSStageCardModel 去掉 queueIDs（连带 hasQueue），WSCardModel 新增 queueIDs。修复拆分后队列 id 落到「规划」等阶段二级卡的 bug；阶段卡任何情况下都不显示队列 id。见 §2 A9 / §9 D16 / §5.1。
> 修订（2026-10-07 五次）：**入口收口为「事项主卡唯一入口」**——**启动**只在事项主卡（`queue/start` 不带 `stage`，按阶段 canonical 顺序）、**创建任务**只在事项主卡（**表单抽屉选阶段** + 首行标题·其余内容，提交即 `task/create`）、**拆分任务**只在事项主卡（发**提示词**）、**确认**在**各阶段卡**（人工门）。阶段卡不再有「启动阶段」「＋创建任务」；A3 / A14 / D19 与 §5.1 交叉明确，§5.1 补**入口唯一性**与**阶段卡按钮清单**；`workstream-handoff-prompt-design.md` 补**创建任务抽屉 ↔ `task/create`** 关系；`workstream-panel` 技能入口表补「对话里创建任务」。
> 修订（2026-10-07 七次）：**确认 / 退回开放为「用户明确授权下的会话调用」**——`workstream-panel` 技能由 `user-invocable: false` 改为**可被用户直接调用**（如 `/workstream-panel 确认规划 WS-xxx`）；`stage/confirm`（确认推进）/ `stage/reject`（退回）**仅当用户在本会话明确发出确认 / 退回意图**时可由 agent 调用，confirm 前必须**复述证据 / 结论并请求确认**，reject 必须拿到**人的原因**，agent **不得自行确认、不得主动代签**；409 `evidence-missing` / `stage-changed` 仍为硬门、**不得重试硬推**。见 A14 / §5.1 / §10。
> 修订（2026-10-07 八次）：**阶段确认 / 退回留下来源标记**——R10 从「只能面板点」明确为「**面板点按 或 会话明确授权**；签字仍是人」。`WSStageGate` 新增 `WSStageSource`（`.panel` / `.session(id)`），确认 / 退回在卡片 `## 阶段确认` 写 `source:panel` / `source:session <id>`：面板按钮记 `panel`，API 调用按 `session` 派生（无 `session` 的直连 API 视为直接 / 面板来源）；旧记录无标记仍可读（`source` 为 nil）。见 §5 / §5.1 / §10。

## 0. 这份文档是什么

- **是什么**：从「任务面板升格」的复审出发，最终定形的**事项面板产品设计**——实体层级、阶段到队列的映射、生命周期与人工确认门、与既有面板/架构的关系，以及**决策清单**（§9）。
- **不是什么**：不是实现方案（无字段级 API / 类图 / 文件清单），不含排期；待确认项裁决后才进入实现设计与拆解。
- **怎么用**：先读 §2–§5 的定型模型；§9 记录 2026-10-06 的裁决结果与仍待细化的细项。本设计已全部落地（实现清单见 §10）：阶段队列引擎已接线面板并可事项级 / 阶段级启动；阶段提示词与 `workstream-panel` 技能已改指自有 API；`covered` / `delivery` 写路由与交付接线已完成。

## 1. 背景：为什么不是「让任务面板覆盖各阶段」

2026-10-06 复审（需求池面板已实现）提出的问题是：事项的后续各阶段（规划 / 设计 / 执行 / 验收 / 交付）能否都落到任务面板下（更名 + 能力提升）。

讨论结论（**否决「改造任务面板」，改为「新建独立面板」**）：

1. 任务面板的根实体是**队列**，数据在 `.dsh/tasks/*`（ignored）、绑定 runner 与 issue 驱动；让一个队列中心面板承载事项的各阶段，会把「事项 vs 队列」两层实体搅在一起，并牵动大量成熟且高风险的任务面板代码。
2. 需求池面板已经证明了正确范式：**一个面板服务一类实体**（需求池 → REQ），事项作为子视图挂进去。下一层应当对称：**事项面板 → WS**。
3. 因此定调：**事项面板是全新的第 11 个面板，clean-room 独立实现**；任务面板保持完全独立可用，不做任何改动、也不复用其代码。

## 2. 已定决策

| # | 决策 | 说明 |
|---|---|---|
| A1 | **全新独立面板** | clean-room：不 import / 不调用 / 不继承任务面板任何代码。任务面板保持独立可用。 |
| A2 | **三级卡片模型** | 事项为主卡片，阶段（规划/设计/执行/验收/交付）为二级卡片，任务为三级卡片。 |
| A3 | **启动 = 事项卡「启动事项」（面板唯一入口）** | 一个事项一条自有队列；面板只保留事项级启动（`POST /api/workstreams/queue/start` 不带 `stage`）= 按**阶段 canonical 顺序**（规划 → 设计 → 执行 → 验收 → 交付，同阶段内按入队序）跑完整条队列；技能仍可带 `stage` 做阶段级启动（只跑该阶段、跑完自动暂停）。启动**不改 `stage`**、不等于阶段完成；用事项面板自有队列引擎，不调用任务面板。**阶段卡不再有启动入口；同理「创建任务」也只在事项主卡（抽屉选阶段）**——两者互不替代，见 §5.1 的入口唯一性与阶段卡按钮清单。 |
| A4 | **阶段完成须过人工确认门** | 阶段队列 `.done` **不等于**阶段完成；须人确认才推进 `stage`（R10）。 |
| A5 | **面板是 `WS-*.md` 的唯一写者（Phase B）** | 落地写权反转；agent 不再直写 WS 卡，改走事项面板 API（落地时点见 §9 D5b）。 |
| A6 | **视图基件复制 + 重命名，不共享** | 从 `TaskCardView` / `TaskInlineForms` 复制为事项面板自有视图文件（如 `WSCardView` / `WSInlineForms`），不引用源文件。 |
| A7 | **worktree 隔离本轮不做** | 事项面板与任务面板共用工作树的风险，由 A8 消除；worktree 后续再评估。 |
| A8 | **任务面板本次不退场** | 代码 / 数据 / API 全部保留；待事项面板可用后，**隐藏入口的同时停止其 runner**（不实例化 / 不启动其定时器，空闲时执行）。「隐藏 + 停 runner」不修改任务面板代码，属接线层动作。 |
| A9 | **一事项一队列，关联入 WS 卡** | `WS.queues` 回落为 `[q-...]`（committed，**0..1**）；阶段不再挂在队列上，而是挂在任务上。见裁决 D1 / D16。 |
| A10 | **执行逻辑复制 + 改造** | 任务面板的执行逻辑（runner / 会话 / 完成校验 / 交付 git·PR·token）**复制 + 重命名**到事项面板，再按「事项 / 阶段」语义改造；不共享源码、不重写。见裁决 D10。 |
| A11 | **面板入口位置** | 活动栏槽位**紧邻「需求池」之后**；名「事项」（Workstreams）。快捷键等细节后定。见裁决 D14。 |
| A12 | **任务直连事项 + 阶段** | 任务除 `queueId` 外，直接带 `workstreamId` + `stage`；阶段是任务的属性，阶段视图按它对任务分组。见裁决 D17。 |
| A13 | **运行态回写，权威 stage 仍人门** | 任务状态 → 阶段运行态 → 事项运行态（派生、自动）；权威 `stage` 推进仍由人工确认门（R10）。见裁决 D18。 |
| A14 | **技能可在对话中发起拆分 / 创建任务 / 启动，并在用户明确授权下代发确认 / 退回** | `workstream-panel` 技能：**拆分** = `POST /api/workstreams/task/create`（按阶段建**等待态**任务，只建不启动）、**创建任务** = 同一条 `task/create`（面板侧由主卡「创建任务」抽屉选阶段发起），**启动** = `POST /api/workstreams/queue/start`（带 `stage` = 阶段级、不带 = 事项级）；**确认 / 退回** = `stage/confirm` / `stage/reject`，**仅在用户于本会话明确发出确认 / 退回意图时**才可调，且 confirm 先复述证据并请求确认、reject 必须拿到人的原因，agent 不自签。技能已改为**可被用户直接调用**（如 `/workstream-panel 确认规划 WS-xxx`）。见裁决 D19 / §5.1。 |
| A15 | **焦点通道（注意力单向往面板）** | 任何 `/api/workstreams/*` 可带 `focus`（写请求 body / 读请求 `?focus=`），仅 HTTP 200 触发：面板置前 + 高亮 + 滚动到可见；目标被阶段筛选隐藏时回落「全部」；默认 `false` 不抢右栏。见 §6.1。 |
| A16 | **主场会话（每事项至多一条绑定会话）** | `.dsh/workstreams/local.json` 的 `workstreamSessions`（WS-id → sessionId，ignored，last-writer-wins）；面板「拆分任务」、需求拆解继承、对话内阶段推进都围绕它，`GET /api/workstreams/bound?session=` 反查。见 §6.1 / 裁决 D6。 |

## 3. 目标模型

### 3.1 实体层级

```text
事项面板（全新，第 11 个面板）
└─ 事项 WS     主卡片     .dsh/workstreams/WS-*.md（committed；面板为唯一写者）
   ├─ 队列     执行载体    一个事项一条队列（WS.queues 0..1；事项面板自有 runner）
   └─ 阶段     二级卡片    规划 / 设计 / 执行 / 验收 / 交付（视图：按任务的 stage 分组）
      └─ 任务  三级卡片    带 workstreamId + stage；每任务一条会话
```

### 3.2 与既有实体的关系

- **需求（REQ）**：事项可挂 0..1 需求（`WS.requirement`），需求池面板负责 REQ，事项面板负责 WS；
- **阶段（stage）**：是事项的**状态**，不是站点；允许回边、跳过、停驻（架构 R1–R4）；
- **队列**：**该事项的执行载体（1 事项 : 1 队列）**，由事项面板自有 runner 推进；阶段不拥有队列，阶段是任务的 `stage` 标签；
- **任务（三级）**：队列成员，**直接关联事项（`workstreamId`）+ 阶段（`stage`）**，每任务一条会话；阶段视图 = 该事项队列里同 `stage` 的任务集合。

## 4. 阶段 → 载体映射

| 阶段 | 任务（三级） | 队内任务实质 | 完成证据（阶段级，非任务级） |
|---|---|---|---|
| **规划** | ✅ 可多个 | agent 出「四件套」草案（目标 / 边界 / 验收标准 / 阶段裁剪声明） | 四件套齐 + 人确认（planning-template-design） |
| **设计** | ✅ 可多个 | agent 出设计文档 + 待确认问题（Q 表）草案 | 设计文档 + Q 已拍板 + 人确认 |
| **执行** | ✅ 可多个 | 改代码 / 跑测试 / commit（现有语义） | 任务级证据（marker / 产物）+ 人确认 |
| **验收** | ⚠️ 可选 | 跑测试 / 收集证据 | **人 sign-off**（主干不是队列；D4） |
| **交付** | ✅ 可多个 | 收尾会话：push / PR / merge（逻辑**复制**自任务面板，见 A10） | PR outcome 派生 + 人确认 |

> 五个阶段的全部任务**共用该事项的同一条队列**；阶段不建独立队列，`stage` 是任务的属性。

> 命名：阶段名建议固定为 **规划 / 设计 / 执行 / 验收 / 交付**（用「执行」而非「任务」，避免与三级卡片「任务」撞名）。

> **三件事的阶段分工（动作语义见 §5.1）**：一个阶段的任务来自**拆分任务**（**会话提示词**，按**首个未处理阶段**选阶段），完成由**确认**（**阶段上的人工门**）拍板，实施由**启动**（**事项卡「启动事项」** / 技能 `queue/start`）起跑——三者互不替代。

## 5. 生命周期与人工确认门

```text
事项（主卡）
  │ 进入阶段
  ▼
事项队列（一个事项一条） ── runner 按顺序执行 ──► 该阶段任务全部结束
                                                    │  队列 / 阶段完成 ≠ 阶段完成
                                                    ▼
                                                阶段「待确认」（停驻态，R4）
                                                    │ 人 Review
                                        ┌───────────┴───────────┐
                                     确认通过                  退回（回边，留痕）
                                        ▼                        ▼
                                  推进下一阶段             回到本阶段返工
```

- **启动粒度**：**事项级**（跑该事项队列，可按当前阶段）/ **阶段级**（只跑该阶段的任务）；两者都只是「启动」，**不替人确认**（R10）。
- **运行态自动回写**：任务状态 → 阶段运行态（未开始 / 进行中 / 待确认 / 完成 / 阻塞）→ 事项运行态；**权威 `stage` 仍由人工确认门推进**（A13）。
- **对话内阶段推进**：人确认某阶段、`stage` 真的前移后，面板把**下一阶段**交接提示词发给该事项绑定的**主场会话**（`.dsh/workstreams/local.json` 的 `workstreamSessions`）；**无绑定会话则不发**（不凭空起会话），**交付是终态**、确认不前移，不续发。
- 回边合法且必须留痕（R2）；裁剪（跳过阶段）必须在**规划**声明（R3）。
- **签字来源可追溯（R10）**：确认 / 退回在 `## 阶段确认` 记录本次来源——`source:panel`（面板点按）或 `source:session <id>`（会话在用户明确授权后代发）；**签字始终是人**，agent 只在授权下代发、绝不自签。
- 阶段证据谓词各阶段不同（§4），不能统一套用任务级 marker（见 §9 D3）。

### 5.1 三件事：拆分任务 / 确认 / 启动（UX 语义）

同一张事项卡上的「推进」被拆成**三件互不替代的事**，各自有明确的入口、落点与责任人：

| 动作 | 是什么 | 入口（面板 / 技能） | 落到哪 | 谁做 |
|---|---|---|---|---|
| **拆分任务** | **会话提示词**（不是队列操作、不落盘）：按**首个未处理阶段**（`wsFirstUnprocessedStage` = canonical 顺序里第一个 `runState != 完成` 的阶段，A13 派生态）生成拆分提示词 | 主卡「**拆分任务**」按钮；技能 `POST /api/workstreams/task/create` | 提示词（`WorkstreamHandoff.splitPrompt`）发进该事项**主场会话**；agent 据此 `task/create` 建**等待态**、带该 `stage` 的任务 | 人点按钮 → 会话里的 agent 执行 |
| **确认** | **阶段上的人工门**（R10）：机检证据 AND 人确认才前移 `stage` | 阶段卡「**确认并推进 / 退回本阶段返工**」；技能 `POST /api/workstreams/stage/confirm` / `stage/reject`（**用户明确授权时**） | 卡片 `stage` 前移 / 回边，`## 阶段确认` 留痕 + **来源标记**（`source:panel` / `source:session <id>`，committed） | **人**；用户明确授权时 agent 可代发（confirm 先复述证据、reject 拿人的原因），**不自签** |
| **启动** | **事项卡「启动事项」**（面板唯一入口）；技能仍可带 `stage` 做阶段级 | 主卡「**启动事项**」；技能 `POST /api/workstreams/queue/start` | 不带 `stage` = 按**阶段 canonical 顺序**（同阶段内入队序）跑完整条队列；带 `stage` = 只跑该阶段、跑完自动暂停（`queues.json`，ignored） | 人 / 人确认后 agent |

- **拆分 ≠ 启动**：`task/create` 只建**等待态**任务；**建完停下等人确认拆分**，人确认后才 `queue/start` 起跑。
- **确认 ≠ 启动**：确认回答「这个阶段做完没有」（前移 `stage`，并触发下一阶段提示词，见 §5 / §6.1）；启动回答「把任务跑起来」（**不改 `stage`**）。二者可以先后发生，但不能互相替代。
- **技能入口语境**：对话里说「把这个事项拆成任务」→ `task/create`（等待态，停在等人）；说「启动这个阶段 / 启动这个事项」→ `queue/start`（阶段级 / 事项级）；说「确认 / 退回这个阶段」→ 人工门，**仅当用户在本会话明确授权**时 agent 才调 `stage/confirm` / `stage/reject`（confirm 先复述证据并请求确认、reject 必须拿到人的原因）；未获授权时请人去面板点。409 `evidence-missing` / `stage-changed` **不得重试硬推**。
- **面板直建任务（UX，2026-10-07）**：事项主卡「**创建任务**」打开 `WSInlineForms` 表单抽屉——**阶段选择器**（五阶段，默认该事项**首个未处理阶段**，与「拆分任务」同源 A13 派生态）+ **一个输入框**（首行 = 标题，其余行 = 内容）。⌘↩ 提交、Esc 取消、标题为空时禁用提交。提交走与 agent **同一条 `task/create` 路径**：注入该阶段交接提示词（面板输入的内容附在提示词之后），建**等待态**任务、追加到该事项唯一队列、**不启动**。阶段二级卡的「＋创建任务」按钮已移除（创建入口收口到主卡）。

**入口唯一性（2026-10-07 固化）**：

| 事 | 唯一入口 | 落点 | 阶段卡 |
|---|---|---|---|
| **拆分任务** | 主卡「拆分任务」按钮（技能 = 会话里的拆解指令） | 拆分**提示词**发进主场会话 | 无 |
| **创建任务** | 主卡「创建任务」按钮（**抽屉选阶段**） | `task/create`：等待态任务 + `stage` | 无 |
| **启动** | 主卡「启动事项」按钮（技能 = `queue/start` 带 `stage` 做阶段级） | 跑队列；**不改 `stage`** | 无 |
| **确认** | **各阶段卡**「确认并推进 / 退回本阶段返工」 | `stage` 前移 / 回边 + `## 阶段确认` 留痕 | **就在这里** |

**阶段卡按钮清单（收口后）**：阶段二级卡只保留——① **待确认阶段**的「**确认并推进**」「**退回本阶段返工**」（`awaitingConfirmation` 时才出现）；② **交付阶段**的「**交付**」。阶段卡**没有**「启动阶段」「＋创建任务」，也没有「拆分任务」；其余是只读徽标（`当前阶段` / 运行态 / 验收 `covered` / 交付 `pr·outcome`）。

**默认展开首个未处理事项**（UX）：面板**加载 / 重绘**只展开**首个 `runState != 完成` 的事项卡**（`wsDefaultExpandedID` / `wsApplyingDefaultExpansion`，在 `WSBoardModel.build` 每次构建时应用；阶段筛选后的可见列表内取首个），其余收起，**全部完成不展开任何卡**。「拆分任务」的目标阶段同样取**首个未处理阶段**——两处都以 A13 派生态为准，不碰权威 `stage`。

## 6. 数据与存储（落点已按 §9 裁决）

| 数据 | 落点（初步） | committed / ignored |
|---|---|---|
| 事项卡（`stage`、各阶段段落） | `.dsh/workstreams/WS-*.md` | committed |
| 事项 ↔ 队列关联 | `WS.queues` = `[q-...]`（**0..1**，一事项一队列；裁决 D1 / D16） | committed |
| 三级任务（带 `workstreamId` + `stage`） | 事项面板自有文件，如 `.dsh/workstreams/queues.json`；**不得触碰 `.dsh/tasks/*`**（裁决 D8） | ignored |
| 事项 / 任务运行时绑定（会话 id 等） | `.dsh/workstreams/local.json`（沿用存储设计约定）：任务 → 会话 `sessions`，**事项 → 会话 `workstreamSessions`（WS-id → sessionId，可反查）** | ignored |
| 交付事实 / outcome 派生缓存 | WS 卡 `delivery` 块（沿用 schema） | committed（缓存）/ 派生 |

**硬约束**：事项面板不得读写 `.dsh/tasks/*`；不得依赖 `/api/tasks/*`。

**三件事的落点（对应 §5.1）**：**拆分**是对话里的一次**提示词**（不落盘；产物是 `queues.json` 里的**等待态**任务）；**确认**写**卡片**（`stage` + `## 阶段确认`，committed）；**启动**改**队列运行态**（`queues.json`，ignored）。

### 6.1 焦点 + 主场会话模型（A15 / A16）与切换矩阵

面板与对话之间的「互相找到」由两条**正交**的通道承载：

- **焦点（A15，注意力单向往面板）**：任何 `/api/workstreams/*` 请求可带 `focus`（写请求放 body，读请求放 `?focus=`，接受 `true` / `1` / `yes` / `on`）；**仅当请求被处理（HTTP 200）时**，面板置前（`setRightPanel(.workstreams)`）+ 给目标卡**强调色描边** + 滚动到可见。**默认 `false`**——普通 agent 写卡不抢用户的右栏。高亮目标：写路由取请求里的 `id`；`create` 取响应里新卡的 id；`bound` 取响应里**第一张绑定卡**；其余读路由只置前（无 id）。目标被当前**阶段筛选**隐藏时，筛选自动回落「全部」，保证高亮可见；切换工作区清空焦点。
- **主场会话（A16，对话 ↔ 面板的会话绑定）**：每个事项至多一条**绑定会话**（`.dsh/workstreams/local.json` 的 `workstreamSessions`，WS-id → sessionId，**ignored**）。写请求带 `session` 时把该事项的主场会话记成这次会话，**后写覆盖先写**（last-writer-wins，单一槽位，是运行时绑定不是永久契约）。`GET /api/workstreams/bound?session=` 反向查「本会话绑定的事项」。面板「拆分任务」、需求拆解继承、对话内阶段推进都读它。
  - 因此**只有真正在推进该事项的对话才应带 `session`**；阶段 runner / 临时会话写完就消失，带上会把主场会话覆盖成一条死会话（技能正文对此有显式警示）。

**切换矩阵**（面向用户的简表见 [`docs/usage/panels.md`](../../usage/panels.md)）：

| 方向 | 触发 | 目标 / 动作 | 回退 / 边界 |
|---|---|---|---|
| 对话 → 面板 | 技能 `GET /bound?session=…&focus=true` | 面板置前 + 高亮反查到的第一张卡 | 未绑定 / 无工作区 → 只返回空列表，不聚焦 |
| 需求池 → 面板 | 已拆解事项主 `↗` | `setRightPanel(.workstreams)` + `focus(WS-id)` | WS 卡缺失 → 次级按钮打开卡文件 |
| 面板内聚焦 | `focus` 命中的卡被阶段筛选隐藏 | 筛选回落「全部」再高亮 + 滚动 | 目标 id 不存在 / 空白 → 不聚焦 |
| 面板 → 对话 | 主卡「拆分任务」 | 解析首个未处理阶段，把该阶段的拆分提示词 `sendPrompt` 进绑定主场会话 | 坏 / 无绑定 → 新建并绑定；再失败 → 回退当前会话；全部完成 → 无可拆分阶段 |
| 阶段确认 → 对话 | 人在面板确认或 `POST stage/confirm` | 向绑定主场会话发**下一阶段**交接提示词 | 无绑定 → 不发（不凭空起会话）；delivery 终态 → 不续发 |
| 需求池确认 → 对话 | `RequirementsCore.confirm` | 新 WS 继承需求的绑定会话（写 `workstreamSessions`） | 需求无绑定 → 不发明；显式 `session` 优先 |

> 实现落点：焦点 `WorkstreamsUI.WSFocusTarget` + `WorkstreamsAPI.route` 的 `focusID` / `apiWorkstreamsFocus`；主场会话 `WorkstreamsCore.boundSession` / `boundWorkstream` / `sessionTarget` + `WorkstreamsQueues.WSStore`。两条通道都只读**权威卡片**（焦点目标、阶段）与运行时绑定（会话），不复述卡片状态。

## 7. 与既有架构的分歧及已修订点

本方案与现行 `ai-native-workflow-architecture.md` 存在**正面分歧**；下表四处的修订**已于 2026-10-06 完成**：

| # | 现文档 | 本方案 | 处理 |
|---|---|---|---|
| 1 | 原则 5：**一个面板服务一个阶段** | 一个面板服务一类实体（事项），**阶段是面板内视图** | 修订原则 5 / R1 措辞 |
| 2 | §4 各阶段工具表：规划 / 设计 / 验收「无面板，待立项」 | 收敛为事项面板的阶段视图 | 更新 §4 / §6 现状图 |
| 3 | §3.1 状态图未说明阶段的执行载体 | 阶段由**队列**承载；`.done` 须过确认门才推进 | §3.1 补一句 |
| 4 | §9 Q2（阶段状态权威）、Q11（面板分工） | 已裁决（见本文 §9 D1 / D5b / D6） | 定稿时回填架构文档 |

## 8. 范围外（只拆不胀）

| 候选 | 说明 |
|---|---|
| worktree 隔离 | A7 延后；后续独立事项 |
| 任务面板真正退役 + `.dsh/tasks/*` 数据迁移 | 本次仅「隐藏入口 + 停 runner」；迁移不属本期 |
| 交付结果网络派生（`delivery.outcome` 联网） | 仍由 `derive-status.mjs` 承担 |
| 事项面板跨工作区总览 | 归项目面板（架构 §4.7） |

## 9. 决策清单（2026-10-06 裁决）

| # | 问题 | 裁决 | 说明 |
|---|---|---|---|
| D1 | 阶段 ↔ 队列映射存哪 | **A**：扩展 `WS.queues` 为 `[{id, stage}]`（committed） | 需同步更新 `requirements-workstream-store-design.md` §3.2；运行时会话绑定仍在 `local.json` |
| D2 | 阶段完成 = 人工确认门 | 已定（A4） | — |
| D3 | 各阶段完成证据谓词 | **同意**：每阶段 = 机检谓词 AND 人工确认门 | 规划复用 planning-template §4；执行对齐 completion-verification P1–P5；验收=证据 + `covered` 锚变更；交付=PR 事实 + outcome 派生 |
| D4 | 验收是否建队列 | **A**：不建队列，纯人 sign-off（可选一个证据收集任务）；**必要时再迭代** | 贴合「验主人轻 agent」 |
| D5b | 写权反转的落地时点 | **A**：本期就做，含 `/api/workstreams/*` + 技能改造（**已落地**） | 面板成为 `WS-*.md` 唯一写者；agent 不再直写（技能 `workstream-panel`） |
| D6 | 三列表面板分工 | **同意（已落地 2026-10-07）** | 需求池=REQ 中心（子事项只读、`↗` 跳事项面板并聚焦该 WS）；事项面板=当前工作区 WS 中心；项目面板=跨工作区总览（后续）。防重：REQ 列表只在需求池 |
| D8 | 三级任务数据落点 | **A**：事项面板自有文件（如 `.dsh/workstreams/queues.json`，ignored） | **不得触碰 `.dsh/tasks/*`** |
| D14 | 命名 / 槽位 / 快捷键 | 活动栏槽位**紧邻「需求池」之后**；名「事项」（Workstreams） | 快捷键等细节待定 |
| D15 | 阶段提示词 | 以 `workstream-handoff-prompt-design.md` 为依据（**已落地**，`WorkstreamsPrompts.swift`） | 面板生成、注入任务 body；回归门行按卡片 `regression` 有无出现 |
| D16 | 队列粒度 | **A：一事项一队列** | 阶段不建独立队列；`WS.queues` = `[q-...]`（0..1） |
| D17 | 任务与事项 / 阶段的关联 | **直连** | 任务带 `workstreamId` + `stage`（+ `queueId`）；阶段视图按 `stage` 分组 |
| D18 | 启动与状态回写 | 事项级 / 阶段级启动；运行态回写 | 任务状态 → 阶段运行态 → 事项运行态（派生）；权威 `stage` 仍人门 |
| D19 | 执行阶段的引擎 | **事项面板自有 runner**；`workstream-panel` 技能可发起**拆分**（`task/create`，等待态）与**启动**（`queue/start`，可阶段级） | **不用 `/task-todo`（任务面板）**；三件事互不替代——**拆分 = 会话提示词（按首个未处理阶段）**、**确认 = 阶段上的人工门**、**启动 = 事项卡「启动事项」/ `queue/start`**（§5.1）；面板阶段卡已去掉启动按钮、也去掉「＋创建任务」按钮；事项级启动按阶段 canonical 顺序取任务，**创建任务**面板侧收口到主卡表单抽屉（选阶段 + 首行标题·其余内容，默认首个未处理阶段，提交即 `task/create`）；阶段卡只保留**确认 / 退回**（待确认时）与**交付**（交付阶段），按钮清单见 §5.1；提示词与技能已相应改指 |

### 9.1 细项（均已于 2026-10-06 落地）

- 面板快捷键：采纳 **`⌥⌘K`**（经查全源码无占用），活动栏槽位紧邻「需求池」之后；
- 各阶段提示词措辞：已落到 `WorkstreamsPrompts.swift`（`WorkstreamHandoff`）；
- `WS.queues` 回落后的读取兼容：`WorkstreamsCore` 兼容旧 `[{id, stage}]` 形式（取 id，阶段丢弃）；
- 阶段「待确认」的 UI 表达与退回原因：阶段卡「待确认」徽标 + 「确认 / 退回」（退回弹必填原因抽屉，对齐需求池驳回）。

### 9.2 已关闭项

| # | 项 | 结论 |
|---|---|---|
| D7 | worktree 隔离 | 本轮不做（A7） |
| D9 | 视图基件复用口径 | 复制 + 重命名（A6） |
| D13 | 共存期工作树守卫 | 关闭：任务面板隐藏时停 runner（A8） |
| D10 | 交付是否自研 | **并入 A10**：clean-room ≠ 重写，「独立」与「复制」正交，本问题不成立（详见 §9.3） |

### 9.3 一处澄清：clean-room 的两个轴

D10 之所以是伪问题，源于把两个正交的轴混为一谈：

| 轴 | 取值 | 落点 |
|---|---|---|
| **代码归属** | 独立 / 共享 | A1：**独立**（不 import / 不调用 / 不继承）；决定两个面板是否互相牵动 |
| **代码来源** | 复制 / 重写 | A6 / A10：**复制 + 重命名 + 改造**；决定一次性的实现成本 |

- 「独立」只要求**运行时不互相依赖**，不要求「从零重写」；
- 因此执行逻辑（runner / 会话 / 完成校验 / 交付 git·PR·token）**一律复制**，不存在「自研 vs 复制」的选择——D10 随之消失；
- 真正需要决策的不是来源，而是**复制后必须改造的适配点**：D1（阶段↔队列）、D3（阶段证据谓词）、D5b（写权反转）。

## 10. 下一步

1. 本文件已**定稿并落地**（2026-10-06）：上游文档已同步（见 §7），面板 / 模型 / API / 队列引擎 / 阶段门 / 交付 / 技能均已实现；
2. **已落地**：`WorkstreamsCore` / `WorkstreamsUI` / `WorkstreamsPanel` / `WorkstreamsAPI` / `WorkstreamsQueues`+`WorkstreamsRunner` / `WorkstreamsStageGate` / `WorkstreamsPrompts` / `WorkstreamsDelivery` / `WSCardView`+`WSInlineForms`，内置技能 `workstream-panel`；用户说明见 `docs/usage/panels.md` 与 `CHANGELOG.md`；**模型修订（A9 / A12）已落地**：`WS.queues` = `[q-...]`（0..1，兼容旧 `[{id, stage}]` 读入取 id），任务带 `workstreamId` + `stage`；
3. **接线进展**：
   - **已落地（2026-10-06）**：面板实例化并驱动 `WorkstreamsRunner`（3s `step()` 定时器、工作区切换重建、`serverPortProvider` 注入 dsh RPC）；`/api/workstreams/task/create` / `task/list` / `queue/start` / `queue/pause`；主卡「启动事项」+ 主卡「创建任务」抽屉（原阶段卡「＋创建任务」，UX 收口）；三级任务卡展示状态 / 会话；
   - **已落地**：一事项一队列——`createStageQueue` 追加到该事项的队列、任务带 `stage`；`queue/start` 带 `stage` = 阶段级启动（只跑该阶段任务，跑完暂停队列）；
   - **已落地（2026-10-06）**：任务运行态 → 阶段运行态 → 事项运行态回写（A13 / D18）——纯模型 `WorkstreamsRunState.swift`（`WSRunState.stage` / `WSRunState.workstream`）从**队列状态 + 任务状态**（外加 `## 阶段确认` 审计痕迹判回边）派生**未开始 / 进行中 / 待确认 / 完成 / 阻塞**，主卡与阶段卡显示徽标；**权威 `stage` 一字不改**（仍只由 `confirmStage` 推进）。阶段门读 runner 的实时板，而非磁盘快照；
   - **已落地（2026-10-07）**：阶段提示词去掉 `/task-todo`、改指事项面板自有 API（`task/create` / `queue/start`），技能 `workstream-panel` 同步；
   - **已落地（2026-10-07）**：`covered` / `delivery` 写路由（`POST /api/workstreams/covered` / `delivery`；`delivery.outcome` 是派生缓存，API 拒绝手写，报 `outcome-derived`）；交付接线——面板「交付」按钮用 `WorkstreamsDelivery.resolve` 收集 git / GitHub / token 事实，准入失败给明确原因（`not-delivery-stage` / `not-git-repo` / `no-branch` / `no-remote` / `no-github-remote` / `no-token`），成功则 `runner.enqueueDelivery` 建 delivery 阶段任务并只启动该阶段；
   - **已落地（2026-10-07）**：事项 ↔ 会话绑定——`local.json` 新增 `workstreamSessions`（ignored），任何 `/api/workstreams/*` 写请求带 `session` 时记忆、`list` 随带；反查路由 `GET /api/workstreams/bound?session=...`；主卡「**拆分任务**」（目标 = 首个未处理阶段）对齐需求池「细化」（复用绑定会话 / 新建并绑定 / 回退当前会话），由 `WorkstreamsCore.sessionTarget` 纯决策 + `WorkstreamsQueues` 持久化承载；
   - **已落地（2026-10-07）**：**focus 通道**——面板 `focus(onWorkstream:)` 给目标卡加强调色描边并滚动到可见，被阶段筛选隐藏时回落「全部」；`/api/workstreams/*` 统一支持 `focus`（写操作 body / 读操作 `?focus=`，仅 200 触发，默认 `false` 不抢面板），经 `WorkstreamsAPIDelegate.apiWorkstreamsFocus` → `BrowserAPIBridge.workstreamsFocus` 落到面板；需求池子事项主 `↗` 改走该通道（次级仍打开卡文件）。**对话内阶段推进（2026-10-07）**：人在面板确认某阶段、`stage` 前移后，面板按钮与 `POST /api/workstreams/stage/confirm` 两条确认路径共用 `continueToNextStage`，经 `onStageConfirmed` 把更新后的卡片交给 `main.swift`；后者读该事项的绑定主场会话，复用 `WorkstreamHandoff.nextStagePrompt` 发送下一阶段交接提示词（无绑定会话不发、交付终态不续发）。**至此 §10 无待办。**

   - **已落地（2026-10-07）**：**焦点 + 主场会话模型与切换矩阵**（A15 / A16，§6.1）——把散落在 A11/D6、§6 会话绑定与第 24 项「对话内阶段推进」里的行为收拢成两条正交通道：`focus` 单向把注意力带回面板，`workstreamSessions` 把事项绑到一条**主场会话**（last-writer-wins）；`workstream-panel` 技能同步**修正会话绑定的措辞**（不再承诺「绑回来就永久有效」，并警示临时会话不要覆盖主场会话）。测试：API 增加 `bound?focus` 高亮断言，skills 测试固化新措辞。
   - **已落地（2026-10-07）**：**默认展开首个未处理事项卡**（UX）——面板加载 / 重绘时只展开首个 `runState != 完成`（A13 派生态）的事项卡，其余收起，全部完成时不展开；纯谓词 `wsDefaultExpandedID` / `wsApplyingDefaultExpansion` 在 `WSBoardModel.build` 每次构建时应用，UI 测试（首个未处理 / 跳过已完成 / 全完成全收起）与源码守卫固化。
   - **已落地（2026-10-07）**：**「拆分任务」按钮（目标 = 首个未处理阶段，UX）**——主卡动作由旧的「在会话中处理」更名并改语义：解析首个 `runState != 完成` 的阶段（纯谓词 `wsFirstUnprocessedStage`），经 `WorkstreamHandoff.splitPrompt` 把该阶段的拆解提示词发进主场会话（复用 / 新建并绑定 / 回退当前会话沿用 A16 的 `sessionTarget`）；提示词点名事项 + 阶段，要求 `POST /api/workstreams/task/create` 建**等待态**、带该 `stage` 的任务，**建完停下等人确认、不自签、不启动**。阶段卡去掉重复的「在会话中处理」入口（后续 UX 又依次移除「＋创建任务」「启动阶段」，最终只保留确认 / 退回与交付）。prompt 测试覆盖各阶段拆分提示词与「执行阶段拆分 = 通用 (stage, action) 构造」。
   - **已落地（2026-10-07）**：**三件事固化进设计**——「**拆分任务 = 会话提示词（按首个未处理阶段）**」「**确认 = 阶段上的人工门**」「**启动 = 事项卡「启动事项」/ 技能 `queue/start`**」（该条为当时口径，随后「启动收口」把阶段卡启动按钮移除）写成 **§5.1**，并在 A3 / A14 / D19 与 §4 / §6 交叉明确；补「默认只展开首个未处理事项」规则。`workstream-handoff-prompt-design.md` 补拆分提示词定位与措辞；`workstream-panel` 技能补「对话中发起拆分 / 启动」入口与路由语境。
   - **已落地（2026-10-07）**：**启动收口 + 阶段 canonical 顺序（UX）**——阶段卡的「启动阶段」按钮与 `onStartStage` / `startStage` 入口移除（连 `workstreams.stage.start` / `started` L10n 删除），**事项卡「启动事项」成为面板唯一启动入口**；`WSBoard.nextStartable` / `firstQueued` 在事项级（`stage == nil`）改为按**阶段 canonical 顺序**（规划 → 设计 → 执行 → 验收 → 交付）再按入队序取任务，不再纯按 `taskIds` 插入序（阶段级 `stage` 过滤仍按入队序）。runner 测试覆盖「跨阶段交错建任务 → 按阶段顺序执行」与「同阶段内仍按入队顺序」；技能 / 用户说明同步。
    - **已落地（2026-10-07）**：**创建任务移到事项卡抽屉（UX）**——阶段卡的「＋创建任务」按钮与 `onCreateStageTask` / `workstreams.stage.createTask` 移除；主卡新增「创建任务」按钮，打开复用 `WSInlineForms` 的表单抽屉（`WSStageTaskComposerView` + `WSFormSheetHostView`）——**阶段选择器**（五阶段，默认 `wsFirstUnprocessedStage`）+ 一个输入框（首行 = 标题、其余行 = 内容，`WSStageTaskComposerModel`）。提交走同一 `createStageQueue` 路径（`WorkstreamHandoff.stageTask` 注入该阶段交接提示词，内容附后），建**等待态**任务、追加到事项唯一队列、**不启动**。UI 测试覆盖标题 / 内容拆分与默认阶段；提示词 / runner / 面板 / L10n 同步。
   - **已落地（2026-10-07）**：**设计 + 技能同步（启动唯一入口 / 创建任务抽屉）**——A3 / A14 / D19 与 §5.1 固化「**启动**只在事项主卡（按阶段 canonical 顺序）、**创建任务**只在事项主卡（抽屉选阶段）、**拆分任务**发提示词、**确认**在各阶段卡」，并给出**阶段卡按钮清单**（确认 / 退回 + 交付）；`workstream-handoff-prompt-design.md` 新增 §4.2「创建任务抽屉与 `task/create`」；`workstream-panel` 技能入口表补「对话里创建任务 → `task/create`」。本任务为**文档 / 技能同步**，`tests/workstreams-panel` 计数不变（**1070**）。
   - **已落地（2026-10-07）**：**队列 id 展示位置修正（UX）**——队列 id 从阶段二级卡移到事项主卡：`WSStageCardModel` 去掉 `queueIDs`（连带 `hasQueue`），`WSCardModel` 新增 `queueIDs`，主卡标题行以中性徽标（`WSTierBadgeView`，tone .neutral）渲染，阶段卡任何情况下都不显示（修复拆分后队列 id 落到「规划」二级卡）。UI 测试 + `run.sh`「队列 id 展示位置」源码守卫固化。
   - **已落地（2026-10-07）**：**阶段确认 / 退回开放为「用户明确授权下的会话调用」**——技能去掉 `user-invocable: false`（与 `requirement-pool` / `task-todo` 对齐，可 `/workstream-panel 确认规划 WS-xxx` 直接调用），并把「`stage/confirm` / `stage/reject` 绝不调用」改为**授权 + 证据**规则：仅当用户在本会话明确发出确认 / 退回意图时才能调；confirm 前先复述证据 / 结论并请求确认；reject 必须拿到人的原因；409 `evidence-missing` / `stage-changed` 不得重试硬推。技能新增「阶段确认 / 退回（人工门）」工作流与两条路由的请求体；内嵌副本字节一致；`tests/skills` 新增授权 / 路由断言。
   - **已落地（2026-10-07）**：**阶段确认 / 退回留下来源标记（R10）**——`WorkstreamsStageGate` 新增 `WSStageSource`（`.panel` / `.session(id)`，`marker` / `from(session:)` / `parse`），`WSStageHistoryEntry.source` 写进卡片行尾（` · source:panel` / ` · source:session <id>`），`parseHistory` 剥离标记且**旧记录无标记照常可读**，门 JSON 暴露 `source`；`confirmStage` / `rejectStage` 带 `source` 参数，面板按钮记 `.panel`、API 两条路由按 `request.session` 派生来源。stage-gate 测试 60 → **80**，`run.sh` 新增「阶段决策来源」源码守卫。文档：`.dsh/ai-native-workflow-spec.md` R10 / §5 与本文档同步。