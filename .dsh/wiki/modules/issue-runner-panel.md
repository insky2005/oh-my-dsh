---
title: 模块：任务面板（IssueRunner）
tags: [module, tasks, github, issue, queue, index]
updated: 2026-08-16T16:02:38Z
sources: [platforms/macos/src/IssueRunnerPanel.swift, core/lib/issues.js, core/lib/jobqueue.js, core/lib/tasks.js, core/tests/issues.test.js, .dsh/skills/issue-fix/SKILL.md, docs/issue-runner-design.md, docs/git-workflow.md]
manual: false
---

# 模块：任务面板（IssueRunner）

## 一句话

由 GitHub issue 驱动的工作面板：识别当前工作区仓库 → 列出 open issues → 单击行**行内展开详情**（手风琴：状态/标签/分支/PR/错误 + issue 正文，滚动区 + 固定底部按钮），点明确按钮「处理」（或「全部处理」串行）→ 自动「切分支 → dsh 会话 → issue-fix skill 修复 → 推送 → 开 PR」，全程串行、可追溯、重启可恢复。

## 方案要点（方案 E：branch-based 串行队列）

- **不用 worktree**：worktree 在 dsh 上分组错乱（未注册 workspace 的会话前端按 cwd 归组）且生命周期清理负担重；用 git branch + 严格串行队列绕开（见 `docs/issue-runner-design.md` 决策记录）；
- **会话创建**：`session.create(workspaceId=主项目)` 单独传 workspaceId 即 ok，cwd 自动 = 主项目目录（实测），归主 workspace 无错乱；
- **可追溯**：会话/分支/PR 全保留不自动删；会话改名 `fix(#N): …` 便于 dsh web 左侧辨识；
- **worktree 迭代预留**：等 dsh web 原生支持后切换，队列与监控逻辑不变。

## 关键实现

