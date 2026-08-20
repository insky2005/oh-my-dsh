# 发布流程（Release Process）

> 状态：✅ 生效（2026-08-21 起，v1.11.0 实战校准）
> 目标：把「从主干发布一个新版本」固化为可照抄的步骤，与 `docs/git-workflow.md`、
>   `scripts/local-release.sh`、`scripts/version.sh`、`scripts/changelog.sh` 对齐。
> 适用：主版本 `vX.Y.0`（main 打 tag）；patch 版本从 `release/X.Y` 分支发布，流程一致。

## 前置

- 在 `main` 上，工作区干净，`github/main` 与本地同步；
- 已确定下一个版本号：`scripts/version.sh` 的 `FALLBACK_VERSION` 即「下一个主版本」；
- 已装 Xcode Command Line Tools（swiftc / pkgbuild / hdiutil / curl / python3）；
- 发布需写权限：`GH_TOKEN`（`~/.dsh/tokens/<owner>-<repo>`）或已登录 `gh` CLI。

## 4 步总览

```
1. 更新 CHANGELOG.md（必须用 scripts/changelog.sh）→ commit
2. 打 tag vX.Y.Z + git push
3. scripts/local-release.sh arm64 x86_64 构建并发布 GitHub Release
4. 推进版本号（version.sh FALLBACK + CHANGELOG [Unreleased] 占位）→ commit + push
```

### 步骤 1：更新 CHANGELOG.md（必须用 changelog.sh）

1. 用 `scripts/changelog.sh <上个tag>` 生成「未发布改动」原始清单（按 conventional commit 类型分组）：
   ```bash
   scripts/changelog.sh v1.10.0     # 输出 v1.10.0..HEAD 的提交
   ```
2. 把产出**整理（curate）**进 CHANGELOG 顶部 `## [Unreleased]` 段，遵循仓库既有风格：
   - 分组：`### Added` / `### Changed` / `### Fixed` / `### Docs`；
   - 每条用 **加粗主题词** + 详细描述（参考 `[1.10.0]`/`[1.11.0]` 段写法），**不要照抄提交标题**；
   - 覆盖该版本全部实质改动（用 changelog.sh 清单交叉核对，勿漏）。
3. commit：
   ```bash
   git add CHANGELOG.md
   git commit -m "docs(changelog): 发布 vX.Y.Z，[Unreleased] 转正"
   ```

### 步骤 2：打 tag + push

1. 在 `main`（已含 changelog 提交）上打 **annotated** tag：
   ```bash
   git tag -a vX.Y.Z -m "oh-my-dsh vX.Y.Z"
   ```
   ⚠️ tag 必须指向「包含 changelog 的提交」——先改 changelog 再打 tag，不要先打 tag 再补文档。
2. 推送：
   ```bash
   git push github main
   git push github vX.Y.Z          # 触发 release.yml（走 CI）或本地 local-release
   ```
3. `main` 受 GitHub 分支保护，**禁止 force-push**：发布流程不得改写已推送的 main 历史。

### 步骤 3：本地构建并发布（scripts/local-release.sh）

```bash
export GH_TOKEN="$(cat ~/.dsh/tokens/insky2005-oh-my-dsh)"   # 不打印/回显 token
export IS_PRERELEASE=1                                        # 默认预发布；正式版用 0
scripts/local-release.sh arm64 x86_64                          # 两架构 pkg+dmg
```

- 发布模式要求 **HEAD 恰在 vX.Y.Z tag 上**（版本单一来源 = git tag，不一致会阻断）——步骤 2 后满足；
- 产物：`dist/oh-my-dsh-<ver>-<arch>.pkg/.dmg` + `SHA-256SUMS`，自动上传到 GitHub Release；
- 发布优先用 `gh` CLI，缺 `gh` 时自动 fallback 到 curl API（需要 `GH_TOKEN`）。

**⚠️ 已知坑：DMG 构建在文件沙箱下失败**
- `make-pkg.sh` 的 DMG 步骤用 `hdiutil create -srcfolder`，需对 `/dev` 设备节点做 `newfs_apfs` 格式化；
- 在 DSH 文件沙箱（workspace-write）下报 `Operation not permitted` / `Directory not empty`（连空目录也失败），
  verbose 日志可见 `newfs_apfs: /dev/rdisk4s1: Operation not permitted`；
- **必须在 `danger-full-access` 沙箱权限下运行 local-release**（或完全脱离沙箱）才能生成 DMG；
- 只打包不发布用 `scripts/local-release.sh pack [arch...]`（跳过 checksums/publish）。

### 步骤 4：推进版本号

发布后立即把开发线推进到下一个版本（参考 `86eba72` 单提交惯例）：

1. 改 `scripts/version.sh`：
   ```bash
   FALLBACK_VERSION="${FALLBACK_VERSION:-1.12.0}"   # 上一版 + 1
   FALLBACK_BUILD="${FALLBACK_BUILD:-68}"           # 上一版 + 1
   ```
2. 改 CHANGELOG 顶部：新增/更新 `## [Unreleased]` 占位：
   ```markdown
   ## [Unreleased]

   - 暂无（v1.11.0 已发布；开发线已推进到 1.12.0）。
   ```
   （版本推进只在顶部 `[Unreleased]` 记占位，**不在已发布版本段加**「fallback 推进」Changed 条目。）
3. 提交 + 推送（合并成单个 commit，形如 `86eba72`）：
   ```bash
   git add scripts/version.sh CHANGELOG.md
   git commit -m "chore(version): fallback 推进到 1.12.0（v1.11.0 发布后的开发线版本）"
   git push github main
   ```

## 发布完成自检清单

- [ ] `github/main` 与本地一致；工作区干净
- [ ] 远端 tag `vX.Y.Z` 指向含 changelog 的提交
- [ ] GitHub Release `vX.Y.Z` 有 5 个资产：arm64/x86_64 的 `.pkg` + `.dmg` + `SHA-256SUMS`
- [ ] `scripts/version.sh` 输出下一个版本号 / 下一个 build
- [ ] CHANGELOG 顶部 `[Unreleased]` 占位已更新

## 参考

- `docs/git-workflow.md`：分支 / tag / PR 合并规范
- `scripts/local-release.sh`、`scripts/version.sh`、`scripts/changelog.sh`、`scripts/github-publish.sh`
- `.github/workflows/release.yml`（CI 打 tag 自动发布路径）
