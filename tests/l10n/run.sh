#!/bin/bash
# L10n key lint for the macOS shell: every L10n.tr("…") literal used by the
# Swift sources must exist in L10n.table (a missing key renders as the raw key —
# a "preview.switchDiscard" button shipped once), keys must be unique, and each
# entry must carry both its Chinese and English string (AGENTS.md: 文案中英成对).
# Usage: tests/l10n/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root
python3 tests/l10n/lint.py platforms/macos/src
