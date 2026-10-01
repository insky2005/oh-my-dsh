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
    host.layoutSubtreeIfNeeded()
    return view.frame.size
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

section("队列头：打开 PR 排在最后（图标与 PR 链接都是）")
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
    check(buttons.contains { $0.toolTip == L10n.tr("tasks.queue.openPR") }, "行上有「打开 PR」")
    if let pr = buttons.first(where: { $0.toolTip == L10n.tr("tasks.queue.openPR") }) {
        let prFrame = pr.convert(pr.bounds, to: openHeader)
        let others = buttons.filter { $0 !== pr }.map { $0.convert($0.bounds, to: openHeader) }
        check(others.allSatisfy { $0.maxX <= prFrame.minX + 1 },
              "它是这一行最右的按钮（其余按钮都在它左边）")
        check(prFrame.maxX <= openHeader.bounds.width, "没有越出队列头")
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
    // 高级设置 opens three more controls; a form that then needs a scrollbar in a
    // normal panel is a form that should have been shorter (the section's rows sit
    // caption-BESIDE-field, and its spacing is tighter).
    let collapsed = QueueComposerView(model: QueueComposerModel.create())
    let collapsedSize = layout(collapsed, width: 400)
    let expanded = QueueComposerView(model: QueueComposerModel.create().togglingAdvanced())
    let expandedSize = layout(expanded, width: 400)
    check(expandedSize.height > collapsedSize.height, "高级设置 makes the form taller")
    check(expandedSize.height <= 290,
          "but the expanded form still fits a normal content area (got \(expandedSize.height)pt)")
    check(expanded.branchField.frame.width > 180,
          "and the inline advanced fields keep their width (\(expanded.branchField.frame.width)pt)")
}

section("队列表单：工作流 picker（跟随设置 + 三档，推荐项带标记）")
do {
    // The recommendation follows the WORKSPACE, never the global default.
    eq(QueueComposerModel.create().forWorkspace(git: true, pr: true).recommendedIntegration, .pr,
       "GitHub 工作区推荐 PR")
    eq(QueueComposerModel.create().forWorkspace(git: true, pr: false).recommendedIntegration, .merge,
       "普通 git 仓库推荐合并并推送")
    eq(QueueComposerModel.create().forWorkspace(git: false, pr: false).recommendedIntegration, .push,
       "非 git 目录推荐仅推送")

    let model = QueueComposerModel.create()
        .forWorkspace(git: true, pr: true, defaultBase: "main", defaultIntegration: .pr)
        .togglingAdvanced()
    let form = QueueComposerView(model: model)
    var submitted: QueueComposerModel?
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 400)

    eq(form.integrationPopup.numberOfItems, 4, "跟随设置 + 三个模式")
    check(form.integrationPopup.itemTitle(at: 0).contains("follow"), "第一项是跟随设置")
    eq(form.selectedIntegration, nil, "默认就是跟随设置")
    check(form.integrationPopup.itemTitle(at: 0).contains("recommendedSuffix"),
          "推荐项带（推荐）标记")
    check(form.integrationPopup.itemTitle(at: 1).contains("recommendedSuffix"),
          "推荐的是 pr —— 标记落在 pr 那一项上（1 = pr）")

    // 选中 merge：模型与提交都带上队列自己的覆盖。名字要填，否则表单不可提交。
    form.nameField.stringValue = "Lane"
    form.integrationPopup.selectItem(at: 2)
    form.integrationChanged()
    eq(form.selectedIntegration, .merge, "选中项映射回模型（2 = merge）")
    form.submitTapped()
    eq(submitted?.integration, .merge, "提交时带上队列自己的工作流")
    eq(submitted?.integrationChoices.count, 4, "选项集合包含跟随设置")
}

section("面板设置抽屉：token + 工作流默认值")
do {
    let model = TaskSettingsModel(token: "ghp_x", defaultIntegration: .merge,
                                  recommendedIntegration: .pr, prAvailable: true)
    let form = TaskSettingsView(model: model)
    var submitted: TaskSettingsModel?
    form.onSubmit = { submitted = $0 }
    let settingsSize = layout(form, width: 440)
    check(settingsSize.height <= 290,
          "设置抽屉与两张表单共用同一个内容区，不能更高 (got \(settingsSize.height)pt)")

    eq(form.tokenField.stringValue, "ghp_x", "token 预填")
    check(form.tokenField.frame.width > 300, "token 字段撑满抽屉 (got \(form.tokenField.frame.width)pt)")
    eq(form.integrationPopup.numberOfItems, 3, "三档（这里就是默认值，没有跟随设置）")
    eq(form.integrationPopup.indexOfSelectedItem, 1, "选中的是当前默认值 merge")
    check(!form.integrationNote.isHidden, "推荐说明是可见信息，不是校验 hint")
    check(form.submitButton.isEnabled, "保存总是可点：设置没有非法值")

    form.integrationPopup.selectItem(at: 2)
    form.integrationChanged()
    form.tokenField.stringValue = "ghp_y"
    form.submitTapped()
    eq(submitted?.defaultIntegration, .push, "提交带上新选的默认工作流")
    eq(submitted?.token, "ghp_y", "以及新填的 token")
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
