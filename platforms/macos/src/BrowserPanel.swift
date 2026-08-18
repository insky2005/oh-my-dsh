// BrowserPanel.swift — 浏览器面板（右栏槽位）。
//
// WKWebView 多标签浏览器：地址栏/前进后退/刷新停止、控制台抽屉（注入捕获
// console + fetch/XHR 网络日志 + JS 求值）、`isInspectable` 开启 Safari
// Web Inspector 完整调试；页面状态经壳层 REST API（BrowserAPI.swift）供
// Agent/用户 curl 驱动。
//
// 注：CEF（嵌入式 Chromium）方案 spike 因环境阻塞回退为 WKWebView，见
// docs/plans/BROWSER_PLAN-browser-panel.md §二。

import AppKit
import WebKit

// MARK: - 日志模型（纯模型，可单测）

/// 一条控制台/网络日志。
struct BrowserConsoleEntry {
    let timestamp: TimeInterval
    let level: String  // log / info / warn / error / debug / network
    let text: String
}

/// 环形日志缓冲（per-tab）。
final class BrowserLogBuffer {
    private(set) var entries: [BrowserConsoleEntry] = []
    let maxEntries: Int

    init(maxEntries: Int = 2000) {
        self.maxEntries = maxEntries
    }

    func append(level: String, text: String) {
        entries.append(BrowserConsoleEntry(timestamp: Date().timeIntervalSince1970, level: level, text: text))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func entries(level: String? = nil, limit: Int? = nil) -> [BrowserConsoleEntry] {
        var result = entries
        if let level = level {
            result = result.filter { $0.level == level }
        }
        if let limit = limit, result.count > limit {
            result = Array(result.suffix(limit))
        }
        return result
    }
}

// MARK: - URL 规范化（纯模型，可单测）

enum BrowserURL {
    /// 无 scheme 时补 https://；about:blank / file: / data: 原样；非法输入返回 nil。
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "about:blank" { return trimmed }
        if trimmed.hasPrefix("file://") { return trimmed }
        if trimmed.hasPrefix("data:") { return trimmed }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return trimmed
        }
        let candidate = "https://" + trimmed
        if let url = URL(string: candidate), url.host != nil {
            return candidate
        }
        return nil
    }
}

// MARK: - 注入脚本（console + 网络捕获）

/// 注入到每个页面（所有 frame）：包装 console 方法、window.onerror、
/// unhandledrejection、fetch 与 XMLHttpRequest，把事件发给
/// messageHandlers.browserConsole。仅捕获 main-frame JS 发起的调用
/// （图片/CSS/子框架请求捕获不到，属文档化限制；完整调试用 Safari
/// Web Inspector）。
private let browserInjectionScript = """
(function(){
  if (window.__ohMyDshBrowserInstalled) { return; }
  window.__ohMyDshBrowserInstalled = true;
  var send = function(level, args){
    try {
      var text = Array.prototype.map.call(args, function(a){
        try { return (typeof a === 'string') ? a : JSON.stringify(a); } catch(e){ return String(a); }
      }).join(' ');
      window.webkit.messageHandlers.browserConsole.postMessage({level: level, text: text});
    } catch(e){}
  };
  ['log','info','warn','error','debug'].forEach(function(m){
    var orig = console[m];
    console[m] = function(){ send(m, arguments); orig.apply(console, arguments); };
  });
  window.addEventListener('error', function(e){
    send('error', [e.message + ' @ ' + (e.filename || '') + ':' + (e.lineno || '')]);
  });
  window.addEventListener('unhandledrejection', function(e){
    send('error', ['Unhandled rejection: ' + String(e.reason)]);
  });
  var origFetch = window.fetch;
  window.fetch = function(input, init){
    var url = (typeof input === 'string') ? input : ((input && input.url) || String(input));
    var start = Date.now();
    return origFetch.apply(this, arguments).then(function(r){
      try { send('network', [(r.status >= 400 ? 'FAIL ' : 'OK ') + r.status + ' ' + url + ' (' + (Date.now() - start) + 'ms)']); } catch(e){}
      return r;
    }, function(err){
      try { send('network', ['ERR ' + url + ' ' + String(err)]); } catch(e){}
      throw err;
    });
  };
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url){
    this.__ohMyDshXhr = { method: method, url: String(url), start: 0 };
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(){
    var self = this;
    if (this.__ohMyDshXhr) {
      this.__ohMyDshXhr.start = Date.now();
      this.addEventListener('loadend', function(){
        try {
          var x = self.__ohMyDshXhr;
          send('network', [self.status + ' ' + x.method + ' ' + x.url + ' (' + (Date.now() - x.start) + 'ms)']);
        } catch(e){}
      });
    }
    return origSend.apply(this, arguments);
  };
})();
"""

