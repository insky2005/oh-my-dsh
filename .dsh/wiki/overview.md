---
title: 仓库概览
tags: [overview, tech-stack, build, run, test]
updated: 2026-08-22T15:04:38Z
sources: [README.md, platforms/macos/build-app.sh, platforms/macos/swift-sources.sh, platforms/macos/src/SkillInstaller.swift, docs/builtin-skills-design.md, platforms/macos/build-cef.sh, platforms/macos/make-pkg.sh, platforms/macos/src/main.swift, platforms/macos/src/PreviewPanel.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/TerminalPanel.swift, platforms/macos/src/WikiPanel.swift, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/src/ChannelPanel.swift, platforms/macos/src/MakeIcon.swift, core/lib/issues.js, core/lib/jobqueue.js, core/lib/tasks.js, core/lib/channel.js, core/lib/channel-runner.js, core/tests/issues.test.js, core/tests/channel-runner.test.js, docs/productization.md, docs/git-workflow.md, docs/channel-design.md, docs/channel-status.md, docs/plans/PREVIEW_PLAN-file-panel.md, scripts/version.sh, scripts/local-release.sh, scripts/release-checksums.sh, scripts/github-publish.sh, Jenkinsfile, .github/workflows/, tests/wiki-panel/run.sh]
manual: false
---

# 仓库概览

## 一句话定位

oh-my-dsh 是 DeepSeek Harness 的 **macOS 原生壳**：把 `dsh web`（`@deepseek-ai/dsh` 的浏览器界面）封装成可双击运行的 `.app`。**不改动任何 DeepSeek Harness 源码**，只做端口探测、服务拉起/复用、WKWebView 呈现，并附右栏面板（预览/文件、终端、Repo Wiki、任务、浏览器、通道）。

## 技术栈

| 层 | 技术 |
|---|---|
| 界面 | Swift 5 + AppKit（自绘控件，无第三方 UI 依赖） |
| Web 容器 | WebKit `WKWebView`（渲染 `http://127.0.0.1:<port>`） |
| 浏览器面板内核 | CEF / Chromium Embedded Framework（pin `150.0.18+gdb11278+chromium-150.0.7871.213`，OSR 离屏渲染帧回调自绘；`build-cef.sh` 下载 + shim/helper 编译） |
| PDF 预览 | PDFKit |
| 语法高亮 | vendored **Highlightr**（MIT v2.3.0，底层 highlight.js），文件面板代码编辑（[file-panel](modules/file-panel.md)） |
| 消息通道 | 微信 ClawBot（**官方 iLink 协议**，长轮询 getupdates 无需公网；`core/lib/weixin-clawbot*.js`）+ 面板内 `CIQRCodeGenerator` 二维码扫码登录 + CLI QR（vendored `core/vendor/qrcode-terminal/`），见 [channel-panel](modules/channel-panel.md) |
| 内置运行时 | Node（darwin-arm64 tarball）+ npm + `@deepseek-ai/dsh` 依赖树（构建期下载，嵌入 `Contents/Resources/runtime/`） |
| 构建 | bash（`platforms/macos/build-app.sh`）、`swiftc`、`codesign`、`iconutil`、`curl`、`python3` |
| 打包 | `pkgbuild` + `hdiutil`（`platforms/macos/make-pkg.sh` → .pkg / .dmg） |
| 目标平台 | macOS 13+（Apple Silicon / arm64；Info.plist `LSMinimumSystemVersion` = 13.0） |

