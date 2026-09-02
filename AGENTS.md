# AGENTS.md — Agent 工作指引

> 本文件供 AI 代理（如 DeepSeek Harness 会话）在进入本仓库时快速了解上下文。
> 维护方式：与 `.dsh/wiki/` 同步更新（可用 repo-knowledge skill 做增量刷新）。

## 项目是什么

**oh-my-dsh**：把 DeepSeek Harness 的 Web 界面（`dsh web`）封装成原生 macOS App 的壳层。

- **只封装、不修改** DeepSeek Harness 上游源码；
- 完全自包含：内置 Node 运行时 + `@deepseek-ai/dsh` 依赖树；
- 启动复用 `127.0.0.1:3080` 已有服务，否则自拉起；退出只清理自己拉起的服务。

## 先读什么

- `.dsh/wiki/index.md` 与 `.dsh/wiki/conventions.md` —— 工程约定（L10n / 构建 / 测试 / 日志）；
- `docs/productization.md` —— 产品化总纲（路线图 / 分发 / 升级 / 多平台 / 开源治理）；
- `docs/milestones/` —— 各里程碑目标（M1 产品化基础 … M5 Apple 生态）；
- `docs/release-process.md` —— **发布流程**（CHANGELOG → tag → local-release → 版本推进）；
- `README.md` —— 安装 / 构建 / 环境变量。

## 关键约束

1. **绝不改动 DeepSeek Harness 源码**；扩展只走壳层面板 + dsh 既有能力；
2. 自包含优先：构建不复制本机 node/dsh；退出只清理自己拉起的服务；
3. 版本号单一来源：`build-app.sh` 从 git tag 读取 VERSION，BUILD 由 CI 注入；
4. 新增文案必须中英双语成对（`main.swift` 的 `L10n.table`）；
5. macOS 源码清单单一事实来源为 `platforms/macos/swift-sources.sh`（glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，`build-app.sh` / `local-ci.sh` / `ci.yml` 共用，新增文件无需逐个登记）；仅当新文件是独立工具（如 `MakeIcon.swift`，含顶层代码）时需在 `swift_sources()` 显式排除；
6. 面板 UI 遵循 `PreviewPanel.swift` 基件约定；**所有 AppKit 布局统一读 `docs/appkit-ui-layout-guide.md`**（容器裁剪 / layer 合成 / autoresizing / 滚动 doc 高度等越界·遮罩·点不到问题的活文档，会持续积累）；layer 合成陷阱原始排障见 `docs/terminal-header-fix.md`。

## 分支与提交（强制，见 docs/git-workflow.md）

- **开发前必须先切分支**，禁止直接在 `main` 上改代码：
  - 新功能/重构 → `feature/<slug>`（如 `feature/issue-runner`）；
  - bug 修复（未发布）→ `fix/<slug>`；
  - bug 修复（已发布版本）→ `release/X.Y`（打 patch tag 发布后 PR 回 main）；
- **`main` 只接受合并（PR），只打主版本 tag** `vX.Y.0`；不直接 `git push origin main`；
- 分支推送后开 PR 合并（CI 全绿 + review）；已发布版本的修复同步回 main 也走 PR；
- 提交用 conventional commits（`feat(…): …` / `fix(…): …` / `docs(…): …`）；
- 提交前 `git status` 确认只含本次改动，**不顺手提交无关文件**（其他会话/代理的在途改动不要碰）；
- **更新 README 时，直接在「当前分支」修改并提交，不切分支、不开 PR**——README 为仓库说明文档，随当前工作一起落地（特例：仅当 README 需配合独立发布时，可随该发布分支）。

## 发布流程（见 docs/release-process.md）

主版本发布四步（v1.11.0 实战校准）：

1. **更新发布文档**：CHANGELOG.md（必须用 `scripts/changelog.sh <上个tag>` 生成清单，curate 进顶部 `[Unreleased]` 段）；**检查 README/CONTRIBUTING 覆盖本次发布内容**（新面板/特性/测试清单不遗漏）；**主版本（vX.Y.0）同步更新 SECURITY.md ## Supported Versions**（新版本进表、最老出表，patch 跳过）→ 同 commit；
2. **打 tag + push**：`git tag -a vX.Y.Z` 后 `git push github main && git push github vX.Y.Z`（先改 changelog 再打 tag）；
3. **构建发布**：`GH_TOKEN=… IS_PRERELEASE=1 scripts/local-release.sh arm64 x86_64`；⚠️ DMG 的 `hdiutil` 需访问 `/dev`，必须在 `danger-full-access` 沙箱下运行；
4. **推进版本号**：`scripts/version.sh` 的 `FALLBACK_VERSION`/`FALLBACK_BUILD` +1，并更新 CHANGELOG 顶部 `[Unreleased]` 占位，单 commit（形如 `86eba72`）提交推送。

> `main` 受分支保护**禁 force-push**；已推送历史不可改写。

## GitHub token（位置与用法）

- **按仓库**：`~/.dsh/tokens/<owner>-<repo>`（如 `~/.dsh/tokens/insky2005-oh-my-dsh`）；
- **通用兜底**：`~/.dsh/gh-token`；
- 需要 GitHub 写操作（创建 PR、发评论、关闭 issue、推私有仓库）时读取对应文件（`cat` 即可），**绝不打印/回显 token 内容，绝不在对话、汇报、日志、commit message 中泄露 token**；
- 公开仓库的拉取（issues 列表等）无需 token；
- 面板保存 token 时会同时写入 Keychain 与该文件，App 与外部工具/代理共用。

## 测试

```bash
node --test core/tests/        # 共享核心单测（ANSI 模拟器 / 端口 / 升级 / 会话 RPC）
tests/wiki-panel/run.sh        # Wiki 面板模型层单测
tests/terminal-emulator/run.sh # 模拟器测试（已迁 core/tests/ansi.test.js 的薄封装）
```

提交前保持全绿；CI 会在 push/PR 自动跑（macOS arm64 构建 + core 单测；x86_64 交叉编译由 release.yml 打 tag 时构建，不再出 universal）。
