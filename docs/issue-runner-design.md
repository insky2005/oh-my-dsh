# 任务面板设计（IssueRunner / Tasks）

> 状态：**v1 已实现**（v1.8.0+，方案 E：branch-based 串行队列）；**v2 方案已定稿，待实现**（2026-09-24：手动任务 + 串行队列 + 卡片式 UI + token 仅文件）
> 更新：2026-09-24
> 关联：`docs/git-workflow.md`（分支规范）、`docs/ui-color-scheme.md`（配色令牌）、`docs/projects-panel-design.md`（卡片面板体例）、`docs/dsh-version-impact.md`（会话 RPC 耦合面）、`.dsh/wiki/modules/issue-runner-panel.md`

## 目标

让 oh-my-dsh 从「查看/操作工具」进化为「**由 issue 驱动的工作执行器**」：面板拉取当前工作区 GitHub 仓库的 open issues，用户逐个（或「全部处理」串行）让 dsh 代理完成「切分支 → 修复 → 测试 → 提交推送 → 开 PR」的闭环，且全程可追溯、互不干扰。

## 核心决策（方案 E：branch，不用 worktree）

> 决策过程见会话记录：worktree 方案在 dsh 上存在分组错乱（未注册 workspace 的会话前端按 cwd 归组）与生命周期清理负担；且实测「主 workspaceId + worktree cwd」混传会被 dsh 拒绝。方案 E 用 **git branch + 串行队列**，绕开全部问题：

| 决策点 | 选择 | 依据（实测） |
|---|---|---|
| 隔离方式 | git branch（非 worktree） | 串行队列与分支切换天然匹配；worktree 留待 dsh web 原生支持后迭代 |
| 会话创建 | `session.create(workspaceId=主项目)` | 单独传 workspaceId 即 ok，cwd 自动 = 主项目目录，归主 workspace（无分组错乱） |
| 代理工作目录 | 会话 cwd = 主项目，当前分支 | 标记文件实测只在目标分支所在目录落盘 |
| 可追溯 | 会话/分支/PR 全保留，不自动删 | `session.export`/`archive` 等 API 不存在，删除即丢失追溯 |
| 串行 | 严格串行（同一时间一个任务） | 「全部处理」自动依次入队 |

## 架构

```
IssueRunnerPanelController (macOS, Swift)
  ├── 任务列表（NSTableView）：issue 编号/标题/标签/状态徽标
  ├── 仓库识别：git remote → owner/repo（自动，工作区切换时）
  ├── GitHub REST：拉 issues（过滤 PR）/ 创建 PR（token 走 Keychain）
  ├── git 流水线（Process）：checkout main → pull → checkout -b fix/issue-N → 校验推送
  ├── dsh 会话：create(workspaceId) → rename("fix(#N): …") → prompt(issue-resolve) → 轮询 → cancel
  └── 串行队列：一次一个 running，完成自动启动下一个 pending

core/lib/jobqueue.js —— 跨平台串行队列状态机（Node，纯逻辑，可单测）
core/lib/issues.js  —— GitHub REST 封装（Node，可单测）
$DSH_HOME/skills/issue-resolve/SKILL.md —— 代理在任务会话中加载的执行指令（App 启动时安装到全局）
```

## 数据流（处理 issue #N）

1. 用户点「处理」（或「全部处理」）
2. `git checkout main` → `git pull --ff-only` → `git checkout -b fix/issue-N`
3. `session.create(workspaceId=主项目)` → `session.rename("fix(#N): 标题")`
4. `session.prompt`（queue 模式）注入 issue-resolve skill + issue 内容
5. 轮询 `session.list` 中该会话 `running` → 结束后
6. `git ls-remote` 校验分支已推送 → `POST /pulls` 创建 PR（base=main, head=fix/issue-N）
7. 状态 → done(PR url)；`git checkout main`；队列自动下一项

## 状态模型（Job）

