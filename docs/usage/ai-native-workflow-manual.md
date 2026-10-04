# AI 原生工作流 · 手动模式使用说明（配合任务面板）

> 状态：草案 · 日期：2026-10-03 · 关联：`docs/research/ai-native-workflow-architecture.md`、`docs/design/panels/requirements-workstream-store-design.md`、`docs/design/panels/workstream-handoff-prompt-design.md`、`docs/usage/panels.md`、`.dsh/requirements/README.md`

## 0. 适用范围

在没有「需求池面板 / 拆解器」之前，用 **agent 读写 `.dsh` 卡片 + 任务面板跑执行** 组成的手动闭环。覆盖：**需求 → 拆解 → 事项（规划 → 设计 → 任务拆分 → 实施 → 验收 → 交付）→ 终态派生**。任务阶段的实际执行交给**任务面板**（`⌥⌘J`）。

前提：

- 在 oh-my-dsh 里工作；任务面板相关操作需要 App 在运行；
- 需求 / 事项状态在 `.dsh/requirements`、`.dsh/workstreams`（**随仓库提交**）；
- 终态由 `node .dsh/tools/derive-status.mjs` **派生**，不手写。

## 1. 闭环总览

```text
对话/想法 ─► 需求卡 REQ ──拆解(agent 出方案 / 人确认)──► 事项卡 WS
                                                          │ 规划(AC + 裁剪)
                                                          ◆ 人确认规划
                                                          ▼
                                                       设计
                                                          ◆ 人确认设计          ← 本页新增门
                                                          ▼
                                                     任务拆分(方案)
                                                          ◆ 人确认拆分合理       ← 本页新增门
                                                          ▼
                                                     落成队列 ▶ 启动实施
                                                          ▼
                                       验收(回归门 + 机检) ◆ 人 sign-off
                                                          ▼
                                       交付(PR) ◆ 人 merge ─► derive-status ─► closed(派生)

◆ = 人工确认门（agent 出方案 / 人 Own）
```

## 2. 手动模式：逐步 + 提示词示例

### 2.0 通用开头（每次交接都带上）

```text
你在 oh-my-dsh 仓库工作。先读事实来源，不要依赖转述：
- AGENTS.md                                         仓库约定（分支/提交/文档）
- docs/research/ai-native-workflow-architecture.md  模型
- docs/design/panels/requirements-workstream-store-design.md  .dsh 存储 schema
- docs/usage/ai-native-workflow-manual.md           本说明
```

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

### 2.5 任务拆分（出方案 → 人确认拆分）

```text
读 WS-<id> 的设计，提出任务拆分方案：每条任务 = 标题 + 给执行者的描述 + 顺序 / 依赖。
先只给方案，等我确认拆分是否合理；确认后再落成队列。
```

### 2.6 实施（确认拆分 → 落队列 → 启动）

```text
拆分已确认。用 task-todo 把任务落成队列，并启动；把队列 id 记到 WS-<id>.md 的 `queues`。
实施时：先切分支 feature/<slug>；只做边界内的事，范围外的新发现回池；
conventional commits；改到共享路径前先跑回归门。
```

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

入口：**`⌥⌘J`** / 活动栏「任务」。任务台 = **手动任务 + GitHub issue** 两种来源，**队列（泳道）** 串行执行。

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

## 4. 任务面板：提示词示例（`task-todo` 技能）

技能只在**你明确要求**时动手；默认**追加到本会话已有的队列**，没有才新建。

| 目的 | 这样说 |
|---|---|
| 把方案落成队列 + 任务 | 「把刚才讨论的方案拆成任务，建到任务面板」 |
| 启动队列 | 「启动队列」 |
| 交付已完成队列 | 「交付这个队列」 |
| 只要任务、不入队 | 「只建任务，先别入队」 |

> 技能经壳层 localhost API 写面板，**不直接改 `.dsh/tasks/*.json`**；App 没运行时它会报错而不是绕过。

## 5. 交接提示词（把事项交给新会话）

模板见 `docs/design/panels/workstream-handoff-prompt-design.md`。最小可用形状：

```text
你在 oh-my-dsh 仓库工作。处理事项 WS-<id>「<标题>」。
先读：.dsh/workstreams/WS-<id>.md、.dsh/requirements/<REQ-ID>.md、
      .dsh/requirements/README.md、docs/research/ai-native-workflow-architecture.md、AGENTS.md。
当前 stage：<stage>；本步动作：<action>。目标与边界以卡片「规划」为准。
规则：只拆不胀；终态是派生谓词（不写 closed/outcome/split）；
      回归门 <REG-ID>（若改动其覆盖路径，交付前跑）；不改其它会话的在途文件。
结束前停下问：规划确认 / 验收 sign-off。不要自签。
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
- [ ] **设计已获人确认**、**任务拆分已获人确认**，才落队列并启动；
- [ ] 验收有**可机检证据**，且有人 sign-off；
- [ ] `delivery.pr` 已记；`closed` / `outcome` **未被手写**；
- [ ] 交付前跑过适用的回归门；
- [ ] 没有改其它会话 / 事项的在途文件。

## 8. 常见坑

| 坑 | 正确做法 |
|---|---|
| 手写 `closed` / `outcome` / `split` | 它们都是**派生**的；要状态就跑 `derive-status` |
| 把新发现并进当前事项 | **只拆不胀**：回池成新需求，另起事项 |
| 让 agent 自签验收 | 机检绿 ≠ 完成；**人 sign-off** 是 Own 点 |
| 直改 `.dsh/tasks/*.json` | 走任务面板或 `/api/tasks/*`（面板是唯一写者） |
| 以为「建了队列」就是「开跑」 | 建 ≠ 启动；显式「启动」或点「开始」 |