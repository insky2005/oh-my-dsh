# AI 原生工作流 · 使用说明（需求池面板 + 任务面板）

> 状态：草案 · 日期：2026-10-05 · 关联：`docs/research/ai-native-workflow-architecture.md`、`docs/design/panels/requirements-pool-panel-design.md`、`docs/design/panels/requirements-breakdown-standard-design.md`、`docs/design/panels/requirements-workstream-store-design.md`、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/usage/panels.md`、`.dsh/requirements/README.md`

## 0. 适用范围

本说明是 **oh-my-dsh 下的用法**；通用规范见 `.dsh/ai-native-workflow-spec.md`（概念 / `.dsh` 契约 / 规则 R1–R12 / 确认门）——**两者冲突以 spec 为准**。

覆盖：**需求 → 拆解 → 事项（规划 → 设计 → 任务拆分 → 实施 → 验收 → 交付）→ 终态派生**。其中两段已是壳层面板能力（App 能力，见 spec §9）：

| 阶段 | 承接者 | 入口 |
|---|---|---|
| 需求 → 拆解 | **需求池面板** + 技能 `requirement-pool` | `⌥⌘I`（活动栏第 5 位「需求池」） |
| 任务拆分 → 实施 → 交付 | **任务面板** + 技能 `task-todo` | `⌥⌘J`（活动栏「任务」） |

规划 / 设计仍由**事项会话**承担（面板不服务这两个阶段）；终态由 `derive-status` 派生。

不用面板也可以：用 agent 直接读写 `.dsh` 卡片，按 §2 的提示词逐步推进——**手动路径与面板路径等价**，只是少了「确认拆解 / 启动队列」这类面板按钮。

初始化：对 agent 说「**按 `.dsh/ai-native-workflow-spec.md` 初始化本项目的 AI 原生工作流**」（spec §7.1）。

前提：

- 在 oh-my-dsh 里工作；面板相关操作需要 App 在运行；
- 需求 / 事项状态在 `.dsh/requirements`、`.dsh/workstreams`（**随仓库提交**）；运行时绑定（需求 ↔ 会话）在 ignored 的 `.dsh/requirements/local.json`，不进卡片；
- 终态由 `node .dsh/tools/derive-status.mjs` **派生**，不手写。

## 1. 闭环总览

```text
对话/想法
  ├─（面板可做）需求池「＋」/ requirement-pool 技能 → 需求卡 REQ-*.md（candidate）
  ▼
拆解（agent 出 1..N 事项方案）
  ◆ 人在需求池面板「确认拆解」/「驳回（带原因）」（面板是唯一 confirm 入口）
  ▼
事项卡 WS-*.md
  │ 规划(AC + 裁剪)                      ◆ 人确认规划
  ▼ 设计                                 ◆ 人确认设计
  ▼ 任务拆分（/task-todo 建等待态队列）   ◆ 人确认拆分合理
  ▼ 启动实施
  ▼ 验收(回归门 + 机检证据)              ◆ 人 sign-off
  ▼ 交付(PR) ◆ 人 merge ─► derive-status ─► closed(派生)

