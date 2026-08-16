---
title: 工程约定
tags: [conventions, l10n, build, qa-hooks, versioning]
updated: 2026-08-16T14:10:06Z
sources: [README.md, platforms/macos/build-app.sh, platforms/macos/src/main.swift, docs/terminal-header-fix.md, docs/terminal-input-fix.md, .gitignore, .github/workflows/ci.yml, core/tests/, .dsh/skills/repo-wiki/SKILL.md]
manual: false
---

# 工程约定

## 核心原则

1. **绝不改动 DeepSeek Harness 源码**：壳层只封装 `dsh web`，不补丁、不注入 dsh 源码；一切扩展走壳层面板 + dsh 既有能力（skill / session RPC / AGENTS.md 指令加载）；
2. **自包含优先**：运行时不依赖本机 node/dsh（构建期嵌入 `Contents/Resources/runtime/`）；构建不复制本机任何 node/dsh 文件；
3. **退出只清理自己拉起的服务**：复用的外部 `dsh web` 实例绝不被壳层杀掉；
4. **版本化知识库**：`.dsh/wiki/` 随仓库提交/共享，可增量更新，`manual: true` 页面永不覆盖。

## 语言与文案（L10n）

- 所有面向用户的文案集中在 `main.swift` 的 `L10n.table`，**中英双语成对**（`(zh, en)`）；新增文案必须同时提供两种语言；
- 语言优先级：`DSH_LANG` 环境变量 > `UserDefaults.appLanguage` > 启动时快照的系统语言（`captureSystemLang` 在改写 AppleLanguages 前调用，保证"跟随系统"即时且准确）；
- 切换语言时重建菜单 + 重建 WebView（注入新 `navigator.language`）并重载页面，dsh web 界面语言随之联动（会话在服务端不受影响）。

## 构建与代码组织

- 编译：`swiftc -O -swift-version 5`，frameworks 为 AppKit/WebKit/PDFKit；**编译源文件清单显式写在 `platforms/macos/build-app.sh`**，新增 `.swift` 文件必须登记；
- `module-cache-path` 固定在 `.build/module-cache`（沙箱/环境问题规避）；
- 图标：`MakeIcon.swift` 程序化渲染（16…1024px 全尺寸）→ `iconutil -c icns`，不提交二进制图；
- 版本号单一来源：`scripts/version.sh`（HEAD 命中 git tag vX.Y.Z → VERSION 取 tag，否则回退 1.8.0；BUILD 取 CI 运行号，本地回退 64）；`platforms/macos/build-app.sh` 运行期读取，**勿在脚本硬编码版本**；产物命名 `oh-my-dsh-<version>-<arch>.{pkg,dmg}`（`platforms/macos/make-pkg.sh` 从 Info.plist 读取版本，避免两处失配）；
- `git status` 应只出现源码/文档变更：`.build/` `.cache/` `dist/` `pic/` `.DS_Store` 均在 `.gitignore`；`.dsh/tasks/local.json`（本机会话覆盖）也忽略——**`index.json` 随仓库提交**（任务关联共享，见 [data-model](data-model.md)）。

## 面板 UI 约定

- 右栏四个面板共享 `PreviewPanel.swift` 的 UI 基件（`HoverButton`/`DynamicFillView`/`CustomIconButton`/`HeaderLabel` 等），视觉与交互保持一致：40pt 头部 + 内容区、统一背景条、图标深浅色均可见；
- **layer-backed 窗口合成陷阱**（`docs/terminal-header-fix.md`，wiki 面板同源，见 `docs/repo-wiki-design.md` §14 修复 12）：`isOpaque = true` 且无独立 layer 的视图，绘制会溢出到父 layer 覆盖同级视图；隔离绘制用**父容器的** `wantsLayer = true` + `masksToBounds = true`（不是子视图的 wantsLayer）；根视图用 `isOpaque = false` 的自绘背景视图（`TerminalRootView`/`WikiRootView` 模式）；**经验推广**：任何「平时隐藏、生成/状态变化时才显示」的 opaque 无 layer 视图（如 wiki 面板底部状态条）都可能触发同类合成溢出——显示前先给视图自身 `wantsLayer = true` + `masksToBounds = true`；
- markdown 预览：预览面板把 markdown 当**纯文本**显示（软换行保真是有意取舍）；wiki 面板则需真正渲染（`WikiMarkdownRenderer`，同样保留软换行）。

## 终端实现约定

