---
title: 模块：BrowserPanel.swift / BrowserAPI.swift（浏览器面板，CEF/Chromium 内核）
tags: [module, browser, cef, chromium, osr, rest-api, agent]
updated: 2026-08-22T15:04:38Z
sources: [platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/src/BrowserCDP.swift, platforms/macos/cef/CEFShim.h, platforms/macos/cef/CEFShim.mm, platforms/macos/build-cef.sh, platforms/macos/src/main.swift, docs/plans/BROWSER_PLAN-browser-panel.md, docs/terminal-header-fix.md, docs/devtools-drag-fix.md]
manual: false
---

# 模块：浏览器面板（BrowserPanel.swift + BrowserAPI.swift + BrowserCDP.swift + CEFShim）

右栏浏览器面板：多标签 **CEF 嵌入式 Chromium** 浏览器，面向「开发调试 web 页面」与「Agent 排查网页问题」两个目标。Agent 经 localhost REST API（curl 即用）驱动，配套技能 `.dsh/skills/web-dev-tools/SKILL.md`（v1.13.0 由 `shell-browser` 更名，经 SkillInstaller 全局安装到 `$DSH_HOME/skills/web-dev-tools/`）。

## 背景：Chromium 内核 + 根因修正 + 版本 pin

- CEF 148+ 在 macOS 要求**五个 helper app**（base/Alerts/GPU/Plugin/Renderer，同一份二进制、名字承重，见发行包 `CEF_HELPER_APP_SUFFIXES`）——只打 base helper 时 renderer 静默失败；补上 `(Renderer)` 后 CEF 144/150/151 全部正常渲染（完整记录见 `docs/plans/BROWSER_PLAN-browser-panel.md` §二）；
- 版本单一来源在 `platforms/macos/build-cef.sh`（`DSH_CEF_VERSION` 覆盖）：当前 pin **`150.0.18+gdb11278+chromium-150.0.7871.213`**（arm64/x86_64 sha1 从 cef-builds.spotifycdn.com/index.json 核对），CEF 产物经 `.cache` 缓存；
- 钥匙串：`use-mock-keychain`（不弹密码框）；GPU：`enable-unsafe-swiftshader` + `ignore-gpu-blocklist` 软件渲染兜底（GPU 路径恢复默认）。

## 渲染模式：OSR 离屏（默认）/ windowed 切换

- **默认 OSR（windowless）**：Chromium 把每帧 BGRA 像素经 `CEFShim.setPaintHandler` 回调给壳层，`BrowserOSRView.presentFrame` 转成 `CGImage` 自绘到 `CALayer.contents`（字节序 BGRA：`premultipliedFirst` + `byteOrder32Little`；`contentsScale` 跟随窗口 backingScaleFactor）；windowed 路径在 layer-backed 壳窗口内呈现失效（`docs/plans/BROWSER_PLAN-browser-panel.md`）；
- **窗口化切换**：`defaults write com.ohmydsh.app browserRenderMode -string windowed`（UserDefaults 键 `browserRenderMode`）→ CEF 自建 NSView 原生绘制（零拷贝），必须在 CEF `initialize` 之前设（`settings.windowless_rendering_enabled = !windowed`）；
- `GetViewRect`/`GetScreenInfo`（device_scale_factor=2.0）取自容器尺寸；容器尺寸变化 → `CEFShim.resizeBrowser`（`WasResized`）同步 OSR 视口。

## BrowserOSRView（OSR 内容视图）

- 必须**入窗前就 layer-backed**（`wantsLayer = true`，入窗后再设可能生成未挂进显示树的 detached layer）；`viewDidMoveToWindow` 设 `contentsScale` + tracking area（`.mouseMoved` 默认不送达，hover 事件要靠它进 CEF）；
- **输入转发**（CEF OSR 坐标左上原点，`cefPoint` 翻转 y）：`sendMouseClick`（0 左/1 右/2 中；count 1 down / 2 up / 3 drag）、`sendMouseMove`、`sendMouseWheel`、`sendKeyEvent`（keyDown 附带 char 事件）、`setFocus`；⌘ 组合键不转发、走 AppKit 响应链（编辑菜单等）；
- **交互前提 `ensureFocus()`**：点击/键入前先 `makeFirstResponder` + `CEFShim.setFocus(true)`——OSR 下浏览器未获焦则事件不交给页面；
- **光标跟随**：`OnCursorChange` → `CEFShim.setCursorHandler` → 活动页签 `cursor.set()`（链接 → 手型）；
- QA 帧探针：`writeFrameProbe` 抽样平均 alpha/亮度，`/tmp/osr-frame-N.png` 落盘，暴露 `frameCount`/`lastFrameSize`/`lastAvgAlpha`/`lastAvgLum`。

