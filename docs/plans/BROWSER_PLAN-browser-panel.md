# 实现 oh-my-dsh 右侧活动栏「浏览器」面板（Browser Panel）

> 状态：⚠️ **CEF 方案 spike 受阻，按计划回退 WKWebView 方案**（见 §二）· 实现中 · 2026-08

## 一、目标与验收标准

在 oh-my-dsh 壳层右侧面板槽位新增**浏览器面板**，两个目标：

1. **方便开发调试 web 页面**：多标签页浏览器（同终端面板交互），地址栏/前进后退/刷新停止、可开关的**控制台抽屉**（console 日志 + 网络请求日志 + JS 求值）、页面可被 **Safari Web Inspector** 完整调试（`isInspectable`）；
2. **方便 Agent 排查网页问题**：壳层提供 **localhost REST API**（curl 即用），Agent（或用户终端）可：开页面、查状态、读 console/network 日志、执行 JS、截图 PNG 到工作区；配套 `.dsh/skills/shell-browser` 技能开箱即用；Agent 驱动时面板自动展开。

**验收清单（手动 QA，见 §九）**：多标签增删/切换、地址栏导航、控制台与网络日志、JS 求值、Safari 检查器可附加、Agent curl 全流程、面板持久化与互斥、L10n 中英齐全、CI/单测全绿。

## 二、CEF（嵌入式 Chromium）spike 结论 —— 为什么回退（2026-08 实测）

按用户指示（对标 Qoder Quest 的 Chromium 集成）先做了 CEF 嵌入式方案 spike，**集成层面全部打通，但渲染进程在本机无法启动，判定为环境阻塞，按计划回退 WKWebView**。

**已验证可用的部分（保留在本文档，未来可复活）**
- 下载管线：`https://cef-builds.spotifycdn.com/cef_binary_<version>_macosarm64.tar.bz2`（`index.json` 含 sha1/size；150 为 272MB，151 为 284MB；`minimal` 类型不含测试）；CEF 151 框架二进制 `LC_BUILD_VERSION minos = 13.0`，与 App 部署目标兼容；
- 纯 swiftc 集成路径全部走通：`libcef_dll` wrapper 编译（`-DWRAPPING_CEF_SHARED`，.cc+.mm 都要）、ObjC++ shim（`swiftc -import-objc-header`）、helper 子进程（`process_helper_mac.cc` + `helper-Info.plist`）、框架经 `CefScopedLibraryLoader` 运行期 dlopen（**无需链接框架**，主程序/helper 用 `-Wl,-undefined,dynamic_lookup`）、`external_message_pump + CefDoMessageLoopWork` 融入 AppKit 主循环、`CefWindowInfo::SetAsChild` 原生 NSView 托管（自动 Alloy 风格）、多浏览器同窗口（每 tab 一个 parent NSView）、CDP 端口可用（`/json` 返回 target、`Browser.getVersion`/`Target.attachToTarget` 可用）、helper 命名必须与主可执行名一致（`<exe> Helper.app`，CEF 按 `libcef/common/util_mac.mm` 约定查找）；
- 构建产物体积：app +~300MB/架构。

**阻塞点（环境级，非集成 bug）**
- **renderer 子进程从不启动**（浏览器侧静默失败，helper 无 renderer exec），gpu/network/storage 子进程正常；
- 该问题在**未修改的参考 cefsimple 上同样复现**（排除集成问题）；在 **CEF 144 / 150 / 151 三个版本全部复现**（排除版本回归）；在沙箱内外（直接运行 vs `open` 经 launchd）均复现；
- 用户已安装、**Developer ID 签名的 Chrome 148 在本机正常渲染**（pgrep 可见其 renderer 进程）——强烈指向**签名校验**：本机 macOS 26.5 上 ad-hoc 签名的进程 `csops(CS_OPS_VALIDATION_CATEGORY)` 返回 `NONE`（实测），而 Chromium 150+ 新增的 `base/mac/process_requirement` 机制对 `NONE` 分类有 `CHECK_NE(category, None)`（`RequirementStringForValidationCategory`）等硬性路径；Chromium 侧另有 `errSecCSInfoPlistFailed (-67030)` 报错；
- 本开发沙箱无可用签名身份（`security find-identity` = 0，`security create-keychain` 被拒），无法验证「真实签名可修复」假设，也无法在本机绕过。

