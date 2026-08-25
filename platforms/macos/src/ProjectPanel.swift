import AppKit
import Foundation

// MARK: - 项目面板（ProjectPanel.swift）
//
// 设计：docs/plans/PROJECT_PLAN-project-panel.md
// 职责：首屏三选入口 → 向导（选模板/选目标/变量与步骤/摘要执行）→ 工作区尾动作 → 完成视图。
// 模型/执行逻辑在 ProjectTemplates.swift（纯 Foundation，无头可测）；本文件只做 UI 编排。

/// 面板根视图（isOpaque=false 自绘背景，规避 layer-backed 合成陷阱 —— docs/terminal-header-fix.md；
/// 同 ChannelRootView/WikiRootView 模式）。
final class ProjectRootView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        color.setFill()
        dirtyRect.fill()
    }
}

final class ProjectPanelController: NSObject {

    // MARK: - 注入闭包（main.swift 接线）
    var onRequestHide: (() -> Void)?
    var serverPortProvider: (() -> Int)?
    /// 当前项目目录（dsh 活动会话 cwd 的共享投影），供「应用到当前项目」入口使用。
    var workspacePath: (() -> String?)?
    /// 初始化完成（含工作区注册）后回调：path + 可选 sessionId。main.swift 负责设 ProjectDirectory 并切换 dsh web 会话。
    var onProjectReady: ((String, String?) -> Void)?
    /// 完成视图「在终端打开」：path（main.swift 设 ProjectDirectory 后 newSession 即落在该目录）。
    var onOpenTerminal: ((String) -> Void)?
    /// 完成视图「在文件面板打开」：path。
    var onOpenInFilePanel: ((String) -> Void)?

    static let minWidth: CGFloat = 300

    let view = ProjectRootView()

    // MARK: - 模板数据（懒加载 + 手动刷新）
    private var templates: [ProjectTemplate] = []
    private var builtinTemplateCount = 0
    private var userTemplateCount = 0
    private var skippedTemplateSlugs: [String] = []

    // MARK: - 视图
    private let headerTitle = HeaderLabel()
    private let rescanButton: CustomIconButton
    private let hideButton = CustomIconButton(glyph: .close, tooltip: "")
    private let contentContainer = DynamicFillView()

    // home
    private let homeView = NSView()
    private let homeCurrentPathLabel = NSTextField(labelWithString: "")
    private let homeStatsLabel = NSTextField(labelWithString: "")

    // wizard
    private let wizardView = NSView()
    private let stepIndicator = NSTextField(labelWithString: "")
    private let wizardContent = DynamicFillView()
    private let wizardBackButton = NSButton()
    private let wizardNextButton = NSButton()
    private let wizardCancelButton = NSButton()
    private let wizardBottomBar = NSView()

    // wizard state
    private enum EntryMode { case newProject, existingDir, currentProject }
    private var entryMode: EntryMode = .newProject
    private var currentStep = 1
    private var selectedTemplate: ProjectTemplate?
    private var targetDir: String?
    private var existingMode = false
    private var variableFields: [NSTextField] = []
    private var variableKeys: [String] = []
    private var stepCheckboxes: [NSButton] = []
    private var summaryLabel = NSTextField(labelWithString: "")
    private var registerWorkspaceCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // steps: 1 选模板 / 2 选目标 / 3 变量+步骤 / 4 摘要与执行
    private static let totalSteps = 4

    // 执行状态
    private var currentPlan: ApplyPlan?
    private var executing = false
    private var cancelledFlag = AtomicFlag()
    private var lastDonePath: String?
    private var lastDoneSessionId: String?

    // done view
    private let doneView = NSView()
    private let doneTitle = NSTextField(labelWithString: "")
    private let doneDetail = NSTextField(wrappingLabelWithString: "")

    // 日志视图
    private var logTextView: NSTextView?
    private var logScroll: NSScrollView?

    // MARK: - init

    override init() {
        rescanButton = CustomIconButton(glyph: .symbol("arrow.clockwise"), tooltip: "")
        super.init()
        buildUI()
        reloadTemplates()
        showHome()
    }

