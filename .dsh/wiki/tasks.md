---
title: 常见任务手册
tags: [tasks, build, package, test, debug, release]
updated: 2026-08-22T15:04:38Z
sources: [README.md, platforms/macos/build-app.sh, platforms/macos/swift-sources.sh, platforms/macos/make-pkg.sh, tests/terminal-emulator/run.sh, tests/wiki-panel/run.sh, tests/skills/run.sh, docs/terminal-header-fix.md, docs/terminal-input-fix.md, docs/git-workflow.md, docs/release-process.md, docs/channel-commands.md, docs/channel-status.md, docs/channel-storage.md, docs/channel-project-switch.md, scripts/version.sh, scripts/git-remote.sh, scripts/release-fix.sh, scripts/local-release.sh, scripts/release-checksums.sh, scripts/github-publish.sh, scripts/local-ci.sh, core/bin/ohmy-core.js, Jenkinsfile, .github/workflows/, core/tests/]
manual: false
---

# 常见任务手册

## 构建 App

```bash
./platforms/macos/build-app.sh --prefetch   # 首次或换版本时先预下载 Node + 预装 dsh 到 .cache/（可离线复用）
./platforms/macos/build-app.sh              # 全量构建 → dist/oh-my-dsh.app（复用 .cache 则无需网络）
```

- 产物：`dist/oh-my-dsh.app`（arm64、ad-hoc 签名、含内置运行时 + `runtime/core` 共享核心）；
- 常见失败：网络不可达 → 有缓存 tarball 会自动推导版本继续；`swiftc` 报错 → 检查新增文件是否登记进编译清单（第 3 步）；
- 重新构建会清掉旧包（`rm -rf "$BUILD_DIR" "$APP"`），`platforms/macos/make-pkg.sh` 依赖已构建的 `.app`。


## 构建开发版（与正式版并存测试）

```bash
DSH_DEV_BUILD=1 ./platforms/macos/build-app.sh     # Info.plist 写 DSHDevBuild=1
./scripts/local-ci.sh dev                          # 等价 full，但 build 用 DSH_DEV_BUILD=1
```

- 开发版运行时（`isDevBuild`）：CEF 用**独立 profile** `~/.dsh/browser-dev`（与正式版 `~/.dsh/browser` 隔离，不争抢）、**跳过单实例退出**——可与已安装正式版并存；
- 未来需隔离端口 / channel runner 等资源时，在 `main.swift` 的 `isDevBuild` 覆盖处快速追加；
- 单实例约束：正式版启动时若已有同 bundle id 实例在跑 → 聚焦它并立即退出（防双实例争抢 CEF profile 致 Chromium 异常退出「Chromium didn't shut down correctly.」）。

## 打包安装包（.pkg / .dmg）

```bash
./platforms/macos/make-pkg.sh   # 需先 ./platforms/macos/build-app.sh
# 产物：dist/oh-my-dsh-<version>-<arch>.pkg 与 .dmg（版本从 Info.plist 读取）
# 安装：open "dist/oh-my-dsh-<version>-<arch>.pkg"（装到 /Applications，preinstall 自动删旧版）
```

## 运行与验证

```bash
open "dist/oh-my-dsh.app"
```

- 验证点：窗口标题 `oh-my-dsh (DeepSeek Harness)`；活动栏图标互斥切换（预览/终端/知识库/任务/浏览器/通道）；⌥⌘P / ⌥⌘T / ⌥⌘W / ⌥⌘J 快捷键；About 面板显示 dsh/Node 版本与 registry；文件面板编辑文本后 ⌘S 保存、页签标题出现 `*` 未保存标记（见 [file-panel](modules/file-panel.md)）。

## 跑单元测试

```bash
node --test core/tests/*.test.js  # 共享核心单测（ANSI 模拟器 / 端口 / 升级 / 会话 RPC / issues / jobqueue / tasks / channel 通道，166 用例；不带引号由 bash 展开 glob，Node 20 兼容）
tests/terminal-emulator/run.sh      # 模拟器测试（core/tests/ansi.test.js 的薄封装）
tests/wiki-panel/run.sh             # Repo Wiki 模型层
tests/skills/run.sh                # 内置 skill 安装器（SkillInstaller：缺失即装/更新/跳过/迁移/字节一致）
```

- 均无窗口依赖，可在纯命令行环境运行；失败即非零退出（`set -euo pipefail`）；
- `tests/wiki-panel/run.sh` 会先 `mkdir -p .build/module-cache` 再编译（干净环境/CI 无 `.build/` 时必需，见 `c2d626b`）。

