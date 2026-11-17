# 面板提示词清单（需求池 / 事项 / 任务）

> 状态：已落地 · 日期：2026-11-17（事项四阶段 + 交付操作）
> 关联：`docs/design/panels/requirements-pool-panel-design.md`（§5.7 需求提示词）、`docs/design/panels/workstream-handoff-prompt-design.md`（§3 / §4 事项阶段提示词）、`docs/design/panels/workstream-panel-design.md`（§5.1 四件事：拆分 / 确认 / 启动 / 交付）、`docs/design/panels/tasks-queue-session-loop-design.md`
> **单一事实来源是代码**。本文件是索引与快照；改提示词必须同步本文件与对应设计文档，否则会漂移。

## 0. 说明

「面板发出的提示词」在本清单里分**两类**：

1. **直接发给会话**：用户点面板按钮 → 壳层调 `session.prompt` 发一段文本；
2. **写进任务 body、由 runner 发出**：面板生成文本 → 存成三级任务的 body → 任务启动时作为该任务会话的提示词。

**目标会话选择规则**（当前实现）：

| 来源 | 选择规则 | 落点 |
|---|---|---|
| 需求池 | 该需求**绑定会话**（`.dsh/requirements/local.json`）→ 来源会话 → 当前会话 → 都没有则**复制提示词** | `main.swift` `startRequirementRefinementSession` / `sendBreakdownPrompt` / `notifyBreakdownResolved` |
| 事项面板（聊天侧） | 该事项**主场会话**（`.dsh/workstreams/local.json` 的 `workstreamSessions`）；没有则新建并绑定；失败回退当前会话 | `main.swift` `startWorkstreamSession` / `continueWorkstreamInSession` |
| 事项任务（执行侧） | **每个三级任务一条新会话**（不是主场会话） | `WorkstreamsRunner` |

编号：`RQ-*` 需求池 · `WS-*` 事项面板 · `TK-*` 任务面板（存量，参考）。

## 1. 需求池面板

| 编号 | 触发 | 目标会话 | 来源 | 一句话 |
|---|---|---|---|---|
| RQ-1 | 「创建并细化」/ 卡片「细化」 | 需求绑定会话 / 新建「细化 REQ-xxx」 | `RequirementsCore.refinementPrompt` | 请 agent 一起细化，只讨论不改码 |
| RQ-2 | 卡片「拆解」 | 需求来源会话 / 当前会话 / 复制 | `RequirementsCore.breakdownPrompt` | 请 agent 出 1..N 事项提案 |
| RQ-3 | 面板「确认拆解」 | 需求绑定会话 | L10n `requirements.notify.confirmed`（+ `confirmedFocus`） | 回写「已生成 WS-…，去事项面板」 |
| RQ-4 | 面板「驳回拆解」 | 需求绑定会话 | `RequirementsCore.rejectPrompt` | 带原因请 agent 改方案再提案 |

### RQ-1 细化（`refinementPrompt`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md
请和我一起细化这条需求：澄清目标、边界、验收标准；

注意：
- 只讨论、只澄清，不要修改代码或其它文件。
- 须修改需求时，用 POST /api/requirements/update（带上 session，保持同一会话）。
- 细化后，等待用户进行「需求拆解」。
```

### RQ-2 拆解（`breakdownPrompt`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md，需求已确认。
根据需求，将需求拆解为可依次落地的事项。
请给出拆解方案：每个事项的标题、边界、依赖顺序。

注意：
- 只拆不胀，范围外的新发现回池。
- 提交待确认提案（不要建卡、不要自签）。调用 拆解器 API `POST /api/requirements/breakdown/propose  {"id":"<REQ-id>","items":[{"title":"...","boundary":"...","dependsOn":["..."]}]}` 提交。
- 提交后，等待用户确认『待确认提案』。
```

### RQ-3 确认拆解回写（L10n `requirements.notify.confirmed`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md，需求拆解已确认。
已生成 <WS-…、WS-…>，请到事项面板继续处理。
（可用 ⌥⌘K 打开事项面板）

注意：
- 回复『收到』。
- 列出事项清单。
```

> 第 5 个格式参数是 focus 提示行（`requirements.notify.confirmedFocus`）。确认后右栏也会真的 `setRightPanel(.workstreams)`。

### RQ-4 驳回拆解（`rejectPrompt`）

```text
<REQ-id>「<标题>」@.dsh/requirements/<REQ-id>.md，需求拆解已驳回。
驳回原因：<原因>            ← 原因为空时省略这一行
请修改拆解方案。

