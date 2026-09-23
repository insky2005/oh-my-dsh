import Foundation

// Headless unit tests for the snapshot UI data model (SnapshotModel.swift):
// decoding the `ohmy-core snapshot …` JSON. Pure Foundation, no AppKit, no Node
// — the CLI itself is covered by tests/snapshot-rollback/run.sh.

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

// --- fixture: the exact shape `snapshot list` emits ---

let listJSON = """
{
  "snapshots": [
    {"id": "20260923-101500_app1.16.0_dsh0.1.2-rc.1_bootstrap", "broken": false,
     "createdAt": "2026-09-23T10:15:00.000Z", "sessions": 246, "bytes": 322122547,
     "reason": "bootstrap", "fromCombo": {"app": "1.16.0", "dsh": "0.1.2-rc.1"},
     "forCombo": {"app": "1.16.2", "dsh": "0.1.2-rc.1"}, "dshTree": null,
     "treeAvailable": false, "restoredFrom": null},
    {"id": "20260923-120000_app1.16.2_dsh0.1.5-rc.2_dsh-upgrade", "broken": false,
     "createdAt": "2026-09-23T12:00:00.000Z", "sessions": 250, "bytes": 1073741824,
     "reason": "dsh-upgrade", "fromCombo": {"app": "1.16.2", "dsh": "0.1.2-rc.1"},
     "forCombo": {"app": "1.16.2", "dsh": "0.1.5-rc.2"}, "dshTree": "trees/0.1.2-rc.1",
     "treeAvailable": true, "restoredFrom": null},
    {"id": "20260923-130000_app1.16.2_dsh0.1.5-rc.2_pre-rollback", "broken": false,
     "createdAt": "2026-09-23T13:00:00.000Z", "sessions": 252, "bytes": 2097152,
     "reason": "pre-rollback", "fromCombo": {"app": "1.16.2", "dsh": "0.1.5-rc.2"},
     "forCombo": {"app": "1.16.0", "dsh": "0.1.2-rc.1"}, "dshTree": "trees/0.1.5-rc.2",
     "treeAvailable": false, "restoredFrom": null},
    {"id": "broken_snapshot_dir", "broken": true, "createdAt": null, "sessions": 0, "bytes": 0}
  ],
  "state": {"version": 1, "dataCombo": {"app": "1.16.2", "dsh": "0.1.2-rc.1"},
            "upgradePinned": {"dsh": "0.1.2-rc.1"}, "rollback": {"snapshot": "20260923-120000_app1.16.2_dsh0.1.5-rc.2_dsh-upgrade"}},
  "pool": ["0.1.2-rc.1", "0.1.5-rc.2"],
  "journal": {"status": "in-progress", "nextStep": "swap-tree", "canUndo": true, "canComplete": true}
}
"""

guard let listing = SnapshotModel.parseListing(listJSON) else { exit(1) }

test("listing decodes every row", listing.entries.count == 4)
test("a data-only snapshot needs no tree", listing.entries[0].treeVersion == nil)
test("a data-only snapshot is always rollbackable", listing.entries[0].canRollbackDsh)
test("a pooled tree is rollbackable", listing.entries[1].treeVersion == "0.1.2-rc.1"
     && listing.entries[1].treeAvailable && listing.entries[1].canRollbackDsh)
test("a missing tree asks for an install first", listing.entries[2].needsTreeInstall
     && !listing.entries[2].canRollbackDsh)
test("a broken row stays visible", listing.entries[3].broken && listing.entries[3].reason == "broken")
test("the state carries the data combo and the pin", listing.state?.dataDsh == "0.1.2-rc.1"
     && listing.state?.pinnedDsh == "0.1.2-rc.1"
     && listing.state?.rollbackSnapshot == "20260923-120000_app1.16.2_dsh0.1.5-rc.2_dsh-upgrade")
test("the pool lists both versions", listing.pool == ["0.1.2-rc.1", "0.1.5-rc.2"])
test("an unfinished journal is surfaced", listing.unfinishedRollback && listing.journalStep == "swap-tree")

// --- fixture: `snapshot plan-rollback` ---

let planJSON = """
{"ok": true, "target": {"id": "x", "meta": {}},
 "plan": {"mode": "B", "fallbackReason": null,
          "restore": ["session-a", "session-b"], "addMissing": [], "quarantine": ["session-c"],
          "dropNewerGeneration": [{"id": "session-a", "files": ["session.v3.jsonl.zstd"]}],
          "tree": {"action": "swap", "toVersion": "0.1.2-rc.1", "fromVersion": "0.1.5-rc.2"},
          "state": {"dataCombo": {"app": "1.16.2", "dsh": "0.1.2-rc.1"}, "pinDsh": "0.1.2-rc.1"}},
 "pool": ["0.1.2-rc.1"]}
"""

guard let plan = SnapshotModel.parseRollback(planJSON) else { exit(1) }
test("plan decodes mode and counts", plan.mode == "B" && plan.restoreCount == 2 && plan.quarantineCount == 1)
test("plan reports the generation files it will drop", plan.dropGenerationCount == 1)
test("plan reports the tree swap", plan.touchesTree && plan.treeVersion == "0.1.2-rc.1" && !plan.isDataOnly)

let pathAJSON = """
{"ok": true, "plan": {"mode": "A", "fallbackReason": "below-min-supported",
   "restore": [], "addMissing": [], "quarantine": [], "dropNewerGeneration": [], "tree": {"action": "none"}}}
"""
guard let pathA = SnapshotModel.parseRollback(pathAJSON) else { exit(1) }
test("path A never touches the tree", pathA.isDataOnly && !pathA.touchesTree
     && pathA.fallbackReason == "below-min-supported")

// --- formatting + robustness ---

test("sizes are human readable", SnapshotModel.sizeText(0) == "—"
     && SnapshotModel.sizeText(512) == "512 B"
     && SnapshotModel.sizeText(322122547) == "307.2 MB"
     && SnapshotModel.sizeText(1073741824) == "1.0 GB")
test("reason keys are localisable", SnapshotModel.reasonKey("pre-rollback") == "snapshot.reason.pre-rollback")
test("ISO timestamps become short local text", SnapshotModel.timeText("2026-09-23T10:15:00.000Z").count == 16)
test("an empty timestamp degrades to a dash", SnapshotModel.timeText("") == "—")
test("malformed payloads decode to nil, never crash", SnapshotModel.parseListing("not json") == nil
     && SnapshotModel.parseRollback("{}") == nil)

print("all snapshot model checks passed")
