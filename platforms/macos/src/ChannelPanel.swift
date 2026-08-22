import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Channel panel v2 (onboarding cards + wizard + project view)

final class ChannelRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

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

struct ProjectChannelRef: Codable {
    var channelId: String
    var workspaceRoot: String
    var routingConversations: [String] = []
    var routingKeywords: [String] = []
    var routingDefault: Bool = false
}

struct ProjectRefsFile: Codable {
    var version: Int = 1
    var refs: [ProjectChannelRef] = []
}

struct ChannelCard {
    let platform: String
    let symbol: String
    let titleKey: String
    let descKey: String
}

/// A vertical NSStackView that is flipped (y=0 at the top). Used as the
/// scroll documentView so short content stays anchored to the TOP of the
/// content area (a non-flipped, shorter-than-viewport documentView gets
/// dropped to the bottom by NSScrollView on hidden→shown flips).
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class ChannelPanelController: NSObject {

    var onRequestHide: (() -> Void)?
    var workspacePath: (() -> String?)?
    var channelLoginRunner: ((String, @escaping (String?) -> Void, @escaping (Bool) -> Void) -> Void)?

    static let minWidth: CGFloat = 300
    let view = ChannelRootView()

    // header
    private let headerTitle = HeaderLabel()
    private let configButton: CustomIconButton
    private let hideButton: CustomIconButton

    // (28pt toolbar placeholder is created locally in buildUI)

    // content container
    private let contentContainer = DynamicFillView()
    private let onboardingView = NSView()
    private let projectView = NSView()

    // onboarding
    private let onboardingTitle = NSTextField(labelWithString: "")
    private let onboardingHint = NSTextField(wrappingLabelWithString: "")
    private var cardViews: [NSView] = []

    // wizard
    private let wizardView = NSView()
    private let wizardTitle = NSTextField(labelWithString: "")
    private let wizardInfo = NSTextField(wrappingLabelWithString: "")
    private let wizardQRView = NSImageView()
    private let wizardStatus = NSTextField(labelWithString: "")
    private let wizardPrimary: NSButton
    private let wizardSecondary: NSButton
    private var wizardPlatform: String = ""
    private var wizardStep = 0

    // project view — rows of channel + toggle + expandable sessions
    private let projectScroll = NSScrollView()
    private let projectList = FlippedStackView()
    private var projectRows: [ProjectRowView] = []

    // state
    private var channels: [GlobalChannel] = []
    private var refs: [ProjectChannelRef] = []
    private var currentRoot: String?

    private enum Mode { case onboarding, project }
    private var mode: Mode = .onboarding
    private var collapsedChannelIds: Set<String> = []

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
    }

    func refreshTooltips() { updateLabels() }

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



        // toolbar (28pt) — empty placeholder, with a separator below it so the
        // toolbar is visually separated from the content area.
        let toolbar = DynamicFillView()
        toolbar.kind = .window
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        let toolbarSeparator = NSBox()
        toolbarSeparator.boxType = .separator
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarSeparator)
        NSLayoutConstraint.activate([
            toolbarSeparator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarSeparator.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])

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
        view.addSubview(toolbar)
        view.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
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

    // ---- onboarding: full-width uniform cards ----
    private func buildOnboarding() {
        onboardingTitle.translatesAutoresizingMaskIntoConstraints = false
        onboardingTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        onboardingTitle.alignment = .left
        onboardingHint.translatesAutoresizingMaskIntoConstraints = false
        onboardingHint.font = .systemFont(ofSize: 12)
        onboardingHint.textColor = .secondaryLabelColor
        onboardingHint.alignment = .left

        onboardingView.addSubview(onboardingTitle)
        onboardingView.addSubview(onboardingHint)

        // cards: full-width (pure Auto Layout)
        var prev: NSView? = onboardingHint
        for card in ChannelPanelController.builtins {
            let cardView = makeCard(card)
            cardViews.append(cardView)
            onboardingView.addSubview(cardView)
            NSLayoutConstraint.activate([
                cardView.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor, constant: 16),
                cardView.trailingAnchor.constraint(equalTo: onboardingView.trailingAnchor, constant: -16),
                cardView.topAnchor.constraint(equalTo: prev!.bottomAnchor, constant: 12),
            ])
            prev = cardView
        }
        NSLayoutConstraint.activate([
            onboardingTitle.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor, constant: 16),
            onboardingTitle.topAnchor.constraint(equalTo: onboardingView.topAnchor, constant: 16),
            onboardingHint.leadingAnchor.constraint(equalTo: onboardingView.leadingAnchor, constant: 16),
            onboardingHint.topAnchor.constraint(equalTo: onboardingTitle.bottomAnchor, constant: 4),
            onboardingHint.trailingAnchor.constraint(lessThanOrEqualTo: onboardingView.trailingAnchor, constant: -16),
        ])
    }

    private func makeCard(_ card: ChannelCard) -> NSView {
        let cardView = ChannelCardView(card: card)
        cardView.platform = card.platform
        cardView.onTap = { [weak self] in self?.cardTapped(platform: card.platform) }
        cardView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return cardView
    }

    private func cardTapped(platform: String) {
        guard let card = ChannelPanelController.builtins.first(where: { $0.platform == platform }) else { return }
        if card.platform != "weixin-clawbot" { NSSound.beep(); return }
        wizardPlatform = card.platform
        wizardStep = 0
        renderWizard()
    }

    // ---- wizard (prompt → QR scan → done) ----
    private func buildWizard() {
        wizardTitle.translatesAutoresizingMaskIntoConstraints = false
        wizardTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        wizardInfo.translatesAutoresizingMaskIntoConstraints = false
        wizardInfo.font = .systemFont(ofSize: 12)
        wizardInfo.textColor = .secondaryLabelColor
        wizardStatus.translatesAutoresizingMaskIntoConstraints = false
        wizardStatus.font = .systemFont(ofSize: 12)
        wizardStatus.textColor = .labelColor

        wizardQRView.translatesAutoresizingMaskIntoConstraints = false
        wizardQRView.imageScaling = .scaleProportionallyUpOrDown
        wizardQRView.widthAnchor.constraint(equalToConstant: 180).isActive = true
        wizardQRView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        wizardPrimary.translatesAutoresizingMaskIntoConstraints = false
        wizardSecondary.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [wizardPrimary, wizardSecondary])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [wizardTitle, wizardInfo, wizardQRView, wizardStatus, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
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
            wizardStep = 1
            renderWizard()
            startLogin()
        } else if wizardStep == 2 {
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
            wizardQRView.image = nil
            wizardPrimary.title = L10n.tr("channel.wizard.continue")
            wizardPrimary.isEnabled = true
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        } else if wizardStep == 1 {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr("channel.wizard.scanning")
            wizardStatus.stringValue = L10n.tr("channel.wizard.promptTitle")
            wizardPrimary.title = L10n.tr("btn.ok")
            wizardPrimary.isEnabled = false
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        } else {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr("channel.wizard.done")
            wizardStatus.stringValue = ""
            wizardQRView.image = nil
            wizardPrimary.title = L10n.tr("channel.done")
            wizardPrimary.isEnabled = true
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        }
    }

    private func startLogin() {
        let platform = wizardPlatform
        let existing = channels.first(where: { $0.platform == platform })
        let channelId: String
        if let existing = existing {
            channelId = existing.id
        } else {
            let id = "\(platform)-\(UUID().uuidString.prefix(8))"
            channels.append(GlobalChannel(id: id, platform: platform, name: id))
            saveGlobalChannels()
            channelId = id
        }
        guard let runner = channelLoginRunner else {
            wizardStatus.stringValue = L10n.tr("channel.noLoginRunner")
            return
        }
        // onQRUrl: render the QR in-panel (no browser).
        runner(channelId, { [weak self] url in
            DispatchQueue.main.async {
                guard let self = self, let url = url else { return }
                self.wizardQRView.image = ChannelPanelController.qrImage(from: url, size: 180)
            }
        }) { [weak self] ok in
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
        // return to the global-config (onboarding) view, not the project view
        wizardView.isHidden = true
        mode = .onboarding
        onboardingView.isHidden = false
        projectView.isHidden = true
        rebuildCards()
    }

    // ---- project view: channel rows + toggle + expandable sessions ----
    private func buildProject() {
        projectScroll.translatesAutoresizingMaskIntoConstraints = false
        projectScroll.hasVerticalScroller = true
        projectScroll.documentView = projectList

        projectList.orientation = .vertical
        projectList.alignment = .leading
        projectList.spacing = 6
        projectList.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        projectList.translatesAutoresizingMaskIntoConstraints = false

        // Pin the stack to the clip view so rows fill the full content width
        // (otherwise the stack collapses to its intrinsic size in the corner).
        NSLayoutConstraint.activate([
            projectList.leadingAnchor.constraint(equalTo: projectScroll.contentView.leadingAnchor),
            projectList.trailingAnchor.constraint(equalTo: projectScroll.contentView.trailingAnchor),
            projectList.topAnchor.constraint(equalTo: projectScroll.contentView.topAnchor),
            projectList.widthAnchor.constraint(equalTo: projectScroll.contentView.widthAnchor),
        ])

        projectView.addSubview(projectScroll)
        NSLayoutConstraint.activate([
            projectScroll.topAnchor.constraint(equalTo: projectView.topAnchor),
            projectScroll.leadingAnchor.constraint(equalTo: projectView.leadingAnchor),
            projectScroll.trailingAnchor.constraint(equalTo: projectView.trailingAnchor),
            projectScroll.bottomAnchor.constraint(equalTo: projectView.bottomAnchor),
        ])
        projectView.isHidden = true
    }

    private func rebuildProjectRows() {
        for row in projectRows { row.removeFromSuperview() }
        projectRows = []
        for ch in channels {
            let enabled = refs.contains { $0.channelId == ch.id }
            // default: expanded; only collapse when explicitly toggled off
            let expanded = !collapsedChannelIds.contains(ch.id)
            let sessionNames = loadSessionNames(for: ch.id)
            let row = ProjectRowView(channel: ch, enabled: enabled, expanded: expanded, sessionNames: sessionNames)
            row.onToggle = { [weak self] in self?.toggleProjectChannel(ch.id) }
            row.onExpand = { [weak self] in self?.toggleExpand(ch.id) }
            projectList.addArrangedSubview(row)
            // Stretch every row to the full content width (stack `.width`
            // alignment only stretches the widest row — shorter ones would
            // stay at their fitting width, right-aligned). -20 = left+right
            // edgeInsets (10 each).
            row.widthAnchor.constraint(equalTo: projectList.widthAnchor, constant: -20).isActive = true
            projectRows.append(row)
        }
    }

    private func toggleProjectChannel(_ channelId: String) {
        if let idx = refs.firstIndex(where: { $0.channelId == channelId }) {
            refs.remove(at: idx)
        } else if let root = currentRoot {
            refs.append(ProjectChannelRef(channelId: channelId, workspaceRoot: root))
        }
        saveRefs()
        rebuildProjectRows()
    }

    private func toggleExpand(_ channelId: String) {
        if collapsedChannelIds.contains(channelId) {
            collapsedChannelIds.remove(channelId)
        } else {
            collapsedChannelIds.insert(channelId)
        }
        rebuildProjectRows()
    }

    /// Session display names for a channel, read from the project's
    /// `.dsh/channels/<channelId>.sessions.json` (same store the runner uses).
    private func loadSessionNames(for channelId: String) -> [String] {
        guard let root = currentRoot else { return [] }
        let path = (root as NSString).appendingPathComponent(".dsh/channels/\(channelId).sessions.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["sessions"] as? [[String: Any]] else { return [] }
        return arr.compactMap { ($0["name"] as? String) ?? ($0["conversationId"] as? String) }
    }

    // MARK: - Mode switching

    private func refreshMode() {
        let hasConfig = !channels.isEmpty
        mode = hasConfig ? .project : .onboarding
        onboardingView.isHidden = (mode == .project)
        projectView.isHidden = (mode == .onboarding)
        wizardView.isHidden = true
        if mode == .project {
            rebuildProjectRows()
        } else {
            rebuildCards()
        }
    }

    private func configButtonTapped() {
        // Toggle between project view and global-config (onboarding) view.
        if wizardView.isHidden == false { finishWizard() }
        if mode == .onboarding {
            // already showing config → return to project view (if any config)
            refreshMode()
        } else {
            // show the global-config (onboarding) view
            mode = .onboarding
            onboardingView.isHidden = false
            projectView.isHidden = true
            wizardView.isHidden = true
            rebuildCards()
        }
    }

    private func rebuildCards() {
        let cards = ChannelPanelController.builtins
        for (i, cardView) in cardViews.enumerated() where i < cards.count {
            guard let cv = cardView as? ChannelCardView else { continue }
            cv.title = L10n.tr(cards[i].titleKey)
            cv.desc = L10n.tr(cards[i].descKey)
            let channel = channels.first { $0.platform == cards[i].platform }
            let st = channel.map { liveState(for: $0.id) } ?? .disconnected
            cv.setState(st, configured: channel != nil)
        }
    }

    /// Read the channel runner's live connection state from
    /// ~/.dsh/channels/<channelId>.state.json. Called when the global-config view
    /// is opened (no polling).
    private func liveState(for channelId: String) -> GlobalChannel.State {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".dsh/channels")
        let p = (dir as NSString).appendingPathComponent(channelId + ".state.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = json["state"] as? String else { return .disconnected }
        return GlobalChannel.State(rawValue: s) ?? .disconnected
    }

    // MARK: - QR image (in-panel, no browser)

    /// Generate an NSImage QR code for a URL using the system CIQRCodeGenerator.
    static func qrImage(from string: String, size: CGFloat) -> NSImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Persistence

    private func loadGlobalChannels() {
        if let data = UserDefaults.standard.data(forKey: "channel.global.list"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            channels = arr.compactMap { dict in
                guard let id = dict["id"] as? String, let platform = dict["platform"] as? String else { return nil }
                // skip stale bug records whose id is the literal interpolation text
                if id.contains("(") || id.contains(")") { return nil }
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
        if mode == .project { rebuildProjectRows() }
    }
}

/// A project-view row: full-width channel name (left) + on/off switch (right,
/// green when on, gray when off) + an expandable sessions list. Sessions are
/// shown by default and collapse when the title row is clicked again.
final class ProjectRowView: NSView {
    var onToggle: (() -> Void)?
    var onExpand: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let switchControl = NSSwitch()
    private let sessionsStack = NSStackView()

    init(channel: GlobalChannel, enabled: Bool, expanded: Bool, sessionNames: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor

        // left: channel name on a full-width line (truncates to fit)
        titleLabel.stringValue = channel.name
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // right: real on/off switch — system green when on, gray when off
        switchControl.controlSize = .small
        switchControl.target = self
        switchControl.action = #selector(toggleTapped(_:))
        switchControl.state = enabled ? .on : .off

        let topRow = NSStackView(views: [titleLabel, NSView(), switchControl])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topRow)
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])

        // sessions area: header "会话 (N)" + a session row per entry
        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 4
        sessionsStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
        sessionsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sessionsStack)
        NSLayoutConstraint.activate([
            sessionsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            sessionsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessionsStack.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 2),
            sessionsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let header = NSTextField(labelWithString: L10n.tr("channel.sessions") + " (\(sessionNames.count))")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        sessionsStack.addArrangedSubview(header)

        if sessionNames.isEmpty {
            let empty = NSTextField(labelWithString: L10n.tr("channel.noSessions"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            sessionsStack.addArrangedSubview(empty)
        } else {
            for name in sessionNames {
                let item = NSTextField(labelWithString: "•  " + name)
                item.font = .systemFont(ofSize: 11)
                item.textColor = .secondaryLabelColor
                item.lineBreakMode = .byTruncatingMiddle
                sessionsStack.addArrangedSubview(item)
            }
        }
        sessionsStack.isHidden = !expanded

        // Clicking the channel name (which fills the whole line up to the
        // switch) toggles expand/collapse. Kept off the switch so the switch
        // keeps its own toggle action (a row-wide gesture would swallow it).
        let click = NSClickGestureRecognizer(target: self, action: #selector(expandTapped(_:)))
        titleLabel.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleTapped(_ sender: Any) { onToggle?() }

    @objc private func expandTapped(_ gesture: NSClickGestureRecognizer) {
        onExpand?()
    }
}

/// A full-width channel card: SF Symbol icon + title/desc on the left,
/// configuration status dot on the right (gray = unconfigured, green = configured).
/// Background follows the appearance (light in light mode, dark in dark mode).
final class ChannelCardView: NSView {
    var platform: String = ""
    var title: String { get { titleLabel.stringValue } set { titleLabel.stringValue = newValue } }
    var desc: String { get { descLabel.stringValue } set { descLabel.stringValue = newValue } }
    var onTap: (() -> Void)?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let statusDot = NSView()

    init(card: ChannelCard) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        if let img = NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil) {
            iconView.image = img
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        titleLabel.stringValue = L10n.tr(card.titleKey)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.stringValue = L10n.tr(card.descKey)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconView, textStack, spacer, statusDot])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(click)
        setState(.disconnected, configured: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// State-colored status dot: gray = unconfigured/disconnected, green = connected,
    /// orange = reconnecting, red = auth-expired, blue = connecting. Read on open
    /// (no polling).
    func setState(_ state: GlobalChannel.State, configured: Bool) {
        let color: NSColor
        if !configured {
            color = .systemGray
        } else {
            switch state {
            case .connected: color = .systemGreen
            case .reconnecting: color = .systemOrange
            case .authExpired: color = .systemRed
            case .connecting: color = .systemBlue
            case .disconnected: color = .systemGray
            }
        }
        statusDot.layer?.backgroundColor = color.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // appearance-aware card background (light in light, dark in dark)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = dark ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        // subtle border so the card reads on the panel background
        let border = dark ? NSColor(calibratedWhite: 0.35, alpha: 0.6) : NSColor(calibratedWhite: 0.8, alpha: 0.8)
        border.setStroke()
        let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        b.lineWidth = 1
        b.stroke()
    }

    @objc private func tapped(_ sender: Any) { onTap?() }
}