//
//  CodeEditorView.swift — Editable code/text editor with a line-number gutter
//  and optional syntax highlighting (vendored Highlightr) for the file panel.
//
//  Used by FilePanelController.showText() when a UTF-8 file fits under the
//  preview cap. Owns the dirty state and atomic write-back to disk.
//
//  The line-number gutter is a fixed-width, custom-drawn view to the LEFT of a
//  single code NSScrollView. It derives the visible lines directly from the code
//  text view's live layout (visibleRect + layoutManager), so numbers always stay
//  aligned with the code regardless of scrolling — there is no second scroll view
//  to desync.
//

import AppKit
import Foundation

/// Line-number gutter drawn from the code text view's live layout. Flipped so its
/// y-origin is top-left (matching NSTextView). Rendered with Core Graphics text
/// (the same reliable pipeline the panel headers use).
final class LineNumberGutterView: NSView {
    override var isFlipped: Bool { true }

    weak var codeTextView: NSTextView?
    var gutterFont: NSFont = CodeEditorView.codeFont
    var numberColor: NSColor = .secondaryLabelColor
    var fillColor: NSColor = .controlBackgroundColor

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        dirtyRect.fill()

        guard let tv = codeTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visible = tv.visibleRect
        guard visible.height > 0 else { return }

        // glyphIndex(for:in:) uses the text CONTAINER coordinate system, which
        // is offset from the view by textContainerInset; convert before querying.
        let pointY = visible.minY - tv.textContainerInset.height
        var glyphIndex = lm.glyphIndex(for: NSPoint(x: 0, y: pointY), in: tc)
        guard glyphIndex < lm.numberOfGlyphs else { return }