- 向 C API 传 Swift 数组缓冲区必须用 `withUnsafeBytes`/`withUnsafeBufferPointer`，禁用 `&array[index]` 当指针（`docs/terminal-input-fix.md`：曾因 `Darwin.write(fd, &bytes[off], count)` 写出数组对象头导致多字节输入乱码，单字节正常）；
- 终端必须跟踪 shell 的模式切换：DECCKM 应用光标键（`CSI ? 1 h/l`）决定方向键编码，括号粘贴（`CSI ? 2004 h/l`）决定粘贴包封 `\x1b[200~…\x1b[201~`；
- PTY 子进程强制 UTF-8 locale（`LANG/LC_ALL/LC_CTYPE=en_US.UTF-8`），否则 zsh 渲染 `<ffffffff>` 占位。

## QA 钩子与环境变量（调试约定）

- `DSH_PREVIEW_TEST_PATH=<path>`：启动即用指定路径打开预览面板；
- `DSH_TERMINAL_TEST=1`：启动即开终端面板；`DSH_WIKI_TEST=1`（可加 `DSH_WIKI_TEST_PATH=<dir>` 指定 fixture wiki 根）；
- `DSH_UI_DEBUG=1`：面板视图层级 dump + 截图（写 `~/Library/Logs/oh-my-dsh/panel-*-debug.png`）；
- `DSH_PREVIEW_DEBUG=1`：预览拦截器探针（`__dshPreviewInstalled`/hit、伪造 `host.openPath` 请求验证）；`DSH_TERMINAL_DEBUG=1`：终端 I/O 字节级日志；
- `DSH_SESSION_DEBUG=1`：会话跟踪器诊断——日志 dump `window.__dshSessionSeen`（观察到的 session.*/subagent.list 请求序列）与跟踪器状态（`__dshSessionTracked`/`__dshLastTrackedSession`）；
- `DSH_NATIVE_FORCE_SPAWN=1`：跳过复用检查强制自拉起（测试/专用实例）；
- 其他运行期变量（`DSH_CLI`/`DSH_NODE`/`DSH_HOME`/`DSH_NATIVE_PORT`/`DSH_REGISTRY`/`DSH_AUTO_UPGRADE=0`/`DSH_LANG`）见 README「环境变量」表。

## 测试约定

- 共享核心单测走 Node：`node --test core/tests/*.test.js`（ANSI 模拟器 / 端口 / 升级 / 会话 RPC / issues / jobqueue / tasks，77 用例）；**glob 不带引号**——由 bash 展开成文件列表，兼容 Node 20（引号 glob 需 Node 21+，CI 踩过此坑，见 `c2d626b`）；
- CI（push/PR，`ci.yml`）：core 单测走 ubuntu；壳层在 macos-14 跑模拟器单测（`core/tests/ansi.test.js`）+ `tests/wiki-panel/run.sh` + 全源码 `swiftc` 编译检查（先 `mkdir -p .build/module-cache`）；构建矩阵为 arm64 + universal（lipo 覆盖 x86_64 编译验证），**不再使用退役中的 macos-13/x86_64 runner**；
- 面板/壳层 Swift 无头单测模式（`tests/*/run.sh`）：`stubs.swift` + 把被测源码复制进临时目录 + 测试文件改名 `main.swift`（顶层代码需要）→ `swiftc` 编译运行，无窗口/无 PTY 依赖；
- 终端模拟器测试不触 PTY（沙箱可能禁 `/dev/ptmx`），已迁 `core/tests/ansi.test.js`（42 项），`tests/terminal-emulator/run.sh` 为薄封装；
- 新增面板需配套模型层单测（如 `tests/wiki-panel/`）。

## 日志约定

- 统一经 `AppLog.shared.log`（串行队列 + ISO8601 毫秒时间戳）；关键路径都要留日志（启动/复用/升级/页面加载/退出清理），便于远端排查。

## Wiki 维护约定（代理执行）

- 只写可从代码/文档证实的事实，不确定标注「待确认」，禁止编造；
- 脱敏：跳过 `.env*`/密钥/口令/个人数据，示例一律占位符；
- 增量更新用 `git status` + mtime 定位变更面，只重写 `sources` 命中变更的页面，未变页面**字节不变**（便于 git diff 审查）；
- 生成/更新完成后由**代理**（repo-wiki skill 规则 8）执行 `git add .dsh/wiki` + commit（**不 push**），commit message 由代理概括实际变更；若代理未提交，面板 `WikiAutoCommit` **兜底**提交（同样不 push），提交失败仅记日志不打扰用户；
- 完成后刷新 `index.md` 统计与最后生成时间。
