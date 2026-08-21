import AppKit

// MARK: - Channel panel (global channels + per-project refs)

/// Root view. Mirrors IssueRunnerRootView's compositing fix
/// (docs/terminal-header-fix.md): isOpaque=false so header/content composite
/// correctly in the layer-backed window.
final class ChannelRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

/// One global channel shown in the list (docs/channel-design.md §4.1).
struct GlobalChannel {
    enum State: String {
        case disconnected, connecting, connected, reconnecting, authExpired
        var badge: String {
            switch self {
            case .disconnected: return "·"
            case .connecting: return "…"
            case .connected: return "●"
            case .reconnecting: return "⟳"
            case .authExpired: return "!"
            }
        }
    }
    var id: String
    var platform: String
    var name: String
    var enabled: Bool = true
    var state: State = .disconnected
    var connection: [String: String] = [:]
}

/// A project ref: a global channel enabled for one workspace + routing
/// (docs/channel-design.md §4.2).
struct ProjectChannelRef: Codable {
    var channelId: String
    var workspaceRoot: String
    var routingConversations: [String] = []
    var routingKeywords: [String] = []
    var routingDefault: Bool = false
}

/// Persisted model for .dsh/channels.json (docs §4.2):
/// { "version": 1, "refs": [ ... ] }
struct ProjectRefsFile: Codable {
    var version: Int = 1
    var refs: [ProjectChannelRef] = []
}

