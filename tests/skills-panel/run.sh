#!/bin/bash
# Headless tests for the Skills manager panel model layer:
#   SkillsCore.swift   (frontmatter IO / root scanning + levels / store)
#   SkillSources.swift (address parsing / registries / fetch / install / remove)
# Everything runs against a temp fixture home with injected fake transports.
# Usage: tests/skills-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
# swiftc needs a module-cache; CI clean envs have none, create it first.
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/SkillsCore.swift "$TMP/SkillsCore.swift"
cp ../../platforms/macos/src/SkillSources.swift "$TMP/SkillSources.swift"
cp ../../platforms/macos/src/SkillInstaller.swift "$TMP/SkillInstaller.swift"
cp skills-panel-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/skills-panel-tests" "$TMP/stubs.swift" "$TMP/SkillsCore.swift" \
  "$TMP/SkillSources.swift" "$TMP/SkillInstaller.swift" "$TMP/main.swift"
mkdir -p "$TMP/fixture/home"
DSH_HOME="$TMP/fixture/home" DSH_AGENTS_HOME="$TMP/fixture/agents" \
  TEST_ROOT="$TMP/fixture" "$TMP/skills-panel-tests"

echo "--- skills panel controller (headless smoke) ---"
# Separate build dir: top-level code must live in a file named main.swift, and
# the model-layer binary above already owns the outer one.
mkdir -p "$TMP/panel"
cp "$TMP/stubs.swift" "$TMP/SkillsCore.swift" "$TMP/SkillSources.swift" "$TMP/SkillInstaller.swift" "$TMP/panel/"
cp ../../platforms/macos/src/SkillsPanel.swift "$TMP/panel/SkillsPanel.swift"
cp panel-tests.swift "$TMP/panel/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/skills-panel-controller-tests" "$TMP/panel/"*.swift
DSH_HOME="$TMP/fixture/home" DSH_AGENTS_HOME="$TMP/fixture/agents" \
  TEST_ROOT="$TMP/fixture" "$TMP/skills-panel-controller-tests"
rm -rf "$TMP"
