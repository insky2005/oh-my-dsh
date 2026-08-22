---
title: oh-my-dsh 仓库知识库
tags: [wiki, index, oh-my-dsh]
updated: 2026-08-22T15:04:38Z
sources: [README.md, .dsh/skills/repo-knowledge/SKILL.md, platforms/macos/swift-sources.sh, platforms/macos/src/SkillInstaller.swift, docs/builtin-skills-design.md, scripts/github-publish.sh, platforms/macos/src/main.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/vendor/Highlightr/, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/cef/CEFShim.h, platforms/macos/cef/CEFShim.mm, platforms/macos/build-cef.sh, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/ChannelPanel.swift, core/lib/issues.js, core/lib/jobqueue.js, core/lib/tasks.js, core/lib/channel.js, core/lib/channel-runner.js, core/lib/channel-commands.js, core/lib/channel-store.js, core/tests/issues.test.js, core/tests/channel-runner.test.js, docs/git-workflow.md, docs/channel-design.md, docs/channel-commands.md, docs/channel-status.md, docs/channel-storage.md, docs/plans/BROWSER_PLAN-browser-panel.md, docs/plans/PREVIEW_PLAN-file-panel.md, scripts/version.sh, scripts/local-release.sh, scripts/release-checksums.sh, scripts/github-publish.sh, Jenkinsfile, .github/workflows/release.yml, docs/devtools-drag-fix.md]
manual: false
---

# oh-my-dsh 仓库知识库

一句话简介：**oh-my-dsh** 是把 DeepSeek Harness 的 Web 界面（`dsh web`）封装成 macOS 原生 App 的自包含壳层（WKWebView 壳 + 内置 Node/npm/dsh 运行时），不改动任何 DeepSeek Harness 源码。

## 分节页

- [overview](overview.md) — 技术栈、目录布局、构建/运行/测试方式
- [architecture](architecture.md) — 分层、模块依赖、关键数据流、部署形态
- [data-model](data-model.md) — 核心数据模型与领域概念（UserDefaults 键、RPC 信封、wiki frontmatter 等）
- [conventions](conventions.md) — 工程约定（不改源码原则、L10n、编译清单、QA 钩子、版本管理）
- [tasks](tasks.md) — 常见任务手册（构建/打包/测试/加面板/排查）

## 模块页

- [main（壳层核心）](modules/main.md) — 服务管理、升级、菜单、窗口与右栏插槽
- [preview-panel（预览面板）](modules/preview-panel.md) — 文件/文件夹预览、项目目录树（回滚基线 + 共享 UI 组件；现行实现为 file-panel）
- [file-panel（文件面板）](modules/file-panel.md) — 预览强化：无后缀/点文件按文本预览、文件内编辑 + 行号、Highlightr 语法高亮
- [terminal-panel（终端面板）](modules/terminal-panel.md) — PTY 会话 + ANSI/VT 模拟器
- [wiki-panel（Repo Wiki 面板）](modules/wiki-panel.md) — 知识库生成/维护/浏览
- [issue-runner-panel（任务面板）](modules/issue-runner-panel.md) — GitHub issue 驱动的串行任务流水线（切分支→修复→推送→PR）
- [channel-panel（通道面板）](modules/channel-panel.md) — 微信 ClawBot（官方 iLink 协议）扫码登录 + 长轮询收消息 + 斜杠指令 / #tag 路由 + 会话驱动 + 回复回微信；core 层（channel.js / runner / commands / store / weixin-clawbot / session-driver）+ 面板 v2（引导卡片/扫码向导/项目视图/状态徽标）
- [browser-panel（浏览器面板）](modules/browser-panel.md) — 多标签 CEF/Chromium 浏览器（OSR 离屏渲染帧回调自绘）+ localhost REST API（Agent 驱动）+ Chromium 原生 DevTools 窗口 + QA 端点
- [skill-installer（内置 Skill 全局安装器）](modules/skill-installer.md) — App 启动安装内置 skill 到全局 $DSH_HOME/skills/（重命名/缺失即装/受管更新/旧名迁移），配套测试 tests/skills/
- [build-scripts（构建与打包脚本）](modules/build-scripts.md) — platforms/macos/build-app.sh / platforms/macos/make-pkg.sh / MakeIcon.swift / build-cef.sh + release/CI 脚本（version.sh / local-release.sh / release-checksums.sh / github-publish.sh / Jenkinsfile）