## BrowserPanel.swift UI（Chrome 式）

- **布局**：40pt 头部 + 33pt 页签栏 + 分隔线 + 36pt 地址栏 + 内容区钉底；**地址栏位于页签下方**；头部/工具栏/内容容器全部 `wantsLayer + masksToBounds` layer 隔离（`docs/terminal-header-fix.md` 同源合成陷阱），根视图 `BrowserRootView` layer-backed + `isOpaque=false` 自绘背景；
- **页签**：`BrowserTabItemView`（圆角胶囊背景、标题+关闭按钮一体、活动页签加粗、关闭按钮 hover 红色 `hoverColor=systemRed`）；`+` 按钮带常显背景（`CustomIconButton.showsBackground`）紧跟页签；页签最大 200pt、数量多时均分缩小；上限 `maxTabs = 8`（每 tab 一个渲染进程）；
- **新标签**：`about:blank` 时聚焦地址栏并全选（Chrome 式直接输入覆盖）；API 带 URL 新建不抢焦点；`BrowserURL.normalize` 支持 `about:blank`/`file://`/`data:`/`devtools://`/带 scheme+host，否则补 `https://`；`browserLastURL`（UserDefaults）启动恢复；
- **右上角 ✕ = 彻底关闭浏览器**：`closeAllTabs()`（逐页签 `closeTab`）+ 收起面板；页签 ✕ 只关单页签。

## 生命周期与退出（防重入/防误退出）

- `closeTab` 幂等：`isClosing` 标记防 CEF `CloseBrowser` 同步回调 `OnBeforeClose` → `tabClosedByCEF` → 递归 `closeTab` 二次 `remove(at:)` 越界；先摘视图/更新 UI，`CEFShim.closeBrowser` **异步**执行（窗口化模式下 CloseBrowser 可能等 renderer 响应阻塞主线程 → watchdog 杀进程；且 CEF 会关闭宿主主窗口触发误退出）；
- **`g_cefClosingWindow` 守卫**（main.swift）：CEF 关闭浏览器期间置位 2s，`applicationShouldTerminate` 取消退出并恢复主窗口、`windowShouldClose` 拦截（见 [main](main.md)）；
- `shutdown`（CEFShim）：关全部浏览器 + 泵 20 轮消息；**不调用 `CefShutdown()`**——CEF 150 + `external_message_pump` 下它在 macOS 退出流程稳定触发 CHECK 崩溃（SIGTRAP），进程退出由 OS 回收子进程，残留单例锁下次启动 `cleanStaleCEFSingleton` 清理；
- CEF 消息泵：main.swift 8ms 定时器驱动（`external_message_pump`）；`root_cache_path` 显式设 cache 父目录（单例锁定位，防与其他 CEF 应用互相干扰）。

## 上下文菜单（OSR）

OSR 下 CEF 不知道宿主窗口位置，默认菜单弹错位：`OnBeforeContextMenu` 把菜单模型转成条目数组（id/type/label）回调 Swift，宿主在**正确屏幕坐标**弹 NSMenu；`CEFShim.executeContextMenuCommand` 执行 `MENU_ID_BACK/FORWARD/RELOAD/STOPLOAD/UNDO/REDO/CUT/COPY/PASTE/SELECT_ALL/VIEW_SOURCE`（链接/拼写等命令暂不处理）。

## DevTools

「DevTools」按钮 → `CEFShim.showDevTools`：CEF 原生 ShowDevTools（Chromium 自带完整调试器），CEF 150 mac 无 `SetAsPopup` → 自建独立 NSWindow（960×640，`g_devtoolsWindow` 强引用防释放）`SetAsChild` 挂载。此前用 `inspector.html?ws=…` 在系统浏览器打开，CDP WebSocket 连接不稳且挤占面板页签，已废弃。

**DevTools 拖动修复**（`docs/devtools-drag-fix.md`）：拖动 DevTools 标题条调两个窗口高度时，`onDrag` 每 80ms 触发 `notifyResize()`→`WasResized()` 会让 Chromium 重新布局页面、渲染像素内容发生不可控上移（frame 正确但视觉在动）。修复思路：**拖动期间不动 CEF 视图**——首次拖动设 `pageView.autoresizesSubviews = false`、只改 devtoolsArea 高度约束 + `layoutSubtreeIfNeeded()`，不调 `notifyResize()`/`WasResized()`，devtoolsArea z-order 更高盖住 CEF 溢出；拖动结束恢复 autoresize、一次性更新 CEF 视图 frame 并只调一次 `WasResized()`。另：覆盖式切换后把主 CEF 视图钉回顶部全高（Chromium 会把 CEF 底部对齐致顶部空白）+ 视口一次 resize；覆盖式约束用 `activate` 数组激活（init 里 `isActive=true` 曾致启动卡 buildWindow/Starting）。

