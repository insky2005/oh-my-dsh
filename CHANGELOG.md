# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions below
`v1.8.0` are summarized from the git history (conventional commits).

## [Unreleased]

- 暂无（v1.8.0 已发布；下一个版本待定）。

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
