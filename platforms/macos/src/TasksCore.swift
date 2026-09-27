import Foundation

// MARK: - Failure reasons

/// Why a task failed. The raw value IS the L10n key stored in the board and
/// shown on the card (the panel renders L10n.tr(error)), so a missing entry
/// surfaces in tests/l10n rather than on screen.
///
/// It lives here with the board that persists it: the VIEW layer needs one of
/// these keys too — a card whose task failed with .notGitRepo offers
/// 「不切分支并重试」 and must recognize the failure without the runner
/// (TasksUI.swift).
enum TaskFailure: String {
    case interrupted = "tasks.errInterrupted"
    /// The task's session disappeared from dsh (deleted in the sidebar, or the
    /// server was restarted) — nobody can say what became of the work.
    case sessionGone = "tasks.errSessionGone"
    case notGitRepo = "tasks.errNotGit"
    case dirtyWorktree = "tasks.errDirtyTree"
    case checkout = "tasks.errBranch"
    case pull = "tasks.errPull"
    case session = "tasks.errSession"
    case prompt = "tasks.errPrompt"
    case timeout = "tasks.errTimeout"
    case noPush = "tasks.errNoPush"
}

// MARK: - Source & state

/// Where a task came from — drives the source badge on a task card
/// (Issue #12 vs 手动).
enum TaskSource: String {
    case github
    case manual
}

/// One task's lifecycle.
///
/// v2 adds queued (a task waiting for its serial slot inside a queue);
/// pending therefore means "not in any queue" and is never started
/// implicitly. The remaining cases keep v1's raw values, so an existing
/// index.json needs no migration.
enum TaskState: String {
    case pending
    case queued
    case running
    case done
    case failed
    case cancelled
    case closed

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled, .closed: return true
        case .pending, .queued, .running: return false
        }
    }

    /// May be put into a queue (again).
    var isQueueable: Bool {
        switch self {
        case .pending, .failed, .cancelled: return true
        case .queued, .running, .done, .closed: return false
        }
    }

    /// One-glyph badge for the compact list (the cards get colored labels).
    var badge: String {
        switch self {
        case .pending: return "·"
        case .queued: return "≡"
        case .running: return "…"
        case .done: return "✓"
        case .failed: return "✗"
        case .cancelled: return "−"
        case .closed: return "☑"
        }
    }
}

/// A queue's own state: active runs its tasks one at a time, paused waits for
/// the user (a task failed, the worktree was dirty, or the app restarted),
/// done has nothing left to run.
enum QueueState: String {
    case active
    case paused
    case done
}

// MARK: - Task

/// One task — a GitHub issue or a locally created manual task.
///
/// The dsh session id is NOT part of the task's own record: a session only
/// exists on the machine that created it, so it lives in local.json
/// (TaskLocalState.sessions), exactly like v1's issue to session overlay.
struct TaskItem: Equatable {
    var id: String
    var source: TaskSource
    var number: Int?
    var title: String
    var body: String?
    var labels: [String]
    var state: TaskState
    var queueId: String?
    var branch: String?
    var prUrl: String?
    var sessionId: String?
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?
    /// What the agent said when it finished — its 汇报, written back onto the task by
    /// the runner (see TasksRunner.finish) instead of living only inside the session
    /// log. The card shows it, and the next task of the queue receives it as its
    /// 前置汇报 (so the hand-over survives a deleted session).
    ///
    /// Machine-scoped like sessionId (a report is the last text of a session that
    /// exists only on this machine): it belongs to local.json, never to manual.json /
    /// index.json — the committed index keeps its v1 shape and stays shareable.
    var report: String?

    init(id: String,
         source: TaskSource,
         number: Int? = nil,
         title: String,
         body: String? = nil,
         labels: [String] = [],
         state: TaskState = .pending,
         queueId: String? = nil,
         branch: String? = nil,
         prUrl: String? = nil,
         sessionId: String? = nil,
         error: String? = nil,
         startedAt: Date? = nil,
         finishedAt: Date? = nil,
         report: String? = nil) {
        self.id = id
        self.source = source
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
        self.state = state
        self.queueId = queueId
        self.branch = branch
        self.prUrl = prUrl
        self.sessionId = sessionId
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.report = report
    }

    /// ISO-8601 in the exact shape v1 wrote (2026-08-20T15:26:43Z).
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: ids

    static func githubID(_ number: Int) -> String { "issue-\(number)" }

    static func manualID(_ token: String) -> String { "manual-\(token)" }

