import Foundation

// Headless tests for the task list's view models (TasksUI.swift). The card list
// itself is pure presentation; every rule about WHAT a card says and which
// action it offers is asserted here. L10n is stubbed to echo the key (plus its
// arguments), so assertions read like the label semantics.

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

func board(tasks: [TaskItem], queues: [TaskQueue]) -> TaskBoard {
    var board = TaskBoard()
    board.tasks = tasks
    board.queues = queues
    board.reindexQueueMembership()
    return board
}

// MARK: - Source and state badges

section("card badges")
do {
    let issue = TaskItem.github(number: 12, title: "Fix dark mode", labels: ["bug"])
    let b = board(tasks: [issue], queues: [])
    let card = TaskCardModel.build(issue, board: b, expanded: false, githubRepo: true)
    eq(card.sourceBadge, "tasks.source.github(12)", "a github task shows its issue number")
    eq(card.stateBadge, "tasks.state.pending", "a new github task is pending")
    eq(card.primaryKey, "tasks.detailProcess", "a github task offers 处理")
    check(!card.canQueue, "a github task is not queued from the card")
    eq(card.meta, ["bug"], "labels land in the meta line")
    eq(card.tone, TaskTone.neutral, "pending is neutral")

    let manual = TaskItem.manual(title: "Polish README", body: "tidy it")
    let b2 = board(tasks: [manual], queues: [])
    let manualCard = TaskCardModel.build(manual, board: b2, expanded: false, githubRepo: false)
    eq(manualCard.sourceBadge, "tasks.source.manual", "a manual task is marked as such")
    eq(manualCard.primaryKey, "tasks.queue.add", "a manual task offers 加入队列")
    check(manualCard.canQueue, "the primary action is the queue picker")
}

section("queue position and running state")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0001aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0002bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)

    let running = TaskCardModel.build(board.task(t1.id)!, board: board, expanded: true, githubRepo: false)
    eq(running.stateBadge, "tasks.state.running", "the running card says so")
    eq(running.tone, TaskTone.running, "running has its own tone")
    eq(running.primaryKey, "tasks.detailCancelTask", "a running task offers 取消")
    check(running.canCancel, "cancel is offered")
    check(running.isExpanded, "the expanded flag is carried through")
    check(running.meta.contains("feature/lane"), "the queue's branch shows in the meta line")
    check(running.detail.contains("tasks.detailQueue"), "the queue name is in the details")

    let waiting = TaskCardModel.build(board.task(t2.id)!, board: board, expanded: false, githubRepo: false)
    eq(waiting.stateBadge, "tasks.card.queuedAt(2)", "a waiting card shows its position")
    eq(waiting.queuePosition, 2, "the position is exposed for assertions")
    eq(waiting.primaryKey, "tasks.queue.remove", "a waiting task offers 移出队列")
    check(waiting.canDequeue, "移出队列 is offered")
}

section("done, failed and closed cards")
do {
    var board = TaskBoard()
    let done = TaskItem.github(number: 7, title: "Done one", labels: [])
    board.tasks = [done]
    let queue = TaskQueue.auto(for: done)
    board.queues = [queue]
    board.reindexQueueMembership()
    board.markRunning(done.id)
    board.markDone(done.id, prUrl: "https://github.com/o/r/pull/42")

    let card = TaskCardModel.build(board.task(done.id)!, board: board, expanded: true, githubRepo: true)
    eq(card.stateBadge, "tasks.state.done", "a finished task is done")
    eq(card.tone, TaskTone.positive, "done is positive")
    eq(card.primaryKey, "tasks.detailOpenPR", "a finished task offers the PR")
    check(card.primaryEnabled, "the PR button is live when there is a PR")
    check(card.canCommentClose, "a github task with a PR can be commented & closed")
    check(card.meta.contains("tasks.detailPR(o/r#42)"), "the PR is shortened in the meta line")
    check(!card.canEdit, "a github task is never edited from the card")
    check(!card.canDelete, "a github task is never deleted")

    let noRepo = TaskCardModel.build(board.task(done.id)!, board: board, expanded: true, githubRepo: false)
    check(!noRepo.canCommentClose, "no GitHub repo means no comment & close")

    var failedBoard = board
    if let i = failedBoard.index(ofTask: done.id) { failedBoard.tasks[i].state = .failed; failedBoard.tasks[i].prUrl = nil }
    let failed = TaskCardModel.build(failedBoard.task(done.id)!, board: failedBoard, expanded: true, githubRepo: true)
    eq(failed.tone, TaskTone.negative, "failed is negative")
    eq(failed.primaryKey, "tasks.detailRetry", "a failed task offers 重试")
    check(failed.canRetry, "retry is offered")
    check(!failed.primaryEnabled == false, "the retry button is enabled")
}

