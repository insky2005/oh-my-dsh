#!/bin/bash
# Terminal emulator tests now live in the shared core (core/tests/ansi.test.js).
set -euo pipefail
cd "$(dirname "$0")/../.."
node --test core/tests/ansi.test.js
