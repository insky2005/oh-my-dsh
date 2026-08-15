---
title: 常见任务手册
tags: [tasks, build, package, test, debug, release]
updated: 2026-08-15T15:31:24Z
sources: [README.md, build-app.sh, make-pkg.sh, tests/terminal-emulator/run.sh, tests/wiki-panel/run.sh, docs/terminal-header-fix.md, docs/terminal-input-fix.md]
manual: false
---

# 常见任务手册

## 构建 App

```bash
./build-app.sh --prefetch   # 首次或换版本时先预下载 Node + 预装 dsh 到 .cache/（可离线复用）
./build-app.sh              # 全量构建 → dist/oh-my-dsh.app（复用 .cache 则无需网络）
```

- 产物：`dist/oh-my-dsh.app`（arm64、ad-hoc 签名、含内置运行时）；
- 常见失败：网络不可达 → 有缓存 tarball 会自动推导版本继续；`swiftc` 报错 → 检查新增文件是否登记进编译清单（第 3 步）；
- 重新构建会清掉旧包（`rm -rf "$BUILD_DIR" "$APP"`），`make-pkg.sh` 依赖已构建的 `.app`。

## 打包安装包（.pkg / .dmg）

```bash
./make-pkg.sh   # 需先 ./build-app.sh
# 产物：dist/oh-my-dsh-<version>-arm64.pkg 与 .dmg（版本从 Info.plist 读取）
# 安装：open "dist/oh-my-dsh-<version>-arm64.pkg"（装到 /Applications，preinstall 自动删旧版）
```

## 运行与验证

```bash
open "dist/oh-my-dsh.app"
```

- 验证点：窗口标题 `oh-my-dsh (DeepSeek Harness)`；活动栏三图标互斥切换（预览/终端/知识库）；⌥⌘P / ⌥⌘T / ⌥⌘W 快捷键；About 面板显示 dsh/Node 版本与 registry。

## 跑单元测试

```bash
tests/terminal-emulator/run.sh   # 终端模拟器（无 PTY）
tests/wiki-panel/run.sh          # Repo Wiki 模型层
```

- 均无窗口依赖，可在纯命令行环境运行；失败即非零退出（`set -euo pipefail`）。

## 加一个新右栏面板（参照 v1.7.0 Wiki 面板）

1. 新建 `src/<Panel>.swift`，实现 `PanelController`（复用 `HoverButton`/`DynamicFillView`/`CustomIconButton`）；
2. `src/main.swift`：`RightPanel` 枚举加 case；`buildSplitView` 里创建 controller（`onRequestHide` + `serverPortProvider`）；活动栏加 `ActivityBarButton`；`activePanelView`/`setRightPanel` 分发；「视图」菜单加切换项（如 `⌥⌘X`）；`rightPanelKind` 持久化映射；
3. `build-app.sh`：编译清单加入新文件；`VERSION`/`BUILD` 递增；
4. `L10n.table` 加中英文案键；README 特性说明；
5. 配套无头单测（仿 `tests/wiki-panel/`：`stubs.swift` + `run.sh`）。

## 改文案 / 语言

- 在 `main.swift` `L10n.table` 增改 `(zh, en)` 条目；菜单标题等直接调 `L10n.tr(...)`；
- 语言规则：`DSH_LANG` > `appLanguage` > 系统语言；切换会重建菜单并重载 web 页面。

## 升级内置 dsh（运行期）

- 手动：设置菜单 →「检查并升级 dsh…」(⌘U)；自动：设置菜单 →「自动升级 dsh」（默认开，24h 节流）；
- 只作用于内置运行时（路径含 `/Contents/Resources/runtime/`），不碰系统 dsh；
- 注意：升级会改写 App 包内文件导致 ad-hoc 签名失效（本地运行不受影响）；重新 `./build-app.sh` 还原干净包。

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

## 发布清单（简版）

1. `build-app.sh` 版本号确认（VERSION/BUILD）；
2. `./build-app.sh` 全量构建 → `open dist/oh-my-dsh.app` 手工 QA（README 特性逐项过）；
3. `tests/*/run.sh` 全绿；
4. `./make-pkg.sh` 出 .pkg/.dmg；
5. 提交时检查 `git status`：只含源码/文档/wiki 变更（.build/.cache/dist/pic 已忽略）。