```ts
{ id, title, source: "github" | "remote",     // source = 远程驱动预留
  state: "pending" | "running" | "done" | "failed" | "cancelled",
  prUrl?, branch?, sessionId?, error?, log? }
```

## 关联索引（issue ↔ branch ↔ session ↔ PR）

任务关联持久化在 `<repoRoot>/.dsh/tasks/`（随仓库提交，跨机器共享）：

- **`index.json`**（提交）：仓库级关联 `issue → branch → prUrl → state → startedAt/finishedAt/error`；
- **`local.json`**（gitignore）：本机级覆盖 `issue → sessionId`（dsh 会话 id 是本机实例特有的，不入共享索引）。

定位规则：
- **issue → branch**：`fix/issue-N`（或读 index.json）；
- **issue → session**：运行中读内存 `task.sessionId`；重启后读 `local.json`；
- **issue → PR**：读 index.json `prUrl`；
- **恢复**：App 重启后面板按 index.json + local.json 重建任务列表与关联（`restoreFromIndex`），再以 open issues 刷新标题；
- **实现**：`core/lib/tasks.js`（Node，可单测）+ `IssueRunnerPanel.swift` 的 `TaskIndex`（Swift，结构一致）。

## 远程驱动预留（钉钉/微信，本里程碑不实现）

- `source` 字段即任务来源标识；`core/lib/jobqueue.js` 是任务队列的统一后端；
- 未来「钉钉群/微信」驱动 = 一个 JobSource 适配器：接收消息 → 解析为 Job（含 issue 编号或自描述任务）→ `enqueue` → 同一队列串行执行；
- 接入点（计划）：App 内建消息接收（webhook/长连接）→ 构造 Job → 队列；面板 UI 无需改动（只订阅快照）；
- 详见「远程驱动」章节（待实现时补充）。

## 边界情况与失败处理

| 场景 | 行为 |
|---|---|
| 工作区非 GitHub 仓库 | 面板空态「当前工作区不是 GitHub 仓库」 |
| 公开仓库 | 匿名读 issues（60 req/h 限流）；私有需 token（Keychain） |
| 分支已存在 | `git checkout -b` 失败 → 提示「分支已存在」，可续跑 |
| 代理会话失败/超时（30min） | 标记失败，分支+会话保留（可追溯），可「继续新会话」 |
| 分支未推送 | 标记「分支未推送」（代理未 push），可重试 |
| PR 创建失败 | 标记失败 + 显示错误；分支已在远端，可手动开 PR |
| App 退出 | 分支/会话/PR 全保留；下次启动按 git 分支恢复队列状态 |
| 取消 | `session.cancel` + 标记 cancelled；分支保留由用户处理 |

## 测试与验收

- `node --test core/tests/issues.test.js core/tests/jobqueue.test.js` 全绿（CI 自动跑）；
- `swiftc` 编译检查（含新文件）；`build-app.sh` 构建通过；
- 手动 QA：见下节。

### 手动 QA 清单

- [ ] 打开任务面板（活动栏「任务」/ ⌥⌘J）→ 自动识别当前仓库 → 列出 open issues；
- [ ] 点某 issue「处理」→ 主项目出现 `fix/issue-N` 分支 → dsh web 左侧出现命名会话 → 代理执行 → 结束后 PR 出现在 GitHub；
- [ ] 同时点两个 issue → 第二个排队，第一个完成才启动；
- [ ] 处理中取消 → 会话被 cancel、状态 cancelled；
- [ ] 失败（如分支冲突）→ 状态 failed、有错误提示；
- [ ] 工作区切换 → 面板自动重识别仓库并刷新列表。

## 迭代预留

- **worktree**：等 dsh web 原生支持 worktree 后，把「切分支」步骤替换为「worktree + workspace.create + 任务结束清理」，队列与监控逻辑不变（`docs/` 本文件同步更新）；
- **远程驱动**：JobSource 适配器（钉钉/微信）；
- **token 管理**：多仓库多 token、Keychain 按仓库作用域。