## 加一个新右栏面板（参照 v1.7.0 Wiki 面板）

1. 新建 `platforms/macos/src/<Panel>.swift`，实现 `PanelController`（复用 `HoverButton`/`DynamicFillView`/`CustomIconButton`）；
2. `platforms/macos/src/main.swift`：`RightPanel` 枚举加 case；`buildSplitView` 里创建 controller（`onRequestHide` + `serverPortProvider`）；活动栏加 `ActivityBarButton`；`activePanelView`/`setRightPanel` 分发；「视图」菜单加切换项（如 `⌥⌘X`）；`rightPanelKind` 持久化映射；
3. 新增 `.swift` 文件**无需登记**（`platforms/macos/swift-sources.sh` 单一事实来源，glob 自动收录；版本走 git tag + `scripts/version.sh`，勿手改）；
4. `L10n.table` 加中英文案键；README 特性说明；
5. 配套无头单测（仿 `tests/wiki-panel/`：`stubs.swift` + `run.sh`）。

## 改文案 / 语言

- 在 `main.swift` `L10n.table` 增改 `(zh, en)` 条目；菜单标题等直接调 `L10n.tr(...)`；
- 语言规则：`DSH_LANG` > `appLanguage` > 系统语言；切换会重建菜单并重载 web 页面。

## 升级内置 dsh（运行期）

- 手动：设置菜单 →「检查并升级 dsh…」(⌘U)；自动：设置菜单 →「自动升级 dsh」（默认开，24h 节流）；
- 只作用于内置运行时（路径含 `/Contents/Resources/runtime/`），不碰系统 dsh；
- 注意：升级会改写 App 包内文件导致 ad-hoc 签名失效（本地运行不受影响）；重新 `./platforms/macos/build-app.sh` 还原干净包。

## 重新生成/更新仓库知识库（Repo Wiki）

- 打开「知识库」面板（活动栏书图标 / ⌥⌘W）→ 右上「+」→ 生成（初始）或更新（增量）；
- 生成由 dsh 代理执行（`session.create` + `session.prompt` mode: queue），会话在 dsh web 左侧可见、可取消；生成期间阅读区上方**叠加半透明浮层**（居中「Generating…」+ 每秒耗时的底部状态条），页面与左侧树全程可见（代理每写出一页树即实时出现）；「取消」走 `session.cancel`；失败/取消后自动恢复原内容；生成状态按仓库关联，切换仓库不影响别处进行中的生成；
- 开关：设置菜单 →「自动更新知识库」「写入 AGENTS.md 注册块」「知识库根目录」（仓库内 .dsh/wiki 或 DSH_HOME 私有）。

## 排查问题

1. 看日志：`~/Library/Logs/oh-my-dsh/app.log`（壳层）、`server.log`（服务输出）；设置菜单「打开日志文件夹」(⌘L) 直达；
2. 面板渲染异常（白屏/按钮不可见）：`DSH_UI_DEBUG=1` 启动，读层级 dump 与 `panel-<label>-debug.png` 截图；对照 `docs/terminal-header-fix.md` 的合成陷阱检查 `wantsLayer`/`masksToBounds`；
3. 终端输入异常（粘贴乱码/方向键失效）：`DSH_TERMINAL_DEBUG=1` 看字节级 I/O；对照 `docs/terminal-input-fix.md`（写入 API 用 `withUnsafeBytes`；DECCKM/括号粘贴模式跟踪；强制 UTF-8 locale）；
4. 服务起不来：日志 `err.noNode`/`err.noDSH` → 设 `DSH_NODE`/`DSH_CLI` 指向本机安装；超时 90s → 看 server.log 尾部；
5. 预览面板不响应文件点击：`DSH_PREVIEW_DEBUG=1` 看探针（`__dshPreviewInstalled` / `__dshPreviewHit` / 伪造 `host.openPath` 的返回）；
6. 端口被占：默认 3080，`DSH_NATIVE_PORT` 指定端口；`DSH_NATIVE_FORCE_SPAWN=1` 强制自拉起（绕过复用检查）。

## 发布清单（简版，分支规范见 docs/git-workflow.md）

**主版本（vX.Y.0）**：

