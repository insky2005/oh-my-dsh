#!/bin/bash
# Headless unit tests for the terminal emulator (TerminalEmulator) — no PTY,
# so they run anywhere (the PTY layer can't be exercised in a dev sandbox that
# blocks /dev/ptmx). Usage: tests/terminal-emulator/run.sh
set -euo pipefail
cd "$(dirname "$0")"
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp stubs.swift "$TMP/stubs.swift"
cp ../../src/TerminalPanel.swift "$TMP/TerminalPanel.swift"
cp emulator-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/term-emu-tests" "$TMP/stubs.swift" "$TMP/TerminalPanel.swift" "$TMP/main.swift"
"$TMP/term-emu-tests"
rm -rf "$TMP"
