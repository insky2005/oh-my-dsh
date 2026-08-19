// BrowserPanel.swift — 浏览器面板（右栏槽位，Chromium/CEF 内核）。
//
// 多标签浏览器：地址栏（位于页签下方，Chrome 式）/前进后退/刷新停止；
// 「DevTools」按钮在面板内新开标签页打开 Chromium 自带的完整 DevTools
// （Console/Network/Elements/Sources，经 CDP 前端）；页面状态经壳层
// REST API（BrowserAPI.swift）供 Agent/用户 curl 驱动（console/网络日志
// 由 CDP 事件持续写入缓冲，供 API 读取）。
//
// UI 结构遵循 TerminalPanel/WikiPanel 的成熟模式（头部 40pt + 标签栏 33pt
// + 地址栏 36pt + 内容区钉底）；第二行及内容区均做 layer 隔离
// （wantsLayer + masksToBounds），避免 opaque 视图合成溢出盖住头部按钮
// （docs/terminal-header-fix.md 同源问题）。
//
// 背景：CEF 148+ 在 macOS 要求五个 helper app（base/Alerts/GPU/Plugin/
// Renderer，名字承重）——缺 Helper (Renderer).app 会导致 renderer 静默失败
// （曾误判为签名问题），见 docs/plans/BROWSER_PLAN-browser-panel.md §二。

import AppKit
import Foundation

// MARK: - 日志模型（纯模型，可单测）

/// 一条控制台/网络日志。
struct BrowserConsoleEntry {
    let timestamp: TimeInterval
    let level: String  // log / info / warn / error / debug / network
    let text: String
}

/// 环形日志缓冲（per-tab；供 REST API console 端点读取）。
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
        if trimmed.hasPrefix("devtools://") { return trimmed }
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

// MARK: - 面板根视图（防 layer 合成陷阱，同 WikiRootView 模式）

final class BrowserRootView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 根视图 layer-backed：让子视图的 layer（含 OSR 帧层）正确合成
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true  // 同 TerminalRootView/WikiRootView：根尺寸变化时重新布局约束子视图
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor = dark
            ? NSColor(calibratedWhite: 0.28, alpha: 1)
            : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

// MARK: - OSR 内容视图（自绘 CEF 帧 + 输入转发）

// MARK: - DevTools 工具条（可上下拖动调整 DevTools 区高度）

/// DevTools 工具条：背景 + 标题 + 关闭按钮；按住空白处上下拖动
/// 调整 DevTools 区高度（回调目标高度 pt）。
final class DevToolsBarView: NSView {
    /// 回调目标高度（拖动起点 + 位移，pt）。
    var onDrag: ((CGFloat) -> Void)?
    /// 拖动结束（松手）：容器统一通知 CEF resize，避免拖动中每帧重排。
    var onDragEnd: (() -> Void)?
    /// 关闭按钮点击。
    var onClose: (() -> Void)?
    /// 当前高度（由容器写入，拖动起点用）。
    var currentHeight: CGFloat = 300
    private let closeButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("browser.closeTab"), size: 16)
    private var dragStartH: CGFloat = 0
    private var dragStartY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        let bg = DynamicFillView()
        bg.kind = .control
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)
        let label = HeaderLabel()
        label.text = "DevTools"
        label.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onAction = { [weak self] in self?.onClose?() }
        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        dragStartH = currentHeight
        dragStartY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        let dy = event.locationInWindow.y - dragStartY
        onDrag?(dragStartH + dy)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }

    /// 工具条悬停时显示上下拖拽光标。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
}

final class BrowserOSRView: NSView {
    weak var tab: BrowserCEFTab?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: 页签内容（页签 = 主窗口 + DevTools 子窗口，上下分）
    /// 主窗口 CEF 容器。
    let pageView = NSView()
    /// DevTools 区（默认收起）。
    let devtoolsArea = NSView()
    /// DevTools CEF 容器（工具条下方）。
    let devtoolsContent = NSView()
    /// DevTools 浏览器 id（0 = 未打开）。
    var devtoolsBrowserId: Int64 = 0
    /// 关闭 DevTools 回调（工具条 ✕）。
    var onCloseDevTools: (() -> Void)?
    /// DevTools 高度约束：隐藏=0 / 显示=300（双约束切换，hidden 也占布局）。
    private var devtoolsHeight0: NSLayoutConstraint?
    private var devtoolsHeight300: NSLayoutConstraint?
    private let devtoolsBar = DevToolsBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 必须在入窗/加父视图之前就 layer-backed：入窗后再 wantsLayer 可能
        // 生成一个未挂进显示树的 detached layer（有 contents 却不合成上屏）。
        wantsLayer = true