0. **更新发布文档**：`CHANGELOG.md`（必须用 `scripts/changelog.sh <上个tag>` 生成清单并 curate 进 `[Unreleased]`）+ **检查 `README.md`/`CONTRIBUTING.md` 覆盖本次发布内容**（新面板/特性/测试清单不遗漏）+ **主版本同步 `SECURITY.md` ## Supported Versions**（维护最近 2 个大版本：新版本进表、最老出表、EOL 边界上移；patch 版本支持表不变跳过）→ 同 commit（保证 tag 指向完整发布文档）；
1. 版本确认：main 上 HEAD 打 git tag vX.Y.0（`scripts/version.sh` 输出 VERSION/BUILD；`local-release.sh`/CI 均要求 HEAD 恰在 tag 上，版本单一来源 git tag）；
2. `./platforms/macos/build-app.sh` 全量构建 → `open dist/oh-my-dsh.app` 手工 QA（README 特性逐项过）；
3. `tests/*/run.sh` 全绿；
4. 打包 + 发布（二选一）：
   - 本机：`scripts/local-release.sh`（两架构）或 `scripts/local-release.sh pack`（只打包不发布）；自动读 version.sh、做 SHA-256SUMS、发布 GitHub Release；
   - 或 CI：push `v*` tag 触发 release.yml（见下）；
5. 提交时检查 `git status`：只含源码/文档/wiki 变更（.build/.cache/dist/pic 已忽略）；
6. 发布后**立即**把 `scripts/version.sh` 的 `FALLBACK_VERSION`/`FALLBACK_BUILD` 推进到下一个 minor（发布 v1.12.0 → fallback `1.13.0`/69），并更新 CHANGELOG 顶部 `[Unreleased]` 占位，单 commit。

**发布已知坑（v1.12.0 实战校准，见 `docs/release-process.md`）**：tag 推送会触发 CI release.yml，而 CI 的 **CEF prepare 前置 job 当前是坏的**（GitHub runner 上从 cef-builds.spotifycdn.com 下载超时，连续两代 Release run 挂死、publish job 被跳过）——**发布以本地 `local-release.sh` 为准**，CI 失败 run 直接忽略（暂不修复）；上传约 1.1GB 资产慢网耗时 1–2h+，`github-publish.sh` 已幂等化（release 已存在则复用只补传缺失资产 + 逐资产进度输出），中断可直接重跑；**发布统一走 curl API、暂不使用 gh CLI**（gh 分支保留为自动检测兜底）；DMG 构建必须 `danger-full-access` 沙箱（hdiutil 需访问 /dev）。

**已发布版本的 patch 修复（vX.Y.Z）**：用 `scripts/release-fix.sh <base-tag> <patch-version> [branch]`（如 `scripts/release-fix.sh v1.9.0 1.9.1`）——从 base tag 切 `release/1.9` 维护分支 → 提交修复 → 打 patch tag 推送（触发 release.yml 发布）→ 手动 cherry-pick 到 `fix/sync-1.9.1` 分支并 **PR 回 main**（不直接 push main）；push 远端名由 `scripts/git-remote.sh` 检测（github > origin > 首个 remote）。

**分支铁律**：feature/fix 分支回 main 一律走 PR；main 只合并、只打主版本 tag；面板（IssueRunner）处理 issue 时按 label 切 `feature/issue-N` 或 `fix/issue-N` 并自动开 PR。

## Channel 通道（微信远程驱动 dsh）

面板：活动栏「通道」→ 无全局配置时引导页（微信 ClawBot 卡片）→ 点卡片进**扫码登录向导**（面板内渲染二维码，扫码后 token 落 `~/.dsh/channels/<id>.json`，自动拉起 runner）；有全局配置后进**项目视图**（Channel 标题行：图标 + 平台名 (channelId) + 会话数、NSSwitch 开关经 `setChannelEnabled` 写**全局** `~/.dsh/channels/<channelId>.workspaces.json`（project=workspace，「项目开关」真正门控路由；未启用时该行显示「未在项目启用」）；展开区经 ChannelStoreReader 读**全局 store** 展示会话 + 消息气泡，可点开/收起；顶部「全局配置」可切回）。App 启动自动拉起已启用 channel 的 runner，退出时关闭。

CLI（`core/bin/ohmy-core.js`，与面板共用 core 层）：

```bash
node core/bin/ohmy-core.js channel login --save ~/.dsh/channels/<id>.json   # 扫码登录拿 token
node core/bin/ohmy-core.js channel listen <token> --once                    # 长轮询收一条消息
node core/bin/ohmy-core.js channel reply <token> <to> <text>                # 回复（须带入站消息的 context_token）
node core/bin/ohmy-core.js channel run <channelId> <port> <refsJson> [--dsh-home <dir>] [--project-root <root>]  # 端到端循环（真实微信+真实 dsh；--project-root 供「项目开关」门控）
node core/bin/ohmy-core.js channel route <refsJson> <conversationId> <text> # 路由匹配（纯逻辑）
```

