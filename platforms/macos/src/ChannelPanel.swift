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

// Legacy project-refs file — kept only to read it for one-time migration to the
// global workspaces.json association (docs/channel-project-switch.md §5).
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
    /// Unbind a channel: stop its runner and clear its local config (wired to main.swift).
    var channelUnbind: ((String) -> Void)?
    /// Open the given dsh session in dsh web (panel → web session link).
    var onOpenSession: ((String) -> Void)?

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
    private var currentRoot: String?

    private enum Mode { case onboarding, project }
    private var mode: Mode = .onboarding
    private var collapsedChannelIds: Set<String> = []
    private var collapsedSessionIds: Set<String> = []
    // live refresh (docs/channel-status.md §3.x): a lightweight repeating timer
    // re-reads the global channel store while in project mode and rebuilds the
    // project view only when the current project's data actually changed.
    private var refreshTimer: Timer?
    private var projectViewSignature = ""

    static let builtins: [ChannelCard] = [
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

    deinit { stopLiveRefresh() }

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
        cardView.onUnbind = { [weak self] in self?.unbindChannel(platform: card.platform) }
        cardView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return cardView
    }

    /// Unbind a channel after confirmation: clear UserDefaults entry, stop the
    /// runner and remove its local channel files (via main.swift).
    private func unbindChannel(platform: String) {
        guard let ch = channels.first(where: { $0.platform == platform }) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("channel.unbind.confirmTitle")
        alert.informativeText = L10n.tr("channel.unbind.confirmBody")
        alert.addButton(withTitle: L10n.tr("btn.ok"))
        alert.addButton(withTitle: L10n.tr("btn.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            channels.removeAll { $0.id == ch.id }
            saveGlobalChannels()
            channelUnbind?(ch.id)
            rebuildCards()
        }
    }

    private func cardTapped(platform: String) {
        guard let card = ChannelPanelController.builtins.first(where: { $0.platform == platform }) else { return }
        // weixin + dingtalk use the in-panel QR wizard; feishu is still planned.
        if card.platform != "weixin-clawbot" && card.platform != "dingtalk" { NSSound.beep(); return }
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

    /// Platform-specific wizard string: dingtalk uses "….<base>.dingtalk" variants;
    /// other platforms share the base string (which mentions WeChat).
    private func wizardL10n(_ base: String) -> String {
        return wizardPlatform == "dingtalk" ? base + ".dingtalk" : base
    }

    private func renderWizard() {
        wizardView.isHidden = false
        onboardingView.isHidden = true
        projectView.isHidden = true
        let card = ChannelPanelController.builtins.first { $0.platform == wizardPlatform }
        let platformName = card.map { L10n.tr($0.titleKey) } ?? wizardPlatform
        if wizardStep == 0 {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr(wizardL10n("channel.wizard.promptInfo"))
            wizardStatus.stringValue = L10n.tr(wizardL10n("channel.wizard.promptTitle"))
            wizardQRView.image = nil
            wizardPrimary.title = L10n.tr("channel.wizard.continue")
            wizardPrimary.isEnabled = true
            wizardSecondary.title = L10n.tr("channel.wizard.back")
        } else if wizardStep == 1 {
            wizardTitle.stringValue = platformName
            wizardInfo.stringValue = L10n.tr("channel.wizard.scanning")
            wizardStatus.stringValue = L10n.tr(wizardL10n("channel.wizard.promptTitle"))
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
            let enabled = isChannelEnabled(ch.id)
            let sessions = enabled ? loadSessions(for: ch.id) : []
            // collapsedSessionIds is the SINGLE expansion state: web follows write
            // into it (setActiveSession) and manual toggles read/write it, so the
            // two never fight. Channels stay expanded when enabled so sessions
            // remain visible even when every row is collapsed.
            let expanded = enabled && !collapsedChannelIds.contains(ch.id)
            let row = ProjectRowView(channel: ch, enabled: enabled, expanded: expanded, sessions: sessions,
                                     collapsedSessionIds: collapsedSessionIds)
            row.onToggle = { [weak self] in self?.toggleProjectChannel(ch.id) }
            row.onExpand = { [weak self] in self?.toggleExpand(ch.id) }
            row.onToggleSession = { [weak self] sessionId in self?.toggleSession(sessionId) }
            row.onOpenSession = { [weak self] sessionId in self?.onOpenSession?(sessionId) }
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
        setChannelEnabled(channelId, !isChannelEnabled(channelId))
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

    /// Sessions for a channel that belong to the CURRENT project, each with its
    /// message history — read from the GLOBAL channel-scoped store (docs/channel-storage.md, D).
    private func loadSessions(for channelId: String) -> [ChannelSessionVM] {
        guard let root = currentRoot else { return [] }
        return ChannelStoreReader.loadSessions(channelId: channelId, projectRoot: root)
    }

    private func toggleSession(_ sessionId: String) {
        // Clicking a session row: collapse every other session, expand this one
        // (exclusive expansion), then locate it in dsh web via onOpen. Doing the
        // collapse here (not relying on the web follow) gives a deterministic
        // "one expanded at a time" view.
        collapsedSessionIds = allSessionIds().subtracting([sessionId])
        rebuildProjectRows()
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

    private func loadProjectBindings(for root: String?) {
        currentRoot = root
        migrateLegacyRefsIfNeeded(root)
    }

    /// One-time migration from the legacy per-project .dsh/channels.json refs:
    /// seed the global workspaces.json association for each referenced channel so
    /// existing switches aren't lost (docs/channel-project-switch.md §5).
    private func migrateLegacyRefsIfNeeded(_ root: String?) {
        guard let root = root else { return }
        let path = (root as NSString).appendingPathComponent(".dsh/channels.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONDecoder().decode(ProjectRefsFile.self, from: data) else { return }
        for ref in file.refs where ref.workspaceRoot == root {
            // One-time seed: only migrate when the channel has no global association
            // file yet. After the first write the global file is authoritative, so a
            // user turning the switch OFF stays off (migration must not re-enable).
            if !FileManager.default.fileExists(atPath: channelWorkspacesPath(ref.channelId)) {
                setChannelEnabled(ref.channelId, true)
            }
        }
    }

    // MARK: - Global project association (the "project switch") — stored in
    // ~/.dsh/channels/<channelId>.workspaces.json; a project root present there
    // = that workspace has this channel enabled (docs/channel-project-switch.md).

    private func channelWorkspacesPath(_ channelId: String) -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".dsh/channels")
        return (dir as NSString).appendingPathComponent(channelId + ".workspaces.json")
    }

    /// Project roots that currently have this channel enabled (global store).
    private func enabledRoots(for channelId: String) -> [String] {
        let p = channelWorkspacesPath(channelId)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json.values.compactMap { $0 as? String }
    }

    /// Whether the CURRENT project has this channel enabled.
    private func isChannelEnabled(_ channelId: String) -> Bool {
        guard let root = currentRoot else { return false }
        return enabledRoots(for: channelId).contains(root)
    }

    /// Enable/disable this channel for the CURRENT project (project switch).
    private func setChannelEnabled(_ channelId: String, _ enabled: Bool) {
        guard let root = currentRoot else { return }
        var roots = Set(enabledRoots(for: channelId))
        if enabled { roots.insert(root) } else { roots.remove(root) }
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".dsh/channels")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var dict: [String: Any] = [:]
        for r in roots {
            dict[ChannelStoreReader.workspaceKey(for: r)] = r
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: URL(fileURLWithPath: channelWorkspacesPath(channelId)))
        }
    }

    func ensureLoaded() {
        loadGlobalChannels()
        loadProjectBindings(for: workspacePath?())
        refreshMode()
        startLiveRefresh()
    }

    func workspaceChanged() {
        loadProjectBindings(for: workspacePath?())
        if mode == .project { rebuildProjectRows() }
    }

    /// Every session id across the current project's enabled channels — used to
    /// "expand one, collapse the rest" for both manual clicks and web follows.
    private func allSessionIds() -> Set<String> {
        var all: Set<String> = []
        for ch in channels {
            for s in loadSessions(for: ch.id) { all.insert(s.sessionId) }
        }
        return all
    }

    /// Web → panel session link: follow the session the user is viewing in dsh
    /// web. Writes the follow target directly into collapsedSessionIds so the
    /// panel uses ONE expansion state (collapsedSessionIds) — the active session
    /// expands, everything else collapses; a session that matches nothing (or
    /// nil) collapses every row. This keeps manual toggles and web follows from
    /// fighting each other.
    func setActiveSession(_ sessionId: String?) {
        let all = allSessionIds()
        if let sid = sessionId, all.contains(sid) {
            collapsedSessionIds = all.subtracting([sid])
        } else {
            collapsedSessionIds = all
        }
        if mode == .project { rebuildProjectRows() }
    }

    // MARK: - Live refresh

    /// Start the lightweight periodic refresh (approach A: content signature +
    /// rebuild on change). Started when the panel loads; invalidated on deinit.
    private func startLiveRefresh() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshProjectIfChanged()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Re-read the current project's channel data and rebuild the project view only
    /// when something actually changed (a new reply / new session / rename), so the
    /// view stays live after conversation replies without rebuilding on every tick.
    private func refreshProjectIfChanged() {
        guard mode == .project, currentRoot != nil else { return }
        let sig = computeProjectSignature()
        guard sig != projectViewSignature else { return }
        projectViewSignature = sig
        rebuildProjectRows()
    }

    /// A cheap content signature over exactly what the project view displays, so a
    /// rebuild fires only when the current project's sessions/messages change.
    private func computeProjectSignature() -> String {
        guard let root = currentRoot else { return "" }
        var parts: [String] = []
        for ch in channels where isChannelEnabled(ch.id) {
            for s in ChannelStoreReader.loadSessions(channelId: ch.id, projectRoot: root) {
                parts.append("\(ch.id)|\(s.sessionId)|\(Int(s.updatedAt))|\(s.name)|\(s.conversationId)|\(s.messages.count)")
                if let last = s.messages.last {
                    parts.append("\(Int(last.ts))|\(last.dir)|\(last.text)")
                }
            }
        }
        return parts.joined(separator: "\n")
    }
}

/// A project-view row: a full-width channel header block (platform name + id +
/// icon, a sessions-count description, and an on/off switch) plus an expandable
/// list of session blocks. Sessions are shown by default and collapse when the
/// header or a session title is clicked again.
final class ProjectRowView: NSView {
    var onToggle: (() -> Void)?
    var onExpand: (() -> Void)?
    var onToggleSession: ((String) -> Void)?
    var onOpenSession: ((String) -> Void)?

    init(channel: GlobalChannel, enabled: Bool, expanded: Bool, sessions: [ChannelSessionVM], collapsedSessionIds: Set<String>) {
        super.init(frame: .zero)

        // ---- channel header block (one full-width unit with its own bg) ----
        let header = ChannelHeaderBlock(channel: channel, enabled: enabled, sessionCount: sessions.count)
        header.onToggle = { [weak self] in self?.onToggle?() }
        header.onExpand = { [weak self] in self?.onExpand?() }
        header.translatesAutoresizingMaskIntoConstraints = false

        // ---- session blocks (each in its own bg) ----
        let sessionsStack = NSStackView()
        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 6
        sessionsStack.translatesAutoresizingMaskIntoConstraints = false

        if sessions.isEmpty {
            let empty = NSTextField(labelWithString: L10n.tr("channel.noSessions"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            sessionsStack.addArrangedSubview(empty)
        } else {
            for session in sessions {
                // collapsedSessionIds is the single expansion state: a session
                // expands unless it is in the collapsed set.
                let showMessages = !collapsedSessionIds.contains(session.sessionId)
                let row = ChannelSessionRow(session: session, showMessages: showMessages)
                row.onTap = { [weak self] in self?.onToggleSession?(session.sessionId) }
                row.onOpen = { [weak self] in self?.onOpenSession?(session.sessionId) }
                sessionsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sessionsStack.widthAnchor).isActive = true
            }
        }
        sessionsStack.isHidden = !expanded

        // ---- outer vertical stack: header on top, sessions below ----
        let outer = NSStackView(views: [header, sessionsStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: outer.widthAnchor),
            sessionsStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The channel header: one full-width block containing two lines — a platform
/// icon + "平台名 (channelId)" (bigger, clickable to expand) and a
/// "会话 (N)" description, with the on/off switch on the right.
final class ChannelHeaderBlock: RoundedBlockView {
    var onToggle: (() -> Void)?
    var onExpand: (() -> Void)?

    init(channel: GlobalChannel, enabled: Bool, sessionCount: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        radius = 8
        lightFill = NSColor(calibratedRed: 0.88, green: 0.92, blue: 1.0, alpha: 1)
        darkFill = NSColor(calibratedRed: 0.17, green: 0.21, blue: 0.30, alpha: 1)
        lightBorder = NSColor(calibratedWhite: 0.7, alpha: 0.6)
        darkBorder = NSColor(calibratedWhite: 0.42, alpha: 0.5)

        // platform icon (SF Symbol)
        let card = ChannelPanelController.builtins.first { $0.platform == channel.platform }
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: card?.symbol ?? "bubble.left.and.bubble.right", accessibilityDescription: nil) {
            iconView.image = img
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // line 1: "平台名 (channelId)" — bigger font, clickable to expand
        let platformName = card.map { L10n.tr($0.titleKey) } ?? channel.platform
        let titleLabel = NSTextField(labelWithString: "\(platformName) (\(channel.id))")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // right: on/off switch
        let switchControl = NSSwitch()
        switchControl.controlSize = .small
        switchControl.state = enabled ? .on : .off
        switchControl.target = self
        switchControl.action = #selector(toggleTapped(_:))
        switchControl.translatesAutoresizingMaskIntoConstraints = false

        // flexible spacer pushes the switch to the far right
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [iconView, titleLabel, spacer, switchControl])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // line 2: sessions-count description
        let infoLabel = NSTextField(labelWithString: enabled ? L10n.tr("channel.sessions") + " (\(sessionCount))" : L10n.tr("channel.notEnabledInProject"))
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topRow)
        addSubview(infoLabel)
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            infoLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 3),
            infoLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        // clicking the platform name toggles the whole session list
        let click = NSClickGestureRecognizer(target: self, action: #selector(expandTapped(_:)))
        titleLabel.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleTapped(_ sender: Any) { onToggle?() }
    @objc private func expandTapped(_ gesture: NSClickGestureRecognizer) { onExpand?() }
}

/// One expandable session block: a darker title bar (bigger title + bigger
/// expand/collapse arrow, click to collapse/expand) above the message content,
/// which is rendered as chat bubbles — incoming (in) on the RIGHT, agent
/// replies (out) on the LEFT.
final class ChannelSessionRow: RoundedBlockView {
    var onTap: (() -> Void)?
    /// Panel → web session link: open this session in dsh web. Fired together
    /// with onTap so a single click both expands/collapses and locates the
    /// session in dsh web.
    var onOpen: (() -> Void)?

    init(session: ChannelSessionVM, showMessages: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        radius = 8
        lightFill = NSColor(calibratedWhite: 0.97, alpha: 1)
        darkFill = NSColor(calibratedWhite: 0.235, alpha: 1)
        lightBorder = NSColor(calibratedWhite: 0.78, alpha: 0.7)
        darkBorder = NSColor(calibratedWhite: 0.38, alpha: 0.5)

        let name = session.name.isEmpty ? session.sessionId : session.name

        // darker, clickable title bar (bigger font + bigger arrow)
        let titleBar = SessionTitleBar(title: name, expanded: showMessages)
        // One click on the session row: expand/collapse AND locate in dsh web.
        titleBar.onTap = { [weak self] in
            self?.onTap?()
            self?.onOpen?()
        }
        titleBar.translatesAutoresizingMaskIntoConstraints = false

        // message content below the title bar
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        if showMessages {
            if session.messages.isEmpty {
                let empty = NSTextField(labelWithString: L10n.tr("channel.noMessages"))
                empty.font = .systemFont(ofSize: 11)
                empty.textColor = .tertiaryLabelColor
                empty.translatesAutoresizingMaskIntoConstraints = false
                contentStack.addArrangedSubview(empty)
            } else {
                for m in session.messages {
                    let bubbleRow = makeBubbleRow(text: m.text, isIn: m.dir == "in")
                    contentStack.addArrangedSubview(bubbleRow)
                    bubbleRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
                }
            }
        }
        contentStack.isHidden = !showMessages

        addSubview(titleBar)
        addSubview(contentStack)

        if showMessages {
            // expanded: title bar on top (only top corners rounded), content below
            NSLayoutConstraint.activate([
                titleBar.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                contentStack.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 8),
                contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        } else {
            // collapsed: the title bar fills the whole block (all corners rounded)
            NSLayoutConstraint.activate([
                titleBar.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                titleBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeBubbleRow(text: String, isIn: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let bubble = MessageBubble(text: text, isIn: isIn)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        let maxFraction: CGFloat = isIn ? 0.5 : 0.9
        if isIn {
            // user question → right-aligned, up to 50% of the content width
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor).isActive = true
        } else {
            // agent reply → left-aligned, up to 90% of the content width
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: maxFraction).isActive = true
        return row
    }
}

/// The clickable title row of a session: a darker background band holding a
/// bigger title and a bigger expand/collapse chevron. When the session is
/// collapsed the band fills the whole block (all corners rounded); when
/// expanded only the top corners are rounded and the band sits above the
/// message content.
final class SessionTitleBar: NSView {
    var onTap: (() -> Void)?
    private let expanded: Bool

    init(title: String, expanded: Bool) {
        self.expanded = expanded
        super.init(frame: .zero)

        // bigger chevron arrow
        let arrow = NSImageView()
        let symbolName = expanded ? "chevron.down" : "chevron.right"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            arrow.image = img
            arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        }
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.widthAnchor.constraint(equalToConstant: 16).isActive = true
        arrow.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [arrow, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped(_ gesture: NSClickGestureRecognizer) { onTap?() }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let band = dark ? NSColor(calibratedWhite: 0.32, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        band.setFill()
        roundedCornersPath(bounds, radius: 8, roundTop: true, roundBottom: !expanded).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A bezier path for a rectangle with rounded top corners, bottom corners, or
/// both — used to draw the session title band.
private func roundedCornersPath(_ rect: NSRect, radius: CGFloat, roundTop: Bool, roundBottom: Bool) -> NSBezierPath {
    let p = NSBezierPath()
    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY
    let r = radius
    let tl: CGFloat = roundTop ? r : 0
    let tr: CGFloat = roundTop ? r : 0
    let bl: CGFloat = roundBottom ? r : 0
    let br: CGFloat = roundBottom ? r : 0

    p.move(to: NSPoint(x: minX + bl, y: minY))
    p.line(to: NSPoint(x: maxX - br, y: minY))
    if br > 0 {
        p.appendArc(withCenter: NSPoint(x: maxX - br, y: minY + br), radius: br, startAngle: 270, endAngle: 360, clockwise: false)
    }
    p.line(to: NSPoint(x: maxX, y: maxY - tr))
    if tr > 0 {
        p.appendArc(withCenter: NSPoint(x: maxX - tr, y: maxY - tr), radius: tr, startAngle: 0, endAngle: 90, clockwise: false)
    }
    p.line(to: NSPoint(x: minX + tl, y: maxY))
    if tl > 0 {
        p.appendArc(withCenter: NSPoint(x: minX + tl, y: maxY - tl), radius: tl, startAngle: 90, endAngle: 180, clockwise: false)
    }
    p.line(to: NSPoint(x: minX, y: minY + bl))
    if bl > 0 {
        p.appendArc(withCenter: NSPoint(x: minX + bl, y: minY + bl), radius: bl, startAngle: 180, endAngle: 270, clockwise: false)
    }
    p.close()
    return p
}

/// A rounded, appearance-aware background block used for the channel header
/// and session containers.
class RoundedBlockView: NSView {
    var lightFill: NSColor = .white
    var darkFill: NSColor = .black
    var lightBorder: NSColor = .clear
    var darkBorder: NSColor = .clear
    var radius: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? darkFill : lightFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let border = dark ? darkBorder : lightBorder
        if border.alphaComponent > 0 {
            border.setStroke()
            let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            b.lineWidth = 1
            b.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A single chat bubble. Incoming (in) messages use a blue accent bubble shown
/// on the right; agent replies (out) use a neutral bubble shown on the left.
final class MessageBubble: NSView {
    private let label: NSTextField
    private let isIn: Bool

    init(text: String, isIn: Bool) {
        self.isIn = isIn
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.preferredMaxLayoutWidth = label.frame.width
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg: NSColor
        if isIn {
            bg = dark ? NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.55, alpha: 1)
                      : NSColor(calibratedRed: 0.84, green: 0.91, blue: 1.0, alpha: 1)
        } else {
            bg = dark ? NSColor(calibratedWhite: 0.32, alpha: 1)
                      : NSColor(calibratedWhite: 0.93, alpha: 1)
        }
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
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
    var onUnbind: (() -> Void)?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let statusDot = NSView()
    private let unbindButton = CustomIconButton(glyph: .symbol("xmark.circle"), tooltip: "")

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

        unbindButton.toolTip = L10n.tr("channel.unbind")
        unbindButton.isHidden = true
        unbindButton.onAction = { [weak self] in self?.onUnbind?() }

        let row = NSStackView(views: [iconView, textStack, spacer, unbindButton, statusDot])
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
        // Hover tooltip so the status is not conveyed by color alone.
        statusDot.toolTip = statusTooltip(state, configured: configured)
        unbindButton.isHidden = !configured
    }

    /// Localized hover text for the status dot (color is not the only signal).
    private func statusTooltip(_ state: GlobalChannel.State, configured: Bool) -> String {
        if !configured { return L10n.tr("channel.state.unconfigured") }
        let key: String
        switch state {
        case .connected: key = "channel.state.connected"
        case .connecting: key = "channel.state.connecting"
        case .reconnecting: key = "channel.state.reconnecting"
        case .authExpired: key = "channel.state.authExpired"
        case .disconnected: key = "channel.state.disconnected"
        }
        return L10n.tr(key)
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