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

    // MARK: - Subviews

    private let pathLabel = HeaderLabel()
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
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        header.addSubview(pathLabel)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            pathLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
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

    private func close(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].container.removeFromSuperview()
        tabs.remove(at: idx)
        guard selectedId == id else { return }
        selectedId = nil
        if let next = tabs.indices.contains(idx) ? tabs[idx] : tabs.last {
            select(next.id)
        } else {
            contentContainer.subviews.forEach { $0.removeFromSuperview() }
            pathLabel.text = ""
            openButton.isEnabled = false
            revealButton.isEnabled = false
            showEmptyState()
            refreshSaveState()
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

    private func updateHeader(for path: String) {
        pathLabel.text = path
        openButton.isEnabled = true
        revealButton.isEnabled = true
    }

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
        // 关闭面板 = 关闭所有预览页签（释放渲染内容），再收起面板
        closeAllTabs()
        onRequestHide?()
    }

    /// 关闭所有预览页签并清空内容区（面板关闭时释放资源）。
    private func closeAllTabs() {
        for tab in tabs {
            tabStack.removeArrangedSubview(tab.container)
            tab.container.removeFromSuperview()
        }
        tabs.removeAll()
        selectedId = nil
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        pathLabel.text = ""
        openButton.isEnabled = false
        revealButton.isEnabled = false
        showEmptyState()
        refreshSaveState()
    }

    /// 语言切换后刷新头部按钮 tooltip（构建时一次性设置，需手动跟随）。
    func refreshTooltips() {
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
                self.setTreeRoot(cwd)
                self.open(path: cwd)
            } else {
                AppLog.shared.log("preview project dir: RPC failed, using picker")
                self.pickDirectoryFallback()
            }
        }
    }

    /// Re-root the project directory tree when the active dsh session's
    /// workspace changes (called by the shell's dshSession handler). Only the
    /// tree is re-pointed; open preview tabs stay untouched.
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
        if let last = UserDefaults.standard.string(forKey: "previewLastDirectory") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: "previewLastDirectory")
            self?.setTreeRoot(url.path)
            self?.open(path: url.path)
        }
    }

    // MARK: - Directory tree

    /// Replace the tree root with the given directory and reload.
    private func setTreeRoot(_ path: String) {
        guard (path as NSString).isAbsolutePath else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
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