        // 主窗口区
        pageView.translatesAutoresizingMaskIntoConstraints = false
        pageView.wantsLayer = true
        pageView.layer?.masksToBounds = true
        // DevTools 区：工具条 + 内容
        devtoolsArea.translatesAutoresizingMaskIntoConstraints = false
        devtoolsArea.wantsLayer = true
        devtoolsArea.layer?.masksToBounds = true
        devtoolsArea.isHidden = true
        devtoolsBar.translatesAutoresizingMaskIntoConstraints = false
        // 拖动工具条调整 DevTools 区高度（150-700pt，主窗口联动压缩）。
        // 拖动中只改布局（视图框架实时跟随），CEF resize 在松手时统一做，
        // 避免拖动中每帧 WasResized 导致页面顶部反复重排/跳动。
        devtoolsBar.onDrag = { [weak self] targetH in
            guard let self = self, let h = self.devtoolsHeight300 else { return }
            if !self.isDraggingDevTools {
                // 拖动开始：记录主窗口页面当前滚动位置（resize 后恢复）
                self.isDraggingDevTools = true
                self.savedScrollTop = -1
                if let tab = self.tab {
                    DispatchQueue.global().async { [weak tab, weak self] in
                        let r = tab?.cdp.evaluate(expression: "window.scrollY")
                        if case .success(let v)? = r, let n = v as? NSNumber {
                            DispatchQueue.main.async { self?.savedScrollTop = n.doubleValue }
                        }
                    }
                }
            }
            self.pageView.autoresizesSubviews = true
            self.devtoolsContent.autoresizesSubviews = true
            h.constant = min(700, max(150, targetH))
            self.devtoolsBar.currentHeight = h.constant
            // CEF 子视图 frame 由 layout() 统一同步（避免手动设置与
            // autoresizing/Auto Layout 竞争导致每帧微小偏移累积）；
            // 这里只布局，layout() 内同步 frame + 节流视口 resize。
            self.layoutSubtreeIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastDragResizeTime > 0.08 {
                self.lastDragResizeTime = now
                self.notifyResize()
                let did = self.devtoolsBrowserId
                if did > 0, self.devtoolsContent.bounds.height > 1 {
                    CEFShim.resizeBrowser(did, width: Float(self.devtoolsContent.bounds.width),
                                          height: Float(self.devtoolsContent.bounds.height))
                }
                // QA：记录拖动时的几何（定位"上移"：pageView 顶部应恒等于
                // 容器顶部，不随拖动移动；devtoolsArea 底部应恒为 0）
                AppLog.shared.log("devtools drag: pageView.frame=\(NSStringFromRect(self.pageView.frame)) devtoolsArea.frame=\(NSStringFromRect(self.devtoolsArea.frame)) mainFrame=\(self.pageView.subviews.first.map { NSStringFromRect($0.frame) } ?? "nil")")
            }
        }
        devtoolsBar.onDragEnd = { [weak self] in
            guard let self = self else { return }
            self.isDraggingDevTools = false
            self.notifyResize()
            // DevTools 子浏览器视口跟随（devtoolsContent 尺寸已定）
            let did = self.devtoolsBrowserId
            if did > 0, self.devtoolsContent.bounds.width > 1, self.devtoolsContent.bounds.height > 1 {
                CEFShim.resizeBrowser(did, width: Float(self.devtoolsContent.bounds.width),
                                      height: Float(self.devtoolsContent.bounds.height))
            }
            // 恢复主窗口页面滚动位置（resize 重排后 scrollTop 可能偏移）
            if self.savedScrollTop >= 0 {
                let y = self.savedScrollTop
                self.savedScrollTop = -1
                let tab = self.tab
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    DispatchQueue.global().async { [weak tab] in
                        _ = tab?.cdp.evaluate(expression: "window.scrollTo(0, \(y))")
                    }
                }
            }
        }
        devtoolsBar.onClose = { [weak self] in self?.onCloseDevTools?() }
        devtoolsContent.translatesAutoresizingMaskIntoConstraints = false
        devtoolsContent.wantsLayer = true
        devtoolsContent.layer?.masksToBounds = true
        devtoolsArea.addSubview(devtoolsBar)
        devtoolsArea.addSubview(devtoolsContent)
        // 高度约束：默认隐藏（0 高），显示时切到 300——hidden 视图的约束
        // 仍参与布局，必须有确定高度否则 pageView 被挤成 0。
        devtoolsHeight0 = devtoolsArea.heightAnchor.constraint(equalToConstant: 0)
        devtoolsHeight0!.isActive = true
        devtoolsHeight300 = devtoolsArea.heightAnchor.constraint(equalToConstant: 300)

        addSubview(pageView)
        addSubview(devtoolsArea)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: topAnchor),
            pageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: devtoolsArea.topAnchor),
            devtoolsArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            devtoolsArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            devtoolsArea.bottomAnchor.constraint(equalTo: bottomAnchor),
            devtoolsBar.leadingAnchor.constraint(equalTo: devtoolsArea.leadingAnchor),
            devtoolsBar.trailingAnchor.constraint(equalTo: devtoolsArea.trailingAnchor),
            devtoolsBar.topAnchor.constraint(equalTo: devtoolsArea.topAnchor),
            devtoolsBar.heightAnchor.constraint(equalToConstant: 28),
            devtoolsContent.topAnchor.constraint(equalTo: devtoolsBar.bottomAnchor),
            devtoolsContent.leadingAnchor.constraint(equalTo: devtoolsArea.leadingAnchor),
            devtoolsContent.trailingAnchor.constraint(equalTo: devtoolsArea.trailingAnchor),
            devtoolsContent.bottomAnchor.constraint(equalTo: devtoolsArea.bottomAnchor),
        ])
        updatePageBackground()
    }

    /// 主窗口区背景：暗色=黑 / 亮色=白（about:blank 等透明页面时）
    private func updatePageBackground() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        pageView.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePageBackground()
    }

    /// 展开 DevTools 子窗口（压缩主窗口）。
    func showDevToolsArea() {
        devtoolsHeight0?.isActive = false
        devtoolsHeight300?.isActive = true
        devtoolsArea.isHidden = false
        devtoolsBar.currentHeight = devtoolsHeight300?.constant ?? 300
        layoutSubtreeIfNeeded()
        notifyResize()
    }

    /// 收起 DevTools 子窗口（主窗口恢复全高）。
    func hideDevToolsArea() {
        devtoolsHeight300?.isActive = false
        devtoolsHeight0?.isActive = true
        devtoolsArea.isHidden = true
        layoutSubtreeIfNeeded()
        notifyResize()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        // mouseMoved 默认不送达；tracking area 让 hover 事件进 CEF。
        if window != nil, trackingArea == nil {
            trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                          owner: self, userInfo: nil)
            addTrackingArea(trackingArea!)
        }
        notifyResize()
    }

    private var trackingArea: NSTrackingArea?

    /// 尺寸变化通知 CEF（WasResized）：OSR 渲染视口必须跟随容器。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        notifyResize()
    }

    private func notifyResize() {
        guard let tab = tab, tab.browserId > 0,
              pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }
        CEFShim.resizeBrowser(tab.browserId, width: Float(pageView.bounds.width),
                              height: Float(pageView.bounds.height))
    }

    /// 布局后同步：pageView 尺寸变化（首次布局/DevTools 展开收起）时
    /// 强制 CEF 视图跟随 + 通知视口 resize（否则新页签停在 800×600 兜底，
    /// 只渲染左下角，其余灰色）。拖动 DevTools 期间完全跳过——改动 CEF
    /// 视图 frame 会让 chromium 自动检测视口变化并每帧重排（页面滚动），
    /// 松手（onDragEnd）统一刷新。
    private var lastNotifiedSize: NSSize = .zero
    private var isDraggingDevTools = false
    /// 拖动开始时主窗口页面的滚动位置（resize 后恢复，-1=未记录）。
    private var savedScrollTop: Double = -1
    /// 拖动中 CEF resize 节流（~80ms 一次，减少每帧重排抖动）。
    private var lastDragResizeTime: TimeInterval = 0
    override func layout() {
        super.layout()
        // Retina 合成坐标系：pageView/devtoolsContent 的 layer scale 必须
        // 与窗口一致（默认 1.0 会让 CEF 内容在裁剪区内合成偏移）。
        let scale = window?.backingScaleFactor ?? 2
        if pageView.layer?.contentsScale != scale { pageView.layer?.contentsScale = scale }
        if devtoolsContent.layer?.contentsScale != scale { devtoolsContent.layer?.contentsScale = scale }
        if devtoolsArea.layer?.contentsScale != scale { devtoolsArea.layer?.contentsScale = scale }
        // 统一同步 CEF 子视图 frame（唯一来源，避免与 autoresizing 竞争；
        // 拖动中同步 frame 但不 notifyResize，由 onDrag 节流统一刷新）。
        let s = pageView.bounds.size
        if s.width > 1, s.height > 1, s != lastNotifiedSize {
            lastNotifiedSize = s
            for v in pageView.subviews {
                v.frame = NSRect(origin: .zero, size: pageView.bounds.size)
            }
            for v in devtoolsContent.subviews {
                v.frame = NSRect(origin: .zero, size: devtoolsContent.bounds.size)
            }
            if !isDraggingDevTools {
                notifyResize()
            }
        }
    }

    // MARK: 输入转发（CEF OSR 坐标：左上原点；相对主窗口区）

    private func cefPoint(_ event: NSEvent) -> (x: Float, y: Float) {
        let p = pageView.convert(event.locationInWindow, from: nil)
        return (Float(p.x), Float(pageView.bounds.height - p.y))
    }

    private func modifiers(_ event: NSEvent) -> Int {
        var m = 0
        if event.modifierFlags.contains(.shift) { m |= 1 << 0 }      // EVENTFLAG_SHIFT_DOWN
        if event.modifierFlags.contains(.control) { m |= 1 << 1 }     // EVENTFLAG_CONTROL_DOWN
        if event.modifierFlags.contains(.option) { m |= 1 << 2 }      // EVENTFLAG_ALT_DOWN
        if event.modifierFlags.contains(.command) { m |= 1 << 3 }     // EVENTFLAG_COMMAND_DOWN
        return m
    }

    /// CEF OSR 交互前提：浏览器必须先获得焦点（SetFocus），否则点击/键盘
    /// 事件不会交给页面处理。点击/键入前确保 focus + firstResponder。
    func ensureFocus() {
        guard let tab = tab, tab.browserId > 0 else { return }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        CEFShim.setFocus(tab.browserId, focused: true)
    }

    override func mouseDown(with event: NSEvent) {
        ensureFocus()
        let p = cefPoint(event)
        CEFShim.sendMouseClick(tab?.browserId ?? 0, x: p.x, y: p.y, button: 0, count: 1, modifiers: Int32(modifiers(event)))
    }
    override func mouseUp(with event: NSEvent) {
        let p = cefPoint(event)
        CEFShim.sendMouseClick(tab?.browserId ?? 0, x: p.x, y: p.y, button: 0, count: 2, modifiers: Int32(modifiers(event)))
    }
    override func mouseDragged(with event: NSEvent) {
        let p = cefPoint(event)
        CEFShim.sendMouseClick(tab?.browserId ?? 0, x: p.x, y: p.y, button: 0, count: 3, modifiers: Int32(modifiers(event)))
    }
    override func rightMouseDown(with event: NSEvent) {
        ensureFocus()
        let p = cefPoint(event)
        CEFShim.sendMouseClick(tab?.browserId ?? 0, x: p.x, y: p.y, button: 1, count: 1, modifiers: Int32(modifiers(event)))
    }
    override func rightMouseUp(with event: NSEvent) {
        let p = cefPoint(event)
        CEFShim.sendMouseClick(tab?.browserId ?? 0, x: p.x, y: p.y, button: 1, count: 2, modifiers: Int32(modifiers(event)))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = cefPoint(event)
        CEFShim.sendMouseMove(tab?.browserId ?? 0, x: p.x, y: p.y, modifiers: Int32(modifiers(event)))
    }
    override func scrollWheel(with event: NSEvent) {
        let p = cefPoint(event)
        CEFShim.sendMouseWheel(tab?.browserId ?? 0, x: p.x, y: p.y,
                               deltaX: Float(event.scrollingDeltaX), deltaY: Float(event.scrollingDeltaY),
                               modifiers: Int32(modifiers(event)))
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)  // ⌘ 组合走响应链（编辑菜单等）
            return
        }
        CEFShim.sendKeyEvent(tab?.browserId ?? 0, keyCode: event.keyCode,
                             charCode: event.characters?.utf16.first ?? 0,
                             keyDown: true, modifiers: Int32(modifiers(event)))
    }
    override func keyUp(with event: NSEvent) {
        CEFShim.sendKeyEvent(tab?.browserId ?? 0, keyCode: event.keyCode,
                             charCode: 0, keyDown: false, modifiers: Int32(modifiers(event)))
    }

    /// QA：把当前帧存成 PNG 供排查（透明/黑屏/内容缺失）。
    private func writeFrameProbe(_ buffer: UnsafeRawPointer, width: Int, height: Int) {
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        var alphaSum = 0.0, lumSum = 0.0, n = 0.0
        let step = 16
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let i = (y * width + x) * 4
                let b = Double(bytes[i]), g = Double(bytes[i+1]), r = Double(bytes[i+2]), a = Double(bytes[i+3])
                alphaSum += a; lumSum += (0.299*r + 0.587*g + 0.114*b) * (a / 255.0); n += 1
                x += step
            }
            y += step
        }
        let avgAlpha = alphaSum / max(n, 1)
        let avgLum = lumSum / max(n, 1)
        lastAvgAlpha = avgAlpha
        lastAvgLum = avgLum
        let cfData = CFDataCreate(kCFAllocatorDefault, bytes, width * height * 4)!
        let provider = CGDataProvider(data: cfData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), // BGRA（CEF OnPaint 字节序）
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/osr-frame-\(frameCount).png"))
        }
        print("osr frame#\(frameCount) \(width)x\(height) avgAlpha=\(String(format: "%.0f", avgAlpha)) avgLum=\(String(format: "%.1f", avgLum)) -> /tmp/osr-frame-\(frameCount).png")
    }

    /// 收到的帧计数（QA 用）。
    private(set) var frameCount = 0
    /// 最近一帧的平均透明度/亮度（QA 用）。
    private(set) var lastAvgAlpha: Double = 0
    private(set) var lastAvgLum: Double = 0
    /// 最近一帧尺寸（QA 用）。
    private(set) var lastFrameSize = (width: 0, height: 0)

    /// 显示一帧 BGRA 像素。
    func presentFrame(_ buffer: UnsafeRawPointer, width: Int, height: Int) {
        frameCount += 1
        lastFrameSize = (width, height)
        writeFrameProbe(buffer, width: width, height: height)
        guard let layer = layer else { return }
        let bytesPerRow = width * 4
        let cfData = CFDataCreate(kCFAllocatorDefault, buffer.assumingMemoryBound(to: UInt8.self), bytesPerRow * height)
        guard let data = cfData,
              let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), // BGRA（CEF OnPaint 字节序）
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return }
        layer.contents = image
        layer.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }
}