section("manual task editing")
do {
    var board = TaskBoard()
    let manual = TaskItem.manual(title: "Mine", id: "manual-0003cccc")
    board.tasks = [manual]
    let card = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    check(card.canEdit, "a manual task can be edited")
    check(card.canDelete, "a manual task can be deleted")

    board.markRunning(manual.id)
    let running = TaskCardModel.build(board.task(manual.id)!, board: board, expanded: true, githubRepo: false)
    check(!running.canEdit, "a running task cannot be edited")
    check(!running.canDelete, "a running task cannot be deleted")
}

section("error text and detail body")
do {
    var board = TaskBoard()
    let task = TaskItem.manual(title: "Boom", body: "do the thing", id: "manual-0004dddd")
    board.tasks = [task]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: task.id, into: queue.id)
    board.markRunning(task.id)
    board.markFailed(task.id, error: "tasks.errDirtyTree")
    board.local.sessions[task.id] = "session-9"
    board.attachSessions(board.local.sessions)

    let card = TaskCardModel.build(board.task(task.id)!, board: board, expanded: true, githubRepo: false)
    check(card.detail.contains("tasks.detailSession"), "the session is listed in the details")
    check(card.detail.contains("tasks.errDirtyTree"), "the failure reason is translated through L10n")
    check(card.detail.contains("do the thing"), "the task body is in the details")
}

// MARK: - Queue header

section("queue header")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0005eeee")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0006ffff")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Dark Mode", autoPR: true)
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)

    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.name, "Dark Mode", "the queue name is shown")
    eq(header.branchText, "feature/dark-mode → main", "the branch and its base are shown")
    eq(header.progress, "0/2", "progress counts finished over total")
    eq(header.stateKey, "tasks.queue.state.paused", "a fresh queue is paused")
    eq(header.queuedCount, 2, "two tasks are waiting")
    check(header.canStart, "开始 is offered while tasks wait")
    check(!header.canPause, "暂停 is not offered while paused")
    check(!header.canOpenPR, "no PR button before the queue finishes")
    eq(header.failedCount, 0, "no failures yet")

    board.markRunning(t1.id)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.stateKey, "tasks.queue.state.active", "running makes the queue active")
    eq(header.tone, TaskTone.running, "an active queue reads as running")
    check(header.canPause, "暂停 is offered while active")
    check(!header.canStart, "开始 is hidden while active")

    board.markDone(t1.id, prUrl: nil)
    board.markRunning(t2.id)
    board.markDone(t2.id, prUrl: nil)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: true)
    eq(header.progress, "2/2", "progress follows the finished tasks")
    eq(header.stateKey, "tasks.queue.state.finished", "an empty queue is finished")
    check(header.canOpenPR, "the PR button appears when the queue finishes")
    check(header.isCollapsed, "the collapsed flag is carried through")
}

section("queue without a branch and with failures")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0007aaaa")
    board.tasks = [t1]
    let queue = board.createQueue(name: "No Branch", branch: "")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    board.markRunning(t1.id)
    _ = board.markFailed(t1.id, error: "tasks.errNoPush")

    let header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.branchText, "tasks.queue.noBranch", "an empty branch says so")
    eq(header.failedCount, 1, "the failure is counted")
    eq(header.stateKey, "tasks.queue.state.paused", "a failed queue is paused")
    eq(header.tone, TaskTone.negative, "a paused queue with failures reads negative")
    check(!header.canOpenPR, "autoPR is off for this queue")
}

// MARK: - Summary

section("summary card (统计信息)")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0008aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0009bbbb")
    let issue = TaskItem.github(number: 4, title: "Issue four")
    board.tasks = [t1, t2, issue]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)

    let summary = TasksSummaryModel.build(board)
    eq(summary.queues, 1, "the queue is counted")
    eq(summary.queued, 1, "one task waits")
    eq(summary.running, 1, "one task runs")
    eq(summary.failed, 0, "nothing failed")
    // The card is ONE line of labelled counters, in reading order.
    eq(summary.parts.map { $0.text },
       ["tasks.stat.queues 1", "tasks.stat.queued 1", "tasks.stat.running 1", "tasks.stat.failed 0"],
       "the card prints every counter with its label")
    eq(summary.parts.map { $0.count }, [1, 1, 1, 0], "each part carries its count")
    eq(summary.parts[3].tone, TaskTone.neutral, "zero failures stay quiet")
}