    // MARK: - 模板加载

    private func reloadTemplates() {
        let builtinDir = (Bundle.main.resourceURL?.path ?? "")
            + "/project-templates"
        let userDir = projectTemplatesUserDir()
        let result = ProjectTemplateStore.scan(builtinDir: builtinDir, userDir: userDir)
        templates = result.templates
        builtinTemplateCount = result.templates.filter { $0.isBuiltin }.count
        userTemplateCount = result.templates.filter { !$0.isBuiltin }.count
        skippedTemplateSlugs = result.skippedSlugs
        if !skippedTemplateSlugs.isEmpty {
            AppLog.shared.log("project templates skipped (broken manifests): \(skippedTemplateSlugs.joined(separator: ", "))")
        }
        if let selected = selectedTemplate,
           !templates.contains(where: { $0.slug == selected.slug }) {
            selectedTemplate = nil
        }
        refreshHomeStats()
    }

    private func projectTemplatesUserDir() -> String {
        if let env = ProcessInfo.processInfo.environment["DSH_PROJECT_TEMPLATES"], !env.isEmpty {
            return env
        }
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
        return (dshHome as NSString).appendingPathComponent("project-templates")
    }

    // MARK: - buildUI

    private func buildUI() {
        let view = self.view

        // header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.masksToBounds = true
        headerTitle.text = L10n.tr("project.title")
        rescanButton.toolTip = L10n.tr("project.rescan")
        rescanButton.onAction = { [weak self] in self?.reloadTemplates(); self?.refreshTemplateList() }
        hideButton.toolTip = L10n.tr("preview.closePanel")
        hideButton.onAction = { [weak self] in self?.onRequestHide?() }
        let actions = NSStackView(views: [rescanButton, hideButton])
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(actions)
        NSLayoutConstraint.activate([
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
        ])

        // content container（layer 隔离）
        contentContainer.kind = .control
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        contentContainer.addSubview(homeView)
        contentContainer.addSubview(wizardView)
        contentContainer.addSubview(doneView)
        pin(homeView, to: contentContainer)
        pin(wizardView, to: contentContainer)
        pin(doneView, to: contentContainer)

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

        buildHomeView()
        buildWizardView()
        buildDoneView()
    }

    private func buildHomeView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L10n.tr("project.homeTitle"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let newButton = homeEntryButton(
            title: L10n.tr("project.homeNew"), subtitle: L10n.tr("project.homeNewHint"),
            action: #selector(homeNewTapped))
        let existingButton = homeEntryButton(
            title: L10n.tr("project.homeExisting"), subtitle: L10n.tr("project.homeExistingHint"),
            action: #selector(homeExistingTapped))
        let currentButton = homeEntryButton(
            title: L10n.tr("project.homeCurrent"), subtitle: L10n.tr("project.homeCurrentHint"),
            action: #selector(homeCurrentTapped))

        homeCurrentPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        homeCurrentPathLabel.textColor = .secondaryLabelColor
        homeCurrentPathLabel.lineBreakMode = .byTruncatingMiddle

        homeStatsLabel.font = .systemFont(ofSize: 11)
        homeStatsLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(newButton)
        stack.addArrangedSubview(existingButton)
        stack.addArrangedSubview(currentButton)
        stack.addArrangedSubview(homeCurrentPathLabel)
        stack.addArrangedSubview(homeStatsLabel)

        homeView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: homeView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: homeView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: homeView.trailingAnchor, constant: -12),
        ])
        // 入口按钮占满可用宽度
        for btn in [newButton, existingButton, currentButton] {
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        }
        refreshHomeStats()
    }

    private func homeEntryButton(title: String, subtitle: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.font = .systemFont(ofSize: 13, weight: .medium)
        btn.toolTip = subtitle
        return btn
    }

    private func refreshHomeStats() {
        homeStatsLabel.stringValue = L10n.tr("project.templateStats", builtinTemplateCount, userTemplateCount)
        let current = workspacePath?()
        if let current = current, !current.isEmpty {
            homeCurrentPathLabel.stringValue = L10n.tr("project.homeCurrentPath", current)
            homeCurrentPathLabel.isHidden = false
        } else {
            homeCurrentPathLabel.isHidden = true
        }
    }

