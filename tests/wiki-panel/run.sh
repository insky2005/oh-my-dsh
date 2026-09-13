#!/bin/bash
# Headless tests for the Repo Wiki panel:
#   1. the model layer (WikiPanel.swift): frontmatter parsing, page scanning,
#      stale detection, backlinks, markdown rendering, paths, AGENTS.md
#      registration — no window/panel instantiation;
#   2. the panel's fixed header title (panel-header-tests.swift): instantiated
#      without scanning any wiki directory.
# Usage: tests/wiki-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
# swiftc 需要 module-cache；CI 干净环境没有 .build/，先建好再 cd。
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- wiki model ---"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/WikiPanel.swift "$TMP/WikiPanel.swift"
# WikiRPC talks to dsh through the shared, version-agnostic helper (DshWebRPC).
cp ../../platforms/macos/src/DshWebRPC.swift "$TMP/DshWebRPC.swift"
cp wiki-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/wiki-tests" "$TMP/stubs.swift" "$TMP/WikiPanel.swift" "$TMP/DshWebRPC.swift" "$TMP/main.swift"
"$TMP/wiki-tests"
rm -rf "$TMP"

echo "--- wiki panel header (fixed title) ---"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/WikiPanel.swift "$TMP/WikiPanel.swift"
cp ../../platforms/macos/src/DshWebRPC.swift "$TMP/DshWebRPC.swift"
cp panel-header-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/wiki-panel-header-tests" "$TMP/stubs.swift" "$TMP/WikiPanel.swift" "$TMP/DshWebRPC.swift" "$TMP/main.swift"
"$TMP/wiki-panel-header-tests"
rm -rf "$TMP"
