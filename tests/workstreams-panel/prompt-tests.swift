import Foundation

// Headless tests for the panel-generated stage handoff prompts
// (WorkstreamsPrompts.swift, design D15 / workstream-handoff-prompt-design):
//   - each stage's key requirements (planning / design / task / acceptance / delivery);
//   - the public header (card pointer, requirement pointer, stage + action, goal);
//   - the shared model rules, with the regression gate line only when REG-* is set;
//   - injection into a stage queue task's body and the execution-stage completion marker;
//   - the tasks panel's /task-todo skill is gone: task create / start point at the
//     panel's own /api/workstreams/task/create and /api/workstreams/queue/start (D19).
//
// No AppKit, no disk, no dsh server. Usage: tests/workstreams-panel/run.sh

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1; print("  FAIL " + label) }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL " + label + ": got " + String(describing: actual) + ", want " + String(describing: expected))
    }
}

func section(_ name: String) { print("--- " + name + " ---") }

func contains(_ text: String, _ needle: String, _ label: String) {
    check(text.contains(needle), label + " (missing: " + needle + ")")
}

func notContains(_ text: String, _ needle: String, _ label: String) {
    check(!text.contains(needle), label + " (unexpected: " + needle + ")")
}

// MARK: - Fixtures

/// A card shaped like the real ones: planning section with the four-piece set.
func makeCard(id: String = "WS-000007",
              title: String = "阶段提示词",
              requirement: String? = "REQ-000007",
              stage: WorkstreamStage = .planning,
              regression: String? = nil,
              planningGoal: String? = "产出面板生成的各阶段提示词") -> WorkstreamCard {
    var body = "# " + id + " " + title + "\n\n## 规划\n"
    if let goal = planningGoal {
        body += "\n- 目标：" + goal
    }
    body += "\n- 边界：只改事项面板；不建新面板。\n- 验收标准：测试全绿。\n- 阶段裁剪声明：不裁剪。\n"
    return WorkstreamCard(id: id, title: title, requirement: requirement, stage: stage,
                          covered: nil, regression: regression, queues: [], delivery: nil,
                          created: nil, updated: nil, path: "/tmp/" + id + ".md", body: body)
}

// MARK: - (stage, action) 映射

section("(stage, action) map and stage labels")
do {
    eq(WSStageAction.defaultAction(for: .planning), .confirmPlanning, "planning defaults to 确认规划")
    eq(WSStageAction.defaultAction(for: .design), .produceDesign, "design defaults to 出设计")
    eq(WSStageAction.defaultAction(for: .task), .splitTasks, "task defaults to 拆分任务 (split before start)")
    eq(WSStageAction.defaultAction(for: .acceptance), .verify, "acceptance defaults to 校验")
    eq(WSStageAction.defaultAction(for: .delivery), .deliver, "delivery defaults to 交付")
    eq(WSStageAction.startImplementation.stage, .task, "启动实施 belongs to the task stage")
    eq(WSStageAction.splitTasks.stage, .task, "拆分任务 belongs to the task stage")
    eq(WorkstreamHandoff.stageLabel(.planning), "规划", "planning label")
    eq(WorkstreamHandoff.stageLabel(.design), "设计", "design label")
    eq(WorkstreamHandoff.stageLabel(.task), "执行", "task stage is labelled 执行")
    eq(WorkstreamHandoff.stageLabel(.acceptance), "验收", "acceptance label")
    eq(WorkstreamHandoff.stageLabel(.delivery), "交付", "delivery label")
    eq(WSStageAction.allCases.count, 6, "six actions across five stages")
}

// MARK: - 公共头（design §3）

