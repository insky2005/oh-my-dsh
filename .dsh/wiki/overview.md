---
title: 仓库概览
tags: [overview, tech-stack, build, run, test]
updated: 2026-09-28T01:42:18Z
sources: [README.md, CHANGELOG.md, platforms/macos/src/SkillsPanel.swift, platforms/macos/src/SkillsCore.swift, platforms/macos/src/SkillSources.swift, docs/skills-manager-design.md, tests/skills-panel/, platforms/macos/src/DshWebCookieJanitor.swift, platforms/macos/src/ShellConfig.swift, tests/shell-config/, tests/dsh-auth-cookies/, docs/browser-blank-panel-fix.md, platforms/macos/build-app.sh, platforms/macos/src/ReviewPanel.swift, platforms/macos/src/ReviewLogModel.swift, core/lib/review-log.js, tests/review-panel/, docs/review-panel-design.md, platforms/macos/swift-sources.sh, platforms/macos/src/SkillInstaller.swift, docs/builtin-skills-design.md, platforms/macos/build-cef.sh, platforms/macos/make-pkg.sh, platforms/macos/src/main.swift, platforms/macos/src/PreviewPanel.swift, platforms/macos/src/FilePanel.swift, platforms/macos/src/CodeEditorView.swift, platforms/macos/src/TerminalPanel.swift, platforms/macos/src/WikiPanel.swift, platforms/macos/src/IssueRunnerPanel.swift, platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/src/ChannelPanel.swift, platforms/macos/src/MakeIcon.swift, core/lib/issues.js, core/lib/jobqueue.js, core/lib/tasks.js, core/lib/channel.js, core/lib/channel-runner.js, core/tests/issues.test.js, core/tests/channel-runner.test.js, docs/productization.md, docs/git-workflow.md, docs/channel-design.md, docs/channel-status.md, docs/channel-project-switch.md, docs/channel-dingtalk-stream.md, docs/plans/PREVIEW_PLAN-file-panel.md, scripts/version.sh, scripts/local-release.sh, scripts/release-checksums.sh, scripts/github-publish.sh, Jenkinsfile, .github/workflows/, tests/wiki-panel/run.sh, docs/dsh-version-impact.md, platforms/macos/src/PanelSurface.swift, platforms/macos/src/FilePanelTreeMenu.swift, platforms/macos/src/OpenWithApps.swift, platforms/macos/src/ImagePreviewView.swift, platforms/macos/src/ImageZoom.swift, platforms/macos/src/EditorLoadPolicy.swift, platforms/macos/src/TerminalWorkspaceTabs.sw... (line truncated to 2000 chars), platforms/macos/src/TasksRunner.swift, platforms/macos/src/TasksStore.swift, platforms/macos/src/TasksUI.swift, platforms/macos/src/TasksAPI.swift, platforms/macos/src/TaskInlineForms.swift, platforms/macos/src/TasksWorkspaces.swift, tests/tasks-panel/, docs/issue-runner-design.md]
manual: false
---

# 仓库概览

## 一句话定位

oh-my-dsh 是 DeepSeek Harness 的 **macOS 原生壳**：把 `dsh web`（`@deepseek-ai/dsh` 的浏览器界面）封装成可双击运行的 `.app`。**不改动任何 DeepSeek Harness 源码**，只做端口探测、服务拉起/复用、WKWebView 呈现，并附右栏面板（项目、文件、终端、Repo Wiki、任务、浏览器、通道、审查、技能）。

## 技术栈