    /// A fresh manual id: manual- followed by 8 lowercase hex characters.
    static func newManualID() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return manualID(String(token).lowercased())
    }

    /// "issue-12" -> (.github, 12); "manual-ab12cd34" -> (.manual, nil).
    static func parse(id: String) -> (source: TaskSource, number: Int?)? {
        if id.hasPrefix("issue-"), let n = Int(id.dropFirst("issue-".count)) { return (.github, n) }
        if id.hasPrefix("manual-") { return (.manual, nil) }
        return nil
    }

    // MARK: factories

    static func github(number: Int, title: String, body: String? = nil, labels: [String] = []) -> TaskItem {
        TaskItem(id: githubID(number), source: .github, number: number,
                 title: title, body: body, labels: labels)
    }

    static func manual(title: String, body: String? = nil, id: String = TaskItem.newManualID()) -> TaskItem {
        TaskItem(id: id, source: .manual, title: title, body: body)
    }

    // MARK: persistence

    /// manual.json entry (machine-scoped). The session id is deliberately
    /// absent — it lives in local.json.
    func manualDictionary() -> [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "state": state.rawValue, "source": source.rawValue]
        if let body = body { d["body"] = body }
        if let queueId = queueId { d["queueId"] = queueId }
        if let branch = branch { d["branch"] = branch }
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let error = error { d["error"] = error }
        if let startedAt = startedAt { d["startedAt"] = TaskItem.iso8601.string(from: startedAt) }
        if let finishedAt = finishedAt { d["finishedAt"] = TaskItem.iso8601.string(from: finishedAt) }
        return d
    }

    static func fromManual(_ d: [String: Any]) -> TaskItem? {
        guard let id = d["id"] as? String, id.hasPrefix("manual-") else { return nil }
        return TaskItem(id: id,
                        source: .manual,
                        number: nil,
                        title: (d["title"] as? String) ?? id,
                        body: d["body"] as? String,
                        labels: [],
                        state: TaskState(rawValue: (d["state"] as? String) ?? "pending") ?? .pending,
                        queueId: d["queueId"] as? String,
                        branch: d["branch"] as? String,
                        prUrl: d["prUrl"] as? String,
                        sessionId: nil,
                        error: d["error"] as? String,
                        startedAt: (d["startedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) },
                        finishedAt: (d["finishedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) })
    }

    /// index.json entry — the v1 committed shape (keyed by issue number), so
    /// existing files, teammates and external tools keep working unchanged.
    /// body is written as NSNull when absent, which v1 used as "already looked
    /// up, nothing there" (only the single-issue endpoint can fill it later).
    func indexDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "issue": number ?? 0,
            "source": source.rawValue,
            "title": title,
            "state": state.rawValue,
            "labels": labels,
        ]
        if let body = body { d["body"] = body } else { d["body"] = NSNull() }
        if let branch = branch { d["branch"] = branch }
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let error = error { d["error"] = error }
        if let startedAt = startedAt { d["startedAt"] = TaskItem.iso8601.string(from: startedAt) }
        if let finishedAt = finishedAt { d["finishedAt"] = TaskItem.iso8601.string(from: finishedAt) }
        return d
    }

    static func fromIndex(_ d: [String: Any]) -> TaskItem? {
        guard let number = d["issue"] as? Int else { return nil }
        return TaskItem(id: githubID(number),
                        source: .github,
                        number: number,
                        title: (d["title"] as? String) ?? "issue #\(number)",
                        body: d["body"] as? String,
                        labels: (d["labels"] as? [String]) ?? [],
                        state: TaskState(rawValue: (d["state"] as? String) ?? "pending") ?? .pending,
                        queueId: nil,
                        branch: d["branch"] as? String,
                        prUrl: d["prUrl"] as? String,
                        sessionId: nil,
                        error: d["error"] as? String,
                        startedAt: (d["startedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) },
                        finishedAt: (d["finishedAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) })
    }
}

// MARK: - Branch naming

/// Branch names — one place, shared by the panel, the runner and the tests.
enum TaskBranch {

    /// Lower-cased, ASCII letters/digits only, every other run collapsed into a
    /// single dash, trimmed, at most 40 characters. A name without any ASCII
    /// letter or digit at all (a pure Chinese queue name) yields an empty
    /// string, and the caller falls back to the queue id.
    static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            let keep = ch.isASCII && (ch.isLetter || ch.isNumber)
            if keep {
                out.append(ch)
            } else if !out.isEmpty && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        var trimmed = String(out.prefix(40))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }

    /// feature/ plus the name's slug; when the name has no usable slug at all
    /// the default falls back to the queue id (feature/queue-7f3a) instead of an
    /// empty branch name. Never returns an empty string.
    static func defaultBranch(queueName: String, queueID: String) -> String {
        let s = slug(queueName)
        if s.isEmpty { return "feature/queue-" + String(queueID.suffix(4)) }
        return "feature/" + s
    }

    /// The branch a queue should be based on — what the repo itself says, rather
    /// than an assumed "main".
    ///
    /// A repo whose default branch is `master` (or `develop`) used to fail its
    /// very first issue task: the pipeline starts with `git checkout main`
    /// (TasksRunner.enter) and stops there with 「切换分支失败」.
    ///
    /// The caller digs the facts out of git; the decision chain lives here so it
    /// can be asserted without a repo:
    ///   1. the remote's HEAD (`origin/main` → `main`),
    ///   2. a local `main`,
    ///   3. a local `master`,
    ///   4. whatever is checked out right now,
    ///   5. "main" (nothing could be learned).
    static func defaultBaseBranch(symbolicRef: String?, current: String?,
                                  hasMain: Bool, hasMaster: Bool) -> String {
        if let ref = symbolicRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            // "origin/main" / "refs/remotes/origin/main" → the branch name.
            // "origin/HEAD" is an UNRESOLVED symref (dangling): it says nothing
            // about a branch name, so the chain keeps looking.
            if let slash = ref.lastIndex(of: "/") {
                let tail = String(ref[ref.index(after: slash)...])
                if !tail.isEmpty, tail != "HEAD" { return tail }
            } else if ref != "HEAD" {
                return ref
            }
        }
        if hasMain { return "main" }
        if hasMaster { return "master" }
        if let current = current?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty, current != "HEAD" {
            return current
        }
        return "main"
    }

    /// v1 rule kept intact (docs/git-workflow.md): feature-class issues get
    /// feature/issue-N, everything else fix/issue-N.
    static func issueBranch(number: Int, labels: [String]) -> String {
        let lowered = labels.map { $0.lowercased() }
        let isFeature = lowered.contains { $0.contains("feature") || $0.contains("enhancement") }
        return isFeature ? "feature/issue-\(number)" : "fix/issue-\(number)"
    }
}

// MARK: - Manual task draft

/// What the user typed in 新建任务 — ONE box (2026-09-26): the first line is the
/// title, every line after it is the description, and a single line is BOTH. The
/// queue is still chosen later, from the card, so creating a task never forces a
/// decision about branches or PRs.
struct TaskDraft: Equatable {
    var title: String
    var body: String

    init(title: String = "", body: String = "") {
        self.title = title
        self.body = body
    }

    var normalizedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What actually gets stored: a draft that carries no description of its own
    /// keeps the TITLE as its description too — a one-line task hands the agent
    /// that line, and the line is also what names the card and the session.
    var effectiveBody: String { normalizedBody.isEmpty ? normalizedTitle : normalizedBody }

    var isValid: Bool { problem == nil }

    /// The first problem as an L10n key, or nil when the draft is fine. Only the
    /// TITLE is required now: the description can always fall back to it (see
    /// effectiveBody), so a single line is a complete task.
    var problem: String? { normalizedTitle.isEmpty ? "tasks.errName" : nil }

    /// The composer's ONE box, split into the two things a task is made of:
    /// first line = title, the lines after it = description.
    static func composed(from content: String) -> TaskDraft {
        let lines = content.components(separatedBy: .newlines)
        let title = (lines.first ?? "").trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有一行（或其余行都是空白）时，这一行同时作为标题与描述。
        return TaskDraft(title: title, body: rest.isEmpty ? title : rest)
    }

    /// The inverse of composed(from:), for prefilling that box while editing: a
    /// task whose description IS its title goes back to a single line instead of
    /// showing the same sentence twice.
    static func combined(title: String, body: String?) -> String {
        let raw = body ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return title }
        if trimmed == title.trimmingCharacters(in: .whitespacesAndNewlines) { return title }
        return title + "\n" + raw
    }
}

/// One entry of the 加入队列 ▾ picker.
struct QueueChoice: Equatable {
    var id: String
    var name: String
    var branch: String?
    var taskCount: Int
    var state: QueueState
}

// MARK: - Queue

/// A queue is a lane: every task in it shares ONE branch and runs strictly in
/// order, so a later task sees the earlier task's commits.
struct TaskQueue: Equatable {
    var id: String
    var name: String
    /// The branch every task of this queue works on. nil = do not switch
    /// branches at all (run on whatever is checked out).
    var branch: String?
    var baseBranch: String
    var taskIds: [String]
    var state: QueueState
    /// true for the single-task queue the panel creates for an ISSUE task
    /// (rendered compactly, but counted like any other queue).
    var autoCreated: Bool
    /// Whether the queue opens a PR once it is finished. Requires a GitHub
    /// workspace; false everywhere else (an internal repo has no PR to open).
    var autoPR: Bool
    var prUrl: String?
    /// Why the PR session did not produce a PR (an L10n key), or nil. The queue keeps
    /// its 已完成 state — a PR that could not be opened is not failed work — but the
    /// reason is shown instead of silently disappearing into the log.
    var prError: String?
    var createdAt: Date?

    init(id: String,
         name: String,
         branch: String? = nil,
         baseBranch: String = "main",
         taskIds: [String] = [],
         state: QueueState = .paused,
         autoCreated: Bool = false,
         autoPR: Bool = false,
         prUrl: String? = nil,
         prError: String? = nil,
         createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.taskIds = taskIds
        self.state = state
        self.autoCreated = autoCreated
        self.autoPR = autoPR
        self.prUrl = prUrl
        self.prError = prError
        self.createdAt = createdAt
    }

    static func newID() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "q-" + String(token).lowercased()
    }

    /// The single-task queue an issue task runs in (decision 5): created on
    /// 处理, reused on retry, so v1's one-issue-one-branch-one-PR rule — and its
    /// fix/issue-N naming — survive untouched.
    ///
    /// It starts with NO tasks: the task joins through TaskBoard.enqueue, the one
    /// place that owns membership (and writes the task's queueId). Pre-loading the
    /// id here AS WELL made every issue task show up twice in its own lane
    /// (taskIds = ["issue-7","issue-7"] → two identical cards, progress 0/2, and
    /// 「队列内 2 个任务」 in the delete dialog).
    static func auto(for task: TaskItem, baseBranch: String = "main") -> TaskQueue {
        let number = task.number ?? 0
        return TaskQueue(id: TaskQueue.newID(),
                         name: "Issue #\(number)",
                         branch: TaskBranch.issueBranch(number: number, labels: task.labels),
                         baseBranch: baseBranch,
                         taskIds: [],
                         state: .paused,
                         autoCreated: true,
                         autoPR: true,
                         prUrl: nil,
                         createdAt: Date())
    }

    /// The single-task queue a MANUAL task runs in when 全部处理 is asked to run it
    /// on its own: one task, its own branch, its own PR — the same shape an issue
    /// task gets (决策 5), so batching manual work can never silently bundle
    /// unrelated changes onto one branch.
    ///
    /// The branch follows the task's title (`feature/<slug>`), falling back to
    /// `feature/manual-<id4>` when the title has no ASCII slug at all — **unless the
    /// workspace cannot switch branches at all** (`switchesBranch: false`, i.e. the
    /// directory is not a git repository): then the queue has NO branch, exactly like
    /// a queue created from the form there (§V2-7). Handing such a queue a branch is
    /// how 全部处理 made every task fail with tasks.errNotGit.
    ///
    /// Like the issue queue it starts EMPTY: one writer owns membership (enqueue).
    static func auto(forManual task: TaskItem,
                     baseBranch: String = "main",
                     switchesBranch: Bool = true,
                     opensPR: Bool = true) -> TaskQueue {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = TaskBranch.slug(title)
        let derived = slug.isEmpty ? "feature/manual-" + String(task.id.suffix(4)) : "feature/" + slug
        let branch: String? = switchesBranch ? derived : nil
        return TaskQueue(id: TaskQueue.newID(),
                         name: title,
                         branch: branch,
                         baseBranch: baseBranch,
                         taskIds: [],
                         state: .paused,
                         autoCreated: true,
                         autoPR: opensPR,
                         prUrl: nil,
                         createdAt: Date())
    }

    /// 1-based position inside the queue, nil when the task is not in it.
    func order(of taskID: String) -> Int? {
        guard let i = taskIds.firstIndex(of: taskID) else { return nil }
        return i + 1
    }

    func dictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "baseBranch": baseBranch,
            "taskIds": taskIds,
            "state": state.rawValue,
            "autoCreated": autoCreated,
            "autoPR": autoPR,
        ]
        if let branch = branch { d["branch"] = branch }
        if let prUrl = prUrl { d["prUrl"] = prUrl }
        if let prError = prError { d["prError"] = prError }
        if let createdAt = createdAt { d["createdAt"] = TaskItem.iso8601.string(from: createdAt) }
        return d
    }

    static func from(_ d: [String: Any]) -> TaskQueue? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        return TaskQueue(id: id,
                         name: name,
                         branch: d["branch"] as? String,
                         baseBranch: (d["baseBranch"] as? String) ?? "main",
                         taskIds: (d["taskIds"] as? [String]) ?? [],
                         state: QueueState(rawValue: (d["state"] as? String) ?? "paused") ?? .paused,
                         autoCreated: (d["autoCreated"] as? Bool) ?? false,
                         autoPR: (d["autoPR"] as? Bool) ?? false,
                         prUrl: d["prUrl"] as? String,
                         prError: d["prError"] as? String,
                         createdAt: (d["createdAt"] as? String).flatMap { TaskItem.iso8601.date(from: $0) })
    }
}

