import AppKit

// View stand-ins for the headless tests of the task VIEWS. The views themselves
// (TaskCardView.swift / TaskInlineForms.swift), the view models (TasksUI.swift,
// TasksCore.swift) and the shared color tokens (PanelSurface.swift) are all REAL
// code here — only the chrome widgets they draw with are faked, so layout and
// interaction can be asserted without a window.
//
// L10n here returns the LAST key component ("tasks.card.edit" -> "edit"), so the
// labels a view test measures are short like the real ones instead of full keys.
// (The model tests keep the key-echoing stub from stubs.swift, which is why this
// stage compiles stubs-ui.swift only.)

enum L10n {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let leaf = key.split(separator: ".").last.map(String.init) ?? key
        guard !args.isEmpty else { return leaf }
        return leaf + "(" + args.map { "\($0)" }.joined(separator: ",") + ")"
    }
}

final class DynamicFillView: NSView {
    enum Kind { case panel, custom(NSColor) }
    var kind: Kind = .panel
}

final class HeaderLabel: NSView {
    var text: String = ""
    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 12) }
}

class HoverButton: NSButton {
    var showsFeedback = true
}

final class CustomIconButton: NSView {
    enum Glyph { case plus, close, folder, openInApp, reveal, symbol(String), play, stop, folderPlus }
    var onAction: (() -> Void)?
    var isEnabled = true
    var hoverColor: NSColor?
    let glyph: Glyph

    init(glyph: Glyph, tooltip: String, size: CGFloat = 26) {
        self.glyph = glyph
        super.init(frame: .zero)
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width, height: frame.height)
    }
}
