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

/// What a text field's delegate receives while the user types.
func typed(_ field: NSTextField) -> Notification {
    Notification(name: NSControl.textDidChangeNotification, object: field)
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
    check(size.height > 140, "the form carries two fields and a button row")
    eq(form.submitButton.title, "create", "the primary button creates")
    check(!form.submitButton.isEnabled, "an empty form cannot be submitted")
    check(form.hint.isHidden, "and shows no problem yet")

    // A title alone is not enough: the description IS the prompt.
    form.titleField.stringValue = "Polish README"
    form.controlTextDidChange(typed(form.titleField))
    check(!form.submitButton.isEnabled, "a title without a description is not submittable")
    check(form.hint.isHidden, "and the form does not nag while it is being typed into")

    form.bodyText.string = "tidy it up"
    form.textDidChange(Notification(name: NSText.didChangeNotification, object: form.bodyText))
    check(form.submitButton.isEnabled, "both fields filled enables 创建")

    form.submitTapped()
    eq(submitted?.draft.normalizedTitle, "Polish README", "submitting hands over the typed title")
    eq(submitted?.draft.normalizedBody, "tidy it up", "and the typed description")
    eq(submitted?.mode, .create, "in create mode")
    check(!cancelled, "submitting does not close the form (完成 / Esc does)")

    // Enter on an incomplete draft explains what is missing.
    let empty = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    empty.submitTapped()
    check(!empty.hint.isHidden, "an attempted submit shows the problem")
    eq(empty.hint.stringValue, "errName", "and names the title field")
}

section("inline 编辑任务 form")
do {
    let task = TaskItem.manual(title: "Old title", body: "old body", id: "manual-0030aaaa")
    var submitted: TaskComposerModel?
    let form = TaskComposerView(model: TaskComposerModel.edit(task))
    form.onSubmit = { submitted = $0 }
    _ = layout(form, width: 320)

    eq(form.titleField.stringValue, "Old title", "the title is prefilled")
    eq(form.bodyText.string, "old body", "the description is prefilled")
    eq(form.submitButton.title, "save", "编辑 saves")
    eq(form.closeActionButton.title, "cancel", "编辑 can be cancelled")
    check(form.submitButton.isEnabled, "a prefilled form can be saved")

    form.titleField.stringValue = "New title"
    form.controlTextDidChange(typed(form.titleField))
    form.submitTapped()
    eq(submitted?.mode, .edit(taskID: "manual-0030aaaa"), "saving keeps the task id")
    eq(submitted?.draft.normalizedTitle, "New title", "and carries the edited title")
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
    eq(form.branchHint.stringValue, "branchWillUse(branchHint)",
       "with no name there is no derived branch to promise")
    check(form.advancedStack.isHidden, "creating a queue only asks for a name: 高级设置 is collapsed")
    eq(form.branchField.placeholderString, "branchHint",
       "the branch field's placeholder is the branch that will be used")

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
    form.submitTapped()
    eq(submitted?.mode.queueID, "q-3333", "the edited queue is identified")
    eq(submitted?.branchValue, nil, "and the cleared branch is submitted as no branch")
    eq(submitted?.normalizedBaseBranch, "main", "the base branch survives")
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
}

