import Foundation

// MARK: - Workspaces tracked at once

/// Everything the panel is tracking at the same time: the workspace it is SHOWING,
/// plus every other workspace whose task is still running.
///
/// The old shape was ONE runner, rebuilt on every workspace change — and rebuilding
/// ran `reconcileAfterRestart`, which marked the task that was running as 失败
/// while its dsh session kept working (and nobody ever updated its card again).
/// 「切走 = 放弃跟踪」 is precisely what a task console cannot do: switching to
/// another project is the normal way to WAIT for a task.
///
/// git is serialised per worktree, so different workspaces run in parallel — that
/// is the point of tracking more than one.
final class TaskWorkspaceRegistry {

    /// Build the runner for a workspace path. `reconcile` is true the FIRST time a
    /// path is seen in this app run: that is when the board has to be brought in
    /// line with reality (after a restart a task recorded as running cannot still
    /// be running). Re-adopting a path we have already seen must NOT reconcile
    /// again — that would fail its in-flight task and pause its queues for nothing.
    typealias Factory = (_ path: String, _ reconcile: Bool) -> TasksRunner?

    private let factory: Factory
    private var runners: [String: TasksRunner] = [:]
    /// Paths whose board has already been reconciled in this app run.
    private var reconciled: Set<String> = []

    private(set) var currentPath: String?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    var currentRunner: TasksRunner? { currentPath.flatMap { runners[$0] } }

    /// Make `path` the workspace the UI shows. Any OTHER runner that is busy stays
    /// alive (it keeps stepping, still finishes, still opens its PR); idle ones are
    /// forgotten — their board is on disk and costs nothing to re-read.
    @discardableResult
    func adopt(_ path: String) -> TasksRunner? {
        currentPath = path
        let runner = runner(for: path)
        prune()
        return runner
    }

    /// Forget which workspace is current (no workspace resolved at all). Busy
    /// runners stay: another workspace's task is not this panel's to drop.
    func clearCurrent() {
        currentPath = nil
    }

    /// The runner already tracked for a path, or nil — this does NOT build one.
    /// (The UI asks this to show "other workspaces are running", and building a
    /// runner just to answer that would read a board off disk for nothing.)
    func trackedRunner(for path: String) -> TasksRunner? { runners[path] }

    /// The runner for a path, built on first use (and reconciled on the very first
    /// build of that path in this app run).
    func runner(for path: String) -> TasksRunner? {
        if let existing = runners[path] { return existing }
        let firstLoad = reconciled.insert(path).inserted
        guard let runner = factory(path, firstLoad) else { return nil }
        runners[path] = runner
        return runner
    }

    /// Forget the runner of `path` so the next `runner(for:)` builds it again with a
    /// fresh environment.
    ///
    /// An env captures facts about the workspace DIRECTORY (is it a git repository?
    /// which base branch? which remote?), and a task can change them: a task literally
    /// called 「初始化 git 仓库」 turns a plain directory into a repository — after which
    /// the runner that was built with `canSwitchBranches = false` can never use a
    /// branch, and the panel keeps saying 非 Git 仓库.
    ///
    /// The path stays in `reconciled`: the board on disk is still this run's board,
    /// and reconciling again would mark an in-flight task as 失败. The caller must only
    /// do this with NOTHING in flight in that workspace — two runners on one board
    /// would step the same task twice.
    func invalidate(_ path: String) {
        runners.removeValue(forKey: path)
    }

    /// Forget every non-current runner with nothing in flight: a workspace is worth
    /// keeping alive exactly while it is working.
    func prune() {
        for (path, runner) in runners where path != currentPath && !runner.isBusy {
            runners.removeValue(forKey: path)
        }
    }

    /// Workspaces with a task in flight right now (the current one included), in a
    /// stable order.
    func busyPaths() -> [String] { runners.filter { $0.value.isBusy }.keys.sorted() }

    var isBusy: Bool { runners.values.contains { $0.isBusy } }

    /// One tick for EVERY tracked workspace. Returns the tasks that just stopped —
    /// with the workspace they belong to — so the shell can say so.
    func step(now: Date = Date()) -> [(path: String, title: String, ok: Bool)] {
        var finished: [(path: String, title: String, ok: Bool)] = []
        for (path, runner) in runners {
            let wasBusy = runner.isBusy
            let runningID = runner.runningTaskID
            _ = runner.step(now: now)
            guard wasBusy, !runner.isBusy, let id = runningID else { continue }
            let task = runner.board.task(id)
            guard let state = task?.state, state == .done || state == .failed else { continue }
            finished.append((path: path, title: task?.title ?? id, ok: state == .done))
        }
        prune()
        return finished.sorted { $0.path < $1.path }
    }
}