注意：
- 只拆不胀，范围外的新发现回池。
- 重新提交待确认提案（不要建卡、不要自签）。调用 拆解器 API `POST /api/requirements/breakdown/propose  {...}` 提交。
- 提交后，等待用户确认『待确认提案』。
```

## 2. 事项面板

### 2.1 直接发给会话的

| 编号 | 触发 | 目标会话 | 来源 |
|---|---|---|---|
| WS-1 | 主卡「拆分任务」 | 事项主场会话（复用/新建并绑定） | `WorkstreamHandoff.splitPrompt(card:stage:)`，`stage` = **首个未处理阶段** |
| WS-2 | 阶段卡「确认」成功后 stage 前移 | 事项主场会话（有绑定才发） | `WorkstreamHandoff.nextStagePrompt(card:)` |

> WS-2 的前置是**人工门**（R10）：阶段卡「确认 / 退回」由面板点按则卡片留痕记 `source:panel`；用户在会话里**明确授权**后由 agent 调 `POST /api/workstreams/stage/confirm` / `stage/reject` 则记 `source:session <id>`（都写进卡片 `## 阶段确认`，`stage` 前移 / 回边）。**签字仍是人，agent 不自签**。

两条提示词同用**公共头**：

```text
你在 <repo> 处理一个事项。

本步事实：
- 事项：.dsh/workstreams/<WS-id>.md
- 需求：.dsh/requirements/<REQ-id>.md      ← 有需求时出现
- 存储约定：.dsh/requirements/README.md（通用规则见工作区 AGENTS.md）

当前 stage：<中文>      本步动作：<动作>
目标：<卡片「## 规划」里的目标>          ← 有则出现

<动作段>

规则（强制）：
- 改事项卡片一律走 /api/workstreams/*（workstream-panel 技能）；不直接改 .dsh 文件。
- 回边合法但必须留痕；跳过 / 裁剪必须在「规划」声明。
- 只拆不胀：范围外的新发现回需求池（R5），不就地吸收。
- 裁决是点记录；覆盖锚变更；终态是派生谓词（不写 closed / outcome）。
- <回归门 REG-xxx：若改动其覆盖路径，交付前运行。>   ← 卡片有 regression 时才出现
- 阶段任务走事项面板自有 API：POST /api/workstreams/task/create 建（任务带 stage）、POST /api/workstreams/queue/start 启动；不用任务面板技能。
- 不改其它会话的在途文件。
```

**WS-1 的动作段**（`.splitTasks`）：

```text
本步做「拆分任务」：
- 用 POST /api/workstreams/task/create 建等待态阶段任务（= 任务拆分本身）：每条任务带本阶段 stage，追加到该事项唯一的队列；只建不启动。
- 阶段 ↔ 队列映射由面板写回卡片 queues；停下请人确认拆分合理。
- 不自签：拆分是人工确认门，agent 只建等待态任务；等人在面板点「启动事项」（或会话里明确要求启动）后才 queue/start。
```

### 2.2 写进任务 body、由 runner 发出的

| 编号 | 触发 | body 来源 | 动作段 |
|---|---|---|---|
| WS-3 | 阶段任务（agent 调 `task/create` / 创建任务抽屉 / 面板生成阶段队列） | `WorkstreamHandoff.stageTask` / `prompt(card:action:)` | 见下（按阶段默认动作） |
| WS-7 | **事项主卡「交付」**（操作，不是阶段；前置 `accepted`，发进**主场会话**）/ 会话说「交付 WS-x」（`POST /api/workstreams/deliver`） | `WorkstreamsDelivery.prompt(plan:)` | 交付长模板（见代码）：不新建会话 / 任务、不改 `stage`，完成信号 = `POST /api/workstreams/delivery` |

创建任务抽屉会在提示词末尾追加用户输入：`任务内容：` + 内容（首行是标题、其余行是内容）。

**各阶段默认动作段**（`actionSection`）：

```text
规划   「确认规划」：用 /api/workstreams/plan 补齐四件套（目标/边界/验收标准 AC<n>/阶段裁剪声明）；不直接改 .dsh 文件。
                     四件套齐后停下请人确认规划；人确认前不得进入设计。
设计   「出设计」：  在 docs/design/** 写设计文档，把待确认问题列成 Q 表；只写设计不写实现；写完停下请人确认设计。
执行   「拆分任务」：用 POST /api/workstreams/task/create 建等待态阶段任务（带本阶段 stage）；只建不启动；停下请人确认。
       「启动实施」：人确认拆分后，用 POST /api/workstreams/queue/start（带 stage）启动；在已确认边界内改码/跑测试/commit。
验收   「校验」：    跑回归门与机检证据；用 POST /api/workstreams/covered 记录覆盖点（paths + base/head 锚变更）；必须人 sign-off，agent 不自签。
```