// MARK: - Inline forms (新建任务 / 新建队列)

section("task composer (inline 新建任务)")
do {
    var composer = TaskComposerModel.build(mode: .create)
    eq(composer.headingKey, "tasks.new.title", "a fresh composer is the 新建任务 form")
    eq(composer.submitKey, "tasks.new.create", "its button creates")
    check(composer.isPristine, "a fresh composer is pristine")
    check(!composer.canSubmit, "an empty form cannot be submitted")
    eq(composer.problemKey, nil, "a pristine form shows no problem")

    // Typing half a task keeps the form quiet (no nagging) but the button
    // follows the two fields; only Enter explains what is missing.
    composer = composer.typed(title: "Polish README", body: "")
    eq(composer.problemKey, nil, "typing does not nag about the empty description")
    check(!composer.canSubmit, "but a title without a description is not submittable")
    eq(composer.attemptedSubmit().problemKey, "tasks.errBody",
       "an attempted submit names the missing description")

    composer = composer.typed(title: "Polish README", body: "tidy it up")
    eq(composer.problemKey, nil, "both fields filled clears the hint")
    check(composer.canSubmit, "the form can be submitted")
    eq(composer.draft.normalizedTitle, "Polish README", "the draft carries the title")

    // Whitespace-only input is still empty.
    let blank = TaskComposerModel.build(mode: .create, title: "  ", body: "  ")
    check(!blank.canSubmit, "whitespace is not a task")
    eq(blank.attemptedSubmit().problemKey, "tasks.errName",
       "submitting an empty form points at the title")

    // Editing an existing task prefills both fields and saves instead of creating.
    let task = TaskItem.manual(title: "Old title", body: "old body", id: "manual-0010aaaa")
    let editing = TaskComposerModel.edit(task)
    eq(editing.mode, .edit(taskID: "manual-0010aaaa"), "edit mode carries the task id")
    eq(editing.headingKey, "tasks.new.editTitle", "editing says so")
    eq(editing.submitKey, "tasks.new.save", "editing saves")
    eq(editing.title, "Old title", "the title is prefilled")
    eq(editing.body, "old body", "the description is prefilled")
    check(editing.canSubmit, "a prefilled form is submittable")
}

section("queue composer (inline 新建队列)")
do {
    var composer = QueueComposerModel.create(taskID: "manual-0011aaaa")
    eq(composer.headingKey, "tasks.queue.newTitle", "a new queue uses the new-queue heading")
    eq(composer.submitKey, "tasks.queue.create", "a queue created from a card joins the task")
    eq(composer.mode.taskID, "manual-0011aaaa", "the waiting task is remembered")
    check(!composer.canSubmit, "a nameless queue cannot be created")
    eq(composer.problemKey, nil, "an untouched form shows no problem")
    eq(composer.attemptedSubmit().problemKey, "tasks.errQueueName",
       "submitting without a name names the missing field")

    composer = composer.typed(name: "Dark Mode", branch: "", baseBranch: "", autoPR: false)
    check(composer.canSubmit, "a named queue can be created")
    eq(composer.effectiveBranchHint, "feature/dark-mode",
       "an empty branch shows the derived default")
    eq(composer.branchValue, nil, "an empty branch asks for the default")
    eq(composer.normalizedBaseBranch, "main", "an empty base branch falls back to main")

    // A pure-Chinese name has no slug, so the hint falls back to the wording
    // rather than promising a branch that cannot be derived.
    let chinese = QueueComposerModel.create().typed(name: "深色模式改造", branch: "", baseBranch: "main",
                                                    autoPR: false)
    eq(chinese.effectiveBranchHint, "tasks.queue.branchAuto",
       "a name with no slug keeps the generic hint")

    // A typed branch wins, and an explicit one is what the queue gets.
    let typed = chinese.typed(name: "深色模式改造", branch: "feature/dark", baseBranch: "develop",
                              autoPR: true)
    eq(typed.effectiveBranchHint, "feature/dark", "a typed branch is echoed back")
    eq(typed.branchValue, "feature/dark", "and is the value the queue is created with")
    eq(typed.normalizedBaseBranch, "develop", "the base branch is carried")

    // Standalone creation (the queues section header button).
    eq(QueueComposerModel.create().submitKey, "tasks.queue.createOnly",
       "a queue created on its own just creates")

    // The queue's own settings.
    var queue = TaskQueue(id: "q-1111", name: "Lane", branch: "feature/lane", baseBranch: "main")
    queue.autoPR = true
    let settings = QueueComposerModel.edit(queue, prAvailable: true)
    eq(settings.headingKey, "tasks.queue.editTitle", "editing a queue says so")
    eq(settings.submitKey, "tasks.new.save", "editing saves")
    eq(settings.mode.queueID, "q-1111", "the edited queue is remembered")
    eq(settings.name, "Lane", "the name is prefilled")
    eq(settings.branch, "feature/lane", "the branch is prefilled")
    check(settings.autoPR, "the PR switch is prefilled")
    check(settings.prAvailable, "a GitHub workspace can open a PR")
    // Clearing the branch means "run on whatever is checked out".
    let cleared = settings.typed(name: "Lane", branch: "", baseBranch: "main", autoPR: false)
    eq(cleared.effectiveBranchHint, "tasks.queue.noBranch", "no branch says so while editing")
    eq(cleared.branchValue, nil, "no branch really means no branch")
}

