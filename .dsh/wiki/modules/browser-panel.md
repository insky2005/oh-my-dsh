---
title: 模块：BrowserPanel.swift / BrowserAPI.swift（浏览器面板）
tags: [module, browser, webkit, rest-api, agent]
updated: 2026-08-18T14:20:00Z
sources: [platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/src/main.swift, docs/plans/BROWSER_PLAN-browser-panel.md]
manual: false
---

# 模块：浏览器面板（BrowserPanel.swift + BrowserAPI.swift + BrowserCDP.swift + CEF）

右栏浏览器面板：多标签 **CEF 嵌入式 Chromium** 浏览器，面向「开发调试 web 页面」与「Agent 排查网页问题」两个目标。Agent 经 localhost REST API（curl 即用）驱动，配套技能 `.dsh/skills/shell-browser/SKILL.md`。

## 背景：Chromium 内核 + 根因修正

用户要求 Chromium 内核（对标 Qoder Quest）。spike 曾误判「renderer 起不来 = ad-hoc 签名问题」并回退 WKWebView；后经 [CefSwift](https://github.com/Rajaniraiyn/CefSwift) 打包文档提示定位**真实根因：CEF 148+ 在 macOS 要求五个 helper app**（base/Alerts/GPU/Plugin/Renderer，同一份二进制、名字承重，见发行包 `CEF_HELPER_APP_SUFFIXES`）——只打 base helper 时 renderer 静默失败，GPU/网络走 base 正常。补上 `(Renderer)` 后 CEF 144/150/151 全部正常渲染，**ad-hoc 签名无影响**（-67030 仅为无害告警）。完整记录见 `docs/plans/BROWSER_PLAN-browser-panel.md` §二。

## BrowserPanel.swift 职责（CEF 内核）

- **多标签**：每 tab 一个 `BrowserCEFTab` = 容器 NSView + CEF 浏览器（shim `CEFShim.createBrowser(in:url:delegate:)`，`CefWindowInfo::SetAsChild` 原生托管，Alloy 风格）+ `BrowserCDPClient`（直连页面 ws）；`+`/`✕`/`⌘1-9` 同终端面板交互；上限 8 tab（每 tab 一个渲染进程）；
- **工具栏**：后退/前进/刷新·停止（走 shim `CEFShim.goBack/goForward/reload/stop`）+ 地址栏（`BrowserURL.normalize`）+ 前往；
- **控制台抽屉**（可折叠）：CDP 事件（`Runtime.consoleAPICalled`/`exceptionThrown`、`Network.requestWillBeSent`/`responseReceived`/`loadingFailed`（requestId 关联状态码）、`Log.entryAdded`）→ per-tab `BrowserLogBuffer`（2000 条）；JS 求值走 CDP `Runtime.evaluate`（`result.result.value` 两层取值，spike 踩过）；
- **DevTools**：头部按钮在系统浏览器打开 `http://127.0.0.1:<cdpPort>/devtools/inspector.html?ws=<pageWs>`（完整 Chromium DevTools）；
- **CDP 发现**：`BrowserCDP.findUnclaimedTarget` 后台拉取 `/json`（**绝不在主线程同步拉**——与 CEF 消息泵死锁），按创建顺序认领未占用 page target 后直连其 ws；
- **生命周期**：`ensureLoaded()` 懒建首 tab（恢复 `browserLastURL`，默认 about:blank）；`shutdownAll()` 关闭浏览器 + 断开 CDP；CEF 消息泵由 main.swift 的 8ms 定时器驱动（`external_message_pump`）；钥匙串：`use-mock-keychain`（不弹密码框）；单例锁：启动清理陈旧锁 + 显式 `root_cache_path=~/.dsh/browser`（防污染与 exit 21）；
- 根视图 `BrowserRootView`（isOpaque=false 自绘背景，同 WikiRootView 模式）。

## BrowserAPI.swift 职责

- **HTTP 服务**：POSIX socket 极简 HTTP/1.1（127.0.0.1，默认 3081，`DSH_BROWSER_PORT` 覆盖，占用递增尝试 +5；生效端口写 `$DSH_HOME/browser-api.port` + 启动日志；App 启动即起）；CORS 头 + OPTIONS 预检放行（页面内 fetch 也可跨域调用）；
- **可单测纯模型**：`HTTPRequest.parse`（请求行/头/Content-Length）、`BrowserAPIRouter`（协议 `BrowserAPIDelegate` 抽象面板，路由 → (status, contentType, body)）、`BrowserLogBuffer`、`BrowserURL.normalize`；
- **路由**：`status`/`open`（自动展开面板，`show:false` 抑制）/`tabs`（new/close/activate）/`back`/`forward`/`reload`/`stop`/`eval`/`console`/`console/clear`/`screenshot`(PNG)/`hide`；**不提供 /cdp**（WKWebView 无 CDP，CEF 方案专属）；
- **桥接**：`BrowserAPIBridge` 实现 `BrowserAPIDelegate`——异步操作（eval/screenshot）经主线程派发 + 信号量同步等待（10s 超时），其余 `DispatchQueue.main.sync` 读快照；
- **踩坑记录**：① 向 C API 传 `[UInt8]` 必须 `withUnsafeMutableBytes`（`&array` 传结构头，同 `docs/terminal-input-fix.md`）；② accept 循环与连接处理不能共用串行队列（acceptLoop 占死队列，handler 永不执行）——队列用 `.concurrent`。

## 与壳层的数据流

- 入口：`RightPanel.browser` + 活动栏 globe / `⌥⌘B`；`setRightPanel(.browser)` 时 `browserPanel.ensureLoaded()`；`startBrowserAPIServer()` 在 `applicationDidFinishLaunching` 调用（bridge 的 showPanel/hidePanel/isPanelVisible 闭包接 AppDelegate）；`applicationWillTerminate` 里 `browserPanel.shutdownAll()` + `browserAPIServer.stop()`；
- Agent 驱动：curl `POST /api/browser/open {url}` → bridge → 面板导航 + `setRightPanel(.browser)` 自动展开 → KVO/注入脚本回填状态与日志 → `eval`/`screenshot` 取证（截图存工作区后可在预览面板查看）；
- 测试：`tests/browser-panel/run.sh`（56 断言：日志缓冲/URL 规范化/HTTP 解析/REST 路由 + FakeDelegate）。

## 已知限制

- 注入捕获仅 main-frame JS 发起的 console/网络调用；深度排查用 Safari Web Inspector；
- 每 tab 一个 WKWebView，上限 8；极端页面内存与多标签 Chrome 同量级；
- 无内置完整 DevTools 面板（WKWebView 无公共 DevTools API）。
