---
title: oh-my-dsh 仓库知识库
tags: [wiki, index, oh-my-dsh]
updated: 2026-08-24T00:00:00Z
sources: [README.md, .dsh/skills/repo-knowledge/SKILL.md, platforms/macos/swift-sources.sh, platforms/macos/src/SkillInstaller.swift, docs/builtin-skills-design.md, scripts/github-publish.sh, platforms/macos/src/main.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/vendor/Highlightr/, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/cef/CEFShim.h, platforms/macos/cef/CEFShim.mm, platforms/macos/build-cef.sh, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/ChannelPanel.swift, core/lib/issues.js, core/lib/jobqueue.js, core/lib/tasks.js, core/lib/channel.js, core/lib/channel-runner.js, core/lib/channel-commands.js, core/lib/channel-store.js, core/tests/issues.test.js, core/tests/channel-runner.test.js, docs/git-workflow.md, docs/channel-design.md, docs/channel-commands.md, docs/channel-status.md, docs/channel-storage.md, docs/channel-project-switch.md, docs/plans/BROWSER_PLAN-browser-panel.md, docs/plans/PREVIEW_PLAN-file-panel.md, scripts/version.sh, scripts/local-release.sh, scripts/release-checksums.sh, scripts/github-publish.sh, Jenkinsfile, .github/workflows/release.yml, docs/devtools-drag-fix.md]
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
- [channel-panel（通道面板）](modules/channel-panel.md) — 微信 ClawBot（官方 iLink 协议）扫码登录 + 长轮询收消息 + 斜杠指令 / #tag 路由 + Channel–Message–Session 关联模型（会话复用/路由统一/工作区归属/全局存储/面板项目视图）+ **项目开关门控**（PR #30：通道↔workspace 启用关联存全局 `~/.dsh/channels/<channelId>.workspaces.json`，未启用回「该项目未启用该通道」/不建会话）+ 异步应答忙门 + sendTyping + 回复回微信；core 层（channel.js / runner / commands / store / sessions / weixin-clawbot / session-driver）+ 面板 v2（引导卡片/扫码向导/项目视图/状态徽标）+ ChannelStoreReader
- [browser-panel（浏览器面板）](modules/browser-panel.md) — 多标签 CEF/Chromium 浏览器（OSR 离屏渲染帧回调自绘）+ localhost REST API（Agent 驱动）+ Chromium 原生 DevTools 窗口 + QA 端点
- [skill-installer（内置 Skill 全局安装器）](modules/skill-installer.md) — App 启动安装内置 skill 到全局 $DSH_HOME/skills/（重命名/缺失即装/受管更新/旧名迁移），配套测试 tests/skills/
- [build-scripts（构建与打包脚本）](modules/build-scripts.md) — platforms/macos/build-app.sh / platforms/macos/make-pkg.sh / MakeIcon.swift / build-cef.sh + release/CI 脚本（version.sh / local-release.sh / release-checksums.sh / github-publish.sh / Jenkinsfile）

## 统计

