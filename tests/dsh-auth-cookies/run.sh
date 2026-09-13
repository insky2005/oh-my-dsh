#!/bin/bash
# Headless unit tests for DshWebCookieJanitor: dsh's cookie-name derivation
# ("dsh-auth-" + base64url(sha256(authority))), which cookies the startup and
# exit purges delete, and the node header-cap seatbelt. Pure logic — no AppKit,
# no WebKit data store, no running dsh.
# Usage: tests/dsh-auth-cookies/run.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../../.build/module-cache
CACHE="$(cd ../../.build/module-cache && pwd)"
TMP="$(mktemp -d)"
cp ../../platforms/macos/src/DshWebCookieJanitor.swift "$TMP/DshWebCookieJanitor.swift"
cp dsh-auth-cookies-tests.swift "$TMP/main.swift"   # top-level code needs the main.swift name
swiftc -swift-version 5 -module-cache-path "$CACHE" -framework WebKit \
  -o "$TMP/dsh-auth-cookies-tests" "$TMP/DshWebCookieJanitor.swift" "$TMP/main.swift"
"$TMP/dsh-auth-cookies-tests"
rm -rf "$TMP"
