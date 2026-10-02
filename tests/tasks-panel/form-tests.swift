import AppKit
import Foundation

// Headless tests for the task panel's VIEWS: the two inline forms (新建任务 /
// 新建队列 and their edit modes) and the card / queue-header renderers.
//
// The forms exist so the panel never raises a modal dialog, so these checks are
// about exactly that contract: the fields are real text fields, the submit
// button follows what is in them, an incomplete draft explains itself instead of
// silently failing, and submitting hands the panel a validated model. Layout is
// asserted too — a card that does not fill the list width was a real bug.
//
// No window, no dsh server: only the models and the views.

_ = NSApplication.shared

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL \(label)") }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL \(label): got \(actual), want \(expected)")
    }
}

func section(_ name: String) { print("--- \(name) ---") }

/// Lay a view out at the panel's list width and report the size it settled on.
func layout(_ view: NSView, width: CGFloat) -> NSSize {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
    view.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    // Two passes: a wrapping label only learns its width once the form has been
    // laid out, so the first pass settles the width and the second measures the
    // wrapped height (AppKit does the same in the running app).
    host.layoutSubtreeIfNeeded()
    host.layoutSubtreeIfNeeded()
    return view.frame.size
}

/// 设置抽屉里仓库下拉的标题列表（headless 断言用）。
func repoPopupTitles(_ form: TaskSettingsView) -> [String] {
    (0..<form.repoPopUp.numberOfItems).compactMap { form.repoPopUp.item(at: $0)?.title }
}

/// 模拟从下拉里选中第 `index` 个仓库。
func selectRepo(_ form: TaskSettingsView, _ index: Int) {
    form.repoPopUp.selectItem(at: index)
    form.repoSelected(form.repoPopUp)
}

/// 设置抽屉里 issue 归属下拉的标题列表。
func issueRepoPopupTitles(_ form: TaskSettingsView) -> [String] {
    (0..<form.issueRepoPopUp.numberOfItems).compactMap { form.issueRepoPopUp.item(at: $0)?.title }
}

/// Every descendant of `view` (depth-first) that is a `type` — the cards are
/// stacks inside stacks, so their rows are reached by walking, not by index.
func descendants<T>(_ view: NSView, of type: T.Type) -> [T] {
    view.subviews.flatMap { subview -> [T] in
        let match = (subview as? T).map { [$0] } ?? []
        return match + descendants(subview, of: type)
    }
}

/// Does this card/header carry the row marker for `symbol`? The glyph views are the
/// only NSImageViews the two rows build themselves, and they are identified for exactly
/// this question (a symbol cannot be read back out of an NSImageView).
func hasGlyph(_ view: NSView, _ symbol: String) -> Bool {
    descendants(view, of: NSImageView.self).contains { $0.identifier?.rawValue == "taskGlyph:" + symbol }
}

/// What a text field's delegate receives while the user types.
func typed(_ field: NSTextField) -> Notification {
    Notification(name: NSControl.textDidChangeNotification, object: field)
}

/// Type into the task composer's ONE box — the same notification its
/// NSTextViewDelegate gets from the real editor.
func type(_ form: TaskComposerView, _ text: String) {
    form.editor.string = text
    form.textDidChange(Notification(name: NSText.didChangeNotification, object: form.editor))
}

// MARK: - 新建任务 / 编辑任务

section("inline 新建任务 form")
do {
    var submitted: TaskComposerModel?
    var cancelled = false
    let form = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    form.onSubmit = { submitted = $0 }
    form.onCancel = { cancelled = true }

    let size = layout(form, width: 320)
    eq(size.width, 320, "the form fills the list width")
    check(size.height > 140, "the form carries its one box and a button row")
    eq(form.submitButton.title, "create", "the primary button creates")
    check(!form.submitButton.isEnabled, "an empty form cannot be submitted")
    check(form.hint.isHidden, "and shows no problem yet")
    check(!form.editorPlaceholder.isHidden, "the empty box shows its placeholder")

    // 只有一行也是完整的任务：这一行同时是标题和描述。
    type(form, "Polish README")
    check(form.submitButton.isEnabled, "a single line is enough to create")
    check(form.hint.isHidden, "and the form does not nag while it is being typed into")
    check(form.editorPlaceholder.isHidden, "the placeholder goes away once there is text")

    type(form, "Polish README\ntidy it up")
    form.submitTapped()
    eq(submitted?.draft.normalizedTitle, "Polish README", "submitting hands over the first line as the title")
    eq(submitted?.draft.normalizedBody, "tidy it up", "and the lines after it as the description")
    eq(submitted?.mode, .create, "in create mode")
    check(!cancelled, "submitting does not close the form (完成 / Esc does)")

    // Submitting an EMPTY box explains what is missing.
    let empty = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    empty.submitTapped()
    check(!empty.hint.isHidden, "an attempted submit shows the problem")
    eq(empty.hint.stringValue, "errName", "and names the missing title")

    // A plain Enter stays a newline (the lines ARE the task — first one is the
    // title), Esc closes. (⌘↩ submits; it reads the current event, so the headless
    // run leaves that path to manual QA.)
    var escClosed = false
    let keys = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    keys.onCancel = { escClosed = true }
    _ = layout(keys, width: 320)
    type(keys, "Only a title")
    check(!keys.textView(keys.editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
          "a plain Enter is handed to the editor (a newline)")
    check(keys.textView(keys.editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
          "Esc is handled by the form")
    check(escClosed, "…and Esc asks the panel to close it")
}

section("inline 编辑任务 form")
do {
    let task = TaskItem.manual(title: "Old title", body: "old body", id: "manual-0030aaaa")
    var submitted: TaskComposerModel?
    let form = TaskComposerView(model: TaskComposerModel.edit(task))
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 320)

    eq(form.editor.string, "Old title\nold body", "title and description are prefilled into the box")
    eq(form.submitButton.title, "save", "编辑 saves")
    eq(form.closeActionButton.title, "cancel", "编辑 can be cancelled")
    check(form.submitButton.isEnabled, "a prefilled form can be saved")

    // 单行任务：回填一行（不是同一句话写两遍）。
    let oneLiner = TaskComposerView(model: TaskComposerModel.edit(
        TaskItem.manual(title: "One line", body: "One line", id: "manual-0066aaaa")))
    _ = layout(oneLiner, width: 320)
    eq(oneLiner.editor.string, "One line", "a one-line task opens as one line")

    type(form, "New title\nand a new description")
    form.submitTapped()
    eq(submitted?.mode, .edit(taskID: "manual-0030aaaa"), "saving keeps the task id")
    eq(submitted?.draft.normalizedTitle, "New title", "and carries the edited title")
    eq(submitted?.draft.normalizedBody, "and a new description", "and the edited description")
}

// MARK: - 新建队列 / 队列设置

section("inline 新建队列 form")
do {
    var submitted: QueueComposerModel?
    let form = QueueComposerView(model: QueueComposerModel.create(taskID: "manual-0031aaaa"))
    form.onSubmit = { submitted = $0 }

    let size = layout(form, width: 320)
    eq(size.width, 320, "the form fills the list width")
    // Creating a queue asks for a NAME: 分支 / 基于分支 / PR live behind 高级设置,
    // so the collapsed form is deliberately short.
    check(size.height < 240, "a new queue's form asks for a name and little else")
    eq(form.submitButton.title, "create", "creating from a card joins that task")
    check(!form.submitButton.isEnabled, "a nameless queue cannot be created")
    check(form.prSwitch.isHidden,
          "no dead PR switch without a GitHub repo (the reason is a sentence instead)")
    check(!form.prNote.isHidden, "and that sentence is on screen")
    eq(form.branchHint.stringValue, "branchWillUse(branchAuto)",
       "with no name there is no exact branch yet, only the auto wording")
    check(form.advancedStack.isHidden, "creating a queue only asks for a name: 高级设置 is collapsed")
    eq(form.branchField.placeholderString, "branchPlaceholderCreate",
       "creating says the empty field DERIVES a branch (it never means 不切分支)")

    form.nameField.stringValue = "Dark Mode"
    form.controlTextDidChange(typed(form.nameField))
    check(form.submitButton.isEnabled, "a named queue can be created")
    eq(form.branchHint.stringValue, "branchWillUse(feature/dark-mode)",
       "the derived branch follows the name as it is typed")

    form.prSwitch.state = .on
    form.submitTapped()
    eq(submitted?.normalizedName, "Dark Mode", "the typed name is submitted")
    eq(submitted?.mode.taskID, "manual-0031aaaa", "the task waiting for a queue comes along")
    eq(submitted?.branchValue, nil, "an empty branch asks for the derived default")
    eq(submitted?.autoPR, true, "and the PR switch is carried")
}

section("inline 队列设置 form")
do {
    var queue = TaskQueue(id: "q-3333", name: "Lane", branch: "feature/lane", baseBranch: "main")
    queue.autoPR = true
    var submitted: QueueComposerModel?
    let form = QueueComposerView(model: QueueComposerModel.edit(queue, prAvailable: true))
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 320)

    eq(form.submitButton.title, "save", "settings save")
    eq(form.nameField.stringValue, "Lane", "the name is prefilled")
    eq(form.branchField.stringValue, "feature/lane", "the branch is prefilled")
    eq(form.baseField.stringValue, "main", "the base branch is prefilled")
    eq(form.prSwitch.state, .on, "the PR switch reflects the queue")
    check(form.prSwitch.isEnabled, "and stays live in a GitHub workspace")
    check(!form.advancedStack.isHidden, "editing a queue opens 高级设置 (that is what the user came for)")

    // Clearing the branch means "run on whatever is checked out".
    form.branchField.stringValue = ""
    form.controlTextDidChange(typed(form.branchField))
    eq(form.branchHint.stringValue, "branchWillUse(noBranch)",
       "an empty branch says it will not switch branches")
    eq(form.branchField.placeholderString, "branchPlaceholderEdit",
       "editing explains the empty field as 不切分支 — the opposite of creating")
    form.submitTapped()
    eq(submitted?.mode.queueID, "q-3333", "the edited queue is identified")
    eq(submitted?.branchValue, nil, "and the cleared branch is submitted as no branch")
    eq(submitted?.normalizedBaseBranch, "main", "the base branch survives")
}

