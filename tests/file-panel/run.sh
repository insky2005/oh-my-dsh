#!/bin/bash
# Headless tests for the Files panel (FilePanel.swift / CodeEditorView.swift):
#   1. WorkspaceTabMemory model — the per-workspace "which tabs were open" store;
#   2. the real FilePanelController driven through workspace switches, the Close
#      action and folder/file tabs (no window, no dsh server).
# AppKit views are instantiated without a run loop; Highlightr's bundle assets
# are absent in the test binary, so editors degrade to plain text (by design).
# Usage: tests/file-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"                 # tests/file-panel
SRC="../../platforms/macos/src"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- workspace tab memory (model) ---"
TMP="$(mktemp -d)"
cp "$SRC/WorkspaceTabMemory.swift" "$TMP/WorkspaceTabMemory.swift"
cp workspace-tab-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/workspace-tab-tests" "$TMP/WorkspaceTabMemory.swift" "$TMP/main.swift"
"$TMP/workspace-tab-tests"
rm -rf "$TMP"

echo "--- file panel workspace hand-off (panel) ---"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"   # L10n/AppLog/ShellConfig/共享 UI 基件
cp "$SRC/FilePanel.swift" "$TMP/FilePanel.swift"
cp "$SRC/CodeEditorView.swift" "$TMP/CodeEditorView.swift"
cp "$SRC/WorkspaceTabMemory.swift" "$TMP/WorkspaceTabMemory.swift"
cp "$SRC"/vendor/Highlightr/*.swift "$TMP/"
cp panel-switch-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -framework AppKit -framework PDFKit -framework JavaScriptCore \
  -o "$TMP/panel-switch-tests" \
  "$TMP/stubs.swift" "$TMP/FilePanel.swift" "$TMP/CodeEditorView.swift" \
  "$TMP/WorkspaceTabMemory.swift" "$TMP"/Highlightr.swift "$TMP"/CodeAttributedString.swift \
  "$TMP"/Theme.swift "$TMP"/HTMLUtils.swift "$TMP"/Shims.swift "$TMP/main.swift"
"$TMP/panel-switch-tests"
rm -rf "$TMP"
