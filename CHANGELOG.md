# Changelog

All notable changes to this project are documented in this file. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions below
`v1.8.0` are summarized from the git history (conventional commits).

## [Unreleased]

- **单实例约束（修复双实例争抢 CEF profile）**：App 启动时按 bundle id 检测是否已有其他实例在跑，若有则聚焦已有实例并立即退出，避免两个副本共用 `~/.dsh/browser` 导致 Chromium 异常退出（`Chromium didn't shut down correctly.`）。
- **开发版构建支持**：构建时 `DSH_DEV_BUILD=1` 打包开发版（Info.plist 写入 `DSHDevBuild=1`），或直接 `./scripts/local-ci.sh dev`（等价 full，但 build 用 `DSH_DEV_BUILD=1`）；开发版运行时自动使用独立 CEF profile（`~/.dsh/browser-dev`）并跳过单实例退出，可与已安装正式版并存测试；未来如需隔离端口/channel 等资源，在 `main.swift` 的 `isDevBuild` 覆盖处快速追加。

## [1.12.0] - 2026-08-22

### Added

- **通道面板（微信远程驱动 dsh）**（活动栏通道图标 + 菜单）：绑定微信个人号（官方 iLink 协议），在微信里发消息/斜杠指令远程驱动 dsh 干活——消息路由到项目会话、结果回复回微信；已跑通「扫码登录 → 长轮询收消息 → 指令/路由 → dsh 会话 → 回复回微信」**全链路**（真实微信 + 真实 dsh web 端到端验证）。
  - **配置面板**：全局配置视图 + 项目引用开关（写 `.dsh/channels.json`）；内置平台卡片（微信 ClawBot / 钉钉 / 飞书，带**实时连接状态徽标**）；微信扫码登录**在面板内渲染二维码**（CIQRCodeGenerator，不弹浏览器），登录态落 `~/.dsh/channels/<id>.json`（文件优先，chmod 600）；统一 40pt HeaderLabel 样式，顶部「全局配置」随时重开；
  - **项目视图**：Channel 行默认展开 Sessions + 原生 NSSwitch（灰绿）开关 + 展开区显示真实会话；行占满整宽、从内容区顶部渲染；
  - **微信内斜杠指令**：`/help`（分组排序）、`/ping`、`/status`（新格式）、`/workspaces`(`/wks`，代号+标题+`~`路径)、`/new`（无内容只创建标记 pending 等待首条消息激活、有内容创建并立即 prompt，落 workspaceId）、`/sessions`(`/ses`，工作区头+最近 5 条)、`/switch`；快捷指令 `#w1`/`#s1...`（切项目/会话，未找到有明确提示）与 #tag 路由（如 `#w1 帮我看看`）；
  - **会话驱动**：conversationId → dsh 会话映射（多轮续接，`/new` 另起），经 `session.create` + `session.prompt`（queue）驱动，回复回传微信；通道级全局状态（lastWorkspace / 会话映射 / activeSession）持久化 `~/.dsh/channels/<id>.state.json`（重启可恢复，写失败尽力不抛错）；
  - **生命周期**：启动自动拉起已配置 channel runner、退出关闭；绑定成功后自动启动 listener；SIGTERM 立即退出不留僵尸进程；runner 去重（同 channelId 不重复启动）。
- **通道核心入 `core/`（跨平台复用）**：统一抽象层（ChannelEvent / ChannelReply / 状态机 / Router / 管理编排）+ 微信 ClawBot 适配器（transport **重写为纯官方 iLink 协议**，由 `@tencent-weixin/openclaw-weixin` 2.4.6 官方源码推导）+ CLI（`channel login` / `listen` / `reply` / `run`，vendor qrcode-terminal）+ 单测（指令 / 路由 / 会话 / 传输层，全绿）。
- **文件面板升级为预览 + 编辑器**（`⌥⌘P` / 活动栏「文件」图标）：UTF-8 且 ≤2MB 的代码/文本文件面板内直接编辑，**行号栏随滚动严格对齐**（gutter 逐行按实际字形基线绘制）、**语法高亮**（vendored Highlightr，180+ 语言，明暗自适应）；未保存页签显示 `*`；`File ▸ 保存`（⌘S）原子写回，`File ▸ 关闭页签`（⌘W / Ctrl+W）；保存图标 + File 菜单置于 Edit 前；设计文档 `docs/plans/PREVIEW_PLAN-file-panel.md`（rollback-first）。
- **CI / 测试补齐**：local-ci 与 GitHub swiftc 编译清单登记 FilePanel / CodeEditorView / Highlightr / ChannelPanel；channel 单测并入 `node --test core/tests/`；clawbot 测试 mock 只返回一次消息、移除依赖真实 dsh web 的 e2e（避免残留临时会话/目录）。

