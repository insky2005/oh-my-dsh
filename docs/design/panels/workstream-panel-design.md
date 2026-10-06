# 事项面板设计（Workstream Panel · 全新独立面板）

> 状态：**已落地**（2026-10-06 实现落地；2026-10-07 交付接线与文档同步收口）· 日期：2026-10-07
> 关联（上游模型）：`docs/research/ai-native-workflow-architecture.md`（§2 / §3.1 / §4 / §7 原则 5 / §9 Q2·Q11）、`.dsh/ai-native-workflow-spec.md`（R1 / R5 / R6 / R10 / R12）
> 关联（存储 / 面板体例）：`docs/design/panels/requirements-workstream-store-design.md`（REQ/WS/REG schema、Phase A/B 写权）、`docs/design/panels/requirements-pool-panel-design.md`、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/design/panels/planning-template-design.md`、`docs/design/panels/task-completion-verification-design.md`
> 参考（交互样板，**不复用其代码**）：`docs/design/panels/issue-runner-design.md`、`docs/design/panels/tasks-queue-session-loop-design.md`
> 讨论来源：2026-10-06 会话（需求池面板完成后的方案复审：各阶段是否收敛到任务面板下）
> 修订（2026-10-06 二次）：队列粒度定为**一事项一队列**；任务**直连事项 + 阶段**；启动分**事项级 / 阶段级**；任务运行态回写事项 / 阶段；执行阶段走**自有 runner**，`workstream-panel` 技能可发起各阶段任务。见 §2 A3·A9·A12–A14 / §3 / §4 / §5 / §6 / §9 D16–D19 / §10。

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
| A3 | **事项 / 阶段启动 = 队列启动** | 一个事项一条自有队列；**事项级启动**跑该事项队列（可按当前阶段），**阶段级启动**只跑该阶段的全部任务。用事项面板自有的队列引擎，不调用任务面板。 |
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
| A14 | **技能可发起各阶段任务** | `workstream-panel` 技能（+ 对应 API）可为一个事项按阶段创建任务、启动事项 / 阶段队列。见裁决 D19。 |

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
- 回边合法且必须留痕（R2）；裁剪（跳过阶段）必须在**规划**声明（R3）。
- 阶段证据谓词各阶段不同（§4），不能统一套用任务级 marker（见 §9 D3）。

## 6. 数据与存储（落点已按 §9 裁决）

| 数据 | 落点（初步） | committed / ignored |
|---|---|---|
| 事项卡（`stage`、各阶段段落） | `.dsh/workstreams/WS-*.md` | committed |
| 事项 ↔ 队列关联 | `WS.queues` = `[q-...]`（**0..1**，一事项一队列；裁决 D1 / D16） | committed |
| 三级任务（带 `workstreamId` + `stage`） | 事项面板自有文件，如 `.dsh/workstreams/queues.json`；**不得触碰 `.dsh/tasks/*`**（裁决 D8） | ignored |
| 事项 / 任务运行时绑定（会话 id 等） | `.dsh/workstreams/local.json`（沿用存储设计约定）：任务 → 会话 `sessions`，**事项 → 会话 `workstreamSessions`（WS-id → sessionId，可反查）** | ignored |
| 交付事实 / outcome 派生缓存 | WS 卡 `delivery` 块（沿用 schema） | committed（缓存）/ 派生 |

**硬约束**：事项面板不得读写 `.dsh/tasks/*`；不得依赖 `/api/tasks/*`。

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
| D19 | 执行阶段的引擎 | **事项面板自有 runner**；`workstream-panel` 技能可发起各阶段任务创建 / 启动 | **不用 `/task-todo`（任务面板）**；提示词与技能需相应改指 |

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
   - **已落地（2026-10-06）**：面板实例化并驱动 `WorkstreamsRunner`（3s `step()` 定时器、工作区切换重建、`serverPortProvider` 注入 dsh RPC）；`/api/workstreams/task/create` / `task/list` / `queue/start` / `queue/pause`；主卡「启动事项」+ 阶段卡「＋创建任务」「启动阶段」；三级任务卡展示状态 / 会话；
   - **已落地**：一事项一队列——`createStageQueue` 追加到该事项的队列、任务带 `stage`；`queue/start` 带 `stage` = 阶段级启动（只跑该阶段任务，跑完暂停队列）；
   - **已落地（2026-10-06）**：任务运行态 → 阶段运行态 → 事项运行态回写（A13 / D18）——纯模型 `WorkstreamsRunState.swift`（`WSRunState.stage` / `WSRunState.workstream`）从**队列状态 + 任务状态**（外加 `## 阶段确认` 审计痕迹判回边）派生**未开始 / 进行中 / 待确认 / 完成 / 阻塞**，主卡与阶段卡显示徽标；**权威 `stage` 一字不改**（仍只由 `confirmStage` 推进）。阶段门读 runner 的实时板，而非磁盘快照；
   - **已落地（2026-10-07）**：阶段提示词去掉 `/task-todo`、改指事项面板自有 API（`task/create` / `queue/start`），技能 `workstream-panel` 同步；
   - **已落地（2026-10-07）**：`covered` / `delivery` 写路由（`POST /api/workstreams/covered` / `delivery`；`delivery.outcome` 是派生缓存，API 拒绝手写，报 `outcome-derived`）；交付接线——面板「交付」按钮用 `WorkstreamsDelivery.resolve` 收集 git / GitHub / token 事实，准入失败给明确原因（`not-delivery-stage` / `not-git-repo` / `no-branch` / `no-remote` / `no-github-remote` / `no-token`），成功则 `runner.enqueueDelivery` 建 delivery 阶段任务并只启动该阶段；
   - **已落地（2026-10-07）**：事项 ↔ 会话绑定——`local.json` 新增 `workstreamSessions`（ignored），任何 `/api/workstreams/*` 写请求带 `session` 时记忆、`list` 随带；反查路由 `GET /api/workstreams/bound?session=...`；主卡 / 阶段卡「**在会话中处理**」对齐需求池「细化」（复用绑定会话 / 新建并绑定 / 回退当前会话），由 `WorkstreamsCore.sessionTarget` 纯决策 + `WorkstreamsQueues` 持久化承载；
   - **已落地（2026-10-07）**：**focus 通道**——面板 `focus(onWorkstream:)` 给目标卡加强调色描边并滚动到可见，被阶段筛选隐藏时回落「全部」；`/api/workstreams/*` 统一支持 `focus`（写操作 body / 读操作 `?focus=`，仅 200 触发，默认 `false` 不抢面板），经 `WorkstreamsAPIDelegate.apiWorkstreamsFocus` → `BrowserAPIBridge.workstreamsFocus` 落到面板；需求池子事项主 `↗` 改走该通道（次级仍打开卡文件）。**至此 §10 无待办。**