// MARK: - 面板根视图（防 layer 合成陷阱，同 WikiRootView 模式）

final class BrowserRootView: NSView {
    var kind: DynamicFillView.Kind = .window {
        didSet { needsDisplay = true }
    }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        switch kind {
        case .window:
            color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        case .control:
            color = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        case .custom(let c):
            color = c
        }
        color.setFill()
        dirtyRect.fill()
    }
}

// MARK: - 单个标签页

final class BrowserTab: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let id: Int64
    let container: NSView
    let webView: WKWebView
    let logBuffer = BrowserLogBuffer()
    weak var owner: BrowserPanelController?

    private(set) var title: String = ""
    private(set) var url: String = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    init(id: Int64, owner: BrowserPanelController) {
        self.id = id
        self.owner = owner

        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.addUserScript(
            WKUserScript(source: browserInjectionScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))
        config.userContentController = userController
        // 浏览器面板独立 dataStore：cookie/localStorage 与 dsh web 视图隔离。
        // （forIdentifier 需 macOS 14+；13 上回退非持久化 store。）
        if #available(macOS 14.0, *),
           let storeID = UUID(uuidString: "6F8B2A3C-D5E1-4C9A-9B2F-1A2B3C4D5E6F") {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        } else {
            config.websiteDataStore = .nonPersistent()
        }

        let web = WKWebView(frame: .zero, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.allowsMagnification = true
        if #available(macOS 13.3, *) {
            web.isInspectable = true  // Safari → 开发 → oh-my-dsh → 此面板
        }
        self.webView = web

        container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        web.frame = container.bounds
        container.addSubview(web)

        super.init()

        web.navigationDelegate = self
        userController.add(self, name: "browserConsole")

        // KVO 同步状态（url/title/isLoading/canGoBack/canGoForward）。
        for key in [#keyPath(WKWebView.url), #keyPath(WKWebView.title),
                    #keyPath(WKWebView.isLoading), #keyPath(WKWebView.canGoBack),
                    #keyPath(WKWebView.canGoForward)] {
            web.addObserver(self, forKeyPath: key, options: [.initial, .new], context: nil)
        }
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "browserConsole")
    }

    func load(url: String) {
        guard let target = BrowserURL.normalize(url) else {
            logBuffer.append(level: "error", text: "无法识别的地址: \(url)")
            owner?.consoleUpdated()
            return
        }
        self.url = target
        if target == "about:blank" {
            webView.loadHTMLString("", baseURL: nil)
        } else if let u = URL(string: target) {
            webView.load(URLRequest(url: u))
        }
    }

    // MARK: KVO

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard object as? WKWebView === webView else { return }
        switch keyPath {
        case #keyPath(WKWebView.url):
            if let u = webView.url?.absoluteString { url = u }
        case #keyPath(WKWebView.title):
            title = webView.title ?? ""
        case #keyPath(WKWebView.isLoading):
            isLoading = webView.isLoading
        case #keyPath(WKWebView.canGoBack):
            canGoBack = webView.canGoBack
        case #keyPath(WKWebView.canGoForward):
            canGoForward = webView.canGoForward
        default:
            break
        }
        owner?.tabStateChanged(self)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        logBuffer.append(level: "error", text: "加载失败: \(nsError.localizedDescription) (\(webView.url?.absoluteString ?? ""))")
        owner?.consoleUpdated()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        logBuffer.append(level: "error", text: "加载中断: \(nsError.localizedDescription)")
        owner?.consoleUpdated()
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "browserConsole",
              let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["text"] as? String else { return }
        logBuffer.append(level: level, text: text)
        owner?.consoleUpdated()
    }
}

// MARK: - 面板控制器

