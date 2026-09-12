//
//  FilePanel.swift — Right-side file/folder preview + editor panel (fork of PreviewPanel).
//
//  Mounted as the right pane of the main NSSplitView. Opening a path creates
//  (or activates) a tab; the content area renders directories (list), text /
//  markdown, images, PDFs, or a metadata fallback. The panel width is
//  controlled by the split view divider (see AppDelegate).
//
//  Localization strings live in AppDelegate's L10n table (see main.swift).
//

import AppKit
import PDFKit
import UniformTypeIdentifiers

/// One node of the project directory tree shown on the left of the preview
/// panel. Children are loaded lazily (`children == nil` means not loaded).
private final class TreeNode {
    let name: String
    let path: String
    let isDir: Bool
    var children: [TreeNode]?

    init(name: String, path: String, isDir: Bool) {
        self.name = name
        self.path = path
        self.isDir = isDir
    }
}


final class FilePanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                     NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSSplitViewDelegate {

    /// Root view mounted directly as the right pane of the main split view.
    /// Opaque, clearly-gray background (DynamicFillView) so the whole top
    /// block reads as one strip; also re-lays its internal tree on resize.
    let view = DynamicFillView()
    /// Invoked when the user hits the panel's "Close" button.
    var onRequestHide: (() -> Void)?

    /// Supplies the dsh web server port (used to query the active session's
    /// working directory via the host RPC when opening the project folder).
    var serverPortProvider: (() -> Int)?

    /// Called whenever the set of open tabs changes (open/close/clear), so the
    /// host can enable/disable the Cmd+W close-tab menu item.
    var onTabsChanged: (() -> Void)?

    /// Whether any preview tab is currently open.
    var hasOpenTabs: Bool { !tabs.isEmpty }

    // MARK: - Headless test surface (tests/file-panel/run.sh)

    /// The open tabs' paths, in tab-bar order. The panel's tab state has no
    /// other reader, and the workspace hand-off is only observable through it.
    var openTabPaths: [String] { tabs.map { $0.path } }

    /// The selected tab's path, if any.
    var selectedTabPath: String? { currentTabPath }

    /// The directory the panel currently follows (its tree root), if any.
    var projectRootPath: String? { treeRoot?.path }

    /// The header's title (a fixed panel name, never a file path).
    var headerTitle: String { titleLabel.text }

    /// The hover tooltip of the header title (the active tab's full path).
    var headerTooltip: String? { titleLabel.toolTip }

    /// Run the header Close button's action (close every tab + clear the
    /// per-workspace tab memory), exactly as clicking it does.
    func performCloseAction() { hidePanel(nil) }

    // MARK: - Subviews

    /// 头部固定标题（「文件 / Files」，与活动栏同名）：**不跟随当前文件的路径**。
    /// 路径没有丢——页签 tooltip 与这里的悬停 tooltip 都带完整路径。
    private let titleLabel = HeaderLabel()
    private var projectButton: CustomIconButton!
    private var openButton: CustomIconButton!
    private var revealButton: CustomIconButton!
    private var hideButton: CustomIconButton!
    private var saveButton: CustomIconButton!
    private let tabScroll = NSScrollView()
    private let tabStack = NSStackView()
    private let contentContainer = NSView()
    /// Left pane of the content area: the project directory tree.
    private let treeScroll = NSScrollView()
    private let treeOutline = NSOutlineView()
    /// Content area split view (tree | preview).
    private var contentSplit: NSSplitView!

    // MARK: - State

    private struct Tab {
        let id: Int
        var path: String
        let titleButton: NSButton
        let closeButton: NSButton
        let container: NSView
        /// Whether this tab currently shows an editable text/code buffer.
        var isEditable: Bool = false
        /// Whether the buffer has unsaved changes (drives the save button).
        var isDirty: Bool = false
        /// The active editor view when the tab is an editable text file.
        var editor: CodeEditorView?
        /// File mtime captured the last time this tab's content was loaded from
        /// disk (used to detect on-disk changes and refresh open tabs).
        var fileMtime: Date?
    }

    private struct DirRow {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int64
        let modified: Date?
    }

    private var tabs: [Tab] = []
    private var selectedId: Int?
    private var nextId = 1
    private var dirRows: [DirRow] = []

    /// Per-workspace memory of the open preview tabs (see setTreeRoot): a
    /// workspace switch closes every tab — releasing its editor / highlighting /
    /// preview content — after remembering what was open, and reopens that set
    /// when the user switches back. Cleared wholesale by the Close button.
    private var tabMemory = WorkspaceTabMemory()
    /// The unsaved-changes sheet the panel is currently asking in (a workspace
    /// switch or a close), if any. A newer switch request dismisses it (newest
    /// wins) instead of being ignored — ignoring used to leave the panel
    /// permanently stuck on a workspace it no longer followed.
    private var pendingPromptAlert: NSAlert?
    /// Bumped for every switch request so a superseded prompt's completion is
    /// recognised and never applied.
    private var switchRequestGeneration = 0

    /// Directory tree state (root of the current project folder).
    private var treeRoot: TreeNode?
    private var treeTriedLoad = false
    /// Whether the tree pane's default width has been applied.
    private var treeWidthInitialized = false
    /// Auto-refresh: polls mtime of the tree root and every expanded directory,
    /// reloading the tree when the filesystem changes (new files written by the
    /// agent show up without reopening the panel).
    private var treeWatchTimer: Timer?
    private var watchedMtimes: [String: Date] = [:]
    private let treeWatchInterval: TimeInterval = 2.0

    deinit {
        treeWatchTimer?.invalidate()
    }

    /// Preview cap for text content (bytes).
    private let textCap = 2 * 1024 * 1024
    /// Smallest allowed panel width (matches AppDelegate's divider constraint).
    static let minWidth: CGFloat = 260