// MARK: - 单个标签页（CEF OSR 渲染 + CDP 通道）

final class BrowserCEFTab: NSObject, CEFBrowserDelegate, BrowserCDPDelegate {
    let id: Int64
    /// shim 侧浏览器 id（由 CEFShim.createBrowser 分配，导航用它；init 后赋值）。
    var browserId: Int64 = 0
    let container: BrowserOSRView
    let logBuffer = BrowserLogBuffer()
    let cdp = BrowserCDPClient()
    weak var owner: BrowserPanelController?

    private(set) var title: String = ""
    private(set) var url: String
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// 关闭中标记：防 closeTab 重入（CEF CloseBrowser 同步触发 OnBeforeClose
    /// → tabClosedByCEF → 递归 closeTab → 二次 remove(at:) 越界崩溃）。
    var isClosing = false

    private var cdpRetries = 0

    init(id: Int64, owner: BrowserPanelController, url: String) {
        self.id = id
        self.owner = owner
        self.url = url

        container = BrowserOSRView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.autoresizingMask = [.width, .height]

        super.init()

        container.tab = self
        container.onCloseDevTools = { [weak self] in self?.closeDevTools() }
        cdp.delegate = self
        startCDPTargetPolling()
    }

    /// 创建 CEF 浏览器（必须在容器已加入窗口后再调用；容器未入窗时
    /// CEF 可能不创建/附加视图，导致页面渲染不出）。
    func createBrowser(url: String) {
        guard browserId == 0 else { return }
        // 主窗口 CEF 挂 pageView（DevTools 展开时主窗口区压缩，CEF 视口跟随）
        browserId = CEFShim.createBrowser(in: container.pageView, url: url, delegate: self)
    }

