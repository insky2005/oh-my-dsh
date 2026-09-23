#!/bin/bash
# Headless end-to-end test for the session snapshot / rollback CLI
# (docs/session-snapshot-rollback-design.md): bootstrap -> dsh upgrade ->
# rollback -> relaunch, on a real temp $DSH_HOME with real files. No dsh runs.
# Usage: tests/snapshot-rollback/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

CLI="node core/bin/ohmy-core.js snapshot"
H="$(mktemp -d)"
trap 'rm -rf "$H"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# jget <expr-on-d> : read stdin JSON, print the expression
jget() { node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String($1))"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got [$1], want [$2])"; }

# jfile <expr-on-d> <file> : read a JSON file and print the expression
jfile() { node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.stdout.write(String($1))" "$2"; }

# --- 1) a session from the dsh 0.1.2 era -----------------------------------
mkdir -p "$H/sessions/--w--/session-old" "$H/storages" "$H/runtime/dsh/lib"
echo '{"type":"session","version":0}' > "$H/sessions/--w--/session-old/session.jsonl.zstd"
echo '{"unit":{"name":"workspace","version":2}}' > "$H/storages/workspace.json"
echo '0.1.2-rc.1' > "$H/runtime/dsh/lib/bin.js"

echo "== bootstrap launch"
OUT="$($CLI launch --app-version 1.16.0 --dsh-version 0.1.2-rc.1 --dsh-dir "$H/runtime/dsh" --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.launch.reason')" bootstrap "first launch must bootstrap"
assert_eq "$(echo "$OUT" | jget 'd.tree.action')" cloned "the running tree must be captured"
assert_eq "$(echo "$OUT" | jget 'd.prune.keptTrees.join(",")')" 0.1.2-rc.1 "pool holds the running version"
BOOT="$(echo "$OUT" | jget 'd.snapshotId')"
assert_eq "$(ls "$H/shell/snapshots/$BOOT" | sort | tr '\n' ',')" "meta.json,sessions,storages," "snapshot copies sessions+storages"
[ -e "$H/shell/snapshots/$BOOT/shell" ] && fail "snapshot must not copy shell/ (launch token)"

echo "== relaunch with an unchanged combo"
OUT="$($CLI launch --app-version 1.16.0 --dsh-version 0.1.2-rc.1 --dsh-dir "$H/runtime/dsh" --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.launch.action')" none "unchanged combo must not snapshot"
assert_eq "$(echo "$OUT" | jget 'd.tree.action')" present "tree already in the pool"

# --- 2) install a new app: the dsh tree changes on disk --------------------
rm -rf "$H/runtime/dsh"; mkdir -p "$H/runtime/dsh/lib"; echo '0.1.5-rc.2' > "$H/runtime/dsh/lib/bin.js"

echo "== first launch of the newer dsh (snapshot must happen BEFORE it runs)"
OUT="$($CLI launch --app-version 1.16.2 --dsh-version 0.1.5-rc.2 --dsh-dir "$H/runtime/dsh" --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.launch.reason')" combo-change "a combo change must snapshot"
UP="$(echo "$OUT" | jget 'd.snapshotId')"
assert_eq "$(node core/bin/ohmy-core.js snapshot list --home "$H" | jget "d.snapshots.find(s=>s.id==='$UP').dshTree")" trees/0.1.2-rc.1 "the pre-upgrade snapshot references the OLD tree"

# --- 3) the new dsh migrates the old session and creates a new one ---------
echo '{"type":"session","version":3}' > "$H/sessions/--w--/session-old/session.v3.jsonl.zstd"
mkdir -p "$H/sessions/--w--/session-fresh"
echo '{"type":"session","version":3}' > "$H/sessions/--w--/session-fresh/session.v3.jsonl.zstd"

echo "== rollback plan"
PLAN="$($CLI plan-rollback --id "$UP" --current-dsh 0.1.5-rc.2 --min-supported 0.1.2-rc.1 --home "$H")"
assert_eq "$(echo "$PLAN" | jget 'd.plan.mode')" B "the old tree is pooled, so path B applies"
assert_eq "$(echo "$PLAN" | jget 'd.plan.restore.join(",")')" session-old "only snapshot sessions are restored"
assert_eq "$(echo "$PLAN" | jget 'd.plan.quarantine.join(",")')" session-fresh "post-snapshot sessions are quarantined"
assert_eq "$(echo "$PLAN" | jget 'd.plan.dropNewerGeneration.map(x=>x.id).join(",")')" session-old "the restored session drops its generation-3 log"
assert_eq "$(echo "$PLAN" | jget 'd.plan.tree.action')" swap "the built-in dsh is swapped back"

echo "== rollback (server already stopped by the caller)"
$CLI rollback --id "$UP" --current-app 1.16.2 --current-dsh 0.1.5-rc.2 --dsh-dir "$H/runtime/dsh" --home "$H" >/dev/null 2>&1 \
  && fail "rollback without --server-stopped must be refused"
OUT="$($CLI rollback --id "$UP" --server-stopped --current-app 1.16.2 --current-dsh 0.1.5-rc.2 --dsh-dir "$H/runtime/dsh" --min-supported 0.1.2-rc.1 --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.ok')" true "rollback succeeds"
assert_eq "$(echo "$OUT" | jget 'd.partial')" false "rollback completed without needing a tree install"
assert_eq "$(echo "$OUT" | jget 'd.applied.quarantined.join(",")')" session-fresh "the new session was quarantined"

echo "== verify the rolled-back home"
assert_eq "$(cat "$H/runtime/dsh/lib/bin.js")" 0.1.2-rc.1 "built-in dsh is the old version again"
assert_eq "$(ls "$H/sessions/--w--/session-old" | tr '\n' ',')" "session.jsonl.zstd," "the old session is generation 0 again"
[ -e "$H/sessions/--w--/session-fresh" ] && fail "the new session must no longer be in sessions/"
QDIR="$(ls -d "$H/shell/snapshots/quarantine/"*/ | head -1)"
assert_eq "$(jfile 'd.sessions.map(s=>s.id).join(",")' "${QDIR}quarantine.json")" session-fresh "quarantine carries a manifest"
[ -e "${QDIR}sessions/--w--/session-fresh/session.v3.jsonl.zstd" ] || fail "quarantined files must be kept"
assert_eq "$(jfile "[d.dataCombo.app,d.dataCombo.dsh,d.upgradePinned.dsh].join('/')" "$H/shell/dsh-state.json")" "1.16.0/0.1.2-rc.1/0.1.2-rc.1" "state points at the old combo and pins auto-upgrade"
[ -e "$H/shell/rollback-journal.json" ] && fail "the journal must be cleared after a completed rollback"
ls -d "$H/shell/snapshots/"*_pre-rollback >/dev/null || fail "the live state must be parked as a pre-rollback snapshot"
[ -e "$H/shell/snapshots/"*_pre-rollback/sessions/--w--/session-fresh/session.v3.jsonl.zstd ] || fail "the parked state keeps the post-snapshot work"

echo "== relaunch after the rollback"
OUT="$($CLI launch --app-version 1.16.0 --dsh-version 0.1.2-rc.1 --dsh-dir "$H/runtime/dsh" --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.launch.action')" none "after reinstalling the old app the combo matches again"
assert_eq "$(echo "$OUT" | jget 'd.mismatch')" false "data and tree agree"

echo "== path A: a dsh below the compatibility floor may not swap the tree"
PLAN="$($CLI plan-rollback --id "$UP" --current-dsh 0.1.5-rc.2 --min-supported 0.1.5-rc.2 --home "$H")"
assert_eq "$(echo "$PLAN" | jget 'd.plan.mode')" A "below-min-supported falls back to data-only"
assert_eq "$(echo "$PLAN" | jget 'd.plan.tree.action')" none "path A never touches the tree"

echo "== in-app dsh upgrade: snapshot before, adopt after (no double snapshot)"
UP2="$($CLI create --reason dsh-upgrade --app-version 1.16.2 --dsh-version 0.9.9 \
  --from-app 1.16.0 --from-dsh 0.1.2-rc.1 --dsh-dir "$H/runtime/dsh" --home "$H")"
assert_eq "$(echo "$UP2" | jget 'd.id.endsWith("_dsh-upgrade")')" true "the pre-upgrade snapshot is tagged dsh-upgrade"
assert_eq "$(echo "$UP2" | jget 'd.meta.dshTree')" trees/0.1.2-rc.1 "it references the outgoing tree"
assert_eq "$(echo "$UP2" | jget 'd.meta.fromCombo.dsh + "->" + d.meta.forCombo.dsh')" "0.1.2-rc.1->0.9.9" "from/for combos are recorded"

OUT="$($CLI launch --app-version 1.16.2 --dsh-version 0.9.9 --dsh-dir "$H/runtime/dsh" --no-snapshot --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.snapshotId === null')" true "--no-snapshot takes no second snapshot"
assert_eq "$(echo "$OUT" | jget 'd.state.dataCombo.dsh')" 0.9.9 "--no-snapshot still adopts the new combo"
OUT="$($CLI launch --app-version 1.16.2 --dsh-version 0.9.9 --dsh-dir "$H/runtime/dsh" --home "$H")"
assert_eq "$(echo "$OUT" | jget 'd.launch.action')" none "the next launch sees an unchanged combo"


# --- jump-version case: the pool never captured the outgoing tree -----------

echo "== path B with a missing tree: install it, then finish the rollback"
H2="$(mktemp -d)"
mkdir -p "$H2/sessions/--w--/s-old" "$H2/storages" "$H2/runtime/dsh/lib"
echo '{"type":"session","version":0}' > "$H2/sessions/--w--/s-old/session.jsonl.zstd"
echo '{}' > "$H2/storages/workspace.json"
echo 0.1.2-rc.1 > "$H2/runtime/dsh/lib/bin.js"
$CLI launch --app-version 1.16.0 --dsh-version 0.1.2-rc.1 --dsh-dir "$H2/runtime/dsh" --home "$H2" >/dev/null
# a newer app arrives with a newer dsh, and the pre-upgrade snapshot is taken
rm -rf "$H2/runtime/dsh"; mkdir -p "$H2/runtime/dsh/lib"; echo 0.1.5-rc.2 > "$H2/runtime/dsh/lib/bin.js"
UP3="$($CLI launch --app-version 1.16.2 --dsh-version 0.1.5-rc.2 --dsh-dir "$H2/runtime/dsh" --home "$H2")"
ID3="$(echo "$UP3" | jget 'd.snapshotId')"
# the user jumped versions: the pool never got the old tree
rm -rf "$H2/shell/snapshots/trees/0.1.2-rc.1"
PLAN="$($CLI plan-rollback --id "$ID3" --current-dsh 0.1.5-rc.2 --min-supported 0.1.2-rc.1 --home "$H2")"
assert_eq "$(echo "$PLAN" | jget 'd.plan.tree.action')" install-then-swap "a missing tree asks for an install"
PARTIAL="$($CLI rollback --id "$ID3" --server-stopped --current-app 1.16.2 --current-dsh 0.1.5-rc.2 --dsh-dir "$H2/runtime/dsh" --min-supported 0.1.2-rc.1 --home "$H2")"
assert_eq "$(echo "$PARTIAL" | jget 'd.partial')" true "the data half completes and the tree half waits"
assert_eq "$(echo "$PARTIAL" | jget 'd.needsTreeInstall')" 0.1.2-rc.1 "the shell is told which version to fetch"
[ -e "$H2/shell/rollback-journal.json" ] || fail "an unfinished rollback must leave its journal"
# the shell npm-installs that version into the pool, then asks to finish
mkdir -p "$H2/shell/snapshots/trees/0.1.2-rc.1"
echo 0.1.2-rc.1 > "$H2/shell/snapshots/trees/0.1.2-rc.1/version"
FIN="$($CLI finish-rollback --id "$ID3" --current-app 1.16.2 --current-dsh 0.1.5-rc.2 --dsh-dir "$H2/runtime/dsh" --home "$H2")"
assert_eq "$(echo "$FIN" | jget 'd.ok')" true "finish-rollback completes the transaction"
assert_eq "$(cat "$H2/runtime/dsh/version" 2>/dev/null || echo missing)" 0.1.2-rc.1 "the built-in dsh is the pooled one"
[ -e "$H2/shell/rollback-journal.json" ] && fail "the journal must be cleared once finished"
assert_eq "$(jfile 'd.dataCombo.dsh' "$H2/shell/dsh-state.json")" 0.1.2-rc.1 "the data combo is restored"
assert_eq "$(jfile 'd.upgradePinned.dsh' "$H2/shell/dsh-state.json")" 0.1.2-rc.1 "auto-upgrade stays pinned"
rm -rf "$H2"

echo "all snapshot-rollback checks passed"