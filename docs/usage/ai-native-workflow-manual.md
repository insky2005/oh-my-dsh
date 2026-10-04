# AI 原生工作流 · 手动模式使用说明（配合任务面板）

> 状态：草案 · 日期：2026-10-03 · 关联：`docs/research/ai-native-workflow-architecture.md`、`docs/design/panels/requirements-workstream-store-design.md`、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/usage/panels.md`、`.dsh/requirements/README.md`

## 0. 适用范围

本说明是 **oh-my-dsh 下的用法**；通用规范见 `.dsh/ai-native-workflow-spec.md`（概念 / `.dsh` 契约 / 规则 R1–R11 / 确认门）——**两者冲突以 spec 为准**。

在没有「需求池面板 / 拆解器」之前，用 agent 读写 `.dsh` 卡片 + 任务面板跑执行组成的手动闭环。覆盖：**需求 → 拆解 → 事项（规划 → 设计 → 任务拆分 → 实施 → 验收 → 交付）→ 终态派生**。任务阶段交给**任务面板**（`⌥⌘J`；App 能力，见 spec §9）。

初始化：对 agent 说「**按 `.dsh/ai-native-workflow-spec.md` 初始化本项目的 AI 原生工作流**」（spec §7.1）。

前提：

- 在 oh-my-dsh 里工作；任务面板相关操作需要 App 在运行；
- 需求 / 事项状态在 `.dsh/requirements`、`.dsh/workstreams`（**随仓库提交**）；
- 终态由 `node .dsh/tools/derive-status.mjs` **派生**，不手写。

## 1. 闭环总览

```text
对话/想法 ─► 需求卡 ──拆解(agent 出方案)──► 事项卡
                                   ◆ 人确认拆解
                                      │ 规划(AC + 裁剪)
                                   ◆ 人确认规划
                                      ▼
                                    设计
                                   ◆ 人确认设计
                                      ▼
                                  任务拆分（/task-todo 建等待态队列）
                                   ◆ 人确认拆分合理
                                      ▼
                                    启动实施
                                      ▼
                     验收(回归门 + 机检证据) ◆ 人 sign-off
                                      ▼
                     交付(PR) ◆ 人 merge ─► derive-status ─► closed(派生)

◆ = 人工确认门（agent 出方案 / 人 Own）；规范同 spec §5
```

## 2. 手动模式：逐步 + 提示词示例

### 2.0 通用规则：写进工作区 `AGENTS.md`（自动加载）

通用规则**不在提示词里重复**：写进工作区的 `AGENTS.md`，agent 对话开始会自动加载。模板**以 spec §7 为准**：

```md
## AI 原生工作流（.dsh 卡片）
- 规范：.dsh/ai-native-workflow-spec.md
- 状态在 .dsh（随仓库提交）：需求 REQ-*.md、事项 WS-*.md、回归门 REG-*.md
- 不手写派生字段：closed / outcome / split 由派生器算出
- 人工确认门：拆解 / 规划 / 设计 / 任务拆分 / 验收 sign-off / merge
- 开工前置（硬规则）：需求未落卡 / 事项未确认 / 任务队列未启动之前，只讨论、只澄清、只落卡，不得修改代码或文件；实施的唯一入口 = 已启动的任务队列
- 只拆不胀：范围外的新发现回池
```

> 本仓库的实例见 `AGENTS.md` 的「AI 原生工作流」段。之后每条提示词只写**本步要做什么**（见 §2.1–§2.9）。

### 2.1 落需求

```text
把下面这条诉求落成需求卡片 `.dsh/requirements/REQ-<id>.md`（`state: candidate`）：
<诉求>
先切分支，不要直接改 main。
```

### 2.2 拆解（1 需求 → 1..N 事项）

```text
读 .dsh/requirements/REQ-<id>.md，提出拆解方案：给出每个事项的边界与依赖顺序。
先只给方案，等我确认后再建 `.dsh/workstreams/WS-*.md`；不要把范围外的东西并进来。
```

### 2.3 事项规划

```text
读 .dsh/workstreams/WS-<id>.md，补齐「规划」：目标 / 边界 / 验收标准 / 阶段裁剪声明。
停下等我确认，再进设计。
```

### 2.4 设计（写完 → 人确认）

```text
按 WS-<id> 的规划出设计：写 `docs/design/**`，不写实现。
写完后停下，让我确认设计再往下。
```

### 2.5 任务拆分（`task-todo` 落成等待态队列 → 人确认拆分合理）

```text
/task-todo 把 WS-<id> 的设计拆成任务：建等待态队列 + 批量入队（只建、不启动）。
这一步**就是「任务拆分」本身**（每条任务 = 一个待入队的拆分单元）——只建、不启动。
把队列 id 记到 WS-<id>.md 的 `queues`；建成后停下，让我在任务面板确认拆分是否合理。
```

> 等待态队列（`.draft`）是**拆分结果的载体**：人在面板里看过任务清单、确认合理，才启动。见 §4。

### 2.6 实施（确认拆分 → 启动队列）

```text
/task-todo 启动队列。
实施时：先切分支 feature/<slug>；只做边界内的事，范围外的新发现回池；
conventional commits；改到共享路径前先跑回归门。
```

> 队列跑完由 `task-todo` 交付（`queue/deliver`，交付会话 push + PR），见 §4。

### 2.7 验收

```text
对 WS-<id> 做验收：跑回归门（若适用）与机检，给出可机检证据与 covered 区间；
停在我这里等 sign-off，不要自签。
```

### 2.8 交付

```text
记录 WS-<id> 的 delivery.pr，push 分支并开 PR。
`closed` / `outcome` 不要手写。
```

### 2.9 终态派生

```sh
GH_TOKEN=$(cat "$HOME/.dsh/oh-my-dsh/tokens/<owner>-<repo>") \
  node .dsh/tools/derive-status.mjs