当前工作区版本：`1.13.0`（fallback，BUILD 69；最新发布 `v1.12.0`）；版本由 git tag 驱动（`scripts/version.sh`：HEAD 命中 vX.Y.Z → 取 tag，否则回退 1.13.0；BUILD 取 CI 运行号）。当前分支：**`main`**（HEAD `1ef594c`，合并 PR #28 `feature/channel-association`）——**Channel 关联模型落地**：Channel–Message–Session 关联（会话复用 A / 路由统一 B / 工作区归属 C / 存储全局化 D / 面板项目视图 E）、异步应答 + 忙门 + sendTyping、channel runner 日志落盘，见 [channel-panel](modules/channel-panel.md)。此前 PR #27 `feature/builtin-skills-global` 合并 **内置 Skill 全局化**（SkillInstaller 装到全局 $DSH_HOME/skills/、shell-browser→web-dev-tools / repo-wiki→repo-knowledge / issue-fix→issue-resolve 重命名）；PR #23 `feature/channel` 把**通道能力合入 main**：微信 ClawBot 扫码登录 → 长轮询收消息 → 斜杠指令 / #tag 路由 → 驱动 dsh 会话 → 回复回微信，全链路真实微信端到端验证；macOS 面板 v2（引导卡片 + 扫码向导 + 项目视图 + 状态徽标）。此前的文件面板强化已合入（`feature/file-panel` HEAD `6b5aab4`：预览面板改由 [FilePanel](modules/file-panel.md)（`FilePanelController`）实现，新增无后缀/点文件按文本预览、文件内编辑 + 行号栏、Highlightr 语法高亮，及「文件」菜单（保存 ⌘S / 关闭页签 ⌘W））。此前最近合并进 main 的提交：`8f51161`（合并 PR #14 feature/browser-panel）——浏览器面板内核定为 CEF/Chromium（root cause：CEF 148+ 需五 helper app，缺 `(Renderer)` 致 renderer 静默失败，见 [browser-panel](modules/browser-panel.md)）；浏览器面板演进已合并进 main（OSR 离屏渲染默认、Chromium 原生 DevTools 窗口、控制台抽屉移除、QA 端点 debug/hierarchy、DevTools 拖动修复）。发布/CI 侧近期演进：`local-release.sh`（含 `pack` 只打包不发布子命令）、`github-publish.sh`/`release-checksums.sh` 发布脚本、`Jenkinsfile`、runtime/CEF 缓存按架构分目录（`.cache/runtime/<arch>`、`.cache/cef-built-<arch>`）、release.yml 新增 prepare 前置 job，见 [build-scripts](modules/build-scripts.md) 与 [tasks](tasks.md)。历史：Node 选择策略定型为**系统优先、内置兜底、带版本门槛**（ac4312c 系统优先：resolveNode = DSH_NODE > 系统 node（PATH→nvm current→nvm default→nvm 最新→Homebrew，90d9176/ceefc0c 定序）> 内置 node；6428249 加版本门槛：候选低于 22.0.0 跳过（`DSH_NODE_MIN` 可覆盖），全过旧则内置兜底，版本比较内联 Swift 不经 CoreBridge 避免递归；启动轮询加 1s 沉降校验防引导页假就绪；f4cfa33：dsh web 环境经 `loginShellPath()`（`/bin/zsh -ilc` 读一次登录 shell PATH，8s 超时兜底、结果缓存）合并用户 PATH，不注入内置目录）；About 面板显示实际 node 路径（8fcd6cc）并将 Node 版本+路径合并为一行（e9d6bb2）；此前任务面板工作区识别改**权威判断**（workspacePath 非 GitHub 仓库时诚实显示空态、不再替换为其他工作区，13bf9e3；切换到不同仓库先清空旧任务列表，197189e）、会话切换**无条件**触发任务面板刷新（4a7de43/40288d1）、token 读取改文件优先、Keychain 兜底（88f0255）。

## 目录布局

