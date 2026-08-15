#!/bin/bash
# Headless unit tests for the Repo Wiki model layer (WikiPanel.swift): frontmatter
# parsing, page scanning, stale detection, backlinks, markdown rendering, paths
# and AGENTS.md registration. No window/panel instantiation, so they run anywhere.
# Usage: tests/wiki-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../src/WikiPanel.swift "$TMP/WikiPanel.swift"
cp wiki-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/wiki-tests" "$TMP/stubs.swift" "$TMP/WikiPanel.swift" "$TMP/main.swift"
"$TMP/wiki-tests"
rm -rf "$TMP"