    // MARK: - wizard

    private func buildWizardView() {
        wizardContent.kind = .control
        wizardContent.translatesAutoresizingMaskIntoConstraints = false
        wizardContent.wantsLayer = true
        wizardContent.layer?.masksToBounds = true

        stepIndicator.font = .systemFont(ofSize: 12, weight: .medium)
        stepIndicator.textColor = .secondaryLabelColor

        wizardCancelButton.title = L10n.tr("btn.cancel")
        wizardCancelButton.bezelStyle = .rounded
        wizardCancelButton.target = self
        wizardCancelButton.action = #selector(wizardCancelTapped)

        wizardBackButton.title = L10n.tr("project.back")
        wizardBackButton.bezelStyle = .rounded
        wizardBackButton.target = self
        wizardBackButton.action = #selector(wizardBackTapped)

        wizardNextButton.title = L10n.tr("project.next")
        wizardNextButton.bezelStyle = .rounded
        wizardNextButton.keyEquivalent = "\r"
        wizardNextButton.target = self
        wizardNextButton.action = #selector(wizardNextTapped)

        let bottomStack = NSStackView(views: [wizardCancelButton, wizardBackButton, wizardNextButton])
        bottomStack.spacing = 8
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        wizardBottomBar.addSubview(bottomStack)
        wizardBottomBar.translatesAutoresizingMaskIntoConstraints = false

        wizardView.addSubview(stepIndicator)
        wizardView.addSubview(wizardContent)
        wizardView.addSubview(wizardBottomBar)

        NSLayoutConstraint.activate([
            stepIndicator.topAnchor.constraint(equalTo: wizardView.topAnchor, constant: 10),
            stepIndicator.leadingAnchor.constraint(equalTo: wizardView.leadingAnchor, constant: 12),
            stepIndicator.trailingAnchor.constraint(lessThanOrEqualTo: wizardView.trailingAnchor, constant: -12),
            wizardContent.topAnchor.constraint(equalTo: stepIndicator.bottomAnchor, constant: 8),
            wizardContent.leadingAnchor.constraint(equalTo: wizardView.leadingAnchor, constant: 1),
            wizardContent.trailingAnchor.constraint(equalTo: wizardView.trailingAnchor, constant: -1),
            wizardBottomBar.topAnchor.constraint(equalTo: wizardContent.bottomAnchor, constant: 8),
            wizardBottomBar.leadingAnchor.constraint(equalTo: wizardView.leadingAnchor, constant: 12),
            wizardBottomBar.trailingAnchor.constraint(equalTo: wizardView.trailingAnchor, constant: -12),
            wizardBottomBar.bottomAnchor.constraint(equalTo: wizardView.bottomAnchor, constant: -8),
            bottomStack.trailingAnchor.constraint(equalTo: wizardBottomBar.trailingAnchor),
            bottomStack.topAnchor.constraint(equalTo: wizardBottomBar.topAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: wizardBottomBar.bottomAnchor),
        ])
    }

    private func enterWizard(mode: EntryMode, dir: String?) {
        entryMode = mode
        targetDir = dir
        existingMode = false
        currentStep = 1
        selectedTemplate = nil
        showWizard()
    }

    @objc private func homeNewTapped() { enterWizard(mode: .newProject, dir: nil) }

    @objc private func homeExistingTapped() {
        guard let pick = chooseDirectory(createAllowed: false) else { return }
        enterWizard(mode: .existingDir, dir: pick)
    }

    @objc private func homeCurrentTapped() {
        guard let current = workspacePath?(), !current.isEmpty else {
            // 取不到当前项目 → 回退到选目录
            homeExistingTapped()
            return
        }
        enterWizard(mode: .currentProject, dir: current)
    }