```
core/                共享核心（Node 模块：ANSI 模拟器 / 端口探测 / 升级 / 会话 RPC / issues / jobqueue / tasks 关联索引 / channel 通道（抽象+路由+指令+存储+微信适配器+会话驱动），跨平台复用；随构建嵌入 runtime/core）
platforms/           各平台壳（macos/ 现有壳，windows/ linux/ 规划中）
scripts/             跨平台工具（version.sh 版本单一来源 / changelog.sh / release-checksums.sh 校验和 / github-publish.sh 发布 / local-release.sh 本机 Release / git-remote.sh 远端检测 / release-fix.sh patch 发布 / 迁移脚本）
.github/             CI 工作流（core 单测走 ubuntu；壳层单测/编译检查 + arm64 构建走 macos-14；x86_64 交叉编译由 release.yml 打 tag 时构建，不再出 universal，也不再依赖退役中的 macos-13 runner）；release.yml 发布幂等（先删旧 release+tag 再 --target 重建）+ prepare 前置 job 预编译双架构 CEF 统一缓存，见 [tasks](tasks.md)
Jenkinsfile          Jenkins 打包 + GitHub Release 发布（macOS agent 上 build-app.sh + make-pkg.sh；gh CLI / curl API 兜底），见 [build-scripts](modules/build-scripts.md)
platforms/macos/src/main.swift       壳层核心（日志/L10n/服务管理/升级/窗口/菜单/设置窗口/onboarding/CoreBridge）约 3600 行
platforms/macos/src/PreviewPanel.swift  预览面板回滚基线 + 共享 UI 组件（约 1481 行）；现行预览实现为 FilePanel.swift
platforms/macos/src/FilePanel.swift      文件面板（`FilePanelController`，PreviewPanel 强化分支：预览+编辑+行号+语法高亮）约 1246 行
platforms/macos/src/CodeEditorView.swift 代码编辑器视图（行号栏 + 可编辑 + Highlightr 语法高亮）388 行
platforms/macos/src/vendor/Highlightr/   Vendored 语法高亮组件（Highlightr MIT v2.3.0 + highlight.js 资源）
platforms/macos/src/TerminalPanel.swift 终端面板（PTY 会话 + ANSI/VT 模拟器）约 1875 行
platforms/macos/src/WikiPanel.swift      Repo Wiki 面板（知识库生成/维护/浏览 + 自动 git 提交）约 2072 行
platforms/macos/src/IssueRunnerPanel.swift 任务面板（GitHub issues 串行处理 → 分支/修复/推送/PR + 关联索引 + 评论并关闭 + 按仓库作用域 token）约 1498 行
platforms/macos/src/ChannelPanel.swift    通道面板（全局 channel 卡片 + 扫码登录向导 + 项目视图开关 + 连接状态徽标 + runner 生命周期）850 行
platforms/macos/src/SkillInstaller.swift   内置 Skill 全局安装器（App 启动装到 $DSH_HOME/skills/ + 缺失即装/受管更新/旧名迁移，Foundation-only）约 307 行
platforms/macos/src/BrowserPanel.swift 浏览器面板（多标签 CEF/Chromium，OSR 渲染 + REST API 驱动）约 1123 行
platforms/macos/src/BrowserAPI.swift   浏览器面板 REST API（127.0.0.1:3081，Agent 驱动 + QA 端点）530 行
platforms/macos/src/BrowserCDP.swift   CDP 客户端（WebSocket：console/网络/求值/截图）303 行
platforms/macos/src/MakeIcon.swift       App 图标生成器（渲染 → iconset → icns）104 行
platforms/macos/build-app.sh         一键构建脚本（6 步：目录/图标/编译/运行时/Info.plist/签名）
platforms/macos/build-cef.sh         CEF 构建脚本（版本 pin + sha1 校验 + 缓存；wrapper/shim/五 helper 编译）
platforms/macos/cef/                 CEFShim.h/.mm（ObjC++ 桥，OSR 渲染/输入转发/DevTools）、process_helper_mac.cc、helper-Info.plist.in
platforms/macos/make-pkg.sh          .pkg 安装包 + .dmg 镜像脚本
docs/                设计与排查文档（repo-wiki-design.md、productization.md、git-workflow.md、milestones/、plans/、terminal-header-fix.md、terminal-input-fix.md、channel-design.md、channel-commands.md、channel-status.md、channel-storage.md、channel-ui-commands.md、channel-issues.md、raw/）
tests/               无头单元测试（terminal-emulator/、wiki-panel/、browser-panel/、skills/，各含 run.sh；模拟器测试已迁 core/tests/ansi.test.js 的薄封装）
.cache/              构建缓存（node tarball、npm-cache、已构建 runtime）— git 忽略
.build/              构建中间产物 — git 忽略
dist/                产物（.app / .pkg / .dmg）— git 忽略
pic/                 QA 调试截图 — git 忽略
.dsh/skills/         内置 skill 提交副本（web-dev-tools / repo-knowledge / issue-resolve，App 启动经 SkillInstaller 安装到全局 $DSH_HOME/skills/）
.dsh/wiki/           本知识库
.dsh/tasks/          任务关联索引（index.json 提交 + local.json 本机覆盖，gitignore）
```