// MARK: - Machine-scoped overlay (local.json)

/// The part of the board that belongs to THIS machine: the dsh session each
/// task was run in, plus the queue the user last worked on.
struct TaskLocalState: Equatable {
    /// task id -> dsh sessionId.
    var sessions: [String: String] = [:]
    /// task id -> ISO-8601 stamp of the last write for that session, kept so
    /// rewriting the file does not invent new timestamps for old sessions.
    var sessionUpdatedAt: [String: String] = [:]
    /// task id -> the agent's 汇报, written back when the task finished (see
    /// TaskItem.report). Machine-scoped: it is the last text of a local session.
    var reports: [String: String] = [:]
    var activeQueueID: String?
    var runningTaskID: String?

    /// v1 keyed sessions by ISSUE NUMBER ("6"); v2 keys them by task id
    /// ("issue-6"). Reading accepts both and rewrites nothing on load.
    static func taskID(fromStoredKey key: String) -> String {
        let digits = CharacterSet(charactersIn: "0123456789")
        if !key.isEmpty, key.rangeOfCharacter(from: digits.inverted) == nil {
            return TaskItem.githubID(Int(key) ?? 0)
        }
        return key
    }

    static func from(_ d: [String: Any]) -> TaskLocalState {
        var s = TaskLocalState()
        if let raw = d["sessions"] as? [String: Any] {
            for (key, value) in raw {
                guard let entry = value as? [String: Any],
                      let sessionId = entry["sessionId"] as? String else { continue }
                let id = taskID(fromStoredKey: key)
                s.sessions[id] = sessionId
                if let updatedAt = entry["updatedAt"] as? String { s.sessionUpdatedAt[id] = updatedAt }
            }
        }
        if let raw = d["reports"] as? [String: String] {
            for (key, text) in raw where !text.isEmpty { s.reports[taskID(fromStoredKey: key)] = text }
        }
        s.activeQueueID = d["activeQueueId"] as? String
        s.runningTaskID = d["runningTaskId"] as? String
        return s
    }