    /// NSOpenPanel 选目录；createAllowed 时允许新建文件夹（新项目模式选父目录/空目录）。
    private func chooseDirectory(createAllowed: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = createAllowed
        panel.prompt = L10n.tr("project.chooseDir")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    @objc private func wizardCancelTapped() {
        if executing { return }
        showHome()
    }

    @objc private func wizardBackTapped() {
        if executing { return }
        if currentStep > 1 { currentStep -= 1 }
        renderStep()
    }

    @objc private func wizardNextTapped() {
        if executing { return }
        if currentStep == 2 {
            // 选目标：新项目模式必须选目录；既有/当前模式已有目录
            if targetDir == nil {
                guard let pick = chooseDirectory(createAllowed: true) else { return }
                targetDir = pick
            }
            detectExistingMode()
        }
        if currentStep == 4 {
            startExecution()
            return
        }
        if currentStep < ProjectPanelController.totalSteps { currentStep += 1 }
        renderStep()
    }

    private func detectExistingMode() {
        guard let target = targetDir else { existingMode = false; return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            existingMode = false
            return
        }
        // 空目录 = 新项目模式；非空 = 既有项目模式（只补缺失）
        let contents = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        existingMode = !contents.isEmpty
    }

    private func showWizard() {
        homeView.isHidden = true
        doneView.isHidden = true
        wizardView.isHidden = false
        renderStep()
    }

    private func showHome() {
        homeView.isHidden = false
        wizardView.isHidden = true
        doneView.isHidden = true
        refreshHomeStats()
    }

    private func renderStep() {
        stepIndicator.stringValue = L10n.tr("project.stepIndicator", currentStep, ProjectPanelController.totalSteps, stepTitle(currentStep))
        wizardBackButton.isHidden = currentStep == 1
        wizardNextButton.title = currentStep == ProjectPanelController.totalSteps ? L10n.tr("project.start") : L10n.tr("project.next")
        // 清空 wizardContent 子视图
        for sub in wizardContent.subviews { sub.removeFromSuperview() }
        switch currentStep {
        case 1: renderStepTemplate()
        case 2: renderStepTarget()
        case 3: renderStepVariables()
        default: renderStepSummary()
        }
    }

    private func stepTitle(_ step: Int) -> String {
        switch step {
        case 1: return L10n.tr("project.stepTemplate")
        case 2: return L10n.tr("project.stepTarget")
        case 3: return L10n.tr("project.stepVariables")
        default: return L10n.tr("project.stepSummary")
        }
    }

    // MARK: step 1 — 选模板

    private var templateSearchField: NSSearchField?
    private var templateListStack: NSStackView?

    private func renderStepTemplate() {
        let search = NSSearchField()
        search.placeholderString = L10n.tr("project.searchPlaceholder")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self
        search.action = #selector(filterTemplates)
        templateSearchField = search

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let list = FlippedStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        templateListStack = list

        wizardContent.addSubview(search)
        wizardContent.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: wizardContent.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: wizardContent.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: wizardContent.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: wizardContent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wizardContent.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: wizardContent.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        refreshTemplateList()
    }

    @objc private func filterTemplates() {
        refreshTemplateList()
    }

    private func refreshTemplateList() {
        guard let list = templateListStack else { return }
        for sub in list.arrangedSubviews { sub.removeFromSuperview() }
        let query = (templateSearchField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = query.isEmpty ? templates : templates.filter { $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
        if shown.isEmpty {
            let empty = NSTextField(labelWithString: L10n.tr("project.emptyTemplates"))
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
            return
        }
        for tpl in shown {
            list.addArrangedSubview(templateCard(tpl))
        }
    }

    private func templateCard(_ tpl: ProjectTemplate) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        card.layer?.backgroundColor = dark ? NSColor(calibratedWhite: 0.22, alpha: 1).cgColor
                                            : NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        card.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: tpl.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let desc = NSTextField(wrappingLabelWithString: tpl.description.isEmpty ? "—" : tpl.description)
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        let badge = NSTextField(labelWithString: tpl.isBuiltin ? L10n.tr("project.badgeBuiltin") : L10n.tr("project.badgeUser"))
        badge.font = .systemFont(ofSize: 10)
        badge.textColor = .secondaryLabelColor

        let useButton = NSButton(title: L10n.tr("project.use"), target: self, action: #selector(useTemplateTapped))
        useButton.tag = templates.firstIndex(where: { $0.slug == tpl.slug }) ?? -1
        useButton.bezelStyle = .rounded

        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.toolTip = L10n.tr("project.more")
        more.addItem(withTitle: "")
        let menu = more.menu ?? NSMenu()
        let duplicateItem = NSMenuItem(title: L10n.tr("project.duplicate"), action: #selector(duplicateTemplateTapped), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.tag = useButton.tag
        let revealItem = NSMenuItem(title: L10n.tr("project.reveal"), action: #selector(revealTemplateTapped), keyEquivalent: "")
        revealItem.target = self
        revealItem.tag = useButton.tag
        menu.addItem(duplicateItem)
        menu.addItem(revealItem)

        let textStack = NSStackView(views: [title, desc])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let actionStack = NSStackView(views: [useButton, more])
        actionStack.spacing = 4

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [textStack, spacer, actionStack, badge])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])
        return card
    }

    @objc private func useTemplateTapped(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < templates.count else { return }
        selectedTemplate = templates[idx]
        // 选中模板后进入下一步（选目标）；不自动弹目录选择器
        if currentStep < ProjectPanelController.totalSteps { currentStep += 1 }
        renderStep()
    }

    @objc private func duplicateTemplateTapped(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < templates.count else { return }
        let tpl = templates[idx]
        let userDir = projectTemplatesUserDir()
        if let newSlug = ProjectTemplateStore.duplicate(template: tpl, into: userDir) {
            AppLog.shared.log("project template duplicated: \(tpl.slug) -> \(newSlug)")
            reloadTemplates()
            refreshTemplateList()
        }
    }

    @objc private func revealTemplateTapped(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < templates.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: templates[idx].dirPath)])
    }

    // MARK: step 2 — 选目标

    private var targetPathLabel: NSTextField?
    private var targetModeLabel: NSTextField?

    private func renderStepTarget() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L10n.tr("project.targetTitle"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let pathLabel = NSTextField(wrappingLabelWithString: targetDir ?? L10n.tr("project.targetNone"))
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        targetPathLabel = pathLabel

        let modeLabel = NSTextField(labelWithString: "")
        modeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        targetModeLabel = modeLabel

        let chooseButton = NSButton(title: L10n.tr("project.chooseDir"), target: self, action: #selector(chooseTargetTapped))
        chooseButton.bezelStyle = .rounded
        chooseButton.tag = entryMode == .newProject ? 1 : 0

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(pathLabel)
        stack.addArrangedSubview(modeLabel)
        stack.addArrangedSubview(chooseButton)

        wizardContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wizardContent.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: wizardContent.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: wizardContent.trailingAnchor, constant: -12),
        ])
        refreshTargetStep()
    }

    @objc private func chooseTargetTapped(_ sender: NSButton) {
        let createAllowed = sender.tag == 1
        guard let pick = chooseDirectory(createAllowed: createAllowed) else { return }
        targetDir = pick
        detectExistingMode()
        refreshTargetStep()
    }

    private func refreshTargetStep() {
        if let label = targetPathLabel {
            label.stringValue = targetDir ?? L10n.tr("project.targetNone")
        }
        if let mode = targetModeLabel {
            if existingMode {
                mode.stringValue = L10n.tr("project.modeExisting")
            } else {
                mode.stringValue = L10n.tr("project.modeNew")
            }
        }
    }

    // MARK: step 3 — 变量 + 步骤

    private func renderStepVariables() {
        guard let tpl = selectedTemplate else { return }
        variableFields = []
        variableKeys = []
        stepCheckboxes = []

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.translatesAutoresizingMaskIntoConstraints = false

        // 变量表单
        let variablesTitle = NSTextField(labelWithString: L10n.tr("project.variablesTitle"))
        variablesTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        outer.addArrangedSubview(variablesTitle)

        let folderName = targetDir.map { ($0 as NSString).lastPathComponent } ?? ""
        for v in tpl.manifest.variables {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(labelWithString: v.required ? "(v.label) *" : v.label)
            label.font = .systemFont(ofSize: 12)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let field = NSTextField(string: "")
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = v.defaultValue
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            // 默认值渲染
            var warnings: [String] = []
            let renderedDefault = TemplatePlaceholders.render(v.defaultValue, variables: [:], folderName: folderName, warnings: &warnings)
            if !v.defaultValue.isEmpty && renderedDefault != "{{(v.defaultValue)}}" {
                field.stringValue = renderedDefault
            }
            row.addArrangedSubview(label)
            row.addArrangedSubview(field)
            outer.addArrangedSubview(row)
            variableKeys.append(v.key)
            variableFields.append(field)
        }

        // 步骤勾选
        let stepsTitle = NSTextField(labelWithString: L10n.tr("project.stepsTitle"))
        stepsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        outer.addArrangedSubview(stepsTitle)
        for step in tpl.manifest.steps {
            let display: String
            if step.type == .command, let program = step.program {
                display = "\(step.displayLabel)  ·  \(([program] + (step.args ?? [])).joined(separator: " "))"
            } else {
                display = step.displayLabel
            }
            let checkbox = NSButton(checkboxWithTitle: display, target: nil, action: nil)
            checkbox.state = .on
            checkbox.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            outer.addArrangedSubview(checkbox)
            stepCheckboxes.append(checkbox)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedStackView()
        doc.orientation = .vertical
        doc.alignment = .leading
        doc.spacing = 12
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addArrangedSubview(outer)
        scroll.documentView = doc

        wizardContent.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: wizardContent.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: wizardContent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wizardContent.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: wizardContent.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    // MARK: step 4 — 摘要与执行

    private var summaryDescription: NSTextField?
    private var summaryScroll: NSScrollView?

    private func renderStepSummary() {
        guard let tpl = selectedTemplate, let target = targetDir else { return }

        let desc = NSTextField(wrappingLabelWithString: L10n.tr("project.summaryTarget", tpl.name, target))
        desc.font = .systemFont(ofSize: 12)
        desc.lineBreakMode = .byTruncatingMiddle
        summaryDescription = desc

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor

        let fileList = NSTextView()
        fileList.isEditable = false
        fileList.isSelectable = true
        fileList.drawsBackground = false
        fileList.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fileList.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = fileList
        scroll.translatesAutoresizingMaskIntoConstraints = false
        summaryScroll = scroll

        registerWorkspaceCheckbox.title = L10n.tr("project.registerWorkspace")
        registerWorkspaceCheckbox.state = .on
        registerWorkspaceCheckbox.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [desc, summaryLabel, scroll, registerWorkspaceCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        wizardContent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wizardContent.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: wizardContent.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: wizardContent.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: 150),
            stack.widthAnchor.constraint(equalTo: wizardContent.widthAnchor, constant: -24),
        ])

        // dry-run 规划
        let enabled = enabledStepIndexes()
        let plan = TemplateExecutor.plan(template: tpl, targetDir: target, variables: collectedVariables(), enabledSteps: enabled)
        currentPlan = plan
        summaryLabel.stringValue = L10n.tr("project.summaryFiles", plan.creates, plan.skips, plan.overwrites)
        var lines = [String]()
        for entry in plan.files where entry.action != "skip" {
            lines.append(entry.action == "overwrite" ? "⟳ \(entry.relativePath)" : "+ \(entry.relativePath)")
        }
        if let git = plan.git {
            let branch = tpl.manifest.steps.first { $0.type == .git }?.gitBranch ?? "main"
            lines.append(git.initRepo ? "git init -b \(branch)" : "git")
            if git.initialCommit { lines.append("git add -A + 初始提交") }
        }
        for cmd in plan.commands {
            lines.append("$ \(cmd.display)")
        }
        for w in plan.warnings { lines.append("⚠ \(w)") }
        fileList.string = lines.joined(separator: "\\n")
        // 重建日志视图（首次进入 step4 时）
        if logScroll == nil {
            let log = NSTextView()
            log.isEditable = false
            log.isSelectable = true
            log.drawsBackground = false
            log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            log.textContainerInset = NSSize(width: 6, height: 6)
            let ls = NSScrollView()
            ls.hasVerticalScroller = true
            ls.drawsBackground = false
            ls.borderType = .noBorder
            ls.documentView = log
            logTextView = log
            logScroll = ls
        }
        logScroll?.isHidden = true
        logTextView?.string = ""
    }

    private func enabledStepIndexes() -> Set<Int> {
        guard let tpl = selectedTemplate else { return [] }
        var enabled = Set<Int>()
        for (idx, _) in tpl.manifest.steps.enumerated() {
            if idx < stepCheckboxes.count && stepCheckboxes[idx].state == .on {
                enabled.insert(idx)
            }
        }
        return enabled
    }

    private func collectedVariables() -> [String: String] {
        var vars: [String: String] = [:]
        for (i, key) in variableKeys.enumerated() {
            if i < variableFields.count {
                vars[key] = variableFields[i].stringValue
            }
        }
        return vars
    }

    // MARK: - 执行

    private func startExecution() {
        guard let tpl = selectedTemplate, let target = targetDir, let plan = currentPlan else { return }
        executing = true
        cancelledFlag.set(false)
        wizardBackButton.isEnabled = false
        wizardNextButton.isEnabled = false
        wizardCancelButton.isEnabled = true
        logScroll?.isHidden = false
        logTextView?.string = ""
        appendLog(L10n.tr("project.logBegin", tpl.name, target))

        let folderName = (target as NSString).lastPathComponent
        // 主线程捕获，避免后台队列访问 UI 控件（data race）
        let variables = collectedVariables()
        let shouldRegister = registerWorkspaceCheckbox.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var tailLogs: [String] = []
            let result = TemplateExecutor.execute(
                plan: plan, template: tpl, targetDir: target,
                variables: variables,
                cancelled: { self.cancelledFlag.get() },
                logLine: { [weak self] line in
                    DispatchQueue.main.async { self?.appendLog(line) }
                })
            // 尾动作：工作区注册（用户勾选 + 未取消时）；只收集日志，不在此线程改 UI
            var sessionId: String?
            if shouldRegister && !result.cancelled {
                sessionId = self.workspaceTailRegister(path: target, logs: &tailLogs)
            }
            DispatchQueue.main.async {
                for line in tailLogs { self.appendLog(line) }
                self.endExecution(result: result, sessionId: sessionId, folderName: folderName)
            }
        }
    }

    /// 工作区尾动作（同步 RPC，后台队列调用）：workspace.create({path}) → session.create({workspaceId})。
    /// 只做 RPC 与日志收集（logs 追加），不在此线程访问 UI。
    private func workspaceTailRegister(path: String, logs: inout [String]) -> String? {
        logs.append(L10n.tr("project.logWorkspace"))
        guard let port = serverPortProvider?() else {
            logs.append(L10n.tr("project.logNoPort"))
            return nil
        }
        guard let ws = ProjectPanelHTTP.rpc(port: port, method: "workspace.create", payload: ["path": path]),
              let workspace = ws["workspace"] as? [String: Any],
              let workspaceId = workspace["workspaceId"] as? String else {
            logs.append(L10n.tr("project.logWorkspaceFail"))
            return nil
        }
        logs.append(L10n.tr("project.logWorkspaceOk", workspaceId))
        guard let session = ProjectPanelHTTP.rpc(port: port, method: "session.create", payload: ["workspaceId": workspaceId]),
              let sessionId = session["sessionId"] as? String else {
            logs.append(L10n.tr("project.logSessionFail"))
            return nil
        }
        logs.append(L10n.tr("project.logSessionOk", sessionId))
        return sessionId
    }

    private func appendLog(_ text: String) {
        guard let log = logTextView else { return }
        let full = log.string.isEmpty ? text : log.string + "\n" + text
        log.string = full
        log.scrollToEndOfDocument(nil)
    }

    private func endExecution(result: ApplyResult, sessionId: String?, folderName: String) {
        executing = false
        wizardCancelButton.isEnabled = true
        lastDonePath = targetDir
        lastDoneSessionId = sessionId
        if result.cancelled {
            appendLog(L10n.tr("project.logCancelled"))
            showHome()
            return
        }
        onProjectReady?(lastDonePath ?? "", sessionId)
        showDoneView(name: folderName, sessionId: sessionId)
    }

    // MARK: - 完成视图

    private func buildDoneView() {
        doneTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        doneDetail.font = .systemFont(ofSize: 12)
        doneDetail.textColor = .secondaryLabelColor
        doneDetail.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let dshButton = NSButton(title: L10n.tr("project.openInDsh"), target: self, action: #selector(doneOpenInDsh))
        dshButton.bezelStyle = .rounded
        let terminalButton = NSButton(title: L10n.tr("project.openTerminal"), target: self, action: #selector(doneOpenTerminal))
        terminalButton.bezelStyle = .rounded
        let fileButton = NSButton(title: L10n.tr("project.openFilePanel"), target: self, action: #selector(doneOpenFilePanel))
        fileButton.bezelStyle = .rounded
        let finderButton = NSButton(title: L10n.tr("project.openFinder"), target: self, action: #selector(doneOpenFinder))
        finderButton.bezelStyle = .rounded
        let anotherButton = NSButton(title: L10n.tr("project.another"), target: self, action: #selector(doneAnother))
        anotherButton.bezelStyle = .rounded

        let row1 = NSStackView(views: [dshButton, terminalButton, fileButton])
        row1.spacing = 8
        let row2 = NSStackView(views: [finderButton, anotherButton])
        row2.spacing = 8

        stack.addArrangedSubview(doneTitle)
        stack.addArrangedSubview(doneDetail)
        stack.addArrangedSubview(row1)
        stack.addArrangedSubview(row2)

        doneView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doneView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: doneView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doneView.trailingAnchor, constant: -12),
        ])
    }

    private func showDoneView(name: String, sessionId: String?) {
        homeView.isHidden = true
        wizardView.isHidden = true
        doneView.isHidden = false
        doneTitle.stringValue = L10n.tr("project.doneTitle", name)
        if let sessionId = sessionId {
            doneDetail.stringValue = L10n.tr("project.doneDetail", sessionId)
        } else {
            doneDetail.stringValue = L10n.tr("project.doneDetailNoSession")
        }
    }

    @objc private func doneOpenInDsh() {
        // onProjectReady 已在 endExecution 调用（设当前项目 + 切会话）；此处再点 → 重新回调
        if let path = lastDonePath {
            onProjectReady?(path, lastDoneSessionId)
        }
    }

    @objc private func doneOpenTerminal() {
        if let path = lastDonePath { onOpenTerminal?(path) }
    }

    @objc private func doneOpenFilePanel() {
        if let path = lastDonePath { onOpenInFilePanel?(path) }
    }

    @objc private func doneOpenFinder() {
        if let path = lastDonePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    @objc private func doneAnother() {
        selectedTemplate = nil
        targetDir = nil
        currentStep = 1
        showHome()
    }

    // MARK: - 语言切换 tooltip 刷新（main.swift applyLanguage 调用）

    func refreshTooltips() {
        headerTitle.text = L10n.tr("project.title")
        rescanButton.toolTip = L10n.tr("project.rescan")
        hideButton.toolTip = L10n.tr("preview.closePanel")
    }

    // MARK: - helpers

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

// MARK: - 小工具

/// 线程安全的布尔标志（执行取消）。
private final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    func set(_ x: Bool) { lock.lock(); value = x; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 与 core（session-driver.js）一致的 client-request RPC 信封；同步等待（后台队列调用）。
enum ProjectPanelHTTP {
    static func rpc(port: Int, method: String, payload: [String: Any], timeout: TimeInterval = 10) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = timeout
        let rpcId = UUID().uuidString
        let body: [String: Any] = ["type": "client-request", "rpcId": rpcId, "method": method, "payload": payload]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  (result["ok"] as? Bool) == true,
                  let value = result["value"] as? [String: Any] else { return }
            out = value
        }.resume()
        _ = sem.wait(timeout: .now() + timeout)
        return out
    }
}