    deinit {
        cdp.disconnect()
    }

    /// 轮询 /json 找到本标签页对应的 CDP target 并连接（renderer 启动约 1s）。
    /// /json 拉取在后台队列进行，绝不阻塞主线程（否则与 CEF 消息泵死锁）。
    private func startCDPTargetPolling() {
        guard cdpRetries < 40 else { return }  // ~12s 上限
        cdpRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let owner = self.owner else { return }
            BrowserCDP.findUnclaimedTarget(claimed: owner.claimedTargetIds) { [weak self, weak owner] target in
                guard let self = self, let owner = owner else { return }
                if let target = target,
                   let id = target["id"] as? String,
                   let ws = target["webSocketDebuggerUrl"] as? String {
                    owner.claimedTargetIds.insert(id)
                    self.cdp.connect(webSocketURL: ws)
                    return
                }
                self.startCDPTargetPolling()
            }
        }
    }

    // MARK: 导航

    func load(url: String) {
        guard let target = BrowserURL.normalize(url) else {
            logBuffer.append(level: "error", text: "无法识别的地址: \(url)")
            return
        }
        self.url = target
        CEFShim.navigateBrowser(browserId, url: target)
    }

    // MARK: CEFBrowserDelegate（主线程回调）

    func cefTitleChanged(_ title: String, forBrowser id: Int64) {
        guard id == browserId else { return }  // DevTools 子浏览器回调忽略
        self.title = title
        owner?.tabStateChanged(self)
    }

    func cefAddressChanged(_ url: String, forBrowser id: Int64) {
        // 后退/前进/重定向后地址变化（窗口化模式 OnAddressChange）
        guard id == browserId else { return }
        guard url.hasPrefix("http") || url.hasPrefix("about:") || url.hasPrefix("file:") else { return }
        self.url = url
        owner?.tabStateChanged(self)
    }

    func cefLoadingStateChanged(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool, forBrowser id: Int64) {
        guard id == browserId else { return }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        owner?.tabStateChanged(self)
    }

    func cefLoadError(_ errorText: String, failedURL: String, forBrowser id: Int64) {
        guard id == browserId else { return }
        logBuffer.append(level: "error", text: "加载失败: \(errorText) (\(failedURL))")
    }

    func cefBrowserClosed(_ id: Int64) {
        if id == browserId {
            owner?.tabClosedByCEF(self)
        } else if id == container.devtoolsBrowserId {
            // DevTools 子浏览器关闭：重置状态并收起
            container.devtoolsBrowserId = 0
            container.hideDevToolsArea()
        }
    }

    /// 关闭本页签的 DevTools 子窗口（工具条 ✕）。
    func closeDevTools() {
        let did = container.devtoolsBrowserId
        container.devtoolsBrowserId = 0
        container.hideDevToolsArea()
        if did > 0 {
            // CEF 窗口化模式关浏览器会关宿主主窗口 → 必须设标记拦截误退出
            //（同 closeTab；否则 app 直接退出 = 用户看到的"闪退"）。
            g_cefClosingWindow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { g_cefClosingWindow = false }
            DispatchQueue.main.async { CEFShim.closeBrowser(did) }
        }
    }

    // MARK: BrowserCDPDelegate（主队列派发）

    func cdpEvent(level: String, text: String) {
        logBuffer.append(level: level, text: text)
    }
}

// MARK: - 面板控制器

// MARK: - 页签项（Chrome 式：标题 + 关闭按钮一体，背景圆角胶囊）

/// 单个页签：圆角背景 + 标题 + 关闭按钮（关闭按钮活动/hover 时显示）。
final class BrowserTabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isActive = false {
        didSet { updateStyle() }
    }

    /// 更新标题（导航后）。
    func setTitle(_ title: String) {
        titleButton.title = title
    }

    /// 宽度约束（页签均分/最大宽度由面板动态调整）。
    lazy var widthConstraint: NSLayoutConstraint = widthAnchor.constraint(equalToConstant: 160)

    private let titleButton = NSButton()
    private let closeButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("browser.closeTab"), size: 16)
    private var isHovered = false { didSet { updateStyle() } }
    private var trackingArea: NSTrackingArea?

    /// 动态背景色（亮/暗外观切换自动变化，不写死）。
    /// 暗色：深灰系（活动最深）；浅色：浅灰系（活动略深但仍浅）。
    private let activeBg = NSColor(name: nil) { app in
        let dark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.74, alpha: 1)
    }
    private let hoverBg = NSColor(name: nil) { app in
        let dark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.64, alpha: 1)
    }
    private let normalBg = NSColor(name: nil) { app in
        let dark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.55, alpha: 1)
    }

    init(title: String, tabId: Int64) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint.isActive = true

        titleButton.title = title
        titleButton.bezelStyle = .inline
        titleButton.setButtonType(.momentaryChange)
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 12)
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.cell?.truncatesLastVisibleLine = true
        titleButton.target = self
        titleButton.action = #selector(titleClicked(_:))
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.onAction = { [weak self] in self?.onClose?() }
        closeButton.isHidden = true
        // 关闭按钮 hover 红色高亮（Chrome 式，明显）
        closeButton.hoverColor = NSColor.systemRed

        addSubview(titleButton)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// 整个页签区域可点击切换（不仅标题文字；关闭按钮由子视图自己处理）。
    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func titleClicked(_ sender: NSButton) { onSelect?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 外观切换（亮/暗）：重新解析动态色的 cgColor 并刷新 layer。
        updateStyle()
    }

    private func updateStyle() {
        closeButton.isHidden = !(isActive || isHovered)
        // 背景：动态色（活动最深，hover 居中，非活动最浅仍可见分隔）
        let bg = isActive ? activeBg : (isHovered ? hoverBg : normalBg)
        layer?.backgroundColor = bg.cgColor
        // 活动页签标题加粗
        titleButton.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
    }
}