final class BrowserPanelController: NSObject {
    /// 根视图：直接挂为右栏 split view 的第二个 pane。
    let view = BrowserRootView()
    /// 用户点击「关闭」时收起面板。
    var onRequestHide: (() -> Void)?

    static let minWidth: CGFloat = 300

    /// 标签页上限（每 tab 一个 WKWebView，内存随页数增长）。
    static let maxTabs = 8

    // MARK: 子视图

    private let headerTitle = HeaderLabel()
    private var openInBrowserButton: CustomIconButton!
    private var copyURLButton: CustomIconButton!
    private var consoleToggleButton: CustomIconButton!
    private var hideButton: CustomIconButton!
    private var backButton: CustomIconButton!
    private var forwardButton: CustomIconButton!
    private var reloadButton: CustomIconButton!
    private var addressField: NSTextField!
    private var goButton: CustomIconButton!
    private let tabBar = DynamicFillView()
    private var tabBarStack: NSStackView!
    private var newTabButton: CustomIconButton!
    private let contentContainer = NSView()
    private let drawer = DynamicFillView()
    private let drawerTitle = HeaderLabel()
    private var clearLogButton: CustomIconButton!
    private var drawerCloseButton: CustomIconButton!
    private let logView = NSTextView()
    private var evalField: NSTextField!
    private var evalButton: CustomIconButton!
    private let emptyLabel = HeaderLabel()

    // MARK: 状态

    private var tabs: [BrowserTab] = []
    /// 当前活动标签页（内部供 BrowserAPIBridge 读取）。
    var activeTab: BrowserTab?
    private var tabButtons: [Int64: HoverButton] = [:]
    private var nextTabId: Int64 = 1
    private var isDrawerOpen = false

    override init() {
        super.init()
        buildUI()
        showEmptyState()
    }

    // MARK: UI

