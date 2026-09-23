import AppKit

/// The「会话快照…」window: lists session snapshots and offers roll back /
/// reveal / delete (docs/session-snapshot-rollback-design.md §12).
///
/// Presentation only: data comes from the `ohmy-core snapshot` CLI (CoreBridge)
/// and the actual rollback — which must stop dsh web first and then quit the
/// app — stays in the AppDelegate, reached through `onRollback`.
final class SnapshotWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    /// Where the data lives ($DSH_HOME — dev builds point at ~/.dsh-dev).
    var dshHome: () -> String = { NSHomeDirectory() + "/.dsh" }
    /// The user confirmed a target; the AppDelegate runs the transaction.
    var onRollback: ((SnapshotModel.Entry) -> Void)?

    private var window: NSWindow?
    private var entries: [SnapshotModel.Entry] = []
    private var listing: SnapshotModel.Listing?
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var rollbackButton: NSButton!
    private var revealButton: NSButton!
    private var deleteButton: NSButton!

    private static let columns: [(id: String, titleKey: String, width: CGFloat)] = [
        ("time", "snapshot.col.time", 120),
        ("reason", "snapshot.col.reason", 110),
        ("from", "snapshot.col.from", 150),
        ("sessions", "snapshot.col.sessions", 70),
        ("size", "snapshot.col.size", 80),
        ("tree", "snapshot.col.tree", 170),
    ]

    // MARK: lifecycle

    func show() {
        if window == nil { buildWindow() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.shared.log("snapshot window shown")
    }

    /// Set by the AppDelegate when the launch hook has something to report.
    func setNotice(_ text: String?) {
        hintLabel.stringValue = text ?? ""
        hintLabel.isHidden = (text ?? "").isEmpty
    }

    // MARK: data

    private func runSnapshot(_ args: [String]) -> String? {
        CoreBridge.run(["snapshot"] + args + ["--home", dshHome()], timeout: 120, preferBundledNode: true)
    }

    func reload() {
        guard let json = runSnapshot(["list"]) else {
            entries = []; listing = nil
            table.reloadData()
            statusLabel.stringValue = L10n.tr("snapshot.unavailable")
            updateButtons()
            return
        }
        listing = SnapshotModel.parseListing(json)
        entries = listing?.entries ?? []
        table.reloadData()
        updateButtons()
        updateStatusLabel()
    }

    private func updateStatusLabel() {
        guard let state = listing?.state else { statusLabel.stringValue = ""; return }
        var line = L10n.tr("snapshot.status.data", state.dataApp, state.dataDsh)
        if let pinned = state.pinnedDsh {
            line += " · " + L10n.tr("snapshot.status.pinned", pinned)
        }
        if let pool = listing?.pool, !pool.isEmpty {
            line += " · " + L10n.tr("snapshot.status.pool", pool.joined(separator: ", "))
        }
        statusLabel.stringValue = line
    }

    private func updateButtons() {
        let selected = selectedEntry()
        rollbackButton.isEnabled = selected != nil && !(selected?.broken ?? true)
        revealButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
    }

    private func selectedEntry() -> SnapshotModel.Entry? {
        let row = table.selectedRow
        return row >= 0 && row < entries.count ? entries[row] : nil
    }

    // MARK: actions

    @objc private func refreshTapped(_ sender: Any?) { reload() }

    @objc private func rollbackTapped(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        onRollback?(entry)
    }

    @objc private func revealTapped(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dshHome() + "/shell/snapshots/" + entry.id)
    }

    @objc private func deleteTapped(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("snapshot.delete.title")
        alert.informativeText = L10n.tr("snapshot.delete.info", entry.id)
        alert.addButton(withTitle: L10n.tr("btn.delete"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = runSnapshot(["delete", "--id", entry.id])
        AppLog.shared.log("snapshot deleted: " + entry.id)
        reload()
    }

    // MARK: construction

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 380)
        w.title = L10n.tr("snapshot.title")
        window = w

        let root = NSView(frame: w.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        w.contentView = root

        let title = NSTextField(labelWithString: L10n.tr("snapshot.title"))
        title.font = .boldSystemFont(ofSize: 15)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .systemOrange
        hintLabel.isHidden = true
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2

        let header = NSStackView(views: [title, statusLabel, hintLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        for col in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = L10n.tr(col.titleKey)
            column.width = col.width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        rollbackButton = NSButton(title: L10n.tr("snapshot.action.rollback"), target: self, action: #selector(rollbackTapped(_:)))
        rollbackButton.bezelStyle = .rounded
        rollbackButton.keyEquivalent = "\r"
        revealButton = NSButton(title: L10n.tr("snapshot.action.reveal"), target: self, action: #selector(revealTapped(_:)))
        revealButton.bezelStyle = .rounded
        deleteButton = NSButton(title: L10n.tr("snapshot.action.delete"), target: self, action: #selector(deleteTapped(_:)))
        deleteButton.bezelStyle = .rounded
        let refreshButton = NSButton(title: L10n.tr("snapshot.action.refresh"), target: self, action: #selector(refreshTapped(_:)))
        refreshButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [refreshButton, spacer, revealButton, deleteButton, rollbackButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        w.center()
    }

    // MARK: table datasource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: Self.text(for: id, entry: entries[row]))
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    /// One cell text (pure formatting lives in SnapshotModel).
    static func text(for column: String, entry: SnapshotModel.Entry) -> String {
        switch column {
        case "time": return SnapshotModel.timeText(entry.createdAt)
        case "reason": return entry.broken ? L10n.tr("snapshot.reason.broken") : L10n.tr(SnapshotModel.reasonKey(entry.reason))
        case "from": return entry.appVersion + " / " + entry.dshVersion
        case "sessions": return String(entry.sessions)
        case "size": return SnapshotModel.sizeText(entry.bytes)
        case "tree":
            guard let tree = entry.treeVersion else { return L10n.tr("snapshot.tree.dataOnly") }
            return entry.treeAvailable ? L10n.tr("snapshot.tree.available", tree)
                                       : L10n.tr("snapshot.tree.missing", tree)
        default: return ""
        }
    }
}