section("非 git 工作区：新建队列表单直接说清「不切分支」")
do {
    // 目录不是 git 仓库：开关自己就是开的、且不可点（那是事实，不是选项），提示说明原因，
    // 分支字段退出使用 —— 提交出来的是一个「显式不带分支」的队列，不是注定失败的队列。
    var submitted: QueueComposerModel?
    let model = QueueComposerModel.create(taskID: "manual-0034aaaa")
        .forWorkspace(git: false, pr: false)
    let form = QueueComposerView(model: model)
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 320)

    eq(form.skipBranchSwitch.state, .on, "没有仓库时开关就是开着的")
    check(!form.skipBranchSwitch.isEnabled, "而且不可点：这里没有可选项")
    eq(form.branchHint.stringValue, "notGitRepo", "提示说的是原因，不是承诺")
    check(!form.branchField.isEnabled, "分支字段退出使用")
    check(!form.baseField.isEnabled, "基于分支也是")
    eq(form.branchField.placeholderString, "branchPlaceholderEdit",
       "字段里写的是「不切分支」，不是「留空 = 自动生成」")

    form.nameField.stringValue = "Docs Cleanup"
    form.controlTextDidChange(typed(form.nameField))
    form.submitTapped()
    eq(submitted?.branchValue, "", "建出来的队列显式不带分支")
    eq(submitted?.skipsBranch, true, "模型也这么说")

    // 同样的表单在 git 仓库里：开关是一个真选项，默认关着，提示照旧给派生分支。
    let gitForm = QueueComposerView(model: QueueComposerModel.create()
        .forWorkspace(git: true, pr: true)
        .typed(name: "Docs Cleanup", branch: "", baseBranch: "main", autoPR: false))
    _ = layout(gitForm, width: 320)
    check(gitForm.skipBranchSwitch.isEnabled, "git 仓库里这个开关是能点的")
    eq(gitForm.skipBranchSwitch.state, .off, "默认不勾")
    eq(gitForm.branchHint.stringValue, "branchWillUse(feature/docs-cleanup)", "照旧派生分支")
    check(gitForm.branchField.isEnabled, "分支字段是活的")

    // 勾上之后：字段静下来，提示不再承诺分支，提交就是「不切分支」。
    var flipped: QueueComposerModel?
    gitForm.onSubmit = { flipped = $0 }
    gitForm.skipBranchSwitch.state = .on
    gitForm.skipBranchTapped()
    eq(gitForm.branchHint.stringValue, "branchSkipped", "勾上后提示改口")
    check(!gitForm.branchField.isEnabled, "字段跟着静下来")
    gitForm.submitTapped()
    eq(flipped?.branchValue, "", "提交的也是不切分支")

    // 开关住在「提示 / 高级设置」那一行上：最小面板宽度下这一行不得撑破表单
    // （提示文字自己截断，开关与高级设置都得留在表单里面）。
    let narrow = QueueComposerView(model: QueueComposerModel.create().forWorkspace(git: true, pr: true))
    _ = layout(narrow, width: 300)
    check(narrow.skipBranchSwitch.frame.width > 0, "开关有自己的宽度")
    check(narrow.skipBranchSwitch.frame.maxX <= narrow.bounds.width,
          "窄面板下开关不越出表单（(narrow.skipBranchSwitch.frame.maxX) > (narrow.bounds.width)）")
    check(narrow.advancedButton.frame.maxX <= narrow.bounds.width,
          "高级设置按钮也还在表单里")
}

// MARK: - Cards

section("card and queue header layout")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "A fairly long task title that has to wrap in a narrow panel",
                               body: "the description an agent receives", id: "manual-0032aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "A queue with a long name")
    _ = board.enqueue(taskID: task.id, into: queue.id)

    let card = TaskCardView(model: TaskCardModel.build(task, board: board, expanded: true, githubRepo: false))
    let cardSize = layout(card, width: 320)
    eq(cardSize.width, 320, "the card fills the list width")
    check(cardSize.height > 80, "an expanded card fits its detail and its buttons")

    let collapsedCard = TaskCardView(model: TaskCardModel.build(task, board: board, expanded: false, githubRepo: false))
    let collapsedSize = layout(collapsedCard, width: 320)
    check(collapsedSize.height < cardSize.height, "a collapsed card is the compact one")

    let expandedHeader = TaskQueueHeaderView(model: QueueHeaderModel.build(board.queue(queue.id)!, board: board,
                                                                          collapsed: false))
    let headerSize = layout(expandedHeader, width: 320)
    eq(headerSize.width, 320, "the queue header fills the list width")
    check(headerSize.height > 40, "an expanded header carries the branch and the progress bar")

    let collapsedHeader = TaskQueueHeaderView(model: QueueHeaderModel.build(board.queue(queue.id)!, board: board,
                                                                           collapsed: true))
    let oneLiner = layout(collapsedHeader, width: 320)
    check(oneLiner.height < headerSize.height, "a collapsed queue header is one line")

    // 行标（用户 2026-09-27：队列名、任务名前都要有图标）：卡片是 checklist、
    // 队列头是 rectangle.stack，都紧接着名字，窄面板下也不会把标题挤没。
    check(hasGlyph(card, "checklist"), "任务卡片在任务名前有行标")
    check(hasGlyph(expandedHeader, "rectangle.stack"), "队列头在队列名前有行标")
    check(hasGlyph(collapsedHeader, "rectangle.stack"), "折叠的队列头也有")
    let glyph = descendants(card, of: NSImageView.self)
        .first { $0.identifier?.rawValue == "taskGlyph:checklist" }
    if let glyph = glyph {
        check(glyph.frame.width > 0 && glyph.frame.height > 0, "行标有实际尺寸")
        check(glyph.frame.maxX < card.bounds.width, "行标在卡片里，不越界")
    } else {
        check(false, "行标视图应当存在")
    }
}

section("队列头：交付排在关闭之前，PR 链接仍在最后")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "改 README", body: nil, id: "manual-hh301010")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", branch: "feature/x", autoPR: true)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markDone(task.id)

    // 还没有 PR：那一格是图标按钮，工具提示是「打开 PR」。
    let openModel = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                           prAvailable: true)
    check(openModel.canOpenPR, "完成的队列可以开 PR")
    let openHeader = TaskQueueHeaderView(model: openModel)
    _ = layout(openHeader, width: 320)
    let buttons = descendants(openHeader, of: CustomIconButton.self)
    let publish = buttons.first { $0.toolTip == L10n.tr("tasks.queue.openPR") }
    let close = buttons.first { $0.toolTip == L10n.tr("tasks.queue.close") }
    check(publish != nil, "行上有「打开 PR」（发布）")
    check(close != nil, "行上有「关闭队列」")
    if let publish = publish, let close = close {
        let publishFrame = publish.convert(publish.bounds, to: openHeader)
        let closeFrame = close.convert(close.bounds, to: openHeader)
        check(publishFrame.maxX <= closeFrame.minX + 1, "发布排在关闭之前")
        check(publishFrame.maxX <= openHeader.bounds.width, "没有越出队列头")
    }

    // 已经有 PR：那一格变成 PR 链接，同样在最右。
    _ = board.setQueuePRError(queue.id, nil)
    var withPR = board
    withPR.queues[0].prUrl = "https://github.com/o/r/pull/42"
    let linkModel = QueueHeaderModel.build(withPR.queue(queue.id)!, board: withPR, collapsed: false,
                                           prAvailable: true)
    let linkHeader = TaskQueueHeaderView(model: linkModel)
    _ = layout(linkHeader, width: 320)
    let link = descendants(linkHeader, of: NSButton.self).first { $0.toolTip == withPR.queue(queue.id)?.prUrl }
    check(link != nil, "PR 链接在行上")
    if let link = link, let row = link.superview as? NSStackView {
        check(row.arrangedSubviews.last === link, "链接是这一行的最后一个控件")
    }
}