section("public header: pointer + stage + action + goal (design §3)")
do {
    let card = makeCard()
    let prompt = WorkstreamHandoff.prompt(card: card, stage: .planning, repoName: "oh-my-dsh")
    contains(prompt, "你在 oh-my-dsh 处理一个事项。", "names the repo")
    contains(prompt, WorkstreamHandoff.factsMarker, "carries the 本步事实 block")
    contains(prompt, "- 事项：.dsh/workstreams/WS-000007.md", "points at the WS card")
    contains(prompt, "- 需求：.dsh/requirements/REQ-000007.md", "points at the requirement card")
    contains(prompt, "- 存储约定：.dsh/requirements/README.md", "points at the storage convention")
    contains(prompt, WorkstreamHandoff.stageMarker + "规划", "names the current stage")
    contains(prompt, "本步动作：确认规划", "names this step's action")
    contains(prompt, "目标：产出面板生成的各阶段提示词", "injects the planning goal")
    check(WorkstreamHandoff.isHandoff(prompt), "a generated prompt is recognised as a handoff")
    notContains(WorkstreamHandoff.prompt(card: makeCard(requirement: nil), stage: .planning),
                "- 需求：", "a card without a requirement omits the requirement line")
    notContains(WorkstreamHandoff.prompt(card: makeCard(planningGoal: nil), stage: .planning),
                "目标：", "a card without a planning goal omits the goal line")
    // repo name falls back to the workspace basename when not given.
    contains(WorkstreamHandoff.prompt(card: card, stage: .planning, workspace: "/tmp/repo-name"),
             "你在 repo-name 处理一个事项。", "repo name comes from the workspace basename")
}

section("planning goal extraction")
do {
    // The real card shape: "- 目标：..." possibly wrapped onto an indented continuation line.
    let body = "## 规划\n\n- 目标：第一行\n  续行\n- 边界：x\n"
    eq(WorkstreamHandoff.planningGoal(body), "第一行 续行", "goal plus indented continuation is joined")
    eq(WorkstreamHandoff.planningGoal("## 规划\n\n- 目标（WHAT）：可观察结果\n"),
       "可观察结果", "goal（WHAT） is recognised")
    eq(WorkstreamHandoff.planningGoal("## 规划\n\n- 边界：x\n"), nil, "no goal -> nil")
    eq(WorkstreamHandoff.planningGoal("## 设计\n\n- 目标：x\n"), nil, "goal is only read from 规划")
}

// MARK: - 各阶段关键要求（design §4）

section("planning: four-piece set then human confirmation")
do {
    let p = WorkstreamHandoff.prompt(card: makeCard(), stage: .planning)
    contains(p, "确认规划", "action is 确认规划")
    contains(p, "/api/workstreams/plan", "planning writes the section through the API")
    contains(p, "不直接改", "planning never edits .dsh directly")
    contains(p, "四件套", "requires the four-piece set")
    contains(p, "目标（WHAT）", "names 目标（WHAT）")
    contains(p, "边界", "names 边界")
    contains(p, "验收标准（AC<n>）", "names 验收标准")
    contains(p, "阶段裁剪声明", "names 阶段裁剪声明")
    contains(p, "停下请人确认规划", "stops for human confirmation")
    contains(p, "人确认前不得进入设计", "does not enter design before confirmation")
}

section("design: write the design doc, not the implementation")
do {
    let p = WorkstreamHandoff.prompt(card: makeCard(), stage: .design)
    contains(p, "出设计", "action is 出设计")
    contains(p, "docs/design/", "writes under docs/design")
    contains(p, "只写设计", "does not write the implementation")
    contains(p, "不写实现", "states 不写实现")
    contains(p, "停下请人确认设计", "stops for human confirmation")
}

section("task split: waiting stage tasks via the panel API, never auto-start")
do {
    let p = WorkstreamHandoff.prompt(card: makeCard(), stage: .task)
    contains(p, "拆分任务", "default task action is 拆分任务")
    contains(p, "/api/workstreams/task/create", "creates waiting tasks through the panel's own API")
    contains(p, "等待态阶段任务", "creates waiting-state stage tasks")
    contains(p, "本阶段 `stage`", "explains that each task carries the stage")
    contains(p, "只建不启动", "does not start the tasks")
    contains(p, "停下请人确认拆分合理", "stops for human confirmation")
    notContains(p, "/task-todo", "never points at the tasks panel's skill")
}

section("task start: execution after confirmation, marker protocol")
do {
    let card = makeCard()
    let p = WorkstreamHandoff.prompt(card: card, action: .startImplementation)
    contains(p, "启动实施", "action is 启动实施")
    contains(p, "/api/workstreams/queue/start", "starts the queue through the panel's own API")
    contains(p, "带 `stage`", "a stage-scoped start only runs that stage's tasks")
    contains(p, "conventional commits", "keeps conventional commits")
    notContains(p, "/task-todo", "never points at the tasks panel's skill")
    // 执行阶段沿用 marker 完成协议：提示词 + marker instruction，marker 落在末尾。
    let marked = WorkstreamHandoff.injectingCompletionMarker(p, marker: "DSH-WS-DONE-ABCDEF01")
    contains(marked, "DSH-WS-DONE-ABCDEF01", "the execution marker is injected")
    check(marked.hasSuffix("DSH-WS-DONE-ABCDEF01"), "the marker is the last line")
    check(marked.hasPrefix(p), "injection only appends to the prompt")
    eq(WorkstreamHandoff.injectingCompletionMarker(p, marker: nil), p, "no marker -> no change")
    eq(WorkstreamHandoff.injectingCompletionMarker(p, marker: "  "), p, "blank marker -> no change")
    contains(WorkstreamHandoff.completionMarkerInstruction("DSH-WS-DONE-ABCDEF01"),
             "DSH-WS-DONE-ABCDEF01", "marker instruction names the marker")
}