        let attrs: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: numberColor]
        let rightX = bounds.width - 6
        let totalLines = Self.lineCount(of: tv.string)
        var line = Self.lineNumber(ofCharacter: lm.characterIndexForGlyph(at: glyphIndex), in: tv.string)
        var lastBottom: CGFloat = 0
        var lastHeight: CGFloat = 0

        // Walk the layout manager line fragment by line fragment, drawing each
        // number at that line's EXACT y (no drift with mixed-height lines) and
        // never skipping a line because an empty fragment has no glyph.
        let gutterHeight = bounds.height
        let glyphRange = NSRange(location: glyphIndex, length: lm.numberOfGlyphs - glyphIndex)
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, _, _, stop in
            if line > totalLines { stop.pointee = true; return }
            let fragTop = rect.minY + tv.textContainerInset.height - visible.minY
            if fragTop > gutterHeight { stop.pointee = true; return }
            // Center the number on the line's USED (glyph) vertical center, so a
            // line made taller by an emoji still aligns with its actual text.
            let usedCenter = usedRect.midY + tv.textContainerInset.height - visible.minY
            LineNumberGutterView.drawNumberCentered(line: line, centerY: usedCenter, rightX: rightX, attrs: attrs)
            lastBottom = rect.minY + rect.height
            lastHeight = rect.height
            line += 1
        }

        // A trailing empty line (file ends with a newline) may not be emitted as a
        // line fragment; draw its number too so the very last line is never missing.
        if line <= totalLines {
            let gutterY = lastBottom + tv.textContainerInset.height - visible.minY
            if gutterY <= gutterHeight {
                Self.drawNumber(line: line, at: gutterY, height: lastHeight, rightX: rightX, attrs: attrs)
            }
        }
    }

    /// Draw one line number right-aligned, vertically centered on the given point.
    private static func drawNumberCentered(line: Int, centerY: CGFloat, rightX: CGFloat,
                                           attrs: [NSAttributedString.Key: Any]) {
        let label = "\(line)" as NSString
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: rightX - size.width, y: centerY - size.height / 2),
                   withAttributes: attrs)
    }

    /// Draw one line number right-aligned at the given y (centered in its line height).
    private static func drawNumber(line: Int, at y: CGFloat, height: CGFloat, rightX: CGFloat,
                                   attrs: [NSAttributedString.Key: Any]) {
        let label = "\(line)" as NSString
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: rightX - size.width, y: y + (height - size.height) / 2),
                   withAttributes: attrs)
    }

    /// Number of lines in the string (a trailing newline counts an empty last line).
    private static func lineCount(of string: String) -> Int {
        var count = 1
        for ch in string.unicodeScalars where ch == "\n" { count += 1 }
        return count
    }

    /// 1-based line number of the character at the given index (1 if before any newline).
    private static func lineNumber(ofCharacter index: Int, in string: String) -> Int {
        let ns = string as NSString
        let end = min(max(index, 0), ns.length)
        var line = 1
        for i in 0..<end where ns.character(at: i) == 10 { line += 1 }
        return line
    }
}

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
    private let gutterView = LineNumberGutterView()
    private var codeTextView: NSTextView!

    // MARK: - State

    let path: String
    private let language: String?
    private let dark: Bool
    private var usesHighlighting = false
    private var suppressDirty = false
    /// Bumped per reload request so a slow background read cannot overwrite a
    /// newer one.
    private var reloadGeneration = 0
    /// Bumped per chunked highlight pass so an older pass stops at the next chunk.
    private var highlightGeneration = 0
    private(set) var isDirty = false
    private var gutterWidthConstraint: NSLayoutConstraint!

    var onDirtyChange: ((Bool) -> Void)?
    var onSaveError: ((String) -> Void)?

    // MARK: - Init

    init(path: String, text: String, language: String?, dark: Bool) {
        self.path = path
        self.language = language
        self.dark = dark
        super.init(frame: .zero)
        setup(text: text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Construction

    private func setup(text: String) {
        // Build the code editor around the highlighting storage when available.
        var storage: NSTextStorage?
        // Large files stay plain text: highlighting them costs seconds of JS plus
        // a full-document attribute pass, which is what froze the panel when such
        // a file was reloaded (see EditorLoadPolicy).
        let highlightingWorthIt = EditorLoadPolicy.shouldHighlight(text: text, language: language)
        if let lang = language, Self.highlightingAvailable(), highlightingWorthIt,
           let cas = Self.makeHighlightingStorage(language: lang, dark: dark) {
            storage = cas
            usesHighlighting = true
        } else if let lang = language, !highlightingWorthIt {
            let lines = EditorLoadPolicy.lineCount(of: text)
            AppLog.shared.log("preview: \(lines) line(s) — syntax highlighting skipped for \(lang)")
        }
        codeTextView = makeCodeTextView(storage: storage)

        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.hasHorizontalScroller = true
        codeScroll.autohidesScrollers = true
        codeScroll.drawsBackground = false
        codeScroll.verticalScrollElasticity = .automatic

        gutterView.codeTextView = codeTextView
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        codeScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutterView)
        addSubview(codeScroll)
        gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidthConstraint,
            codeScroll.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            codeScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScroll.topAnchor.constraint(equalTo: topAnchor),
            codeScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Load content.
        suppressDirty = true
        codeTextView.string = text
        suppressDirty = false
        if let cas = storage as? CodeAttributedString {
            let highlight = EditorLoadPolicy.shouldHighlight(text: text, language: language)
            cas.setLanguage(highlight ? language : nil, automaticallyHighlighting: false)
            if highlight {
                highlightInChunks()     // progressive: the UI stays responsive
            } else if let lang = language {
                AppLog.shared.log("preview: \(EditorLoadPolicy.lineCount(of: text)) line(s) — "
                                  + "above the highlighting safety valve, shown plain (\(lang))")
            }
            cas.suppressesAutomaticHighlight = false   // later edits highlight normally
        }
        updateGutterWidthAndRedraw()
    }

    /// A horizontally-scrolling, vertically-growing editable code text view,
    /// optionally backed by a custom (highlighting) text storage.
    private func makeCodeTextView(storage: NSTextStorage?) -> NSTextView {
        let tv: NSTextView
        if let storage = storage {
            let lm = NSLayoutManager()
            storage.addLayoutManager(lm)
            let tc = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude))
            lm.addTextContainer(tc)
            tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), textContainer: tc)
        } else {
            tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        }
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = Self.codeFont
        tv.textColor = .textColor
        tv.drawsBackground = true
        tv.backgroundColor = PanelSurface.dynamic
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 4
        tv.delegate = self
        return tv
    }

    /// True when all Highlightr assets are embedded in the main bundle root.
    private static func highlightingAvailable() -> Bool {
        let required: [(String, String)] = [
            ("highlight.min", "js"), ("pojoaque.min", "css"),
            ("xcode.min", "css"), ("atom-one-dark.min", "css"),
        ]
        for (name, ext) in required where Bundle.main.path(forResource: name, ofType: ext) == nil {
            return false
        }
        return true
    }

    /// Build a CodeAttributedString wired to our themes/font. We construct
    /// Highlightr() EXPLICITLY and bail out (return nil -> plain editor) if it
    /// fails, because CodeAttributedString() force-unwraps Highlightr()! and
    /// would crash the app if the JS runtime can't be initialized.
    private static func makeHighlightingStorage(language: String, dark: Bool) -> CodeAttributedString? {
        guard let highlightr = Highlightr() else {
            AppLog.shared.log("highlightr init failed — syntax highlighting disabled for \(language)")
            return nil
        }
        let cas = CodeAttributedString(highlightr: highlightr)
        cas.highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        cas.highlightr.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        return cas
    }

    // MARK: - Gutter sizing / redraw

    private func updateGutterWidthAndRedraw() {
        let count = codeTextView.string.components(separatedBy: "\n").count
        let digits = String(count).count
        gutterWidthConstraint.constant = max(36, CGFloat(digits) * 8 + 22)
        gutterView.needsDisplay = true
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateGutterWidthAndRedraw()
        if !suppressDirty && !isDirty {
            isDirty = true
            onDirtyChange?(true)
        }
    }

    // MARK: - Scroll/layout: redraw the gutter whenever the code scrolls or
    // (re)lays out. Laying out again is essential: on the very first open the
    // view isn't laid out yet (visibleRect is zero/stale), so the gutter would
    // draw wrong numbers until a scroll/edit/re-select redraws it.

    override func layout() {
        super.layout()
        updateGutterWidthAndRedraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            codeScroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                selector: #selector(codeScrollChanged),
                name: NSView.boundsDidChangeNotification,
                object: codeScroll.contentView)
            updateGutterWidthAndRedraw()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Follow light/dark by swapping the highlight.js theme. The storage's
        // themeChanged hook would re-colour EVERYTHING in one pass, so it is
        // suppressed here and the colours are re-applied in chunks instead.
        if let cas = codeTextView.textStorage as? CodeAttributedString {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let suppressed = cas.suppressesAutomaticHighlight
            cas.suppressesAutomaticHighlight = true
            cas.highlightr.setTheme(to: isDark ? "atom-one-dark" : "xcode")
            cas.suppressesAutomaticHighlight = suppressed
            if !suppressed { highlightInChunks() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func codeScrollChanged() {
        // The gutter has no scroll view of its own; it just needs a redraw so it
        // can recompute which lines are visible from the code's live layout.
        gutterView.needsDisplay = true
    }

    // MARK: - Reload

    /// Reload the buffer from disk, replacing the current content. The caller
    /// guarantees the tab has no unsaved edits (otherwise the in-memory edits
    /// would be silently discarded). Scroll position is preserved when the new
    /// content is still tall enough to reach it, otherwise it clamps to top.
    /// Keeps the buffer non-dirty: the replace happens with dirty-tracking
    /// suppressed, matching the initial load.
    func reloadFromDisk() {
        reloadFromDisk(completion: nil)
    }

    /// Read the file on a background queue and apply it on the main thread — the
    /// read must never block the UI, and only the LAST request wins (a file that
    /// was rewritten twice while the first read was in flight must not push stale
    /// content into the editor).
    func reloadFromDisk(completion: (() -> Void)? = nil) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = (try? Data(contentsOf: url, options: .mappedIfSafe))
                .flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                guard let self = self, generation == self.reloadGeneration else { return }
                guard let text = text else { completion?(); return }
                if text != self.codeTextView.string { self.applyReload(text) }
                completion?()
            }
        }
    }

    /// Replace the buffer in one text-storage edit with highlighting suspended,
    /// then re-highlight ONCE. Letting the replacement highlight on its own would
    /// highlight the whole document, and re-assigning `language` right after would
    /// do it a second time — the pair is what made a big-file reload freeze.
    private func applyReload(_ newText: String) {
        let offset = codeScroll.contentView.bounds.origin
        let storage = codeTextView.textStorage as? CodeAttributedString
        let highlight = EditorLoadPolicy.shouldHighlight(text: newText, language: language)
        // Swap the buffer with BOTH automatic highlight paths suppressed: neither
        // the replacement itself nor a language assignment may start a pass (that
        // pair used to run the whole document twice).
        storage?.setLanguage(highlight ? language : nil, automaticallyHighlighting: false)
        suppressDirty = true
        codeTextView.textStorage?.beginEditing()
        codeTextView.string = newText
        codeTextView.textStorage?.endEditing()
        suppressDirty = false
        updateGutterWidthAndRedraw()
        if let doc = codeScroll.documentView, doc.frame.height > offset.y {
            codeScroll.contentView.scroll(to: offset)
            codeScroll.reflectScrolledClipView(codeScroll.contentView)
        } else {
            codeScroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            codeScroll.reflectScrolledClipView(codeScroll.contentView)
        }
        if highlight { highlightInChunks() }
        storage?.suppressesAutomaticHighlight = false   // later edits highlight normally
    }

    // MARK: - Highlighting

    /// Colour the buffer in whole-line chunks, yielding to the run loop between
    /// them. One pass over the whole document would block the main thread for as
    /// long as it takes (that was the freeze); chunked, the file shows its colours
    /// from the top down while the UI keeps responding.
    private func highlightInChunks() {
        guard let storage = codeTextView.textStorage as? CodeAttributedString,
              storage.language != nil else { return }
        highlightGeneration += 1
        let generation = highlightGeneration
        var location = 0
        func highlightNextChunk() {
            // A newer reload (or a theme change) invalidates this pass.
            guard generation == self.highlightGeneration else { return }
            let length = storage.length
            guard location < length else { return }
            let chunk = EditorLoadPolicy.highlightChunk(in: storage.string as NSString, from: location)
            guard chunk.length > 0 else { return }
            storage.highlight(chunk)
            location = chunk.location + chunk.length
            DispatchQueue.main.async { highlightNextChunk() }
        }
        highlightNextChunk()
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