section("fields span the whole form")
do {
    // An EMPTY NSTextField's intrinsic width is almost nothing, and a .leading
    // vertical stack hugs its widest arranged view — so a caption+field row used
    // to collapse to the caption's width (measured on screen: ~25pt wide, the
    // placeholder clipped to one character). The rows must be pinned to the form.
    let taskForm = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(taskForm, width: 360)
    let titleWidth = taskForm.titleField.frame.width
    check(titleWidth > 300, "the title field spans the form (got \(titleWidth)pt)")
    // The editor is the form's other input surface, and it must WRAP at the same
    // width: an autoresizing document view used to keep a width 318pt wider than
    // the clip view, so long lines were clipped instead of wrapped.
    let bodyWidth = taskForm.bodyText.frame.width
    check(bodyWidth > 280, "the description editor spans the form (got \(bodyWidth)pt)")
    check(abs(bodyWidth - titleWidth) < 12,
          "the editor wraps at the fields' width (editor \(bodyWidth), field \(titleWidth))")

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

    // Widening the panel widens the fields with it.
    let wide = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    _ = layout(wide, width: 520)
    check(wide.titleField.frame.width > titleWidth, "a wider panel gives wider fields")
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
    // it was just a tall box.
    check(form.bodyText.isVerticallyResizable, "the editor is a multi-line text view")
    check(form.bodyBox is TaskFieldBox, "inside the same box as the single-line fields")
    check(form.titleBox is TaskFieldBox, "which the title field uses too")
    check(form.bodyBox.frame.height >= 100,
          "the empty editor is a usable area, not one line (got \(form.bodyBox.frame.height)pt)")
    check(abs(form.bodyText.frame.width - form.titleField.frame.width) <= 24,
          "the text wraps at the same width the fields use")

    let emptyHeight = form.bodyBox.frame.height
    form.bodyText.string = String(repeating: "一行比较长的描述文本，用来看编辑器会不会长高。", count: 8)
    form.textDidChange(Notification(name: NSText.didChangeNotification, object: form.bodyText))
    _ = layout(form, width: 430)
    check(form.bodyBox.frame.height > emptyHeight,
          "the editor grows with its text (\(emptyHeight) → \(form.bodyBox.frame.height)pt)")

    // Past the maximum box height the TEXT grows instead, so the rest scrolls
    // under the caret rather than disappearing.
    form.bodyText.string = String(repeating: "一行比较长的描述文本。\n", count: 40)
    form.textDidChange(Notification(name: NSText.didChangeNotification, object: form.bodyText))
    _ = layout(form, width: 430)
    check(form.bodyBox.frame.height <= TaskFormKit.editorMaxHeight + 1,
          "the box stops growing at its maximum")
    check(form.bodyText.frame.height > form.bodyBox.frame.height,
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

section("the drawer grows when the FORM grows")
do {
    // 高级设置 changes the form's height from the INSIDE: the panel's own layout
    // never runs for that, so the form has to tell the sheet to re-measure. Without
    // it the drawer kept its collapsed height and the extra fields scrolled.
    let windowHost = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
    let host = TaskFormSheetHostView()
    host.translatesAutoresizingMaskIntoConstraints = false
    windowHost.addSubview(host)
    let sheet = TaskFormSheetView()
    host.addSubview(sheet)
    let form = QueueComposerView(model: QueueComposerModel.create())
    sheet.setContent(form)

    let height = sheet.heightAnchor.constraint(equalToConstant: 0)
    height.priority = NSLayoutConstraint.Priority(999)
    NSLayoutConstraint.activate([
        windowHost.widthAnchor.constraint(equalToConstant: 460),
        windowHost.heightAnchor.constraint(equalToConstant: 420),
        host.leadingAnchor.constraint(equalTo: windowHost.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: windowHost.trailingAnchor),
        host.topAnchor.constraint(equalTo: windowHost.topAnchor),
        host.bottomAnchor.constraint(equalTo: windowHost.bottomAnchor),
        sheet.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
        sheet.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
        sheet.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
        sheet.heightAnchor.constraint(lessThanOrEqualTo: host.heightAnchor, constant: -16),
        height,
    ])
    // Exactly what IssueRunnerPanel wires up.
    host.onLayout = { height.constant = ceil(sheet.idealHeight()) }
    form.onHeightChanged = { height.constant = ceil(sheet.idealHeight()) }
    // Twice: the measurement happens during a layout pass, so the frame follows on
    // the next one (IssueRunnerPanel does the same before its slide-in).
    windowHost.layoutSubtreeIfNeeded()
    windowHost.layoutSubtreeIfNeeded()

    let collapsed = sheet.frame.height
    check(form.advancedStack.isHidden, "高级设置 starts collapsed")
    check(abs(collapsed - form.frame.height) < 1, "the drawer matches the collapsed form")

    form.advancedButton.performClick(nil)
    host.layoutSubtreeIfNeeded()
    check(!form.advancedStack.isHidden, "clicking it opens the section")
    check(sheet.frame.height > collapsed + 50,
          "the drawer grows with the form (\(collapsed) → \(sheet.frame.height)pt)")
    check(abs(sheet.frame.height - form.frame.height) < 1,
          "and is exactly as tall as the form (no scrolling)")
}

section("a click never falls through the form to the list")
do {
    // With no form open the host must be click-through (it covers the list), but
    // while a form is open it must swallow clicks aimed outside the form — a card
    // behind the drawer reacting to a click is startling.
    let host = TaskFormSheetHostView()
    host.translatesAutoresizingMaskIntoConstraints = false
    let form = TaskComposerView(model: TaskComposerModel.build(mode: .create))
    host.addSubview(form)
    form.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        host.widthAnchor.constraint(equalToConstant: 400),
        host.heightAnchor.constraint(equalToConstant: 600),
        form.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
        form.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
        form.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
    ])
    host.layoutSubtreeIfNeeded()

    // A point in the host's empty area (below the form): passed on to the list
    // while nothing is open…
    let emptyArea = NSPoint(x: 200, y: 20)
    check(host.hitTest(emptyArea) == nil, "the empty host area is click-through while nothing is open")

    // …and swallowed while a form is on screen.
    host.blocksClicksBelow = true
    check(host.hitTest(emptyArea) === host,
          "with a form open the click stops at the form's own layer")
    host.blocksClicksBelow = false
    check(host.hitTest(emptyArea) == nil, "and opens up again once the form closes")
}