section("交付失败：原因写在队列卡上，按钮 tooltip 仍是动作说明")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "改 README", body: nil, id: "manual-hh302020")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", branch: "feature/x", autoPR: true)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markDone(task.id)
    _ = board.setQueuePRError(queue.id, "tasks.errPRNoBranch")

    let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                       prAvailable: true)
    eq(model.prErrorKey, "tasks.errPRNoBranch", "失败原因跟着队列到模型")
    let header = TaskQueueHeaderView(model: model)
    _ = layout(header, width: 320)
    // 按钮永远说它做什么——失败不会把 tooltip 顶掉。
    let publish = descendants(header, of: CustomIconButton.self)
        .first { $0.toolTip == L10n.tr("tasks.queue.openPR") }
    check(publish != nil, "发布按钮的 tooltip 仍是动作说明")
    // 失败原因在卡片上。
    let labels = descendants(header, of: NSTextField.self).map { $0.stringValue }
    check(labels.contains(L10n.tr("tasks.errPRNoBranch")), "失败原因显示在队列卡上")

    // 折叠时失败也要露出来（成功摘要才随折叠隐藏）。
    let collapsed = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: true,
                                           prAvailable: true)
    let collapsedHeader = TaskQueueHeaderView(model: collapsed)
    _ = layout(collapsedHeader, width: 320)
    let collapsedLabels = descendants(collapsedHeader, of: NSTextField.self).map { $0.stringValue }
    check(collapsedLabels.contains(L10n.tr("tasks.errPRNoBranch")), "折叠的队列也显示失败原因")
}
section("交付结果：默认一行，可展开全文")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "改 README", body: nil, id: "manual-hh303030")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane", branch: "feature/x")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markDone(task.id)
    _ = board.setQueueIntegrationNote(queue.id, "第一行：已合并到 main\n第二行：细节\n第三行：更多")

    let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    check(model.canExpandIntegrationNote, "多行结果可以展开")
    let header = TaskQueueHeaderView(model: model)
    var toggled = false
    header.onToggleNote = { toggled = true }
    _ = layout(header, width: 320)
    let labels = descendants(header, of: NSTextField.self).map { $0.stringValue }
    check(labels.contains("第一行：已合并到 main"), "折叠时显示第一行")
    check(!labels.contains(where: { $0.contains("第三行") }), "折叠时不显示后面的内容")
    let toggle = descendants(header, of: NSButton.self)
        .first { $0.title == L10n.tr("tasks.queue.note.expand") }
    check(toggle != nil, "有「展开」入口")
    toggle?.performClick(nil)
    check(toggled, "点击展开会通知面板")

    // 展开态：整段都在卡片上。
    let expandedModel = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                               noteExpanded: true)
    let expandedHeader = TaskQueueHeaderView(model: expandedModel)
    _ = layout(expandedHeader, width: 320)
    let expandedLabels = descendants(expandedHeader, of: NSTextField.self).map { $0.stringValue }
    check(expandedLabels.contains(where: { $0.contains("第三行") }), "展开后显示全文")
    let collapse = descendants(expandedHeader, of: NSButton.self)
        .first { $0.title == L10n.tr("tasks.queue.note.collapse") }
    check(collapse != nil, "展开后给「收起」入口")
}

section("多仓库交付卡片：逐仓库结果显示，PR 链接可点")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "多仓库", body: nil, id: "manual-reporun01")
    board.tasks = [task]
    let queue = board.createQueue(name: "Multi", branch: "feature/x", autoPR: true,
                                  repos: ["repo-a", "repo-b"])
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markDone(task.id)
    _ = board.setQueueRepoRuns(queue.id, [
        QueueRepoRun(repoID: ".", branch: "feature/x", base: "main",
                     intent: .pr, effective: .pr, status: .done,
                     prUrl: "https://github.com/o/r/pull/7"),
        QueueRepoRun(repoID: "repo-b", branch: "feature/x", base: "master",
                     intent: .pr, effective: .merge, status: .failed, note: "冲突，请用户介入"),
    ])

    let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    check(model.showsRepoRuns, "有交付记录的队列显示逐仓库结果区")
    eq(model.repoRuns.count, 2, "两个仓库都在模型里")
    eq(QueueHeaderModel.repoDisplayName("."), L10n.tr("tasks.repoRun.root"), "根仓库显示为（工作区根）")
    eq(QueueHeaderModel.repoDisplayName("repo-b"), "repo-b/", "子仓库带斜杠")
    eq(QueueHeaderModel.repoActionLabel(.merge), L10n.tr("tasks.repoRun.action.merge"), "动作名可读")
    eq(QueueHeaderModel.repoStatusLabel(.failed), L10n.tr("tasks.repoRun.status.failed"), "状态名可读")
    eq(QueueHeaderModel.repoTone(.done), TaskTone.positive, "成功是正向色")
    eq(QueueHeaderModel.repoTone(.failed), TaskTone.negative, "失败是负向色")

    let header = TaskQueueHeaderView(model: model)
    _ = layout(header, width: 320)
    let labels = descendants(header, of: NSTextField.self).map { $0.stringValue }
    check(labels.contains("repo-b/"), "子仓库行在卡片上")
    check(labels.contains(L10n.tr("tasks.repoRun.action.merge")), "失败仓库的实际动作在卡片上")
    check(labels.contains("冲突，请用户介入"), "失败原因在卡片上")

    let link = descendants(header, of: RepoPRButton.self).first { $0.url == "https://github.com/o/r/pull/7" }
    check(link != nil, "逐仓库 PR 链接在卡片上")
    var opened: String?
    header.onOpenRepoPR = { opened = $0 }
    link?.performClick(nil)
    eq(opened, "https://github.com/o/r/pull/7", "点击逐仓库链接把 URL 交给面板")

    // 失败仓库可单独重试：只有失败行有按钮，点击把该仓库 id 交给面板。
    check(model.canRetryRepos, "队列可交付且有失败仓库 → 可重试")
    let retries = descendants(header, of: RepoRetryButton.self)
    eq(retries.map { $0.repoID }, ["repo-b"], "只有失败的仓库有重试按钮")
    var retried: String?
    header.onRetryRepo = { retried = $0 }
    retries.first?.performClick(nil)
    eq(retried, "repo-b", "点击重试把仓库 id 交给面板")

    // 成功仓库的记录不会被重试覆盖（模型层：队列仍标 done）。
    eq(model.repoRuns.first { $0.repoID == "." }?.status, .done, "成功仓库仍是已交付")

    // 折叠：逐仓库结果区不出现（与交付结果同规则）。
    let collapsedModel = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: true)
    let collapsedHeader = TaskQueueHeaderView(model: collapsedModel)
    _ = layout(collapsedHeader, width: 320)
    let collapsedLabels = descendants(collapsedHeader, of: NSTextField.self).map { $0.stringValue }
    check(!collapsedLabels.contains("repo-b/"), "折叠时不显示逐仓库结果")
}
section("fields span the whole form")
do {
    // An EMPTY NSTextField's intrinsic width is almost nothing, and a .leading
    // vertical stack hugs its widest arranged view — so a caption+field row used
    // to collapse to the caption's width (measured on screen: ~25pt wide, the
    // placeholder clipped to one character). The rows must be pinned to the form.
    let taskForm = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(taskForm, width: 360)
    // The box is the form's only input surface, and it must WRAP at the form's
    // width: an autoresizing document view used to keep a width 318pt wider than
    // the clip view, so long lines were clipped instead of wrapped.
    let editorWidth = taskForm.editor.frame.width
    check(editorWidth > 280, "the editor spans the form (got \(editorWidth)pt)")
    check(taskForm.editorBox.frame.width > 300,
          "and its box spans the form (got \(taskForm.editorBox.frame.width)pt)")

    let queueForm = QueueComposerView(model: QueueComposerModel.create())
    _ = layout(queueForm, width: 360)
    check(queueForm.nameField.frame.width > 300,
          "the queue NAME field spans the form (got \(queueForm.nameField.frame.width)pt)")
    // 分支 / 基于分支 sit in 高级设置 with their caption beside them (that is what
    // keeps the expanded form short enough not to scroll), so they are narrower —
    // still wide enough for a branch name.
    for (name, field) in [("branch", queueForm.branchField), ("base", queueForm.baseField)] {
        check(field.frame.width > 200, "the \(name) field stays usable (got \(field.frame.width)pt)")
    }

    // Widening the panel widens the box with it.
    let wide = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(wide, width: 520)
    check(wide.editor.frame.width > editorWidth, "a wider panel gives a wider box")
}

section("队列表单：基于分支的占位跟着工作区走")
do {
    let masterForm = QueueComposerView(model: QueueComposerModel.create()
        .forWorkspace(git: true, pr: true, defaultBase: "master"))
    _ = layout(masterForm, width: 400)
    eq(masterForm.baseField.placeholderString, "master", "占位是工作区自己的默认分支")
    eq(masterForm.baseField.stringValue, "master", "而且已经预填好了（可改）")

    // 默认（没有探测结果）时仍是 main。
    let plain = QueueComposerView(model: QueueComposerModel.create())
    _ = layout(plain, width: 400)
    eq(plain.baseField.placeholderString, "main", "没有探测结果时还是 main")
}

section("the description editor is a real editor")
do {
    // It is a wrapping multi-line field, so the whole area is clickable and
    // wrapped text stays visible — an NSTextView document view sized itself to one
    // line (only the first line was clickable) and its bezel did not match.
    let form = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(form, width: 430)
    // A real multi-line text VIEW, not a taller single-line field: an editable
    // NSTextField reports one line for any bounds (measured), so a tall box around
    // it was just a tall box. The one box IS the whole form now.
    check(form.editor.isVerticallyResizable, "the editor is a multi-line text view")
    check(form.editorBox is TaskFieldBox, "inside the form's own field box")
    check(form.editorBox.frame.height >= 100,
          "the empty editor is a usable area, not one line (got \(form.editorBox.frame.height)pt)")
    check(form.editorBox.frame.width > 300, "and it spans the form")

    let emptyHeight = form.editorBox.frame.height
    check(emptyHeight >= TaskFormKit.editorHeight,
          "the empty box starts at its comfortable height (\(emptyHeight)pt)")
    // 12 行：超过默认高度但不到上限 —— 框随文字长高。
    type(form, String(repeating: "一行比较长的描述文本，用来看编辑器会不会长高。", count: 12))
    _ = layout(form, width: 430)
    check(form.editorBox.frame.height > emptyHeight,
          "the editor grows with its text (\(emptyHeight) → \(form.editorBox.frame.height)pt)")

    // Past the maximum box height the TEXT grows instead, so the rest scrolls
    // under the caret rather than disappearing.
    type(form, String(repeating: "一行比较长的描述文本。\n", count: 40))
    _ = layout(form, width: 430)
    check(form.editorBox.frame.height <= TaskFormKit.editorMaxHeight + 1,
          "the box stops growing at its maximum")
    check(form.editor.frame.height > form.editorBox.frame.height,
          "and the text view grows past it (the editor scrolls)")
}