---

## V2 方案（2026-09-24 定稿，待实现）

> 本章是本次迭代（分支 `feature/tasks-manual-queue`）的落地依据：**GitHub token 只从文件读取** + **手动创建任务** + **任务队列（可入队 / 随时移出）** + **卡片式任务清单**。上文 v1 章节保留作历史决策记录。

### V2-0 总览

```
IssueRunnerPanelController（保留文件名与类名，UI 层重写）
  ├── TaskStore      统一任务模型 + .dsh/tasks 读写（index.json / manual.json / local.json）
  ├── TaskQueue      串行队列模型（入队 / 移出 / 队首 / 顺序持久化 / 重新入队）
  ├── QueueRunner    队列运行器（空闲 → 启动队首 → 轮询会话 → 结束 → 下一个）
  ├── TaskCardView   单张任务卡片（来源徽标 + 状态徽标 + 元信息 + 操作行 + 可展开详情）
  └── GitHubToken    仅文件解析（tokens/<owner>-<repo> → gh-token）
```

三条需求的改动面：

| # | 需求 | 主要改动面 |
|---|---|---|
| 1 | 移除钥匙串读写 GitHub token，只从文件读取 | `IssueRunnerPanel.swift`（token 一节）、`main.swift` 的 L10n 文案、README / wiki |
| 2 | 手动创建任务 + 队列（入队 / 随时移出） | 任务模型、`.dsh/tasks/*` 持久化、队列运行器、新建任务表单 |
| 3 | 任务清单改卡片样式、优化交互 | `IssueRunnerPanel.swift` UI 层（NSTableView → NSScrollView + NSStackView 卡片）、L10n |

### V2-1 GitHub token：只从文件读取

**现状（本次删除）**：`readKeychain(service:)`、`saveToken` 里的 `SecItemAdd` / `SecItemDelete`、`loadToken` 的第 ③④ 级 Keychain 回退，以及 `genericTokenService` / `tokenService(for:)` 两个 service 名常量。改完 `platforms/macos/src/` 下不应再出现 `SecItem` / `kSecClass`。

**改后的解析顺序（只剩文件两级）**：

1. 文件专属：`$DSH_HOME/tokens/<owner>-<repo>`（默认 `~/.dsh/tokens/<owner>-<repo>`）；
2. 文件通用：`$DSH_HOME/gh-token`（App 与外部工具 / 代理共用同一份）。

**保存**：写文件专属（原子写 + `chmod 600`）；输入留空 = 删除该文件。**不再写钥匙串**，面板提示同步改为文件口径。

**兼容性**：自 `88f0255` 起面板保存 token 就是「文件 + 钥匙串双写」，凡是通过面板保存过的 token 早已在文件里，本次改动**不会让绝大多数用户重填**；只有更老构建（或手工 `security add-generic-password`）写进钥匙串的条目不再被读取 —— 面板文案与 README / wiki 明确写「钥匙串里的旧 token 不再使用，请重新填写一次」。

**验收**：全仓库 grep 无 `SecItem` / `kSecClass`；文件存在时私有 issue 拉取、开 PR、评论关闭均正常；删掉专属文件后回落到通用文件；输入留空时专属文件被删除；`tests/tasks-panel` 覆盖三级解析。

### V2-2 统一任务模型

```swift
struct TaskItem {
    enum Source: String { case github, manual }      // 来源标记 → 卡片徽标
    enum State: String {
        case pending, queued, running, done, failed, cancelled, closed
    }
    var id: String            // github: issue-<N>；manual: manual-<8 位随机>
    var source: Source
    var number: Int?          // 仅 github 任务有 issue 号
    var title: String
    var body: String?         // issue 正文 / 手动任务的描述（提示词正文）
    var labels: [String]
    var state: State
    var branch: String?       // github 自动 feature|fix/issue-N；manual 可空
    var baseBranch: String    // 默认 main
    var createPR: Bool        // 手动任务专用：完成后是否校验推送并开 PR
    var prUrl: String?
    var sessionId: String?
    var error: String?
    var queuedAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var order: Int            // 队列内序号（卡片显示「队列中 #2」）
}
```

