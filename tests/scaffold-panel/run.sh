#!/bin/bash
# Headless unit tests for the Scaffold Workbench engine (ScaffoldPanel.swift):
# stage.yaml parsing + bad-manifest isolation, validators, template renderer,
# plan (file list / conflicts / order), applier (write / backup / state.json),
# and end-to-end fixture combos over the built-in 10-stage library.
# The renderer/planner/applier do not touch the panel or the network, so they
# run anywhere. Usage: tests/scaffold-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
# swiftc 需要 module-cache；CI 干净环境没有 .build/，先建好再 cd。
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/ScaffoldPanel.swift "$TMP/ScaffoldPanel.swift"
# 内置环节库（10 环节）拷入临时目录，DSH_SCAFFOLD_STAGES 指向它（追加语义，测试即唯一来源）。
cp -R ../../platforms/macos/scaffold-stages "$TMP/stages"
cp scaffold-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
DSH_SCAFFOLD_STAGES="$TMP/stages" swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/scaffold-tests" "$TMP/stubs.swift" "$TMP/ScaffoldPanel.swift" "$TMP/main.swift"
DSH_SCAFFOLD_STAGES="$TMP/stages" "$TMP/scaffold-tests"
rm -rf "$TMP"