    func dictionary() -> [String: Any] {
        var out: [String: Any] = [:]
        for (id, sessionId) in sessions {
            out[id] = [
                "sessionId": sessionId,
                "updatedAt": sessionUpdatedAt[id] ?? TaskItem.iso8601.string(from: Date()),
            ]
        }
        var d: [String: Any] = ["sessions": out]
        if !reports.isEmpty { d["reports"] = reports }
        if let activeQueueID = activeQueueID { d["activeQueueId"] = activeQueueID }
        if let runningTaskID = runningTaskID { d["runningTaskId"] = runningTaskID }
        return d
    }
}

// MARK: - Board

/// Tasks plus queues plus the machine overlay, with every rule the panel and
/// the runner share. Pure value type: no timers, no I/O, no AppKit — the runner
/// (step 3) and the UI (step 6) only call into this.
struct TaskBoard {
    var tasks: [TaskItem] = []
    var queues: [TaskQueue] = []
    var local = TaskLocalState()

    // MARK: lookups

    func task(_ id: String) -> TaskItem? { tasks.first { $0.id == id } }

    func queue(_ id: String) -> TaskQueue? { queues.first { $0.id == id } }

    func index(ofTask id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    func index(ofQueue id: String) -> Int? { queues.firstIndex { $0.id == id } }

    /// Tasks that are in no queue at all — the 未入队 area.
    var unqueued: [TaskItem] { tasks.filter { $0.queueId == nil && $0.state != .running } }

    func tasks(inQueue queueID: String) -> [TaskItem] {
        guard let queue = queue(queueID) else { return [] }
        return queue.taskIds.compactMap { task($0) }
    }

    /// The auto (issue-task) queue a task already runs in, if any.
    func autoQueueID(forTask taskID: String) -> String? {
        queues.first { $0.autoCreated && $0.taskIds.contains(taskID) }?.id
    }

    /// The queues offered by 加入队列 ▾. User queues only: an issue task's auto
    /// single-task queue is never a destination for a manual task.
    func queueChoices() -> [QueueChoice] {
        queues.filter { !$0.autoCreated }.map { queue in
            QueueChoice(id: queue.id, name: queue.name, branch: queue.branch,
                        taskCount: queue.taskIds.count, state: queue.state)
        }
    }

    /// Counts for the summary strip: queues, queued, running, failed.
    /// Every queue counts, auto ones included (decision 8).
    /// Counters for the summary card. `source` narrows them to the tasks the list
    /// is currently showing (nil = everything): a filtered list whose header still
    /// counts the hidden half reads as a bug.
    func summary(source: TaskSource? = nil) -> (queues: Int, queued: Int, running: Int, failed: Int) {
        let source = source
        let shown = source.map { wanted in tasks.filter { $0.source == wanted } } ?? tasks
        let shownIDs = Set(shown.map { $0.id })
        // A queue counts when it holds at least one of the shown tasks: the issue
        // task's auto queue disappears with the 手动 filter, exactly like its lane.
        let shownQueues = source == nil ? queues.count
            : queues.filter { queue in queue.taskIds.contains { shownIDs.contains($0) } }.count
        return (shownQueues,
                shown.filter { $0.state == .queued }.count,
                shown.filter { $0.state == .running }.count,
                shown.filter { $0.state == .failed }.count)
    }

    // MARK: queue membership

    /// Append a task to a queue (FIFO). Moving a task that already sits in a
    /// different queue moves it out first. Idempotent for the same queue.
    @discardableResult
    mutating func enqueue(taskID: String, into queueID: String) -> Bool {
        guard let ti = index(ofTask: taskID), index(ofQueue: queueID) != nil else { return false }
        guard tasks[ti].state.isQueueable else { return false }
        if tasks[ti].queueId == queueID { return false }
        if tasks[ti].queueId != nil { _ = dequeue(taskID: taskID) }
        guard let qi = index(ofQueue: queueID) else { return false }
        tasks[ti].state = .queued
        tasks[ti].queueId = queueID
        // One id per queue, ever: the lane renders from taskIds, so a duplicate
        // would draw the same card twice (and inflate progress and every count
        // derived from it).
        if !queues[qi].taskIds.contains(taskID) { queues[qi].taskIds.append(taskID) }
        return true
    }

    /// Take a task out of its queue while it is still waiting — it returns to
    /// the 未入队 area. A running task cannot be dequeued (that is 取消).
    @discardableResult
    mutating func dequeue(taskID: String) -> Bool {
        guard let ti = index(ofTask: taskID), let queueID = tasks[ti].queueId,
              let qi = index(ofQueue: queueID), tasks[ti].state == .queued else { return false }
        queues[qi].taskIds.removeAll { $0 == taskID }
        tasks[ti].queueId = nil
        tasks[ti].state = .pending
        // 分支是队列的属性：离开队列就不再属于它。留着会让人以为这个任务还会跑在
        // 那条分支上（而且它会被当成「这个任务要用的分支」传给下一个队列/提示词）。
        tasks[ti].branch = nil
        return true
    }

    /// Remove a task from every queue regardless of its state — used when the
    /// task itself is deleted. A waiting task goes back to 未入队.
    mutating func detach(taskID: String) {
        for i in queues.indices { queues[i].taskIds.removeAll { $0 == taskID } }
        guard let ti = index(ofTask: taskID) else { return }
        tasks[ti].queueId = nil
        tasks[ti].branch = nil
        if tasks[ti].state == .queued { tasks[ti].state = .pending }
    }

    /// Delete a queue. Tasks that never started go back to 未入队; finished ones
    /// keep their record but lose the membership. Refused while one of its tasks
    /// is running (cancel it first).
    @discardableResult
    mutating func removeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        let ids = queues[qi].taskIds
        if ids.contains(where: { task($0)?.state == .running }) { return false }
        for id in ids {
            guard let ti = index(ofTask: id) else { continue }
            tasks[ti].queueId = nil
            if tasks[ti].state == .queued { tasks[ti].state = .pending }
            // Same rule as 移出队列: the branch belonged to the queue.
            tasks[ti].branch = nil
        }
        queues.remove(at: qi)
        if local.activeQueueID == queueID { local.activeQueueID = nil }
        return true
    }