section("acceptance: run the evidence, human signs off")
do {
    let p = WorkstreamHandoff.prompt(card: makeCard(), stage: .acceptance)
    contains(p, "校验", "action is 校验")
    contains(p, "机检证据", "collects machine evidence")
    contains(p, "sign-off", "requires human sign-off")
    contains(p, "不自签", "the agent does not self-sign")
    contains(p, "/api/workstreams/covered", "records covered through the write route")
}

section("delivery: push / PR, facts recorded, outcome derived")
do {
    let p = WorkstreamHandoff.prompt(card: makeCard(), stage: .delivery)
    contains(p, "交付", "action is 交付")
    contains(p, "push", "pushes")
    contains(p, "PR", "opens a PR")
    contains(p, "outcome", "mentions outcome")
    contains(p, "不手写", "does not hand-write the derived outcome")
    contains(p, "不直接改", "delivery never edits .dsh directly")
    contains(p, "/api/workstreams/delivery", "records delivery facts through the write route")
}

// MARK: - 模型规则（design §4）

section("shared model rules on every stage")
do {
    for stage in WorkstreamStage.allCases {
        let p = WorkstreamHandoff.prompt(card: makeCard(), stage: stage)
        contains(p, "规则（强制）：", "rules header for " + stage.rawValue)
        contains(p, "/api/workstreams/", "API write rule for " + stage.rawValue)
        contains(p, "workstream-panel", "names the workstream-panel skill for " + stage.rawValue)
        contains(p, "不直接改", "no direct .dsh edits for " + stage.rawValue)
        contains(p, "回边合法但必须留痕", "back-edge rule for " + stage.rawValue)
        contains(p, "只拆不胀", "只拆不胀 rule for " + stage.rawValue)
        contains(p, "派生谓词", "derived terminal state for " + stage.rawValue)
        contains(p, "/api/workstreams/task/create", "task-create rule for " + stage.rawValue)
        contains(p, "/api/workstreams/queue/start", "queue-start rule for " + stage.rawValue)
        contains(p, "任务带 `stage`", "stage-carrying tasks rule for " + stage.rawValue)
        notContains(p, "/task-todo", "no tasks-panel skill for " + stage.rawValue)
        contains(p, "不改其它会话的在途文件", "in-flight-files rule for " + stage.rawValue)
    }
    let plain = WorkstreamHandoff.prompt(card: makeCard(regression: nil), stage: .planning)
    notContains(plain, "回归门", "no regression line without a REG-* card")
    let gated = WorkstreamHandoff.prompt(card: makeCard(regression: "REG-002"), stage: .delivery)
    contains(gated, "回归门 REG-002", "the regression line names the card's REG-*")
}

// MARK: - 注入阶段队列任务的 body（design §2）

section("inject the prompt into a stage queue task's body")
do {
    let card = makeCard()
    let draft = WorkstreamHandoff.stageTask(title: "规划", card: card, action: .confirmPlanning)
    check(draft.isValid, "the draft is valid")
    eq(draft.normalizedTitle, "规划", "the title is kept")
    let expected = WorkstreamHandoff.prompt(card: card, action: .confirmPlanning)
    eq(draft.effectiveBody, expected, "the prompt is the task body")
    check(WorkstreamHandoff.isHandoff(draft.effectiveBody), "the body is a generated handoff")
    eq(draft.body, draft.normalizedBody, "the body carries no leading/trailing blank lines")

    var task = WSTaskItem(id: "wt-1", title: "规划")
    task = WorkstreamHandoff.injectingStagePrompt(into: task, card: card, action: .confirmPlanning)
    eq(task.body, expected, "injectingStagePrompt writes the prompt into an existing task")
}

