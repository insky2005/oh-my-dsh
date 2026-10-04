# AI 原生工作流 · 可复用规范（Spec）

> 状态：草案 · 日期：2026-10-03 · 适用：任何采用「需求 → 拆解 → 事项」工作流的项目
> 来源：从 oh-my-dsh 的实践与产出物中抽取的**通用部分**；本项目的具体实现见 `docs/research/ai-native-workflow-architecture.md`、`docs/design/panels/requirements-workstream-store-design.md`、`docs/usage/ai-native-workflow-manual.md`。

## 0. 这份文档是什么

- **是什么**：与具体项目无关的工作流**规范**——概念、状态存储契约、规则、人工确认门、接入步骤；
- **不是什么**：不含某个项目的面板 / 工具实现，不规定 UI，不依赖特定文档结构；
- **怎么用**：把下面的路径换成你自己的，按 §7 接入；其余是它与 agent 之间的契约。

## 1. 概念模型

| 概念 | 定义 |
|---|---|
| **需求（Requirement）** | 追踪单元的**来源**：一条尚未确定做法的诉求，住在需求池。 |
| **需求池（Idea Pool）** | 需求的家：收集 / 评估 / 拆分 / 丢弃。 |
| **拆解（Breakdown）** | 需求 → 1..N 个事项的入口；agent 出方案、**人确认**。 |
| **事项（Workstream）** | **最小工作单元**；关联 0..1 需求、0..N 队列 / PR。 |
| **阶段（Stage）** | 事项的状态：规划 / 设计 / 任务 / 验收 / 交付。 |
| **终态（Terminal）** | **派生谓词**：`stage == 交付` 且交付结果终结（merged / closed / abandoned）。 |
| **裁决（Verdict）** | 验收的**点记录**：判定人 + 证据 + 覆盖的变更；**永不失效**，只覆盖。 |
| **覆盖（Coverage）** | 裁决只覆盖它裁定的那次**变更**（不可变内容标识）。 |
| **回归门（Regression Gate）** | 长期不变量，**每次改动都跑**的可执行检查。 |
| **角色（Role）** | Delegate（agent 首版）/ Review（人校验）/ Own（人负责）。 |

## 2. 追踪单元

- 追踪单元是**事项**，不是「工作区的阶段」；需求是事项的来源。
- 事项是**最小工作单元**：量级 ≈ 1 目标 + 1 设计 + 1 队列 + 1 PR；超出即拆成多个事项。
- 一个需求可拆出 1..N 个事项；事项可**不挂需求**（顺手活）。

## 3. 状态存储契约（`.dsh`）

一卡一文件（Markdown + YAML frontmatter），**随仓库提交**：

```text
.dsh/
├── ai-native-workflow-spec.md   # 本规范（默认位置，随仓库提交）
├── requirements/REQ-<id>.md     # 需求卡
├── workstreams/WS-<id>.md       # 事项卡
├── regression/REG-<id>.md       # 回归门 + 可执行 checker
└── tools/                       # 派生器等（参考实现）
```

**字段摘要**：

- **REQ**：`id` / `title` / `source` / `created` / `updated`（必选）；`state`（**可选，仅人工判断**：candidate / evaluating / suspended / discarded）；`workstreams`（派生缓存）；
- **WS**：`id` / `title` / `stage` / `created` / `updated`（必选）；`requirement`（0..1）；`covered`（验收起必选，锚变更）；`regression`（0..1）；`queues`（0..N）；`delivery.pr` / `delivery.url`（交付阶段的事实）；
- **REG**：`id` / `title` / `source` / `runs`（可执行检查）/ `created` / `updated`。

**committed vs ignored**：定义与阶段随仓库提交；**运行时绑定只在本机**（如 `*.local.json`，忽略）。

**禁止手写的字段**：`closed`、`outcome`、`split`——全部**派生**（§4 R6/R9）。

## 4. 规则

