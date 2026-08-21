//
//  CodeEditorView.swift — Editable code/text editor with a line-number gutter
//  and optional syntax highlighting (vendored Highlightr) for the file panel.
//
//  Used by FilePanelController.showText() when a UTF-8 file fits under the
//  preview cap. Owns the dirty state and atomic write-back to disk.
//
//  Line numbers are rendered by a small read-only NSTextView placed left of the
//  code editor inside a dedicated vertical-only scroll; both scroll views are
//  locked in step so the numbers track the code vertically while the code scrolls
//  horizontally on its own. Both use the same monospaced font and text insets so
//  lines stay aligned (the code editor never wraps, so one logical line = one row).
//

import AppKit
import Foundation

/// Editable code/text view with a line-number gutter and optional syntax
/// highlighting. Embeds as an NSView (fills the panel's content area).
final class CodeEditorView: NSView, NSTextViewDelegate {

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Map a file extension to a highlight.js language name; nil = no highlighting.
    static func language(forExtension ext: String) -> String? {
        switch ext {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py", "pyw": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hxx": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "php": return "php"
        case "pl", "pm": return "perl"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "sql": return "sql"
        case "html", "htm": return "xml"
        case "css", "scss", "less": return "css"
        case "json", "jsonl": return "json"
        case "yaml", "yml": return "yaml"
        case "toml", "ini", "cfg", "conf": return "ini"
        case "xml", "svg": return "xml"
        case "md", "markdown", "mdown", "mkd": return "markdown"
        case "makefile": return "makefile"
        case "dockerfile": return "dockerfile"
        case "diff", "patch": return "diff"
        case "tex": return "tex"
        case "lua": return "lua"
        case "rbx": return "lua"
        case "r", "R": return "r"
        case "ps1", "psm1": return "powershell"
        case "gradle": return "gradle"
        case "vue": return "xml"
        case "jsonc": return "json"
        default: return nil
        }
    }

    // MARK: - Subviews

    private let codeScroll = NSScrollView()
    private let gutterScroll = NSScrollView()
    private let codeTextView = NSTextView()
    private let gutterTextView = NSTextView()

    // MARK: - State

    let path: String
    private let language: String?
    private var usesHighlighting = false
    private var suppressDirty = false
    private var lastGutterLineCount = -1
    private(set) var isDirty = false
    private var gutterWidthConstraint: NSLayoutConstraint!

    var onDirtyChange: ((Bool) -> Void)?
    var onSaveError: ((String) -> Void)?

    // MARK: - Init

