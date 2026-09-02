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
    var showsBackground = false
    var hoverColor: NSColor?
    var size: CGFloat = 26
    init(glyph: Glyph, tooltip: String, size: CGFloat = 26) {
        self.size = size
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    required init?(coder: NSCoder) { fatalError() }
}

// Scaffold 面板编辑器用到的 CodeEditorView 桩（无头测试不渲染，仅满足编译/链接；
// 真实实现见 platforms/macos/src/CodeEditorView.swift，由 FilePanel 共用）。
final class LineNumberGutterView: NSView {
    weak var codeTextView: NSTextView?
}
final class CodeEditorView: NSView {
    static func language(forExtension ext: String) -> String? { nil }
    let path: String
    var onDirtyChange: ((Bool) -> Void)?
    var onSaveError: ((String) -> Void)?
    private(set) var isDirty = false
    var text = ""
    init(path: String, text: String, language: String?, dark: Bool) {
        self.path = path
        self.text = text
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult
    func writeBack() -> Bool { isDirty = false; return true }
    func markClean() { isDirty = false }
    func reloadFromDisk() {}
}

// Browser panel stubs（无头测试不实例化，仅满足编译/链接；与真实 CEFShim.h
// 接口同名，见 platforms/macos/cef/CEFShim.h）。
@objc protocol CEFBrowserDelegate: NSObjectProtocol {
    func cefTitleChanged(_ title: String, forBrowser id: Int64)
    func cefLoadingStateChanged(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool, forBrowser id: Int64)
    func cefLoadError(_ errorText: String, failedURL: String, forBrowser id: Int64)
    func cefBrowserClosed(_ id: Int64)
}

/// 全局标记（main.swift 定义；测试环境提供默认值）
var g_cefClosingWindow = false

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
    @objc class func resizeBrowser(_ id: Int64, width: Float, height: Float) {}
    @objc class func setMenuRequestHandler(_ handler: ((Int64, Float, Float, [[AnyHashable: Any]]) -> Void)?) {}
    @objc class func setCursorHandler(_ handler: ((Int64, UnsafeMutableRawPointer) -> Void)?) {}
    @objc class func setPaintHandler(_ handler: ((Int64, UnsafeRawPointer, Int32, Int32) -> Void)?) {}
    @objc class func sendMouseClick(_ id: Int64, x: Float, y: Float, button: Int32, count: Int32, modifiers: Int32) {}
    @objc class func sendMouseMove(_ id: Int64, x: Float, y: Float, modifiers: Int32) {}
    @objc class func sendMouseWheel(_ id: Int64, x: Float, y: Float, deltaX: Float, deltaY: Float, modifiers: Int32) {}
    @objc class func sendKeyEvent(_ id: Int64, keyCode: UInt16, charCode: UInt16, keyDown: Bool, modifiers: Int32) {}
    @objc class func setFocus(_ id: Int64, focused: Bool) {}
    @objc class func setWindowedMode(_ on: Bool) {}
    @objc class func isWindowedMode() -> Bool { false }
    @objc class func executeContextMenuCommand(_ id: Int64, commandId: Int32) {}
    @objc class func cancelContextMenu(_ id: Int64) {}
    @objc class func showDevTools(_ id: Int64) {}
    @objc class func shutdown() {}
}