| # | 规则 | 含义 |
|---|---|---|
| R1 | **阶段是状态，不是站点** | 面板 / 工具服务「某状态的所有事项」，不是「流程第 N 站」 |
| R2 | **回边合法且留痕** | 返工 / 退回 / 重跑是正常工序，但要有记录 |
| R3 | **跳过 / 裁剪必须在规划声明** | 裁剪决策本身是规划产物 |
| R4 | **停驻是一等状态** | 「待确认」可停留、可回退，不得被当作成功 |
| R5 | **只拆不胀** | 范围外的新发现回池为新需求、另起事项，不就地吸收 |
| R6 | **终态是派生谓词** | `closed = stage==交付 且交付结果终结`；是观察不是迁移 |
| R7 | **裁决是点记录，覆盖锚变更** | 不锚文件当前内容 / 分支 / 裸 commit；无「失效」，只有「未覆盖」 |
| R8 | **需求关闭派生** | 有子事项且全部终态（或显式 `discarded`）；空子集不自动关闭 |
| R9 | **不手写派生事实** | `closed` / `outcome` / `split` 一律由派生器算出 |
| R10 | **人工确认门** | 见 §5；规划确认 / 设计确认 / 拆分确认 / 验收 sign-off 不可由 agent 自签 |
| R11 | **回归门** | 不变量每次改动都跑；后事项打破 → 后事项失败，不重开前事项 |

## 5. 工作流与人工确认门

```text
对话/想法 ─► 需求卡 ──拆解(agent 出方案)──► 事项卡
                                   ◆ 人确认拆解
                                      │ 规划(目标/边界/验收标准/裁剪声明)
                                   ◆ 人确认规划
                                      ▼
                                    设计
                                   ◆ 人确认设计
                                      ▼
                                  任务拆分(方案 / 队列)
                                   ◆ 人确认拆分合理
                                      ▼
                                    启动实施
                                      ▼
                     验收(回归门 + 机检证据) ◆ 人 sign-off
                                      ▼
                     交付(PR) ◆ 人 merge ─► 派生终态

◆ = 人工确认门（agent 出方案 / 人 Own）
```

## 6. 派生与门（实现无关的接口）

- **终态派生器**：输入 = 卡片 + 交付结果（PR 状态），输出 = `outcome` / `closed`，以及需求的**有效状态**（`discarded > closed > split > state`）。**只读，不写卡片。**
- **回归门**：一条能自证失败的可执行检查；由事项验收标准中「长期成立」的部分升格而来，定义在 `REG-*.md` 的 `runs`。
- **复核原则**：无令牌 / 无网络时输出 `unknown`，**不假装成功**。

## 7. 接入指南（新项目）

1. **放规范**：把本文件复制到 `<项目根>/.dsh/ai-native-workflow-spec.md`（**默认位置**），随仓库提交；
2. **建目录**：`.dsh/requirements`、`.dsh/workstreams`、`.dsh/regression`、`.dsh/tools`；
3. **写通用规则**：在本项目 `AGENTS.md` 增一段（模板见下）——agent 对话开始会自动加载；
4. **放参考实现**：派生器与回归门 checker（见 §8）；
5. **约定确认门**：把 §5 的 ◆ 写进团队约定（谁确认、在哪个 PR / 面板确认）；
6. **迁移**：从「无卡片」起，先把一个真实需求落成 `REQ-*.md` + 一件 `WS-*.md`，走完一次闭环再铺开。

`AGENTS.md` 模板：

```md
## AI 原生工作流（.dsh 卡片）
- 规范：.dsh/ai-native-workflow-spec.md
- 状态在 .dsh（随仓库提交）：需求 REQ-*.md、事项 WS-*.md、回归门 REG-*.md
- 不手写派生字段：closed / outcome / split 由派生器算出
- 人工确认门：拆解 / 规划 / 设计 / 任务拆分 / 验收 sign-off / merge
- 只拆不胀：范围外的新发现回池
```

## 8. 参考实现（不属于规范本身，可替换）

- **派生器**：`node .dsh/tools/derive-status.mjs`（读卡片 + 查 PR 状态，输出 outcome / closed / 有效状态）；
- **回归门 checker**：`node .dsh/regression/check-*.mjs`；
- **任务阶段工具**：oh-my-dsh 的任务面板 + `/task-todo` 技能（拆分 = 建等待态队列、实施 = 启动、交付 = deliver）——**可选**，任何等价机制都可以。

## 9. 词汇表

| 词 | English |
|---|---|
| 需求 / 需求池 | Requirement / Idea Pool |
| 拆解 | Breakdown |
| 事项 | Workstream |
| 规划 / 设计 / 任务 / 验收 / 交付 | Planning / Design / Task / Acceptance / Delivery |
| 裁决 / 覆盖 | Verdict / Coverage |
| 回归门 | Regression Gate |
| 终态 | Terminal |