// MARK: - 运行时：runner 原样发送提示词并追加 marker

section("runner sends the panel prompt and appends the execution marker")
do {
    // Minimal scripted dsh (same idea as runner-tests.swift, reduced to what this needs).
    final class ScriptedDsh {
        var sessions: [String] = []
        var running: Set<String> = []
        var prompts: [String: String] = [:]
        func create() -> String? {
            let id = "session-" + String(sessions.count + 1)
            sessions.append(id); running.insert(id); return id
        }
        func rename(_ id: String, _ title: String) -> Bool { true }
        func prompt(_ id: String, _ text: String) -> Bool { prompts[id] = text; return true }
        func state(_ id: String) -> WSSessionState { running.contains(id) ? .running : .idle }
        func cancel(_ id: String) -> Bool { running.remove(id); return true }
    }
    let dsh = ScriptedDsh()
    let card = makeCard()
    let draft = WorkstreamHandoff.stageTask(title: "启动实施", card: card,
                                            action: .startImplementation)
    var board = WSBoard()
    let env = WSRunnerEnv(
        repoRoot: "/tmp/ws",
        createSession: { _ in dsh.create() },
        renameSession: { id, title in dsh.rename(id, title) },
        promptSession: { id, text in dsh.prompt(id, text) },
        sessionState: { id in dsh.state(id) },
        cancelSession: { id in dsh.cancel(id) },
        requireCompletionMarker: true,
        persist: { _ in },
        log: { _ in },
        perform: { block, done in block(); done() })
    let runner = WorkstreamsRunner(board: board, env: env)
    let queue = runner.createQueue(name: "执行", workstreamID: card.id)
    board = runner.board
    let task = WSTaskItem(id: WSTaskItem.newID(), title: draft.normalizedTitle,
                          body: draft.effectiveBody, workstreamId: card.id, stage: .task)
    board.tasks.append(task)
    _ = board.enqueue(taskID: task.id, into: queue.id)
    runner.adopt(board)
    _ = runner.startQueue(queue.id)
    let sent = dsh.prompts[dsh.sessions[0]] ?? ""
    check(sent.hasPrefix(draft.effectiveBody), "the runner sends the panel prompt as-is")
    contains(sent, "本步做「启动实施」", "the sent prompt carries the action section")
    contains(sent, "DSH-WS-DONE-", "the execution marker is appended")
    notContains(sent, "你正在推进事项", "the panel prompt is NOT wrapped in the generic template")
}

section("createStageQueue injects the prompt body and stays a waiting queue")
do {
    let env = WSRunnerEnv(
        repoRoot: "/tmp/ws",
        createSession: { _ in nil },
        renameSession: { _, _ in false },
        promptSession: { _, _ in false },
        sessionState: { _ in .idle },
        cancelSession: { _ in false },
        persist: { _ in },
        log: { _ in },
        perform: { block, done in block(); done() })
    let runner = WorkstreamsRunner(board: WSBoard(), env: env)
    let card = makeCard()
    let built = runner.createStageQueue(card: card, stage: .planning, workspace: "/tmp/ws",
                                        titles: ["出规划四件套"])
    eq(built.created.count, 1, "one stage task created")
    eq(built.queue.state, .draft, "the stage queue stays draft (waiting, not started)")
    eq(built.queue.stage == nil, true, "the queue no longer carries a stage")
    eq(built.queue.name, card.title, "the queue is named after the workstream (one queue)")
    eq(built.queue.workstreamId, card.id, "the queue carries the workstream id")
    eq(built.created[0].stage, .planning, "the task carries the stage")
    eq(built.created[0].workstreamId, card.id, "the task carries the workstream id")
    let body = built.created[0].body ?? ""
    check(WorkstreamHandoff.isHandoff(body), "the task body is the panel handoff prompt")
    contains(body, "本步动作：确认规划", "it uses the stage's default action")
}

// MARK: - 对话内阶段推进：确认 → 下一阶段提示词（design §5 + §6）