## 统计

- 页面数：16（含本页；模块页 10 个）
- 主要源码：`platforms/macos/src/`（13 个 Swift 文件：main/PreviewPanel/FilePanel/CodeEditorView/TerminalPanel/WikiPanel/IssueRunnerPanel/ChannelPanel/BrowserPanel/BrowserAPI/BrowserCDP/SkillInstaller/MakeIcon）+ `platforms/macos/src/vendor/Highlightr/`（Vendored 语法高亮组件）+ `platforms/macos/cef/`（CEFShim.h/.mm ObjC++ 桥）+ 共享核心 `core/`（Node 模块，含 issues/jobqueue/tasks/channel 后 **148 用例单测全绿**）
- **最近提交（2026-08-22）**：`e0fd1f8`（合并 **PR #27 `feature/builtin-skills-global`**）——**内置 Skill 全局化 + 重命名**：新增 `platforms/macos/src/SkillInstaller.swift`，三个面板配套 skill 改由 **App 启动时安装到全局 `$DSH_HOME/skills/`**（缺失即装、受管下自动覆盖更新、用户改过不覆盖），并重命名 `shell-browser`→`web-dev-tools`（浏览器面板）/ `repo-wiki`→`repo-knowledge`（Repo Wiki）/ `issue-fix`→`issue-resolve`（IssueRunner）；启动时自动把旧名迁移到新名；移除面板「按仓库安装」逻辑（`WikiSkill.ensureInstalled` / `ensureIssueFixSkillInstalled` 删除）；新增 `tests/skills/` 无头单测（含内嵌 SKILL.md 与仓库副本字节一致断言）；skill frontmatter 用合法键（省略弃用的 `modelInvocable`/`userInvocable`，新增 `user-invocable: false` 表「仅 model 可调用」）。同 PR 落地 **macOS 源码清单单一事实来源**：新增 `platforms/macos/swift-sources.sh`（glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，排除独立工具 `MakeIcon.swift`），`build-app.sh` / `scripts/local-ci.sh` / `ci.yml` 三方共用，新增 Swift 文件不再逐个登记，消除「新增文件遗漏 local-ci」问题，见 [skill-installer](modules/skill-installer.md) 与 [build-scripts](modules/build-scripts.md)。此前 PR #26 `fix/single-instance`（**单实例约束**：启动按 bundle id 检测已有实例则聚焦并退出，防双实例争抢 CEF profile 致 Chromium 异常退出；**开发版** `DSH_DEV_BUILD=1` / `scripts/local-ci.sh dev`：Info.plist 写 `DSHDevBuild=1`、独立 CEF profile `~/.dsh/browser-dev`、跳过单实例退出，可与已安装正式版并存测试）与 PR #25 `fix/release-smoothing`（**发布平滑**：发布流程补 README/CONTRIBUTING 覆盖检查与主版本 SECURITY.md ## Supported Versions 同步；`scripts/github-publish.sh` 发布统一走 curl API、幂等化——release 已存在则复用只补传缺失资产 + 逐资产进度输出；`v1.12.0` 已发布，fallback 推进到 `1.13.0`）。此前最近提交：`9829f65`（合并 **PR #23 `feature/channel` 进 main**）——**通道能力合入 main**：微信 ClawBot（官方 iLink 协议）扫码登录 → 长轮询收消息 → 斜杠指令（/help /ping /status /wks /new /sessions /switch）与 #wN/#sN 快捷指令 / #tag 路由 → 驱动 dsh 会话 → 回复回微信（真实微信端到端验证）；macOS 面板 v2（引导卡片 + 面板内二维码扫码向导 + 项目视图 NSSwitch + 连接状态徽标）+ 启动自动拉起/退出关闭 runner；core 层新增 channel.js（五态状态机 + 路由优先级）/ channel-runner / channel-commands / channel-store / channel-sessions / channel-workspaces / weixin-clawbot*.js / session-driver；严格串行长轮询修复重复回复（afa46d5）；存储全局化改造（docs/channel-storage.md）已定稿未实现。此前最近提交 `6b5aab4`（`feature/file-panel` 分支）——**文件面板强化**：预览面板改由 [file-panel](modules/file-panel.md)（`FilePanelController`，PreviewPanel 强化分支）实现，新增无后缀/点文件按文本预览、文件内编辑 + 行号栏、Highlightr 语法高亮（vendored `vendor/Highlightr/`，MIT v2.3.0），及「文件」菜单（保存 ⌘S / 关闭页签 ⌘W）；PreviewPanel.swift 零改动保留为回滚基线，见 [preview-panel](modules/preview-panel.md)。此前最近合并进 main 的提交 `8f51161`（合并 PR #14 feature/browser-panel）——浏览器面板内核定为 CEF/Chromium（根因：CEF 148+ 在 macOS 要求五 helper app，缺 `(Renderer)` 致 renderer 静默失败，见 [browser-panel](modules/browser-panel.md)）；浏览器面板演进已**合并进 main**：渲染 **OSR 离屏默认**（`browserRenderMode` 可切窗口化；CEF pin 150.0.18）、Chromium 原生 DevTools 窗口（CEFShim.showDevTools）、控制台抽屉/JS 求值 UI 移除（日志缓冲只供 REST API）、Chrome 式页签栏、`g_cefClosingWindow` 防 CEF 误关主窗口退出、QA 端点 `POST /api/browser/debug` 与 `/api/browser/hierarchy`、DevTools 拖动修复（docs/devtools-drag-fix.md）；更早的定型：Node 选择策略**系统优先、内置兜底、带版本门槛**（ac4312c/6428249：`DSH_NODE` > 系统 node（PATH→nvm current→nvm default→nvm 最新→Homebrew，候选 ≥22.0.0，`DSH_NODE_MIN` 可覆盖）> 内置 node；启动轮询含 1s 沉降校验），dsh web 环境**不注入内置目录**、经 `loginShellPath()`（`/bin/zsh -ilc` 读一次、8s 超时兜底、缓存）合并登录 shell PATH（f4cfa33）；About 面板显示实际运行 dsh web 的 node 路径（8fcd6cc）并把 Node 版本+路径合并为一行（e9d6bb2）；此前任务面板工作区识别改**权威判断**（workspacePath 非 GitHub 仓库时诚实显示空态、不再替换为其他工作区，13bf9e3；切换到不同仓库先清空旧任务列表，197189e）、会话切换**无条件**触发任务面板刷新（4a7de43/40288d1）；更早 token 读取改**文件优先**、Keychain 兜底（88f0255，免每次弹密码），配置按钮改齿轮图标、配置文案改按仓库双写说明（628c30a）
- 工作区版本号：`1.13.0`（fallback，BUILD 69；最新发布 `v1.12.0`；发布后 fallback 立即推进到下一 minor，见 [conventions](conventions.md)）
- 仓库新增文档：`docs/channel-design.md`（Channel 统一抽象设计：平台适配器 / 状态机 / 路由 / 配置模型）、`docs/channel-commands.md`（已实现指令清单，改动须同步维护）、`docs/channel-status.md`（面板 + core 完成状态总览）、`docs/channel-storage.md`（消息/会话存储全局化设计，待实现）、`docs/channel-ui-commands.md`（面板 UI + 指令设计）、`docs/channel-issues.md`（重复回复根因排查）；`docs/productization.md`（产品化方案：P0 已达成 → P1 开源/CI → P2 Windows → P3 Linux → P4 生态 → F Apple 生态暂缓，见 [overview](overview.md)）；`docs/git-workflow.md`（统一分支与发布规范：main 只合并/只打主版本，feature/fix 走 PR，已发布 bug 走 release/X.Y + patch tag + cherry-pick 回 main，见 [conventions](conventions.md) 与 [tasks](tasks.md)）；`docs/milestones/`（M1 产品化基础 … M5 Apple 生态 5 份里程碑目标文档，README「目录」收录）；`docs/issue-runner-design.md`（任务面板设计 + 远程驱动预留 + 关联索引章节）；`docs/devtools-drag-fix.md`（DevTools 拖动导致 CEF 视图上移问题的分析与修复）
- 发布/CI 工具链：版本单一来源 `scripts/version.sh`（git tag 驱动）；本机发布 `scripts/local-release.sh`（含 `pack` 只打包子命令）；`scripts/release-checksums.sh`（SHA-256SUMS + release notes）+ `scripts/github-publish.sh`（gh CLI / curl API 兜底）发布；`Jenkinsfile` Jenkins 打包发布；release.yml 新增 prepare 前置 job 预编译双架构 CEF、runtime/CEF 缓存按架构分目录（`.cache/runtime/<arch>`、`.cache/cef-built-<arch>`）——详见 [build-scripts](modules/build-scripts.md) 与 [tasks](tasks.md)
- 任务关联索引：`.dsh/tasks/index.json`（issue→branch→PR→state，随仓库提交）+ `local.json`（sessionId，gitignore），实现 `core/lib/tasks.js`（Node）+ `IssueRunnerPanel.swift` 的 `TaskIndex`（Swift），见 [data-model](data-model.md) 与 [issue-runner-panel](modules/issue-runner-panel.md)
- GitHub token：按仓库作用域——Keychain 专属 + 文件 `~/.dsh/tokens/<owner>-<repo>` 双写（chmod 600），回退 Keychain 通用 + `~/.dsh/gh-token`（外部工具/代理共用）；读取**优先文件**、Keychain 兜底（免 Keychain 弹密码，88f0255），见 [issue-runner-panel](modules/issue-runner-panel.md)
- Channel 配置与状态：账号/token `~/.dsh/channels/<id>.json`（chmod 600，文件优先 + Keychain 兜底）、通道级状态 `~/.dsh/channels/<id>.state.json`（lastWorkspace/会话映射/activeSession，重启可恢复）、项目引用 `.dsh/channels.json`（未跟踪，迁移到 `.dsh/channels/channels.json` 并提交为待办）；消息/会话 v1 落项目 `.dsh/channels/`（gitignore），见 [channel-panel](modules/channel-panel.md) 与 [data-model](data-model.md)
- 任务面板工作区跟随：会话/工作区切换时壳层**先更新 `ProjectDirectory`** 再**无条件**调用 `tasksPanel.workspaceChanged()`（fetch cwd 失败也触发）——面板以 workspacePath 为**权威**（GitHub 仓库 → 显示 issues；非 GitHub → 诚实空态、不替换其他工作区；仅启动早期回退 workspace.list 扫描，≤10 次重试），见 [issue-runner-panel](modules/issue-runner-panel.md) 与 [architecture](architecture.md)
- Wiki 提交：更新完成后由维护代理按指令执行 `git add .dsh/wiki` + commit（不 push，message 概括实际变更；repo-knowledge skill 现行规则已不含提交步骤）；`WikiAutoCommit` 兜底（代理未提交时），见 [wiki-panel](modules/wiki-panel.md)

## 维护约定

- 本知识库由 dsh 代理按 `repo-knowledge` skill（`.dsh/skills/repo-knowledge/SKILL.md`）维护；
- 增量更新只重写 `sources` 命中变更的页面；`manual: true` 页面绝不改写；
- 内容只写可证实事实；`.env*`/密钥/口令一律不收录。

最后生成时间：2026-08-22T15:04:38Z
