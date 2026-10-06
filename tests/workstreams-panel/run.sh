#!/bin/bash
# Headless tests for the Workstreams panel:
#   1. the pure model (WorkstreamsCore.swift): frontmatter parsing, the five
#      stages, queues [{id, stage}], covered / delivery blocks, validation, and
#      create / update / stage / queues writes with atomic rename + six-digit ids.
#   2. the localhost API router (WorkstreamsAPI.swift): routing, validation, error
#      codes and response shapes (no AppKit, no disk).
#   3. the pure view models (WorkstreamsUI.swift): the three-level card model,
#      the top stage filter and the empty state.
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

echo "--- workstreams UI models (three-level card / stage filter / empty state) ---"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/WorkstreamsCore.swift "$TMP/WorkstreamsCore.swift"
cp ../../platforms/macos/src/WorkstreamsUI.swift "$TMP/WorkstreamsUI.swift"
cp ui-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/ui-tests" "$TMP/WorkstreamsCore.swift" "$TMP/WorkstreamsUI.swift" "$TMP/main.swift"
"$TMP/ui-tests"
rm -rf "$TMP"


echo "--- view base namespace guard (WSCardView / WSInlineForms / WorkstreamsPanel, design A6) ---"
SRC2="../../platforms/macos/src"
# The workstream panel must NOT reference the tasks panel's view widgets: its
# copies live under the WS* names. The pattern is word-bounded so WSRepoPRButton /
# WSQueueComposerView do not count as RepoPRButton / QueueComposerView.
FORBIDDEN='TaskInk|taskRowGlyph|TaskBadgeView|TaskProgressBarView|TaskSectionHeaderView|TaskSummaryCardView|TaskCardView|RepoPRButton|RepoRetryButton|TaskQueueHeaderView|TaskQueueBlockView|TaskFormCardView|TaskFieldBox|TaskFormKit|TaskComposerView|QueueComposerView|TaskSettingsModel|TaskSettingsRepoModel|TaskSettingsView|TasksHelpTextView|TasksHelpView|TaskFormSheetView|TaskFormSheetHostView'
if grep -nE "\b(${FORBIDDEN})\b" "$SRC2/WSCardView.swift" "$SRC2/WSInlineForms.swift" "$SRC2/WorkstreamsPanel.swift"; then
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

echo "--- workstreams panel surface guard (PanelSurface / PanelControl, no new token) ---"
SRC3="../../platforms/macos/src"
if ! grep -q 'PanelSurface' "$SRC3/WorkstreamsPanel.swift" || ! grep -q 'PanelControl' "$SRC3/WorkstreamsPanel.swift"; then
  echo "FAIL: WorkstreamsPanel.swift must paint with the shared PanelSurface / PanelControl tokens" >&2
  exit 1
fi
# A new color token would be a 'static let ...: NSColor'; the panel may only use
# the shared tokens (WSInk / PanelSurface / PanelControl / system colors).
if grep -nE 'static let (dark|light)[A-Za-z]* *: *NSColor' "$SRC3/WorkstreamsPanel.swift"; then
  echo "FAIL: WorkstreamsPanel.swift defines a new color token" >&2
  exit 1
fi
echo "workstreams panel surface guard: PanelSurface + PanelControl ok"

echo "--- main.swift wiring guard (entry points) ---"
# The panel entry wiring is AppKit main.swift (no headless unit test), so freeze
# it with a source guard: RightPanel.workstreams, the activity-bar slot right
# after 需求池, the ⌥⌘K toggle (view menu + shortcut list), the L10n keys, the
# panel instance, and the /api/workstreams/* bridge landing. See design A5 / A11.
MAIN="$SRC3/main.swift"
wiring_check() {
  if ! grep -qE "$1" "$MAIN"; then
    echo "FAIL: main.swift missing $2" >&2
    exit 1
  fi
}
wiring_check 'enum RightPanel \{[^}]*\bworkstreams\b' 'RightPanel.workstreams'
wiring_check 'requirementsBarButton, workstreamsBarButton' 'activity-bar slot immediately after 需求池'
wiring_check 'workstreamsEntryTapped' 'the workstreams toggle handler'
wiring_check 'keyEquivalent: "k"' 'the ⌥⌘K view-menu shortcut'
wiring_check 'menu\.toggleWorkstreams' 'the view-menu L10n key'
wiring_check 'bar\.workstreams' 'the activity-bar L10n key'
wiring_check '\("menu\.toggleWorkstreams", "⌥⌘K"\)' 'the Settings shortcut-list row'
wiring_check 'workstreamsPanel = WorkstreamsPanelController\(\)' 'the panel instance'
wiring_check 'workstreamsPanel\.workspaceProvider' 'the workspace provider wiring'
wiring_check 'bridge\.workstreamsList' 'the /api/workstreams/list bridge landing'
wiring_check 'bridge\.workstreamsQueues' 'the /api/workstreams/queues bridge landing'
echo "main.swift wiring guard ok"

echo "workstreams-panel tests passed"