## 控制台/网络日志（供 REST API 读取）

**控制台抽屉与 JS 求值 UI 已移除**（console 切换按钮/日志视图/求值输入框全删）；CDP 事件（`Runtime.consoleAPICalled`/`exceptionThrown`、`Network.requestWillBeSent`/`responseReceived`/`loadingFailed`、`Log.entryAdded`）仍由 `BrowserCDPClient` 写入 per-tab `BrowserLogBuffer`（2000 条），只经 REST API `console` 端点读取；`eval`/`screenshot` API 仍走 CDP。target 发现：后台拉 `/json`（**绝不在主线程同步拉**——与 CEF 消息泵死锁），按创建顺序认领未占用 page target；CDP 端口 `DSH_CDP_PORT` 覆盖、默认 9333（与 CEFShim `remote_debugging_port` 一致）。

## BrowserAPI.swift（Agent 驱动 REST API）

- POSIX socket 极简 HTTP/1.1（127.0.0.1，默认 3081，`DSH_BROWSER_PORT` 覆盖，占用递增 +5；生效端口写 `$DSH_HOME/browser-api.port`；App 启动即起）；CORS 头 + OPTIONS 预检；
- 路由：`status`/`open`（自动展开，`show:false` 抑制）/`tabs`/`back`/`forward`/`reload`/`stop`/`eval`/`console`/`console/clear`/`screenshot`(PNG)/`hide`，**新增 QA 端点**：
  - `POST /api/browser/debug`：触发视图层级 dump（AppLog + `panel-browser-debug.png`）+ 返回 OSR 渲染状态（`debugState`：containerInWindow/osrLayerContents/frameCount/lastFrameSize/avgAlpha/avgLum…）；可选 body `{"click":[x,y]}` 模拟点击（`simulateClick`，验证 OSR 点击链路）；
  - `POST /api/browser/hierarchy`：全窗口视图层级 JSON + 命中测试（面板/内容区中心 `hitTest`）+ 窗口/面板截图（写 `/tmp/window-shot.png`、`/tmp/panel-browser-shot.png`）——定位「内容区被盖住/事件被截」的遮挡视图；
- 可单测纯模型：`HTTPRequest.parse`、`BrowserAPIRouter`（协议 `BrowserAPIDelegate` 抽象面板）、`BrowserLogBuffer`、`BrowserURL.normalize`；
- 桥接 `BrowserAPIBridge`：异步操作（eval/screenshot）主线程派发 + 信号量同步等待（10s 超时），其余 `DispatchQueue.main.sync` 读快照；`debugDump`/`debugState`/`debugHierarchy` 闭包由 AppDelegate 接线（main.swift）。

## QA 调试

- `DSH_UI_DEBUG=1` 或 `--ui-debug`（`uiDebug`，main.swift 统一开关）：打开浏览器面板 + 面板渲染后视图层级 dump（浏览器 `dumpHierarchy` maxDepth=8）+ `panel-browser-debug.png`；`DSH_BROWSER_TEST=1` 同入口；
- `tabStateChanged` 在 uiDebug 下打印活动页签容器 subviews 与标题联动；面板 `debugState()`/`simulateClick(x:y:)` 供 API 与人工排查；
- 遮挡诊断：`dumpBrowserHierarchyJSON`（main.swift）——`NSApp.windows` 全清单（排查 CEF 辅助窗口/DevTools 混入误退出）、split panes、面板层级 JSON（含 layer superlayer 链诊断）、命中测试、截图。

## 测试

`tests/browser-panel/run.sh`（日志缓冲/URL 规范化/HTTP 解析/REST 路由 + FakeDelegate；无窗口/CEF 实例化）。注意：OSR 输入转发落地后，`tests/terminal-emulator/stubs.swift` 需补 `sendMouseClick` 等桩，`run.sh` 才能编译通过（当前 WIP 分支测试为红）。

## 已知限制

- OSR 输入转发未覆盖全部事件（如 ⌘ 组合走响应链、触控板手势、拖放）；上下文菜单仅实现常用命令；
- 注入/捕获依赖 CDP 事件，仅覆盖页面发出的 console/网络调用；深度排查用 Chromium 原生 DevTools 窗口；
- 每 tab 一个 Chromium 渲染进程，上限 8；极端页面内存与多标签 Chrome 同量级。