◆ = 人工确认门（agent 出方案 / 人 Own）；规范同 spec §5
```

## 2. 逐步操作 + 提示词示例

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

### 2.1 落需求（需求池面板 / `requirement-pool`）

**面板**：`⌥⌘I` 打开需求池 → 工具栏右侧「＋」→ 抽屉里**首行写标题、其余行写诉求** → `⌘↩` 或「创建」（只写卡）；点**「创建并细化」**会再起一条「细化 REQ-xxx」会话，并把卡片绑定到它。

**对话**（要明确说「记个想法 / 落成需求」）：

```text
把这个想法落成需求卡片 `.dsh/requirements/REQ-<id>.md`（`state: candidate`）：
<诉求>
```

> agent 经 `POST /api/requirements/create` 落卡（带 `$DSH_SESSION_ID`），**不直接改文件**；这样之后面板点「拆解」会回到这条对话。

### 2.2 拆解（1 需求 → 1..N 事项；面板确认）

**面板**：在需求卡点「拆解」（`square.split.2x2`，**仅尚未拆解时出现**）→ 提示词发到创建该需求的会话（没有则当前对话）→ agent 出方案并 `POST /api/requirements/breakdown/propose` 落成**待确认提案** → 面板出现「待确认拆解」→ 人点「确认拆解」建 `WS-*.md`，或点「驳回」填原因（原因随提示词回到对话，让 agent 按原因改）。

**对话**：

```text
/requirement-pool 拆解 REQ-<id>
```

或（手动路径）：

```text
读 .dsh/requirements/REQ-<id>.md，提出拆解方案：给出每个事项的边界与依赖顺序。
先只给方案，等我在需求池面板确认；不要把范围外的东西并进来。
```

> **确认拆解是不可自签的人工门**（R10）：agent 只调 `propose`；`confirm` 只有面板按钮能触发。确认后 `WS-*.md` 的 `requirement` 回指需求、`stage: planning`，并留下需求 → 事项映射表。确认后该需求**冻结**（不可再编辑，改需求请另起，R5）。

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

> 等待态队列（`.draft`）是**拆分结果的载体**：人在面板里看过任务清单、确认合理，才启动。见 §5。

### 2.6 实施（确认拆分 → 启动队列）

```text
/task-todo 启动队列。
实施时：先切分支 feature/<slug>；只做边界内的事，范围外的新发现回池；
conventional commits；改到共享路径前先跑回归门。
```

> 队列跑完由 `task-todo` 交付（`queue/deliver`，交付会话 push + PR），见 §5。

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

## 3. 需求池面板：操作说明（收件 / 需求池 / 拆解）

需求池面板是 **oh-my-dsh App 的能力**（不是规范；见 spec §9）。入口：**`⌥⌘I`** / 活动栏第 5 位「需求池」（知识库之后、任务之前）。面板只服务**需求池**：收件 / 评估 / 拆分 / 丢弃；规划 / 设计 / 验收 / 交付仍走事项会话。

| 操作 | 位置 | 说明 |
|---|---|---|
| 新建需求 | 工具栏右侧 **「＋」**（空态给「新建需求」） | 抽屉：**首行标题、其余行诉求**；`⌘↩` 创建；可点「创建并细化」起一条细化会话 |
| 改人工状态 | 卡片**状态徽标**（尾部 `▾`，整枚可点） | 生命周期**单向前进**：候选 → 评估中 → 已评估；另有挂起 / 丢弃（丢弃单向）。菜单**只列可达状态** |
| 拆解 | 卡片 **「拆解」**（`square.split.2x2`） | **仅尚未拆解时出现**；把提示词发到创建该需求的会话（没有则当前对话） |
| 确认拆解 | 「待确认拆解」块右上 | **唯一**生成 `WS-*.md` 的入口（人工门，R10） |
| 驳回 | 「待确认拆解」块右上 | 弹**原因抽屉**（必填），原因带回对话让 agent 按原因改 |
| 编辑 | 卡片铅笔图标 | 仅**未拆解**时可改标题 + 诉求；已拆解**冻结**（R5） |
| 打开事项卡 | 事项卡 **`↗`** | 在文件面板打开对应 `WS-*.md` |

- **有效状态**（派生，只读徽标）：`discarded > closed > split > state || candidate`；`split` / `closed` 与人工状态**分开展示**（如「已评估 + 已拆分」），`split` 时人工菜单不含 `candidate`；
- **已拆解事项**：内容（标题 / 边界 / 依赖）取自 REQ 确认表，状态（阶段 / 结果 / 路径）取自 WS 卡；两处不一致会**显式标注**「WS 卡缺失 / REQ 表未记录」；
- **同一需求同一会话**：落卡 / 调整 / 拆解 / 确认都回到创建该需求的会话；面板创建的需求点「创建并细化」后同样满足；
- **已知限制**：`closed` 只读卡片里 `delivery.outcome` 的派生缓存、**不联网**；PR 状态的网络派生仍由 `node .dsh/tools/derive-status.mjs` 完成。

> 面板交互细节、状态转换矩阵与 API 契约见 `docs/usage/panels.md`（需求池面板）与 `docs/design/panels/requirements-pool-panel-design.md`。

## 4. 任务面板：操作说明

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

### 4.1 与事项的关系

| 维度 | 事项 WS | 队列 queue |
|---|---|---|
| 层级 | **追踪单元** | **执行载体** |
| 宿主 | `.dsh/workstreams/WS-*.md`（committed） | `.dsh/tasks/queues.json`（本机） |
| 基数 | 1 事项 : 0..N 队列 | 1 队列 : 0..1 事项 |
| 关联权威 | `WS.queues`（committed） | 队列内 `workstream` 是运行时镜像（可重建） |

### 4.2 三种工作区形状（提示词按形状出条目）

| 形状 | 行为 |
|---|---|
| 非 git 目录 | 不切分支、不 commit、不开 PR |
| git 仓库、无 GitHub 远端 | 有分支 / commit，无 PR 能力 |
| GitHub 仓库 | 全流程（分支 + commit + 交付会话开 PR） |

### 4.3 必须知道的三条语义

- **任务只 commit**；push 与 PR 由队列跑完后的一条**交付会话**执行，结果回写队列；
- **建任务 / 建队列 ≠ 开始干活**：只有「开始」或明确说「启动队列」才跑；
- 任务默认**60 分钟**超时；每个任务结束会**汇报回写**，队列下一棒据此知道上一棒做了什么。

## 5. 任务面板：内置技能 `task-todo`（任务拆分 / 实施 / 交付）

任务面板 / `task-todo` 是 **oh-my-dsh App 的能力**（spec §9），不是规范的一部分。**任务拆分、任务实施、交付这三步**由内置技能 `task-todo` 承接（App 启动时安装到 `$DSH_HOME/skills/task-todo/SKILL.md`）；不用技能时也可在面板里手点（§4）。

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

## 6. 交接提示词（把事项交给新会话）

模板见 `docs/design/panels/workstream-handoff-prompt-design.md`。最小可用形状：

```text
你在 oh-my-dsh 仓库工作。处理事项 WS-<id>「<标题>」。
先读：.dsh/workstreams/WS-<id>.md、.dsh/requirements/<REQ-ID>.md（通用规则见工作区 AGENTS.md）。
当前 stage：<stage>；本步动作：<action>。目标与边界以卡片「规划」为准。
规则：只拆不胀；终态是派生谓词（不写 closed/outcome/split）；
      回归门 <REG-ID>（若改动其覆盖路径，交付前跑）；不改其它会话的在途文件。
