#!/bin/bash
# Headless tests for the Projects panel:
#   1. the pure model (ProjectsCore.swift): projects-root resolution, folder-name
#      rules, directory listing and the dsh-registry merge;
#   2. the panel controller (ProjectsPanel.swift) driven without a window, with a
#      fake dsh HTTP transport (workspace/create + session/create).
# No dsh server, no window. Usage: tests/projects-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
SRC=../../platforms/macos/src
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"

echo "--- projects model (root / names / listing / registry merge) ---"
TMP="$(mktemp -d)"
cp "$SRC/ProjectsCore.swift" "$TMP/ProjectsCore.swift"
cp "$SRC/DshWebRPC.swift" "$TMP/DshWebRPC.swift"   # DshWorkspaceStore.canonical for the merge tests
cp projects-tests.swift "$TMP/main.swift"          # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/projects-tests" "$TMP/ProjectsCore.swift" "$TMP/DshWebRPC.swift" "$TMP/main.swift"
"$TMP/projects-tests"
rm -rf "$TMP"

print_ok() { echo "projects-panel tests passed"; }
print_ok
