# IssueRunner 任务面板设计

> 状态：✅ 已实现（v1.8.0+，方案 E：branch-based 串行队列）
> 更新：2026-08-16

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
  ├── dsh 会话：create(workspaceId) → rename("fix(#N): …") → prompt(issue-fix) → 轮询 → cancel
  └── 串行队列：一次一个 running，完成自动启动下一个 pending

core/lib/jobqueue.js —— 跨平台串行队列状态机（Node，纯逻辑，可单测）
core/lib/issues.js  —— GitHub REST 封装（Node，可单测）
.dsh/skills/issue-fix/SKILL.md —— 代理在任务会话中加载的执行指令
```

## 数据流（处理 issue #N）

1. 用户点「处理」（或「全部处理」）
2. `git checkout main` → `git pull --ff-only` → `git checkout -b fix/issue-N`
3. `session.create(workspaceId=主项目)` → `session.rename("fix(#N): 标题")`
4. `session.prompt`（queue 模式）注入 issue-fix skill + issue 内容
5. 轮询 `session.list` 中该会话 `running` → 结束后
6. `git ls-remote` 校验分支已推送 → `POST /pulls` 创建 PR（base=main, head=fix/issue-N）
7. 状态 → done(PR url)；`git checkout main`；队列自动下一项

## 状态模型（Job）

```ts
{ id, title, source: "github" | "remote",     // source = 远程驱动预留
  state: "pending" | "running" | "done" | "failed" | "cancelled",
  prUrl?, branch?, sessionId?, error?, log? }
```

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
