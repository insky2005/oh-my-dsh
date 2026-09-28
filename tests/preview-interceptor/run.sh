#!/bin/bash
# Regression tests for the injected file-open interceptor
# (platforms/macos/src/main.swift: previewInterceptorScript).
#
# Evaluates the real script (extracted from main.swift) against a tiny DOM stub
# covering both dsh generations: the click capture for dsh >= 0.1.5's built-in
# file panel and the legacy host.openPath / session/openWorkspacePath fetch
# interception. Usage: tests/preview-interceptor/run.sh
set -euo pipefail
cd "$(dirname "$0")"
node --test interceptor.test.js