结束前停下问：规划确认 / 设计确认 / 拆分确认 / 验收 sign-off。不要自签。
```

## 7. 命令速查

```sh
# 终态派生（只读，不写卡片）
GH_TOKEN=$(cat "$HOME/.dsh/oh-my-dsh/tokens/<owner>-<repo>") node .dsh/tools/derive-status.mjs

# 回归门（共享路径改动后）
node .dsh/regression/check-architecture-model.mjs

# 分支与交付
git checkout -b feature/<slug>
git push https://github.com/<owner>/<repo>.git HEAD:refs/heads/feature/<slug>
```

## 8. 收尾自检清单

- [ ] 需求卡 / 事项卡的 `state` / `stage` 与事实一致（`split` / `closed` 不手写，由派生给出）；
- [ ] 人工状态按生命周期前进（候选 → 评估中 → 已评估；挂起 / 丢弃是旁路），没有回退；
- [ ] 范围外的新发现已回池为新需求，没有偷偷扩大事项；
- [ ] **拆解已由人在需求池面板「确认拆解」**（不是 agent 自签）；确认后需求已冻结、未再编辑；
- [ ] **设计已获人确认**；任务拆分（等待态队列）已获人确认合理，才启动；
- [ ] 验收有**可机检证据**，且有人 sign-off；
- [ ] `delivery.pr` 已记；`closed` / `outcome` **未被手写**；
- [ ] 交付前跑过适用的回归门；
- [ ] 没有改其它会话 / 事项的在途文件。

## 9. 常见坑

规则以 **spec §4（R1–R12）** 为准；这里只列最容易踩的几条。

| 坑 | 正确做法 |
|---|---|
| 手写 `closed` / `outcome` / `split` | 它们都是**派生**的；要状态就跑 `derive-status` |
| 把新发现并进当前事项 | **只拆不胀**：回池成新需求，另起事项 |
| 让 agent 自签验收 | 机检绿 ≠ 完成；**人 sign-off** 是 Own 点 |
| 让 agent 调 `breakdown/confirm` / 在面板之外建 `WS-*.md` | 拆解只走「agent `propose` → **人在需求池面板确认**」（R10）；手工建卡会绕过确认门与映射表 |
| 已拆解的需求还想改标题 / 诉求 | 已冻结（R5）：重开另起需求，不追溯改已确认的拆解 |
| 直改 `.dsh/tasks/*.json` | 走任务面板或 `/api/tasks/*`（面板是唯一写者） |
| 以为「建了队列」就是「开跑」 | 建 ≠ 启动；显式「启动」或点「开始」 |
| 需求还没落卡 / 拆解还没确认就动手改代码 | 需求阶段**只讨论、只澄清、只落卡**；实施的唯一入口是**已启动的任务队列**（spec R12） |