    /// Create a user queue. A nil branch derives the default from the name; an
    /// explicit empty string means "do not switch branches at all".
    @discardableResult
    mutating func createQueue(name: String,
                              branch: String? = nil,
                              baseBranch: String = "main",
                              autoPR: Bool = false,
                              autoCreated: Bool = false) -> TaskQueue {
        let queueID = TaskQueue.newID()
        let resolved: String?
        if let branch = branch {
            resolved = branch.isEmpty ? nil : branch
        } else {
            resolved = TaskBranch.defaultBranch(queueName: name, queueID: queueID)
        }
        let queue = TaskQueue(id: queueID, name: name, branch: resolved, baseBranch: baseBranch,
                              taskIds: [], state: .paused, autoCreated: autoCreated,
                              autoPR: autoPR, prUrl: nil, createdAt: Date())
        queues.append(queue)
        return queue
    }

    /// The queue the runner works on: the selected one while it is active, else
    /// the first active queue (covers a restart that did not persist the id).
    func activeQueue() -> TaskQueue? {
        if let id = local.activeQueueID, let q = queue(id), q.state == .active { return q }
        return queues.first { $0.state == .active }
    }

    /// The task the runner should start now, or nil. Serial by construction:
    /// while ANY task runs nothing else may start, and only the active queue
    /// contributes. Failed/cancelled/done entries are skipped rather than
    /// blocking the queue (that is what 跳过并继续 means).
    func nextStartable() -> String? {
        if local.runningTaskID != nil { return nil }
        if tasks.contains(where: { $0.state == .running }) { return nil }
        // The queue the user last pointed the runner at wins…
        if let queue = activeQueue(), let id = firstQueued(in: queue) { return id }
        // …but when it has nothing left to start, ANY other active queue with a
        // queued task does. Without this the runner stalled: 全部处理 makes one
        // single-task queue per task, and once the current one emptied, the runner
        // sat there while other lanes showed 活跃 and never moved.
        for queue in queues where queue.state == .active {
            if let id = firstQueued(in: queue) { return id }
        }
        return nil
    }

