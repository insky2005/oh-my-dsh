# 发布流程（Release Process）

> 状态：✅ 生效（2026-08-21 起，v1.11.0 实战校准）
> 目标：把「从主干发布一个新版本」固化为可照抄的步骤，与 `docs/git-workflow.md`、
>   `scripts/local-release.sh`、`scripts/version.sh`、`scripts/changelog.sh` 对齐。
> 适用：主版本 `vX.Y.0`（main 打 tag）；patch 版本从 `release/X.Y` 分支发布，流程一致。

## 前置

- 在 `main` 上，工作区干净，`github/main` 与本地同步；
- 已确定下一个版本号：`scripts/version.sh` 的 `FALLBACK_VERSION` 即「下一个主版本」；
- 已装 Xcode Command Line Tools（swiftc / pkgbuild / hdiutil / curl / python3）；
- 发布需写权限：`GH_TOKEN`（`~/.dsh/tokens/<owner>-<repo>`；当前统一走 curl API，暂不使用 `gh` CLI）。

## 4 步总览

```
1. 更新发布文档：CHANGELOG.md（必须用 scripts/changelog.sh）+ 检查 README/CONTRIBUTING 覆盖本次内容 + 主版本时 SECURITY.md ## Supported Versions → commit
2. 打 tag vX.Y.Z + git push
3. scripts/local-release.sh arm64 x86_64 构建并发布 GitHub Release
4. 推进版本号（version.sh FALLBACK + CHANGELOG [Unreleased] 占位）→ commit + push
```

### 步骤 1：更新发布文档（CHANGELOG + README/CONTRIBUTING 检查 + 主版本时 SECURITY）

1. 用 `scripts/changelog.sh <上个tag>` 生成「未发布改动」原始清单（按 conventional commit 类型分组）：
   ```bash
   scripts/changelog.sh v1.10.0     # 输出 v1.10.0..HEAD 的提交
   ```
2. 把产出**整理（curate）**进 CHANGELOG 顶部 `## [Unreleased]` 段，遵循仓库既有风格：
   - 分组：`### Added` / `### Changed` / `### Fixed` / `### Docs`；
   - 每条用 **加粗主题词** + 详细描述（参考 `[1.10.0]`/`[1.11.0]` 段写法），**不要照抄提交标题**；
   - 覆盖该版本全部实质改动（用 changelog.sh 清单交叉核对，勿漏）。
3. **检查 `README.md` / `CONTRIBUTING.md` 是否覆盖本次发布内容**（防止遗漏；主版本必做，patch 按改动范围判断）：
   - README：新增面板/特性 → 「右栏面板」小节 + 「特性一览」；新增构建变量/环境变量 → 对应章节；配图同步 `docs/screenshots/`；
   - CONTRIBUTING：新增模块/测试 → 「项目结构」+「运行测试」；新增 Swift 文件/面板 → 编译清单与测试套件说明；
   - 原则：**对外可见的发布内容必须有文档**；缺失则补写，随 changelog 一并提交。
4. **主版本（vX.Y.0）同步更新 `SECURITY.md` ## Supported Versions**（patch 版本 `vX.Y.Z` 支持表不变，跳过）：
   - 策略：维护**最近 2 个大版本**——新版本进表（`X.Y.x` ✅ Supported），最老一条出表，EOL 边界上移；
   - 示例：发布 v1.12.0 → 表为 `1.12.x` / `1.11.x`，`< 1.11` → End of life；
   - 版本号以 `git tag` 最新发布为准（开发线 `FALLBACK_VERSION` 未发布，不进表）。
5. commit（changelog + 文档检查补写 + security 同一次提交，保证 tag 指向完整发布文档）：
   ```bash
   git add CHANGELOG.md README.md CONTRIBUTING.md SECURITY.md
   git commit -m "docs(changelog): 发布 vX.Y.Z，[Unreleased] 转正"
   ```

### 步骤 2：打 tag + push

1. 在 `main`（已含 changelog 提交）上打 **annotated** tag：
   ```bash
   git tag -a vX.Y.Z -m "oh-my-dsh vX.Y.Z"
   ```
   ⚠️ tag 必须指向「包含 changelog/SECURITY 等发布文档的提交」——先改文档再打 tag，不要先打 tag 再补文档。
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

## 已知坑与规避（v1.12.0 实战校准）

- **tag 推送会触发 CI release.yml，而 CI 的 CEF prepare 当前是坏的**：`prepare` job 从
  `cef-builds.spotifycdn.com` 下载 CEF 在 GitHub runner 上超时失败（v1.11.0 / v1.12.0
  连续两代 Release run 都挂在「Pre-build CEF artifacts」），`publish release` job 被跳过。
  → 发布以**本地 local-release 为准**；CI 那次失败 run 直接忽略。**CI 的 CEF prepare
  暂不修复**（问题在 GitHub runner 侧，本地构建不受影响）。
- **上传约 1.1GB 资产在慢网下耗时 1–2h+，且脚本静默无进度**：资产按 pkg→dmg→
  SHA-256SUMS 顺序逐个上传。中途可用 API 观察进度（资产逐个出现）：
  `curl -s https://api.github.com/repos/insky2005/oh-my-dsh/releases/tags/vX.Y.Z`，
  看 `assets` 数组长度与每个资产的 `state`（uploaded = 完成）。
- **上传中断可安全重跑**：`github-publish.sh` 已幂等化——release 已存在则复用并只补传
  缺失资产（curl 兜底路径同样适用），无需手动删除半成品 release。
- **暂不使用 gh CLI，发布统一走 curl API 路径**：gh 分支保留为自动检测兜底（日志见
  `gh not found, publishing via curl API`），当前环境不安装 gh、不依赖 gh 路径。
- **DMG 构建必须 danger-full-access 沙箱**（见步骤 3）：hdiutil 需访问 `/dev`，
  workspace-write 下必失败（`Directory not empty` / `Operation not permitted`）。
- **CHANGELOG curate 需对照 `scripts/changelog.sh <上个tag>` 清单逐项打勾**：勿漏实质
  改动（v1.12.0 核对时曾主动跳过一条 minor 诊断日志条目——可接受，但需有意识）。

## 发布完成自检清单

- [ ] `github/main` 与本地一致；工作区干净
- [ ] 远端 tag `vX.Y.Z` 指向含 changelog/SECURITY 的提交
- [ ] `README.md` / `CONTRIBUTING.md` 已覆盖本次发布内容（新面板/特性/测试清单无遗漏）
- [ ] `SECURITY.md` ## Supported Versions 已更新（主版本发布；patch 版本跳过）
- [ ] GitHub Release `vX.Y.Z` 有 5 个资产：arm64/x86_64 的 `.pkg` + `.dmg` + `SHA-256SUMS`
- [ ] `scripts/version.sh` 输出下一个版本号 / 下一个 build
- [ ] CHANGELOG 顶部 `[Unreleased]` 占位已更新

## 参考

- `docs/git-workflow.md`：分支 / tag / PR 合并规范
- `scripts/local-release.sh`、`scripts/version.sh`、`scripts/changelog.sh`、`scripts/github-publish.sh`
- `.github/workflows/release.yml`（CI 打 tag 自动发布路径）