section("empty state")
do {
    let fresh = TasksEmptyStateModel.build(filtered: false, githubRepo: true)
    eq(fresh.messageKey, "tasks.empty", "a fresh board points at the way in")
    check(fresh.showsNewTask, "and offers the inline form")
    eq(fresh.symbol, "checklist", "with the checklist symbol")

    let noRepo = TasksEmptyStateModel.build(filtered: false, githubRepo: false)
    eq(noRepo.messageKey, "tasks.emptyManualOnly",
       "a non-GitHub workspace explains what still works")

    let filtered = TasksEmptyStateModel.build(filtered: true, githubRepo: true)
    eq(filtered.messageKey, "tasks.emptyFiltered", "an empty filter says which kind of empty")
    check(!filtered.showsNewTask, "and does not offer to create a task")
}

section("counters, progress and the auto queue flag")
do {
    var board = TaskBoard()
    let t1 = TaskItem.manual(title: "One", id: "manual-0012aaaa")
    let t2 = TaskItem.manual(title: "Two", id: "manual-0013bbbb")
    board.tasks = [t1, t2]
    let queue = board.createQueue(name: "Lane")
    _ = board.enqueue(taskID: t1.id, into: queue.id)
    _ = board.enqueue(taskID: t2.id, into: queue.id)
    board.markRunning(t1.id)

    var header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.runningCount, 1, "the running task is counted for the header")
    eq(header.progressFraction, 0, "nothing is finished yet")
    check(!header.isAutoCreated, "a user queue is not an auto queue")

    board.markDone(t1.id, prUrl: nil)
    header = QueueHeaderModel.build(board.queue(queue.id)!, board: board, collapsed: false)
    eq(header.progressFraction, 0.5, "half the queue is done")
    eq(header.runningCount, 0, "nothing runs now")

    let issue = TaskItem.github(number: 7, title: "Seven")
    let auto = board.createQueue(name: "Issue #7", autoCreated: true)
    _ = board.enqueue(taskID: issue.id, into: auto.id)
    let autoHeader = QueueHeaderModel.build(board.queue(auto.id)!, board: board, collapsed: true)
    check(autoHeader.isAutoCreated, "the issue lane is flagged as auto-created")

    // The summary card mirrors the counts, and only 失败 lights up.
    let summary = TasksSummaryModel.build(board)
    eq(summary.parts.count, 4, "four counters")
    eq(summary.parts.map { $0.key },
       ["tasks.stat.queues", "tasks.stat.queued", "tasks.stat.running", "tasks.stat.failed"],
       "the card reads 队列 · 排队 · 运行 · 失败")
    eq(summary.parts.map { $0.count }, [summary.queues, summary.queued, summary.running, summary.failed],
       "every counter carries its count")
    eq(summary.parts[3].tone, TaskTone.neutral, "zero failures stay quiet")
    eq(TaskSummaryPart.tone(forCount: 2, negativeWhenPositive: true), TaskTone.negative,
       "failures light up")
    eq(TaskSummaryPart.tone(forCount: 2, negativeWhenPositive: false), TaskTone.neutral,
       "running is an accent count, not an alarm")
}

if failures == 0 {
    print("ok - \(checks) checks passed")
} else {
    print("FAILED - \(failures) of \(checks) checks failed")
    exit(1)
}