### Fixed

- **通道消息重复回复**：轮询改**严格串行 while 长轮询**（对齐官方 monitor）——setInterval 破坏 `get_updates_buf` 游标推进导致同一消息被反复处理/重复回复（根因与验证见 `docs/channel-issues.md`）。
- **通道路由/状态**：通道级状态写入加内存缓存，避免 onState 与 setActiveSession 并发写 state 文件互相覆盖；`/new` 创建后立即用 /new 文本 prompt（会话非 blank、dsh web 可见）；快捷指令未找到提示更新（`#wN` → 未找到工作区、`#sN` → 未找到会话）；`/wks` 显示 workspace title + `~` 缩短路径不泄露用户目录；加载全局通道过滤历史坏 id；`channel run` 默认 dshHome=~/.dsh 使 CLI 可用。
- **面板 v2 UI**：分隔线位置修正（去掉标题/工具条之间、保留工具条/内容区之间）；工具条清空（无文字无线）+ 引导标题/卡片改纯 Auto Layout 左对齐；项目视图从内容区顶部渲染（FlippedStackView）、行占满整宽、展开手势移回 Channel 名（不再吞开关点击）。
- **代码编辑器**：Highlightr() init 崩溃防护；行号栏滚动去同步/末行缺失/越界/首布局漂移——按每行实际字形基线绘制、布局稳定后重绘。
- **终端启动目录**：解析忽略系统临时目录会话（`chan-e2e-*` 测试残留），终端不再默认落在测试临时目录。
- **CI 编译清单**：补齐 ChannelPanel.swift（修复 ChannelPanelController 未定义）与 FilePanel/CodeEditorView/Highlightr。

### Docs

- **通道文档**：`docs/channel-design.md`（能力设计：统一抽象 + 微信/钉钉/飞书多平台扩展 + ClawBot 可行性）、`docs/channel-commands.md`（指令清单）、`docs/channel-status.md`（完成状态总览）、`docs/channel-storage.md`（存储全局化设计）、`docs/channel-issues.md`（重复回复根因排查）。
- **文件面板**：`docs/plans/PREVIEW_PLAN-file-panel.md` 设计文档（预览增强，rollback-first）；README「预览面板」小节改为「文件面板」（预览 + 编辑 + 高亮）。
- **发布流程固化**：`docs/release-process.md`（四步发布：CHANGELOG → tag → local-release → 版本推进）；AGENTS.md 增补发布指引与 GitHub token 位置；SECURITY.md Supported Versions 同步步骤。
- **README / CONTRIBUTING 覆盖本次发布内容**：新增 Channel 面板介绍（右栏面板 + 特性一览 + 截图）；项目结构/测试清单补 channel 模块与文件面板组件；wiki 同步（channel-panel / file-panel 模块页、架构/数据模型/任务/构建脚本刷新）；README 增加 app 截图。

## [1.11.0] - 2026-08-21

### Added