**状态语义**（与 v1 的关键差别：新增 `queued`，且 `pending` 不再被隐式自动执行）：

| 状态 | 含义 | 卡片主操作 |
|---|---|---|
| pending | 待处理，**不在队列** | 加入队列（空闲时即开始） |
| queued | 已入队，等待前一个任务结束 | 移出队列（随时可点） |
| running | 正在执行（同一时刻仅一个） | 取消 |
| done | 完成，有 PR 时展示链接 | 打开 PR / 评论并关闭（仅 github） |
| failed | 失败（分支与会话保留，可追溯） | 重试（= 重新入队） |
| cancelled | 已取消 | 重试 |
| closed | issue 已关闭（仅 github） | 打开 Issue |

**id 规则**：github 任务沿用 `issue-<N>`（旧索引可直接映射，历史数据零迁移）；手动任务 `manual-<uuid 前 8 位>`，冲突时重新生成。

### V2-3 持久化布局（`.dsh/tasks/`）

| 文件 | 作用域 | 内容 |
|---|---|---|
| `index.json` | 提交（**结构不变**，`version: 1`） | github 任务：issue → branch / prUrl / state / title / body / labels / 时间戳；写入时补 `source: github`（读侧缺省按 github，向后兼容） |
| `manual.json` | **本机（新增，需加进 `.gitignore`）** | 手动任务全量：id → title / body / branch / createPR / state / 时间戳 |
| `local.json` | 本机（已 gitignore） | 沿用 `sessions`（issue → sessionId），新增 `queue: [id, …]`（FIFO 顺序）与 `runningTaskId`（退出时记一次，用于识别中断） |

**为什么手动任务与队列放本机文件**：手动任务是个人临时工作项（例：「把终端面板的滚动逻辑重构一下」），提交进仓库只会污染协作者的 diff；队列更是纯本地工作流状态。github 的 issue ↔ 分支 ↔ PR 关联索引**维持提交语义不变**（跨机器 / 跨同事可追溯），这是 v1 的既有价值，不因本次改动而改变。

`core/lib/tasks.js` 同步扩展（`loadManual` / `saveManual` / `mergeManual` / `removeManual` / `loadQueue` / `saveQueue`），保持 Node 与 Swift 双实现结构一致（沿用既有体例），并补 `core/tests/tasks.test.js` 用例。

### V2-4 队列

**语义**：严格串行（沿用 v1 方案 E —— 单工作树 + 分支切换，不能并行）。队列 = 按加入顺序等待执行的 id 列表，**一次只有一个 running**。

**操作**：

- **加入队列**：`pending → queued`，记 `queuedAt`，追加队尾；若当前无运行任务，立刻启动队首 —— 所以空闲时「加入队列」就等于「开始」，不需要用户在两个按钮之间做选择。重复入队幂等（已在队列中则不动）；
- **移出队列**（仅 queued）：从队列删除、`queued → pending`，卡片回到待处理；**运行中的任务不能靠移出队列取消**（那是「取消」，语义不同）；
- **全部加入队列**：工具栏按钮（取代 v1 的「全部处理」），把当前所有 pending 任务按列表顺序批量入队；
- **重试**（failed / cancelled）：`→ pending` 后重新入队（追加队尾）。

**运行器（QueueRunner）**：只有一个入口 `pump()` —— `runningTaskId == nil` 且队列非空时取队首、标 running、执行流水线；任务结束时（done / failed / cancelled）**再次 `pump()`**：一个任务失败**不阻塞**队列，失败原因留在卡片上（与 v1 `finishCurrentTask` 的既有行为一致）。队列空 → 状态条显示「队列空闲」。同一时刻只有一条轮询定时器（沿用 `pollTimer`）。

