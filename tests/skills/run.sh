#!/bin/bash
# Headless unit tests for the built-in skill installer (SkillInstaller.swift):
# fresh install, update, skip-user-managed, migration, idempotency, and
# byte-identical embedded SKILL.md vs the repo copies. Foundation-only, headless.
# Usage: tests/skills/run.sh
set -euo pipefail
cd "$(dirname "$0")"
# swiftc needs a module-cache; CI clean envs have none, create it first.
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
REPO="$(cd ../.. && pwd)"
TMP="$(mktemp -d)"
cp ../terminal-emulator/stubs.swift "$TMP/stubs.swift"
cp ../../platforms/macos/src/SkillInstaller.swift "$TMP/SkillInstaller.swift"
cp skills-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework AppKit \
  -o "$TMP/skills-tests" "$TMP/stubs.swift" "$TMP/SkillInstaller.swift" "$TMP/main.swift"
# Migration pass on a fresh home.
HOME_M="$TMP/home-migrate"; mkdir -p "$HOME_M"
TEST_MODE=migrate DSH_HOME="$HOME_M" REPO_ROOT="$REPO" "$TMP/skills-tests"
# Install/update/idempotent/skip pass on a fresh home.
HOME_I="$TMP/home-install"; mkdir -p "$HOME_I"
TEST_MODE=install DSH_HOME="$HOME_I" REPO_ROOT="$REPO" "$TMP/skills-tests"
rm -rf "$TMP"
