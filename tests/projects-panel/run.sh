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

echo "--- projects panel controller (headless: create / list / quick entries / root change) ---"
# Separate build dir: top-level code must live in a file named main.swift, and the
# model binary above already owns the outer one.
TMP="$(mktemp -d)"
cp stubs.swift "$TMP/stubs.swift"
cp "$SRC/PanelSurface.swift" "$TMP/PanelSurface.swift"   # panel surface / control tokens
cp "$SRC/ProjectsCore.swift" "$TMP/ProjectsCore.swift"
cp "$SRC/ProjectsPanel.swift" "$TMP/ProjectsPanel.swift"
cp "$SRC/ShellConfig.swift" "$TMP/ShellConfig.swift"     # the root setting is real
cp "$SRC/DshWebRPC.swift" "$TMP/DshWebRPC.swift"         # the RPC layer is real (fake transport)
cp controller-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/projects-controller-tests" "$TMP/"*.swift
"$TMP/projects-controller-tests"
rm -rf "$TMP"

echo "projects-panel tests passed"