## 构建

```bash
./platforms/macos/build-app.sh --prefetch   # 可选：预下载 Node + 预装 dsh 到 .cache/，不产出 App
./platforms/macos/build-app.sh              # 全量构建 → dist/oh-my-dsh.app
```

- 编译命令：`swiftc -O -swift-version 5 -framework AppKit -framework WebKit -framework PDFKit`，源文件清单显式列出（`main/PreviewPanel/TerminalPanel/WikiPanel/IssueRunnerPanel/BrowserPanel/BrowserAPI/BrowserCDP`）+ CEF 产物（`build-cef.sh` 产出 wrapper/shim/五 helper，由内向外签名）；
- 内置运行时构建期现做：下载 Node tarball（默认国内镜像 `npmmirror.com/mirrors/node`，校验 SHA-256），用其自带 npm 在 `runtime/dsh` 装 `@deepseek-ai/dsh@0.1.0-rc.7`（默认 `DSH_PACKAGE_SPEC`，国内源失败自动回退 npmjs.org）；
- 缓存：`(Node 版本, dsh 版本)` 相同则复用 `.cache/runtime`，重建只需几十秒；网络不可用时用缓存 tarball 推导版本继续。

构建变量（均可用环境变量覆盖）：`DSH_NODE_VERSION`、`DSH_PACKAGE_SPEC`、`DSH_NODE_MIRROR`、`DSH_NPM_REGISTRY`、`DSH_ARCH`、`DSH_DEV_BUILD`（=1 打开发版：Info.plist 写 `DSHDevBuild=1`、独立 CEF profile、跳过单实例退出，可与正式版并存测试，详见 [build-scripts](modules/build-scripts.md) 与 [main](modules/main.md)）。

## 运行

```bash
open "dist/oh-my-dsh.app"     # 或双击
```

- 运行时**无需**本机安装 Node 或 dsh（自包含）；
- 启动先探测 `127.0.0.1:3080` 是否已有 `dsh web`（页面含 `window.__DSH_BOOT__` 判定）→ 复用；否则按 node 选择策略（`DSH_NODE` > 系统 node（PATH→nvm current→nvm default→nvm 最新→Homebrew，候选须 ≥ 22.0.0，`DSH_NODE_MIN` 可覆盖）> 内置 node）拉起 `dsh web --port <n>`（3080 被占自动换空闲端口），dsh web 环境合并登录 shell PATH（`loginShellPath()`），系统 node 启动失败自动回退内置 node 重试一次（`DSH_NODE` 显式指定不回退），90 秒超时 + 1s 沉降校验；
- **项目目录跟随当前会话**：壳层注入 `sessionTrackerScript` 监听 dsh web 的会话 RPC（`session.history/prompt/rename/selectModel`、`subagent.list`），用户切换会话/工作区时经 `dshSession` 消息把新的项目目录同步给预览树、终端新会话、wiki 根与任务面板（共享 `ProjectDirectory`；任务面板跟随会话**无条件**刷新——workspacePath 权威、非 GitHub 仓库诚实显示空态，见 [architecture](architecture.md)）；
- 日志：`~/Library/Logs/oh-my-dsh/app.log`（壳层）、`server.log`（自拉起服务输出）。