**回退决策（预决定，§十 原计划）**：改用 **WKWebView 多标签面板**。WKWebView 使用系统 WebKit：不访问钥匙串（不再触发密码弹窗）、无子进程/签名校验问题、`isInspectable = true` 提供 Safari 完整 DevTools。REST API 路由面保持不变，仅 `/cdp` 路由不提供（WKWebView 无 CDP）。

**CEF 复活条件（记录，未来 M1 分发引入 Developer ID 签名或 CEF/Chromium 修复后可重试）**：app 以真实开发者证书签名后重跑 spike（预期 renderer 可启动）；届时复用本文档 §二 的已验证集成路径。

## 三、总体架构（WKWebView 方案）

```
┌─ oh-my-dsh 主窗口 ─────────────────────────────────────────────┐
│ 活动栏(48pt) │ WKWebView(dsh web) │ 右栏槽位: 浏览器面板        │
│  (globe 图标)                      │  头部40pt（标题+系统浏览器/  │
│                                    │    复制URL/控制台/关闭）     │
│                                    │  工具栏36pt（后退/前进/刷新/ │
│                                    │    停止+地址栏+前往）        │
│                                    │  标签栏33pt（多标签, 同终端） │
│                                    │  内容区: tab容器NSView       │
│                                    │    └ WKWebView (每tab一个)  │
│                                    │  控制台抽屉（可折叠）        │
└────────────────────────────────────┴────────────────────────────┘
   ┌── 壳层进程内 ──┐         ┌── 系统 WebKit ──┐
   │ BrowserPanelUI │─WKWebView─▶ (无独立进程)   │
   │ BrowserAPI     │◀─HTTP─▶ 127.0.0.1:3081    │ (Agent/用户 curl)
   └────────────────┘                          └─────────────────┘
```

- 每 tab 一个 WKWebView（独立 `WKWebsiteDataStore(forIdentifier: "oh-my-dsh.browser")`，与 dsh web 的 cookie 隔离）；切标签=显隐容器（同终端会话模式）；
- console/网络捕获走 **WKUserScript 注入**（console 方法包装 + window.onerror + unhandledrejection + fetch/XMLHttpRequest 包装 → `messageHandlers.browserConsole`）；**限制：仅捕获 main-frame 的 JS 调用**（图片/CSS 加载、子框架请求捕获不到——文档明示；完整网络面板请用 Safari Web Inspector）；
- JS 求值：`evaluateJavaScript("JSON.stringify(eval(<expr>))")`；
- 截图：`takeSnapshot`（需面板可见，先自动展开再截）；
- 调试：`webView.isInspectable = true`（macOS 13.3+，`#available` 守卫），Safari → 开发 → oh-my-dsh → 浏览器面板 → 完整 DevTools。

## 四、实现方案（按子系统）

### 子系统 1：`platforms/macos/src/BrowserPanel.swift`（新增，核心）

**`BrowserConsoleEntry` / `BrowserLogBuffer`**（纯模型，可单测）：环形缓冲（上限 2000 条），`{ts, level, text}`，`append/clear/entries(level:limit:)`。

**`BrowserTab`**：`id/title/url/webView/container/loading/canGoBack/canGoForward`；WKNavigationDelegate 回调更新状态并写日志（didFinish → info、didFail/didFailProvisional → error 进 console 缓冲）；`createWebView` 用独立配置（`WKUserContentController` + 注入脚本 + `browserConsole` handler + 独立 dataStore）。

