import Foundation

// MARK: - Task persistence (.dsh/tasks/)

/// Disk layout under <repoRoot>/.dsh/tasks/ — one file, one job
/// (docs/design/panels/issue-runner-design.md §V2-4):
///
///   index.json   COMMITTED  github task to branch/PR/state, the v1 shape
///   manual.json  local      the user's own tasks
///   queues.json  local      queue definitions and their FIFO order
///   local.json   local      task id to dsh sessionId + last active queue
///
/// Reading is tolerant: a missing or corrupt file yields empty state, and a read
/// never deletes or rewrites anything (a broken file must not cost data).
enum TasksStore {
    static let indexFile = "index.json"
    static let manualFile = "manual.json"
    static let queuesFile = "queues.json"
    static let localFile = "local.json"

    static func tasksDir(_ repoRoot: String) -> String {
        let dir = (repoRoot as NSString).appendingPathComponent(".dsh/tasks")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func path(_ repoRoot: String, file: String) -> String {
        (tasksDir(repoRoot) as NSString).appendingPathComponent(file)
    }

    static func readJSON(_ file: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func writeJSON(_ file: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: file))
    }

    // MARK: - index.json (committed, v1 shape)

    static func indexEntries(_ repoRoot: String) -> [[String: Any]] {
        readJSON(path(repoRoot, file: indexFile))["tasks"] as? [[String: Any]] ?? []
    }

    /// Upsert one issue entry into the committed index, preserving the v1 file
    /// shape (version 1, tasks sorted by issue number).
    static func mergeIssueTask(_ repoRoot: String, issue: Int, update: [String: Any]) {
        var entries = indexEntries(repoRoot)
        var merged: [String: Any] = ["issue": issue]
        if let i = entries.firstIndex(where: { ($0["issue"] as? Int) == issue }) {
            merged = entries[i]
            entries.remove(at: i)
        }
        merged["issue"] = issue
        for (key, value) in update { merged[key] = value }
        entries.append(merged)
        entries.sort { (($0["issue"] as? Int) ?? 0) < (($1["issue"] as? Int) ?? 0) }
        writeJSON(path(repoRoot, file: indexFile), ["version": 1, "tasks": entries])
    }

    /// One committed index entry, or nil.
    static func findIssueTask(_ repoRoot: String, issue: Int) -> [String: Any]? {
        indexEntries(repoRoot).first { ($0["issue"] as? Int) == issue }
    }

    /// Write a whole github task through to the committed index.
    static func saveIssueTask(_ repoRoot: String, _ task: TaskItem) {
        mergeIssueTask(repoRoot, issue: task.number ?? 0, update: task.indexDictionary())
    }

    // MARK: - manual.json / queues.json (machine-scoped)

    static func loadManual(_ repoRoot: String) -> [TaskItem] {
        let entries = readJSON(path(repoRoot, file: manualFile))["tasks"] as? [[String: Any]] ?? []
        return entries.compactMap { TaskItem.fromManual($0) }
    }

    static func saveManual(_ repoRoot: String, _ tasks: [TaskItem]) {
        writeJSON(path(repoRoot, file: manualFile),
                  ["version": 1, "tasks": tasks.map { $0.manualDictionary() }])
    }

    static func loadQueues(_ repoRoot: String) -> [TaskQueue] {
        let entries = readJSON(path(repoRoot, file: queuesFile))["queues"] as? [[String: Any]] ?? []
        return entries.compactMap { TaskQueue.from($0) }
    }

    static func saveQueues(_ repoRoot: String, _ queues: [TaskQueue]) {
        writeJSON(path(repoRoot, file: queuesFile),
                  ["version": 1, "queues": queues.map { $0.dictionary() }])
    }

    // MARK: - local.json (machine-scoped)

    static func loadLocal(_ repoRoot: String) -> TaskLocalState {
        TaskLocalState.from(readJSON(path(repoRoot, file: localFile)))
    }

    static func saveLocal(_ repoRoot: String, _ state: TaskLocalState) {
        writeJSON(path(repoRoot, file: localFile), state.dictionary())
    }

    // MARK: - the whole board

    /// Read all four files into one board, with the sessions overlay applied and
    /// the queue membership re-derived.
    static func load(_ repoRoot: String) -> TaskBoard {
        var board = TaskBoard()
        board.tasks = indexEntries(repoRoot).compactMap { TaskItem.fromIndex($0) }
        board.tasks.append(contentsOf: loadManual(repoRoot))
        board.queues = loadQueues(repoRoot)
        board.local = loadLocal(repoRoot)
        board.attachSessions(board.local.sessions, reports: board.local.reports,
                             markers: board.local.taskMarkers,
                             markerVerified: board.local.taskMarkerVerified)
        board.reindexQueueMembership()
        return board
    }

    /// Persist the machine-scoped half of a board (manual tasks, queues, the
    /// local overlay). The committed index is written per issue task through
    /// mergeIssueTask — never by a bulk save.
    static func saveLocalHalf(_ repoRoot: String, _ board: TaskBoard) {
        saveManual(repoRoot, board.tasks.filter { $0.source == .manual })
        saveQueues(repoRoot, board.queues)
        saveLocal(repoRoot, board.local)
    }
}