    /// Extensions treated as plain text even when the system has no UTType text conformance.
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "json", "jsonl", "xml", "yml", "yaml",
        "toml", "ini", "conf", "cfg", "env", "properties", "gitignore", "dockerfile",
        "sh", "bash", "zsh", "fish", "py", "rb", "pl", "php", "js", "mjs", "cjs",
        "ts", "jsx", "tsx", "swift", "c", "h", "m", "mm", "cpp", "cc", "hpp", "java",
        "go", "rs", "sql", "html", "htm", "css", "scss", "less", "makefile", "md",
    ]

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Init / UI

    override init() {
        super.init()
        buildUI()
        showEmptyState()
    }

    /// A borderless SF Symbol icon button with a hover tooltip, hover
    /// highlight and pointing-hand cursor. Delegates to the shared
    /// PanelIconButton (explicit appearance-aware tint) — the SAME
    /// implementation the terminal panel uses, so both panels stay identical.
    private func buildUI() {
        // The panel itself stays transparent (shows the window's dynamic
        // background); only the top bar gets an explicit dynamic fill so the
        // header/tab strip reads as one consistent block in both appearances.

        // --- header: path label (left) + icon action buttons (right) ---
        // All header content is custom-drawn (HeaderLabel / CustomIconButton):
        // NSTextField/NSButton cells were observed not rendering in some
        // environments, while Core Graphics text and bezier paths render.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.text = Self.panelTitle

        // Icon buttons with tooltips (hover shows what each does).
        projectButton = CustomIconButton(glyph: .folder, tooltip: L10n.tr("preview.openProjectHint"))
        projectButton.onAction = { [weak self] in self?.openProjectDirectory(nil) }
        let openButton = CustomIconButton(glyph: .openInApp, tooltip: L10n.tr("preview.openInDefaultAppHint"))
        openButton.onAction = { [weak self] in self?.openInDefaultApp(nil) }
        let revealButton = CustomIconButton(glyph: .reveal, tooltip: L10n.tr("preview.revealInFinderHint"))
        revealButton.onAction = { [weak self] in self?.revealInFinder(nil) }
        let hideButton = CustomIconButton(glyph: .close, tooltip: L10n.tr("preview.closePanel"))
        hideButton.onAction = { [weak self] in self?.hidePanel(nil) }
        let saveButton = CustomIconButton(glyph: .symbol("externaldrive"), tooltip: L10n.tr("preview.saveHint"))
        saveButton.onAction = { [weak self] in self?.saveActiveTab() }
        saveButton.isEnabled = false
        self.openButton = openButton
        self.revealButton = revealButton
        self.hideButton = hideButton
        self.saveButton = saveButton

        let actions = NSStackView(views: [projectButton, openButton, revealButton, saveButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        // Header strip: explicit dynamic background so the top bar is a
        // defined block (consistent with the terminal panel) in both modes.
        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // --- tab bar (horizontally scrollable) ---
        tabStack.orientation = .horizontal
        tabStack.spacing = 6
        tabStack.alignment = .centerY
        tabStack.distribution = .gravityAreas
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        tabScroll.documentView = tabStack
        tabScroll.hasHorizontalScroller = true
        tabScroll.hasVerticalScroller = false
        tabScroll.drawsBackground = false
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor),
        ])

        let tabBarUnderline = NSBox()
        tabBarUnderline.boxType = .separator
        tabBarUnderline.translatesAutoresizingMaskIntoConstraints = false

        // The content area must participate in Auto Layout via explicit
        // constraints only; leaving translatesAutoresizingMaskIntoConstraints
        // true here produces conflicting constraints and a zero-sized content
        // area (the preview appears blank).
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        // --- content area: project tree (left) | preview (right) ---
        treeOutline.headerView = nil
        let treeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        treeOutline.addTableColumn(treeColumn)
        treeOutline.outlineTableColumn = treeColumn
        treeOutline.rowSizeStyle = .small
        treeOutline.dataSource = self
        treeOutline.delegate = self
        treeOutline.autoresizesOutlineColumn = true

        treeScroll.documentView = treeOutline
        treeScroll.hasVerticalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.translatesAutoresizingMaskIntoConstraints = false

        // The tree pane participates in Auto Layout; its width is set once the
        // panel is visible (see applyInitialTreeWidthIfNeeded) and can then be
        // adjusted by dragging the divider (bounded by the delegate below).
        let treePane = NSView()
        treePane.translatesAutoresizingMaskIntoConstraints = false
        treePane.addSubview(treeScroll)
        NSLayoutConstraint.activate([
            treeScroll.leadingAnchor.constraint(equalTo: treePane.leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: treePane.trailingAnchor),
            treeScroll.topAnchor.constraint(equalTo: treePane.topAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: treePane.bottomAnchor),
        ])

        let contentSplit = NSSplitView()
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addSubview(treePane)
        contentSplit.addSubview(contentContainer)
        contentSplit.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
        self.contentSplit = contentSplit

        view.addSubview(header)
        view.addSubview(tabScroll)
        view.addSubview(tabBarUnderline)
        view.addSubview(contentSplit)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tabScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // header (40) + tab bar (33) + separator (1) = 74pt, matching the
            // height of dsh web's workspace top so the two panes line up.
            tabScroll.heightAnchor.constraint(equalToConstant: 33),

            tabBarUnderline.topAnchor.constraint(equalTo: tabScroll.bottomAnchor),
            tabBarUnderline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarUnderline.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentSplit.topAnchor.constraint(equalTo: tabBarUnderline.bottomAnchor),
            contentSplit.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentSplit.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentSplit.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Open a path in the panel: activates the matching tab or creates a new one.
    @discardableResult
    func open(path rawPath: String) -> Bool {
        let path = (rawPath as NSString).standardizingPath
        guard path.hasPrefix("/") else { return false }
        ensureTreeLoaded() // load the project tree once the panel is in use
        AppLog.shared.log("preview open: \(path)")
        if let existing = tabs.first(where: { $0.path == path }) {
            select(existing.id)
            return true
        }
        let id = nextId
        nextId += 1
        let name = (path as NSString).lastPathComponent
        let item = makeTabItem(id: id, title: name, tooltip: path)
        tabStack.addArrangedSubview(item.view)
        tabs.append(Tab(id: id, path: path,
                        titleButton: item.titleButton,
                        closeButton: item.closeButton,
                        container: item.view))
        onTabsChanged?()
        select(id)
        return true
    }

    // MARK: - Tab management

    private func makeTabItem(id: Int, title: String, tooltip: String)
        -> (view: NSView, titleButton: NSButton, closeButton: NSButton) {
        let titleButton = NSButton(title: title, target: self, action: #selector(selectTab(_:)))
        titleButton.bezelStyle = .texturedRounded
        titleButton.setButtonType(.pushOnPushOff)
        titleButton.state = .off
        titleButton.tag = id
        titleButton.toolTip = tooltip
        titleButton.cell?.lineBreakMode = .byTruncatingTail
        // Let the title shrink (with truncation) instead of forcing the tab wide.
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true

        let closeButton = NSButton(title: "✕", target: self, action: #selector(closeTab(_:)))
        closeButton.bezelStyle = .inline
        closeButton.tag = id
        closeButton.toolTip = L10n.tr("preview.closeTab")

        // A stack-based tab unit has a proper intrinsic size, so the outer
        // tab bar can lay tabs out side by side without squeezing them.
        let item = NSStackView(views: [titleButton, closeButton])
        item.orientation = .horizontal
        item.spacing = 2
        item.alignment = .centerY
        item.translatesAutoresizingMaskIntoConstraints = false
        item.setHuggingPriority(.defaultHigh, for: .horizontal)
        return (item, titleButton, closeButton)
    }

    @objc private func selectTab(_ sender: NSButton) {
        select(sender.tag)
    }

    @objc private func closeTab(_ sender: NSButton) {
        close(sender.tag)
    }

    /// Close a tab the USER asked to close (the tab's ✕, or ⌘W): when it has
    /// unsaved edits, ask first — this is a panel-local action, so "cancel" is a
    /// legitimate answer here (unlike a workspace switch, which dsh web already
    /// performed).
    private func close(_ id: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard tab.isDirty, tab.editor != nil else {
            closeNow(id)
            return
        }
        askAboutUnsaved([tab], message: "preview.closeUnsavedMessage", saveTitle: "preview.closeSave") { [weak self] decision in
            guard let self = self else { return }
            switch decision {
            case .cancel:
                AppLog.shared.log("preview close tab cancelled (unsaved): \(tab.path)")
            case .discard:
                self.closeNow(id)
            case .save:
                guard self.saveTabs([tab]) else { return }   // error shown; tab stays
                self.closeNow(id)
            }
        }
    }

    private func select(_ id: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedId = id
        for t in tabs {
            t.titleButton.state = (t.id == id) ? .on : .off
        }
        updateHeader(for: tab.path)
        render(tab.path)
        refreshSaveState()
    }

    /// Drop one tab immediately (no unsaved-changes question — callers have
    /// either resolved it or are not user-initiated).
    private func closeNow(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].container.removeFromSuperview()
        tabs.remove(at: idx)
        onTabsChanged?()
        guard selectedId == id else { return }
        selectedId = nil
        if let next = tabs.indices.contains(idx) ? tabs[idx] : tabs.last {
            select(next.id)
        } else {
            resetContentArea()
        }
    }

    /// Navigate the given tab to a new path (used by folder browsing).
    private func navigate(_ tabId: Int, to newPath: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let path = (newPath as NSString).standardizingPath
        tabs[idx].path = path
        tabs[idx].titleButton.toolTip = path
        refreshTabTitle(at: idx)
        updateHeader(for: path)
        render(path)
    }

    private var currentTabPath: String? {
        guard let id = selectedId else { return nil }
        return tabs.first(where: { $0.id == id })?.path
    }

    /// 头部随活动页签变化的部分：按钮可用性 + 悬停提示里的完整路径。
    /// 标题本身是固定的面板名（见 panelTitle），不显示路径。
    private func updateHeader(for path: String) {
        titleLabel.toolTip = path
        openButton.isEnabled = true
        revealButton.isEnabled = true
    }

    /// 面板的固定标题：与活动栏的「文件 / Files」同名，语言切换时刷新。
    private static var panelTitle: String { L10n.tr("bar.preview") }

    // MARK: - Actions (top-right)

    @objc private func openInDefaultApp(_ sender: Any?) {
        guard let path = currentTabPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let path = currentTabPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func hidePanel(_ sender: Any?) {
        // 关闭面板 = 关闭所有预览页签（释放渲染内容）+ 清空工作区记忆，再收起面板。
        // 有未保存修改时先问一句：取消 = 面板保持原样（不关也不清）。
        let dirty = tabs.filter { $0.isDirty && $0.editor != nil }
        guard !dirty.isEmpty else {
            closeAllTabs()
            onRequestHide?()
            return
        }
        askAboutUnsaved(dirty, message: "preview.closeUnsavedMessage", saveTitle: "preview.closeSave") { [weak self] decision in
            guard let self = self else { return }
            switch decision {
            case .cancel:
                AppLog.shared.log("preview close cancelled (unsaved tabs kept)")
            case .discard:
                self.closeAllTabs()
                self.onRequestHide?()
            case .save:
                guard self.saveTabs(dirty) else { return }   // error shown; panel stays
                self.closeAllTabs()
                self.onRequestHide?()
            }
        }
    }

    /// 关闭所有预览页签并清空内容区（面板关闭时释放资源）。
    private func closeAllTabs() {
        supersedePendingPrompt()
        closeEveryTab()
        tabMemory.forgetAll()          // 关闭面板 = 回收：连各工作区的记忆一并清空
        AppLog.shared.log("preview close: all tabs dropped (workspace tab memory cleared)")
    }

    /// The answer to an unsaved-changes question before a user-initiated close.
    private enum UnsavedDecision { case save, discard, cancel }

    /// Ask about unsaved edits before a close the USER asked for (a tab's ✕, ⌘W,
    /// or the panel's ✕). `cancel` abandons the action; `save`/`discard` proceed
    /// (the caller saves first for .save). With no window there is nobody to ask:
    /// nothing is discarded — the action is abandoned instead.
    private func askAboutUnsaved(_ dirty: [Tab], message: String, saveTitle: String,
                                 proceed: @escaping (UnsavedDecision) -> Void) {
        guard !dirty.isEmpty else {
            proceed(.discard)
            return
        }
        guard let window = view.window else {
            AppLog.shared.log("preview close: \(dirty.count) unsaved tab(s) kept (no window to confirm in)")
            proceed(.cancel)
            return
        }
        let names = dirty.map { ($0.path as NSString).lastPathComponent }
        let listed = names.prefix(5).joined(separator: "\n") + (names.count > 5 ? "\n…" : "")
        let alert = NSAlert()
        alert.messageText = L10n.tr("preview.unsavedTitle")
        alert.informativeText = L10n.tr(message, listed)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr(saveTitle))
        alert.addButton(withTitle: L10n.tr("preview.discard"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))   // ESC
        pendingPromptAlert = alert
        AppLog.shared.log("preview close: asks about \(dirty.count) unsaved tab(s)")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.pendingPromptAlert = nil
            switch response {
            case .alertFirstButtonReturn: proceed(.save)
            case .alertSecondButtonReturn: proceed(.discard)
            default: proceed(.cancel)
            }
        }
    }

    /// Write back every tab among `candidates` that is still dirty. Returns false
    /// when any save failed (the editor already reported it through onSaveError),
    /// so the caller can keep the tab / panel open instead of losing the buffer.
    private func saveTabs(_ candidates: [Tab]) -> Bool {
        var allSaved = true
        for candidate in candidates {
            guard let idx = tabs.firstIndex(where: { $0.id == candidate.id }),
                  tabs[idx].isDirty, let editor = tabs[idx].editor else { continue }
            AppLog.shared.log("preview close: saving \(tabs[idx].path)")
            if !editor.writeBack() { allSaved = false }
        }
        return allSaved
    }

    /// Drop every open tab and reset the content area (no memory side effects).
    private func closeEveryTab() {
        closeTabs(Set(tabs.map { $0.id }))
        selectedId = nil
        resetContentArea()
    }

    /// Close the given tabs, releasing their content (no memory side effects).
    /// Used by the workspace hand-off, which keeps tabs with unresolved unsaved
    /// edits open while closing the rest.
    private func closeTabs(_ ids: Set<Int>) {
        for id in ids {
            guard let idx = tabs.firstIndex(where: { $0.id == id }) else { continue }
            tabStack.removeArrangedSubview(tabs[idx].container)
            tabs[idx].container.removeFromSuperview()
            tabs.remove(at: idx)
        }
        if let selected = selectedId, !tabs.contains(where: { $0.id == selected }) {
            selectedId = nil
        }
        onTabsChanged?()
        refreshSaveState()
    }

    /// Empty the content area and the header (no tab is open/rendered).
    private func resetContentArea() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        titleLabel.toolTip = nil
        openButton.isEnabled = false
        revealButton.isEnabled = false
        showEmptyState()
        refreshSaveState()
    }

    /// 语言切换后刷新头部按钮 tooltip（构建时一次性设置，需手动跟随）。
    func refreshTooltips() {
        titleLabel.text = Self.panelTitle
        projectButton?.toolTip = L10n.tr("preview.openProjectHint")
        openButton?.toolTip = L10n.tr("preview.openInDefaultAppHint")
        revealButton?.toolTip = L10n.tr("preview.revealInFinderHint")
        hideButton?.toolTip = L10n.tr("preview.closePanel")
        saveButton?.toolTip = L10n.tr("preview.saveHint")
    }

    // MARK: - Editing / Save

    /// Save the active editable tab's buffer to disk (header Save button and
    /// the app's Cmd+S menu item). No-op unless the tab is editable & dirty.
    func saveActiveTab() {
        guard let id = selectedId,
              let idx = tabs.firstIndex(where: { $0.id == id }),
              let editor = tabs[idx].editor, tabs[idx].isDirty else { return }
        AppLog.shared.log("preview save: \(tabs[idx].path)")
        _ = editor.writeBack()   // on failure, editor reports via onSaveError
    }

    /// Close the active (selected) tab, if any — used by the File ▸ 关闭页签
    /// menu item (Ctrl+W). No-op when no tab is open.
    func closeActiveTab() {
        guard let id = selectedId else { return }
        close(id)
    }

    /// Enable/disable the header Save button from the active tab's state.
    private func refreshSaveState() {
        let active = tabs.first(where: { $0.id == selectedId })
        saveButton?.isEnabled = (active?.isEditable ?? false) && (active?.isDirty ?? false)
    }

    /// Set a tab's title to its filename, appending "*" when it has unsaved
    /// edits (the classic dirty marker). Cleared on save or when re-rendered.
    private func refreshTabTitle(at idx: Int) {
        guard tabs.indices.contains(idx) else { return }
        let tab = tabs[idx]
        let base = (tab.path as NSString).lastPathComponent
        tab.titleButton.title = tab.isDirty ? base + " *" : base
    }

    /// Record the active tab's editable/dirty state and its live editor.
    private func applyEditState(editable: Bool, dirty: Bool, editor: CodeEditorView?, atTab id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].isEditable = editable
        tabs[idx].isDirty = dirty
        tabs[idx].editor = editor
        refreshSaveState()
        refreshTabTitle(at: idx)
    }

    /// Show a non-blocking save-error alert (sheets over the panel window).
    private func presentSaveError(_ message: String) {
        AppLog.shared.log("preview save error: \(message)")
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("preview.saveFailed", message)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Open the current project folder as the directory tree root (and as a
    /// folder tab in the preview area). Resolved via the dsh host RPC
    /// `session.list`; falls back to a folder picker when the directory can't
    /// be determined.
    @objc private func openProjectDirectory(_ sender: Any?) {
        resolveProjectDirectory { [weak self] cwd in
            guard let self = self else { return }
            if let cwd = cwd {
                AppLog.shared.log("preview project dir (RPC): \(cwd)")
                self.setTreeRoot(cwd, thenOpen: cwd)
            } else {
                AppLog.shared.log("preview project dir: RPC failed, using picker")
                self.pickDirectoryFallback()
            }
        }
    }

    /// Re-root the project directory tree when the active dsh session's
    /// workspace changes (called by the shell's dshSession handler). The tabs of
    /// the outgoing workspace are remembered and closed, and the incoming
    /// workspace's remembered tabs are reopened — see setTreeRoot.
    func setProjectDirectory(_ path: String) {
        AppLog.shared.log("preview project dir updated: \(path)")
        treeTriedLoad = false
        setTreeRoot(path)
    }

    /// Load the project directory tree once the panel comes into use. Called
    /// from open(path:) and by the shell whenever the panel is shown; retries
    /// are allowed until the server is reachable.
    func ensureTreeLoaded() {
        guard !treeTriedLoad, treeRoot == nil else { return }
        treeTriedLoad = true
        resolveProjectDirectory { [weak self] cwd in
            guard let self = self else { return }
            if let cwd = cwd {
                self.setTreeRoot(cwd)
            } else {
                self.treeTriedLoad = false
            }
        }
    }

    /// Resolve the active session's working directory on a background queue,
    /// then call the completion on the main queue (nil when unresolved).
    /// Implemented by the shared DSHSessionRPC helper (see main.swift).
    private func resolveProjectDirectory(_ completion: @escaping (String?) -> Void) {
        DSHSessionRPC.resolveProjectDirectory(port: serverPortProvider?() ?? 3080,
                                              completion: completion)
    }

    /// Fallback when the project directory can't be resolved: let the user
    /// pick any folder to browse (remembering the last choice).
    private func pickDirectoryFallback() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("preview.pickFolderMessage")
        panel.prompt = L10n.tr("preview.pickFolderOpen")
        if let last = ShellConfig.shared.string(forKey: "previewLastDirectory") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            ShellConfig.shared.set(url.path, forKey: "previewLastDirectory")
            // setTreeRoot hands the open tabs over when this is a different
            // folder, then opens the picked folder as the new workspace's tab.
            self?.setTreeRoot(url.path, thenOpen: url.path)
        }
    }

    // MARK: - Directory tree

    /// Replace the tree root with the given directory and reload.
    ///
    /// This is the panel's ONLY re-root entry point — the workspace follow
    /// (setProjectDirectory), the project-folder button and the folder picker
    /// all land here — so a root change is also where the per-workspace tab
    /// hand-off happens: when the root moves to a DIFFERENT directory, the
    /// outgoing workspace's tabs are remembered and closed (they belong to that
    /// workspace and hold editors/highlighting/preview content alive), and the
    /// incoming workspace's remembered tabs are reopened. A first resolution
    /// (treeRoot == nil) never closes anything: file links can open tabs before
    /// the tree has a root.
    /// `thenOpen` is a path to open as a tab once the root is in place — the
    /// caller's own "show me this folder" step (project-folder button, folder
    /// picker). It must NOT run before the hand-off decides the fate of the old
    /// tabs, or the caller's tab would be remembered under the OLD workspace.
    private func setTreeRoot(_ path: String, thenOpen: String? = nil) {
        guard (path as NSString).isAbsolutePath else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        if let previous = treeRoot?.path,
           WorkspaceTabMemory.key(for: previous) != WorkspaceTabMemory.key(for: path) {
            beginWorkspaceSwitch(from: previous, to: path, thenOpen: thenOpen)
            return   // the hand-off continues into applyTreeRoot
        }
        applyTreeRoot(path)
        if let thenOpen = thenOpen { open(path: thenOpen) }
    }

    /// Install `path` as the tree root and start watching it (the body of the
    /// original setTreeRoot, split out so a workspace switch can re-root AFTER
    /// it has dealt with the outgoing tabs).
    private func applyTreeRoot(_ path: String) {
        applyInitialTreeWidthIfNeeded()
        let root = TreeNode(name: (path as NSString).lastPathComponent, path: path, isDir: true)
        root.children = Self.loadChildren(of: root)
        treeRoot = root
        watchedMtimes = [:]
        treeOutline.reloadData()
        treeOutline.expandItem(root)
        treeOutline.selectRowIndexes([], byExtendingSelection: false)
        startTreeWatcher()
        AppLog.shared.log("preview tree root: \(path) (\(root.children?.count ?? 0) entries)")
    }

    // MARK: - Workspace tab hand-off

    /// A switch is pending: the tree root is moving from `from` to `to`.
    ///
    /// The panel ALWAYS follows the workspace — dsh web has already switched, so
    /// there is no "stay here" answer (that is what left the two sides showing
    /// different workspaces). When unsaved edits are in the way the sheet only
    /// asks whether to SAVE them:
    ///   - 保存并切换: write every dirty buffer, then hand the tabs over; a tab
    ///     whose save failed stays open (never discard silently);
    ///   - 不保存: hand over, dropping the edits;
    ///   - nobody to ask (panel hidden / headless) or an unrecognised dismissal:
    ///     keep the dirty tabs open and follow anyway.
    private func beginWorkspaceSwitch(from: String, to: String, thenOpen: String? = nil) {
        // A prompt from an earlier switch may still be up (workspaces can be
        // flipped in dsh web faster than the sheet is answered): the newest
        // request wins — never ignore a request, or the panel ends up stuck on a
        // workspace it silently stopped following.
        supersedePendingPrompt()
        switchRequestGeneration += 1
        let generation = switchRequestGeneration
        let dirty = tabs.filter { $0.isDirty && $0.editor != nil }
        guard !dirty.isEmpty else {
            performWorkspaceSwitch(from: from, to: to, thenOpen: thenOpen)
            return
        }
        let dirtyIds = Set(dirty.map { $0.id })
        guard let window = view.window else {
            AppLog.shared.log("preview workspace switch: \(dirty.count) unsaved tab(s) kept open, "
                              + "no window to ask in: \(to)")
            performWorkspaceSwitch(from: from, to: to, thenOpen: thenOpen, keeping: dirtyIds)
            return
        }
        let names = dirty.map { ($0.path as NSString).lastPathComponent }
        let listed = names.prefix(5).joined(separator: "\n") + (names.count > 5 ? "\n…" : "")
        let alert = NSAlert()
        alert.messageText = L10n.tr("preview.unsavedTitle")
        alert.informativeText = L10n.tr("preview.switchUnsavedMessage", listed)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("preview.switchSave"))
        alert.addButton(withTitle: L10n.tr("preview.discard"))
        pendingPromptAlert = alert
        AppLog.shared.log("preview workspace switch asks about \(dirty.count) unsaved tab(s): \(from) -> \(to)")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, generation == self.switchRequestGeneration else {
                AppLog.shared.log("preview workspace switch: superseded prompt ignored: \(to)")
                return
            }
            self.pendingPromptAlert = nil
            // The root can move while the sheet is up only via a newer request,
            // which the generation check above already rejected.
            let root = self.treeRoot.map { $0.path } ?? from
            guard WorkspaceTabMemory.key(for: root) == WorkspaceTabMemory.key(for: from) else {
                AppLog.shared.log("preview workspace switch: stale request ignored (root already moved): \(to)")
                return
            }
            switch response {
            case .alertSecondButtonReturn:
                AppLog.shared.log("preview workspace switch discarding unsaved edits: \(to)")
                self.performWorkspaceSwitch(from: from, to: to, thenOpen: thenOpen)
            case .alertFirstButtonReturn:
                var failed: Set<Int> = []
                for id in dirtyIds.sorted() {
                    guard let idx = self.tabs.firstIndex(where: { $0.id == id }),
                          self.tabs[idx].isDirty, let editor = self.tabs[idx].editor else { continue }
                    AppLog.shared.log("preview workspace switch saving: \(self.tabs[idx].path)")
                    if !editor.writeBack() { failed.insert(id) }   // reports via presentSaveError
                }
                if !failed.isEmpty {
                    AppLog.shared.log("preview workspace switch: \(failed.count) tab(s) could not be saved, "
                                      + "kept open: \(to)")
                }
                self.performWorkspaceSwitch(from: from, to: to, thenOpen: thenOpen, keeping: failed)
            default:
                // Dismissed without an answer (ESC / window closed): never guess
                // and never discard — keep the edits and follow anyway.
                AppLog.shared.log("preview workspace switch: dismissed without an answer, "
                                  + "unsaved tab(s) kept open: \(to)")
                self.performWorkspaceSwitch(from: from, to: to, thenOpen: thenOpen, keeping: dirtyIds)
            }
        }
    }

    /// Hand the open tabs over from one workspace to another: remember & close
    /// the outgoing set (releasing its resources), re-root the tree, then reopen
    /// whatever the incoming workspace had open.
    ///
    /// `keeping` are tabs whose unsaved edits could NOT be resolved (nobody to
    /// ask, or the save failed): they stay open and are not remembered — closing
    /// them would silently discard the edits, and refusing to move would leave
    /// the panel on a workspace dsh web has already left.
    private func performWorkspaceSwitch(from: String, to: String, thenOpen: String? = nil,
                                        keeping pinned: Set<Int> = []) {
        let leaving = tabs.filter { !pinned.contains($0.id) }
        let selectedLeaves = leaving.contains { $0.id == selectedId }
        tabMemory.remember(paths: leaving.map { $0.path },
                           selectedPath: selectedLeaves ? currentTabPath : nil,
                           for: from)
        AppLog.shared.log("preview workspace switch: \(from) -> \(to) "
                          + "(remembered \(leaving.count) tab(s), kept \(pinned.count))")
        closeTabs(Set(leaving.map { $0.id }))
        applyTreeRoot(to)
        restoreTabs(for: to)
        if let thenOpen = thenOpen { open(path: thenOpen) }
        if tabs.isEmpty {
            resetContentArea()
        } else if selectedId == nil, let last = tabs.last {
            select(last.id)   // e.g. only pinned tabs remain: show one of them
        }
    }

    /// Dismiss a still-open prompt sheet so the newest switch request wins. The
    /// dismissed prompt's completion sees the stale generation (switch) or the
    /// third-button response (close) and is never applied.
    private func supersedePendingPrompt() {
        guard let alert = pendingPromptAlert else { return }
        pendingPromptAlert = nil
        let sheet = alert.window
        guard let parent = sheet.sheetParent else { return }
        AppLog.shared.log("preview workspace switch: superseding the pending prompt")
        parent.endSheet(sheet, returnCode: .alertThirdButtonReturn)
    }

    /// Reopen the tabs remembered for a workspace (folder tabs reopen as folders,
    /// same as before the switch). Paths that no longer exist are skipped, and the
    /// remembered selection is restored when it survived.
    private func restoreTabs(for workspace: String) {
        guard let snapshot = tabMemory.snapshot(for: workspace) else { return }
        let fm = FileManager.default
        var missing = 0
        for path in snapshot.paths {
            if fm.fileExists(atPath: path) {
                open(path: path)
            } else {
                missing += 1
            }
        }
        if let selected = snapshot.selectedPath,
           let tab = tabs.first(where: { $0.path == selected }) {
            select(tab.id)
        }
        AppLog.shared.log("preview restore: \(tabs.count)/\(snapshot.paths.count) tab(s) reopened for \(workspace)"
                          + (missing > 0 ? " (\(missing) missing)" : ""))
    }

    /// Start (once) the filesystem watcher that keeps the tree fresh.
    private func startTreeWatcher() {
        guard treeWatchTimer == nil else { return }
        let t = Timer(timeInterval: treeWatchInterval, repeats: true) { [weak self] _ in
            self?.treeWatcherTick()
        }
        RunLoop.main.add(t, forMode: .common)
        treeWatchTimer = t
    }

    /// Poll mtime of the tree root and every visible directory (expanded or
    /// not); on any change reload the tree while preserving which directories
    /// stay expanded.
    private func treeWatcherTick() {
        guard let root = treeRoot else { return }
        var targets = [root.path]
        for row in 0..<treeOutline.numberOfRows {
            if let item = treeOutline.item(atRow: row) as? TreeNode, item.isDir {
                targets.append(item.path)
            }
        }
        var changed = false
        for p in targets {
            let m = Self.mtime(of: p)
            if let prev = watchedMtimes[p], prev != m { changed = true }
            watchedMtimes[p] = m
        }
        watchedMtimes = watchedMtimes.filter { targets.contains($0.key) }
        if ProcessInfo.processInfo.environment["DSH_PREVIEW_DEBUG"] == "1" {
            AppLog.shared.log("tree tick: targets=\(targets.count) changed=\(changed) root=\(Self.mtime(of: root.path)?.timeIntervalSince1970 ?? -1)")
        }
        if changed {
            AppLog.shared.log("preview tree refresh (filesystem changed)")
            refreshTree()
        }
        // Keep already-open tabs in sync with the filesystem too: when the
        // agent (or anything else) rewrites a file that's open, refresh the
        // tab's content — unless it has unsaved local edits.
        refreshOpenTabsIfChanged()
    }

    /// Reload the content of every open tab whose file changed on disk.
    /// Editable tabs reuse their live editor (so unsaved edits survive) and are
    /// skipped while dirty; read-only tabs are re-rendered when visible.
    private func refreshOpenTabsIfChanged() {
        for (idx, tab) in tabs.enumerated() {
            let m = Self.mtime(of: tab.path)
            guard let m = m, let prev = tab.fileMtime, m != prev else { continue }
            tabs[idx].fileMtime = m   // absorb the change so we don't redo it
            if let editor = tab.editor {
                if tab.isDirty {
                    AppLog.shared.log("preview tab changed on disk; kept unsaved edits: (tab.path)")
                    continue
                }
                AppLog.shared.log("preview reload editor (disk changed): (tab.path)")
                editor.reloadFromDisk()
            } else if tab.id == selectedId {
                AppLog.shared.log("preview reload tab (disk changed): (tab.path)")
                render(tab.path)
            }
        }
    }

    /// Reload the tree: re-read every visible directory's children, keep the
    /// previously expanded directories expanded.
    private func refreshTree() {
        guard let root = treeRoot else { return }
        var expanded: Set<String> = []
        for row in 0..<treeOutline.numberOfRows {
            if let item = treeOutline.item(atRow: row) as? TreeNode,
               item.isDir, treeOutline.isItemExpanded(item) {
                expanded.insert(item.path)
            }
        }
        // Re-read children of every visible directory (including collapsed
        // ones, so expanding shows the latest files too).
        for row in 0..<treeOutline.numberOfRows {
            if let item = treeOutline.item(atRow: row) as? TreeNode, item.isDir {
                item.children = Self.loadChildren(of: item)
            }
        }
        root.children = Self.loadChildren(of: root)
        treeOutline.reloadData()
        treeOutline.expandItem(root)
        var progressed = true
        while progressed {
            progressed = false
            for row in 0..<treeOutline.numberOfRows {
                guard let item = treeOutline.item(atRow: row) as? TreeNode,
                      item.isDir, expanded.contains(item.path),
                      !treeOutline.isItemExpanded(item) else { continue }
                item.children = Self.loadChildren(of: item) ?? []
                treeOutline.expandItem(item)
                progressed = true
            }
        }
        treeOutline.selectRowIndexes([], byExtendingSelection: false)
    }

    private static func mtime(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }

    /// Give the tree pane its default width once the panel actually has a
    /// non-zero size (NSSplitView ignores setPosition before layout). Runs
    /// once; the user can still drag the divider afterwards.
    private func applyInitialTreeWidthIfNeeded() {
        guard !treeWidthInitialized, contentSplit.bounds.width > 0 else { return }
        treeWidthInitialized = true
        contentSplit.setPosition(160, ofDividerAt: 0)
        contentSplit.adjustSubviews()
        AppLog.shared.log("preview tree width initialized: 160pt")
    }

    /// Read a directory's immediate children (directories first, then name).
    private static func loadChildren(of node: TreeNode) -> [TreeNode]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: node.path) else { return nil }
        let nodes = names.map { name -> TreeNode in
            let full = (node.path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: full, isDirectory: &isDir)
            return TreeNode(name: name, path: full, isDir: isDir.boolValue)
        }
        return nodes.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: NSOutlineViewDataSource / Delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return treeRoot == nil ? 0 : 1 }
        guard let node = item as? TreeNode, node.isDir else { return 0 }
        if node.children == nil {
            node.children = Self.loadChildren(of: node) ?? []
        }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return treeRoot! }
        let node = item as! TreeNode
        if node.children == nil {
            node.children = Self.loadChildren(of: node) ?? []
        }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.isDir ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let ident = NSUserInterfaceItemIdentifier("treeCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = ident
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: 12)
            cell.textField = tf
            cell.addSubview(tf)
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = iv
            cell.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.name
        if node.isDir {
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: node.name)
        } else {
            let icon = NSWorkspace.shared.icon(forFile: node.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
        }
        return cell
    }

    /// Clicking a file node opens it in the preview tabs.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = treeOutline.selectedRow
        guard row >= 0, let node = treeOutline.item(atRow: row) as? TreeNode, !node.isDir else { return }
        open(path: node.path)
    }

    // MARK: NSSplitViewDelegate (content area: tree | preview)

    /// Keep the tree narrow but usable when dragging the divider.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        420
    }

    // MARK: - Rendering

    private func render(_ path: String) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        // Record the file's current mtime so the watcher can tell this render
        // apart from a later on-disk modification (refresh of open tabs).
        if let id = selectedId, let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].fileMtime = Self.mtime(of: path)
        }
        // Re-selecting an already-open editable tab reuses its live editor so
        // in-memory unsaved edits survive tab switches (same path only).
        if let id = selectedId, let idx = tabs.firstIndex(where: { $0.id == id }),
           let existing = tabs[idx].editor, tabs[idx].isEditable, existing.path == path {
            embed(existing)
            AppLog.shared.log("preview reused live editor: \(path)")
            return
        }
        // Freshly rendered content is not editable until showText() says so.
        if let id = selectedId, let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].isEditable = false
            tabs[idx].isDirty = false
            tabs[idx].editor = nil
            refreshTabTitle(at: idx)
        }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            showPlaceholder(symbol: "questionmark.folder",
                            title: L10n.tr("preview.missing", path))
            return
        }
        if isDir.boolValue {
            showDirectory(path)
        } else {
            showFile(path)
        }
        AppLog.shared.log("preview rendered: \(isDir.boolValue ? "directory" : "file") \(path)")
        // Layout diagnostics (DSH_PREVIEW_DEBUG=1): confirm the content area
        // actually has a size and the embedded view fills it.
        if ProcessInfo.processInfo.environment["DSH_PREVIEW_DEBUG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                AppLog.shared.log("layout: panel=\(self.view.frame) content=\(self.contentContainer.frame)")
                if self.contentSplit.subviews.count > 1 {
                    AppLog.shared.log("layout: treePane=\(self.contentSplit.subviews[0].frame.width)pt")
                }
                for sub in self.contentContainer.subviews {
                    AppLog.shared.log("layout: child \(type(of: sub)) frame=\(sub.frame) hidden=\(sub.isHidden)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                AppLog.shared.log("layout2: content=\(self.contentContainer.frame) tree=\(self.contentSplit.subviews[0].frame.width)pt")
                for sub in self.contentContainer.subviews {
                    AppLog.shared.log("layout2: child \(type(of: sub)) frame=\(sub.frame)")
                }
            }
        }
    }

    private func embed(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func showEmptyState() {
        showPlaceholder(symbol: "doc.text.magnifyingglass", title: L10n.tr("preview.empty"))
    }

    private func showPlaceholder(symbol: String, title: String) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let iconView = BakedIconView(symbol: symbol)

        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 300

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -20),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: - Directory preview

    private func showDirectory(_ path: String) {
        let fm = FileManager.default
        var rows: [DirRow] = []
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path && fm.fileExists(atPath: parent) {
            rows.append(DirRow(name: L10n.tr("preview.parent"), path: parent, isDir: true, size: 0, modified: nil))
        }
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let full = (path as NSString).appendingPathComponent(name)
            var isD: ObjCBool = false
            _ = fm.fileExists(atPath: full, isDirectory: &isD)
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs?[.modificationDate] as? Date
            rows.append(DirRow(name: name, path: full,
                               isDir: isD.boolValue,
                               size: isD.boolValue ? 0 : size,
                               modified: modified))
        }
        rows.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        dirRows = rows
        AppLog.shared.log("preview directory: \(rows.count) entries")

        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.addTableColumn(column(L10n.tr("preview.name"), id: "name", width: 220))
        table.addTableColumn(column(L10n.tr("preview.size"), id: "size", width: 70))
        table.addTableColumn(column(L10n.tr("preview.modified"), id: "modified", width: 130))
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        embed(scroll)
    }

    private func column(_ title: String, id: String, width: CGFloat) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title
        c.width = width
        c.resizingMask = .autoresizingMask
        return c
    }

    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < dirRows.count, let current = selectedId else { return }
        let target = dirRows[row]
        if target.isDir {
            navigate(current, to: target.path)
        } else {
            open(path: target.path)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        dirRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < dirRows.count, let col = tableColumn else { return nil }
        let r = dirRows[row]
        switch col.identifier.rawValue {
        case "name":
            let icon: NSImage?
            if r.isDir {
                icon = NSImage(systemSymbolName: "folder", accessibilityDescription: r.name)
            } else {
                let img = NSWorkspace.shared.icon(forFile: r.path)
                img.size = NSSize(width: 16, height: 16)
                icon = img
            }
            return cell(tableView, "nameCell", text: r.name, image: icon)
        case "size":
            let text = r.isDir ? "—" : ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
            return cell(tableView, "sizeCell", text: text, image: nil)
        default:
            let text = r.modified.map { Self.dateFmt.string(from: $0) } ?? ""
            return cell(tableView, "modifiedCell", text: text, image: nil)
        }
    }

    private func cell(_ tableView: NSTableView, _ id: String, text: String, image: NSImage?) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier(id)
        var c = tableView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView
        if c == nil {
            c = NSTableCellView()
            c!.identifier = ident
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: 12)
            c!.textField = tf
            c!.addSubview(tf)
            if image != nil || id == "nameCell" {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                c!.imageView = iv
                c!.addSubview(iv)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c!.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: c!.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: c!.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c!.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c!.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: c!.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c!.centerYAnchor),
                ])
            }
        }
        c!.textField?.stringValue = text
        c!.imageView?.image = image
        return c!
    }

    // MARK: - File previews

    private func showFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            showPlaceholder(symbol: "exclamationmark.triangle",
                            title: L10n.tr("preview.unreadable", path))
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .data
        let isMarkdown = ["md", "markdown", "mdown", "mkd"].contains(ext)

        if isMarkdown || type.conforms(to: .text) || Self.textExtensions.contains(ext) || Self.looksLikeText(data) {
            AppLog.shared.log("preview subtype: text\(isMarkdown ? "/markdown" : "") \(path)")
            // Markdown previews stay plain text too: rendering Markdown merges
            // soft line breaks (a single newline becomes a space), which users
            // read as "line breaks are broken". Plain monospaced text keeps
            // every newline intact, same as code files.
            showText(path: path, data: data)
        } else if type.conforms(to: .image) {
            AppLog.shared.log("preview subtype: image \(path)")
            showImage(path: path)
        } else if type == .pdf || ext == "pdf" {
            AppLog.shared.log("preview subtype: pdf \(path)")
            showPDF(path: path)
        } else {
            AppLog.shared.log("preview subtype: metadata \(path)")
            showMetadata(path: path, data: data)
        }
    }

    private func showText(path: String, data: Data) {
        // A file is editable only when it fits under the cap (so we never
        // overwrite it with a truncated buffer) AND its content is valid UTF-8
        // (so a write-back round-trips cleanly). Everything else stays read-only.
        let editable = data.count <= textCap && String(data: data, encoding: .utf8) != nil
        guard editable else {
            showReadOnlyText(path: path, data: data)
            return
        }

        guard let tabId = selectedId else { return }
        let string = String(data: data, encoding: .utf8) ?? ""
        let ext = (path as NSString).pathExtension.lowercased()
        let language = CodeEditorView.language(forExtension: ext)
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let editor = CodeEditorView(path: path, text: string, language: language, dark: dark)
        editor.onDirtyChange = { [weak self] dirty in
            self?.applyEditState(editable: true, dirty: dirty, editor: editor, atTab: tabId)
        }
        editor.onSaveError = { [weak self] message in
            self?.presentSaveError(message)
        }
        applyEditState(editable: true, dirty: false, editor: editor, atTab: tabId)
        AppLog.shared.log("preview editable text: \(string.count) chars (highlight=\(language ?? "none"))")
        embed(editor)
    }

    /// Read-only text preview (too large, or not safely UTF-8). Never editable.
    private func showReadOnlyText(path: String, data: Data) {
        var chunk = data
        var truncated = false
        if data.count > textCap {
            chunk = data.prefix(textCap)
            truncated = true
        }

        // NSTextView.scrollableTextView() returns a ready-made scroll view with
        // a vertically resizable text view — the reliable way to display text
        // of any length (a bare NSTextView with a zero frame is not visible).
        // Backgrounds use the dynamic .textBackgroundColor so the preview
        // follows light/dark appearance.
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.autoresizingMask = [.width]

        var note = ""
        if truncated {
            note = "\n\n────────────────────────\n"
                + L10n.tr("preview.tooLarge", textCap / (1024 * 1024))
                + "\n"
        }
        textView.string = Self.decode(chunk) + note

        AppLog.shared.log("preview read-only text: \(textView.string.count) chars")
        embed(scroll)
    }

    private func showImage(path: String) {
        guard let img = NSImage(contentsOfFile: path) else {
            showPlaceholder(symbol: "photo",
                            title: L10n.tr("preview.unreadable", path))
            return
        }
        let imageView = NSImageView()
        imageView.image = img
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = NSRect(origin: .zero, size: img.size)

        let scroll = NSScrollView()
        scroll.documentView = imageView
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        AppLog.shared.log("preview image: \(Int(img.size.width))x\(Int(img.size.height))")
        embed(scroll)
    }

    private func showPDF(path: String) {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            showPlaceholder(symbol: "doc.richtext",
                            title: L10n.tr("preview.unreadable", path))
            return
        }
        let pdfView = PDFView()
        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .textBackgroundColor
        AppLog.shared.log("preview pdf: \(doc.pageCount) pages")
        embed(pdfView)
    }

    private func showMetadata(path: String, data: Data) {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let ext = (path as NSString).pathExtension
        let type = UTType(filenameExtension: ext)
        let kind = type?.localizedDescription ?? L10n.tr("preview.kindUnknown")

        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: path)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: (path as NSString).lastPathComponent)
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle

        let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        let created = (attrs[.creationDate] as? Date).map { Self.dateFmt.string(from: $0) } ?? "—"
        let modified = (attrs[.modificationDate] as? Date).map { Self.dateFmt.string(from: $0) } ?? "—"

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(metaRow(L10n.tr("preview.kind"), kind))
        rows.addArrangedSubview(metaRow(L10n.tr("preview.size"),
                                        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        rows.addArrangedSubview(metaRow(L10n.tr("preview.created"), created))
        rows.addArrangedSubview(metaRow(L10n.tr("preview.modified"), modified))
        rows.addArrangedSubview(metaRow(L10n.tr("preview.path"), path))

        let openBtn = NSButton(title: L10n.tr("preview.openInDefaultApp"),
                               target: self, action: #selector(openInDefaultApp(_:)))
        openBtn.bezelStyle = .rounded

        let stack = NSStackView(views: [iconView, nameLabel, rows, openBtn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -20),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func metaRow(_ title: String, _ value: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .right
        titleLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.isSelectable = true
        valueLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    private static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return L10n.tr("preview.binary")
    }

    /// Heuristic: treat a file as plain text when it decodes as UTF-8 and is
    /// non-binary (no NUL bytes, low control-char ratio). This lets extensionless
    /// files (LICENSE, Makefile) and dotfiles (.gitignore, .env, .npmrc) preview
    /// as text even though their pathExtension yields "".
    private static func looksLikeText(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        if data.contains(0) { return false }
        let control = s.unicodeScalars.filter { $0.value < 0x20 && !"\n\r\t".unicodeScalars.contains($0) }.count
        return control < 8
    }
}