    init(path: String, text: String, language: String?, dark: Bool) {
        self.path = path
        self.language = language
        super.init(frame: .zero)
        buildUI()
        loadContent(text: text, dark: dark)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private func buildUI() {
        // Code editor
        codeTextView.isRichText = false
        codeTextView.isEditable = true
        codeTextView.isSelectable = true
        codeTextView.allowsUndo = true
        codeTextView.isAutomaticQuoteSubstitutionEnabled = false
        codeTextView.isAutomaticDashSubstitutionEnabled = false
        codeTextView.isAutomaticSpellingCorrectionEnabled = false
        codeTextView.font = Self.codeFont
        codeTextView.textContainerInset = NSSize(width: 8, height: 8)
        codeTextView.drawsBackground = true
        codeTextView.backgroundColor = .textBackgroundColor
        codeTextView.textColor = .textColor
        codeTextView.isVerticallyResizable = true
        codeTextView.isHorizontallyResizable = true
        codeTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeTextView.textContainer?.widthTracksTextView = false
        codeTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeTextView.autoresizingMask = [.width]
        codeTextView.delegate = self

        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.hasHorizontalScroller = true
        codeScroll.autohidesScrollers = true
        codeScroll.drawsBackground = false

        // Line-number gutter
        gutterTextView.isEditable = false
        gutterTextView.isSelectable = false
        gutterTextView.isRichText = false
        gutterTextView.font = Self.codeFont
        gutterTextView.alignment = .right
        gutterTextView.textColor = .secondaryLabelColor
        gutterTextView.backgroundColor = .controlBackgroundColor
        gutterTextView.drawsBackground = true
        gutterTextView.textContainerInset = NSSize(width: 8, height: 8)
        gutterTextView.isVerticallyResizable = true
        gutterTextView.isHorizontallyResizable = false
        gutterTextView.textContainer?.widthTracksTextView = false
        gutterTextView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        gutterTextView.autoresizingMask = []

        gutterScroll.documentView = gutterTextView
        gutterScroll.hasVerticalScroller = false
        gutterScroll.hasHorizontalScroller = false
        gutterScroll.autohidesScrollers = true
        gutterScroll.scrollerStyle = .overlay
        gutterScroll.drawsBackground = false
        gutterScroll.verticalScrollElasticity = .none

        for v in [gutterScroll, codeScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        gutterWidthConstraint = gutterScroll.widthAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            gutterScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterScroll.topAnchor.constraint(equalTo: topAnchor),
            gutterScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidthConstraint,
            codeScroll.leadingAnchor.constraint(equalTo: gutterScroll.trailingAnchor),
            codeScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScroll.topAnchor.constraint(equalTo: topAnchor),
            codeScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Set the initial content and, when possible, attach a highlighting storage.
    private func loadContent(text: String, dark: Bool) {
        var storage: NSTextStorage?
        if let lang = language, Self.highlightingAvailable(),
           let cas = Self.makeHighlightingStorage(language: lang, dark: dark) {
            storage = cas
            usesHighlighting = true
        }
        if let storage = storage {
            // Re-point the existing text view onto the highlighting storage.
            // The text view was created with its own layout manager; replace it
            // via a fresh layout manager so the storage owns the layout.
            codeTextView.layoutManager?.textStorage = storage
        }

        suppressDirty = true
        codeTextView.string = text
        suppressDirty = false

        if let cas = storage as? CodeAttributedString {
            cas.language = language   // triggers a full highlight on a background thread
        }

        refreshGutterLineCount()
        // Sync the gutter to any initial vertical position (usually 0).
        gutterScroll.contentView.scroll(to: NSPoint(x: 0, y: codeScroll.contentView.bounds.origin.y))
    }

    /// True when all Highlightr assets are embedded in the main bundle root.
    private static func highlightingAvailable() -> Bool {
        for name in ["highlight.min.js", "pojoaque.min.css", "xcode.min.css", "atom-one-dark.min.css"] {
            if Bundle.main.url(forResource: name, withExtension: nil) == nil { return false }
        }
        return true
    }

    /// Build a CodeAttributedString wired to our themes/font. Uses the default
    /// Highlightr() (which requires highlight.min.js + pojoaque.min.css in the
    /// bundle root), then switches theme/font.
    private static func makeHighlightingStorage(language: String, dark: Bool) -> CodeAttributedString? {
        let cas = CodeAttributedString()          // default theme "pojoaque"
        cas.highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        cas.highlightr.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        return cas
    }

    // MARK: - Gutter

    private func refreshGutterLineCount() {
        let count = codeTextView.string.components(separatedBy: "\n").count
        guard count != lastGutterLineCount else { return }
        lastGutterLineCount = count
        gutterTextView.string = (1...count).map(String.init).joined(separator: "\n")
        let digits = String(count).count
        gutterWidthConstraint.constant = max(36, CGFloat(digits) * 8 + 22)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        refreshGutterLineCount()
        if !suppressDirty && !isDirty {
            isDirty = true
            onDirtyChange?(true)
        }
    }

    // MARK: - Scroll lock (gutter follows code vertically)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(self,
                selector: #selector(codeScrollChanged),
                name: NSView.boundsDidChangeNotification,
                object: codeScroll.contentView)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Follow light/dark by swapping the highlight.js theme (setTheme
        // triggers a re-highlight through the storage's themeChanged hook).
        if let cas = codeTextView.layoutManager?.textStorage as? CodeAttributedString {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            cas.highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func codeScrollChanged() {
        let origin = codeScroll.contentView.bounds.origin
        gutterScroll.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
    }

    // MARK: - Save

    /// Write the current buffer back to the file atomically. Returns false and
    /// reports via onSaveError on failure (dirty state is preserved).
    @discardableResult
    func writeBack() -> Bool {
        do {
            let data = Data(codeTextView.string.utf8)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if isDirty {
                isDirty = false
                onDirtyChange?(false)
            }
            return true
        } catch {
            onSaveError?(error.localizedDescription)
            return false
        }
    }
}