    /// The first task of a queue that is waiting for its turn.
    private func firstQueued(in queue: TaskQueue) -> String? {
        queue.taskIds.first { task($0)?.state == .queued }
    }

    /// 1-based position of a task inside its queue.
    func order(of taskID: String) -> Int? {
        guard let queueID = task(taskID)?.queueId, let queue = queue(queueID) else { return nil }
        return queue.order(of: taskID)
    }

    // MARK: transitions

    /// Start a task: it becomes the one running task and its queue becomes the
    /// active one. The queue's branch is authoritative, so it is copied onto the
    /// task for display and traceability.
    mutating func markRunning(_ taskID: String, at date: Date = Date()) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .running
        tasks[i].startedAt = date
        tasks[i].error = nil
        if let queueID = tasks[i].queueId, let qi = index(ofQueue: queueID) {
            queues[qi].state = .active
            local.activeQueueID = queueID
            if let branch = queues[qi].branch { tasks[i].branch = branch }
        }
        local.runningTaskID = taskID
    }

    mutating func markDone(_ taskID: String, prUrl: String? = nil, report: String? = nil,
                           at date: Date = Date()) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .done
        tasks[i].finishedAt = date
        if let prUrl = prUrl { tasks[i].prUrl = prUrl }
        recordReport(taskID, report)
        local.runningTaskID = nil
        refreshQueueCompletion()
    }

    /// Write the agent's 汇报 back onto the task (card + local.json), so it is not
    /// locked inside a session log that may be deleted tomorrow. An empty report is
    /// not a report: nothing is written, and a previous one stays.
    mutating func recordReport(_ taskID: String, _ report: String?) {
        guard let text = report?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let i = index(ofTask: taskID) else { return }
        tasks[i].report = text
        local.reports[taskID] = text
    }

    /// Fail a task. A queue containing it is PAUSED and its id returned: inside
    /// a queue every task shares one branch, so running the next one would build
    /// on half-finished work. The user then chooses 重试 or 跳过并继续.
    @discardableResult
    mutating func markFailed(_ taskID: String, error: String, report: String? = nil,
                             at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .failed
        tasks[i].error = error
        tasks[i].finishedAt = date
        // A failed run's last words matter MORE than a successful one's: they say how
        // far it got (the next task in the queue receives them as its 前置汇报).
        recordReport(taskID, report)
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    /// Cancel a task (user-initiated). Cancelling frees the serial slot without
    /// marking the task done, so its queue is paused exactly like a failure.
    @discardableResult
    mutating func markCancelled(_ taskID: String, at date: Date = Date()) -> String? {
        guard let i = index(ofTask: taskID) else { return nil }
        tasks[i].state = .cancelled
        tasks[i].finishedAt = date
        local.runningTaskID = nil
        return pauseQueue(containing: tasks[i])
    }

    /// Close a GitHub task (its issue was closed) — only meaningful for issue
    /// tasks; the record is kept for traceability.
    mutating func markClosed(_ taskID: String) {
        guard let i = index(ofTask: taskID) else { return }
        tasks[i].state = .closed
    }

    /// Record why a queue PR session produced no PR (an L10n key), or clear it once
    /// one did. The queue keeps its own state: a PR that could not be opened is not
    /// failed work, but the reason belongs on the card rather than only in app.log.
    @discardableResult
    mutating func setQueuePRError(_ queueID: String, _ key: String?) -> Bool {
        guard let i = index(ofQueue: queueID) else { return false }
        queues[i].prError = key
        if key != nil { queues[i].prUrl = nil }
        return true
    }

    /// Retry a failed/cancelled task and resume its queue (the card's 重试).
    /// A task with no queue simply returns to 未入队.
    @discardableResult
    mutating func retryAndResume(_ taskID: String) -> Bool {
        guard let i = index(ofTask: taskID), tasks[i].state.isQueueable else { return false }
        tasks[i].error = nil
        tasks[i].finishedAt = nil
        // The old report described the run being retried: it must not be handed to the
        // next task in the queue as if it were this run's outcome.
        tasks[i].report = nil
        local.reports[taskID] = nil
        if let queueID = tasks[i].queueId, let qi = index(ofQueue: queueID) {
            tasks[i].state = .queued
            queues[qi].state = .active
            local.activeQueueID = queueID
        } else {
            tasks[i].state = .pending
        }
        return true
    }

    /// Resume a paused queue without retrying anything (跳过并继续): the runner
    /// walks past the failed entry and takes the next queued task.
    @discardableResult
    mutating func resumeQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        queues[qi].state = .active
        local.activeQueueID = queueID
        return true
    }

    @discardableResult
    mutating func pauseQueue(_ queueID: String) -> Bool {
        guard let qi = index(ofQueue: queueID) else { return false }
        queues[qi].state = .paused
        return true
    }

    /// Mark a queue done when it has no queued/running task left.
    mutating func refreshQueueCompletion() {
        for i in queues.indices {
            let open = queues[i].taskIds.contains { id in
                guard let state = task(id)?.state else { return false }
                return state == .queued || state == .running
            }
            if !open && !queues[i].taskIds.isEmpty && queues[i].state != .done {
                queues[i].state = .done
            }
        }
    }

    /// Pause the queue a task belongs to (only while it is active). Returns the
    /// paused queue's id.
    private mutating func pauseQueue(containing task: TaskItem) -> String? {
        guard let queueID = task.queueId, let qi = index(ofQueue: queueID),
              queues[qi].state == .active else { return nil }
        queues[qi].state = .paused
        return queueID
    }

    // MARK: repair / restart

    /// The queue's taskIds is the source of truth for membership; the per-task
    /// queueId is a denormalized copy. Re-derive it after loading so the two can
    /// never drift apart (and a task listed in a queue but still pending becomes
    /// queued again).
    mutating func reindexQueueMembership() {
        // A duplicated id draws TWO cards in one lane, so the list is cleaned while
        // it is read: every board written before that rule existed (each issue
        // task's auto queue had its id added twice) repairs itself on the next
        // load instead of needing a migration.
        for qi in queues.indices {
            var seen = Set<String>()
            queues[qi].taskIds = queues[qi].taskIds.filter { seen.insert($0).inserted }
        }
        for i in tasks.indices { tasks[i].queueId = nil }
        for queue in queues {
            for id in queue.taskIds {
                guard let ti = index(ofTask: id) else { continue }
                tasks[ti].queueId = queue.id
                if tasks[ti].state == .pending { tasks[ti].state = .queued }
            }
        }
    }

    /// Attach the machine-scoped half of a loaded board: the dsh session each task
    /// ran in, and the 汇报 each one left behind.
    mutating func attachSessions(_ sessions: [String: String], reports: [String: String] = [:]) {
        for i in tasks.indices {
            if let sessionId = sessions[tasks[i].id] { tasks[i].sessionId = sessionId }
            if let report = reports[tasks[i].id] { tasks[i].report = report }
        }
    }

    /// Bring a board loaded from disk in line with reality after a restart: a
    /// task recorded as running cannot still be running (its dsh session died
    /// with the app), and a queue recorded as active is paused so that nothing
    /// starts before the user says so.
    @discardableResult
    mutating func reconcileAfterRestart(interruptedError: String) -> (interrupted: [String], pausedQueues: [String]) {
        var interrupted: [String] = []
        for i in tasks.indices where tasks[i].state == .running {
            tasks[i].state = .failed
            tasks[i].error = interruptedError
            interrupted.append(tasks[i].id)
        }
        var paused: [String] = []
        for i in queues.indices where queues[i].state == .active {
            queues[i].state = .paused
            paused.append(queues[i].id)
        }
        local.runningTaskID = nil
        return (interrupted, paused)
    }
}