- `IssueRunnerPanelController`（`platforms/macos/src/IssueRunnerPanel.swift`，约 1400 行）：
  - UI：header（标题 + 刷新/全部处理/配置/关闭按钮）+ toolbar（仓库名）+ 任务 NSTableView + 底部状态条（compositing trap 同 wiki/terminal 面板：opaque 底条需 wantsLayer+masksToBounds）；
  - **交互（c852894 起，替代 bafa12e 的 NSAlert 弹窗）**：单击行 = **行内展开/收起详情**（`expandedIssue` 记录展开的 issue；`heightOfRow` 展开行 168pt / 普通行 22pt），展开区是 **NSScrollView 内可滚动 NSTextView**（4576dd2：正文不再截断、滚动查看全部，按钮固定底部不被长正文挤出）+ 单元格内明确按钮——primary（pending→Process / running→Cancel Task / done→Open PR / failed、cancelled→Retry）+ Close + 「评论并关闭 Issue」；按钮带 tag（200/201/202），`cell.objectValue` 携带 issue 号；串行约束：另一任务运行时 Process/Retry 禁用（`runningNumber != nil`）；杜绝误触发（选中即 `deselectAll`，动作只在按钮点击）；
  - **评论并关闭（63525e3，用户触发非自动）**：done 且有 PR 的任务展开区显示「评论并关闭 Issue」→ NSAlert 内嵌可编辑 NSTextView（预填 `tasks.commentTemplate`，含 PR 引用）→ 确认后 `commentAndCloseIssue`（POST `/issues/{n}/comments` + PATCH `/issues/{n}` state=closed，需 token）→ 成功记日志并 `reloadIssues`（关闭的 issue 从列表消失），失败状态条提示（3s 后消失）；
  - **仓库识别（b7c5407 兜底）**：优先 `workspacePath`（活动项目目录）；为空时 `listWorkspacePaths(port:)` 从 dsh `workspace.list` 取路径，逐个 `detectGitHubRemote`，都不是则 1s 后重试（≤10 次，`repoResolveRetries`），修复启动早期误报 not a GitHub repo；成功后 `repoRootPath` 缓存，供索引写入与流水线使用；
  - issue 拉取：GitHub REST `/repos/{o}/{r}/issues?state=open`，**过滤 pull_request 条目**；cb13c97 起取 `body` 字段（issue 正文 markdown）供行内详情显示；公开仓库匿名，私有需 token（按仓库作用域解析，见下「GitHub token」）；
  - 任务流水线：`git checkout main → pull → checkout -b <分支>`（`branchForIssue`：按 label 判定——含 feature/enhancement 类 → `feature/issue-N`，否则 bug/其他 → `fix/issue-N`，统一分支规范 `docs/git-workflow.md`）→ `session.create(workspaceId)` → `session.rename` → `session.prompt`(issue-fix, queue) → 轮询 `session.list` running → 校验 `git ls-remote` 分支已推送 → `POST /pulls` 创建 PR（head=分支、base=main，与 git-workflow「feature/fix 回 main 一律走 PR」一致）→ 状态 done(PR url) → 切回 main → 队列下一项；分支推送检查用 `pushRemoteName`——按 **github > origin > 首个 remote** 解析远程名（修复硬编码 origin，与 `scripts/git-remote.sh` 同一规则）；
  - **关联索引**：`TaskIndex`（Swift）把 issue→branch/state/title/startedAt 写入 `.dsh/tasks/index.json`（`mergeTask`，随仓库提交；startTask 起记录 title，6d265a5），会话创建后 `rememberSession` 把 sessionId 写入 `local.json`（本机、gitignore），done/failed 时更新 prUrl/error/finishedAt；App 重启后 `restoreFromIndex(repoRoot:)` 按两文件重建任务列表与 session 关联（不覆盖内存中已存在的同 issue），再以 open issues 刷新——`reloadIssues` 对已存在任务**更新 title/labels/body**（不再跳过，恢复的任务标题不再显示占位符，6d265a5）；
  - 串行：`runningNumber` 非空时其他「处理」禁用；「全部处理」依次入队；完成自动启动下一个 pending；
  - 失败/取消：会话失败/超时（30min）/未推送/PR 失败各有明确状态与错误提示；取消调 `session.cancel`；
- `core/lib/issues.js`（Node）：`parseIssues`（过滤 PR、取 body）/`fetchIssues`/`createPullRequest`/`commentAndCloseIssue`（POST comments → 可选 PATCH close，分步报错 step: comment/close/comment-only）/`ghPatch`/`detectGitHubRemote`（git remote → owner/repo），零依赖（内置 https/child_process）；
- `core/lib/jobqueue.js`（Node）：串行队列状态机 `createQueue()`（enqueue/peek/markRunning/complete/fail/cancel/retry/snapshot/removeFinished），`source` 字段即远程驱动预留；
- `core/lib/tasks.js`（Node，37d27e8 新增，7 单测）：`.dsh/tasks/` 索引的纯 JSON I/O——`tasksDir`/`loadIndex`/`saveIndex`/`mergeTask`/`findTask`/`rememberSession`/`sessionForIssue`/`allLocalSessions`，与 Swift `TaskIndex` 结构一致（双实现，供未来平台复用）；
- `.dsh/skills/issue-fix/SKILL.md`：代理任务会话加载的指令（读 issue → 改代码 → 跑测试 → commit `fix(#N): …` → push → 汇报；禁止新开顶层会话/改其他分支）；当前分支须为面板切好的 `feature/issue-N` 或 `fix/issue-N`（统一分支规范 `docs/git-workflow.md`），push 前先检测远端名（github > origin > 首个 remote）；commit 正文可附 `Closes #<N>`（PR 合并时自动关闭对应 issue，仅当修复关联 PR，63525e3 补充）。

## GitHub token（按仓库作用域）

