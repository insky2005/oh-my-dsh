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
- `docs/research/productization.md` —— 产品化总纲（路线图 / 分发 / 升级 / 多平台 / 开源治理）；
- `docs/process/dsh-version-impact.md` —— **dsh 升级影响清单**（五个耦合面 + 每次升级的执行 SOP + 0.1.2 复盘；动 dsh 相关代码前先读）；
- `docs/milestones/` —— 各里程碑目标（M1 产品化基础 … M5 Apple 生态）；
- `docs/process/release-process.md` —— **发布流程**（CHANGELOG → tag → local-release → 版本推进）；
- `README.md` —— 安装 / 构建 / 环境变量。

## AI 原生工作流（`.dsh` 卡片）

本仓库同时是「AI 原生工作流」的第一个用户（dogfooding）。会话开始即遵循：

- **模型与约定**：`docs/research/ai-native-workflow-architecture.md`（模型）、`docs/design/panels/requirements-workstream-store-design.md`（`.dsh` 卡片 schema）、`docs/usage/ai-native-workflow-manual.md`（手动模式用法）；
- **状态在 `.dsh`**（随仓库提交）：需求 `REQ-*.md`、事项 `WS-*.md`、回归门 `REG-*.md`；任务队列在任务面板；
- **不手写派生字段**：`closed` / `outcome` / `split` 由 `node .dsh/tools/derive-status.mjs` 派生；
- **人工确认门**：拆解 / 规划 / 设计 / 任务拆分 / 验收 sign-off / merge；
- **只拆不胀**：范围外的新发现回池为新需求，不就地吸收；
- **任务阶段用 `/task-todo`**：拆分 = 建等待态队列、实施 = 启动、交付 = deliver。

## 关键约束

1. **绝不改动 DeepSeek Harness 源码**；扩展只走壳层面板 + dsh 既有能力；
2. 自包含优先：构建不复制本机 node/dsh；退出只清理自己拉起的服务；
3. 版本号单一来源：`build-app.sh` 从 git tag 读取 VERSION，BUILD 由 CI 注入；
4. 新增文案必须中英双语成对（`main.swift` 的 `L10n.table`）；
5. macOS 源码清单单一事实来源为 `platforms/macos/swift-sources.sh`（glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，`build-app.sh` / `local-ci.sh` / `ci.yml` 共用，新增文件无需逐个登记）；仅当新文件是独立工具（如 `MakeIcon.swift`，含顶层代码）时需在 `swift_sources()` 显式排除；
6. 面板 UI 遵循 `PreviewPanel.swift` 基件约定；layer-backed 合成陷阱见 `docs/fixes/terminal-header-fix.md`；**配色令牌见 `docs/design/shell/ui-color-scheme.md`（面板底色 + 控件两档，改色只改 `PanelSurface.swift`）**。

## 文档规范（`docs/`）

**分类存放（按开发环节，完整索引见 [`docs/README.md`](docs/README.md)）：**

| 目录 | 放什么 |
|---|---|
| `docs/raw/` | 原始素材 |
| `docs/process/` | 工程流程：分支规范、发布流程、dsh 升级影响清单 |
| `docs/research/` | 调研、选型、产品化总纲等策略文档 |
| `docs/milestones/` | 里程碑目标（`M<n>-*.md`） |
| `docs/design/shell/` | 壳层共性设计（服务生命周期、数据目录、配色令牌…） |
| `docs/design/panels/` | 面板的设计与实现约定 |
| `docs/design/channels/` | 通道（微信 / 钉钉）的抽象、指令、存储、项目开关 |
| `docs/plans/` | 实施计划（`<TOPIC>_PLAN-*.md`、`dsh-*-compat-audit.md`） |
| `docs/feedback/` | 持续跟踪的使用反馈 |
| `docs/fixes/` | 问题排查与修复记录（现象 → 根因 → 修复 → 验证） |
| `docs/screenshots/` | 文档配图 |
| `docs/usage/` | 面向用户的使用说明（`panels.md` 右栏面板说明） |