section("the queue form stays short enough to fit without scrolling")
do {
    // 高级设置 opens more controls; a form that then needs a scrollbar in a
    // normal panel is a form that should have been shorter (the section's rows sit
    // caption-BESIDE-field, and its spacing is tighter). 工作流 is a RADIO group now
    // (跟随设置 + 三档, a deliberate requirement), which costs one caption line plus
    // one row — the sheet still scrolls only in a very short panel.
    let collapsed = QueueComposerView(model: QueueComposerModel.create())
    let collapsedSize = layout(collapsed, width: 400)
    let expanded = QueueComposerView(model: QueueComposerModel.create().togglingAdvanced())
    let expandedSize = layout(expanded, width: 400)
    check(expandedSize.height > collapsedSize.height, "高级设置 makes the form taller")
    check(expandedSize.height <= 310,
          "but the expanded form still fits a normal content area (got \(expandedSize.height)pt)")
    check(expanded.branchField.frame.width > 180,
          "and the inline advanced fields keep their width (\(expanded.branchField.frame.width)pt)")
}

section("队列表单：Git 工作流单选组（跟随工作区设置 + 四档）")
do {
    // The recommendation follows the WORKSPACE, never the global default.
    eq(QueueComposerModel.create().forWorkspace(git: true, pr: true).recommendedIntegration, .pr,
       "GitHub 工作区推荐 PR")
    eq(QueueComposerModel.create().forWorkspace(git: true, pr: false).recommendedIntegration, .merge,
       "普通 git 仓库推荐合并并推送")
    eq(QueueComposerModel.create().forWorkspace(git: false, pr: false).recommendedIntegration, .none,
       "非 git 目录推荐「无」（没什么可发布的）")

    let model = QueueComposerModel.create()
        .forWorkspace(git: true, pr: true, defaultBase: "main", defaultIntegration: .pr)
        .togglingAdvanced()
    let form = QueueComposerView(model: model)
    var submitted: QueueComposerModel?
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 400)

    eq(form.integrationRadios.count, 5, "跟随设置 + 四个模式各一个单选按钮")
    check(form.integrationRadios[0].title.contains("follow"),
          "第一个是跟随工作区设置，括号里带当前默认值")
    eq(form.integrationRadios[1].title, "none", "「无」排在跟随设置之后（第一档）")
    eq(form.selectedIntegration, nil, "默认就是跟随设置")
    check(form.integrationRadios[0].state == .on, "跟随设置那个是选中态")
    check(!form.integrationNote.isHidden, "本工作区推荐在 caption 行上，可见")
    check(form.integrationNote.stringValue.contains("recommend"),
          "推荐文案来自 integration.recommend")
    // 五个 radio 必须放得下（不被截断），否则单选框反而看不清。
    for radio in form.integrationRadios {
        check(radio.frame.width >= radio.intrinsicContentSize.width - 1,
              "radio「\(radio.title)」不被截断 (frame \(radio.frame.width) >= intrinsic \(radio.intrinsicContentSize.width))")
    }

    // 选项顺序：无 / 直接推送 / 合并到基线 / Pull Request（索引 1/2/3/4，0 是跟随）。
    eq(form.integrationRadios[2].title, "push", "直接推送排在「无」之后")
    eq(form.integrationRadios[3].title, "merge", "合并到基线其后")
    eq(form.integrationRadios[4].title, "pr", "Pull Request 最后")

    // 工作区跑不了的工作流灰掉（索引：0 跟随 / 1 无 / 2 推送 / 3 合并 / 4 PR）。
    check(form.integrationRadios[4].isEnabled, "GitHub 工作区：PR 可选")
    check(form.integrationRadios[3].isEnabled, "git 工作区：合并可选")
    check(form.integrationRadios[2].isEnabled, "有远端：直接推送可选")

    let gitOnly = QueueComposerView(model: QueueComposerModel.create()
        .forWorkspace(git: true, pr: false, hasRemote: false).togglingAdvanced())
    _ = layout(gitOnly, width: 400)
    check(!gitOnly.integrationRadios[4].isEnabled, "没有 GitHub 远端：PR 灰掉")
    eq(gitOnly.integrationRadios[4].toolTip, "unavailablePr", "并说明原因")
    check(gitOnly.integrationRadios[3].isEnabled, "git 仓库仍可合并")
    check(!gitOnly.integrationRadios[2].isEnabled, "没有远端：直接推送灰掉")
    eq(gitOnly.integrationRadios[2].toolTip, "unavailablePush", "推送也说明原因")

    let plain = QueueComposerView(model: QueueComposerModel.create()
        .forWorkspace(git: false, pr: false, hasRemote: false).togglingAdvanced())
    _ = layout(plain, width: 400)
    check(!plain.integrationRadios[4].isEnabled, "非 git：PR 不可选")
    check(!plain.integrationRadios[3].isEnabled, "非 git：合并不可选")
    eq(plain.integrationRadios[3].toolTip, "unavailableMerge", "合并说明原因")
    check(!plain.integrationRadios[2].isEnabled, "非 git：推送不可选")
    check(plain.integrationRadios[1].isEnabled, "「无」永远可选")

    // 选中 merge：模型与提交都带上队列自己的覆盖。名字要填，否则表单不可提交。
    form.nameField.stringValue = "Lane"
    form.selectIntegration(.merge)
    eq(form.selectedIntegration, .merge, "选中项映射回模型（2 = merge）")
    check(form.integrationRadios[0].state == .off, "单选：跟随设置被关掉")
    form.submitTapped()
    eq(submitted?.integration, .merge, "提交时带上队列自己的工作流")
    eq(submitted?.integrationChoices.count, 5, "选项集合包含跟随设置与「无」")
}

section("多仓库队列表单：仓库选择区（N==1 锁定）")
do {
    let root = WorkspaceRepo(id: ".", absolutePath: "/tmp/ws", isGit: true, displayName: "ws")
    let a = WorkspaceRepo(id: "repo-a", absolutePath: "/tmp/ws/repo-a", isGit: true,
                         displayName: "repo-a")
    let b = WorkspaceRepo(id: "repo-b", absolutePath: "/tmp/ws/repo-b", isGit: true,
                         displayName: "repo-b")
    let form = QueueComposerView(model: QueueComposerModel.create().forRepos([root, a, b],
                                                                           primary: root))
    var submitted: QueueComposerModel?
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 400)
    eq(form.repoCheckboxes.map { $0.title }, ["ws", "repo-a", "repo-b"], "逐个列出仓库")
    check(form.repoCheckboxes[0].state == .on, "默认勾选 primary")
    check(form.repoCheckboxes[1].state == .off, "其余不勾")
    check(form.repoCheckboxes[1].isEnabled, "N>=2 时可点")
    eq(form.repoNote.stringValue, "reposHint", "并给出选择说明")

    form.repoCheckboxes[1].state = .on
    form.repoTapped(form.repoCheckboxes[1])
    check(form.repoCheckboxes[1].state == .on, "勾上第二个仓库后仍是选中态")
    form.nameField.stringValue = "Lane"
    form.controlTextDidChange(typed(form.nameField))
    form.submitTapped()
    eq(Set(submitted?.selectedRepoIDs ?? []), Set([".", "repo-a"]), "提交带上两个目标仓库")

    // N==1：显示但只读锁定。
    let locked = QueueComposerView(model: QueueComposerModel.create().forRepos([a], primary: a))
    _ = layout(locked, width: 400)
    check(locked.repoCheckboxes.count == 1, "唯一仓库也列出来")
    check(!locked.repoCheckboxes[0].isEnabled, "N==1 锁定不可点")
    eq(locked.repoNote.stringValue, "reposLocked", "并说明锁定原因")

    // 单仓库 / 普通目录：整块隐藏，表单与今天一致。
    let legacy = QueueComposerView(model: QueueComposerModel.create())
    _ = layout(legacy, width: 400)
    check(legacy.repoCheckboxes.isEmpty, "没有仓库选择区")
    check(legacy.repoBlock.isHidden, "选择区隐藏")
}

