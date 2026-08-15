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
    enum Glyph { case plus, close, folder, openInApp, reveal }
    var onAction: (() -> Void)?
    var isEnabled = true
    init(glyph: Glyph, tooltip: String) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}
