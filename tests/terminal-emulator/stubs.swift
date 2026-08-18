import AppKit
import Foundation

enum L10n {
    static var isZh = false
    static func tr(_ key: String, _ args: CVarArg...) -> String { key }
}
final class AppLog {
    static let shared = AppLog()
    func log(_ msg: String) {}
}
class HoverButton: NSButton {
    var showsFeedback = true
}
enum DSHSessionRPC {
    static func fetchActiveSessionCwd(port: Int, timeout: TimeInterval = 6) -> String? { nil }
    static func resolveProjectDirectory(port: Int, timeout: TimeInterval = 6,
                                        completion: @escaping (String?) -> Void) { completion(nil) }
}

final class DynamicFillView: NSView {
    enum Kind { case window, control, custom(NSColor) }
    var kind: Kind = .window
    var fill: NSColor = .windowBackgroundColor
    override var isOpaque: Bool { true }
}

final class PanelIconButton: HoverButton {
    init(symbol: String, tooltip: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.toolTip = tooltip
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ActivityBarButton: HoverButton {
    init(symbol: String, tooltip: String, action: Selector) {
        super.init(frame: .zero)
        self.action = action
        self.toolTip = tooltip
    }
    required init?(coder: NSCoder) { fatalError() }
    func setActive(_ active: Bool) { state = active ? .on : .off }
}

final class BakedIconView: NSImageView {
    init(symbol: String) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

final class HeaderLabel: NSView {
    var text: String = ""
    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 14) }
}

final class CustomIconButton: NSView {
    enum Glyph { case plus, close, folder, openInApp, reveal, symbol(String), play, stop }
    var onAction: (() -> Void)?
    var isEnabled = true
    init(glyph: Glyph, tooltip: String) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

// Browser panel stubs（无头测试不实例化，仅满足编译/链接；与真实 CEFShim.h
// 接口同名，见 platforms/macos/cef/CEFShim.h）。
@objc protocol CEFBrowserDelegate: NSObjectProtocol {
    func cefTitleChanged(_ title: String, forBrowser id: Int64)
    func cefLoadingStateChanged(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool, forBrowser id: Int64)
    func cefLoadError(_ errorText: String, failedURL: String, forBrowser id: Int64)
    func cefBrowserClosed(_ id: Int64)
}

@objc class CEFShim: NSObject {
    @objc class var isInitialized: Bool { false }
    @objc class func initialize(withCachePath: String, remoteDebuggingPort: Int32, logPath: String) throws {}
    @objc class func runMessageLoopWork() {}
    @objc class func createBrowser(in view: NSView, url: String?, delegate: CEFBrowserDelegate) -> Int64 { 0 }
    @objc class func closeBrowser(_ id: Int64) {}
    @objc class func navigateBrowser(_ id: Int64, url: String) {}
    @objc class func goBack(_ id: Int64) {}
    @objc class func goForward(_ id: Int64) {}
    @objc class func reload(_ id: Int64) {}
    @objc class func stop(_ id: Int64) {}
    @objc class func shutdown() {}
}
