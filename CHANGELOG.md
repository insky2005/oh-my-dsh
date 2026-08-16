# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions below
`v1.8.0` are summarized from the git history (conventional commits).

## [Unreleased]

- 暂无（v1.9.0 已发布；开发线已推进到 1.10.0）。

## [1.9.0] - 2026-08-16

### Added

- **IssueRunner 任务面板**（活动栏「任务 / Tasks」、⌥⌘J）：GitHub issue 驱动的串行任务流水线——
  - 仓库自动识别（git remote）+ open issues 拉取（REST，过滤 PR；私有仓库 Keychain token）；
  - 处理流程：切分支 `fix/issue-N` → 新建 dsh 会话（归主工作区）→ 会话改名可追溯 → issue-fix skill 修复 → 推送 → 开 PR；
  - 串行队列、行内展开详情（状态/标签/分支/PR/正文，滚动区 + 底部按钮）、取消/重试/打开 PR；
  - 完成后的 issue 支持「评论并关闭」（用户触发，POST comment + PATCH close）；
  - 任务关联索引落地 `.dsh/tasks/`（index.json 随仓库提交，local.json 本机 session 映射），重启可恢复；
  - 共享核心：`core/lib/issues.js`（issues/PR/comment-close/remote 检测）、`core/lib/jobqueue.js`（串行队列）、`core/lib/tasks.js`（关联索引）；
  - skill：`.dsh/skills/issue-fix/SKILL.md`。
- **Wiki 自动提交**：更新完成后由代理（repo-wiki skill 规则 8）`git add .dsh/wiki` + commit（不 push，message 概括实际变更）；面板 `WikiAutoCommit` 兜底。

### Changed

- 版本单一来源：`scripts/version.sh` fallback 推进到 1.9.0（发布后立即推进开发线版本，避免与已发布版本混淆）。

### Fixed

- IssueRunner：仓库识别兜底（workspace.list 解析）、gitBranchPushed 按 remote 名解析、恢复任务标题/正文显示、行内详情滚动与按钮固定。

## [1.8.0] - 2026-08-15

### Added

- 里程碑 M1（产品化基础，P1）全部交付（详见本里程碑文档 `docs/milestones/M1-productization-foundation.md`）：
  - 开源就绪：MIT LICENSE、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md、CODEOWNERS、AGENTS.md、Issue 模板（bug/feature）；
  - CI：`.github/workflows/ci.yml`（macOS arm64/x64/Universal 矩阵 + 单测 + swiftc 编译检查 + `.cache/` 缓存）、`nightly.yml`、dependabot；
  - 发布：`.github/workflows/release.yml`（tag 触发 → 构建 → `.dmg`/`.pkg` + SHA-256SUMS → GitHub Release）；
  - 版本单一来源：`build-app.sh` 的 VERSION/BUILD 由 git tag / CI 运行号驱动（`scripts/version.sh`）；
  - 共享核心 `core/`（Node 模块）：ANSI 模拟器（42 用例全绿）/ 端口与服务管理 / 升级 / 会话 RPC 从 Swift 抽出，`core/bin/ohmy-core.js` CLI；
  - 设置窗口（语言 / registry / 升级 / 主题 / 快捷键，⌘, 打开）与首次引导（onboarding）；
  - 平台骨架 `platforms/macos/` 迁移（src/ + build-app.sh + make-pkg.sh，git mv 保留历史）。

### Changed

- `build-app.sh` 支持 `DSH_ARCH=arm64|x86_64|universal` 交叉构建（swiftc `-target` + universal lipo）。

### Fixed

- 构建脚本 `TMPDIR` 在清理 `.build` 后未重建导致 swiftc 失败的隐患。

## [1.7.1] - 2026-08-15

### Added

- Repo Wiki 知识库面板：生成/维护/浏览 + 多工作区跟随（`feat(wiki)`）；
- `docs/productization.md` 产品化方案与里程碑目标文档；
- 知识库增量更新流程与 `.dsh/wiki/` 结构。

### Fixed

- 终端多字节输入乱码（`docs/terminal-input-fix.md`：`Darwin.write` 传数组缓冲区必须用
  `withUnsafeBytes`）；
- 终端/Wiki 面板 header 合成溢出（`docs/terminal-header-fix.md`：父容器 `wantsLayer` +
  `masksToBounds`）。

## [1.6.28] - 2026-08-14

### Added

- 原生 macOS 壳首个可分发版本（`b4bceba`）：自包含运行时（内置 Node + dsh）、
  端口探测/复用/自拉起、预览面板、集成终端面板（PTY + ANSI 模拟器）、中英双语、
  dsh 手动/自动升级、registry 配置、退出清理。

---

[Keep a Changelog]: https://keepachangelog.com/en/1.1.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
