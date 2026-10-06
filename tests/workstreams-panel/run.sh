#!/bin/bash
# Headless tests for the Workstreams panel:
#   1. the pure model (WorkstreamsCore.swift): frontmatter parsing, the five
#      stages, queues [{id, stage}], covered / delivery blocks, validation, and
#      create / update / stage / queues writes with atomic rename + six-digit ids.
#   2. the localhost API router (WorkstreamsAPI.swift): routing, validation, error
#      codes and response shapes (no AppKit, no disk).
# No AppKit, no dsh server, no window. Usage: tests/workstreams-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- workstreams model (frontmatter / stages / queues / writes) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp model-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/model-tests" "$TMP/WorkstreamsCore.swift" "$TMP/main.swift"
"$TMP/model-tests"
rm -rf "$TMP"

echo "--- workstreams API (routing / validation / error codes) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsAPI.swift "$TMP/WorkstreamsAPI.swift"
cp api-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/api-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsAPI.swift" "$TMP/main.swift"
"$TMP/api-tests"
rm -rf "$TMP"


echo "--- view base namespace guard (WSCardView / WSInlineForms, design A6) ---"
SRC2="../../platforms/macos/src"
# The workstream panel must NOT reference the tasks panel's view widgets: its
# copies live under the WS* names. The pattern is word-bounded so WSRepoPRButton /
# WSQueueComposerView do not count as RepoPRButton / QueueComposerView.
FORBIDDEN='TaskInk|taskRowGlyph|TaskBadgeView|TaskProgressBarView|TaskSectionHeaderView|TaskSummaryCardView|TaskCardView|RepoPRButton|RepoRetryButton|TaskQueueHeaderView|TaskQueueBlockView|TaskFormCardView|TaskFieldBox|TaskFormKit|TaskComposerView|QueueComposerView|TaskSettingsModel|TaskSettingsRepoModel|TaskSettingsView|TasksHelpTextView|TasksHelpView|TaskFormSheetView|TaskFormSheetHostView'
if grep -nE "\b(${FORBIDDEN})\b" "$SRC2/WSCardView.swift" "$SRC2/WSInlineForms.swift"; then
  echo "FAIL: WS view files still reference tasks-panel view symbols" >&2
  exit 1
fi
# ...and it must actually define its own copies.
for sym in WSCardView WSBadgeView WSProgressBarView WSQueueHeaderView WSQueueBlockView WSFormCardView WSFormKit WSComposerView WSQueueComposerView WSFormSheetHostView; do
  if ! grep -qE "\b(class|struct|enum) $sym\b" "$SRC2/WSCardView.swift" "$SRC2/WSInlineForms.swift"; then
    echo "FAIL: $sym is not defined in the WS view files" >&2
    exit 1
  fi
done
echo "view base namespace guard: $(for s in WSCardView WSBadgeView WSComposerView WSFormSheetHostView; do printf "%s " "$s"; done)ok"

echo "workstreams-panel tests passed"