section("next-stage handoff after a human confirmation")
do {
    // 手动验收路径：确认「规划」后，主场会话应收到「设计」阶段提示词。
    let planning = makeCard(stage: .planning)
    let first = WorkstreamHandoff.nextStagePrompt(card: planning, workspace: "/tmp/ws")
    eq(first?.stage, .design, "confirming 规划 hands off to 设计")
    if let prompt = first?.prompt {
        check(WorkstreamHandoff.isHandoff(prompt), "the next-stage prompt is a panel handoff")
        contains(prompt, "当前 stage：设计", "the 设计 stage marker is in the prompt")
        contains(prompt, "本步动作：出设计", "the 设计 default action is in the prompt")
        eq(prompt, WorkstreamHandoff.prompt(card: planning, stage: .design, workspace: "/tmp/ws"),
           "the next-stage prompt is the 设计 stage prompt verbatim")
    } else {
        check(false, "planning must hand off to 设计")
    }
    // 每个非终态阶段都前移一格，且用的是目标阶段的默认动作。
    eq(WorkstreamHandoff.nextStagePrompt(card: makeCard(stage: .design))?.stage, .task,
       "design hands off to 执行 (task)")
    eq(WorkstreamHandoff.nextStagePrompt(card: makeCard(stage: .task))?.stage, .acceptance,
       "task hands off to 验收")
    eq(WorkstreamHandoff.nextStagePrompt(card: makeCard(stage: .acceptance))?.stage, .delivery,
       "acceptance hands off to 交付")
    // 交付是终态：确认它没有下一阶段，不发提示词。
    eq(WorkstreamHandoff.nextStagePrompt(card: makeCard(stage: .delivery)) == nil, true,
       "delivery is terminal: no next-stage prompt")
    // 目标从卡片注入（同一张卡 → 同一段提示词）。
    let design = WorkstreamHandoff.nextStagePrompt(card: makeCard(stage: .design,
        planningGoal: "产出面板生成的各阶段提示词"))?.prompt ?? ""
    contains(design, "目标：产出面板生成的各阶段提示词", "the goal is injected from the card")
    // 需求指针 / 仓库名沿用公共头。
    let named = WorkstreamHandoff.nextStagePrompt(card: makeCard(stage: .planning),
                                                  workspace: "/tmp/my-repo")?.prompt ?? ""
    contains(named, "你在 my-repo 处理一个事项", "the next-stage prompt names the repo")
    check(named.contains("- 事项：.dsh/workstreams/" + planning.id + ".md"),
          "the next-stage prompt still points at the workstream card")
}

// MARK: - 拆分任务提示词（首个未处理阶段）

section("split-task prompt names an explicit stage (first unprocessed)")
do {
    let card = makeCard(stage: .design)
    let p = WorkstreamHandoff.splitPrompt(card: card, stage: .design, repoName: "oh-my-dsh")
    contains(p, "你在 oh-my-dsh 处理一个事项。", "names the repo")
    check(WorkstreamHandoff.isHandoff(p), "the split prompt is a panel handoff")
    contains(p, "- 事项：.dsh/workstreams/WS-000007.md", "points at the WS card")
    contains(p, WorkstreamHandoff.stageMarker + "设计", "names the requested stage (not .task)")
    contains(p, "本步动作：拆分任务", "the action is 拆分任务")
    contains(p, "/api/workstreams/task/create", "creates waiting tasks through the panel API")
    contains(p, "等待态阶段任务", "creates waiting-state stage tasks")
    contains(p, "本阶段 `stage`", "each task carries the stage")
    contains(p, "只建不启动", "only creates, never starts")
    contains(p, "不自签", "the agent never self-signs the split")
    contains(p, "停下请人确认拆分合理", "stops for human confirmation")
    notContains(p, "/task-todo", "never points at the tasks panel's skill")
    // Every stage can be split; the header always names the requested stage.
    for stage in WorkstreamStage.allCases {
        let sp = WorkstreamHandoff.splitPrompt(card: makeCard(), stage: stage)
        contains(sp, WorkstreamHandoff.stageMarker + WorkstreamHandoff.stageLabel(stage),
                 "split prompt names " + stage.rawValue)
        contains(sp, "本步动作：拆分任务", "split action for " + stage.rawValue)
    }
    // 执行阶段的拆分与 (stage, action) 通用构造逐字一致（同一个动作段）。
    eq(WorkstreamHandoff.splitPrompt(card: card, stage: .task, workspace: "/tmp/ws"),
       WorkstreamHandoff.prompt(card: card, stage: .task, workspace: "/tmp/ws"),
       "splitting the task stage reuses the generic (stage, action) prompt")
}

print("")
if failures == 0 {
    print("prompt tests passed (" + String(checks) + " checks)")
} else {
    print(String(failures) + " of " + String(checks) + " checks FAILED")
    exit(1)
}