final class BrowserPanelController: NSObject {
    /// 根视图：直接挂为右栏 split view 的第二个 pane。
    let view = BrowserRootView()
    /// 用户点击「关闭」时收起面板。
    var onRequestHide: (() -> Void)?
    /// 内容容器（QA：命中测试 / 遮挡诊断用）。
    var contentContainerView: NSView { contentContainer }

    static let minWidth: CGFloat = 300
    /// 标签页上限（每 tab 一个 CEF 浏览器 + 渲染进程）。
    static let maxTabs = 8

    // MARK: 子视图

    private let headerTitle = HeaderLabel()
    private var newTabButton: CustomIconButton!
    private var openInBrowserButton: CustomIconButton!
    private var copyURLButton: CustomIconButton!
    private var devToolsButton: CustomIconButton!
    private var closePanelButton: CustomIconButton!
    private var backButton: CustomIconButton!
    private var forwardButton: CustomIconButton!
    private var reloadButton: CustomIconButton!
    private var addressField: NSTextField!
    private let tabStack = NSStackView()
    private let contentContainer = NSView()
    private let emptyLabel = HeaderLabel()

    // MARK: 状态

    private var tabs: [BrowserCEFTab] = []
    /// 当前活动标签页（内部供 BrowserAPIBridge 读取）。
    var activeTab: BrowserCEFTab?
    /// 已被标签页认领的 CDP target id（避免同 URL 标签页误配对）。
    var claimedTargetIds: Set<String> = []
    private var tabButtons: [Int64: BrowserTabItemView] = [:]
    private var nextTabId: Int64 = 1

    override init() {
        super.init()
        buildUI()
        showEmptyState()
        // 注册 OSR 帧回调：按 browserId 派发给对应标签页自绘。
        CEFShim.setPaintHandler { [weak self] browserId, buffer, width, height in
            guard let self = self,
                  let tab = self.tab(withId: browserId) else { return }
            tab.container.presentFrame(buffer, width: Int(width), height: Int(height))
        }
        // 光标变化回调：OSR hover 跟随页面（链接 → 手型）。
        CEFShim.setCursorHandler { [weak self] browserId, cursorPtr in
            guard let self = self else { return }
            guard let tab = self.tab(withId: browserId), tab === self.activeTab else { return }
            let cursor = Unmanaged<NSCursor>.fromOpaque(cursorPtr).takeUnretainedValue()
            cursor.set()
        }
        // 上下文菜单：OSR 下 CEF 不知道宿主窗口位置，默认菜单会弹错位；
        // 由宿主在正确屏幕坐标弹 NSMenu，命令经菜单 id 驱动 CEF 动作。
        CEFShim.setMenuRequestHandler { [weak self] browserId, x, y, items in
            guard let self = self,
                  let tab = self.tab(withId: browserId),
                  tab === self.activeTab,
                  let window = tab.container.window else { return }
            let viewPoint = tab.container.convert(
                NSPoint(x: CGFloat(x), y: tab.container.bounds.height - CGFloat(y)), to: nil)
            let screenPoint = window.convertPoint(toScreen: viewPoint)
            self.popupContextMenu(at: screenPoint, items: items, tab: tab)
        }
    }

    // MARK: 上下文菜单（OSR）

