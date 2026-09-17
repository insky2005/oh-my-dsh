//
//  stubs-min.swift — headless-test stubs WITHOUT the panel UI classes.
//
//  tests/terminal-emulator/stubs.swift also stubs HoverButton / DynamicFillView /
//  HeaderLabel / CustomIconButton / ActivityBarButton; this variant omits them so
//  the REAL implementations from platforms/macos/src/PreviewPanel.swift can be
//  compiled into the same binary (see tests/skills-panel/render-tests.swift,
//  which pins an AppKit painting trap in DynamicFillView).
//

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
/// Shell settings facade ($DSH_HOME/shell/config.json). Real implementation:
/// platforms/macos/src/ShellConfig.swift; headless panel tests use this stub.
final class ShellConfig {
    static let shared = ShellConfig()
    private var store: [String: Any] = [:]
    var filePath: String { "" }
    func object(forKey key: String) -> Any? { store[key] }
    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
    func double(forKey key: String) -> Double { (store[key] as? NSNumber)?.doubleValue ?? 0 }
    func array(forKey key: String) -> [Any]? { store[key] as? [Any] }
    func data(forKey key: String) -> Data? {
        guard let v = store[key] else { return nil }
        return try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])
    }
    func set(_ value: Any, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    func flushNow() {}
}
enum DSHSessionRPC {
    static func fetchActiveSessionCwd(port: Int, timeout: TimeInterval = 6) -> String? { nil }
    static func resolveProjectDirectory(port: Int, timeout: TimeInterval = 6,
                                        completion: @escaping (String?) -> Void) { completion(nil) }
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
    // 测试可观察面：真实 shim 把回调存在 C++ 侧，测试里存下来供手动触发；
    // browserId 计数器与真实实现同款（全局递增，DevTools 子浏览器也吃号），
    // 用来钉住「按 browserId 而不是 tab.id 派发帧」这条约定。
    static var lastPaintHandler: ((Int64, UnsafeRawPointer, Int32, Int32) -> Void)?
    static var lastMenuHandler: ((Int64, Float, Float, [[AnyHashable: Any]]) -> Void)?
    static var lastCursorHandler: ((Int64, UnsafeMutableRawPointer) -> Void)?
    private static var nextBrowserId: Int64 = 1
    static func resetBrowserIdCounter() { nextBrowserId = 1 }

    @objc class var isInitialized: Bool { false }
    @objc class func initialize(withCachePath: String, remoteDebuggingPort: Int32, logPath: String) throws {}
    @objc class func runMessageLoopWork() {}
    @objc class func createBrowser(in view: NSView, url: String?, delegate: CEFBrowserDelegate) -> Int64 {
        let id = nextBrowserId
        nextBrowserId += 1
        return id
    }
    @objc class func closeBrowser(_ id: Int64) {}
    @objc class func navigateBrowser(_ id: Int64, url: String) {}
    @objc class func goBack(_ id: Int64) {}
    @objc class func goForward(_ id: Int64) {}
    @objc class func reload(_ id: Int64) {}
    @objc class func stop(_ id: Int64) {}
    @objc class func resizeBrowser(_ id: Int64, width: Float, height: Float) {}
    @objc class func setMenuRequestHandler(_ handler: ((Int64, Float, Float, [[AnyHashable: Any]]) -> Void)?) { lastMenuHandler = handler }
    @objc class func setCursorHandler(_ handler: ((Int64, UnsafeMutableRawPointer) -> Void)?) { lastCursorHandler = handler }
    @objc class func setPaintHandler(_ handler: ((Int64, UnsafeRawPointer, Int32, Int32) -> Void)?) { lastPaintHandler = handler }
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