- **`docs/` 根目录只放 `README.md` 索引**，新文档一律进上表子目录，不再往根目录堆；新增后必须在 `docs/README.md` 登记；
- 文件名用 kebab-case；设计文档以 `-design.md` 结尾、修复记录以 `-fix.md` 结尾；
- 面板相关优先 `docs/design/panels/`（设计）或 `docs/usage/`（用户说明）。

**编写要求：**

- 正文用中文；文首用引用块写元信息，与现有文档保持一致——设计文档 `> 状态：… · 日期：… · 关联：docs/…`，修复文档 `> 日期 / 状态 / 现象版本`，调研文档 `> 调研日期 / 场景 / 证据原则`；
- **文档间引用统一写仓库根相对路径**（如 `` `docs/process/git-workflow.md` ``），便于全文 grep；只有同目录的 markdown 链接才用 `./` / `../`；配图放 `docs/screenshots/` 并相对引用；
- **移动 / 重命名文档时必须全量更新引用**（源码注释、`.dsh/wiki/` 的 `sources`、AGENTS / README / CHANGELOG、tests），提交前用 grep 校验无残留旧路径；`.dsh/wiki/` 与 `docs/` 保持同步；
- 未提交的在途草案在索引里用代码路径标注、不建链，避免死链；
- 文档改动用 `docs(…): …` 提交；README 更新按「分支与提交」的特例直接在当前分支提交。

## 分支与提交（强制，见 docs/process/git-workflow.md）

- **开发前必须先切分支**，禁止直接在 `main` 上改代码：
  - 新功能/重构 → `feature/<slug>`（如 `feature/issue-runner`）；
  - bug 修复（未发布）→ `fix/<slug>`；
  - bug 修复（已发布版本）→ `release/X.Y`（打 patch tag 发布后 PR 回 main）；
- **`main` 只接受合并（PR），只打主版本 tag** `vX.Y.0`；不直接 `git push origin main`；
- 分支推送后开 PR 合并（CI 全绿 + review）；已发布版本的修复同步回 main 也走 PR；
- 提交用 conventional commits（`feat(…): …` / `fix(…): …` / `docs(…): …`）；
- 提交前 `git status` 确认只含本次改动，**不顺手提交无关文件**（其他会话/代理的在途改动不要碰）；
- **更新 README 时，直接在「当前分支」修改并提交，不切分支、不开 PR**——README 为仓库说明文档，随当前工作一起落地（特例：仅当 README 需配合独立发布时，可随该发布分支）。

## 发布流程（见 docs/process/release-process.md）

主版本发布四步（v1.11.0 实战校准）：

1. **更新发布文档**：CHANGELOG.md（必须用 `scripts/changelog.sh <上个tag>` 生成清单，curate 进顶部 `[Unreleased]` 段）；**检查 README/CONTRIBUTING 覆盖本次发布内容**（新面板/特性/测试清单不遗漏）；**主版本（vX.Y.0）同步更新 SECURITY.md ## Supported Versions**（新版本进表、最老出表，patch 跳过）→ 同 commit；
2. **打 tag + push**：`git tag -a vX.Y.Z` 后 `git push github main && git push github vX.Y.Z`（先改 changelog 再打 tag）；
3. **构建发布**：`GH_TOKEN=… IS_PRERELEASE=1 scripts/local-release.sh arm64 x86_64`；⚠️ DMG 的 `hdiutil` 需访问 `/dev`，必须在 `danger-full-access` 沙箱下运行；
4. **推进版本号**：`scripts/version.sh` 的 `FALLBACK_VERSION`/`FALLBACK_BUILD` +1，并更新 CHANGELOG 顶部 `[Unreleased]` 占位，单 commit（形如 `86eba72`）提交推送。

> `main` 受分支保护**禁 force-push**；已推送历史不可改写。

## GitHub token（位置与用法）

- **按仓库**：`~/.dsh/oh-my-dsh/tokens/<owner>-<repo>`（如 `~/.dsh/oh-my-dsh/tokens/insky2005-oh-my-dsh`）；
- **通用兜底**：`~/.dsh/oh-my-dsh/gh-token`；
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