final class ChannelPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    var onRequestHide: (() -> Void)?
    /// The active workspace directory (set by AppDelegate) — where .dsh/channels.json lives.
    var workspacePath: (() -> String?)?

    static let minWidth: CGFloat = 300

    let view = ChannelRootView()

    // UI
    private let headerTitle = HeaderLabel()
    private let addButton: CustomIconButton
    private let refreshButton: CustomIconButton
    private let hideButton: CustomIconButton
    private let globalLabel = HeaderLabel()
    private let globalTable = NSTableView()
    private let globalScroll = NSScrollView()
    private let refsLabel = HeaderLabel()
    private let refsTable = NSTableView()
    private let refsScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    // State
    private var channels: [GlobalChannel] = []
    private var refs: [ProjectChannelRef] = []
    private var currentRoot: String?

    // MARK: - Init & UI

    override init() {
        addButton = CustomIconButton(glyph: .plus, tooltip: "")
        refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
        hideButton = CustomIconButton(glyph: .close, tooltip: "")
        super.init()
        buildUI()
        addButton.onAction = { [weak self] in self?.addChannelTapped() }
        refreshButton.onAction = { [weak self] in self?.reloadAll() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        loadGlobalChannels()
        updateLabels()
    }

    deinit {}

    private func updateLabels() {
        headerTitle.text = L10n.tr("channel.title")
        addButton.toolTip = L10n.tr("channel.add")
        refreshButton.toolTip = L10n.tr("channel.refresh")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        globalLabel.text = L10n.tr("channel.global")
        refsLabel.text = L10n.tr("channel.refs")
        statusLabel.stringValue = currentRoot.map { L10n.tr("channel.workspace") + " \($0)" } ?? L10n.tr("channel.noWorkspace")
    }

    func refreshTooltips() {
        updateLabels()
    }

    private func buildUI() {
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [refreshButton, addButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        globalLabel.translatesAutoresizingMaskIntoConstraints = false
        refsLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        configureTable(globalTable)
        configureTable(refsTable)
        globalScroll.documentView = globalTable
        globalScroll.hasVerticalScroller = true
        refsScroll.documentView = refsTable
        refsScroll.hasVerticalScroller = true
        globalScroll.translatesAutoresizingMaskIntoConstraints = false
        refsScroll.translatesAutoresizingMaskIntoConstraints = false

        let content = DynamicFillView()
        content.kind = .control
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(globalLabel)
        content.addSubview(globalScroll)
        content.addSubview(refsLabel)
        content.addSubview(refsScroll)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            globalLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            globalLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            globalLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            globalScroll.topAnchor.constraint(equalTo: globalLabel.bottomAnchor, constant: 4),
            globalScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            globalScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            globalScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            refsLabel.topAnchor.constraint(equalTo: globalScroll.bottomAnchor, constant: 12),
            refsLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            refsLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            refsScroll.topAnchor.constraint(equalTo: refsLabel.bottomAnchor, constant: 4),
            refsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            refsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            refsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.topAnchor.constraint(equalTo: refsScroll.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -8),
        ])

        let root = DynamicFillView()
        root.kind = .control
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureTable(_ table: NSTableView) {
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
    }

    // MARK: - Loading

    /// Global channels are persisted in UserDefaults as JSON (docs §4.1).
    private func loadGlobalChannels() {
        if let data = UserDefaults.standard.data(forKey: "channel.global.list"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            channels = arr.compactMap { dict in
                guard let id = dict["id"] as? String, let platform = dict["platform"] as? String else { return nil }
                return GlobalChannel(
                    id: id,
                    platform: platform,
                    name: dict["name"] as? String ?? id,
                    enabled: dict["enabled"] as? Bool ?? true,
                    state: GlobalChannel.State(rawValue: dict["state"] as? String ?? "") ?? .disconnected,
                    connection: dict["connection"] as? [String: String] ?? [:]
                )
            }
        }
    }

    private func saveGlobalChannels() {
        let arr = channels.map { c -> [String: Any] in
            ["id": c.id, "platform": c.platform, "name": c.name, "enabled": c.enabled, "state": c.state.rawValue, "connection": c.connection]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            UserDefaults.standard.set(data, forKey: "channel.global.list")
        }
    }

    /// Load .dsh/channels.json for the active workspace (docs §4.2).
    private func loadRefs(for root: String?) {
        currentRoot = root
        refs = []
        guard let root = root else { updateLabels(); refsTable.reloadData(); return }
        let path = (root as NSString).appendingPathComponent(".dsh/channels.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONDecoder().decode(ProjectRefsFile.self, from: data) else {
            updateLabels(); refsTable.reloadData(); return
        }
        refs = file.refs
        updateLabels()
        refsTable.reloadData()
    }

    private func saveRefs() {
        guard let root = currentRoot else { return }
        let dir = (root as NSString).appendingPathComponent(".dsh")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (root as NSString).appendingPathComponent(".dsh/channels.json")
        let file = ProjectRefsFile(version: 1, refs: refs)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func ensureLoaded() {
        loadGlobalChannels()
        reloadRefs()
        globalTable.reloadData()
    }

    func workspaceChanged() {
        reloadRefs()
    }

    private func reloadAll() {
        loadGlobalChannels()
        reloadRefs()
        globalTable.reloadData()
    }

    private func reloadRefs() {
        loadRefs(for: workspacePath?())
    }

    // MARK: - Actions

    private func addChannelTapped() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("channel.addTitle")
        alert.informativeText = L10n.tr("channel.addInfo")
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = L10n.tr("channel.namePlaceholder")
        let platformPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        platformPopup.addItems(withTitles: ["weixin-clawbot", "dingtalk", "feishu"])
        let stack = NSStackView(views: [nameField, platformPopup])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let platform = platformPopup.titleOfSelectedItem ?? "weixin-clawbot"
        guard !name.isEmpty else { return }
        let id = "\(platform)-\(UUID().uuidString.prefix(8))"
        channels.append(GlobalChannel(id: id, platform: platform, name: name))
        saveGlobalChannels()
        globalTable.reloadData()
    }

    /// Toggle a global channel's enabled flag via double-click on its row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === refsTable {
            // selecting a ref row does nothing for now (routing edit is future)
            return
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // enable/disable a channel on single click (global table only)
        if tableView === globalTable, row >= 0, row < channels.count {
            channels[row].enabled.toggle()
            saveGlobalChannels()
            globalTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        return true
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === globalTable ? channels.count : refs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === globalTable {
            let c = channels[row]
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "\(c.state.badge)  \(c.name)  (\(c.platform))")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            if !c.enabled { label.textColor = .secondaryLabelColor }
            cell.textField?.removeFromSuperview()
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
            return cell
        } else {
            let r = refs[row]
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "\(r.channelId)  →  \(r.workspaceRoot)")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField?.removeFromSuperview()
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
            return cell
        }
    }
}