**注入脚本（console/网络捕获）**：
```js
(function(){
  if (window.__ohMyDshBrowserInstalled) return; window.__ohMyDshBrowserInstalled = true;
  var send = function(level, args){
    try {
      var text = Array.prototype.map.call(args, function(a){
        try { return typeof a === 'string' ? a : JSON.stringify(a); } catch(e){ return String(a); }
      }).join(' ');
      window.webkit.messageHandlers.browserConsole.postMessage({level: level, text: text, main: true});
    } catch(e){}
  };
  ['log','info','warn','error','debug'].forEach(function(m){
    var orig = console[m];
    console[m] = function(){ send(m, arguments); orig.apply(console, arguments); };
  });
  window.addEventListener('error', function(e){ send('error', [e.message + ' @ ' + (e.filename||'') + ':' + (e.lineno||'')]); });
  window.addEventListener('unhandledrejection', function(e){ send('error', ['Unhandled rejection: ' + String(e.reason)]); });
  // fetch / XHR 网络捕获（level: "network"）
  var origFetch = window.fetch;
  window.fetch = function(input, init){
    var url = typeof input === 'string' ? input : (input && input.url) || String(input);
    var start = Date.now();
    return origFetch.apply(this, arguments).then(function(r){
      try { send('network', [r.status + ' ' + (r.status >= 400 ? 'FAIL' : 'OK') + ' ' + url + ' (' + (Date.now()-start) + 'ms)']); } catch(e){}
      return r;
    }, function(err){
      try { send('network', ['ERR ' + url + ' ' + String(err)]); } catch(e){}
      throw err;
    });
  };
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url){
    this.__ohMyDshXhr = {method: method, url: String(url), start: 0};
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(){
    var self = this;
    if (this.__ohMyDshXhr) { this.__ohMyDshXhr.start = Date.now();
      this.addEventListener('loadend', function(){
        try { send('network', [self.status + ' ' + String(self.__ohMyDshXhr.method) + ' ' + self.__ohMyDshXhr.url + ' (' + (Date.now()-self.__ohMyDshXhr.start) + 'ms)']); } catch(e){}
      });
    }
    return origSend.apply(this, arguments);
  };
})();
```
（`forMainFrameOnly: false` 注入所有 frame，消息带 `main` 标志；生产实现把注入脚本作为 Swift 字符串常量。）

**UI 结构**：根视图 `BrowserRootView`（isOpaque=false 自绘背景，防 layer 合成陷阱）+ 头部 40pt（标题「浏览器」+ 系统浏览器打开/复制 URL/控制台开关/关闭）+ 工具栏 36pt（后退/前进/刷新·停止、地址栏 NSTextField、前往）+ 标签栏 33pt（`+` 新建、✕ 关闭、⌘1-9 切换）+ 内容区（tab 容器栈显隐切换）+ **控制台抽屉**（底部可折叠：日志列表 NSTableView/NSTextView 按 level 着色 + 网络行 + JS 求值输入 + 清空按钮）。复用 `HoverButton`/`DynamicFillView`/`CustomIconButton(.symbol:)`/`HeaderLabel`。

**其他**：`minWidth = 300`；tab 上限 8；`ensureLoaded()` 懒创建首 tab（恢复 `UserDefaults "browserLastURL"`，默认 `about:blank`）；`shutdown()` 退出时清理；QA 钩子 `DSH_BROWSER_TEST=1` 启动即开面板。

### 子系统 2：`platforms/macos/src/BrowserAPI.swift`（新增）

POSIX socket 极简 HTTP/1.1 服务（127.0.0.1，默认 **3081**，`DSH_BROWSER_PORT` 覆盖，占用则 3082-3086 递增；生效端口写 `$DSH_HOME/browser-api.port` + 启动日志；App 启动即起）。CORS 头 + OPTIONS 放行。

**可单测的纯模型**：`HTTPRequest.parse(data:)`（请求行/头/Content-Length）、`BrowserURL.normalize(_:)`（补 `https://`、about:blank、非法输入）、`BrowserLogBuffer`、`BrowserAPIRouter`（协议 `BrowserAPIDelegate` 抽象面板，路由 → (status, headers, body)）。

路由：

| 方法/路径 | 参数 | 说明 |
|---|---|---|
| GET `/api/browser/status` | — | `{panelVisible, tabs:[{id,url,title,loading,canGoBack,canGoForward}], activeTabId}` |
| POST `/api/browser/open` | `{url, tab:"active"\|"new"\|tabId}` | 导航/开新 tab；自动展开面板（`show:false` 抑制） |
| POST `/api/browser/tabs` | `{action:"new"\|"close"\|"activate", tabId?}` | 标签管理 |
| POST `/api/browser/back` `/forward` `/reload` `/stop` | `{tabId?}` | 导航控制 |
| POST `/api/browser/eval` | `{expression, tabId?}` | JS 求值，`{ok, result}` / `{ok:false, error}` |
| GET `/api/browser/console` | `level?, limit?` | console 日志（含 network 行） |
| POST `/api/browser/console/clear` | — | 清空 |
| GET `/api/browser/screenshot` | — | PNG 字节（`Content-Type: image/png`；先自动展开面板再 takeSnapshot） |
| POST `/api/browser/hide` | — | 收起面板 |