**重启恢复**：启动时读 `local.json.queue` 复原顺序，读 `manual.json` + `index.json` 复原任务本身。上次退出时状态为 `running` 的任务：**标记为已中断**（`failed` + 「上次运行被中断」错误文案，会话与分支保留），因为那个 dsh 会话已随进程结束 —— 这修掉了 v1 恢复后长期显示「运行中」的观感问题。恢复后**不自动开跑**：状态条提示「队列中有 N 个任务」，用户点工具栏「开始队列」（或队首卡片的开始）才继续，避免启动即消耗额度 / 擅自改动仓库。

### V2-5 手动创建任务

**入口**：工具栏「+」→ 新建任务表单（NSAlert + accessoryView，多字段，体例与「配置 GitHub Token」一致）。表单字段：

1. **标题**（必填）：卡片主行、会话名；
2. **描述 / 指令**（必填，多行 NSTextView）：即发给代理的提示词正文；
3. **分支**（可选）：默认由标题生成 `feature/<slug>`；留空 = 不切分支，在当前分支上执行；
4. **完成后创建 PR**（开关，默认开）：仅在「指定了分支」且「工作区是 GitHub 仓库」时可用；
5. **立即加入队列**（开关，默认开）。

**slug 规则**：标题转小写、非字母数字替换为 `-`、去首尾 `-`、截断 40 字符；与本地 / 远端已有分支冲突时追加 `-2`、`-3`。

**执行流水线**（与 github 任务复用同一套，差异如下）：

| 步骤 | github 任务 | 手动任务 |
|---|---|---|
| 切分支 | `checkout main → pull → checkout -b feature/issue-N 或 fix/issue-N` | 有分支：`checkout <base> → pull → checkout -b <slug>`；无分支：跳过 |
| 建会话 | `session.create(workspaceId)` + `session.rename(fix(#N): …)` | 同左，会话名 = 任务标题 |
| 提示词 | issue-resolve skill + issue 正文 | **通用提示词**：工作目录与分支、任务描述、要求（改代码 → 跑测试 → commit → push）、token 文件位置说明（需要 GitHub 写操作时）；不复用 issue-resolve skill |
| 收尾 | 校验分支已推送 → 开 PR → done(PR url) | 仅当 createPR 打开才校验推送并开 PR；否则直接 done |
| 评论并关闭 | 有（done 且有 PR 时） | **无**（没有 issue 可关） |

**非 GitHub 工作区**：手动任务**仍然可用**（不依赖 issue 拉取），但「创建 PR」开关禁用、卡片不显示 PR 相关操作；issue 区维持原有空态「当前工作区不是 GitHub 仓库」（文案改为只针对 issue 区）。前提依然是工作区是一个 git 目录（否则没有分支可切、也没有会话 cwd）：非 git 目录时「+」置灰并在状态条说明。

### V2-6 卡片式任务清单

把 `NSTableView` 换成 `NSScrollView + NSStackView` 卡片列表，体例直接照 `ProjectsPanel.swift`：`render()` 重建 `arrangedSubviews`，每张卡片 `widthAnchor == list.widthAnchor - 20`，卡片自身 `draw(_:)` 画圆角 + 描边、`hitTest` 把非按钮区域的点击交回卡片、`resetCursorRects` 设 `pointingHand`。