- **解析优先级**（`loadToken(for:)`）：① Keychain 专属（service `oh-my-dsh.issuerunner.github-token.<owner>/<repo>`）→ ② 文件专属 `~/.dsh/tokens/<owner>-<repo>` → ③ Keychain 通用（`oh-my-dsh.issuerunner.github-token`，旧版单 token）→ ④ 文件通用 `~/.dsh/gh-token`（App 与外部工具/代理共用同一份）；多工作区各用各的 token；
- **保存（双写，`saveToken(for:)`）**：面板「配置 GitHub Token」确认后**同时写** Keychain 专属条目和文件专属 `~/.dsh/tokens/<owner>-<repo>`（`chmod 600`，原子写）——外部工具/代理读同一文件即可用同一 token；清空（空值）时**双清**（删 Keychain 条目 + 删文件）；
- 不落 UserDefaults 明文；公开仓库无需 token；token 仅用于拉取 issues、创建 PR、评论关闭 issue。

## 集成点（main.swift）

- `RightPanel` 增加 `case tasks`；活动栏第 4 按钮（symbol `checkmark.circle`，tooltip 「任务/Tasks」）；
- 「视图」菜单「显示/隐藏 任务面板」`⌥⌘J`；`rightPanelKind` 持久化 `"tasks"`；
- `tasksPanel.workspacePath` 由 AppDelegate 提供（跟随 `ProjectDirectory.current`，即用户当前查看的会话目录；为空时面板自回退 workspace.list，见上）；
- `serverReady(port:)` 时通知面板做仓库识别 + issue 加载；
- 编译清单：`build-app.sh` 的 `SWIFT_SOURCES` 登记 `IssueRunnerPanel.swift`；
- L10n：`bar.tasks` / `menu.toggleTasks` / `tasks.*` 一组双语键；详情文本键 `tasks.detailTitle`/`detailLabels`/`detailBranch`/`detailPR`/`detailState`、`tasks.state.{pending,running,done,failed,cancelled}` 沿用；按钮键 `tasks.detailProcess`/`detailOpenPR`/`detailRetry`/`detailCancelTask`/`detailClose`；63525e3 新增评论并关闭一组：`tasks.detailCommentClose`/`commentCloseTitle`/`commentCloseInfo`/`commentCloseDone`/`commentCloseFailed`/`commentTemplate`。

## 边界与失败处理

| 场景 | 行为 |
|---|---|
| 工作区非 GitHub 仓库 | 空态「当前工作区不是 GitHub 仓库」；启动早期 workspace 未就绪 → 自动重试（≤10 次 × 1s） |
| 公开仓库 | 匿名读（限流 60/h）；私有需 token（按仓库作用域解析：Keychain 专属 → 文件专属 → Keychain 通用 → ~/.dsh/gh-token） |
| 分支已存在 | 提示「分支已存在」，可续跑 |
| 会话失败/超时（30min） | 标记 failed（index.json 写 state= failed + error），分支+会话保留，详情内可 Retry |
| 分支未推送 | 标记「分支未推送」（按 pushRemoteName 解析的 remote 检查），可重试 |
| PR 创建失败 | 标记 failed + 错误信息；分支在远端可手动开 PR |
| 评论并关闭失败 | 需 token；失败提示「评论/关闭失败（检查 token 与网络）」，不自动重试 |
| App 退出/重启 | 分支/会话/PR 全保留；重启后 `restoreFromIndex` 按 `.dsh/tasks/` 重建列表与关联 |

## 测试

- `core/tests/issues.test.js`（8 用例）：parseIssues 过滤 PR、body 断言、detectGitHubRemote（本仓库实测 owner/repo + https 形式）、commentAndCloseIssue 网络错误路径（ok:false 不崩溃）；
- `core/tests/jobqueue.test.js`：串行/失败/重试/取消/快照/清理；
- `core/tests/tasks.test.js`（37d27e8 新增）：tasksDir 建目录、loadIndex 缺省空索引、mergeTask 按 issue upsert + 排序、findTask 未知 issue、local overlay 记/查 session、index/local 两文件隔离、save/load 往返；
- CI：`node --test core/tests/*.test.js` 自动跑；Swift 面板编译检查。
