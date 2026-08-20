---
name: issue-fix
description: 在当前会话中修复一个 GitHub issue（读 issue → 改代码 → 跑测试 → 提交推送 → 汇报）。Fix a GitHub issue in the current session (read issue → change code → run tests → commit & push → report).
modelInvocable: true
userInvocable: false
---

# issue-fix — 按 GitHub issue 完成修复并提交推送

面板（IssueRunner）为某个 issue 创建独立会话并加载本 skill 时使用。会话 cwd 是**主项目工作区**，当前 git 分支由面板提前切好：feature 类 issue 为 `feature/issue-<N>`，bug/其他为 `fix/issue-<N>`（按统一分支规范 `docs/git-workflow.md`）。

## 执行方式（强制）
- **在当前会话内直接执行，绝不新建顶层会话**（不得 session.create / fork）；确需并行探索时可使用 subagent（子会话，不影响顶层会话归属）；
- **仓库根**：当前会话工作目录（`pwd`）；当前分支必须是 `feature/issue-<N>` 或 `fix/issue-<N>`（以面板会话提示为准）——若不是，先 `git status` 确认，异常则停下汇报；
- 只改当前分支上的代码，**绝不触碰 main/其他分支**，不 `git checkout` 别的分支。

## 输入
会话提示语会给出 issue 的：编号 `<N>`、标题、标签、正文/复现步骤（如有）、验收要求（如有）。

## 流程
1. **理解 issue**：读给出的 issue 内容；不清楚的地方在代码里找依据，不臆测；
2. **定位与修改**：找到相关代码，做**最小**修改解决 issue；遵守仓库 `.dsh/wiki/conventions.md` 的工程约定（L10n 中英、不改 dsh 上游源码、面板 UI 约定等）；需要时先读 `.dsh/wiki/` 了解模块结构；
3. **本地验证**：按 issue 影响面跑相关测试：
   - 共享核心：`node --test core/tests/*.test.js`（node 用内置运行时：`Contents/Resources/runtime/node` 或 PATH 上的 node）；
   - macOS 壳：`tests/*/run.sh`（swiftc 可用时）；
   - 无法跑的（如缺工具链）明确说明，不假装通过；
4. **提交**：`git add` 相关文件 → `git commit -m "fix(#<N>): <标题简短>"`；一个 issue 一个 commit（或逻辑相关的少量 commit）。若修复关联 PR，commit 正文可附加 `Closes #<N>`（GitHub 在 PR 合并时自动关闭对应 issue），但**不要**在 commit 里写无关内容；
5. **推送**：先检测远端名（`git remote`；优先名为 `github`，其次 `origin`，否则第一个 remote），再 `git push -u <远端名> <当前分支名>`；
6. **汇报**：简短列出改动文件、测试结果、commit 号；PR 由面板创建，你**不负责开 PR**。

## 规则（强制）
1. 只做 issue 要求的最小改动；不顺手重构无关代码；
2. 不提交无关文件（`git status` 里与本次修复无关的变更不要 add）；
3. 不改动 `.env*`/密钥/口令相关文件，不提交敏感信息；
4. 测试失败必须停下说明，不得静默跳过；
5. 推送失败（无远端/权限）时停下汇报，不伪造成功；
6. **GitHub 写操作需 token**：推送私有仓库 / 需要认证的调用时，从 `~/.dsh/tokens/<owner>-<repo>` 或 `~/.dsh/gh-token` 读取（`cat` 即得），**绝不打印/回显 token 内容，绝不在对话、汇报、日志、commit message 中泄露 token**；公开仓库推送通常无需 token；
7. 汇报简短（几行），不粘贴大段正文。