    /// 在正确屏幕坐标弹出 CEF 上下文菜单；命令经菜单 id 驱动 CEF 动作。
    private func popupContextMenu(at screenPoint: NSPoint, items: [[AnyHashable: Any]], tab: BrowserCEFTab) {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        for item in items {
            guard let type = (item["type"] as? NSNumber)?.intValue else { continue }
            if type == 1 { // CEFMenuItemSeparator
                menu.addItem(.separator())
                continue
            }
            guard let cmdId = (item["id"] as? NSNumber)?.intValue else { continue }
            let label = (item["label"] as? String) ?? "?"
            let mi = NSMenuItem(title: label, action: #selector(contextMenuItemClicked(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = [NSNumber(value: cmdId), NSNumber(value: tab.id)]
            mi.isEnabled = true
            menu.addItem(mi)
        }
        guard menu.items.count > 0 else { return }
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
        CEFShim.cancelContextMenu(tab.browserId)
    }

    @objc private func contextMenuItemClicked(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [NSNumber], payload.count == 2 else { return }
        CEFShim.executeContextMenuCommand(payload[1].int64Value, commandId: payload[0].int32Value)
    }

    // MARK: UI

    private func buildUI() {
        headerTitle.text = L10n.tr("browser.title")
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        newTabButton = CustomIconButton(glyph: .plus, tooltip: L10n.tr("browser.newTabHint"), size: 18)
        newTabButton.showsBackground = true  // 页签样式统一：带背景、hover 高亮
        // .fill 分布下固定宽度（不被拉伸）
        newTabButton.setContentHuggingPriority(.required, for: .horizontal)
        newTabButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        newTabButton.onAction = { [weak self] in self?.newTab(url: nil) }
        openInBrowserButton = CustomIconButton(glyph: .symbol("safari"), tooltip: L10n.tr("browser.openInSystem"))
        openInBrowserButton.onAction = { [weak self] in self?.openInSystemBrowser() }
        copyURLButton = CustomIconButton(glyph: .symbol("link"), tooltip: L10n.tr("browser.copyURL"))
        copyURLButton.onAction = { [weak self] in self?.copyActiveURL() }
        closePanelButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("preview.closePanel"))
        closePanelButton.onAction = { [weak self] in
            // 右上角 ✕ = 彻底关闭浏览器：关掉所有页签/浏览器 + 收起面板。
            self?.closeAllTabs()
            self?.onRequestHide?()
        }

        let headerActions = NSStackView(views: [openInBrowserButton, copyURLButton,
                                                closePanelButton])
        headerActions.orientation = .horizontal
        headerActions.spacing = 6
        headerActions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        // layer 隔离（docs/terminal-header-fix.md）：opaque 无独立 layer 的
        // 视图绘制会溢出盖住垫底的内容区（实测 header 移除后内容区即恢复）。
        // 与 toolbar 同款修复：wantsLayer + masksToBounds 收住合成。
        header.wantsLayer = true
        header.layer?.masksToBounds = true
        header.addSubview(headerTitle)
        header.addSubview(headerActions)

        // 标签栏（Chrome 式：页签固定最大宽度，数量多时均分缩小；
        // + 号作为栈内最后一项紧跟页签）
        tabStack.orientation = .horizontal
        tabStack.spacing = 6
        tabStack.alignment = .centerY
        tabStack.distribution = .fill
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.addArrangedSubview(newTabButton)  // 初始仅 + 号；rebuild 时移到末尾
        let tabBarRow = NSView()
        tabBarRow.translatesAutoresizingMaskIntoConstraints = false
        tabBarRow.addSubview(tabStack)
        let tabBarUnderline = NSBox()
        tabBarUnderline.boxType = .separator
        tabBarUnderline.translatesAutoresizingMaskIntoConstraints = false

        // 地址栏（位于页签下方，Chrome 式）：后退/前进/刷新·停止 + 地址 + 前往
        backButton = CustomIconButton(glyph: .symbol("chevron.left"), tooltip: L10n.tr("browser.back"))
        backButton.onAction = { [weak self] in
            if let tab = self?.activeTab { CEFShim.goBack(tab.browserId) }
        }
        forwardButton = CustomIconButton(glyph: .symbol("chevron.right"), tooltip: L10n.tr("browser.forward"))
        forwardButton.onAction = { [weak self] in
            if let tab = self?.activeTab { CEFShim.goForward(tab.browserId) }
        }
        reloadButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: L10n.tr("browser.reload"))
        reloadButton.onAction = { [weak self] in
            guard let tab = self?.activeTab else { return }
            if tab.isLoading { CEFShim.stop(tab.browserId) } else { CEFShim.reload(tab.browserId) }
        }
        addressField = NSTextField()
        addressField.placeholderString = L10n.tr("browser.addressPlaceholder")
        addressField.font = .systemFont(ofSize: 12)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))  // 回车触发访问
        addressField.isBezeled = true
        // DevTools 按钮（扳手）：地址栏右侧；回车即可访问，无需 Go 按钮
        devToolsButton = CustomIconButton(glyph: .symbol("wrench"), tooltip: L10n.tr("browser.devTools"))
        devToolsButton.onAction = { [weak self] in self?.openDevTools() }

        let toolbar = DynamicFillView()
        toolbar.kind = .control
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        // layer 隔离：opaque 无 layer 视图的绘制会溢出盖住上方头部按钮
        // （docs/terminal-header-fix.md 同源问题；wiki 面板工具行同款处理）。
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        let toolbarStack = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, devToolsButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 6
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbarStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.addSubview(toolbarStack)

        // 内容区：页签容器（每页签内部自带「主窗口 + DevTools 子窗口」，
        // 见 BrowserOSRView；切页签时整个容器一起隐藏/显示）。
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        // 合成隔离（docs/terminal-header-fix.md）：必须 masksToBounds，
        // 否则 OSR 帧 layer 内容可溢出容器沿合成树盖住上方头部/工具栏。
        contentContainer.layer?.masksToBounds = true

        emptyLabel.text = L10n.tr("browser.empty")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        // 子视图顺序 = z 序：与终端面板一致（header/tabs/toolbar 先加，
        // 内容区最后添加在最上层）。各控件自带 layer 隔离（wantsLayer +
        // masksToBounds）收住绘制，内容区无需垫底也不会被盖住。
        view.addSubview(header)
        view.addSubview(tabBarRow)
        view.addSubview(tabBarUnderline)
        view.addSubview(toolbar)
        view.addSubview(contentContainer)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            // header
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: headerActions.leadingAnchor, constant: -8),
            headerActions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            headerActions.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            // 标签栏行（33pt）。tabStack 宽度按内容自适应（不撑满行）：
            // 页签固定宽 +「+」按钮紧跟最后一个页签；页签多时 rebuild 缩小。
            tabBarRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabBarRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarRow.heightAnchor.constraint(equalToConstant: 33),
            tabStack.leadingAnchor.constraint(equalTo: tabBarRow.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabBarRow.topAnchor, constant: 3),
            tabStack.bottomAnchor.constraint(equalTo: tabBarRow.bottomAnchor, constant: -3),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBarRow.trailingAnchor),

            tabBarUnderline.topAnchor.constraint(equalTo: tabBarRow.bottomAnchor),
            tabBarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // 地址栏（页签下方）
            toolbar.topAnchor.constraint(equalTo: tabBarUnderline.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarStack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // 内容区钉底
            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
        ])
    }

    // MARK: 标签管理

    func ensureLoaded() {
        if tabs.isEmpty {
            // 重开面板 = 干净的空页签（不再恢复上次浏览地址）
            _ = newTab(url: "about:blank")
        }
    }

    @discardableResult
    func newTab(url: String?) -> BrowserCEFTab {
        if tabs.count >= Self.maxTabs { return activeTab ?? tabs.last! }
        let targetURL = BrowserURL.normalize(url ?? "about:blank") ?? "about:blank"
        let tab = BrowserCEFTab(id: nextTabId, owner: self, url: targetURL)
        nextTabId += 1
        UserDefaults.standard.set(targetURL, forKey: "browserLastURL")
        if contentContainer.bounds.width > 10 {
            tab.container.frame = contentContainer.bounds
        }
        contentContainer.addSubview(tab.container)   // 先入窗
        // 先布局（pageView 约束解出真实尺寸），再建 CEF 浏览器——
        // 否则 CEF 视口用 800×600 兜底，只渲染左下角其余灰色。
        tab.container.layoutSubtreeIfNeeded()
        tab.createBrowser(url: targetURL)            // 再建 CEF 浏览器
        tabs.append(tab)
        addTabButton(for: tab)
        select(tab)
        emptyLabel.isHidden = true
        // 新建空白页签（+ 按钮）：聚焦地址栏并全选，直接输入即覆盖（Chrome 式）。
        // API 带 URL 新建（tab:"new"）不抢焦点。
        if targetURL == "about:blank" {
            addressField.selectText(nil)
        }
        return tab
    }

    /// 关闭标签页（幂等：CEF 关闭回调与用户操作都会经过这里）。
    func closeTab(_ tab: BrowserCEFTab) {
        AppLog.shared.log("browser closeTab id=\(tab.id) closing=\(tab.isClosing)")
        // 幂等：CEF CloseBrowser 可能同步回调 OnBeforeClose → tabClosedByCEF
        // → 本函数重入。重入时直接返回，由最外层完成移除（见 isClosing）。
        guard !tab.isClosing else { return }
        tab.isClosing = true
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.cdp.disconnect()
        tab.container.removeFromSuperview()
        // 兜底：清理 contentContainer 里不属于任何存活 tab 的残留视图
        // （历史版本 CEF 视图直接挂在内容容器下，关闭页签时残留）。
        if tabs.count <= 1 {
            let alive = Set(tabs.filter { $0 !== tab }.map { ObjectIdentifier($0.container) })
            for v in contentContainer.subviews where !alive.contains(ObjectIdentifier(v)) {
                v.removeFromSuperview()
            }
        }
        tabButtons.removeValue(forKey: tab.id)
        rebuildTabBar()
        tabs.remove(at: idx)
        // 先摘视图/更新 UI，CEF 销毁放异步：窗口化模式下 CloseBrowser 可能
        // 等待 renderer 响应（页面加载中点击 ✕ 会阻塞主线程 → watchdog 杀），
        // 且 CEF 会关闭宿主主窗口触发误退出（见 g_cefClosingWindow 拦截）。
        let bid = tab.browserId
        if bid > 0 {
            g_cefClosingWindow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { g_cefClosingWindow = false }
            DispatchQueue.main.async { CEFShim.closeBrowser(bid) }
        }
        // DevTools 子浏览器一并关闭（随页签移除）
        let did = tab.container.devtoolsBrowserId
        if did > 0 {
            tab.container.devtoolsBrowserId = 0
            DispatchQueue.main.async { CEFShim.closeBrowser(did) }
        }
        if activeTab === tab {
            activeTab = tabs.isEmpty ? nil : tabs[max(0, idx - 1)]
            if let active = activeTab {                select(active)
            } else {
                showEmptyState()
            }
        }
    }

    /// 关闭全部标签页（右上角 ✕：彻底关闭浏览器）。
    func closeAllTabs() {
        for tab in tabs {
            closeTab(tab)
        }
    }

    /// 语言切换后刷新头部/工具栏按钮 tooltip 与面板标题。
    func refreshTooltips() {
        headerTitle.text = L10n.tr("browser.title")
        newTabButton?.toolTip = L10n.tr("browser.newTabHint")
        openInBrowserButton?.toolTip = L10n.tr("browser.openInSystem")
        copyURLButton?.toolTip = L10n.tr("browser.copyURL")
        closePanelButton?.toolTip = L10n.tr("preview.closePanel")
        backButton?.toolTip = L10n.tr("browser.back")
        forwardButton?.toolTip = L10n.tr("browser.forward")
        reloadButton?.toolTip = L10n.tr("browser.reload")
        devToolsButton?.toolTip = L10n.tr("browser.devTools")
    }

    /// CEF 侧关闭（OnBeforeClose）回调。
    func tabClosedByCEF(_ tab: BrowserCEFTab) {
        closeTab(tab)
    }

    private func select(_ tab: BrowserCEFTab) {
        activeTab = tab
        for t in tabs {
            // 整个页签容器（主窗口 + DevTools 子窗口）一起隐藏/显示
            t.container.isHidden = (t !== tab)
        }
        // 强制刷新地址栏：切页签时即使焦点在地址栏（正在编辑）也要跟随
        // 新页签 URL（Chrome 同款行为）。
        updateToolbar(forceURL: true)
        updateTabButtons()
    }

    private func showEmptyState() {
        activeTab = nil
        for t in tabs { t.container.isHidden = true }
        updateToolbar()
        emptyLabel.isHidden = tabs.isEmpty ? false : true
    }

    /// 按 id 取标签页（API 用）。
    func tab(withId id: Int64) -> BrowserCEFTab? {
        tabs.first { $0.id == id }
    }

    /// 激活指定标签页（API 用）。
    func selectTab(_ tab: BrowserCEFTab) {
        select(tab)
    }

    // MARK: 标签栏（终端同款：标题按钮 + ✕ 关闭）

    private func addTabButton(for tab: BrowserCEFTab) {
        let item = BrowserTabItemView(title: displayTitle(tab), tabId: tab.id)
        item.onSelect = { [weak self] in self?.select(tab) }
        item.onClose = { [weak self] in self?.closeTab(tab) }
        tabButtons[tab.id] = item
        rebuildTabBar()
    }

    private func displayTitle(_ tab: BrowserCEFTab) -> String {
        if tab.url == "about:blank" { return "about:blank" }
        if !tab.title.isEmpty { return tab.title }
        if let u = URL(string: tab.url), let host = u.host, !host.isEmpty { return host }
        return "\(tab.id)"
    }

    // MARK: 标签栏（Chrome 式：BrowserTabItemView，标题+关闭一体）

    private func rebuildTabBar() {
        // 保留 + 按钮，移除所有页签项
        for sub in tabStack.arrangedSubviews where sub !== newTabButton {
            tabStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        for tab in tabs {
            if let item = tabButtons[tab.id] {
                tabStack.addArrangedSubview(item)
            }
        }
        // + 号始终在页签之后（紧跟最后一个页签）
        if tabStack.arrangedSubviews.last !== newTabButton {
            tabStack.removeArrangedSubview(newTabButton)
            tabStack.addArrangedSubview(newTabButton)
        }
        // 页签宽度：最大 200pt，页签多时按可用宽度均分缩小
        // （stack 内容自适应：总宽 = 页签 + 间距 +「+」按钮 + 内边距）
        let n = max(tabs.count, 1)
        let avail = max(view.bounds.width - 12 - 18 - 6 * CGFloat(n + 1), 60)
        let per = min(CGFloat(200), avail / CGFloat(n))
        for item in tabButtons.values {
            item.widthConstraint.constant = per
        }
        updateTabButtons()
    }

    private func updateTabButtons() {
        for (id, item) in tabButtons {
            let isActive = tabs.first(where: { $0.id == id }) === activeTab
            item.isActive = isActive
            if let tab = tabs.first(where: { $0.id == id }) {
                item.setTitle(displayTitle(tab))
            }
        }
    }

    // MARK: 地址栏

    private func updateToolbar(forceURL: Bool = false) {
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
        // forceURL（切页签/关闭页签）：忽略编辑态强制更新；
        // 否则编辑中不打断用户输入（导航导致的 URL 变化除外）。
        if forceURL || (addressField.currentEditor() == nil && addressField.stringValue != display) {
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
            tab.logBuffer.append(level: "error", text: "无法识别的地址: \(raw)")
            return
        }
        tab.load(url: target)
        UserDefaults.standard.set(target, forKey: "browserLastURL")
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

    /// 在面板内新开标签页打开 Chromium 自带的完整 DevTools 前端
    /// （http://127.0.0.1:<cdpPort>/devtools/inspector.html?ws=<pageWs>）。
    func openDevTools() {
        guard let tab = activeTab else { return }
        // 必须主线程：内部做约束切换（devtoolsArea 高度）与 CEF 调用，
        // API 路由可能在并发队列线程执行。
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.openDevTools() }
            return
        }
        let targetURL = tab.url
        let port = BrowserCDP.port
        // ws 获取：实时 /json 按 URL 匹配当前页签的 target（最可靠，
        // 处理重定向）；tab.cdp.webSocketURL 的 targetId 可能陈旧/认领错
        // 页签（导航或 CDP 轮询误配）导致 DevTools 连不上，仅作兜底。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var ws: String?
            if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/json")!),
               let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                let norm = { (u: String) -> String in
                    u.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                     .replacingOccurrences(of: "www.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                let targetN = norm(targetURL)
                for t in list {
                    guard let u = t["url"] as? String, let v = t["webSocketDebuggerUrl"] as? String else { continue }
                    let n = norm(u)
                    if targetN == n || (targetN.count > 5 && (targetN.contains(n) || n.contains(targetN))) {
                        ws = v
                        break
                    }
                }
                // 兜底 1：CDP 连接记录的 targetId（可能陈旧）
                if ws == nil, let cdpWS = tab.cdp.webSocketURL,
                   let tid = cdpWS.components(separatedBy: "/devtools/page/").last, !tid.isEmpty {
                    ws = "ws://127.0.0.1:\(port)/devtools/page/\(tid)"
                }
                // 兜底 2：第一个 page target（当前页签通常是活动 target）
                if ws == nil {
                    ws = list.first(where: { ($0["type"] as? String) == "page" })?["webSocketDebuggerUrl"] as? String
                }
            }
            guard let w = ws, !w.isEmpty else {
                AppLog.shared.log("devtools: no ws (target=\(targetURL.prefix(50)))")
                return
            }
            AppLog.shared.log("devtools: ws \(w.prefix(70))")
            DispatchQueue.main.async {
                self.showDevToolsInTab(w, port: port)
            }
        }
    }

    /// 在当前页签内部展开 DevTools 子窗口（页签 = 主窗口 + DevTools）。
    private func showDevToolsInTab(_ ws: String, port: Int) {
        guard let tab = activeTab else { return }
        // ws 参数用「主机:端口/路径」（去掉 ws:// scheme）——Chromium 的
        // inspector.html 前端会自己拼 ws://；传完整 ws:// 会拼出
        // ws://ws://… 双重 scheme，WebSocket 无法连接。
        let wsPath = ws.replacingOccurrences(of: "ws://", with: "")
                        .replacingOccurrences(of: "wss://", with: "")
        guard let encoded = wsPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        let url = "http://127.0.0.1:\(port)/devtools/inspector.html?ws=\(encoded)"
        AppLog.shared.log("devtools: embedding in tab \(tab.id) \(url.prefix(70))")
        tab.container.showDevToolsArea()
        if tab.container.devtoolsBrowserId == 0 {
            // 展开布局后再创建 DevTools 浏览器（容器尺寸已定）
            tab.container.layoutSubtreeIfNeeded()
            tab.container.devtoolsBrowserId = CEFShim.createBrowser(
                in: tab.container.devtoolsContent, url: url, delegate: tab)
        } else {
            CEFShim.navigateBrowser(tab.container.devtoolsBrowserId, url: url)
        }
    }

    // MARK: 状态同步（tab 回调 → 面板 UI）

    func tabStateChanged(_ tab: BrowserCEFTab) {
        if ProcessInfo.processInfo.environment["DSH_UI_DEBUG"] == "1" || CommandLine.arguments.contains("--ui-debug") {
            let subs = tab.container.subviews.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" }
            print("browser tab\(tab.id) title=\(tab.title) containerSubviews=\(subs)")
        }
        // 联动：更新页签按钮标题（导航后标题变化）
        if let item = tabButtons[tab.id] {
            item.setTitle(displayTitle(tab))
        }
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

    /// 执行 JS 求值；completion 在主线程回调（后台执行 CDP 命令）。
    func evaluate(expression: String, completion: @escaping (Result<Any?, Error>) -> Void) {
        guard let tab = activeTab else {
            completion(.failure(NSError(domain: "Browser", code: 1, userInfo: [NSLocalizedDescriptionKey: "no active tab"])))
            return
        }
        DispatchQueue.global().async { [weak tab] in
            let result = tab?.cdp.evaluate(expression: expression) ?? .failure(NSError(domain: "Browser", code: 1, userInfo: [NSLocalizedDescriptionKey: "no active tab"]))
            DispatchQueue.main.async {
                switch result {
                case .success(let value): completion(.success(value))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    /// 截图（PNG Data；CDP 离屏渲染，面板隐藏也可截）。
    func screenshot(completion: @escaping (Data?) -> Void) {
        guard let tab = activeTab else {
            completion(nil)
            return
        }
        DispatchQueue.global().async { [weak tab] in
            let data = try? tab?.cdp.screenshot().get()
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// QA：返回活动标签页 CEF 视图的渲染状态（经 API debug 端点查看）。
    func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "panelInWindow": view.window != nil,
            "panelVisible": !view.isHidden,
            "devtoolsOpen": (activeTab?.container.devtoolsBrowserId ?? 0) > 0,
            "devtoolsAreaHidden": activeTab?.container.devtoolsArea.isHidden ?? true,
        ]
        if let tab = activeTab {
            state["containerInWindow"] = tab.container.window != nil
            state["osrLayerContents"] = tab.container.layer?.contents != nil
            state["osrLayerScale"] = tab.container.layer?.contentsScale ?? 0
            state["osrBounds"] = NSStringFromRect(tab.container.bounds)
            state["frameCount"] = tab.container.frameCount
            state["lastFrameSize"] = "\(tab.container.lastFrameSize.width)x\(tab.container.lastFrameSize.height)"
            state["avgAlpha"] = tab.container.lastAvgAlpha
            state["avgLum"] = tab.container.lastAvgLum
        }
        return state
    }

    /// QA：模拟一次点击（down+up，含 focus），验证 OSR 点击链路。
    func simulateClick(x: Float, y: Float) {
        guard let tab = activeTab else { return }
        DispatchQueue.main.async {
            tab.container.ensureFocus()
            CEFShim.sendMouseClick(tab.browserId, x: x, y: y, button: 0, count: 1, modifiers: 0)
            CEFShim.sendMouseClick(tab.browserId, x: x, y: y, button: 0, count: 2, modifiers: 0)
        }
    }

    /// 退出清理。
    func shutdownAll() {
        // 先统一标记 isClosing：CloseBrowser 同步 OnBeforeClose 会重入
        // closeTab（remove 中枚举 tabs），标记后重入直接返回。
        for tab in tabs { tab.isClosing = true }
        for tab in tabs {
            CEFShim.closeBrowser(tab.browserId)
            tab.cdp.disconnect()
            tab.container.removeFromSuperview()
        }
        tabs.removeAll()
        tabButtons.removeAll()
    }
}
