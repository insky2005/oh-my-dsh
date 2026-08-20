# Git 分支与发布流程（统一规范）

> 状态：✅ 生效（2026-08-16 起）
> 目标：统一「功能开发 / bug 修复 / 版本发布」的分支与 tag 规范，避免
>   「在 main 上直接打 patch tag」导致修复版本混入未发布功能。

## 核心模型：main 只合并，只打主版本

```
main（唯一稳定主干）────────── 只接受合并；只打主版本 vX.Y.0；永远可发布
  │
  ├── feature/<slug>   功能分支：从 main 切 → 开发 → PR 合并回 main → 随主版本发布
  │
  └── fix/<slug>       bug 修复分支（两种场景，见下）
```

### 角色

| 分支 | 用途 | 谁打 tag | 打什么 tag |
|---|---|---|---|
| `main` | 稳定主干，唯一集成分支 | 维护者 | **主版本** `vX.Y.0` |
| `feature/<slug>` | 新功能 / 重构 | 不直接打 | —（合并回 main 后随主版本发） |
| `fix/<slug>` | bug 修复（未发布） | 不直接打 | —（合并回 main 后随主版本发） |
| `release/1.9.x` | 已发布版本的维护线 | 维护者 | **patch** `v1.9.1`、`v1.9.2`… |

## 规则（强制）

### 1. main 只合并，只打主版本
- 禁止在 main 上直接提交功能/修复代码（维护者操作例外：版本号 fallback 推进、文档）；
- 禁止在 main 上打 patch tag（`v1.9.1`）——patch 版本必须从 release 分支打；
- main 上的代码**始终可构建、CI 始终绿**（合并前验证）。

### 2. 功能开发必须走分支
```
git checkout main && git pull
git checkout -b feature/<slug>     # 如 feature/issue-runner
# …开发、本地测试、提交（conventional commits）…
git push -u origin feature/<slug>  # 开 PR → CI 绿 → 合并回 main
```
合并回 main 后，功能随**下一个主版本**（`vX.Y.0`）发布；fallback 版本号即该主版本。

### 3. bug 修复必须走分支（两种场景）

**场景 A：bug 针对未发布代码（main 上发现）**
```
git checkout main && git pull
git checkout -b fix/<slug>         # 如 fix/issue-6-title
# …修复、测试…
git push -u origin fix/<slug>      # PR → 合并回 main → 随主版本一起发布（无需单独 patch 版本）
```

**场景 B：bug 针对已发布版本（如 v1.9.0 用户在用）**
```
# 1. 从该版本 tag 切维护分支（如 1.9.x 还在支持期）
git checkout -b release/1.9.x v1.9.0
# 2. 修复 + 测试
# 3. 打 patch tag 并发布（独立发布线，只含修复，不含 1.10.0 功能）
git commit -m "fix(…): …"
git tag -a v1.9.1 -m "oh-my-dsh v1.9.1"
git push origin release/1.9.x v1.9.1      # release.yml 自动发布 v1.9.1
# 4. 修复同步回主干 —— 走 PR（不直接 push main）：
#    a. 把修复 commit 带到 main 上的一个新 fix 分支（或从 main 切分支再 cherry-pick）
git checkout main && git pull
git checkout -b fix/sync-1.9.1 main
git cherry-pick <修复commit>
git push -u origin fix/sync-1.9.1
#    b. 开 PR：fix/sync-1.9.1 → main，CI 绿 + review 后合并
#    （保证 main 的每次前进都经过 PR 审查，不绕过 review 直接 push）
```

### 4. 版本号规则
- **主版本** `vX.Y.0`：从 main 打 tag → release.yml 发布全平台产物；
- **patch 版本** `vX.Y.Z`（Z ≥ 1）：从 `release/X.Y` 分支打 tag → 只含修复，**绝不混入未发布功能**；
- `scripts/version.sh` 的 `FALLBACK_VERSION` 始终指向「下一个主版本」（发布后立即推进）；
- 支持策略：维护最近 2 个大版本（如 1.9.x / 1.10.x），更旧的支持线在次新主版本稳定后清理。

## 合并规则（强制）

- **feature / fix 分支回 main，一律走 PR**：推送分支 → 开 PR → CI 全绿 + review → 合并；禁止直接 `git push origin main`；
- **PR 合并一律用 --no-ff（merge commit）**：
  - 保留分支上每个原始提交与合并拓扑，便于追溯「这个改动来自哪个分支、拆成哪些提交」；
  - 对比 squash 合并（压成单条、丢失原始提交与分支拓扑）：squash 只适合「单提交、自包含、无需追溯」的场景，默认不用；
  - GitHub 网页合并选 **Create a merge commit**（不要选 Squash and merge）；命令行 `git merge --no-ff <branch>`；
- **已发布版本的修复同步回 main**：也走 PR（见场景 B 第 4 步），不直接 push main；
- 面板（IssueRunner）处理 issue 后自动开 PR（`createPR`：head=分支，base=main），与上述规则一致；
- 唯一允许直接操作 main 的场景：维护者推进 fallback 版本号、紧急文档修正、发布打 tag（tag 打 main 本身）。

## 判断速查

| 情况 | 走哪条路 |
|---|---|
| 新功能 / 重构 | `feature/<slug>` → PR 合并 main → 随主版本发 |
| main 上发现 bug（未发布） | `fix/<slug>` → PR 合并 main → 随主版本发 |
| 已发布版本（1.9.0）有 bug | `release/1.9.x` → 打 `v1.9.1` 发布 → **PR** 把修复合并回 main |
| 发布主版本 | main 上打 `vX.Y.0` tag |
| 发布修复版本 | release 分支上打 `vX.Y.Z` tag |

## 与 CI/CD 的衔接

- `release.yml` 监听 `v*` tag：主版本 tag 和 patch tag 都会触发，产物命名含版本号自动区分；
- 任意分支 PR 都跑 CI（push/PR 触发）；
- 合并回 main 前 CI 必须全绿。

## 维护示例（完整走一遍「修 1.9.0 的 bug」）

```bash
# 1. 切维护分支（基于已发布的 v1.9.0，不含任何 1.10.0 内容）
git checkout -b release/1.9.x v1.9.0

# 2. 修复
# …改代码…
git add -A && git commit -m "fix(terminal): 修复 X 问题"

# 3. 发布 patch 版本
git tag -a v1.9.1 -m "oh-my-dsh v1.9.1"
git push origin release/1.9.x
git push origin v1.9.1        # 触发 release.yml → 发布 v1.9.1

# 4. 同步回主干
git checkout main && git pull
git cherry-pick <修复commit>
git push origin main
```
