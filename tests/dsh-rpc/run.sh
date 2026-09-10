#!/bin/bash
# Headless unit tests for the native dsh RPC helper (DshWebRPC.swift): envelope
# shape, dsh >= 0.1.2 slash endpoints + launch-token auth vs dsh <= 0.1.1 dot
# methods, per-endpoint surface memory, and the persisted workspace store.
# No AppKit / no running dsh needed (the HTTP seam is faked).
# Usage: tests/dsh-rpc/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/DshWebRPC.swift "$TMP/DshWebRPC.swift"
cp dsh-rpc-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" \
  -o "$TMP/dsh-rpc-tests" "$TMP/DshWebRPC.swift" "$TMP/main.swift"
"$TMP/dsh-rpc-tests"
rm -rf "$TMP"