无鉴权（127.0.0.1 仅本用户可连，与 dsh web 3080 同信任模型，文档明示 eval 可读页面）。**不提供 `/cdp`**（WKWebView 无 CDP，CEF 方案专属）。

### 子系统 3：main.swift 接线（对照 tasks.md 加面板五步）

- `RightPanel` 加 `.browser`；属性 `browserPanel`/`browserBarButton`/`browserToggleMenuItem`；`rightPanelMinWidth` max 并入（300 不变）；`activePanelView`/`setRightPanel` 分发（含 `ensureLoaded` + `DSH_UI_DEBUG` dump）；`rightPanelKind` 持久化映射 `"browser"`；
- 活动栏 `ActivityBarButton`（SF Symbol `globe`，`bar.browser` tooltip）；「视图」菜单「显示/隐藏 浏览器面板」**⌥⌘B**（`browserEntryTapped`）；设置窗口 Shortcuts 列表加行；
- `buildSplitView` 创建 controller（`onRequestHide`）；`applicationDidFinishLaunching` 启动 `BrowserAPIServer`，`applicationWillTerminate` 收尾；
- L10n 表新增中英键：`menu.toggleBrowser`、`bar.browser`、`browser.title/newTab/newTabHint/closeTab/empty/addressPlaceholder/back/forward/reload/stop/devTools/console/clear/eval/go` 等。

### 子系统 4：构建与 CI

- `build-app.sh`：SWIFT_SOURCES += `BrowserPanel.swift` `BrowserAPI.swift`；
- `.github/workflows/ci.yml`：swiftc 编译检查清单 += 两个新文件；新增 `tests/browser-panel/run.sh` 步骤。

### 子系统 5：Agent 技能（新增 `.dsh/skills/shell-browser/SKILL.md`）

仿 `issue-fix` 技能格式（frontmatter: name/description/modelInvocable）：端口发现（读 `~/.dsh/browser-api.port` 或默认 3081）；标准排查工作流：`open` 页面 → 轮询 `status` 直到 `!loading`（带超时）→ 读 `console`/`network`（failedOnly 过滤）→ `eval` 取 DOM/JS 状态 → `screenshot` 存工作区 → 视觉读图 → 汇报；明确可用性前提与安全边界（仅本机、eval 可读页面）。

### 子系统 6：测试（新增 `tests/browser-panel/`，仿 wiki-panel 无头模式）

`run.sh` + `browser-tests.swift` + `stubs.swift`（复用 terminal-emulator stubs 并补 `CustomIconButton.Glyph.symbol(String)`）：`BrowserLogBuffer`（cap/clear/level 过滤）、`BrowserURL.normalize`（补 scheme/about:blank/非法）、`HTTPRequest.parse`（GET/POST/Content-Length/CORS OPTIONS/畸形 400）、`BrowserAPIRouter` 路由映射（FakeDelegate 桩）。约 25 断言；编译仅 AppKit/Foundation（WKWebView 相关类不实例化）。

### 子系统 7：文档

- `docs/plans/BROWSER_PLAN-browser-panel.md`（本文档）；
- README（浏览器面板特性 + `DSH_BROWSER_PORT`/`DSH_BROWSER_TEST` 环境变量 + API 摘要 + 限制说明）；
- `.dsh/wiki/` 增量更新（index、新增 `modules/browser-panel.md`、tasks.md、conventions.md、architecture.md）；CHANGELOG 条目。

## 五、数据流（关键路径）

1. 用户/Agent `POST /api/browser/open {url}` → BrowserAPI → 主线程 BrowserPanelController → 激活/新建 tab WKWebView 加载 → `setRightPanel(.browser)`（Agent 驱动自动展开）→ WKNavigationDelegate 回调（title/loading/error → 缓冲 + 抽屉 UI）；
2. 页面 JS 产生 console/网络事件 → 注入脚本 → `messageHandlers.browserConsole` → 面板缓冲 → REST 可读；
3. `POST /api/browser/eval` → `evaluateJavaScript` → JSON 回包；
4. `GET /api/browser/screenshot` → 展开面板 → `takeSnapshot` → PNG → 响应（Agent `curl -o workspace/shot.png` → 读图/分享 → 预览面板展示）。

## 六、边界情况与失败处理

