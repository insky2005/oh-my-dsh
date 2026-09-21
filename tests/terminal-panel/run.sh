#!/bin/bash
# Headless tests for the terminal panel's header (TerminalPanel.swift).
# No PTY is opened: the controller is instantiated and only its header state is
# asserted (session paths are covered by the manual pass in .dsh/wiki/tasks.md).
# Usage: tests/terminal-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"                 # tests/terminal-panel
SRC="../../platforms/macos/src"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"   # L10n/AppLog/ShellConfig/共享 UI 基件
cp "$SRC/TerminalPanel.swift" "$TMP/TerminalPanel.swift"
cp "$SRC/PanelSurface.swift" "$TMP/PanelSurface.swift"   # 面板底色 token（#1B1B1C / #F9FAFB）
cp panel-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -framework AppKit -framework PDFKit \
  -o "$TMP/terminal-panel-tests" "$TMP/stubs.swift" "$TMP/PanelSurface.swift" \
  "$TMP/TerminalPanel.swift" "$TMP/main.swift"
"$TMP/terminal-panel-tests"
rm -rf "$TMP"