```

## 3. 任务面板：操作说明

任务面板是 **oh-my-dsh App 的能力**（不是规范；见 spec §9）。入口：**`⌥⌘J`** / 活动栏「任务」。任务台 = 手动任务 + GitHub issue 两种来源，队列（泳道）串行执行。

| 操作 | 位置 | 说明 |
|---|---|---|
| 新建手动任务 | 页签行右侧 **「＋」**（空态给「新建任务」） | 抽屉：首行标题，其余行是给执行者的描述；`⌘↩` 创建，可连续录入 |
| 新建队列 | **「▣＋」** | 队列名 / 分支 / 基于分支 / 不切分支 / 完成后自动开 PR |
| 加入队列 | 卡片 **「加入队列 ▾」** | 第一项固定「新建队列…」 |
| 开始 / 暂停 | 队列头图标 | 队列内 FIFO 串行，全局严格串行 |
| 交付 / 开 PR | 队列头**最右**图标 | 起一条「交付：<队列名>」会话，push + 开 / 复用 PR |
| 全部处理 | 工具栏第一位 | 每个待办任务各建一个单任务队列，按板面顺序串行 |
| 配置 GitHub Token | 工具栏 | 只写文件 `~/.dsh/oh-my-dsh/tokens/<owner>-<repo>`（chmod 600） |

### 3.1 与事项的关系

| 维度 | 事项 WS | 队列 queue |
|---|---|---|
| 层级 | **追踪单元** | **执行载体** |
| 宿主 | `.dsh/workstreams/WS-*.md`（committed） | `.dsh/tasks/queues.json`（本机） |
| 基数 | 1 事项 : 0..N 队列 | 1 队列 : 0..1 事项 |
| 关联权威 | `WS.queues`（committed） | 队列内 `workstream` 是运行时镜像（可重建） |

### 3.2 三种工作区形状（提示词按形状出条目）

| 形状 | 行为 |
|---|---|
| 非 git 目录 | 不切分支、不 commit、不开 PR |
| git 仓库、无 GitHub 远端 | 有分支 / commit，无 PR 能力 |
| GitHub 仓库 | 全流程（分支 + commit + 交付会话开 PR） |

### 3.3 必须知道的三条语义

- **任务只 commit**；push 与 PR 由队列跑完后的一条**交付会话**执行，结果回写队列；
- **建任务 / 建队列 ≠ 开始干活**：只有「开始」或明确说「启动队列」才跑；
- 任务默认**60 分钟**超时；每个任务结束会**汇报回写**，队列下一棒据此知道上一棒做了什么。

## 4. 任务面板：内置技能 `task-todo`（任务拆分 / 实施 / 交付）

任务面板 / `task-todo` 是 **oh-my-dsh App 的能力**（spec §9），不是规范的一部分。**任务拆分、任务实施、交付这三步**由内置技能 `task-todo` 承接（App 启动时安装到 `$DSH_HOME/skills/task-todo/SKILL.md`）；不用技能时也可在面板里手点（§3）。

> 用 **`/task-todo` 指令**调用（如 `/task-todo 把设计拆成任务`、`/task-todo 启动队列`）；技能只在明确要求时动手。

| 工作流步骤 | 技能动作 | API |
|---|---|---|
| **任务拆分**（落队列） | 建**等待态队列** + 批量入队（不启动） | `POST /api/tasks/queue/create` |
| 追加任务 | 追加到本会话已有队列（默认行为） | `POST /api/tasks/queue/append` |
| **任务实施**（启动） | 启动队列 | `POST /api/tasks/queue/start` |
| **交付** | 对**已完成**队列发起交付（交付会话 push + PR） | `POST /api/tasks/queue/deliver` |
| 只建任务 | 建「待处理、未入队」任务 | `POST /api/tasks/task/create` |

技能只在**你明确要求**时动手；默认**追加到本会话已有的队列**，没有才新建「等待态队列」。触发说法：

| 目的 | 这样说 |
|---|---|
| 把方案落成队列 + 任务 | `/task-todo 把刚才讨论的方案拆成任务` |
| 启动队列 | `/task-todo 启动队列` |
| 交付已完成队列 | `/task-todo 交付这个队列` |
| 只要任务、不入队 | `/task-todo 只建任务，先别入队` |

> 技能经壳层 localhost API 写面板，**不直接改 `.dsh/tasks/*.json`**；App 没运行时它会报错而不是绕过。
> 「建任务 / 建队列」≠「开始干活」；只有「启动队列」才跑。

## 5. 交接提示词（把事项交给新会话）

模板见 `docs/design/panels/workstream-handoff-prompt-design.md`。最小可用形状：

```text
你在 oh-my-dsh 仓库工作。处理事项 WS-<id>「<标题>」。
先读：.dsh/workstreams/WS-<id>.md、.dsh/requirements/<REQ-ID>.md（通用规则见工作区 AGENTS.md）。
当前 stage：<stage>；本步动作：<action>。目标与边界以卡片「规划」为准。
规则：只拆不胀；终态是派生谓词（不写 closed/outcome/split）；
      回归门 <REG-ID>（若改动其覆盖路径，交付前跑）；不改其它会话的在途文件。
结束前停下问：规划确认 / 设计确认 / 拆分确认 / 验收 sign-off。不要自签。
```

## 6. 命令速查

```sh
# 终态派生（只读，不写卡片）
GH_TOKEN=$(cat "$HOME/.dsh/oh-my-dsh/tokens/<owner>-<repo>") node .dsh/tools/derive-status.mjs

# 回归门（共享路径改动后）
node .dsh/regression/check-architecture-model.mjs

# 分支与交付
git checkout -b feature/<slug>
git push https://github.com/<owner>/<repo>.git HEAD:refs/heads/feature/<slug>
```

## 7. 收尾自检清单

- [ ] 需求卡 / 事项卡的 `state` / `stage` 与事实一致（`split` 不手写，由派生给出）；
- [ ] 范围外的新发现已回池为新需求，没有偷偷扩大事项；
- [ ] **设计已获人确认**；任务拆分（等待态队列）已获人确认合理，才启动；
- [ ] 验收有**可机检证据**，且有人 sign-off；
- [ ] `delivery.pr` 已记；`closed` / `outcome` **未被手写**；
- [ ] 交付前跑过适用的回归门；
- [ ] 没有改其它会话 / 事项的在途文件。

## 8. 常见坑

规则以 **spec §4（R1–R12）** 为准；这里只列最容易踩的几条。

| 坑 | 正确做法 |
|---|---|
| 手写 `closed` / `outcome` / `split` | 它们都是**派生**的；要状态就跑 `derive-status` |
| 把新发现并进当前事项 | **只拆不胀**：回池成新需求，另起事项 |
| 让 agent 自签验收 | 机检绿 ≠ 完成；**人 sign-off** 是 Own 点 |
| 直改 `.dsh/tasks/*.json` | 走任务面板或 `/api/tasks/*`（面板是唯一写者） |
| 以为「建了队列」就是「开跑」 | 建 ≠ 启动；显式「启动」或点「开始」 |
| 需求还没落卡 / 拆解还没确认就动手改代码 | 需求阶段**只讨论、只澄清、只落卡**；实施的唯一入口是**已启动的任务队列**（spec R12） |