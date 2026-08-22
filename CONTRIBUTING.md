# Contributing to oh-my-dsh

感谢你愿意为 oh-my-dsh 贡献！这是一个把 DeepSeek Harness（`dsh web`）封装成原生 macOS 应用的开源项目。
在提交 PR 之前，请花几分钟读完本指南。

## 项目结构

```
oh-my-dsh/
├── LICENSE  README.md  CHANGELOG.md  CONTRIBUTING.md  SECURITY.md
├── .github/             # CI 工作流 / ISSUE_TEMPLATE / CODEOWNERS（纯文档改动 docs/**、*.md 不触发 CI）
├── core/                # 共享核心（Node，平台无关）：ANSI 模拟器 / 端口 / 升级 / 会话 RPC / issues / jobqueue / tasks /
│                        #   channel（统一抽象 · 路由 · 指令 · 会话映射 · 微信适配器）；单测随 node --test core/tests/ 跑
├── platforms/
│   └── macos/           # macOS 壳：src/（Swift：main + 各面板）+ cef/（CEFShim + helper）+ build-app.sh + build-cef.sh + make-pkg.sh
├── scripts/             # 跨平台工具：version.sh（版本单一来源）/ changelog.sh / local-ci.sh（本机 CI）/ local-release.sh /
│                        #   github-publish.sh / release-checksums.sh / release-fix.sh / git-remote.sh / migrate-platforms-macos.sh
├── tests/               # 面板模型层单测套件（wiki-panel / browser-panel / terminal-emulator，均 headless run.sh）
├── docs/                # 设计/排查文档（productization.md、milestones/、channel-*.md、issue-runner-design.md 等）
└── .dsh/                # wiki / skills（web-dev-tools / repo-knowledge / issue-resolve，随仓库提交）
```

## 环境要求（构建）

- macOS 13+（Apple Silicon；CI 在 arm64 上验证，x86_64 交叉编译由 release.yml 打 tag 发布时校验，不再出 universal）
- Xcode Command Line Tools（`swiftc`、`codesign`、`iconutil`）
- `curl`、`python3`，以及网络（构建期下载 Node + 从 registry 安装 dsh）
- 涉及浏览器面板时需先构建 CEF：`platforms/macos/build-cef.sh <arch>`（产物缓存于 `.cache/`，全量构建自动复用）

```bash
./platforms/macos/build-app.sh --prefetch  # 可选：预下载 Node + 预装 dsh 到 .cache/
./platforms/macos/build-app.sh             # 全量构建 → dist/oh-my-dsh.app
./platforms/macos/make-pkg.sh             # 生成 .pkg / .dmg（打包属 release，本机 CI 不做）
```

## 运行测试

```bash
# 共享核心单测（主套件，headless）：ANSI 模拟器 / 端口 / 升级 / 会话 RPC / issues / 队列 / 任务索引 /
# channel（指令 · 路由 · 会话 · 传输层）
node --test core/tests/

# 面板模型层单测（headless run.sh 套件）
tests/wiki-panel/run.sh
tests/browser-panel/run.sh              # 浏览器面板模型层（REST 路由 / 日志缓冲）
tests/terminal-emulator/run.sh          # 模拟器测试（core/tests/ansi.test.js 的薄封装）

# 本机 CI：与 .github/workflows/ci.yml 三阶段对齐（core → swift 编译检查 → arm64 构建，不打包）
scripts/local-ci.sh                     # 默认 full；可选 test / swift / build [arch]
```

CI（`.github/workflows/ci.yml`）在 push/PR 时跑：core 单测（ubuntu）+ 壳层单测与 `swiftc` 编译检查 +
arm64 构建（macos）；**纯文档改动（`docs/**`、`*.md`）不触发 CI**；x86_64 交叉编译由 release.yml
打 tag 时校验。本地提交前请确保 `scripts/local-ci.sh test`（core + swift）全绿，涉及构建则跑全量。

## 提交规范

沿用 conventional commits：

```
feat(terminal): support bracketed paste toggle     # 新功能
fix(upgrade): retry official registry on failure   # 修复
docs(productization): add release checklist        # 文档
chore(version): bump to v1.8.0                     # 构建/版本
test(core): migrate emulator tests into core/      # 测试
```

- 一个 PR 一个主题，保持小而可审查；
- **提交前 `git status` 确认只含本次改动**，不顺手提交无关文件（尤其其他会话/代理的在途改动不要碰）；
- 新增面向用户的文案必须中英双语成对（见 `.dsh/wiki/conventions.md` 的 L10n 约定；新增 Swift 文案登记进 `main.swift` 的 `L10n.table`）；
- 新增 Swift 文件必须在 `build-app.sh` 的编译清单里登记（`platforms/macos/build-app.sh` 的 `SWIFT_SOURCES`）；
- 新增面板需配套模型层单测（`tests/<name>/run.sh` 模式；平台无关逻辑放 `core/tests/*.test.js`，随 `node --test core/tests/` 跑）；
- **文档与实现同步**：改动 Channel 指令时同步更新 `docs/channel-commands.md`（维护说明见该文档文末）；面板/核心行为变更同步 `docs/channel-status.md`；
- **GitHub token 不外泄**：需要 GitHub 写操作（开 PR、评论/关闭 issue、推私有仓库）时读取 `~/.dsh/tokens/<owner>-<repo>`（通用兜底 `~/.dsh/gh-token`），**绝不打印/回显/写入 commit message**。

## PR 流程

统一分支规范见 [docs/git-workflow.md](docs/git-workflow.md)（main 只合并、只打主版本）：

1. **功能开发**：从 `main` 拉 `feature/<slug>` 分支 → 开发 → PR 到 `main` → 合并后随主版本发布；
2. **bug 修复（未发布）**：从 `main` 拉 `fix/<slug>` 分支 → 修复 → PR 到 `main` → 随主版本发布；
3. **bug 修复（已发布版本）**：从对应 tag 切 `release/X.Y` 分支 → 修复 → 打 patch tag 自行发布 → cherry-pick 回 `main`；
4. 推送前本地过一遍 `scripts/local-ci.sh test`（core + swift；纯文档改动可只跑 markdown/链接检查）；任意分支 PR 都跑 CI；合并回 `main` 前 **CI 必须全绿** + 至少 1 位 CODEOWNER 审查；
5. 发布由维护者打 tag 触发（`.github/workflows/release.yml`）：主版本 `vX.Y.0` 打 `main`，patch `vX.Y.Z` 打 release 分支。

## 行为准则

- 尊重所有人，讨论聚焦技术；
- 不引入与 DeepSeek Harness 上游源码的耦合改动——本项目**只封装、不修改** `dsh`；
- 涉及安全问题的报告请走 `SECURITY.md` 的私有渠道，不要发公开 issue。

## 资源

- 设计总纲：`docs/productization.md`
- 里程碑：`docs/milestones/`
- 工程约定：`.dsh/wiki/conventions.md`
- 分支与提交规范：`docs/git-workflow.md`
- 发布流程：`docs/release-process.md`（CHANGELOG → tag → local-release → 版本推进）
- Channel 面板：`docs/channel-design.md` / `docs/channel-commands.md` / `docs/channel-status.md`（问题排查见 `docs/channel-issues.md`）