- **浏览器面板（Chromium/CEF 内核）**（活动栏 globe / `⌥⌘B`）：多标签浏览器，每标签一个 Chromium 渲染进程（五 helper app：base/Alerts/GPU/Plugin/Renderer，名字承重）；地址栏导航（无 scheme 自动补 `https://`）、后退/前进/刷新·停止；控制台抽屉（CDP 捕获 console/异常/全部网络请求 + JS 求值 + 清空）；DevTools 按钮在系统浏览器打开完整 Chromium DevTools；`use-mock-keychain` 不弹钥匙串密码框；profile 收在 `~/.dsh/browser/`。
- **浏览器 REST API**（`127.0.0.1:3081`，`DSH_BROWSER_PORT` 覆盖，端口文件 `~/.dsh/browser-api.port`）：`status`/`open`/`tabs`/`back`/`forward`/`reload`/`stop`/`eval`/`console`/`console/clear`/`screenshot`/`hide`，CORS 放行；Agent 驱动自动展开面板；配套技能 `.dsh/skills/shell-browser/SKILL.md`（modelInvocable）。
- **DevTools 工具条可拖动调高**（150–700pt，主窗口联动压缩）：拖动条悬停显示上下拖拽光标；拖动中主页面/DevTools 两 CEF 视图完全静止（frame/视口不动）、全程禁用 autoresizing、跳过 layout 钩子、抑制逐帧 notifyResize，松手统一对齐并恢复页面滚动位置（CDP 记录 scrollY、松手 scrollTo）；80ms resize 节流消除逐帧重排导致的页面抖动上移（详见 `docs/devtools-drag-fix.md`）。
- **视图菜单「外观」切换**（`feat(#6)`）：浅色/深色/系统三态，与设置窗口外观双向同步。
- **App 体积精简**（约减 ~138M）：slim app bundle（移除重复 node ~116M、node-pty win32 prebuilds），见 `docs/plans/APP_SLIM-app-size.md`。
- **活动栏图标顺序与文案调整**：Files(重叠文件图标)/Terminal/Browser/Wiki/Tasks，tooltip 固定英文。
- **CEF 构建管线**（`platforms/macos/build-cef.sh`）：版本固定 + sha1 校验 + `.cache` 缓存；wrapper/shim/helper 编译；五 helper 组装与由内向外签名；`build-app.sh`/CI 接入。
- **本地发布/CI 工具链**：`local-release.sh` 支持 `pack` 子命令（只打包不发布）；发布模式强制版本一致性（版本单一来源 git tag，不一致即阻断）；runtime 缓存按架构分目录、双架构 release 不再互相覆盖重建；CEF 缓存 key 改用稳定绝对路径。
- 测试：`tests/browser-panel/`（日志缓冲/URL 规范化/HTTP 解析/REST 路由，56 断言）；CI 编译清单与浏览器测试步骤登记。
- 设计文档：`docs/plans/BROWSER_PLAN-browser-panel.md`（含根因修正：CEF 148+ 需五 helper，缺 `(Renderer)` 导致 renderer 静默失败——曾误判为签名问题）。

### Fixed

- **DevTools 拖动条导致 CEF 视图上移/底部空白**：根治为 contentsScale 同步 + CEF 视图 frame 统一由 layout() 同步（去手动/AutoLayout 竞争）、frame origin 强制为零；拖动中禁用 pageView/devtoolsContent 的 autoresizesSubviews、完全跳过 layout 钩子、抑制 notifyResize（此前每帧 WasResized 致页面缓慢上移），松手统一刷新——消除页面顶部反复重排跳动与累积上移。
- **CEF 覆盖式启动卡死**：覆盖式约束改用 activate 数组激活（init 里 `isActive=true` 曾致启动卡 buildWindow/Starting）；回退覆盖式约束并修 `CEFShim.shutdown` 未初始化时泵循环空指针；覆盖式切换后把主 CEF 视图钉回顶部全高（Chromium 会把 CEF 底部对齐致顶部空白）+ 视口一次 resize。
- **DevTools WebSocket 连不上**：CEF 默认拒绝带 Origin 的连接，加 `--remote-allow-origins=*` 放行；ws 获取改实时 `/json` 按 URL 匹配当前页签（CDP targetId 陈旧/误配导致 WebSocket 连不上）。
- **浏览器面板**：浅色外观页签背景调浅；DevTools 关闭闪退（窗口关闭拦截缺失）。
- **i18n**：语言切换后刷新各面板头部操作按钮与活动栏 tooltip（此前只重建菜单，tooltip 停留旧语言）；补 `terminal.closePanel` 文案、浏览器面板标题跟随语言切换；活动栏 tooltip 恢复系统语言切换（bar.preview 文案改为 文件/Files）。
- **IssueRunner 面板**：issue 关闭后标记实际状态 closed 并适配操作按钮。
- **dsh web 自拉起**：加 `--no-open`，避免默认浏览器被自动打开。
- **发布/CI**：`$VER` 统一加花括号 `${VER}` 修复 UTF-8 locale 下 unbound variable；local-ci.sh swift 阶段补齐 browser 面板测试与 CEF 编译。

### Docs

- `docs/devtools-drag-fix.md`：DevTools 拖动条导致 CEF 视图上移问题分析与修复方案。
- `docs/plans/BROWSER_PLAN-browser-panel.md`：浏览器面板设计（含 CEF 五 helper 根因修正）。
- wiki 同步：浏览器面板 OSR/Chromium 演进、五面板结构、发布/CI 工具链、per-arch 缓存。
- 合并规范：PR 合并一律用 `--no-ff`（merge commit）。

## [1.10.0] - 2026-08-18

### Added