> **交付不是阶段的动作段**：四阶段到此为止。验收确认（`accepted`）后，`WorkstreamsDelivery.prompt(plan:)`
> 由事项主卡「交付」按钮发进**主场会话**执行 push / PR，用 `POST /api/workstreams/delivery` 记
> `pr` / `url` 事实（`outcome` 派生、不手写）——不新建会话 / 任务，也不改变 `stage`。

### 2.3 运行时包装

| 编号 | 场景 | 来源 | 说明 |
|---|---|---|---|
| WS-4 | 每个执行任务 | `WorkstreamHandoff.completionMarkerInstruction(marker)` | 追加在末尾，要求会话最后一行原样回显 marker（完成证据） |
| WS-5 | 任务 body 不是面板交接提示词时的兜底 | `WSPrompts.task(task:queue:)` | 「你在推进事项 … 的『<阶段>』阶段」+ 任务 + 要求（只做这一条 / 不碰运行态文件 / 汇报） |
| WS-6 | 待确认任务重试 | `WSPrompts.retryContinuation(title:marker:)` | 「上一轮因中断或未拿到完成证据而停止，请从未完成处继续本任务：<标题>。」+ marker |

**WS-4 措辞**：

```text
完成前，请在最后一行原样输出以下标记（供面板识别本次任务已结束）：
<marker>
```

## 3. 任务面板（存量，参考）

任务面板有自己的提示词单一来源 `TaskPrompts`（`TasksRunner.swift`），本清单只列**功能入口**，不复制全文：

| 编号 | 场景 | 来源函数 |
|---|---|---|
| TK-1 | issue 任务 | `TaskPrompts.issue` |
| TK-2 | 手动任务 | `TaskPrompts.manual` |
| TK-3 | 通用要求（分支/队列） | `TaskPrompts.requirements` / `multiRepoRequirements` / `childWorkdirRequirement` |
| TK-4 | 完成 marker | `TaskPrompts.completionMarkerInstruction` |
| TK-5 | 重试续跑 | `TaskPrompts.retryContinuation` |
| TK-6 | 交接简报 | `TaskPrompts.briefSection` / `brief` |
| TK-7 | 收尾 / 开 PR / 合并 / 推送 | `TaskPrompts.pullRequest` / `integration` / `mergeAndPush` / `pushOnly` |
| TK-8 | 队列完成通知 | `TaskPrompts.queueFinishedSummary` |

## 4. 梳理结论

1. **三套提示词各有单一来源，但此前没有统一清单**——本文件补上；三处来源分别落在 `RequirementsCore`、`WorkstreamsPrompts`（+ `WorkstreamsDelivery` / `WSPrompts`）、`TaskPrompts`。
2. **阶段命名歧义（已修）**：事项阶段枚举是 `task`、中文叫「执行」，而路由叫 `task/create`、动作叫「拆分任务」——agent 极易把 `stage` 传成 `task`。提示词现给出阶段**原始值**（`当前 stage：规划（planning）`）并明确「不要传 `task`」，`splitPrompt` 生成带 `"stage":"<raw>"` 的调用示例；`api-tests` / `runner-tests` 固化四个原始值的映射（交付不是阶段，没有 `delivery`）。
3. **提示词双重身份**：事项「阶段提示词」既是**聊天提示词**（WS-1/WS-2）又是**任务 body**（WS-3）。改一处会同时影响两侧，需一起验。
4. **目标会话规则不统一**：需求池四级回退（绑定→来源→当前→复制）、事项面板两级（绑定→新建）、任务面板「每任务一条 + 回传来源会话」。长期建议收敛为「**实体 → 主场会话**」一种模型。
5. **两处同名不同物**：需求池有「拆解」、事项面板有「拆分任务」；前者是 REQ→WS，后者是 WS 阶段→任务，别混。

## 5. 维护约定

- **新增**任何面板动作发提示词 → 在本文件登记编号，并写清目标会话与来源函数；
- **改动**提示词 → 同步四处：① 代码；② 本文件；③ 对应设计文档（需求池 §5.7 / `workstream-handoff-prompt-design` §3·§4 / `workstream-panel-design` §5.1）；④ 若涉及 API 措辞，`requirement-pool` / `workstream-panel` 技能；
- 本文件**不复制**长模板全文（交付 / 任务面板），以「来源函数」为准，避免双份漂移；短提示词（RQ-1..4、WS-1..6）保留逐字快照。