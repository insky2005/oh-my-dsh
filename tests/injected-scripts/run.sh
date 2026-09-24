#!/bin/bash
# Guards the JavaScript the shell injects into dsh web (see check.py): the scripts
# must parse, every window.__dshX the Swift side names must be assigned by one of
# them, and no script may rely on a backslash escape (Swift eats it).
# No dsh server, no window, no Swift build. Usage: tests/injected-scripts/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root
python3 tests/injected-scripts/check.py platforms/macos/src
