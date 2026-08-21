import AppKit

// MARK: - Channel panel v2 (onboarding cards + wizard + project view)

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

/// One global channel (docs/channel-design.md §4.1). Persisted in UserDefaults.
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

/// Persisted model for .dsh/channels.json (docs §4.2).
struct ProjectRefsFile: Codable {
    var version: Int = 1
    var refs: [ProjectChannelRef] = []
}

/// A built-in platform card shown on the onboarding screen.
struct ChannelCard {
    let platform: String
    let symbol: String
    let titleKey: String
    let descKey: String
}

final class ChannelPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    /// The active workspace directory (set by AppDelegate) — where .dsh/channels.json lives.
    var workspacePath: (() -> String?)?
    /// Run QR login for a channel via the core CLI (set by AppDelegate).
    /// completion(true) on success, false on failure/cancel.
    var channelLoginRunner: ((String, @escaping (Bool) -> Void) -> Void)?

    static let minWidth: CGFloat = 300
    let view = ChannelRootView()

    // ---- header ----
    private let headerTitle = HeaderLabel()
    private let configButton: CustomIconButton
    private let hideButton: CustomIconButton

    // ---- content container (swaps per mode) ----
    private let contentContainer = DynamicFillView()
    private let onboardingView = NSView()
    private let projectView = NSView()

    // ---- onboarding UI ----
    private let onboardingTitle = NSTextField(labelWithString: "")
    private let onboardingHint = NSTextField(wrappingLabelWithString: "")
    private var cardViews: [NSView] = []

    // ---- wizard UI ----
    private let wizardView = NSView()
    private let wizardTitle = NSTextField(labelWithString: "")
    private let wizardInfo = NSTextField(wrappingLabelWithString: "")
    private let wizardStatus = NSTextField(labelWithString: "")
    private let wizardPrimary: NSButton
    private let wizardSecondary: NSButton
    private var wizardPlatform: String = ""
    private var wizardStep = 0 // 0 prompt, 1 scanning, 2 done

    // ---- project view UI ----
    private let projectLabel = HeaderLabel()
    private let projectScroll = NSScrollView()
    private let projectTable = NSTableView()
    private let sessionsLabel = HeaderLabel()
    private let sessionsLabel2 = HeaderLabel()

    // ---- state ----
    private var channels: [GlobalChannel] = []
    private var refs: [ProjectChannelRef] = []
    private var currentRoot: String?

    /// Current top-level mode.
    private enum Mode { case onboarding, project }
    private var mode: Mode = .onboarding

    private static let builtins: [ChannelCard] = [
        ChannelCard(platform: "weixin-clawbot", symbol: "message", titleKey: "channel.card.weixin", descKey: "channel.card.weixinDesc"),
        ChannelCard(platform: "dingtalk", symbol: "person.2", titleKey: "channel.card.dingtalk", descKey: "channel.card.dingtalkDesc"),
        ChannelCard(platform: "feishu", symbol: "paperplane", titleKey: "channel.card.feishu", descKey: "channel.card.feishuDesc"),
    ]

    // MARK: - Init

    override init() {
        configButton = CustomIconButton(glyph: .symbol("gearshape"), tooltip: "")
        hideButton = CustomIconButton(glyph: .close, tooltip: "")
        wizardPrimary = NSButton(title: "", target: nil, action: nil)
        wizardSecondary = NSButton(title: "", target: nil, action: nil)
        super.init()
        buildUI()
        configButton.onAction = { [weak self] in self?.configButtonTapped() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        wizardPrimary.target = self
        wizardPrimary.action = #selector(wizardPrimaryTapped(_:))
        wizardSecondary.target = self
        wizardSecondary.action = #selector(wizardSecondaryTapped(_:))
        loadGlobalChannels()
        updateLabels()
        refreshMode()
    }

    deinit {}

    private func updateLabels() {
        headerTitle.text = L10n.tr("channel.title")
        configButton.toolTip = L10n.tr("channel.globalConfig")
        hideButton.toolTip = L10n.tr("preview.closePanel")
        onboardingTitle.stringValue = L10n.tr("channel.onboardingTitle")
        onboardingHint.stringValue = L10n.tr("channel.onboardingHint")
        projectLabel.text = L10n.tr("channel.projectAvailable")
        sessionsLabel.text = L10n.tr("channel.sessions")
        wizardSecondary.title = L10n.tr("channel.wizard.back")
    }

    func refreshTooltips() {
        updateLabels()
    }

    // MARK: - Build

    private func buildUI() {
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [configButton, hideButton])
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

        // content container (compositing fix)
        contentContainer.kind = .control
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        buildOnboarding()
        buildWizard()
        buildProject()

        contentContainer.addSubview(onboardingView)
        contentContainer.addSubview(projectView)
        contentContainer.addSubview(wizardView)
        pin(onboardingView, to: contentContainer)
        pin(projectView, to: contentContainer)
        pin(wizardView, to: contentContainer)

        view.addSubview(header)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    // ---- onboarding (cards) ----
    private func buildOnboarding() {
        onboardingTitle.translatesAutoresizingMaskIntoConstraints = false
        onboardingTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        onboardingHint.translatesAutoresizingMaskIntoConstraints = false
        onboardingHint.font = .systemFont(ofSize: 12)
        onboardingHint.textColor = .secondaryLabelColor

        // cards in a vertical stack
        var stackViews: [NSView] = [onboardingTitle, onboardingHint]
        for card in ChannelPanelController.builtins {
            let cardView = makeCard(card)
            cardViews.append(cardView)
            stackViews.append(cardView)
        }
        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        onboardingView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: onboardingView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: onboardingView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: onboardingView.widthAnchor),
        ])
    }

    private func makeCard(_ card: ChannelCard) -> NSView {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = ChannelPanelController.builtins.firstIndex { $0.platform == card.platform } ?? 0
        button.target = self
        button.action = #selector(cardTapped(_:))

        let icon = NSTextField(labelWithString: "●")
        icon.font = .systemFont(ofSize: 22)
        let title = NSTextField(labelWithString: L10n.tr(card.titleKey))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let desc = NSTextField(wrappingLabelWithString: L10n.tr(card.descKey))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, desc])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: button.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12),
        ])
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        return button
    }

    @objc private func cardTapped(_ sender: NSButton) {
        let cards = ChannelPanelController.builtins
        guard cards.indices.contains(sender.tag) else { return }
        let card = cards[sender.tag]
        // Only weixin-clawbot is wired to a login runner today.
        if card.platform != "weixin-clawbot" {
            NSSound.beep()
            return
        }
        wizardPlatform = card.platform
        wizardStep = 0
        renderWizard()
    }

    // ---- wizard ----
    private func buildWizard() {
        wizardTitle.translatesAutoresizingMaskIntoConstraints = false
        wizardTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        wizardInfo.translatesAutoresizingMaskIntoConstraints = false
        wizardInfo.font = .systemFont(ofSize: 12)
        wizardInfo.textColor = .secondaryLabelColor
        wizardStatus.translatesAutoresizingMaskIntoConstraints = false
        wizardStatus.font = .systemFont(ofSize: 12)
        wizardStatus.textColor = .labelColor

        wizardPrimary.translatesAutoresizingMaskIntoConstraints = false
        wizardSecondary.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [wizardPrimary, wizardSecondary])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [wizardTitle, wizardInfo, wizardStatus, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        wizardView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wizardView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wizardView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wizardView.trailingAnchor),
        ])
        wizardView.isHidden = true
    }

    @objc private func wizardPrimaryTapped(_ sender: Any) {
        if wizardStep == 0 {
            // prompt -> scanning: run QR login
            wizardStep = 1
            renderWizard()
            startLogin()
        } else if wizardStep == 1 {
            // during scan, no-op (or cancel later)
        } else if wizardStep == 2 {
            // done -> close wizard, refresh mode
            finishWizard()
        }
    }

    @objc private func wizardSecondaryTapped(_ sender: Any) {
        finishWizard()
    }

    private func renderWizard() {
        wizardView.isHidden = false
        onboardingView.isHidden = true
        projectView.isHidden = true
        let card = ChannelPanelController.builtins.first { $0.platform == wizardPlatform }
        let platformName = card.map { L10n.tr($0.titleKey) } ?? wizardPlatform
        if wizardStep == 0 {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr("channel.wizard.promptInfo")
            wizardStatus.stringValue = L10n.tr("channel.wizard.promptTitle")
            wizardPrimary.title = L10n.tr("channel.wizard.continue")
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        } else if wizardStep == 1 {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr("channel.wizard.promptInfo")
            wizardStatus.stringValue = L10n.tr("channel.wizard.scanning")
            wizardPrimary.title = L10n.tr("btn.ok")
            wizardPrimary.isEnabled = false
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        } else {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr("channel.wizard.done")
            wizardStatus.stringValue = ""
            wizardPrimary.title = L10n.tr("channel.done")
            wizardPrimary.isEnabled = true
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        }
    }

    private func startLogin() {
        // create (or reuse) a channel for the wizard platform, then login
        let platform = wizardPlatform
        let existing = channels.first(where: { $0.platform == platform })
        let channelId: String
        if let existing = existing {
            channelId = existing.id
        } else {
            let id = "(platform)-(UUID().uuidString.prefix(8))"
            channels.append(GlobalChannel(id: id, platform: platform, name: id))
            saveGlobalChannels()
            channelId = id
        }
        guard let runner = channelLoginRunner else {
            wizardStatus.stringValue = L10n.tr("channel.noLoginRunner")
            return
        }
        runner(channelId) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.wizardPrimary.isEnabled = true
                if ok {
                    if let idx = self.channels.firstIndex(where: { $0.id == channelId }) {
                        self.channels[idx].state = .connected
                        self.saveGlobalChannels()
                    }
                    self.wizardStep = 2
                    self.renderWizard()
                } else {
                    self.wizardStatus.stringValue = L10n.tr("channel.loginFailed")
                    self.wizardStep = 1
                }
            }
        }
    }

    private func finishWizard() {
        wizardView.isHidden = true
        refreshMode()
    }

    // ---- project view ----
    private func buildProject() {
        configureTable(projectTable)
        projectScroll.documentView = projectTable
        projectScroll.hasVerticalScroller = true
        projectScroll.translatesAutoresizingMaskIntoConstraints = false
        projectLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionsLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionsLabel2.translatesAutoresizingMaskIntoConstraints = false

        projectView.addSubview(projectLabel)
        projectView.addSubview(projectScroll)
        projectView.addSubview(sessionsLabel)
        projectView.addSubview(sessionsLabel2)
        NSLayoutConstraint.activate([
            projectLabel.topAnchor.constraint(equalTo: projectView.topAnchor, constant: 12),
            projectLabel.leadingAnchor.constraint(equalTo: projectView.leadingAnchor, constant: 12),
            projectScroll.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 6),
            projectScroll.leadingAnchor.constraint(equalTo: projectView.leadingAnchor, constant: 8),
            projectScroll.trailingAnchor.constraint(equalTo: projectView.trailingAnchor, constant: -8),
            projectScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            sessionsLabel.topAnchor.constraint(equalTo: projectScroll.bottomAnchor, constant: 12),
            sessionsLabel.leadingAnchor.constraint(equalTo: projectView.leadingAnchor, constant: 12),
            sessionsLabel2.topAnchor.constraint(equalTo: sessionsLabel.bottomAnchor, constant: 6),
            sessionsLabel2.leadingAnchor.constraint(equalTo: projectView.leadingAnchor, constant: 12),
        ])
        projectView.isHidden = true
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

    // MARK: - Mode switching

    private func refreshMode() {
        // onboarding = no global channels configured yet
        let hasConfig = !channels.isEmpty
        mode = hasConfig ? .project : .onboarding
        onboardingView.isHidden = (mode == .project)
        projectView.isHidden = (mode == .onboarding)
        wizardView.isHidden = true
        if mode == .project {
            projectTable.reloadData()
            sessionsLabel2.text = L10n.tr("channel.noSessions")
        } else {
            rebuildCards()
        }
    }

    private func configButtonTapped() {
        // Global config button: reopen the onboarding/config view.
        if wizardView.isHidden == false {
            finishWizard()
        }
        mode = .onboarding
        onboardingView.isHidden = false
        projectView.isHidden = true
        wizardView.isHidden = true
        rebuildCards()
    }

    private func rebuildCards() {
        // refresh card labels (localization) — cards are static but re-applying labels is cheap
        let cards = ChannelPanelController.builtins
        for (i, cardView) in cardViews.enumerated() where i < cards.count {
            // find title/desc labels in the card button's stack
            if let button = cardView as? NSButton,
               let row = button.subviews.first as? NSStackView,
               row.arrangedSubviews.count == 2,
               let textStack = row.arrangedSubviews[1] as? NSStackView,
               textStack.arrangedSubviews.count == 2 {
                (textStack.arrangedSubviews[0] as? NSTextField)?.stringValue = L10n.tr(cards[i].titleKey)
                (textStack.arrangedSubviews[1] as? NSTextField)?.stringValue = L10n.tr(cards[i].descKey)
            }
        }
    }

    // MARK: - Persistence

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

    private func loadRefs(for root: String?) {
        currentRoot = root
        refs = []
        guard let root = root else { return }
        let path = (root as NSString).appendingPathComponent(".dsh/channels.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONDecoder().decode(ProjectRefsFile.self, from: data) else {
            return
        }
        refs = file.refs
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
        loadRefs(for: workspacePath?())
        refreshMode()
    }

    func workspaceChanged() {
        loadRefs(for: workspacePath?())
        if mode == .project { projectTable.reloadData() }
    }

    // MARK: - Table (project available channels)

    func numberOfRows(in tableView: NSTableView) -> Int {
        // available channels = global channels (configured) for this project
        return channels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < channels.count else { return nil }
        let c = channels[row]
        let enabledInProject = refs.contains { $0.channelId == c.id }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "\(c.state.badge)  \(c.name)  ·  \(L10n.tr(enabledInProject ? "channel.enabled" : "channel.disabled"))")
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

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < channels.count else { return true }
        // toggle this channel's project enable/disable
        let c = channels[row]
        if let idx = refs.firstIndex(where: { $0.channelId == c.id }) {
            refs.remove(at: idx)
        } else if let root = currentRoot {
            refs.append(ProjectChannelRef(channelId: c.id, workspaceRoot: root))
        }
        saveRefs()
        projectTable.reloadData()
        return false
    }
}

extension ChannelPanelController: NSTableViewDataSource, NSTableViewDelegate {}
