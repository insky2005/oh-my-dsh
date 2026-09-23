import AppKit

// Minimal stand-ins for the shell types the Projects panel leans on, so the real
// ProjectsPanelController can be driven headlessly. Everything the panel *must*
// get right (root resolution, name rules, listing, registry merge, RPC) is the
// real code: ProjectsCore.swift, DshWebRPC.swift and ShellConfig.swift are all
// compiled into this test binary — only the chrome and the shell globals are faked.

enum L10n {
    /// Returns the key itself: assertions then read like the label semantics
    /// ("projects.unregistered") instead of localized prose.
    static func tr(_ key: String, _ args: CVarArg...) -> String { key }
}

final class AppLog {
    static let shared = AppLog()
    func log(_ msg: String) {}
}

/// ShellConfig delegates persistence to the core CLI; with no core here it falls
/// back to writing the JSON file directly, which is exactly what the test wants.
enum CoreBridge {
    static func run(_ args: [String], timeout: TimeInterval = 15, preferBundledNode: Bool = false) -> String? { nil }
}

// MARK: - View stand-ins (the panel's chrome only)

final class DynamicFillView: NSView {
    enum Kind { case panel, custom(NSColor) }
    var kind: Kind = .panel
}

final class HeaderLabel: NSView {
    var text: String = ""
    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
}

final class CustomIconButton: NSView {
    enum Glyph { case plus, close, folder, openInApp, reveal, symbol(String), play, stop, folderPlus }
    var onAction: (() -> Void)?
    var isEnabled = true
    init(glyph: Glyph, tooltip: String, size: CGFloat = 26) {
        super.init(frame: .zero)
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