- **系统优先 node 选择策略**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），内置 node 仅作兜底；`DSH_NODE` 显式覆盖仍无条件优先（无回退）。
- **About 面板显示实际 node**：显示实际运行 dsh web 的 node 版本与路径，合并为一行。
- **dsh web 环境合并登录 shell PATH**：App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；不再向 PATH 注入内置目录。
- **GitHub token 按仓库作用域**：解析优先级 Keychain 专属（`<owner>/<repo>`）→ `~/.dsh/tokens/<owner>-<repo>` → Keychain 通用 → `~/.dsh/gh-token`；多工作区各用各的 token（App 与外部工具/代理共用同一份）。
- **GitHub token 双写保存**：面板保存时 Keychain + `~/.dsh/tokens/<owner>-<repo>` 文件（chmod 600）双写，清空时双清。
- **GitHub token 文件优先读取**：token 读取改为文件优先（免 Keychain 密码提示），Keychain 写入设 `kSecAttrAccessibleAfterFirstUnlock` 免每次弹密码。
- **issue 处理按统一分支规范**：feature 类 issue 切 `feature/issue-N`，bug/其他切 `fix/issue-N`（按 label 判定）；issue-fix skill 分支说明同步。
- **issue-fix skill 自动安装**：任务开始时 `ensureIssueFixSkillInstalled` 写入 `<repoRoot>/.dsh/skills/issue-fix/`（内嵌副本与仓库字节一致、幂等），全新工作区也能处理 issue。
- **`scripts/git-remote.sh`**：push 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。
- **文档**：`docs/git-workflow.md`（统一分支与发布规范：main 只合并/只打主版本，feature/fix/release 分支模型，patch 版本同步回 main 走 PR）；AGENTS.md 补充分支提交强制规范与 GitHub token 位置；`.dsh/wiki` 知识库同步刷新。

### Changed

- **Node 选择策略反转（系统优先、内置兜底，含版本门槛）**：`dsh web` 启动优先使用操作系统安装的 node（PATH → nvm current → nvm default → nvm 最新 → Homebrew），但**低于版本门槛（默认 22.0.0，`DSH_NODE_MIN` 可覆盖）的系统 node 会被跳过**——dsh rc.6 实际需要 Node ≥ 22（`node:zlib` 的 zstd ESM 导出、`Promise.withResolvers`、`node:module.stripTypeScriptTypes`，Node 20 全部缺失，实测 v20 启动 dsh web 会崩在插件树加载）；仅当系统 node 缺失/过旧、或用它启动 dsh web 失败时才回退内置 node；`DSH_NODE` 显式覆盖仍无条件优先（无回退）；启动轮询增加 1s 沉降校验，避免"引导页含 `__DSH_BOOT__` 但随后崩溃"的假就绪。
- **dsh web 环境不做 PATH 注入，但合并登录 shell PATH**：移除启动与升级路径的内置目录 PATH 置顶；App 启动时经 `/bin/zsh -ilc` 读取一次登录 shell PATH（8s 超时兜底、失败保留继承值）赋给 dsh web，使其 bash 会话能使用用户全局工具（nvm bin、`~/.local/bin` 等，如 `agent-browser`）；About 面板的 Node 版本显示实际运行 dsh web 的 node。
- **CI action 升级**（dependabot）：`actions/upload-artifact` 4→7、`actions/setup-node` 4→7、`actions/cache` 4→6、`actions/download-artifact` 4→8。
- **版本 fallback 推进到 1.10.0**（v1.9.0 发布后的开发线版本）。

### Fixed

- **Tasks 面板跟随工作区切换**：dshSession 切换时无条件触发 `tasksPanel.workspaceChanged()`（不再依赖 ProjectDirectory 变化）；切换顺序修正为先 `ProjectDirectory.set` 再触发；`workspacePath` 非空时严格按当前会话判断（GitHub 仓库→显示 issues，非 GitHub→诚实显示 not a GitHub repo，不再 fallback 到其他 workspace），仅启动早期 ProjectDirectory 未解析时才用 `workspace.list` 兜底；Ungrouped 会话切回也能正确识别。
- **token 读取文件优先**（免 Keychain 密码提示）：顺序为文件专属 → 文件通用 → Keychain 专属 → Keychain 通用；配置框文案更正为按仓库双写（`~/.dsh/tokens/<owner>-<repo>`），配置按钮图标改齿轮。
- **壳层内嵌 repo-wiki skillMarkdown 同步**：补规则 8 提交指令（与仓库 SKILL.md 字节一致），修复 `ensureInstalled` 每次用旧内嵌版覆盖仓库文件导致提交规则丢失。
- **nvm 解析**：系统 node 解析 honor nvm default alias、prefer nvm current（最后一次 `nvm use`）。
- **git remote 名检测**：`git push` 前检测 remote 名（github 优先，origin 兜底），`release-fix.sh` 不再硬编码 origin。

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