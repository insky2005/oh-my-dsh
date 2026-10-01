#!/bin/bash
# Regression tests for the injected session tracker
# (platforms/macos/src/main.swift: sessionTrackerScript).
#
# Pins both transports: the legacy unary-fetch signals (subagent(s).list etc.)
# and the dsh 0.1.7 WebSocket stream open (session/follow), where the session
# identity moved into a SessionAddress. Usage: tests/session-tracker/run.sh
set -euo pipefail
cd "$(dirname "$0")"
node --test tracker.test.js