section("面板设置抽屉：token + 工作流默认值")
do {
    let model = TaskSettingsModel(token: "ghp_x", defaultIntegration: .merge,
                                  recommendedIntegration: .pr, prAvailable: true,
                                  autoCloseOnPublish: true)
    let form = TaskSettingsView(model: model)
    var submitted: TaskSettingsModel?
    form.onSubmit = { submitted = $0 }
    let settingsSize = layout(form, width: 440)
    // 两条说明都完整显示：不截断（maximumNumberOfLines = 0）且按词换行。
    eq(form.tokenHint.maximumNumberOfLines, 0, "GitHub Token 说明不截断")
    eq(form.tokenHint.lineBreakMode, .byWordWrapping, "GitHub Token 说明按词换行")
    eq(form.autoCloseHint.maximumNumberOfLines, 0, "自动关闭说明不截断")
    check(!form.autoCloseHint.isHidden, "自动关闭说明直接显示（不只是 tooltip）")
    eq(form.autoCloseHint.stringValue, "autoCloseHint", "说明文字来自 settings.autoCloseHint")
    check(settingsSize.height <= 620,
          "设置抽屉已为完整说明加高（短文案下远低于上限）(got \(settingsSize.height)pt)")
    // 短文案（L10n stub）验证不了换行：喂一段长文本，确认说明真的换行并把抽屉撑高。
    form.tokenHint.stringValue = String(repeating: "这是一段很长的说明文字，用来验证换行。", count: 6)
    let grown = layout(form, width: 440)
    check(form.tokenHint.frame.height > 20,
          "长说明换行成多行 (got \(form.tokenHint.frame.height)pt)")
    check(grown.height > settingsSize.height,
          "说明换行把抽屉撑高 (\(settingsSize.height) → \(grown.height)pt)")

    eq(form.tokenField.stringValue, "ghp_x", "token 预填")
    check(form.tokenField.frame.width > 300, "token 字段撑满抽屉 (got \(form.tokenField.frame.width)pt)")
    // 单选按钮组，不是下拉：四个 Git 工作流同时可见，推荐项带标记。
    eq(form.integrationRadios.count, 4, "四个 Git 工作流各一个单选按钮")
    eq(form.integrationRadios[0].title, "none", "「无」排第一（用户 2026-10-01）")
    eq(form.integrationRadios[1].title, "push", "直接推送其后")
    eq(form.integrationRadios[2].title, "merge", "合并到基线其后")
    check(form.integrationRadios[3].title.contains("pr"), "Pull Request 最后（推荐项带后缀）")
    eq(form.selectedIntegration, .merge, "默认选中当前默认值 merge")
    check(form.integrationRadios[2].state == .on, "merge 那一个是选中态（无/push/merge/pr → 2）")
    check(form.integrationRadios[3].title.contains("recommendedSuffix"),
          "推荐项（这里是 pr，最后一个）带标记")
    check(!form.integrationNote.isHidden, "推荐说明是可见信息，不是校验 hint")
    check(form.submitButton.isEnabled, "保存总是可点：设置没有非法值")
    // 交付成功后自动关闭队列：复选框 + 直接显示的完整说明（不再只藏在 tooltip）。
    check(form.autoCloseCheck.state == .on, "自动关闭开关按模型预填")
    eq(form.autoCloseCheck.title, "autoClose", "开关文案来自 tasks.settings.autoClose")

    // 区块顺序：工作流在上、GitHub Token 在下（与 intro 的两段顺序一致）。
    let workflowMidY = form.integrationRadios[0].convert(form.integrationRadios[0].bounds,
                                                         to: form).midY
    let tokenMidY = form.tokenField.convert(form.tokenField.bounds, to: form).midY
    check(workflowMidY > tokenMidY,
          "工作流区块排在 GitHub Token 之上 (workflow \(workflowMidY) > token \(tokenMidY))")

    form.selectIntegration(QueueIntegration.none)
    eq(form.selectedIntegration, QueueIntegration.none, "选「无」——非 git 项目不收尾")

    form.selectIntegration(.push)
    eq(form.selectedIntegration, .push, "点选直接推送")
    check(form.integrationRadios[0].state == .off, "单选：前一个（无）被关掉")
    form.tokenField.stringValue = "ghp_y"
    form.submitTapped()
    eq(submitted?.defaultIntegration, .push, "提交带上新选的默认工作流")
    eq(submitted?.token, "ghp_y", "以及新填的 token")

    form.setAutoCloseOnPublish(false)
    check(form.autoCloseCheck.state == .off, "可以关掉自动关闭开关")
    form.submitTapped()
    eq(submitted?.autoCloseOnPublish, false, "提交带上自动关闭开关")

    // 面板设置同样遵守工作区能力：跑不了的工作流灰掉（索引 0 无 / 1 推送 / 2 合并 / 3 PR）。
    let gitOnlySettings = TaskSettingsView(model: TaskSettingsModel(
        token: "", defaultIntegration: .merge, recommendedIntegration: .merge,
        prAvailable: false, gitAvailable: true, remoteAvailable: false))
    check(!gitOnlySettings.integrationRadios[3].isEnabled, "没有 GitHub 远端：PR 不可选")
    eq(gitOnlySettings.integrationRadios[3].toolTip, "unavailablePr", "并说明原因")
    check(gitOnlySettings.integrationRadios[2].isEnabled, "git 仓库：合并可选")
    check(!gitOnlySettings.integrationRadios[1].isEnabled, "没有远端：推送不可选")
}

section("多仓库设置抽屉：主仓库排第一 / 跟随开关 / 独立存储 / 换主重排")
do {
    func repo(_ id: String, _ name: String, primary: Bool,
              github: GitHubRepo? = nil, token: String = "",
              integration: QueueIntegration, explicit: QueueIntegration?,
              autoClose: Bool, explicitClose: Bool?) -> TaskSettingsRepoModel {
        TaskSettingsRepoModel(id: id, displayName: name, isPrimary: primary,
                              gitAvailable: true, prAvailable: github != nil,
                              remoteAvailable: github != nil, github: github, token: token,
                              integration: integration, explicitIntegration: explicit,
                              autoCloseOnPublish: autoClose, explicitAutoClose: explicitClose,
                              recommendedIntegration: .merge)
    }
    let primary = repo(".", "ws", primary: true, integration: .merge, explicit: .merge,
                       autoClose: true, explicitClose: true)
    let followerB = repo("repo-b", "repo-b", primary: false, integration: .merge, explicit: nil,
                         autoClose: true, explicitClose: nil)
    var model = TaskSettingsModel(token: "", defaultIntegration: .merge,
                                  recommendedIntegration: .merge, prAvailable: false,
                                  autoCloseOnPublish: true)
    model.repos = [primary, followerB]
    model.selectedRepoID = "."
    let form = TaskSettingsView(model: model)
    var submitted: TaskSettingsModel?
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 460)
    check(!form.repoBlock.isHidden, "多仓库显示仓库选择区")
    check(!form.repoNote.isHidden, "多仓库显示下拉下方的说明信息")
    let primaryNote = form.repoNote.stringValue
    eq(repoPopupTitles(form), ["ws", "repo-b"], "主仓库固定排第一")
    check(form.repoPopUp.indexOfSelectedItem == 0, "默认编辑主仓库")
    check(!form.primaryBadge.isHidden, "主仓库在下拉后显示主仓库标识")
    check(form.primaryButton.isHidden, "主仓库没有「设为主仓库」按钮")
    check(form.followCheck.isHidden, "主仓库没有「跟随」开关")

    // 选中非主仓库 b：默认跟随，字段禁用并显示继承值。
    selectRepo(form, 1)
    check(form.repoPopUp.indexOfSelectedItem == 1, "选中 b")
    check(form.primaryBadge.isHidden, "非主仓库不显示主仓库标识")
    check(!form.primaryButton.isHidden, "非主仓库显示「设为主仓库」")
    check(form.repoNote.stringValue != primaryNote, "主仓库 / 非主仓库 显示不同说明")
    check(!form.followCheck.isHidden, "非主仓库有「跟随」开关")
    check(form.followCheck.state == .on, "跟随默认开启")
    check(!form.integrationRadios[2].isEnabled, "跟随时工作流字段禁用")
    check(!form.autoCloseCheck.isEnabled, "跟随时自动关闭禁用")
    eq(form.selectedIntegration, .merge, "显示继承自主仓库的工作流")
    check(form.autoCloseCheck.state == .on, "显示继承自主仓库的自动关闭")
    check(!form.tokenField.isEnabled, "非 GitHub 仓库没有 token 框")

    // issue 归属配置（工作区级）：默认跟随主仓库，可显式选一个仓库。
    check(!form.issueRepoBlock.isHidden, "多仓库显示 issue 归属配置")
    eq(issueRepoPopupTitles(form),
       [L10n.tr("tasks.settings.issueRepoFollow"),
        "ws" + L10n.tr("tasks.repoPrimarySuffix"), "repo-b"],
       "issue 选项：跟随主仓库 + 各仓库（主仓库带标识）")
    check(form.issueRepoPopUp.indexOfSelectedItem == 0, "issue 默认跟随主仓库")
    form.issueRepoPopUp.selectItem(at: 2)
    form.issueRepoSelected(form.issueRepoPopUp)
    check(form.currentDraft.issueRepoIsExplicit, "选中仓库后成为显式")
    eq(form.currentDraft.issueRepoID, "repo-b", "显式 issue 归属 = repo-b")

    // 关闭跟随：用主仓库当前值预填，从此独立存储。
    form.followCheck.state = .off
    form.followTapped()
    check(form.followCheck.state == .off, "跟随已关闭")
    check(form.integrationRadios[2].isEnabled, "关闭后工作流字段可用")
    eq(form.selectedIntegration, .merge, "关闭后用主仓库当前值预填")
    form.selectIntegration(QueueIntegration.none)
    form.setAutoCloseOnPublish(false)
    form.submitTapped()
    let savedB = submitted?.repos.first { $0.id == "repo-b" }
    eq(savedB?.explicitIntegration, QueueIntegration.none, "b 独立存储自己的工作流")
    eq(savedB?.explicitAutoClose, false, "b 独立存储自己的自动关闭")
    eq(savedB?.followsPrimary, false, "b 不再跟随")
    eq(submitted?.repos.first { $0.id == "." }?.explicitIntegration, .merge, "主仓库的值不受 b 影响")
    eq(submitted?.issueRepoID, "repo-b", "提交带上显式 issue 归属")

    // N==1 多仓库（根非 git + 唯一子仓库）：选择区只读锁定。
    var one = TaskSettingsModel(token: "", defaultIntegration: .merge,
                                recommendedIntegration: .merge, prAvailable: false)
    one.repos = [repo("only", "only", primary: true, integration: .merge, explicit: nil,
                      autoClose: false, explicitClose: nil)]
    one.selectedRepoID = "only"
    let lockedForm = TaskSettingsView(model: one)
    _ = layout(lockedForm, width: 460)
    check(lockedForm.repoPopUp.numberOfItems == 1, "唯一仓库也列出来（N==1 仍是多仓库模式）")
    check(!lockedForm.repoPopUp.isEnabled, "N==1 锁定不可点")

    // 单仓库 / 普通目录：整块隐藏，抽屉与今天一致。
    var single = TaskSettingsModel(token: "", defaultIntegration: .merge,
                                   recommendedIntegration: .merge, prAvailable: false)
    single.repos = []
    let legacy = TaskSettingsView(model: single)
    _ = layout(legacy, width: 440)
    check(legacy.repoPopUp.numberOfItems == 0, "单仓库没有仓库按钮")
    check(legacy.repoBlock.isHidden, "单仓库隐藏仓库选择区")
    check(legacy.issueRepoBlock.isHidden, "单仓库隐藏 issue 归属配置")
}