- **面板隐藏**：隐藏不杀 tab（同终端）；关 tab 释放对应 WKWebView；退出 `shutdownAll`；
- **控制台/网络缓冲**：环形 2000 条；多 tab 各自缓冲（本方案 v1 聚合显示，API 可加 tabId 过滤）；
- **eval 异常**：`{ok:false, error}`；表达式用 `eval()` 包 JSON.stringify，语句也可执行；
- **证书错误**：WKWebView 默认行为（不自动放行）；didFail 记录到 console；
- **地址栏输入**：`BrowserURL.normalize`（无 scheme 补 `https://`；`about:blank`/`file://` 原样；非法 → 空态提示）；
- **截图**：面板不可见时先 `setRightPanel(.browser)` + 布局后再 `takeSnapshot`；失败回 `{ok:false}`；
- **内存**：tab 上限 8，超限禁用「+」并提示；
- **注入脚本跨页**：每次导航重新注入（WKUserScript 自动）；跨域页面照常注入（content world）；
- **多实例**：API 端口升位 + port 文件各自写入（log 为准）。

## 七、明确假设

1. 采纳用户指示：多标签（同终端）；按计划回退 WKWebView（CEF 环境阻塞，§二）；
2. WKWebView 的调试能力 = 注入捕获（console/网络，main-frame JS 调用）+ JS 求值 + Safari Web Inspector（`isInspectable`）；**不做**完整 DevTools 面板（WKWebView 无公共 DevTools API）；
3. 每 tab 独立 WKWebView 与独立 dataStore（cookie 与 dsh web 隔离）；v1 不做 tab 间会话隔离；
4. Agent 驱动 API 无鉴权、仅 127.0.0.1（与 dsh web 3080 同信任模型）；
5. API 服务随 App 启动常驻（Agent 可随时驱动）；
6. 本次不 bump 版本号（开发线 1.11.0）；不改任何 DeepSeek Harness 源码。

## 八、实施顺序（feature/browser-panel 分支，PR 回 main）

1. 设计文档（本文档）落盘；
2. `BrowserPanel.swift`（模型 + 注入脚本 + 多标签 UI + 控制台抽屉）；
3. `BrowserAPI.swift`（HTTP 服务 + 纯模型路由）；
4. main.swift 接线 + L10n + QA 钩子 + 持久化 + API 启停；
5. build-app.sh/CI 登记 + `tests/browser-panel/` 单测 + skill；
6. 文档/wiki/README/CHANGELOG + 全量构建 + 手动 QA（§九）→ PR。

## 九、测试与验收（手动 QA 清单）

1. 活动栏 globe / ⌥⌘B 开面板；多标签 +/✕/⌘1-9（同终端）；地址栏导航、后退/前进/刷新/停止、标题更新；
2. 控制台抽屉：页面 console.log/warn/error 实时入列、fetch/XHR 网络行（状态码、失败标红）、JS 求值 `document.title` 等、清空；
3. Safari → 开发 → oh-my-dsh → 浏览器面板：完整 Web Inspector 可附加（Elements/Network/Console）；
4. Agent 全流程（终端面板 curl）：status → open https://example.com → 轮询 loading → console/network → eval → screenshot 存工作区并可在预览面板查看；Agent 驱动时面板自动展开；
5. 面板状态跨重启恢复、与预览/终端/wiki/任务四面板互斥；`DSH_BROWSER_TEST=1` 直开面板；`DSH_UI_DEBUG=1` dump 正常；
6. 构建产物 arm64 + universal 通过；退出无残留；**全程无钥匙串密码弹窗**；
7. `tests/browser-panel/run.sh` 全绿 + 既有测试套件全绿 + CI swiftc 编译检查含新文件；
8. L10n 中英成对、README/wiki/CHANGELOG 更新到位。

## 十、风险与后续

- **CEF 复活**：见 §二「CEF 复活条件」（Developer ID 签名落地或 CEF 修复后，复用已验证集成路径；届时 REST 路由面不变，可平滑替换渲染内核）；
- **注入捕获局限**：main-frame JS 网络调用之外（图片/CSS/子框架）不捕获——文档明示，排查深度场景用 Safari Web Inspector；
- **多标签内存**：每 tab 一个 WKWebView，上限 8；极端页面仍可能高内存（与 Chrome 多标签同量级）。