    private func buildUI() {
        view.kind = .window
        headerTitle.text = L10n.tr("browser.title")
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openInBrowserButton = CustomIconButton(glyph: .symbol("safari"), tooltip: L10n.tr("browser.openInSystem"))
        openInBrowserButton.onAction = { [weak self] in self?.openInSystemBrowser() }
        copyURLButton = CustomIconButton(glyph: .symbol("link"), tooltip: L10n.tr("browser.copyURL"))
        copyURLButton.onAction = { [weak self] in self?.copyActiveURL() }
        consoleToggleButton = CustomIconButton(glyph: .symbol("chevron.up.chevron.down"), tooltip: L10n.tr("browser.console"))
        consoleToggleButton.onAction = { [weak self] in self?.toggleDrawer() }
        hideButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("preview.closePanel"))
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }

        let headerActions = NSStackView(views: [openInBrowserButton, copyURLButton, consoleToggleButton, hideButton])
        headerActions.orientation = .horizontal
        headerActions.spacing = 6
        headerActions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(headerActions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: headerActions.leadingAnchor, constant: -8),
            headerActions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            headerActions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // 工具栏：后退/前进/刷新·停止 + 地址栏 + 前往
        backButton = CustomIconButton(glyph: .symbol("chevron.left"), tooltip: L10n.tr("browser.back"))
        backButton.onAction = { [weak self] in self?.activeTab?.webView.goBack() }
        forwardButton = CustomIconButton(glyph: .symbol("chevron.right"), tooltip: L10n.tr("browser.forward"))
        forwardButton.onAction = { [weak self] in self?.activeTab?.webView.goForward() }
        reloadButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: L10n.tr("browser.reload"))
        reloadButton.onAction = { [weak self] in
            guard let tab = self?.activeTab else { return }
            if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
        }
        addressField = NSTextField()
        addressField.placeholderString = L10n.tr("browser.addressPlaceholder")
        addressField.font = .systemFont(ofSize: 12)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))
        addressField.isBezeled = true
        goButton = CustomIconButton(glyph: .symbol("arrow.right.circle"), tooltip: L10n.tr("browser.go"))
        goButton.onAction = { [weak self] in self?.submitAddress() }

        let toolbar = DynamicFillView()
        toolbar.kind = .control
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let toolbarStack = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, goButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 6
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbarStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarStack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        // 标签栏
        tabBar.kind = .control
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        newTabButton = CustomIconButton(glyph: .plus, tooltip: L10n.tr("browser.newTabHint"))
        newTabButton.onAction = { [weak self] in self?.newTab(url: nil) }
        tabBarStack = NSStackView(views: [newTabButton])
        tabBarStack.orientation = .horizontal
        tabBarStack.spacing = 2
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBarStack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        tabBar.addSubview(tabBarStack)
        NSLayoutConstraint.activate([
            tabBarStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabBarStack.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabBarStack.topAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBarStack.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 33),
        ])

        // 内容区（标签容器显隐切换）
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        // 控制台抽屉
        drawer.kind = .window
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.wantsLayer = true
        drawer.layer?.masksToBounds = true
        drawer.isHidden = true

        drawerTitle.text = L10n.tr("browser.console")
        drawerTitle.translatesAutoresizingMaskIntoConstraints = false
        clearLogButton = CustomIconButton(glyph: .symbol("trash"), tooltip: L10n.tr("browser.clear"))
        clearLogButton.onAction = { [weak self] in
            self?.activeTab?.logBuffer.clear()
            self?.refreshLogView()
        }
        drawerCloseButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("browser.consoleClose"))
        drawerCloseButton.onAction = { [weak self] in self?.toggleDrawer() }

        let drawerHeader = NSStackView(views: [drawerTitle, clearLogButton, drawerCloseButton])
        drawerHeader.orientation = .horizontal
        drawerHeader.spacing = 6
        drawerHeader.translatesAutoresizingMaskIntoConstraints = false

        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .textBackgroundColor
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width, .height]
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logView.frame = logScroll.bounds

        evalField = NSTextField()
        evalField.placeholderString = L10n.tr("browser.evalPlaceholder")
        evalField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        evalField.translatesAutoresizingMaskIntoConstraints = false
        evalField.target = self
        evalField.action = #selector(evalSubmitted(_:))
        evalButton = CustomIconButton(glyph: .symbol("play.fill"), tooltip: L10n.tr("browser.eval"))
        evalButton.onAction = { [weak self] in self?.runEval() }

        let evalRow = NSStackView(views: [evalField, evalButton])
        evalRow.orientation = .horizontal
        evalRow.spacing = 6
        evalRow.translatesAutoresizingMaskIntoConstraints = false

        drawer.addSubview(drawerHeader)
        drawer.addSubview(logScroll)
        drawer.addSubview(evalRow)
        NSLayoutConstraint.activate([
            drawerHeader.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 8),
            drawerHeader.topAnchor.constraint(equalTo: drawer.topAnchor, constant: 6),
            drawerHeader.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -8),
            logScroll.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 8),
            logScroll.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -8),
            logScroll.topAnchor.constraint(equalTo: drawerHeader.bottomAnchor, constant: 6),
            evalRow.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 8),
            evalRow.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -8),
            evalRow.topAnchor.constraint(equalTo: logScroll.bottomAnchor, constant: 6),
            evalRow.bottomAnchor.constraint(equalTo: drawer.bottomAnchor, constant: -8),
            drawer.heightAnchor.constraint(equalToConstant: 190),
        ])

        // 空态
        emptyLabel.text = L10n.tr("browser.empty")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        view.addSubview(header)
        view.addSubview(toolbar)
        view.addSubview(tabBar)
        view.addSubview(contentContainer)
        view.addSubview(drawer)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: drawer.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
        ])
    }

    // MARK: 标签管理

    func ensureLoaded() {
        if tabs.isEmpty {
            let lastURL = UserDefaults.standard.string(forKey: "browserLastURL") ?? "about:blank"
            _ = newTab(url: lastURL)
        }
    }

    @discardableResult
    func newTab(url: String?) -> BrowserTab {
        if tabs.count >= Self.maxTabs { return activeTab ?? tabs.last! }
        let tab = BrowserTab(id: nextTabId, owner: self)
        nextTabId += 1
        tab.container.frame = contentContainer.bounds
        tab.container.autoresizingMask = [.width, .height]
        contentContainer.addSubview(tab.container)
        tabs.append(tab)
        addTabButton(for: tab)
        if let url = url {
            tab.load(url: url)
        } else {
            tab.load(url: "about:blank")
        }
        select(tab)
        emptyLabel.isHidden = true
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.container.removeFromSuperview()
        tabButtons.removeValue(forKey: tab.id)
        rebuildTabBar()
        tabs.remove(at: idx)
        if activeTab === tab {
            activeTab = tabs.isEmpty ? nil : tabs[max(0, idx - 1)]
            if let active = activeTab {
                select(active)
            } else {
                showEmptyState()
            }
        }
    }

    private func select(_ tab: BrowserTab) {
        activeTab = tab
        for t in tabs {
            t.container.isHidden = (t !== tab)
        }
        updateToolbar()
        refreshLogView()
        updateTabButtons()
    }

    /// 按 id 取标签页（API 用）。
    func tab(withId id: Int64) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    /// 激活指定标签页（API 用）。
    func selectTab(_ tab: BrowserTab) {
        select(tab)
    }

    private func showEmptyState() {
        activeTab = nil
        for t in tabs { t.container.isHidden = true }
        updateToolbar()
        emptyLabel.isHidden = tabs.isEmpty ? false : true
        drawer.isHidden = true
        isDrawerOpen = false
        refreshLogView()
    }

    // MARK: 标签栏

    private func addTabButton(for tab: BrowserTab) {
        let button = HoverButton()
        button.title = displayTitle(tab)
        button.font = .systemFont(ofSize: 11)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(tabButtonClicked(_:))
        button.tag = Int(tab.id)
        tabButtons[tab.id] = button
        rebuildTabBar()
    }

    private func displayTitle(_ tab: BrowserTab) -> String {
        if !tab.title.isEmpty { return tab.title }
        if let u = URL(string: tab.url), let host = u.host, !host.isEmpty { return host }
        return "\(tab.id)"
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        guard let tab = tabs.first(where: { $0.id == Int64(sender.tag) }) else { return }
        select(tab)
    }

    private func rebuildTabBar() {
        var views: [NSView] = [newTabButton]
        for tab in tabs {
            if let button = tabButtons[tab.id] { views.append(button) }
        }
        for sub in tabBarStack.arrangedSubviews {
            tabBarStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for v in views { tabBarStack.addArrangedSubview(v) }
        updateTabButtons()
    }

    private func updateTabButtons() {
        for (id, button) in tabButtons {
            let isActive = tabs.first(where: { $0.id == id }) === activeTab
            button.state = isActive ? .on : .off
            if let tab = tabs.first(where: { $0.id == id }) {
                button.title = displayTitle(tab)
            }
        }
    }

    // MARK: 工具栏

    private func updateToolbar() {
        guard let tab = activeTab else {
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            addressField.stringValue = ""
            return
        }
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        reloadButton.isEnabled = true
        let display = tab.url.isEmpty ? "about:blank" : tab.url
        if addressField.currentEditor() == nil, addressField.stringValue != display {
            addressField.stringValue = display
        }
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        submitAddress()
    }

    private func submitAddress() {
        guard let tab = activeTab else { return }
        let raw = addressField.stringValue
        guard let target = BrowserURL.normalize(raw) else {
            logBuffer(of: tab).append(level: "error", text: "无法识别的地址: \(raw)")
            consoleUpdated()
            return
        }
        tab.load(url: target)
    }

    // MARK: 头部操作

    private func openInSystemBrowser() {
        guard let tab = activeTab, !tab.url.isEmpty else { return }
        if let url = URL(string: tab.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyActiveURL() {
        guard let tab = activeTab else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.url.isEmpty ? "about:blank" : tab.url, forType: .string)
    }

    // MARK: 控制台抽屉

    private func toggleDrawer() {
        isDrawerOpen.toggle()
        drawer.isHidden = !isDrawerOpen
        if isDrawerOpen { refreshLogView() }
    }

    private func logBuffer(of tab: BrowserTab?) -> BrowserLogBuffer {
        tab?.logBuffer ?? BrowserLogBuffer()
    }

    /// 收到新的 console/网络事件（主线程回调）。
    func consoleUpdated() {
        if isDrawerOpen { refreshLogView() }
    }

    private func refreshLogView() {
        guard isDrawerOpen, let tab = activeTab else {
            logView.string = ""
            return
        }
        let attr = NSMutableAttributedString()
        let colors: [String: NSColor] = [
            "error": .systemRed,
            "warn": .systemOrange,
            "network": .systemTeal,
            "info": .secondaryLabelColor,
            "debug": .secondaryLabelColor,
            "log": .labelColor,
        ]
        for entry in tab.logBuffer.entries() {
            let color = colors[entry.level] ?? .labelColor
            let line = "[\(entry.level)] \(entry.text)\n"
            attr.append(NSAttributedString(string: line, attributes: [.foregroundColor: color]))
        }
        logView.textStorage?.setAttributedString(attr)
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func evalSubmitted(_ sender: Any?) {
        runEval()
    }

    /// 把用户表达式包成可求值的脚本：表达式先 JSON 序列化为 JS 字符串字面量，
    /// 再交给 eval() 执行（支持表达式与语句），结果 JSON.stringify 回传。
    private static func evalScript(for expression: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [expression])).map { String(data: $0, encoding: .utf8) ?? "\"\"" } ?? "\"\""
        let quoted = String(literal.dropFirst().dropLast())
        return "JSON.stringify(eval(" + quoted + "))"
    }

    private func runEval() {
        guard let tab = activeTab else { return }
        let expression = evalField.stringValue
        guard !expression.isEmpty else { return }
        logBuffer(of: tab).append(level: "log", text: "> \(expression)")
        let script = Self.evalScript(for: expression)
        tab.webView.evaluateJavaScript(script) { [weak self, weak tab] result, error in
            guard let self = self, let tab = tab else { return }
            if let error = error {
                tab.logBuffer.append(level: "error", text: "求值错误: \((error as NSError).localizedDescription)")
            } else if let s = result as? String {
                tab.logBuffer.append(level: "info", text: s)
            } else {
                tab.logBuffer.append(level: "info", text: String(describing: result ?? "undefined"))
            }
            self.consoleUpdated()
        }
    }

    // MARK: 状态同步（tab KVO → 面板 UI）

    func tabStateChanged(_ tab: BrowserTab) {
        guard tab === activeTab else { return }
        updateToolbar()
        updateTabButtons()
    }

    // MARK: 对外 API（BrowserAPI 经主线程调用）

    /// 面板状态快照（JSON 友好）。
    func statusSnapshot() -> [String: Any] {
        let tabInfos = tabs.map { tab -> [String: Any] in
            [
                "id": tab.id,
                "url": tab.url,
                "title": tab.title,
                "loading": tab.isLoading,
                "canGoBack": tab.canGoBack,
                "canGoForward": tab.canGoForward,
            ]
        }
        return [
            "panelVisible": true,
            "tabs": tabInfos,
            "activeTabId": activeTab?.id ?? 0,
        ]
    }

    /// 打开 URL：tab = "new" 新建，否则在活动 tab 导航；返回目标 tab id。
    func openURL(_ raw: String, tab: String?) -> Int64? {
        guard let target = BrowserURL.normalize(raw) else { return nil }
        if tab == "new" {
            return newTab(url: target).id
        }
        if let active = activeTab {
            active.load(url: target)
            return active.id
        }
        return newTab(url: target).id
    }

    /// 执行 JS 求值；completion 在主线程回调。
    func evaluate(expression: String, completion: @escaping (Result<Any?, Error>) -> Void) {
        guard let tab = activeTab else {
            completion(.failure(NSError(domain: "Browser", code: 1, userInfo: [NSLocalizedDescriptionKey: "no active tab"])))
            return
        }
        tab.webView.evaluateJavaScript(Self.evalScript(for: expression)) { result, error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(result))
            }
        }
    }

    /// 截图（PNG Data）；面板不可见时自动展开（由壳层 setRightPanel 处理）。
    func screenshot(completion: @escaping (Data?) -> Void) {
        guard let tab = activeTab else {
            completion(nil)
            return
        }
        tab.webView.takeSnapshot(with: nil) { image, _ in
            guard let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                completion(nil)
                return
            }
            completion(png)
        }
    }

    /// 退出清理。
    func shutdownAll() {
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.navigationDelegate = nil
            tab.webView.configuration.userContentController.removeScriptMessageHandler(forName: "browserConsole")
            tab.container.removeFromSuperview()
        }
        tabs.removeAll()
        tabButtons.removeAll()
    }
}