```
┌────────────────────────────────────────────────┐
│ [Issue #12]  [队列中 #2]           ⟳   ⊖       │  ← 来源徽标 + 状态徽标 + 行内图标操作（hover）
│ 修复暗色模式下终端面板标题看不清                  │  ← 标题（semibold，最多 2 行截断）
│ bug · fix/issue-12 · PR #20                    │  ← 元信息（标签 / 分支 / PR / 会话，可点）
│ [处理] [移出队列] [评论并关闭 Issue]              │  ← 主操作行（展开后显示）
│ ┌ 详情：正文 / 分支 / PR / 会话 / 错误 ─────────┐  │  ← 点卡片 = 展开 / 收起（v1 手感保留）
│ └───────────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

- **来源徽标**：`Issue #N`（accent 系）与 `手动`（另一色）—— 需求「创建的任务和 github issue 任务分开标记」的第一处落点；
- **状态徽标**：待处理 / 队列中 #n / 运行中（配小 spinner）/ 已完成 / 失败 / 已取消 / 已关闭；失败用 `systemRed`、完成用 `systemGreen`，沿用现有语义色约定；
- **交互**：点卡片任意非按钮区域 = 展开 / 收起详情（正文可滚动，长正文不挤走按钮，保留 v1 的 NSTextView 方案）；hover 时卡片底色提亮（`PanelControl.fill(dark:highlighted:)`）并显示行内图标按钮（入队 / 移出队列 / 取消 / 重试 / 打开 PR）；
- **无模态**：入队、移出队列、取消都在卡片上直接完成，结果回到底部状态条（成功 5s 自动清空、失败保留到下次操作），与项目面板一致；只有「评论并关闭 Issue」保留确认框（会改 GitHub 远端状态）；
- **分区与筛选**：列表按状态分区小标题 —— 运行中 / 队列中 / 待处理 / 已结束（默认折叠）；工具栏加来源筛选 `NSSegmentedControl`（全部 / Issue / 手动）—— 「分开标记」的第二处落点；
- **底部状态条保留**（加载中 / 队列 N 项 / 错误回显），compositing trap 的 `wantsLayer + masksToBounds` 写法不变。

**配色纪律**（见 `docs/ui-color-scheme.md`）：面板根 / header / toolbar / 状态条用 `DynamicFillView()`（`.panel`），卡片底与图标按钮用 `PanelControl.fill(dark:highlighted:)`，**不新写** `calibratedWhite` 灰阶；卡片在 `viewDidChangeEffectiveAppearance` 里重绘取色。

### V2-7 L10n（中英成对，`main.swift` 的 `L10n.table`）

修改：`tasks.configInfo`（去掉钥匙串措辞，改为「按当前仓库保存到文件」）。

新增（示意，实现时以 `L10n.table` 为准，`tests/l10n/run.sh` 会兜住漏配）：

- 来源与筛选：`tasks.source.github`、`tasks.source.manual`、`tasks.filter.all` / `.github` / `.manual`；
- 队列：`tasks.queue.add`、`tasks.queue.addAll`、`tasks.queue.remove`、`tasks.queue.start`、`tasks.queue.badge`、`tasks.queue.idle`、`tasks.queue.pendingCount`；
- 状态：`tasks.state.queued`、`tasks.state.interrupted`；
- 手动任务：`tasks.new.title`、`tasks.new.name`、`tasks.new.body`、`tasks.new.branch`、`tasks.new.createPR`、`tasks.new.enqueue`、`tasks.new.create`、`tasks.errName`、`tasks.errBody`、`tasks.prompt.*`（通用提示词模板）；
- 详情与错误：`tasks.detailSession`、`tasks.detailSource`、`tasks.errInterrupted`、`tasks.errNotGit`。

### V2-8 测试与 CI

新增 `tests/tasks-panel/`（无头，体例照 `tests/projects-panel/`：`stubs.swift` + `run.sh` + 若干 `*-tests.swift`）：

