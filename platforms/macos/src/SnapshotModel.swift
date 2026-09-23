import Foundation

/// SnapshotModel — pure decoding of the `ohmy-core snapshot …` JSON for the
/// shell UI (docs/session-snapshot-rollback-design.md). No AppKit, no I/O, so
/// every rule here is testable headlessly (tests/snapshot-panel/run.sh).
///
/// Shapes decoded:
///   `snapshot list`         -> { snapshots: [...], state, pool, journal }
///   `snapshot status`       -> { state, pool, snapshotCount, journal, mismatch }
///   `snapshot plan-rollback`-> { target, plan: { mode, restore, quarantine, ... } }
enum SnapshotModel {

    // MARK: snapshot list

    /// One row of the snapshot list.
    struct Entry: Equatable {
        let id: String
        let createdAt: String
        let reason: String
        let appVersion: String
        let dshVersion: String
        let forApp: String
        let forDsh: String
        let sessions: Int
        let bytes: Int
        let treeVersion: String?
        /// True when the referenced built-in dsh tree is still in the pool.
        let treeAvailable: Bool
        let broken: Bool
        let restoredFrom: String?

        /// Path B (data + built-in dsh) is possible for this snapshot.
        var canRollbackDsh: Bool { treeVersion == nil || treeAvailable }
        /// Path B would have to install the tree first.
        var needsTreeInstall: Bool { treeVersion != nil && !treeAvailable }
    }

    /// `shell/dsh-state.json` essentials.
    struct State: Equatable {
        let dataApp: String
        let dataDsh: String
        let pinnedDsh: String?
        let rollbackSnapshot: String?
    }

    struct Listing: Equatable {
        let entries: [Entry]
        let state: State?
        let pool: [String]
        let journalStep: String?

        var unfinishedRollback: Bool { journalStep != nil }
    }

    private static func dict(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    private static func arr(_ any: Any?) -> [Any]? { any as? [Any] }
    private static func str(_ any: Any?) -> String? { any as? String }
    private static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// Decode the whole `snapshot list` payload; malformed rows are skipped,
    /// never fatal (a broken snapshot still shows up with `broken = true`).
    static func parseListing(_ json: String) -> Listing? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var entries: [Entry] = []
        for raw in arr(root["snapshots"]) ?? [] {
            guard let d = dict(raw), let id = str(d["id"]) else { continue }
            let from = dict(d["fromCombo"]) ?? [:]
            let forCombo = dict(d["forCombo"]) ?? [:]
            let tree = str(d["dshTree"])
            entries.append(Entry(
                id: id,
                createdAt: str(d["createdAt"]) ?? "",
                reason: str(d["reason"]) ?? (d["broken"] as? Bool == true ? "broken" : "unknown"),
                appVersion: str(from["app"]) ?? "?",
                dshVersion: str(from["dsh"]) ?? "?",
                forApp: str(forCombo["app"]) ?? "?",
                forDsh: str(forCombo["dsh"]) ?? "?",
                sessions: int(d["sessions"]) ?? 0,
                bytes: int(d["bytes"]) ?? 0,
                treeVersion: tree.map { $0.replacingOccurrences(of: "trees/", with: "") },
                treeAvailable: (d["treeAvailable"] as? Bool) ?? false,
                broken: (d["broken"] as? Bool) ?? false,
                restoredFrom: str(d["restoredFrom"])
            ))
        }
        return Listing(entries: entries, state: parseState(root["state"]),
                       pool: (arr(root["pool"]) ?? []).compactMap { $0 as? String },
                       journalStep: str(dict(root["journal"])?["nextStep"]))
    }

    /// Decode `state` (shared by `list` and `status`).
    static func parseState(_ any: Any?) -> State? {
        guard let d = dict(any), let combo = dict(d["dataCombo"]) else { return nil }
        return State(dataApp: str(combo["app"]) ?? "?",
                     dataDsh: str(combo["dsh"]) ?? "?",
                     pinnedDsh: str(dict(d["upgradePinned"])?["dsh"]),
                     rollbackSnapshot: str(dict(d["rollback"])?["snapshot"]))
    }

    // MARK: rollback preview

    /// The parts of `plan-rollback` the confirmation dialog must state.
    struct RollbackSummary: Equatable {
        let mode: String
        let fallbackReason: String?
        let restoreCount: Int
        let addMissingCount: Int
        let quarantineCount: Int
        let dropGenerationCount: Int
        let treeAction: String
        let treeVersion: String?

        var touchesTree: Bool { treeAction == "swap" || treeAction == "install-then-swap" }
        var isDataOnly: Bool { mode == "A" }
    }

    static func parseRollback(_ json: String) -> RollbackSummary? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = dict(root["plan"]) else { return nil }
        let tree = dict(plan["tree"]) ?? [:]
        let drops = arr(plan["dropNewerGeneration"]) ?? []
        return RollbackSummary(
            mode: str(plan["mode"]) ?? "?",
            fallbackReason: str(plan["fallbackReason"]),
            restoreCount: (arr(plan["restore"]) ?? []).count,
            addMissingCount: (arr(plan["addMissing"]) ?? []).count,
            quarantineCount: (arr(plan["quarantine"]) ?? []).count,
            dropGenerationCount: drops.count,
            treeAction: str(tree["action"]) ?? "none",
            treeVersion: str(tree["toVersion"]))
    }

    // MARK: formatting

    /// Human size for the list column.
    static func sizeText(_ bytes: Int) -> String {
        if bytes <= 0 { return "—" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    /// Localised label for a snapshot reason ("pre-rollback" is the undo target).
    static func reasonKey(_ reason: String) -> String { "snapshot.reason.\(reason)" }

    /// Short local time for the list column ("2026-09-23 10:15").
    static func timeText(_ iso: String) -> String {
        guard !iso.isEmpty else { return "—" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d = date else { return iso }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd HH:mm"
        return out.string(from: d)
    }
}