| 层 | 技术 |
|---|---|
| 界面 | Swift 5 + AppKit（自绘控件，无第三方 UI 依赖） |
| Web 容器 | WebKit `WKWebView`（渲染 `http://127.0.0.1:<port>`） |
| 浏览器面板内核 | CEF / Chromium Embedded Framework（pin `150.0.18+gdb11278+chromium-150.0.7871.213`，OSR 离屏渲染帧回调自绘；`build-cef.sh` 下载 + shim/helper 编译） |
| PDF 预览 | PDFKit |
| 语法高亮 | vendored **Highlightr**（MIT v2.3.0，底层 highlight.js），文件面板代码编辑（[file-panel](modules/file-panel.md)） |
| 消息通道 | 微信 ClawBot（**官方 iLink 协议**，长轮询 getupdates 无需公网；`core/lib/weixin-clawbot*.js`）+ 钉钉（**dingtalk-stream 原生适配器**，Stream 长连接 + device-code 扫码注册；`core/lib/dingtalk*.js`）+ 面板内 `CIQRCodeGenerator` 二维码扫码登录 + CLI QR（vendored `core/vendor/qrcode-terminal/`），见 [channel-panel](modules/channel-panel.md) |
| 内置运行时 | Node（darwin-arm64 tarball）+ npm + `@deepseek-ai/dsh` 依赖树（构建期下载，嵌入 `Contents/Resources/runtime/`） |
| 构建 | bash（`platforms/macos/build-app.sh`）、`swiftc`、`codesign`、`iconutil`、`curl`、`python3` |
| 打包 | `pkgbuild` + `hdiutil`（`platforms/macos/make-pkg.sh` → .pkg / .dmg） |
| 目标平台 | macOS 13+（Apple Silicon / arm64；Info.plist `LSMinimumSystemVersion` = 13.0） |

当前工作区版本：`1.17.0`（fallback，BUILD 73；最新发布 tag **`v1.16.3`**（2026-09-27，`release/1.16` patch：内置 dsh 推进到 `0.1.5-rc.3` + 闭包锁；此前 **`v1.16.2`**（2026-09-23）：会话快照与回退 + 会话日志世代命名适配 + 运行时可复现构建），另有 `v1.16.0`（2026-09-21）与 `v1.13.1`（patch）——`v1.16.1` 曾发布后**撤回**，Release 与 tag 均已删除）；版本由 git tag 驱动（`scripts/version.sh`：HEAD 命中 vX.Y.Z → 取 tag，否则回退 1.17.0；BUILD 取 CI 运行号）。内置 dsh 版本：`@deepseek-ai/dsh@0.1.5-rc.3`（`DSH_PACKAGE_SPEC` 默认值，依赖闭包由 `platforms/macos/runtime-locks/` 的 lockfile 钉死）。当前分支：**`main`**（HEAD `2672b09` = 合并 **PR #61 `sync/v1.16.3-to-main`**：把 v1.16.3 的 dsh 推进（`0.1.5-rc.3` + 闭包锁）带回 main；此前 HEAD `6d2f954` = 合并 **PR #56 `feature/projects-panel`**；最近两次功能合并——**PR #53 `feature/file-panel-composer-reference`**：**Files 面板目录树右键「添加到对话」**把文件/文件夹以 `@` 引用插进 dsh web 的输入框（**不改 dsh 源码**，经注入桥 `window.__dshInsertFileReference` 直接写 Lexical 编辑器；纯模型 `ComposerReference.swift`，文档 `docs/file-panel-composer-reference.md`，QA 钩子 `DSH_COMPOSER_TEST_PATH`/`DSH_COMPOSER_TEST_SESSION`）；**PR #56 `feature/projects-panel`**：**项目面板（Projects / ⌥⌘P，活动栏首位「项目」）**——可配置**项目根目录**（默认 `$DSH_HOME/oh-my-dsh/projects`，存 `shell/config.json` 的 `projectsRoot`），每个直属子目录一张工作区卡片，支持新建工作区（`workspace/create` 幂等注册）、六个快捷入口、注入桥 `window.__dshNewSession`「新会话」/「在 dsh 中打开」；重根收口到 `AppDelegate.adoptProjectDirectory(_:)`（当前工作区始终是壳层 `ProjectDirectory`，面板不引入第二个选中态），实现为 `ProjectsCore.swift`（纯模型）+ `ProjectsPanel.swift` + `DshWebRPC.swift` 的 `workspaceCreate`/`DshWorkspaceOps`（设计 `docs/projects-panel-design.md`，测试 `tests/projects-panel/` 94 项、`tests/dsh-rpc/` 新增 14 项）；同时视图菜单「显示/隐藏 预览面板」**正名「显示/隐藏 文件面板」、快捷键 ⌥⌘P → ⌥⌘F**（⌥⌘P 让给项目面板；L10n 键 `menu.togglePreview` → `menu.toggleFiles`，设置窗口快捷键清单同步）；此前合并 **PR #52 `feature/ux-feedback-fixes`**——**使用问题清单（`docs/ux-feedback.md`）九条集中落地**：Files 面板目录树右键菜单（新建文件夹/文件 → 重命名 → 删除（废纸篓）→ 在 Finder 中显示，判定抽成纯模型 `FilePanelTreeMenu.swift`）+ 头部改为 **`PanelMenuButton`「打开项目 ▾ / 打开文件 ▾」**（`OpenWithApps.swift` 提供 Finder/13 编辑器 IDE/8 终端目录，记忆键 `files.openProjectWith`）+ **图片预览自适应与手动缩放**（`ImagePreviewView.swift` + 纯模型 `ImageZoom.swift`：5%–1600%、⌘+/−/0、⌘滚轮、捏合、双击、拖拽平移、居中留边距 + 固定尺寸角标）+ **大文件不再关高亮而是分块着色**（`EditorLoadPolicy.swift`：300 行/32 KB 分块 + 0.6s 写文件稳定性窗口 + 后台读取，安全阀只对 >4 万行 / >4 MB）+ **目录... (line truncated to 2000 chars)