- 页面数：16（含本页；模块页 10 个）
- 主要源码：`platforms/macos/src/`（13 个 Swift 文件：main/PreviewPanel/FilePanel/CodeEditorView/TerminalPanel/WikiPanel/IssueRunnerPanel/ChannelPanel/BrowserPanel/BrowserAPI/BrowserCDP/SkillInstaller/MakeIcon）+ `platforms/macos/src/vendor/Highlightr/`（Vendored 语法高亮组件）+ `platforms/macos/cef/`（CEFShim.h/.mm ObjC++ 桥）+ 共享核心 `core/`（Node 模块，含 issues/jobqueue/tasks/channel 后 **166 用例单测全绿**）
- **最近提交（2026-08-24）**：`2ea0d81`（`docs(readme)`，合并 **PR #30 `feature/channel-project-switch`**）——**Channel「项目开关」落地**：通道↔项目（workspace）启用关联存全局 `~/.dsh/channels/<channelId>.workspaces.json`（project=workspace，出现即启用该通道；不再写项目内 `.dsh/channels.json`），`ChannelPanel` 移除 `refs`/`saveRefs` 作启用来源、新增 `isChannelEnabled`/`setChannelEnabled`（旧 refs 仅一次性惰性迁移播种），`channel run` 新增 `--project-root`，`main.swift` `startChannelRunner` 删除强制补 ref 并追加 `--project-root`；**门控**：普通消息/`/new` 路由到未启用 workspace、`#wN/#sN`、`/sessions`、`/switch` → 回「该项目未启用该通道」、不建会话，`/workspaces` 只列已启用，`/help` `/ping` `/status` 放行；L10n 新增 `channel.notEnabledInProject`；core 单测 **166 全绿**（较上次 157 新增 project-switch/workspaces 启用用例）。此前 `1ef594c`（`docs(readme)`）与 `0321a9c`（合并 **PR #28 `feature/channel-association`**）——**Channel–Message–Session 关联模型落地**：会话复用 A（sessionDriver.run 复用 event.sessionId）/ 路由统一 B（resolveRefBinding：conversation/keyword 显式绑定 > workspace-tag 兜底）/ 工作区归属 C（普通消息以 workspaceId 创建/复用会话）/ **存储全局化 D**（createChannelSessions 改按 channel 作用域存全局 `~/.dsh/channels/`，sessions/workspaces/分桶 messages，项目目录不再产生消息/会话文件）/ **面板项目视图 E**（新增 `platforms/macos/src/ChannelStoreReader.swift` 纯 Foundation 读全局 store，ChannelPanel 会话行展开显示消息气泡，无头单测 `tests/channel-panel/`）；**异步应答 + 忙门 + sendTyping**（微信原生「正在输入…」替代「处理中」文字，后台生成 + 结果回推，同 conversation 在途时回「请等待」不入队）；runner stdout/stderr 路由到 `~/Library/Logs/oh-my-dsh/channel-runner-<channelId>.log`；core 单测 **157 全绿**（基线 148 + association/busy/重写 sessions）。此前 **PR #27 `feature/builtin-skills-global`**：`e0fd1f8`（2026-08-22）——**内置 Skill 全局化 + 重命名**：新增 `platforms/macos/src/SkillInstaller.swift`，三个面板配套 skill 改由 **App 启动时安装到全局 `$DSH_HOME/skills/`**（缺失即装、受管下自动覆盖更新、用户改过不覆盖），并重命名 `shell-browser`→`web-dev-tools`（浏览器面板）/ `repo-wiki`→`repo-knowledge`（Repo Wiki）/ `issue-fix`→`issue-resolve`（IssueRunner）；启动时自动把旧名迁移到新名；移除面板「按仓库安装」逻辑（`WikiSkill.ensureInstalled` / `ensureIssueFixSkillInstalled` 删除）；新增 `tests/skills/` 无头单测（含内嵌 SKILL.md 与仓库副本字节一致断言）；skill frontmatter 用合法键（省略弃用的 `modelInvocable`/`userInvocable`，新增 `user-invocable: false` 表「仅 model 可调用」）。同 PR 落地 **macOS 源码清单单一事实来源**：新增 `platforms/macos/swift-sources.sh`（glob 自动收录 `src/*.swift` + `vendor/Highlightr/*`，排除独立工具 `MakeIcon.swift`），`build-app.sh` / `scripts/local-ci.sh` / `ci.yml` 三方共用，新增 Swift 文件不再逐个登记，消除「新增文件遗漏 local-ci」问题，见 [skill-installer](modules/skill-installer.md) 与 [build-scripts](modules/build-scripts.md)。此前 PR #26 `fix/single-instance`（**单实例约束**：启动按 bundle id 检测已有实例则聚焦并退出，防双实例争抢 CEF profile 致 Chromium 异常退出；**开发版** `DSH_DEV_BUILD=1` / `scripts/local-ci.sh dev`：Info.plist 写 `DSHDevBuild=1`、独立 CEF profile `~/.dsh/browser-dev`、跳过单实例退出，可与已安装正式版并存测试）与 PR #25 `fix/release-smoothing`（**发布平滑**：发布流程补 READM... (line truncated to 2000 chars)
- 工作区版本号：`1.13.0`（fallback，BUILD 69；最新发布 `v1.12.0`；发布后 fallback 立即推进到下一 minor，见 [conventions](conventions.md)）
- 仓库新增文档：`docs/channel-design.md`（Channel 统一抽象设计：平台适配器 / 状态机 / 路由 / 配置模型）、`docs/channel-commands.md`（已实现指令清单，改动须同步维护）、`docs/channel-status.md`（面板 + core 完成状态总览）、`docs/channel-storage.md`（消息/会话存储全局化设计，**已实现**，2026-08-22 落地于 `~/.dsh/channels/`）、`docs/channel-project-switch.md`（**「项目开关」设计**：全局 workspaces.json 关联 + 未启用门控，**已实现**，2026-08-23 随 PR #30 落地）`docs/channel-association-model.md`（Channel–Message–Session 关联模型：会话复用 A / 路由统一 B / 工作区归属 C / 存储全局化 D / 面板项目视图 E）、`docs/channel-ui-commands.md`（面板 UI + 指令设计）、`docs/channel-issues.md`（重复回复根因排查）；`docs/productization.md`（产品化方案：P0 已达成 → P1 开源/CI → P2 Windows → P3 Linux → P4 生态 → F Apple 生态暂缓，见 [overview](overview.md)）；`docs/git-workflow.md`（统一分支与发布规范：main 只合并/只打主版本，feature/fix 走 PR，已发布 bug 走 release/X.Y + patch tag + cherry-pick 回 main，见 [conventions](conventions.md) 与 [tasks](tasks.md)）；`docs/milestones/`（M1 产品化基础 … M5 Apple 生态 5 份里程碑目标文档，README「目录」收录）；`docs/issue-runner-design.md`（任务面板设计 + 远程驱动预留 + 关联索引章节）；`docs/devtools-drag-fix.md`（DevTools 拖动导致 CEF 视图上移问题的分析与修复）
- 发布/CI 工具链：版本单一来源 `scripts/version.sh`（git tag 驱动）；本机发布 `scripts/local-release.sh`（含 `pack` 只打包子命令）；`scripts/release-checksums.sh`（SHA-256SUMS + release notes）+ `scripts/github-publish.sh`（gh CLI / curl API 兜底）发布；`Jenkinsfile` Jenkins 打包发布；release.yml 新增 prepare 前置 job 预编译双架构 CEF、runtime/CEF 缓存按架构分目录（`.cache/runtime/<arch>`、`.cache/cef-built-<arch>`）——详见 [build-scripts](modules/build-scripts.md) 与 [tasks](tasks.md)
- 任务关联索引：`.dsh/tasks/index.json`（issue→branch→PR→state，随仓库提交）+ `local.json`（sessionId，gitignore），实现 `core/lib/tasks.js`（Node）+ `IssueRunnerPanel.swift` 的 `TaskIndex`（Swift），见 [data-model](data-model.md) 与 [issue-runner-panel](modules/issue-runner-panel.md)
- GitHub token：按仓库作用域——Keychain 专属 + 文件 `~/.dsh/tokens/<owner>-<repo>` 双写（chmod 600），回退 Keychain 通用 + `~/.dsh/gh-token`（外部工具/代理共用）；读取**优先文件**、Keychain 兜底（免 Keychain 弹密码，88f0255），见 [issue-runner-panel](modules/issue-runner-panel.md)
- Channel 配置与状态：账号/token `~/.dsh/channels/<id>.json`（chmod 600，文件优先 + Keychain 兜底）、通道级状态 `~/.dsh/channels/<id>.state.json`（lastWorkspace/会话映射/activeSession，重启可恢复）、**「项目开关」启用关联 `~/.dsh/channels/<channelId>.workspaces.json`**（PR #30，project=workspace，出现即启用该通道）；旧项目引用 `.dsh/channels.json` 不再作为启用来源（迁移到 `.dsh/channels/channels.json` 并提交为待办）；会话映射/消息归档**已全局化**到 `~/.dsh/channels/`（按 channelId/workspaceKey/sessionId 分桶），见 [channel-panel](modules/channel-panel.md) 与 [data-model](data-model.md)
- 任务面板工作区跟随：会话/工作区切换时壳层**先更新 `ProjectDirectory`** 再**无条件**调用 `tasksPanel.workspaceChanged()`（fetch cwd 失败也触发）——面板以 workspacePath 为**权威**（GitHub 仓库 → 显示 issues；非 GitHub → 诚实空态、不替换其他工作区；仅启动早期回退 workspace.list 扫描，≤10 次重试），见 [issue-runner-panel](modules/issue-runner-panel.md) 与 [architecture](architecture.md)
- Wiki 提交：更新完成后由维护代理按指令执行 `git add .dsh/wiki` + commit（不 push，message 概括实际变更；repo-knowledge skill 现行规则已不含提交步骤）；`WikiAutoCommit` 兜底（代理未提交时），见 [wiki-panel](modules/wiki-panel.md)

## 维护约定

- 本知识库由 dsh 代理按 `repo-knowledge` skill（`.dsh/skills/repo-knowledge/SKILL.md`）维护；
- 增量更新只重写 `sources` 命中变更的页面；`manual: true` 页面绝不改写；
- 内容只写可证实事实；`.env*`/密钥/口令一律不收录。

最后生成时间：2026-08-24T00:00:00Z