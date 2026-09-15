//
//  SkillsPanel.swift — the Skills manager panel (right-side slot).
//
//  Two tabs: "Installed" (scan the four dsh roots, badge each skill with its
//  level, toggle the two invocation flags, remove user/project skills) and
//  "Available" (a configurable registry: its catalog, or keyword search).
//
//  Model layer: SkillsCore.swift (roots/frontmatter/store) and
//  SkillSources.swift (addresses/registries/fetch/install).
//

import AppKit

final class SkillsRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

/// Card background shared by both lists: a rounded fill + hairline border
/// resolved per appearance at draw time (a fixed CGColor layer background would
/// freeze the light/dark resolution — same reason DynamicFillView exists).
class SkillCardView: NSView {

    override var isOpaque: Bool { false }

    /// Accent-tinted card, used for the registry tab's selected state.
    var highlighted = false { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor
        let border: NSColor
        if highlighted {
            fill = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.22 : 0.12)
            border = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.55 : 0.45)
        } else {
            fill = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 1.0, alpha: 1)
            border = dark ? NSColor(calibratedWhite: 0.38, alpha: 0.7) : NSColor(calibratedWhite: 0.82, alpha: 1)
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}


/// One flat tab: borderless text label with an accent underline when selected
/// (no bezel, no dropdown look). Used by both Skills toolbars.
final class SkillTabItemView: NSView {

    var onTap: (() -> Void)?

    private(set) var title: String
    var isSelected = false { didSet { needsDisplay = true } }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ value: String) {
        title = value
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(size.width) + 18, height: 24)
    }

    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isHovered, !isSelected {
            (dark ? NSColor(calibratedWhite: 1, alpha: 0.06) : NSColor(calibratedWhite: 0, alpha: 0.05)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = isSelected
            ? .controlAccentColor
            : (dark ? NSColor(calibratedWhite: 0.78, alpha: 1) : NSColor(calibratedWhite: 0.35, alpha: 1))
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2 + 1),
                                 withAttributes: attrs)
        if isSelected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: NSRect(x: 4, y: 0, width: max(0, bounds.width - 8), height: 2)).fill()
        }
    }
}

/// A row of flat tabs (the registry selector and the level filter). Replaces the
/// dropdowns: every choice is visible at once.
final class SkillTabStrip: NSView {

    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var items: [SkillTabItemView] = []
    private let row = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setItems(_ titles: [String], selected: Int) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        items = []
        for (index, title) in titles.enumerated() {
            let item = SkillTabItemView(title: title)
            item.onTap = { [weak self] in self?.select(index) }
            row.addArrangedSubview(item)
            items.append(item)
        }
        selectedIndex = max(0, min(selected, max(0, titles.count - 1)))
        applySelection()
    }

    func select(_ index: Int, notify: Bool = true) {
        guard index >= 0, index < items.count else { return }
        selectedIndex = index
        applySelection()
        if notify { onSelect?(index) }
    }

    private func applySelection() {
        for (index, item) in items.enumerated() { item.isSelected = index == selectedIndex }
    }
}

