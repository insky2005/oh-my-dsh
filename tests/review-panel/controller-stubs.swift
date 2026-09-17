import AppKit

// Minimal stand-ins for the shell types ReviewPanel.swift leans on, so the
// controller can be driven headlessly (the same recipe the other panel tests
// use). Only what the panel actually touches is defined here.

enum L10n {
    /// Returns the key itself: assertions then read like the label semantics
    /// ("1 review.filesShort · +2 −1") instead of localized prose.
    static func tr(_ key: String, _ args: CVarArg...) -> String { key }
}

final class AppLog {
    static let shared = AppLog()
    func log(_ msg: String) {}
}

/// Fake core CLI. The test installs a handler that answers `review sessions` /
/// `review audit` from a temp fixture, and every call is recorded so
/// "did the panel go back to the log?" is directly observable.
enum CoreBridge {
    private static let lock = NSLock()
    private static var _handler: (([String]) -> String?)?
    private static var _calls: [[String]] = []

    static var handler: (([String]) -> String?)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _calls = []
    }

    static func run(_ args: [String], timeout: TimeInterval = 15, preferBundledNode: Bool = false) -> String? {
        let handler: (([String]) -> String?)?
        lock.lock()
        _calls.append(args)
        handler = _handler
        lock.unlock()
        return handler?(args)
    }

    /// How many times the panel asked for a given review subcommand.
    static func count(_ subcommand: String) -> Int {
        calls.filter { $0.count > 1 && $0[0] == "review" && $0[1] == subcommand }.count
    }
}

/// Title reads are a dsh web RPC; the panel must survive a silent web.
enum DshWebRPC {
    static let sessionList = "session.list"
    static func call(_ method: String, _ params: [String: Any], port: Int,
                     timeout: TimeInterval = 6) -> [String: Any]? { nil }
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
    enum Glyph { case plus, close, folder, openInApp, reveal, symbol(String), play, stop }
    var onAction: (() -> Void)?
    init(glyph: Glyph, tooltip: String, size: CGFloat = 26) {
        super.init(frame: .zero)
        toolTip = tooltip
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

class RoundedBlockView: NSView {
    var lightFill: NSColor = .white
    var darkFill: NSColor = .black
    var lightBorder: NSColor = .clear
    var darkBorder: NSColor = .clear
    var radius: CGFloat = 8
}