section("the sheet caps itself and scrolls instead of squeezing the form")
do {
    // A form must NEVER shrink its description to fit: the sheet is as tall as the
    // form wants, and past the content area it scrolls instead (a squeezed text
    // area cannot wrap, which is exactly what a user reported).
    func build(hostHeight: CGFloat) -> (sheet: TaskFormSheetView, form: TaskComposerView) {
        let windowHost = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: hostHeight))
        let host = TaskFormSheetHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        windowHost.addSubview(host)
        let sheet = TaskFormSheetView()
        host.addSubview(sheet)
        let form = TaskComposerView(model: TaskComposerModel.build(mode: .create))
        sheet.setContent(form)
        let height = sheet.heightAnchor.constraint(equalToConstant: 0)
        height.priority = NSLayoutConstraint.Priority(999)
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
            height,
        ])
        host.onLayout = { height.constant = sheet.idealHeight() }
        windowHost.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return (sheet, form)
    }

    let roomy = build(hostHeight: 600)
    check(abs(roomy.sheet.frame.height - roomy.form.frame.height) < 1,
          "a roomy panel shows the whole form (sheet \(roomy.sheet.frame.height), form \(roomy.form.frame.height))")
    check(roomy.form.bodyBox.frame.height >= 110,
          "with the description at its full height (\(roomy.form.bodyBox.frame.height)pt)")

    let mid = build(hostHeight: 360)
    check(abs(mid.sheet.frame.height - mid.form.frame.height) < 1,
          "a 360pt panel still shows the whole form")

    for hostHeight in [300.0, 240.0] {
        let tight = build(hostHeight: hostHeight)
        check(tight.sheet.frame.height <= hostHeight - 15,
              "a \(Int(hostHeight))pt panel caps the sheet inside the content area")
        check(tight.sheet.frame.height < tight.form.frame.height,
              "and the form scrolls rather than shrinking")
        check(tight.form.bodyBox.frame.height >= 88,
              "the description keeps a usable height (\(tight.form.bodyBox.frame.height)pt)")
    }
}

// MARK: - Section header

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

    let open = block(collapsed: false)
    let openSize = layout(open, width: 320)
    eq(openSize.width, 320, "the queue block fills the list width")
    check(openSize.height > 150, "an open lane holds its header AND its cards")
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

    let closed = block(collapsed: true)
    let closedSize = layout(closed, width: 320)
    eq(closedSize.width, 320, "a collapsed lane still fills the list width")
    check(closedSize.height < openSize.height, "and collapses to its header line")
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