section("多仓库设置抽屉：改主仓库后的重排与继承")
do {
    func repo(_ id: String, _ name: String, primary: Bool,
              integration: QueueIntegration, explicit: QueueIntegration?,
              autoClose: Bool, explicitClose: Bool?) -> TaskSettingsRepoModel {
        TaskSettingsRepoModel(id: id, displayName: name, isPrimary: primary,
                              gitAvailable: true, prAvailable: false, remoteAvailable: false,
                              github: nil, token: "",
                              integration: integration, explicitIntegration: explicit,
                              autoCloseOnPublish: autoClose, explicitAutoClose: explicitClose,
                              recommendedIntegration: .merge)
    }
    let primary = repo(".", "ws", primary: true, integration: .merge, explicit: nil,
                       autoClose: false, explicitClose: nil)
    let b = repo("repo-b", "repo-b", primary: false, integration: .merge, explicit: nil,
                 autoClose: false, explicitClose: nil)
    let c = repo("repo-c", "repo-c", primary: false, integration: .merge, explicit: nil,
                 autoClose: false, explicitClose: nil)
    var model = TaskSettingsModel(token: "", defaultIntegration: .merge,
                                  recommendedIntegration: .merge, prAvailable: false,
                                  autoCloseOnPublish: false)
    model.repos = [primary, b, c]
    model.selectedRepoID = "."
    let form = TaskSettingsView(model: model)
    var submitted: TaskSettingsModel?
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 460)
    eq(repoPopupTitles(form), ["ws", "repo-b", "repo-c"], "初始顺序：主仓库在前")
    check(!form.primaryBadge.isHidden, "初始选中主仓库，显示标识")

    // 选中 c，关掉跟随并给它一组独立值，然后设为主仓库。
    selectRepo(form, 2)
    form.followCheck.state = .off
    form.followTapped()
    form.selectIntegration(QueueIntegration.none)
    form.setAutoCloseOnPublish(true)
    form.primaryTapped()
    eq(repoPopupTitles(form), ["repo-c", "ws", "repo-b"],
       "改主仓库后重排：新的主仓库排第一，其余保持原相对顺序")
    check(!form.primaryBadge.isHidden, "新主仓库显示标识")
    check(form.followCheck.isHidden, "新主仓库没有跟随开关")
    check(form.primaryButton.isHidden, "新主仓库没有设为主仓库按钮")

    // 其余非主仓库（b）跟随新的主仓库：继承它的 none / 自动关闭 on。
    selectRepo(form, 2)            // repo-b
    check(form.primaryBadge.isHidden, "非主仓库不显示标识")
    check(!form.primaryButton.isHidden, "非主仓库显示设为主仓库")
    check(form.followCheck.state == .on, "b 跟随新主仓库")
    eq(form.selectedIntegration, QueueIntegration.none, "继承新主仓库的工作流 none")
    check(form.autoCloseCheck.state == .on, "继承新主仓库的自动关闭 on")

    form.submitTapped()
    eq(submitted?.repos.first?.id, "repo-c", "提交时新主仓库排第一")
    eq(submitted?.primaryRepoID, "repo-c", "提交带上新的主仓库指定")
    eq(submitted?.repos.first { $0.id == "repo-b" }?.explicitIntegration, nil,
       "跟随者不存显式值（缺失 = 跟随）")
    eq(submitted?.repos.first { $0.id == "repo-c" }?.explicitIntegration, QueueIntegration.none,
       "新主仓库保留它被提升时的值")
    eq(submitted?.repos.first { $0.id == "." }?.explicitIntegration, .merge,
       "旧主仓库自己的值仍归它自己，不会被 b 覆盖")
}

section("使用说明视图：抽屉与内联共用一个正文")
do {
    let model = TasksHelpModel.build()
    let drawer = TasksHelpView(model: model)
    var closed = false
    drawer.onCancel = { closed = true }
    let size = layout(drawer, width: 440)
    check(size.height > 60, "抽屉有正文高度 (got \(size.height)pt)")
    check(size.width <= 441, "不超过给定宽度 (got \(size.width)pt)")
    check(!drawer.body.subviews.isEmpty, "正文里渲染了内容")
    let controls = descendants(drawer, of: CustomIconButton.self)
    check(!controls.isEmpty, "抽屉里有关闭按钮")
    check(!closed, "还没有人按关闭")

    // 内联版：同一正文、窄列，供空板的内容区使用。
    let inline = TasksHelpTextView()
    inline.contentWidth = 300
    inline.apply(model)
    let inlineSize = layout(inline, width: 300)
    check(inlineSize.height > 40, "内联正文也有高度 (got \(inlineSize.height)pt)")
    check(!inline.subviews.isEmpty, "内联正文同样渲染了内容")
}

section("抽屉背后有一层虚化（表单与内容区分层）")
do {
    // 抽屉与内容区用的是同一套面板底色，表单打开时曾经看起来像列表里多了一张卡。
    // 虚化层（withinWindow 模糊 + HUD 半透明底）把列表压到后面去。
    let host = TaskFormSheetHostView()
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    check(host.scrim.isHidden, "静止时虚化层不出现（列表点击照常穿透）")
    eq(host.scrim.blendingMode, .withinWindow, "虚化的是同一窗口里抽屉背后的内容")
    eq(host.scrim.material, .hudWindow, "HUD 材质：模糊之外还留一层暗色半透明")
    eq(host.scrim.alphaValue, 0, "初始全透明")
    check(host.subviews.first === host.scrim, "虚化层在抽屉之下")

    host.showScrim()
    check(!host.scrim.isHidden, "表单打开时虚化层出现")
    host.layoutSubtreeIfNeeded()
    eq(host.scrim.frame.size, host.bounds.size, "虚化层铺满整个内容区")

    // 抽屉（表单）永远盖在虚化层上面 —— 顺序错了会把表单也糊掉。
    let sheet = TaskFormSheetView()
    host.addSubview(sheet)
    check(host.subviews.first === host.scrim && host.subviews.last === sheet,
          "抽屉盖在虚化层上面")

    host.hideScrim()
    check(host.scrim.isHidden, "关闭后收起")
    eq(host.scrim.alphaValue, 0, "并回到全透明")
}
section("the sheet IS as tall as the form (no measurement anywhere)")
do {
    // The panel only caps the sheet; the sheet follows its FORM by constraint. That
    // is the whole mechanism — no measurement, no callbacks — so a form that grows
    // from the inside grows the sheet in the SAME layout pass. (Measuring the view's
    // frame instead lagged one toggle behind: 展开时抽屉不动、收起时才长高.)
    func build(hostHeight: CGFloat) -> (host: TaskFormSheetHostView, sheet: TaskFormSheetView) {
        let windowHost = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: hostHeight))
        let host = TaskFormSheetHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        windowHost.addSubview(host)
        let sheet = TaskFormSheetView()
        host.addSubview(sheet)
        NSLayoutConstraint.activate([
            windowHost.widthAnchor.constraint(equalToConstant: 460),
            windowHost.heightAnchor.constraint(equalToConstant: hostHeight),
            host.leadingAnchor.constraint(equalTo: windowHost.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: windowHost.trailingAnchor),
            host.topAnchor.constraint(equalTo: windowHost.topAnchor),
            host.bottomAnchor.constraint(equalTo: windowHost.bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            sheet.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            sheet.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            sheet.heightAnchor.constraint(lessThanOrEqualTo: host.heightAnchor, constant: -16),
        ])
        windowHost.layoutSubtreeIfNeeded()
        return (host, sheet)
    }

    let roomy = build(hostHeight: 420)
    let form = QueueComposerView(model: QueueComposerModel.create())
    roomy.sheet.setContent(form)
    roomy.host.layoutSubtreeIfNeeded()
    let collapsed = roomy.sheet.frame.height
    check(abs(collapsed - form.frame.height) < 1, "the collapsed sheet is exactly the form")
    check(form.advancedStack.isHidden, "高级设置 starts collapsed")

    form.advancedButton.performClick(nil)
    roomy.host.layoutSubtreeIfNeeded()          // ONE pass, and nothing else
    check(!form.advancedStack.isHidden, "clicking it opens the section")
    check(abs(roomy.sheet.frame.height - form.frame.height) < 1,
          "the sheet is the form again after ONE layout pass (\(roomy.sheet.frame.height)pt)")
    check(roomy.sheet.frame.height > collapsed + 50, "which is the expanded height, no lag")

    // The description editor growing does the same thing.
    let taskSheet = build(hostHeight: 420)
    let taskForm = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    taskSheet.sheet.setContent(taskForm)
    taskSheet.host.layoutSubtreeIfNeeded()
    let before = taskSheet.sheet.frame.height
    type(taskForm, String(repeating: "一行描述文本。\n", count: 16))
    taskSheet.host.layoutSubtreeIfNeeded()
    check(taskSheet.sheet.frame.height > before, "typing a long task grows the sheet too")
    check(abs(taskSheet.sheet.frame.height - taskForm.frame.height) < 1,
          "and it stays exactly as tall as that form")

    // A panel too short caps the sheet: the form keeps its height and scrolls.
    let tight = build(hostHeight: 240)
    let tightForm = QueueComposerView(model: QueueComposerModel.create().togglingAdvanced())
    tight.sheet.setContent(tightForm)
    tight.host.layoutSubtreeIfNeeded()
    check(tight.sheet.frame.height <= 240 - 15, "a short panel caps the sheet inside the content area")
    check(tightForm.frame.height >= 200, "the form keeps its own height")
    check(tightForm.frame.height > tight.sheet.frame.height, "so it scrolls instead of shrinking")
}


 section("标题与状态同一行（审查面板的方块体例）")
