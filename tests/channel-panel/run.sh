#!/bin/bash
# Headless unit tests for the Channel project-view data model (ChannelStoreReader.swift):
# reading the GLOBAL channel-scoped store (sessions + per-session message buckets) that
# core/lib/channel-sessions.js writes. Pure Foundation, no AppKit. Usage: tests/channel-panel/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/ChannelStoreReader.swift "$TMP/ChannelStoreReader.swift"
cp channel-tests.swift "$TMP/main.swift"
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/channel-tests" "$TMP/ChannelStoreReader.swift" "$TMP/main.swift"
"$TMP/channel-tests"
rm -rf "$TMP"