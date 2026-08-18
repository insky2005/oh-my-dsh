---
title: 模块：BrowserPanel.swift / BrowserAPI.swift（浏览器面板）
tags: [module, browser, webkit, rest-api, agent]
updated: 2026-08-18T14:20:00Z
sources: [platforms/macos/src/BrowserPanel.swift, platforms/macos/src/BrowserAPI.swift, platforms/macos/src/main.swift, docs/plans/BROWSER_PLAN-browser-panel.md]
manual: false
---

# 模块：浏览器面板（BrowserPanel.swift + BrowserAPI.swift）

右栏浏览器面板：多标签 WKWebView 浏览器，面向「开发调试 web 页面」与「Agent 排查网页问题」两个目标。Agent 经 localhost REST API（curl 即用）驱动，配套技能 `.dsh/skills/shell-browser/SKILL.md`。

## 背景：为什么是 WKWebView 而不是 Chromium

CEF（嵌入式 Chromium）方案 spike 集成全部打通（框架加载/CefInitialize/CDP/多浏览器同窗口），但 **renderer 子进程在本机无法启动**——官方未改动的 cefsimple 参考应用同样复现，CEF 144/150/151 全部复现，沙箱内外均复现；用户 Developer ID 签名的 Chrome 148 正常。根因指向 **macOS 26.5 + ad-hoc 签名**：实测 ad-hoc 进程 `csops(CS_OPS_VALIDATION_CATEGORY)` 返回 `NONE`，新 Chromium 的 `base/mac/process_requirement` 校验对 NONE 分类有硬性路径。故按计划回退 WKWebView；CEF 集成路径（已验证）记录于 `docs/plans/BROWSER_PLAN-browser-panel.md` §二，复活条件 = 真签名（Developer ID/Apple Development）或上游修复。WKWebView 方案**不访问钥匙串、无子进程/签名校验问题**。

## BrowserPanel.swift 职责

- **多标签**：每 tab 一个 WKWebView（独立 `WKWebsiteDataStore`（macOS 14+ 用 forIdentifier 固定 UUID 隔离，13 回退 nonPersistent），cookie 与 dsh web 隔离）；`+`/`✕`/`⌘1-9` 同终端面板交互；上限 8 tab（每 tab 一 webview，内存随页数增长）；
- **工具栏**：后退/前进/刷新·停止 + 地址栏（`BrowserURL.normalize`：无 scheme 补 `https://`，about:blank/file:/data: 原样，非法返回 nil）+ 前往；
- **控制台抽屉**（可折叠）：注入脚本（`browserInjectionScript`，forMainFrameOnly:false）包装 console 方法、window.onerror、unhandledrejection，并包装 fetch/XMLHttpRequest（level "network" 行，含状态码/耗时）→ `messageHandlers.browserConsole`；日志环形缓冲 `BrowserLogBuffer`（per-tab，2000 条）；JS 求值 `evalScript`（表达式 JSON 序列化后交给 `eval()`，支持语句；结果 JSON.stringify 回传）；**限制：仅捕获 main-frame JS 发起的调用**（图片/CSS/子框架看不到，完整网络面板用 Safari Web Inspector）；
- **调试**：`webView.isInspectable = true`（macOS 13.3+，#available 守卫）——Safari → 开发 → oh-my-dsh → 浏览器面板；
- **生命周期**：KVO 同步 url/title/isLoading/canGoBack/canGoForward；WKNavigationDelegate 把加载失败写进 console 缓冲；`ensureLoaded()` 懒建首 tab（恢复 `browserLastURL`，默认 about:blank）；`shutdownAll()` 退出清理（移除 message handler）；
- 根视图 `BrowserRootView`（isOpaque=false 自绘背景，防 layer 合成陷阱，同 WikiRootView 模式）。

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