## 测试

```bash
node --test core/tests/*.test.js     # 共享核心单测（ANSI 模拟器 / 端口 / 升级 / 会话 RPC / issues / jobqueue / tasks / channel 通道，157 用例；不带引号由 bash 展开 glob，Node 20 兼容）
tests/terminal-emulator/run.sh       # 模拟器测试（已迁 core/tests/ansi.test.js 的薄封装）
tests/wiki-panel/run.sh              # Repo Wiki 模型层无头单测（实测 41 passed）
tests/skills/run.sh                  # 内置 skill 安装器无头单测（SkillInstaller：缺失即装/更新/跳过/迁移/字节一致）
tests/channel-panel/run.sh            # 通道项目视图数据模型（ChannelStoreReader 读全局 store）
```

- core 单测为 Node 测试（`core/tests/*.test.js`：ansi 42 / ports 5 / session 4 / upgrade 4 / issues 8 / jobqueue 7 / tasks 7 = 77 + channel 相关 80 = **157 全绿**，2026-08-23 实测；channel 覆盖 channel/commands/runner/sessions/workspaces/weixin-clawbot/e2e-channel/channel-association/channel-busy）；`tests/terminal-emulator/run.sh` 现为 `core/tests/ansi.test.js` 的薄封装；
- Swift 无头单测模式（`tests/wiki-panel/`）：`stubs.swift` + 复制源码 + 测试文件改名 `main.swift` → `swiftc` 编译成可执行文件运行（无窗口/无 PTY 依赖）；
- 设计文档（`docs/repo-wiki-design.md` §14）记录 v1.7.0 验证：全量编译零错误、wiki 单测 41/41（实测 `tests/wiki-panel/run.sh` 41 passed）、终端模拟器 46 项回归全过（Swift 实现，后迁 core/tests/ansi.test.js 42 项）；并记录 16 轮修复（build 43→63，其中修复 10–14：生成中提示改叠加浮层、定位状态条合成溢出根因、生成状态按工作区关联、终端新会话目录跟随当前工作区等，详见 [wiki-panel](modules/wiki-panel.md)；修复 15 移除失效的 `attachOrphans`、16 repo-wiki SKILL 优化）；
- 产品化方案（`docs/productization.md`，2026-08-15，状态已批准执行）：P0 现状基线（v1.7.x，已达成）→ P1 开源基础（GitHub 公开 + MIT、CI、共享核心抽取，约 1–2 周）→ P2 Windows 版（≈2–3 个月）→ P3 Linux 版（≈1–2 个月）→ P4 生态增长；Apple 生态（Developer ID 签名/公证/Sparkle 升级/Homebrew Cask）依赖开发者账号，统一暂缓至最后阶段 F；配套 `docs/milestones/`（M1 产品化基础 … M5 Apple 生态 5 份里程碑目标文档，后续开发任务来源，见 README「目录」）。

## 已知限制（README 明示）

- 终端 v1 不支持输入法直接打字（中文等经 ⌘V 粘贴输入）、DECSTBM 滚动区未实现、会话不跨 App 重启保留；
- Wiki 面板 v1 搜索为标题过滤（无正文/语义检索）；
- 通道（channel）能力 README 已收录；设计/指令/状态/存储文档在 `docs/channel-*.md`；消息/会话存储**已全局化**（2026-08-22 落地于 `~/.dsh/channels/` 分桶，见 [channel-panel](modules/channel-panel.md)），引用配置 `.dsh/channels.json` 旧路径文件仍未跟踪（迁移到 `.dsh/channels/channels.json` 并提交是待办）。