do {
    var board = TaskBoard()
    let long = "A fairly long task title that has to wrap in a narrow panel"
    let task = TaskItem.manual(title: long, body: "the description an agent receives",
                               id: "manual-0062aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)

    let model = TaskCardModel.build(board.task(task.id)!, board: board,
                                    expanded: false, githubRepo: false)
    let card = TaskCardView(model: model)
    let size = layout(card, width: 320)
    eq(size.width, 320, "a card still fills the list width")
    // 来源徽标 + 状态徽标 no longer get a row of their own: they ride the title's
    // first line — the source just AFTER the name (2026-09-27: 它是名字的注解), the
    // state at the far right, and the row marker in front of the name.
    let badges = descendants(card, of: TaskBadgeView.self)
    eq(badges.count, 2, "来源与状态两枚徽标")
    let source = badges.first { $0.text == model.sourceBadge }
    let state = badges.first { $0.text == model.stateBadge }
    let titleLabel = descendants(card, of: NSTextField.self).first { $0.stringValue == long }
    if let titleLabel = titleLabel, let source = source, let state = state {
        let titleFrame = titleLabel.convert(titleLabel.bounds, to: card)
        let sourceFrame = source.convert(source.bounds, to: card)
        let stateFrame = state.convert(state.bounds, to: card)
        eq(titleLabel.toolTip, long, "标题被截断时 tooltip 给出全文")
        check(sourceFrame.minX >= titleFrame.minX, "来源徽标排在标题右边（名字后面）")
        check(sourceFrame.maxX <= stateFrame.minX, "状态徽标在最后一列，排在来源徽标右边")
        for frame in [sourceFrame, stateFrame] {
            check(frame.maxY > titleFrame.maxY - 3, "徽标落在标题首行的高度带里")
        }
    } else {
        check(false, "卡片里能找到标题标签与两枚徽标")
    }
}

 
section("加入队列 is the files panel's dropdown control")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Mine", id: "manual-0070aaaa")
    board.tasks = [task]
    let card = TaskCardView(model: TaskCardModel.build(task, board: board, expanded: true, githubRepo: false))
    _ = layout(card, width: 320)
    // 手动未入队任务的主操作是一个下拉：用壳层的 PanelMenuButton（打开项目 同款），
    // 而不是一个点了就执行的普通按钮。
    let menus = descendants(card, of: PanelMenuButton.self)
    eq(menus.count, 1, "the card carries one dropdown")
    if let menuButton = menus.first {
        eq(menuButton.title, "add", "labelled 加入队列")
        var anchor: NSView?
        card.onQueue = { anchor = $0 }
        menuButton.showMenu()
        check(anchor === menuButton, "opening it hands the panel the button itself (the menu drops under it)")
    }

    // 其它主操作仍是普通按钮（点一下就执行，没有下拉）。
    var queuedBoard = TaskBoard()
    queuedBoard.tasks = [task]
    let queue = queuedBoard.createQueue(name: "Lane")
    _ = queuedBoard.enqueue(taskID: task.id, into: queue.id)
    let queuedCard = TaskCardView(model: TaskCardModel.build(queuedBoard.task(task.id)!, board: queuedBoard,
                                                          expanded: true, githubRepo: false))
    _ = layout(queuedCard, width: 320)
    eq(descendants(queuedCard, of: PanelMenuButton.self).count, 0,
       "a queued task offers 移出队列 as a plain button, not a dropdown")
    check(descendants(queuedCard, of: NSButton.self).contains { $0.title == "remove" },
          "…and that button is a real NSButton")
    // 队列被删掉之后，失败的手动任务同样应该是下拉（见 TaskCardModel：状态还是
    // 失败，但已经没有队列可以重试进去了 —— 一个「点了只是把卡片reset」的重试按钮
    // 比直接给「加入队列」更糟）。
    var orphanBoard = TaskBoard()
    let goneTask = TaskItem.manual(title: "Orphan", id: "manual-0071bbbb")
    orphanBoard.tasks = [goneTask]
    let goneQueue = orphanBoard.createQueue(name: "Lane")
    _ = orphanBoard.enqueue(taskID: goneTask.id, into: goneQueue.id)
    orphanBoard.markRunning(goneTask.id)
    _ = orphanBoard.markFailed(goneTask.id, error: TaskFailure.session.rawValue)
    _ = orphanBoard.removeQueue(goneQueue.id)
    let orphanCard = TaskCardView(model: TaskCardModel.build(orphanBoard.task(goneTask.id)!,
                                                             board: orphanBoard, expanded: true,
                                                             githubRepo: false))
    _ = layout(orphanCard, width: 320)
    let orphanMenus = descendants(orphanCard, of: PanelMenuButton.self)
    eq(orphanMenus.count, 1, "队列没了的失败任务也带那个下拉")
    eq(orphanMenus.first?.title, "add", "而且文案就是 加入队列（不再先显示重试）")
    check(!descendants(orphanCard, of: NSButton.self).contains { $0.title == "retry" },
          "没有那个点了只会 reset 的重试按钮")
}

section("失败卡片：跳过并继续 与 灰按钮的解释")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-00e0aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-00e1bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: TaskFailure.session.rawValue)

    let card = TaskCardView(model: TaskCardModel.build(board.task(t1.id)!, board: board,
                                                      expanded: true, githubRepo: false))
    _ = layout(card, width: 320)
    var skipped = false
    card.onSkip = { skipped = true }
    let skipButton = descendants(card, of: NSButton.self).first { $0.title == "detailSkip" }
    check(skipButton != nil, "失败卡片上有 跳过并继续（在此之前它根本没有入口）")
    skipButton?.performClick(nil)
    check(skipped, "点它交给面板（面板调 runner.skip）")

    // 队里只有它自己：不该出现这个按钮（跳过会唤醒一个没活干的队列）。
    var loneBoard = TaskBoard()
    let lone = TaskItem.manual(title: "Lone", id: "manual-00e2cccc")
    loneBoard.tasks = [lone]
    let loneQueue = loneBoard.createQueue(name: "Lane")
    _ = loneBoard.enqueue(taskID: lone.id, into: loneQueue.id)
    loneBoard.markRunning(lone.id)
    _ = loneBoard.markFailed(lone.id, error: TaskFailure.session.rawValue)
    let loneCard = TaskCardView(model: TaskCardModel.build(loneBoard.task(lone.id)!, board: loneBoard,
                                                           expanded: true, githubRepo: false))
    _ = layout(loneCard, width: 320)
    check(!descendants(loneCard, of: NSButton.self).contains { $0.title == "detailSkip" },
          "没有下一个任务就不给 跳过并继续")

    // 已完成、没有 PR 的 issue 任务：主按钮是「打开 Issue」（PR 归队列头管）；评论并关闭仍在。
    var doneBoard = TaskBoard()
    let issue = TaskItem.github(number: 5, title: "No PR")
    doneBoard.tasks = [issue]
    let auto = TaskQueue.auto(for: issue)
    doneBoard.queues = [auto]
    _ = doneBoard.enqueue(taskID: issue.id, into: auto.id)
    doneBoard.markRunning(issue.id)
    doneBoard.markDone(issue.id, prUrl: nil)
    let doneCard = TaskCardView(model: TaskCardModel.build(doneBoard.task(issue.id)!, board: doneBoard,
                                                          expanded: true, githubRepo: true))
    _ = layout(doneCard, width: 320)
    let openIssue = descendants(doneCard, of: NSButton.self).first { $0.title == "detailOpenIssue" }
    check(openIssue != nil, "主按钮换成了 打开 Issue")
    check(descendants(doneCard, of: NSButton.self).allSatisfy { $0.title != "detailOpenPR" },
          "卡片上不再有「打开 PR」（那是队列头的按钮）")
    check(descendants(doneCard, of: NSButton.self).contains { $0.title == "detailCommentClose" },
          "评论并关闭照样出现（它不需要 PR）")
}

section("队列头：失败之后的 ▶ 说的是「继续」")
do {
    func playTooltip(_ build: () -> QueueHeaderModel) -> String? {
        let header = TaskQueueHeaderView(model: build())
        _ = layout(header, width: 360)
        return descendants(header, of: CustomIconButton.self).first { $0.toolTip == "start" || $0.toolTip == "continue" }?.toolTip
    }
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-00f0aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-00f1bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    eq(playTooltip { QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false) },
       "start", "还没跑过：按钮就是 开始")

    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: TaskFailure.session.rawValue)
    eq(playTooltip { QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false) },
       "continue", "失败之后它其实是 继续（跳过失败项）")
}