## 目录布局

```
core/                共享核心（Node 模块：ANSI 模拟器 / 端口探测 / 升级 / 会话 RPC / issues / jobqueue / tasks 关联索引 / dsh RPC 传输层 / shell 设置 / workspace 存储 / channel 通道（抽象+路由+指令+存储+微信 ClawBot 与钉钉 dingtalk-stream 适配器+会话驱动）/ review-log 会话日志变更审计（zstd 多帧解码；按规范文件名枚举 `session(.vN)?.jsonl(.zstd)?` 取世代最大者）/ snapshot + snapshot-io 会话快照与回退（纯决策 / 事务状态机 + clonefile 落盘 / 树池 / 隔离 / 裁剪，`ohmy-core snapshot …` CLI），跨平台复用；随构建嵌入 runtime/core）
platforms/           各平台壳（macos/ 现有壳，windows/ linux/ 规划中）
scripts/             跨平台工具（version.sh 版本单一来源 / changelog.sh / release-checksums.sh 校验和 / github-publish.sh 发布 / local-release.sh 本机 Release / git-remote.sh 远端检测 / release-fix.sh patch 发布 / 迁移脚本）
.github/             CI 工作流（core 单测走 ubuntu；壳层单测/编译检查 + arm64 构建走 macos-14；x86_64 交叉编译由 release.yml 打 tag 时构建，不再出 universal，也不再依赖退役中的 macos-13 runner）；release.yml 发布幂等（先删旧 release+tag 再 --target 重建）+ prepare 前置 job 预编译双架构 CEF 统一缓存，见 [tasks](tasks.md)
Jenkinsfile          Jenkins 打包 + GitHub Release 发布（macOS agent 上 build-app.sh + make-pkg.sh；gh CLI / curl API 兜底），见 [build-scripts](modules/build-scripts.md)
platforms/macos/src/main.swift       壳层核心（日志/L10n/服务管理/升级/窗口/菜单/设置窗口/onboarding/CoreBridge/⌘R 重新认证刷新）5139 行（实测）
platforms/macos/src/FilePanelTreeMenu.swift 文件面板目录树右键菜单纯模型（TreeMenuModel：分组顺序与置灰规则）62 行
platforms/macos/src/OpenWithApps.swift    「用外部应用打开项目目录」目录（OpenWithCatalog：面板/Finder/13 编辑器 IDE/8 终端，按 bundle id 探测安装）125 行
platforms/macos/src/ImagePreviewView.swift 图片预览视图（缩放/平移/居中 clip view/固定尺寸角标）309 行
platforms/macos/src/ImageZoom.swift      图片缩放数学纯模型（适应比例 / 夹取 / 单步）55 行
platforms/macos/src/EditorLoadPolicy.swift 编辑器载入策略纯模型（分块高亮 / 安全阀 / 写文件稳定性窗口）91 行
platforms/macos/src/TerminalWorkspaceTabs.swift 终端页签 ↔ workspace 归属纯模型（隐藏不杀会话、恢复选中、全局兜底页签）106 行
platforms/macos/src/ShellConfig.swift   壳层设置读写（$DSH_HOME/shell/config.json，UserDefaults 同形 API + 旧键一次性迁移）188 行
platforms/macos/src/DshWebCookieJanitor.swift dsh 认证 cookie 清理（cookie 名派生 / 启动清旧 / 退出清本次）+ NODE_OPTIONS 头预算 152 行
platforms/macos/src/PreviewPanel.swift  预览面板回滚基线 + 共享 UI 组件（1765 行，含新增 `PanelMenuButton` 头部菜单按钮；`DynamicFillView` 脏矩形夹取修复见 [preview-panel](modules/preview-panel.md)）；现行预览实现为 FilePanel.swift
platforms/macos/src/FilePanel.swift      文件面板（`FilePanelController`，PreviewPanel 强化分支：预览+编辑+行号+语法高亮+目录树菜单+头部菜单按钮+图片缩放+树宽恢复）2358 行
platforms/macos/src/CodeEditorView.swift 代码编辑器视图（行号栏 + 可编辑 + Highlightr 分块语法高亮 + 后台重载）500 行
platforms/macos/src/vendor/Highlightr/   Vendored 语法高亮组件（Highlightr MIT v2.3.0 + highlight.js 资源）
platforms/macos/src/TerminalPanel.swift 终端面板（PTY 会话 + ANSI/VT 模拟器 + 页签按 workspace 隔离 + 选中即复制）2180 行
platforms/macos/src/WikiPanel.swift      Repo Wiki 面板（知识库生成/维护/浏览 + 自动 git 提交）约 2072 行
platforms/macos/src/IssueRunnerPanel.swift 任务面板（手动任务 + GitHub issue 两种来源 / 队列泳道严格串行 / 内联表单 / 队列结束后的「开 PR 会话」/ 按仓库作用域 token）2296 行
platforms/macos/src/TasksCore.swift     任务 / 队列纯模型（TaskItem / TaskQueue / TaskBoard / TaskDraft / 分支命名 / 状态机）1027 行
platforms/macos/src/TasksStore.swift    `.dsh/tasks/` 四文件读写（index / manual / queues / local，读侧容错）130 行
platforms/macos/src/TasksRunner.swift   队列运行器（git 进入分支、dsh 会话、提示词、开 PR 会话、取消 / 重试 / 跳过、重启恢复）1336 行
platforms/macos/src/TasksUI.swift       任务面板视图模型（卡片 / 队列头 / 统计 / 空态 / 两张表单的模型）1014 行
platforms/macos/src/TaskCardView.swift  任务卡片与队列块视图（只渲染与转发点击）878 行
platforms/macos/src/TaskInlineForms.swift 面板内联表单（新建·编辑任务 / 新建·设置队列，无模态）939 行
platforms/macos/src/TasksAPI.swift      任务面板 localhost API 路由 `/api/tasks/*`（纯模型：路由命中、请求解析、工作区解析）215 行
platforms/macos/src/TasksWorkspaces.swift 跨工作区运行器注册表（一个工作区一个 runner，非当前仍在跑的一直被 tick）122 行
platforms/macos/src/ChannelPanel.swift    通道面板（全局 channel 卡片 + 扫码登录向导 + 项目视图开关 + 连接状态徽标 + runner 生命周期）850 行
platforms/macos/src/ReviewPanel.swift    审查面板（只读变更审计：会话→对话→文件→变更内容 树 + 按需审计缓存 + 日志身份失效 + 在屏每 5s 轮询 + 跟随 dsh web）1122 行
platforms/macos/src/ReviewLogModel.swift 审查面板展示模型（纯 Foundation：JSON 解码 / 文件分组 / turn 分组 / diff 折叠 + ReviewLogStamp 日志身份）390 行
platforms/macos/src/SkillsPanel.swift     技能面板（已安装/可安装 / registry 管理页 / 调用开关 / 安装移除 / hover 解析）1667 行
platforms/macos/src/SkillsCore.swift      技能模型（frontmatter 读写与可逆开关、四根扫描与级别判定、壳层记录 shell/skills.json）742 行
platforms/macos/src/SkillSources.swift    技能来源（地址解析、registry 清单与搜索、well-known / GitHub 拉取、安装/移除服务，传输可注入）919 行
platforms/macos/src/SkillInstaller.swift   内置 Skill 全局安装器（App 启动装到 $DSH_HOME/skills/ + 缺失即装/受管更新/旧名迁移，Foundation-only；技能面板**不改它**，对内置级别只读以保证字节一致）307 行
platforms/macos/src/BrowserPanel.swift 浏览器面板（多标签 CEF/Chromium，OSR 渲染 + REST API 驱动）约 1123 行
platforms/macos/src/BrowserAPI.swift   浏览器面板 REST API（127.0.0.1:3081，Agent 驱动 + QA 端点）530 行
platforms/macos/src/BrowserCDP.swift   CDP 客户端（WebSocket：console/网络/求值/截图）303 行
platforms/macos/src/MakeIcon.swift       App 图标生成器（渲染 → iconset → icns）104 行
platforms/macos/src/ProjectsCore.swift   项目面板纯模型（项目根解析 / 命名规则 / 目录列举 / 与 dsh 注册表按 canonical 路径合并）217 行
platforms/macos/src/ProjectsPanel.swift  项目面板（工作区卡片三行 + 头部 + 根目录行 + 空态 + 结果行 + 取名 sheet）851 行
platforms/macos/src/DshWebRPC.swift      壳层原生 dsh RPC（信封形状 / 斜杠↔点号回退 / launch token 换 cookie，含 `workspaceCreate` 与 `DshWorkspaceOps`）438 行
platforms/macos/src/ComposerReference.swift 输入框 `@` 引用纯模型（引用语法 + 相对路径）90 行
platforms/macos/src/SnapshotModel.swift  会话快照窗口数据模型 166 行
platforms/macos/src/SnapshotWindow.swift 会话快照 / 回退窗口（预览 → 二次确认 → 回退并退出）245 行
platforms/macos/runtime-locks/<spec>/   已提交的 dsh 依赖闭包锁（`package.json` + `package-lock.json`；0.1.5-rc.3 那份 584 包，0.1.2-rc.1 那份 583 包保留供快照回退），构建用 `npm ci` 复现，并随 App 嵌入 `Contents/Resources/runtime-locks`
platforms/macos/build-app.sh         一键构建脚本（6 步：目录/图标/编译/运行时/Info.plist/签名）
platforms/macos/build-cef.sh         CEF 构建脚本（版本 pin + sha1 校验 + 缓存；wrapper/shim/五 helper 编译）
platforms/macos/cef/                 CEFShim.h/.mm（ObjC++ 桥，OSR 渲染/输入转发/DevTools）、process_helper_mac.cc、helper-Info.plist.in
platforms/macos/make-pkg.sh          .pkg 安装包 + .dmg 镜像脚本
docs/                设计与排查文档（repo-wiki-design.md、review-panel-design.md（审查面板设计/覆盖矩阵）、skills-manager-design.md（技能面板：四档级别判定 / registry 模型 / 开关可逆写法）、productization.md、git-workflow.md、release-process.md、ui-color-scheme.md（面板配色方案：令牌表 / 取色 API / 应用映射）、projects-panel-design.md（项目面板）、file-panel-composer-reference.md（目录树「添加到对话」的 `@` 引用注入桥）、session-snapshot-rollback-design.md（会话快照与回退）、dsh-version-impact.md、milestones/、plans/（dsh-015rc2-compat-audit.md：0.1.5-rc.2 兼容审计；2026-09-27 已按 rc.3 执行完毕）、terminal-header-fix.md、terminal-input-fix.md、channel-*.md、raw/）
tests/               无头单元测试（terminal-emulator/、wiki-panel/、browser-panel/、channel-panel/、dsh-rpc/、review-panel/、file-panel/（6 个测试文件，含真实 NSWindow 场景）、terminal-panel/、l10n/、shell-config/、dsh-auth-cookies/、skills/、skills-panel/、projects-panel/（模型 45 + 控制器 49 = 94 项）、tasks-panel/（任务面板逻辑层五段 = 1129 项）、injected-scripts/（注入 dsh web 的 JS 守卫：可解析 + 桥名对得上 + 不许出现会被 Swift 吃掉的转义）、snapshot-panel/、snapshot-rollback/（端到端，含升级路径与崩溃拒绝），各含 run.sh；模拟器测试已迁 core/tests/ansi.test.js 的薄封装）
.cache/              构建缓存（node tarball、npm-cache、已构建 runtime）— git 忽略
.build/              构建中间产物 — git 忽略
dist/                产物（.app / .pkg / .dmg）— git 忽略
pic/                 QA 调试截图 — git 忽略
.dsh/skills/         内置 skill 提交副本（web-dev-tools / repo-knowledge / task-todo，App 启动经 SkillInstaller 安装到全局 $DSH_HOME/skills/；issue-resolve 已于 2026-09-27 退役，受管副本启动时删除）
.dsh/wiki/           本知识库
.dsh/tasks/          任务面板四文件（index.json 提交 + manual.json / queues.json / local.json 本机，后三者 gitignore）
```

## 构建

```bash
./platforms/macos/build-app.sh --prefetch   # 可选：预下载 Node + 预装 dsh 到 .cache/，不产出 App
./platforms/macos/build-app.sh              # 全量构建 → dist/oh-my-dsh.app
```

- 编译命令：`swiftc -O -swift-version 5 -framework AppKit -framework WebKit -framework PDFKit`，源文件清单单一事实来源 `swift-sources.sh`（glob 收录 `src/*.swift` + `vendor/Highlightr/*`，只排除独立工具 `MakeIcon.swift`，`build-app.sh` / `local-ci.sh` / `ci.yml` 共用，新增文件无需逐个登记）+ CEF 产物（`build-cef.sh` 产出 wrapper/shim/五 helper，由内向外签名）；
- 内置运行时构建期现做：下载 Node tarball（默认国内镜像 `npmmirror.com/mirrors/node`，校验 SHA-256），用其自带 npm 在 `runtime/dsh` 装 `@deepseek-ai/dsh@0.1.5-rc.3`（默认 `DSH_PACKAGE_SPEC`，国内源失败自动回退 npmjs.org）——**按 `platforms/macos/runtime-locks/<spec>/{package.json,package-lock.json}` 的已提交闭包锁 `npm ci` 复现**（只钉 `DSH_PACKAGE_SPEC` 不够：dsh 用 caret 声明 cordis 工具链，闭包会随上游发版漂移，实测导致新构建的 dsh web 打印入口 URL 后立刻退出；没有 lock 的 spec 走老路并**大声警告**），装完做**启动冒烟** `smoke_runtime`（起一次 `dsh web`，40 秒内必须打出入口 URL 且进程存活，否则**构建失败**；跨架构 stage 自动跳过，`DSH_SKIP_RUNTIME_SMOKE=1` 可临时跳过）；构建日志应出现 `using committed runtime lock: …` 与 `smoke: dsh web came up`；
- 缓存：`node|spec|arch|lockHash` 相同则复用 `.cache/runtime`（**缓存键含 lock 指纹**，改锁即重建，避免复用漂移过的旧树），重建只需几十秒；网络不可用时用缓存 tarball 推导版本继续。

构建变量（均可用环境变量覆盖）：`DSH_NODE_VERSION`、`DSH_PACKAGE_SPEC`、`DSH_NODE_MIRROR`、`DSH_NPM_REGISTRY`、`DSH_ARCH`、`DSH_DEV_BUILD`（=1 打开发版：Info.plist 写 `DSHDevBuild=1`、独立 CEF profile、跳过单实例退出，可与正式版并存测试，详见 [build-scripts](modules/build-scripts.md) 与 [main](modules/main.md)）。

## 运行

```bash
open "dist/oh-my-dsh.app"     # 或双击
```

- 运行时**无需**本机安装 Node 或 dsh（自包含）；
- 启动**从不复用**已有实例（2026-09-12 起复用分支整体删除：dsh ≥ 0.1.2 的 `/api` 只认本进程 launch token 换来的 cookie，复用别人的实例必然无 token → 原生 RPC 全 401），先回收自己上次残留的实例（`$DSH_HOME/shell/dsh-web.json` 记 pid/port/token，用 token 探活确认真是自己的才杀），再按 node 选择策略（`DSH_NODE` > 系统 node（PATH→nvm current→nvm default→nvm 最新→Homebrew，候选须 ≥ 22.0.0，`DSH_NODE_MIN` 可覆盖）> 内置 node）拉起 `dsh web --port <n>`（3080 被占自动换空闲端口），dsh web 环境合并登录 shell PATH（`loginShellPath()`），系统 node 启动失败自动回退内置 node 重试一次（`DSH_NODE` 显式指定不回退），90 秒超时 + 1s 沉降校验；
- **项目目录跟随当前会话**：壳层注入 `sessionTrackerScript` 监听 dsh web 的会话 RPC（`session.history/prompt/rename/selectModel`、`subagent.list`），用户切换会话/工作区时经 `dshSession` 消息把新的项目目录同步给预览树、终端新会话、wiki 根与任务面板（共享 `ProjectDirectory`；任务面板跟随会话**无条件**刷新——workspacePath 权威、非 GitHub 仓库诚实显示空态，见 [architecture](architecture.md)）；
- 日志：`~/Library/Logs/oh-my-dsh/app.log`（壳层）、`server.log`（自拉起服务输出）。

## 测试

```bash
node --test --test-timeout=60000 core/tests/*.test.js   # 共享核心单测（ANSI 模拟器 / 端口 / 升级 / 会话 RPC / dsh RPC / settings / workspace-store / issues / jobqueue / tasks / channel / review-log / snapshot，**261 用例（25 个 `.test.js`）**；不带引号由 bash 展开 glob，Node 20 兼容；--test-timeout 让泄漏定时器的用例 60s 失败而非挂死整套）
tests/terminal-emulator/run.sh       # 模拟器测试（已迁 core/tests/ansi.test.js 的薄封装）
tests/wiki-panel/run.sh              # Repo Wiki 模型层无头单测（实测 41 passed）
tests/skills/run.sh                  # 内置 skill 安装器无头单测（SkillInstaller：缺失即装/更新/跳过/迁移/字节一致）
tests/channel-panel/run.sh            # 通道项目视图数据模型（ChannelStoreReader 读全局 store）
tests/dsh-rpc/run.sh                  # 壳层原生 dsh RPC（信封形状 / 斜杠↔点号回退 / launch token 换 cookie；整套 54 项）
tests/review-panel/run.sh             # 审查面板（展示模型 64 项 + 控制器日志新鲜度回归 12 项 = 76 项）
tests/skills-panel/run.sh             # 技能面板（模型层 + 控制器冒烟 + 真实绘制回归，150 项；含 HeaderLabel 截断/不越界）
tests/shell-config/run.sh             # ShellConfig 旧 UserDefaults 一次性迁移（13 例：旧值迁移 / 只做一次 / config.json 优先 / 不搬无关键）
tests/dsh-auth-cookies/run.sh         # dsh 认证 cookie 清理纯逻辑（22 例：cookie 名派生向量 / 启动与退出清理选择 / NODE_OPTIONS 追加规则）
tests/file-panel/run.sh              # 文件面板（workspace-tab 模型 28 例 + open-with / tree-menu / image-zoom / editor-load-policy + 真实 NSWindow 面板场景；2026-09-21 实测全绿）
tests/preview-interceptor/run.sh      # 注入的文件打开拦截脚本（从 main.swift 抽取 previewInterceptorScript，DOM stub：三类点击捕获（内联 / 产出行 / 工具行 fileLink）+ host.openPath/session.openWorkspacePath fetch 形状，11 例）
tests/terminal-panel/run.sh          # 终端面板（头部固定标题 + TerminalWorkspaceTabs 工作区隔离 + 选中即复制开关；2026-09-21 实测全绿）
tests/projects-panel/run.sh          # 项目面板（纯模型 45 项 + 控制器无头 49 项 = 94 项）
tests/tasks-panel/run.sh             # 任务面板逻辑层五段（模型 176 + 运行器 362 + 视图模型 324 + 视图 199 + 本地 API 68 = 1129 项）
tests/injected-scripts/run.sh        # 注入 dsh web 的 JS 守卫（可解析 / `window.__dshX` 桥名对得上 / 不许出现会被 Swift 吃掉的转义）
tests/snapshot-panel/run.sh          # 会话快照窗口数据模型
tests/snapshot-rollback/run.sh       # 会话快照与回退 CLI 端到端（含升级路径与崩溃拒绝）
```

- core 单测为 Node 测试（`core/tests/*.test.js`：ansi 42 / ports 5 / session 4 / upgrade 10 / issues 8 / jobqueue 7 / tasks 18 = 94 + 其余（channel 相关 / dsh-rpc / workspace-store / settings / review-log 24 / snapshot 14 / snapshot-io 7 等）= **277 用例（26 个 `.test.js`），2026-09-27 本机实测 273 通过 / 4 跳过 / 0 失败**（Node v20.19.6 无 zstd，跳过项全是 review-log 的 zstd 用例）；channel 覆盖 channel/commands/runner/sessions/workspaces/weixin-clawbot/dingtalk/e2e-channel/channel-association/channel-busy/project-switch）；`tests/terminal-emulator/run.sh` 现为 `core/tests/ansi.test.js` 的薄封装；
- Swift 无头单测模式（`tests/wiki-panel/`）：`stubs.swift` + 复制源码 + 测试文件改名 `main.swift` → `swiftc` 编译成可执行文件运行（无窗口/无 PTY 依赖）；
- 设计文档（`docs/repo-wiki-design.md` §14）记录 v1.7.0 验证：全量编译零错误、wiki 单测 41/41（实测 `tests/wiki-panel/run.sh` 41 passed）、终端模拟器 46 项回归全过（Swift 实现，后迁 core/tests/ansi.test.js 42 项）；并记录 16 轮修复（build 43→63，其中修复 10–14：生成中提示改叠加浮层、定位状态条合成溢出根因、生成状态按工作区关联、终端新会话目录跟随当前工作区等，详见 [wiki-panel](modules/wiki-panel.md)；修复 15 移除失效的 `attachOrphans`、16 repo-wiki SKILL 优化）；
- 产品化方案（`docs/productization.md`，2026-08-15，状态已批准执行）：P0 现状基线（v1.7.x，已达成）→ P1 开源基础（GitHub 公开 + MIT、CI、共享核心抽取，约 1–2 周）→ P2 Windows 版（≈2–3 个月）→ P3 Linux 版（≈1–2 个月）→ P4 生态增长；Apple 生态（Developer ID 签名/公证/Sparkle 升级/Homebrew Cask）依赖开发者账号，统一暂缓至最后阶段 F；配套 `docs/milestones/`（M1 产品化基础 … M5 Apple 生态 5 份里程碑目标文档，后续开发任务来源，见 README「目录」）。

## 已知限制（README 明示）

- 终端 v1 不支持输入法直接打字（中文等经 ⌘V 粘贴输入）、DECSTBM 滚动区未实现、会话不跨 App 重启保留；
- Wiki 面板 v1 搜索为标题过滤（无正文/语义检索）；
- 通道（channel）能力 README 已收录；设计/指令/状态/存储文档在 `docs/channel-*.md`；消息/会话存储**已全局化**（2026-08-22 落地于 `~/.dsh/channels/` 分桶，见 [channel-panel](modules/channel-panel.md)）；**「项目开关」关联（PR #30）存全局 `~/.dsh/channels/<channelId>.workspaces.json`**（project=workspace，见 [channel-panel](modules/channel-panel.md) 与 docs/channel-project-switch.md）；引用配置 `.dsh/channels.json` 旧路径文件仍未跟踪（迁移到 `.dsh/channels/channels.json` 并提交是待办）。