1. **模型与持久化**：TaskItem 编解码往返；`index.json` 旧格式兼容（无 `source` 视为 github、无 id 用 `issue-N`）；`manual.json` 增删改查；读坏文件不崩溃且不删文件；
2. **队列模型**：入队顺序、重复入队幂等、移出队列后回到 pending、队首推进、`order` 编号、失败不阻塞（下一个照常启动）、重启恢复（running → interrupted、队列顺序保留）；
3. **token 解析**：临时 `DSH_HOME` 下「专属文件 → 通用文件 → nil」三级；保存写文件且权限 `0600`；空值删文件；断言实现里不再有钥匙串路径；
4. **卡片视图模型**：给定 TaskItem → 断言标题、来源徽标文案、状态徽标、主操作标题与可用性（把现有 `primaryActionTitle` 一类纯函数抽出来覆盖 queued / interrupted / manual 新分支）。

同步：扩展 `core/tests/tasks.test.js`（manual.json + queue 读写）；把 `tests/tasks-panel/run.sh` **同时**登记进 `scripts/local-ci.sh` 的 `stage_swift` 与 `.github/workflows/ci.yml`（两处清单必须一致）。

QA 钩子：`DSH_TASKS_TEST=1` 启动即开面板；`DSH_PANEL_TEST=` 全量核对串里已含 `tasks`；`--ui-debug` 下 `setRightPanel` 落 `panel-tasks-debug.png`。

### V2-9 实施拆分（建议提交顺序）

1. `refactor(tasks): GitHub token 只从文件读取（移除 Keychain 读写）` —— token 一节 + L10n 文案 + README；
2. `feat(tasks): 统一任务模型与 .dsh/tasks 持久化（manual.json + 队列）` —— 含 `core/lib/tasks.js` 与单测；
3. `feat(tasks): 串行队列运行器（入队 / 移出 / 开始队列 / 失败不阻塞）`；
4. `feat(tasks): 手动创建任务（表单 + 通用提示词 + 可选分支与 PR）`；
5. `refactor(tasks): 任务清单改卡片式 UI（来源徽标 + 状态分区 + hover / 展开）`；
6. `test(tasks): tests/tasks-panel 无头套件 + CI 登记`，`docs: 本文档与 .dsh/wiki 同步`。

分支：`feature/tasks-manual-queue`（本仓库规范：不在 main 上开发，合并走 PR）。

### V2-10 风险与边界

| 风险 / 场景 | 处置 |
|---|---|
| 旧钥匙串里的 token 失效 | 面板文案 + README / wiki 写明「请重新填写一次」；面板保存一直是双写，绝大多数用户不受影响 |
| 工作区不是 git 目录 | 「+」置灰 + 状态条说明（没有分支可切、没有会话 cwd） |
| 工作区不是 GitHub 仓库 | 手动任务照常可用；PR 开关禁用、issue 区显示原有空态 |
| `index.json` 被外部写坏 | 读侧宽容（缺字段用缺省值、解析失败返回空索引，不删文件） |
| 队列与手动任务存本机文件，换机器 / 换 clone 会丢 | 设计取舍（个人工作项）；github 关联索引仍提交 |
| 50+ issue 时卡片列表性能 | NSStackView 全量重建与项目面板一致；实测无感，若变慢再引入可见区懒加载 |
| 单工作树不能并行 | 严格串行是设计前提（方案 E）；并行留给未来 worktree 迭代 |
| 恢复队列后误改仓库 | 恢复后不自动开跑，必须显式「开始队列」 |

### V2-11 待确认决策点

1. **手动任务持久化**：本机 `manual.json`（推荐，不污染仓库）还是提交进 `index.json`？
2. **队列顺序持久化**：本机 `local.json`（推荐）还是提交进 `index.json`？
3. **手动任务默认是否走「分支 + PR」**：默认开（推荐，与 issue 任务同一条流水线；表单里可关）还是默认只在当前分支执行？
4. **App 启动后队列是否自动继续**：默认不自动、需点「开始队列」（推荐）还是自动继续？
5. **卡片分区**：按状态分区（推荐）还是单一列表按编号 / 时间排序？
6. **命名**：保留 `IssueRunnerPanel.swift` / 类名（推荐，减少无谓 churn）还是更名 `TasksPanel.swift` / `TaskItem`？