客户端内指令（微信里发）：全局 `/help` `/ping` `/status`；工作区指令 `/workspaces`(`/wks`)、`/sessions`(`/ses`)（无内容列出 / 有内容切换，等同 `#wN`/`#sN`）、`/new [内容]`（统一回 `创建新会话 #sN (sessionId)`，无内容建占位 `New Session`（dsh 标题由 dsh web 按首条消息自动命名）等首条消息激活、有内容 prompt=内容并回推答案）；纯代号 `#wN`/`#sN` 快捷切换当前工作区/会话；消息含 `#w1` 或 `#<workspace名>` 按 #tag 路由到对应项目（清单见 docs/channel-commands.md，改动须同步维护该文档）。

验证：`node --test core/tests/` **171 全绿**（指令体系 v2 后较 166 新增 /workspaces、/sessions 带内容切换与 /new 统一回复用例；含 channel 相关 89+ 项：association/busy/重写后的 sessions/project-switch 等）；`tests/channel-panel/run.sh`（ChannelStoreReader）无头单测；真实微信端到端已跑通（扫码 → 收消息 → 回复确认收到）；重复回复回归见 docs/channel-issues.md（严格串行长轮询修复）。

> ✅ 消息/会话存储**已全局化**（2026-08-22 落地）：会话映射与消息归档到全局 `~/.dsh/channels/`（按 channelId/workspaceKey/sessionId 分桶，无会话入 system 桶），项目内仅剩引用配置 `.dsh/channels.json`；旧项目格式经 `channel migrate` CLI / 惰性迁移（见 [channel-panel](modules/channel-panel.md)）。**「项目开关」关联（PR #30，2026-08-23）**：通道↔项目启用关系存**全局** `~/.dsh/channels/<channelId>.workspaces.json`（project=workspace，出现即启用，见 [channel-panel](modules/channel-panel.md)「项目开关」与 docs/channel-project-switch.md），项目内 refs 文件不再作为启用来源。仍待办：引用配置落位 `.dsh/channels/channels.json` 并提交。

## 配置 GitHub token（任务面板）

- 面板「配置 GitHub Token」→ 确认后**双写** Keychain 专属（`oh-my-dsh.issuerunner.github-token.<owner>/<repo>`）与文件专属（`~/.dsh/tokens/<owner>-<repo>`，chmod 600）；清空则双清；
- 也可手动写 `~/.dsh/gh-token`（通用，App 与外部工具/代理共用同一份）；解析优先级见 [issue-runner-panel](modules/issue-runner-panel.md)；公开仓库无需 token。

CI 侧（`release.yml`）：push `v*` tag（主版本或 patch 均触发）自动在 macos-14 构建 arm64 / x86_64（-target 交叉编译）两份产物（.pkg/.dmg，不再出 universal），汇总后出 SHA-256SUMS 并以 **pre-release** 发布 GitHub Release（人工确认后改正式）；同一 tag 重复触发会取消旧 run（concurrency）；
- **prepare 前置 job**（`ab1f0b0`/38f4605 起）：release 三个 build job 经 `needs: prepare` 依赖前置 job——它预编译双架构 CEF + 预下载 node/prefetch runtime，统一缓存到 `.cache/`；build 矩阵（arm64/x86_64 均跑 macos-14，x86_64 交叉编译）restore-key 回退到 arm64/prepare 的 `.cache/` 复用，避免各 job 冷启动重下/重编 CEF（build-cef.sh 产物缓存 `.cache/cef-built-<arch>`）；x86_64 不再依赖退役中的 macos-13 runner；
- **发布幂等**（`68fc925` 起）：Collect 步骤先 `rm -rf dist` 再拷贝产物（避免混入历史产物）；publish 先 `gh release delete <tag> --cleanup-tag`（失败忽略）再用 `gh release create --target $GITHUB_SHA` 重建 tag + Release + 资产，同 tag 重复发布不再 already_exists（此前尝试过 smoke job / softprops action / --clobber，均已回退或替换）；
- 另可用 **Jenkins**（`Jenkinsfile`）在 macOS agent 上打包 + 发布（gh CLI / curl API 兜底），见 [build-scripts](modules/build-scripts.md)。