section("卡片上的会话动作：打开会话 / 审查改动")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Ran", id: "manual-00j0aaaa")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.local.sessions[task.id] = "session-42"
    board.attachSessions(board.local.sessions)
    board.markDone(task.id, prUrl: nil)

    let card = TaskCardView(model: TaskCardModel.build(board.task(task.id)!, board: board,
                                                      expanded: true, githubRepo: false))
    _ = layout(card, width: 320)
    let sessionButtons = descendants(card, of: CustomIconButton.self)
    let openButton = sessionButtons.first { $0.toolTip == "detailOpenSession" }
    let reviewButton = sessionButtons.first { $0.toolTip == "detailReview" }
    check(openButton != nil, "跑过的任务带「打开会话」图标按钮")
    check(reviewButton != nil, "也带「审查改动」")
    var opened = false
    var reviewed = false
    card.onOpenSession = { opened = true }
    card.onReview = { reviewed = true }
    openButton?.onAction?()
    reviewButton?.onAction?()
    check(opened && reviewed, "点了分别回调面板（面板把它交给壳层的桥 / 审查面板）")

    // 还没跑过的任务：没有会话，两个按钮都不出现。
    var fresh = TaskBoard()
    let pending = TaskItem.manual(title: "Not run", id: "manual-00j1bbbb")
    fresh.tasks = [pending]
    let freshCard = TaskCardView(model: TaskCardModel.build(fresh.task(pending.id)!, board: fresh,
                                                           expanded: true, githubRepo: false))
    _ = layout(freshCard, width: 320)
    let freshIcons = descendants(freshCard, of: CustomIconButton.self)
    check(!freshIcons.contains { $0.toolTip == "detailOpenSession" }, "没跑过就没有会话可打开")
    check(!freshIcons.contains { $0.toolTip == "detailReview" }, "也没有改动可审")

    // 运行中的卡片真的把时钟画在 meta 行上。
    var running = TaskBoard()
    let live = TaskItem.manual(title: "Live", id: "manual-00j2cccc")
    running.tasks = [live]
    let liveQueue = running.createQueue(name: "Lane")
    _ = running.enqueue(taskID: live.id, into: liveQueue.id)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    running.markRunning(live.id, at: start)
    let liveCard = TaskCardView(model: TaskCardModel.build(running.task(live.id)!, board: running,
                                                           expanded: false, githubRepo: false,
                                                           now: start.addingTimeInterval(95)))
    _ = layout(liveCard, width: 320)
    check(descendants(liveCard, of: NSTextField.self).contains { $0.stringValue.contains("runningFor(1:35,60)") },
          "运行中的卡片把 已运行 1:35（上限 60 分钟）画出来了")
}

section("队列头：三个操作都在明面上（不再藏在 更多 里）")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0090aaaa")
    board.tasks = [t1]
    let queue = board.createQueue(name: "Lane", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)

    func setAutoPR(_ value: Bool) {
        if let i = board.index(ofQueue: queue.id) { board.queues[i].autoPR = value }
    }

    func headerGlyphs(prAvailable: Bool, autoPR: Bool) -> [String] {
        setAutoPR(autoPR)
        let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                           prAvailable: prAvailable)
        let header = TaskQueueHeaderView(model: model)
        _ = layout(header, width: 360)
        return descendants(header, of: CustomIconButton.self).compactMap {
            if case .symbol(let name) = $0.glyph { return name }
            return nil
        }
    }

    // GitHub 工作区、自动开 PR 开着：设置 / 删除 / PR 开关三个图标按钮都在行上。
    let on = headerGlyphs(prAvailable: true, autoPR: true)
    check(on.contains("gearshape"), "队列设置有了自己的图标按钮")
    check(on.contains("trash"), "删除队列也有了")
    check(on.contains("checkmark.circle.fill"), "自动开 PR 开着时是实心对勾")
    check(!on.contains("ellipsis"), "⋯ 更多菜单没有了")

    let off = headerGlyphs(prAvailable: true, autoPR: false)
    check(off.contains("circle"), "自动开 PR 关着时是空心圆")
    check(!off.contains("checkmark.circle.fill"), "不再是实心对勾")

    // 非 GitHub 工作区：开关不出现（不是点了没反应的死按钮）。
    let noRepo = headerGlyphs(prAvailable: false, autoPR: false)
    check(!noRepo.contains("circle") && !noRepo.contains("checkmark.circle.fill"),
          "没有 GitHub 就不显示 PR 开关")
    check(noRepo.contains("gearshape") && noRepo.contains("trash"),
          "但队列设置与删除照常在明面上")

    // 已经开着自动开 PR 的队列换了非 GitHub 工作区：开关留着（状态可见）但不可点。
    setAutoPR(true)
    let lockedModel = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                             prAvailable: false)
    let locked = TaskQueueHeaderView(model: lockedModel)
    _ = layout(locked, width: 360)
    let lockedButtons = descendants(locked, of: CustomIconButton.self)
    let toggle = lockedButtons.first { if case .symbol("checkmark.circle.fill") = $0.glyph { return true }; return false }
    if let toggle = toggle {
        check(!toggle.isEnabled, "状态还在，但点不动（tooltip 说明没有 GitHub）")
        eq(toggle.toolTip, "prUnavailable", "tooltip 指向 prUnavailable")
    } else {
        check(false, "自动开 PR 开着时开关仍然可见")
    }
}


section("队列头在最小宽度下不撑破")
do {
    var board = TaskBoard()
    let longName = "A queue with a rather long name"
    let t1 = TaskItem.manual(title: "One", id: "manual-0096aaaa")
    board.tasks = [t1]
    let queue = board.createQueue(name: longName, autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    board.markRunning(t1.id)
    board.markDone(t1.id, prUrl: nil)

    // 最坏情况：活跃态 + 可以开 PR + 自动开 PR 开着、三个操作全在行上。
    let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false,
                                       prAvailable: true)
    let header = TaskQueueHeaderView(model: model)
    let size = layout(header, width: 300)      // 面板最小宽度
    eq(size.width, 300, "the header fills the panel at its minimum width")
    for button in descendants(header, of: CustomIconButton.self) {
        let frame = button.convert(button.bounds, to: header)
        check(frame.minX >= 0 && frame.maxX <= header.bounds.width + 0.5,
              "an action button stays inside the header")
    }
    let name = descendants(header, of: NSTextField.self).first { $0.stringValue == longName }
    check((name?.frame.width ?? 0) > 20, "the queue name keeps a usable width at 300pt")
}
section("统计信息卡（内容区首行）")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0060aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0061bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    board.markRunning(t1.id)

    let summary = TasksSummaryModel.build(board)
    let card = TaskSummaryCardView(model: summary)
    let size = layout(card, width: 320)
    eq(size.width, 320, "统计卡跟任务卡一样撑满列表宽度")
    check(size.height > 20, "统计卡有一行计数的高度")

    let text = card.summaryText.string
    eq(summary.parts.count, 4, "四个计数")
    for part in summary.parts {
        check(text.contains(part.text), "每一个计数都在卡里：\(part.text)")
    }
    check(!text.contains("\n"), "四个计数排在同一行")

    // 失败 > 0 才变红，其余保持中性（审查面板摘要卡的体例）。
    func color(of needle: String, in string: NSAttributedString) -> NSColor? {
        let range = (string.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return string.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }
    eq(color(of: summary.parts[3].text, in: card.summaryText), NSColor.secondaryLabelColor,
       "零失败保持中性色")
    eq(color(of: summary.parts[2].text, in: card.summaryText), NSColor.secondaryLabelColor,
       "运行不是告警色")

    _ = board.markFailed(t1.id, error: "tasks.errNoPush")
    let failedSummary = TasksSummaryModel.build(board)
    let failed = TaskSummaryCardView(model: failedSummary)
    eq(color(of: failedSummary.parts[3].text, in: failed.summaryText), NSColor.systemRed,
       "有失败时这一段变红")
}
section("徽标容得下自己的文字")
do {
    // 徽标的固有宽度少算了内边距（6pt × 2）时会截断文字 —— 实测「队列中 #2」只剩
    // 「队列中 #」，在「标题与状态同一行」的排布里尤其明显。
    for text in ["手动", "队列中 #2", "运行中", "0/2"] {
        let badge = TaskBadgeView(text: text, tone: .neutral)
        let label = descendants(badge, of: NSTextField.self).first
        if let label = label {
            eq(badge.intrinsicContentSize.width, label.intrinsicContentSize.width + 12,
               "徽标固有宽度 = 标签 + 内边距（\(text)）")
        } else {
            check(false, "徽标里能找到标签（\(text)）")
        }
    }
}

section("section header + progress bar")
do {
    let header = TaskSectionHeaderView(text: "queues (2)")
    let size = layout(header, width: 320)
    eq(size.width, 320, "the section header fills the list width")
    check(size.height > 20, "and keeps its caption line")

    let bar = TaskProgressBarView()
    bar.fraction = 0.5
    bar.tone = .positive
    let barSize = layout(bar, width: 72)
    check(barSize.height > 0, "the progress bar has a visible thickness")
}

section("queue block containment")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", body: "b1", id: "manual-0040aaaa")
    let t2 = TaskItem.manual(title: "Two", body: "b2", id: "manual-0041bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)

    func block(collapsed: Bool) -> TaskQueueBlockView {
        let model = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: collapsed)
        let header = TaskQueueHeaderView(model: model)
        let cards = collapsed ? [] : [t1, t2].map {
            TaskCardView(model: TaskCardModel.build($0, board: board, expanded: false, githubRepo: false))
        }
        return TaskQueueBlockView(header: header, cards: cards, collapsed: collapsed)
    }

    let closed = block(collapsed: true)
    let closedSize = layout(closed, width: 320)
    let open = block(collapsed: false)
    let openSize = layout(open, width: 320)
    eq(openSize.width, 320, "the queue block fills the list width")
    // 相对断言：展开的泳道比折叠态多出两张卡片的高度（不是随手写死的绝对值）。
    check(openSize.height > closedSize.height + 80, "an open lane holds its header AND its cards")
    // Every card sits strictly inside the lane — that is the containment the
    // user asked for (queue and tasks were two parallel stacks before).
    let headers = open.subviews.compactMap { $0 as? TaskQueueHeaderView }
    eq(headers.count, 1, "the lane carries one queue header")
    let headerInset = headers[0].frame.minX
    let cards = open.subviews.flatMap { $0.subviews }.compactMap { $0 as? TaskCardView }
    eq(cards.count, 2, "both tasks are laid out inside the lane")
    for card in cards {
        let frame = card.convert(card.bounds, to: open)
        check(frame.minX > headerInset, "a card is indented past the lane header, not level with it")
        check(frame.maxX < open.bounds.width, "and never spills out of the lane")
    }

    eq(closedSize.width, 320, "a collapsed lane still fills the list width")
    check(closedSize.height < openSize.height, "and collapses to its header line")
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