/// One card of the installed list: name, level badge, path, the two invocation
/// toggles and the row actions.
final class SkillRowView: SkillCardView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let shadowLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let userToggle: NSButton
    private let modelToggle: NSButton
    private let removeButton: NSButton
    private let detailButton: NSButton
    private let revealButton: NSButton

    var onToggleUser: ((Bool) -> Void)?
    var onToggleModel: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onDetail: (() -> Void)?

    private var skill: InstalledSkill

    init(skill: InstalledSkill) {
        self.skill = skill
        userToggle = NSButton(checkboxWithTitle: L10n.tr("skills.toggle.userInvocable"), target: nil, action: nil)
        modelToggle = NSButton(checkboxWithTitle: L10n.tr("skills.toggle.modelInvocable"), target: nil, action: nil)
        removeButton = NSButton(title: L10n.tr("skills.remove"), target: nil, action: nil)
        detailButton = NSButton(title: L10n.tr("skills.detail"), target: nil, action: nil)
        revealButton = NSButton(title: L10n.tr("skills.reveal"), target: nil, action: nil)
        super.init(frame: .zero)
        build()
        update(skill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func style(_ b: NSButton) {
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = NSFont.systemFont(ofSize: 11)
        b.target = self
    }

    private func build() {
        for b in [removeButton, detailButton, revealButton] { style(b) }
        removeButton.action = #selector(removeTapped)
        detailButton.action = #selector(detailTapped)
        revealButton.action = #selector(revealTapped)
        for t in [userToggle, modelToggle] {
            t.controlSize = .small
            t.font = NSFont.systemFont(ofSize: 11)
            t.target = self
        }
        userToggle.action = #selector(userToggled)
        modelToggle.action = #selector(modelToggled)

        nameLabel.font = NSFont.boldSystemFont(ofSize: 12)
        badgeLabel.font = NSFont.systemFont(ofSize: 10)
        badgeLabel.textColor = .secondaryLabelColor
        shadowLabel.font = NSFont.systemFont(ofSize: 10)
        shadowLabel.textColor = .tertiaryLabelColor
        shadowLabel.stringValue = L10n.tr("skills.badge.shadowed")
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 2
        pathLabel.font = NSFont.systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor

        let titleRow = NSStackView(views: [nameLabel, badgeLabel, shadowLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .firstBaseline

        let actions = NSStackView(views: [userToggle, modelToggle, detailButton, revealButton, removeButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        let stack = NSStackView(views: [titleRow, descLabel, pathLabel, hintLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func update(_ skill: InstalledSkill) {
        self.skill = skill
        nameLabel.stringValue = skill.name
        badgeLabel.stringValue = L10n.tr(skill.level.badgeKey)
        shadowLabel.isHidden = skill.shadowedBy == nil
        descLabel.stringValue = skill.description
        pathLabel.stringValue = skill.skillFile
        pathLabel.toolTip = skill.skillFile
        userToggle.state = skill.userInvocable ? .on : .off
        modelToggle.state = skill.modelInvocable ? .on : .off
        userToggle.isEnabled = skill.canEditInvocation
        modelToggle.isEnabled = skill.canEditInvocation
        userToggle.toolTip = L10n.tr("skills.toggle.hintKey")
        modelToggle.toolTip = L10n.tr("skills.toggle.hintKey")
        removeButton.isHidden = !skill.canRemove
        var hints: [String] = []
        if skill.level == .builtin { hints.append(L10n.tr("skills.builtinLocked")) }
        if skill.level == .shared { hints.append(L10n.tr("skills.sharedManaged")) }
        hintLabel.stringValue = hints.joined(separator: " · ")
        hintLabel.isHidden = hints.isEmpty
    }

    @objc private func userToggled() { onToggleUser?(userToggle.state == .on) }
    @objc private func modelToggled() { onToggleModel?(modelToggle.state == .on) }
    @objc private func removeTapped() { onRemove?() }
    @objc private func detailTapped() { onDetail?() }
    @objc private func revealTapped() { onReveal?() }
}

/// One card of the available (registry) list: a checkbox, name, source, installs.
final class SkillCandidateRowView: SkillCardView {

    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton()
    private let detailButton = NSButton()

    var onToggle: ((Bool) -> Void)?
    var onInstall: (() -> Void)?
    var onDetail: (() -> Void)?

    init(candidate: SkillCandidate, selected: Bool) {
        super.init(frame: .zero)
        check.state = selected ? .on : .off
        check.target = self
        check.action = #selector(toggled)
        installButton.title = L10n.tr("skills.install")
        installButton.bezelStyle = .rounded
        installButton.controlSize = .small
        installButton.font = NSFont.systemFont(ofSize: 11)
        installButton.target = self
        installButton.action = #selector(installTapped)

        detailButton.title = L10n.tr("skills.detail")
        detailButton.bezelStyle = .rounded
        detailButton.controlSize = .small
        detailButton.font = NSFont.systemFont(ofSize: 11)
        detailButton.target = self
        detailButton.action = #selector(detailTapped)
        nameLabel.font = NSFont.boldSystemFont(ofSize: 12)
        nameLabel.stringValue = candidate.name
        var meta = candidate.sourceLabel
        if let installs = candidate.installs, installs > 0 {
            meta += " · " + SkillsPanelController.formatInstalls(installs)
        }
        metaLabel.font = NSFont.systemFont(ofSize: 10)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.stringValue = meta
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 2
        descLabel.stringValue = candidate.description

        let titleRow = NSStackView(views: [check, nameLabel, NSView(), detailButton, installButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY
        let stack = NSStackView(views: [titleRow, metaLabel, descLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggled() { onToggle?(check.state == .on) }
    @objc private func installTapped() { onInstall?() }
    @objc private func detailTapped() { onDetail?() }
}


/// One registry card on the registry-management page: name, what it can do
/// (search / catalog), the URLs, plus enable + delete.
final class RegistryCardView: SkillCardView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let searchLabel = NSTextField(labelWithString: "")
    private let catalogLabel = NSTextField(labelWithString: "")
    private let enabledToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let deleteButton = NSButton()

    var onToggleEnabled: ((Bool) -> Void)?
    var onDelete: (() -> Void)?

    init(entry: SkillRegistryRecord) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = entry.label
        titleLabel.font = NSFont.boldSystemFont(ofSize: 12)

        kindLabel.stringValue = L10n.tr(entry.catalog.labelKey)
        kindLabel.font = NSFont.systemFont(ofSize: 10)
        kindLabel.textColor = .secondaryLabelColor

        searchLabel.font = NSFont.systemFont(ofSize: 10)
        searchLabel.textColor = .tertiaryLabelColor
        searchLabel.lineBreakMode = .byTruncatingMiddle
        searchLabel.stringValue = entry.searchURL ?? ""
        searchLabel.isHidden = (entry.searchURL ?? "").isEmpty
        searchLabel.toolTip = entry.searchURL

        catalogLabel.font = NSFont.systemFont(ofSize: 10)
        catalogLabel.textColor = .tertiaryLabelColor
        catalogLabel.lineBreakMode = .byTruncatingMiddle
        catalogLabel.stringValue = entry.catalogURL
        catalogLabel.isHidden = entry.catalogURL.isEmpty
        catalogLabel.toolTip = entry.catalogURL

        if !entry.popularQueries.isEmpty {
            catalogLabel.stringValue = (entry.catalogURL.isEmpty ? "" : entry.catalogURL + "  ·  ")
                + L10n.tr("skills.registry.popularQueries") + ": " + entry.popularQueries.joined(separator: ", ")
            catalogLabel.isHidden = false
        }

        enabledToggle.title = L10n.tr("skills.registry.enabled")
        enabledToggle.state = entry.enabled ? .on : .off
        enabledToggle.controlSize = .small
        enabledToggle.font = NSFont.systemFont(ofSize: 11)
        enabledToggle.target = self
        enabledToggle.action = #selector(toggled)

        deleteButton.title = L10n.tr("skills.registry.delete")
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.font = NSFont.systemFont(ofSize: 11)
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)

        let titleRow = NSStackView(views: [titleLabel, kindLabel, NSView(), enabledToggle, deleteButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let info = NSStackView(views: [searchLabel, catalogLabel])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2

        let stack = NSStackView(views: [titleRow, info])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggled() { onToggleEnabled?(enabledToggle.state == .on) }
    @objc private func deleteTapped() { onDelete?() }
}

/// The "add a registry" card: name + address (auto-detected type) + hint.
final class RegistryAddCardView: SkillCardView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField(string: "")
    private let addressField = NSTextField(string: "")
    private let addButton = NSButton()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    var onAdd: ((String, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = L10n.tr("skills.addRegistry")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 12)

        nameField.placeholderString = L10n.tr("skills.registry.name")
        nameField.font = NSFont.systemFont(ofSize: 11)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        addressField.placeholderString = L10n.tr("skills.registry.address")
        addressField.font = NSFont.systemFont(ofSize: 11)
        addressField.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = L10n.tr("skills.addRegistry")
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = NSFont.systemFont(ofSize: 11)
        addButton.target = self
        addButton.action = #selector(addTapped)

        noteLabel.stringValue = L10n.tr("skills.registry.note")
        noteLabel.font = NSFont.systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor

        let fields = NSStackView(views: [nameField, addressField, addButton])
        fields.orientation = .horizontal
        fields.alignment = .centerY
        fields.spacing = 6
        nameField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let stack = NSStackView(views: [titleLabel, fields, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func addTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        onAdd?(name, address)
    }
}

final class SkillsPanelController: NSObject, NSSearchFieldDelegate {

    // Wiring (injected by main.swift)
    var onRequestHide: (() -> Void)?
    var onOpenFile: ((String) -> Void)?
    var onRevealInFinder: ((String) -> Void)?
    /// Open an http(s) URL (the shell hands it to the system browser).
    var onOpenURL: ((String) -> Void)?
    var workspacePath: (() -> String?)?
    /// Fired whenever a change makes dsh web's cached skill catalog stale
    /// (invocation flags / install / remove). dsh's client caches the catalog
    /// per session and only drops it on connection/reset, so the shell nudges
    /// the page to reconnect (see AppDelegate.nudgeDSHWebCaches).
    var onCatalogChanged: (() -> Void)?

    /// QA hook (--ui-debug): fires after each render so the shell can snapshot
    /// the panel once it actually has content (same pattern as ReviewPanel).
    var onDidRender: (() -> Void)?

    static let minWidth: CGFloat = 300

    let view = SkillsRootView()

    private let headerTitle = HeaderLabel()
    private let refreshButton: CustomIconButton
    private let hideButton: CustomIconButton
    private let segmented = NSSegmentedControl()
    private let contentContainer = DynamicFillView()

    // Installed tab
    private let installedView = NSView()
    private let installedSearch = NSSearchField()
    /// Flat tabs (all / built-in / user / shared / project) — was a dropdown.
    private let levelTabs = SkillTabStrip()
    private let installedScroll = NSScrollView()
    private let installedList = FlippedStackView()

    // Available tab
    private let availableView = NSView()
    /// Flat registry tabs (the toolbar switches between registries directly
    /// instead of hiding them in a dropdown).
    private let registryTabs = SkillTabStrip()
    private let availableSearch = NSSearchField()
    private let searchButton = NSButton()
    private let catalogButton = NSButton()
    private let resultsScroll = NSScrollView()
    private let resultsList = FlippedStackView()
    private let addressButton = NSButton()
    private let importButton = NSButton()
    /// Header (top-right) entry for the registry-management page.
    private let registryButton: CustomIconButton
    // Registries page (shown INSIDE the content area, not as a sheet)
    private let registriesView = NSView()
    private let registriesTitle = NSTextField(labelWithString: "")
    private let registriesBackButton: CustomIconButton
    private let registriesScroll = NSScrollView()
    private let registriesList = FlippedStackView()
    private var page: PanelPage = .installed

    /// Panel pages: the two tab contents plus the registry-management page.
    enum PanelPage { case installed, available, registries }
    private let statusLabel = NSTextField(labelWithString: "")

    private let store: SkillStore
    private let queue = DispatchQueue(label: "com.ohmydsh.skills")
    private var roots: [SkillRoot] = []
    private var skills: [InstalledSkill] = []
    private var candidates: [SkillCandidate] = []
    private var selected = Set<String>()
    private var filterLevel: SkillLevel?
    /// Registry whose default list is already loaded (skips redundant refetches
    /// when the tab is re-shown).
    private var loadedDefaultRegistryID: String?
    private var busy = false

    /// Called by the shell whenever the panel is (re)shown.
    func ensureLoaded() { reloadAll() }

    /// Test hook: apply invocation flags to an installed skill by name. Drives the
    /// exact path the row toggles use (including onCatalogChanged).
    @discardableResult
    func applyInvocationForQA(name: String, userInvocable: Bool?, modelInvocable: Bool?) -> Bool {
        guard let skill = skills.first(where: { $0.name == name }) else { return false }
        setInvocation(skill, userInvocable: userInvocable, modelInvocable: modelInvocable)
        return true
    }

    /// QA hook: DSH_SKILLS_TEST_ROOT swaps the user root for a fixture home.
    static func storeHome() -> String {
        let raw = ProcessInfo.processInfo.environment["DSH_SKILLS_TEST_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? SkillRoots.dshHome() : SkillRoots.expand(raw)
    }

    override init() {
        store = SkillStore(home: SkillsPanelController.storeHome())
        store.seedDefaultRegistriesIfEmpty()
        refreshButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
        hideButton = CustomIconButton(glyph: .close, tooltip: "")
        registryButton = CustomIconButton(glyph: .symbol("shippingbox"), tooltip: "")
        registriesBackButton = CustomIconButton(glyph: .symbol("chevron.left"), tooltip: "")
        super.init()
        buildUI()
        refreshTooltips()
    }

    /// Test hook (mirrors the other panels' header tests).
    func headerTitleKey() -> String { headerTitle.text }

    func refreshTooltips() {
        headerTitle.text = L10n.tr("skills.title")
        refreshButton.toolTip = L10n.tr("skills.refresh")
        hideButton.toolTip = L10n.tr("skills.hide")
        registryButton.toolTip = L10n.tr("skills.manageRegistry")
        registriesBackButton.toolTip = L10n.tr("skills.registry.back")
        registriesTitle.stringValue = L10n.tr("skills.registry.title")
        segmented.setLabel(L10n.tr("skills.tab.installed"), forSegment: 0)
        segmented.setLabel(L10n.tr("skills.tab.available"), forSegment: 1)
        installedSearch.placeholderString = L10n.tr("skills.searchInstalled")
        availableSearch.placeholderString = L10n.tr("skills.search")
        searchButton.title = L10n.tr("skills.searchAction")
        catalogButton.title = L10n.tr("skills.catalogAction")
        addressButton.title = L10n.tr("skills.fromAddress")
        importButton.title = L10n.tr("skills.import")
        rebuildLevelFilter()
        renderInstalled()
        renderAvailable()
    }

    static func formatInstalls(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }

    // MARK: - UI

    private func buildUI() {
        // NOTE: the panel root is mounted directly as the split view's second
        // pane, which positions subviews by FRAME. Setting
        // translatesAutoresizingMaskIntoConstraints = false here (as an earlier
        // version did) leaves the pane without any size, so the header collapsed
        // to its fitting width and the content area stayed empty — the same
        // trap the review panel hit. Keep the root frame-based.
        refreshButton.onAction = { [weak self] in self?.reloadAll() }
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        registryButton.onAction = { [weak self] in self?.toggleRegistryPage() }

        let header = DynamicFillView()
        header.kind = .window
        header.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        let actions = NSStackView(views: [registryButton, refreshButton, hideButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: headerTitle.trailingAnchor, constant: 8),
        ])

        segmented.segmentCount = 2
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.selectedSegment = 0
        segmented.controlSize = .small
        segmented.font = NSFont.systemFont(ofSize: 11)
        segmented.target = self
        segmented.action = #selector(tabChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.kind = .window
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        buildInstalledTab()
        buildAvailableTab()
        buildRegistriesPage()

        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Z-order: subviews added later draw ON TOP, so the content container
        // (an opaque, full-width filler) goes in FIRST and the header/tab strip
        // last. DynamicFillView also clamps its fill to its own bounds now, but
        // this order keeps the panel correct on its own.
        view.addSubview(contentContainer)
        view.addSubview(segmented)
        view.addSubview(statusLabel)
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            segmented.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            segmented.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),

            contentContainer.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            statusLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        // Mount the default tab: nothing is added to contentContainer until
        // tabChanged runs, so do it once while building.
        tabChanged()
    }

    private func buildInstalledTab() {
        installedSearch.translatesAutoresizingMaskIntoConstraints = false
        installedSearch.controlSize = .small
        installedSearch.font = NSFont.systemFont(ofSize: 11)
        installedSearch.delegate = self
        installedSearch.target = self
        installedSearch.action = #selector(searchChanged)
        installedSearch.setContentHuggingPriority(.required, for: .horizontal)
        installedSearch.widthAnchor.constraint(equalToConstant: 170).isActive = true

        levelTabs.onSelect = { [weak self] index in self?.levelTabChanged(index) }

        installedScroll.translatesAutoresizingMaskIntoConstraints = false
        installedScroll.hasVerticalScroller = true
        installedScroll.drawsBackground = false
        installedList.orientation = .vertical
        installedList.alignment = .leading
        installedList.spacing = 8
        installedList.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        installedList.translatesAutoresizingMaskIntoConstraints = false
        installedScroll.documentView = installedList

        // Toolbar: level filter on the LEFT, search pinned RIGHT (same shape as
        // the registry tab's toolbar).
        let installedToolbar = NSStackView(views: [levelTabs, NSView(), installedSearch])
        installedToolbar.orientation = .horizontal
        installedToolbar.alignment = .centerY
        installedToolbar.spacing = 6
        installedToolbar.translatesAutoresizingMaskIntoConstraints = false
        let installedSpacer = installedToolbar.arrangedSubviews[1]
        installedSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        installedSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        installedView.addSubview(installedToolbar)
        installedView.addSubview(installedScroll)
        NSLayoutConstraint.activate([
            installedToolbar.topAnchor.constraint(equalTo: installedView.topAnchor, constant: 8),
            installedToolbar.leadingAnchor.constraint(equalTo: installedView.leadingAnchor, constant: 8),
            installedToolbar.trailingAnchor.constraint(equalTo: installedView.trailingAnchor, constant: -8),

            installedScroll.topAnchor.constraint(equalTo: installedToolbar.bottomAnchor, constant: 6),
            installedScroll.leadingAnchor.constraint(equalTo: installedView.leadingAnchor),
            installedScroll.trailingAnchor.constraint(equalTo: installedView.trailingAnchor),
            installedScroll.bottomAnchor.constraint(equalTo: installedView.bottomAnchor),
            installedList.leadingAnchor.constraint(equalTo: installedScroll.contentView.leadingAnchor),
            installedList.trailingAnchor.constraint(equalTo: installedScroll.contentView.trailingAnchor),
            installedList.topAnchor.constraint(equalTo: installedScroll.contentView.topAnchor),
            installedList.widthAnchor.constraint(equalTo: installedScroll.contentView.widthAnchor),
        ])
        installedView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildAvailableTab() {
        for b in [searchButton, catalogButton, addressButton, importButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            b.target = self
        }
        searchButton.action = #selector(doSearch)
        catalogButton.action = #selector(loadCatalog)
        addressButton.action = #selector(installFromAddress)
        importButton.action = #selector(manualImport)

        registryTabs.onSelect = { [weak self] _ in self?.registryChanged() }
        registryTabs.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        registryTabs.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        availableSearch.translatesAutoresizingMaskIntoConstraints = false
        availableSearch.controlSize = .small
        availableSearch.font = NSFont.systemFont(ofSize: 11)
        availableSearch.target = self
        availableSearch.action = #selector(doSearch)
        availableSearch.setContentHuggingPriority(.required, for: .horizontal)
        availableSearch.widthAnchor.constraint(equalToConstant: 170).isActive = true

        // Spacer: takes the slack so the search controls hug the right edge.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Toolbar: flat registry tabs on the LEFT, search pinned RIGHT.
        let toolbarRow = NSStackView(views: [registryTabs, spacer, availableSearch, searchButton, catalogButton])
        toolbarRow.orientation = .horizontal
        toolbarRow.alignment = .centerY
        toolbarRow.spacing = 6
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [addressButton, importButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 6
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.drawsBackground = false
        resultsList.orientation = .vertical
        resultsList.alignment = .leading
        resultsList.spacing = 8
        resultsList.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        resultsList.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.documentView = resultsList

        availableView.addSubview(toolbarRow)
        availableView.addSubview(resultsScroll)
        availableView.addSubview(bottomRow)
        NSLayoutConstraint.activate([
            toolbarRow.topAnchor.constraint(equalTo: availableView.topAnchor, constant: 8),
            toolbarRow.leadingAnchor.constraint(equalTo: availableView.leadingAnchor, constant: 8),
            toolbarRow.trailingAnchor.constraint(equalTo: availableView.trailingAnchor, constant: -8),

            resultsScroll.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor, constant: 6),
            resultsScroll.leadingAnchor.constraint(equalTo: availableView.leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: availableView.trailingAnchor),
            resultsList.leadingAnchor.constraint(equalTo: resultsScroll.contentView.leadingAnchor),
            resultsList.trailingAnchor.constraint(equalTo: resultsScroll.contentView.trailingAnchor),
            resultsList.topAnchor.constraint(equalTo: resultsScroll.contentView.topAnchor),
            resultsList.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor),

            bottomRow.topAnchor.constraint(equalTo: resultsScroll.bottomAnchor, constant: 6),
            bottomRow.leadingAnchor.constraint(equalTo: availableView.leadingAnchor, constant: 8),
            bottomRow.bottomAnchor.constraint(equalTo: availableView.bottomAnchor, constant: -6),
        ])
        availableView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Tab switching

    @objc private func tabChanged() {
        showPage(segmented.selectedSegment == 0 ? .installed : .available)
    }

    /// The registry button toggles between the management page and the tab the
    /// panel was on before.
    private func toggleRegistryPage() {
        if page == .registries {
            showPage(segmented.selectedSegment == 0 ? .installed : .available)
        } else {
            showPage(.registries)
        }
    }

    /// Switch the content area (also the QA/test entry point for the registry page).
    func showPage(_ target: PanelPage) {
        page = target
        for child in [installedView, availableView, registriesView] {
            child.removeFromSuperview()
        }
        let child: NSView
        switch target {
        case .installed: child = installedView
        case .available: child = availableView
        case .registries: child = registriesView
        }
        contentContainer.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        registryButton.showsBackground = (target == .registries)
        switch target {
        case .installed: renderInstalled()
        case .available:
            renderRegistryPopup()
            renderAvailable()
            loadDefaultList()
        case .registries: renderRegistries()
        }
    }

    // MARK: - Data

    private func currentRoots() -> [SkillRoot] {
        SkillRoots.defaultRoots(workspace: workspacePath?(), home: store.home)
    }

    /// Rescan the filesystem and re-render (called on open and after mutations).
    func reloadAll() {
        roots = currentRoots()
        skills = SkillScanner.scan(roots)
        loadedDefaultRegistryID = nil      // a refresh also re-pulls the default list
        rebuildLevelFilter()
        renderInstalled()
        renderRegistryPopup()
        renderAvailable()
        AppLog.shared.log("skills: scanned " + String(skills.count) + " skill(s) across "
            + String(roots.count) + " root(s); "
            + skills.map { $0.name + "(" + $0.level.rawValue + ")" }.joined(separator: ", "))
        setStatus(L10n.tr("skills.found").replacingOccurrences(of: "%d", with: String(skills.count)), error: false)
        // Let the shell snapshot AFTER the rows exist (a startup-time dump has no
        // backing store yet, so its PNG came out empty).
        DispatchQueue.main.async { [weak self] in self?.onDidRender?() }
    }

    private func rescan() {
        skills = SkillScanner.scan(roots)
        renderInstalled()
    }

    /// Tab order in the installed toolbar: All / Shared / Built-in / User /
    /// Project (shared first, since that is the level external tools install
    /// into — see docs/skills-manager-design.md).
    private static var levelEntries: [(String, SkillLevel?)] {
        [(L10n.tr("skills.filter.all"), nil),
         (L10n.tr("skills.badge.shared"), .shared),
         (L10n.tr("skills.badge.builtin"), .builtin),
         (L10n.tr("skills.badge.user"), .user),
         (L10n.tr("skills.badge.project"), .project)]
    }

    private func rebuildLevelFilter() {
        let entries = SkillsPanelController.levelEntries
        // Keep the SELECTED LEVEL across rebuilds (language switches, rescans):
        // the tab order may differ from the previous build, so match by value
        // instead of carrying the old index over.
        let index = entries.firstIndex { $0.1 == filterLevel } ?? 0
        levelTabs.setItems(entries.map { $0.0 }, selected: index)
        filterLevel = entries[index].1
    }

    private func levelTabChanged(_ index: Int) {
        let entries = SkillsPanelController.levelEntries
        filterLevel = entries[max(0, min(index, entries.count - 1))].1
        renderInstalled()
    }

    @objc private func searchChanged() { renderInstalled() }

    func controlTextDidChange(_ obj: Notification) { renderInstalled() }

    private func renderInstalled() {
        for sub in installedList.arrangedSubviews { sub.removeFromSuperview() }
        let query = installedSearch.stringValue.lowercased()
        let visible = skills.filter { s in
            if let level = filterLevel, s.level != level { return false }
            if query.isEmpty { return true }
            return s.name.lowercased().contains(query) || s.description.lowercased().contains(query)
        }
        if visible.isEmpty {
            let empty = emptyCard(L10n.tr("skills.empty.installed"))
            installedList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: installedList.widthAnchor, constant: -20).isActive = true
            return
        }
        for skill in visible {
            let row = SkillRowView(skill: skill)
            row.onToggleUser = { [weak self] on in self?.setInvocation(skill, userInvocable: on, modelInvocable: nil) }
            row.onToggleModel = { [weak self] on in self?.setInvocation(skill, userInvocable: nil, modelInvocable: on) }
            row.onRemove = { [weak self] in self?.confirmRemove(skill) }
            row.onOpen = { [weak self] in self?.onOpenFile?(skill.skillFile) }
            row.onReveal = { [weak self] in self?.onRevealInFinder?(skill.dir) }
            row.onDetail = { [weak self] in self?.showDetail(skill) }
            row.translatesAutoresizingMaskIntoConstraints = false
            installedList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: installedList.widthAnchor, constant: -20).isActive = true
        }
    }

    /// Empty-state text that spans the list width (so .center actually centers).
    private func emptyCard(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -24),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
        ])
        return holder
    }

    private func renderRegistryPopup() {
        let entries = store.data.registries.filter { $0.enabled }
        let current = activeRegistryLabel
        let titles = entries.isEmpty ? ["-"] : entries.map { $0.label }
        let selected = entries.firstIndex(where: { $0.label == current }) ?? 0
        registryTabs.setItems(titles, selected: selected)
    }

    private var activeRegistryLabel: String? {
        let entries = store.data.registries.filter { $0.enabled }
        guard !entries.isEmpty else { return nil }
        let index = registryTabs.selectedIndex
        guard index >= 0, index < entries.count else { return entries.first?.label }
        return entries[index].label
    }

    private var activeRegistry: SkillRegistryRecord? {
        let entries = store.data.registries.filter { $0.enabled }
        guard !entries.isEmpty else { return nil }
        let index = registryTabs.selectedIndex
        return entries[max(0, min(index, entries.count - 1))]
    }

    private func registryChanged() {
        candidates = []
        selected.removeAll()
        loadedDefaultRegistryID = nil
        renderAvailable()
        loadDefaultList(force: true)
    }

    /// What the available tab shows BEFORE the user types anything: the
    /// registry's catalog when it has one, otherwise its "popular" list —
    /// search-only registries (skills.sh) cannot be enumerated, but a broad
    /// query returns the ecosystem sorted by installs.
    private func loadDefaultList(force: Bool = false) {
        guard let registry = activeRegistry else { return }
        if !force, loadedDefaultRegistryID == registry.id { return }
        loadedDefaultRegistryID = registry.id
        if registry.catalog != SkillCatalogKind.none {
            loadCatalog()
            return
        }
        guard registry.searchURL != nil else {
            setStatus(L10n.tr("skills.noCatalogHint"), error: true)
            return
        }
        setBusy(true)
        setStatus(L10n.tr("skills.loading"), error: false)
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let found = try SkillRegistryClient.popular(registry)
                DispatchQueue.main.async {
                    self.candidates = found
                    self.selected.removeAll()
                    self.renderAvailable()
                    self.setBusy(false)
                    self.setStatus(L10n.tr("skills.popular"), error: false)
                }
            } catch let error as SkillPanelError {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(self.message(for: error), error: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func renderAvailable() {
        for sub in resultsList.arrangedSubviews { sub.removeFromSuperview() }
        if candidates.isEmpty {
            let hint = (activeRegistry?.catalog == SkillCatalogKind.none)
                ? L10n.tr("skills.noCatalogHint")
                : L10n.tr("skills.empty.results")
            let empty = emptyCard(hint)
            resultsList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: resultsList.widthAnchor, constant: -20).isActive = true
            return
        }
        for candidate in candidates {
            let key = candidate.name + "|" + candidate.sourceLabel
            let card = SkillCandidateRowView(candidate: candidate, selected: selected.contains(key))
            card.onToggle = { [weak self] on in
                if on { self?.selected.insert(key) } else { self?.selected.remove(key) }
            }
            card.onInstall = { [weak self] in self?.startInstall(address: candidate.address, label: candidate.name) }
            card.onDetail = { [weak self] in self?.openDetail(candidate) }
            card.translatesAutoresizingMaskIntoConstraints = false
            resultsList.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: resultsList.widthAnchor, constant: -20).isActive = true
        }
    }

    /// Open a candidate's detail page (skills.sh / GitHub / well-known URL) in
    /// the system default browser; local sources are revealed in Finder.
    private func openDetail(_ candidate: SkillCandidate) {
        if let url = candidate.detailURL(registry: activeRegistry), !url.isEmpty {
            AppLog.shared.log("skills: open detail " + candidate.name + " -> " + url)
            onOpenURL?(url)
            return
        }
        if case .local(let path) = candidate.address {
            onRevealInFinder?(path)
            return
        }
        setStatus(L10n.tr("skills.err.unsupportedAddress"), error: true)
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func setBusy(_ value: Bool) {
        busy = value
        searchButton.isEnabled = !value
        catalogButton.isEnabled = !value
        addressButton.isEnabled = !value
        importButton.isEnabled = !value
        refreshButton.isEnabled = !value
    }

    // MARK: - Invocation flags

    private func setInvocation(_ skill: InstalledSkill, userInvocable: Bool?, modelInvocable: Bool?) {
        let ui = userInvocable ?? skill.userInvocable
        let model = modelInvocable ?? skill.modelInvocable
        do {
            _ = try SkillInstallService.applyInvocation(skill,
                                                       userInvocable: ui,
                                                       disableModelInvocation: !model,
                                                       store: store)
            AppLog.shared.log("skills: invocation " + skill.name + " user=" + String(ui) + " model=" + String(model))
            rescan()
            setStatus(L10n.tr("skills.saved"), error: false)
            onCatalogChanged?()
        } catch let error as SkillPanelError {
            AppLog.shared.log("skills: invocation failed " + skill.name + " " + error.l10nKey)
            setStatus(message(for: error), error: true)
            rescan()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func message(for error: SkillPanelError) -> String {
        let base = L10n.tr(error.l10nKey)
        return error.detail.isEmpty ? base : base + " " + error.detail
    }

    // MARK: - Remove

    private func confirmRemove(_ skill: InstalledSkill) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("skills.removeConfirm")
        alert.informativeText = skill.dir
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("skills.remove"))
        alert.addButton(withTitle: L10n.tr("skills.cancel"))
        runAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            do {
                try SkillInstallService.remove(skill, store: self.store)
                AppLog.shared.log("skills: removed " + skill.name + " (" + skill.dir + ")")
                self.setStatus(L10n.tr("skills.removedOk"), error: false)
                self.onCatalogChanged?()
            } catch let error as SkillPanelError {
                self.setStatus(self.message(for: error), error: true)
            } catch {
                self.setStatus(error.localizedDescription, error: true)
            }
            self.rescan()
        }
    }

    private func showDetail(_ skill: InstalledSkill) {
        let record = store.installRecord(skill.name)
        var lines: [String] = [
            L10n.tr("skills.detail.name") + ": " + skill.name,
            L10n.tr("skills.detail.level") + ": " + L10n.tr(skill.level.badgeKey),
            L10n.tr("skills.detail.root") + ": " + skill.root.path,
            L10n.tr("skills.detail.path") + ": " + skill.skillFile,
            L10n.tr("skills.detail.files") + ": " + String(skill.extraFiles + 1),
        ]
        if skill.shadowedBy != nil { lines.append(L10n.tr("skills.badge.shadowed")) }
        if let record = record {
            lines.append(L10n.tr("skills.detail.source") + ": " + record.source)
            lines.append(L10n.tr("skills.detail.installedAt") + ": " + record.installedAt)
        }
        let alert = NSAlert()
        alert.messageText = skill.description
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: L10n.tr("skills.ok"))
        alert.addButton(withTitle: L10n.tr("skills.copyPath"))
        runAlert(alert) { response in
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(skill.skillFile, forType: .string)
            }
        }
    }

    // MARK: - Registry

    @objc private func loadCatalog() {
        guard let registry = activeRegistry else { return }
        guard registry.catalog != SkillCatalogKind.none else {
            setStatus(L10n.tr("skills.noCatalogHint"), error: true)
            return
        }
        setBusy(true)
        setStatus(L10n.tr("skills.loading"), error: false)
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let found = try SkillRegistryClient.catalog(registry)
                DispatchQueue.main.async {
                    self.candidates = found
                    self.selected.removeAll()
                    self.renderAvailable()
                    self.setBusy(false)
                    self.setStatus(L10n.tr("skills.catalogLoaded"), error: false)
                }
            } catch let error as SkillPanelError {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(self.message(for: error), error: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    @objc private func doSearch() {
        guard let registry = activeRegistry else { return }
        let query = availableSearch.stringValue
        setBusy(true)
        setStatus(L10n.tr("skills.loading"), error: false)
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let found = try SkillRegistryClient.search(registry, query: query)
                DispatchQueue.main.async {
                    self.candidates = found
                    self.selected.removeAll()
                    self.renderAvailable()
                    self.setBusy(false)
                    self.setStatus(L10n.tr("skills.searchDone"), error: false)
                }
            } catch let error as SkillPanelError {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(self.message(for: error), error: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    // MARK: - Registries page

    /// Management page rendered INSIDE the panel (the header's top-right button
    /// switches to it); registries are cards, with an "add" card on top of the
    /// list.
    private func buildRegistriesPage() {
        registriesTitle.font = NSFont.boldSystemFont(ofSize: 12)
        registriesTitle.translatesAutoresizingMaskIntoConstraints = false
        registriesBackButton.onAction = { [weak self] in
            guard let self = self else { return }
            self.showPage(self.segmented.selectedSegment == 0 ? .installed : .available)
        }

        let headerRow = NSStackView(views: [registriesBackButton, registriesTitle, NSView()])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        registriesScroll.translatesAutoresizingMaskIntoConstraints = false
        registriesScroll.hasVerticalScroller = true
        registriesScroll.drawsBackground = false
        registriesList.orientation = .vertical
        registriesList.alignment = .leading
        registriesList.spacing = 8
        registriesList.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        registriesList.translatesAutoresizingMaskIntoConstraints = false
        registriesScroll.documentView = registriesList

        registriesView.addSubview(headerRow)
        registriesView.addSubview(registriesScroll)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: registriesView.topAnchor, constant: 8),
            headerRow.leadingAnchor.constraint(equalTo: registriesView.leadingAnchor, constant: 8),
            headerRow.trailingAnchor.constraint(equalTo: registriesView.trailingAnchor, constant: -8),

            registriesScroll.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),
            registriesScroll.leadingAnchor.constraint(equalTo: registriesView.leadingAnchor),
            registriesScroll.trailingAnchor.constraint(equalTo: registriesView.trailingAnchor),
            registriesScroll.bottomAnchor.constraint(equalTo: registriesView.bottomAnchor),
            registriesList.leadingAnchor.constraint(equalTo: registriesScroll.contentView.leadingAnchor),
            registriesList.trailingAnchor.constraint(equalTo: registriesScroll.contentView.trailingAnchor),
            registriesList.topAnchor.constraint(equalTo: registriesScroll.contentView.topAnchor),
            registriesList.widthAnchor.constraint(equalTo: registriesScroll.contentView.widthAnchor),
        ])
        registriesView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func renderRegistries() {
        for sub in registriesList.arrangedSubviews { sub.removeFromSuperview() }
        registriesTitle.stringValue = L10n.tr("skills.registry.title")

        for entry in store.data.registries {
            let card = RegistryCardView(entry: entry)
            card.onToggleEnabled = { [weak self] on in
                guard let self = self else { return }
                var updated = entry
                updated.enabled = on
                self.store.upsertRegistry(updated)
                AppLog.shared.log("skills: registry " + entry.id + " enabled=" + String(on))
                self.renderRegistryPopup()
                self.renderRegistries()
            }
            card.onDelete = { [weak self] in self?.confirmDeleteRegistry(entry) }
            registriesList.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: registriesList.widthAnchor, constant: -20).isActive = true
        }

        if store.data.registries.isEmpty {
            let empty = emptyCard(L10n.tr("skills.registry.empty"))
            registriesList.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: registriesList.widthAnchor, constant: -20).isActive = true
        }

        let addCard = RegistryAddCardView()
        addCard.onAdd = { [weak self] name, address in self?.addRegistry(name: name, address: address) }
        registriesList.addArrangedSubview(addCard)
        addCard.widthAnchor.constraint(equalTo: registriesList.widthAnchor, constant: -20).isActive = true
    }

    private func addRegistry(name: String, address: String) {
        guard let probed = SkillRegistryClient.probe(address) else {
            setStatus(L10n.tr("skills.err.unsupportedAddress") + " " + address, error: true)
            return
        }
        var entry = probed
        if !name.isEmpty { entry.label = name }
        store.upsertRegistry(entry)
        AppLog.shared.log("skills: registry added " + entry.label + " (" + entry.catalog.rawValue + ")")
        setStatus(L10n.tr("skills.registry.added"), error: false)
        renderRegistryPopup()
        renderRegistries()
    }

    private func confirmDeleteRegistry(_ entry: SkillRegistryRecord) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("skills.registry.delete")
        alert.informativeText = entry.label
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("skills.registry.delete"))
        alert.addButton(withTitle: L10n.tr("skills.cancel"))
        runAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.store.removeRegistry(id: entry.id)
            AppLog.shared.log("skills: registry removed " + entry.id)
            self.renderRegistryPopup()
            self.renderRegistries()
        }
    }

    // MARK: - Install

    @objc private func installFromAddress() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("skills.fromAddress")
        alert.informativeText = L10n.tr("skills.addressHint") + "\n" + L10n.tr("skills.warnPermissions")
        let field = NSTextField(string: "")
        field.placeholderString = "owner/repo@skill"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let target = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 200, height: 24), pullsDown: false)
        target.addItem(withTitle: L10n.tr("skills.target.user"))
        target.addItem(withTitle: L10n.tr("skills.target.project"))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 58))
        accessory.addSubview(field)
        accessory.addSubview(target)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L10n.tr("skills.install"))
        alert.addButton(withTitle: L10n.tr("skills.cancel"))
        runAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return }
            self.startInstall(addressText: address, projectLevel: target.indexOfSelectedItem == 1)
        }
    }

    @objc private func manualImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("skills.importHint")
        panel.prompt = L10n.tr("skills.import")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self = self, let url = panel.url else { return }
            self.chooseImportTarget(path: url.path)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func chooseImportTarget(path: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("skills.import")
        alert.informativeText = path
        alert.addButton(withTitle: L10n.tr("skills.target.user"))
        alert.addButton(withTitle: L10n.tr("skills.target.project"))
        alert.addButton(withTitle: L10n.tr("skills.cancel"))
        runAlert(alert) { [weak self] response in
            guard let self = self else { return }
            if response == .alertThirdButtonReturn { return }
            let projectLevel = response == .alertSecondButtonReturn
            self.performImport(path: path, projectLevel: projectLevel, overwrite: false)
        }
    }

    private func performImport(path: String, projectLevel: Bool, overwrite: Bool) {
        guard let root = targetRoot(projectLevel: projectLevel) else {
            setStatus(L10n.tr("skills.err.unsupportedTarget"), error: true)
            return
        }
        do {
            let skill = try SkillInstallService.importLocal(path: path, into: root, store: store, overwrite: overwrite)
            AppLog.shared.log("skills: imported " + skill.name + " -> " + skill.dir)
            setStatus(L10n.tr("skills.installedOk"), error: false)
            rescan()
            onCatalogChanged?()
        } catch SkillPanelError.targetExists(let detail) {
            confirmOverwrite(title: L10n.tr("skills.overwriteConfirm"), detail: detail) { [weak self] in
                self?.performImport(path: path, projectLevel: projectLevel, overwrite: true)
            }
        } catch let error as SkillPanelError {
            setStatus(message(for: error), error: true)
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func targetRoot(projectLevel: Bool) -> SkillRoot? {
        if projectLevel {
            guard let ws = workspacePath?(), !ws.isEmpty else { return nil }
            return SkillRoot(kind: .projectDsh, level: .project,
                             path: SkillRoots.join(ws, ".dsh/skills"),
                             rank: SkillRoots.rankProjectDsh)
        }
        return SkillRoot(kind: .userDsh, level: .user,
                         path: SkillRoots.join(store.home, "skills"),
                         rank: SkillRoots.rankUserDsh)
    }

    private func startInstall(addressText: String, projectLevel: Bool) {
        guard let address = SkillAddressParser.parse(addressText) else {
            setStatus(L10n.tr("skills.err.unsupportedAddress") + " " + addressText, error: true)
            return
        }
        startInstall(address: address, label: addressText, projectLevel: projectLevel)
    }

    private func startInstall(address: SkillAddress, label: String, projectLevel: Bool = false, overwrite: Bool = false) {
        guard let root = targetRoot(projectLevel: projectLevel) else {
            setStatus(L10n.tr("skills.err.unsupportedTarget"), error: true)
            return
        }
        setBusy(true)
        setStatus(L10n.tr("skills.installing"), error: false)
        let temp = SkillFetcher.makeTempDir()
        queue.async { [weak self] in
            guard let self = self else { return }
            defer { try? FileManager.default.removeItem(atPath: temp) }
            do {
                let fetched = try SkillFetcher.fetch(address, temp: temp)
                guard let first = fetched.first else { throw SkillPanelError.noSkillsFound }
                let skill = try SkillInstallService.install(first, into: root, store: self.store, overwrite: overwrite)
                AppLog.shared.log("skills: installed " + skill.name + " from " + label + " -> " + skill.dir)
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(L10n.tr("skills.installedOk"), error: false)
                    self.roots = self.currentRoots()
                    self.rescan()
                    self.onCatalogChanged?()
                }
            } catch SkillPanelError.targetExists(let detail) {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.confirmOverwrite(title: L10n.tr("skills.overwriteConfirm"), detail: detail) { [weak self] in
                        self?.startInstall(address: address, label: label, projectLevel: projectLevel, overwrite: true)
                    }
                }
            } catch let error as SkillPanelError {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(self.message(for: error), error: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func confirmOverwrite(title: String, detail: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("skills.overwrite"))
        alert.addButton(withTitle: L10n.tr("skills.cancel"))
        runAlert(alert) { response in
            if response == .alertFirstButtonReturn { onConfirm() }
        }
    }

    // MARK: - Alert plumbing

    private func runAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
