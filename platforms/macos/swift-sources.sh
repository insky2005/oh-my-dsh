#!/bin/bash
# Single source of truth for the macOS app Swift source list.
#
# Consumed by:
#   - platforms/macos/build-app.sh        (production build)
#   - scripts/local-ci.sh                 (local CI swiftc compile check)
#   - .github/workflows/ci.yml            (GitHub CI swiftc compile check)
#
# Adding a new app Swift file to src/ is picked up AUTOMATICALLY (glob) — there
# is no per-file list to edit, so build / local CI / GitHub CI can never drift.
#
# MakeIcon.swift is intentionally EXCLUDED: it is a standalone icon-rendering
# tool with top-level code (not named main.swift), NOT part of the app target.
#
# Usage: swift_sources <src_dir>   -> prints one source file path per line.
swift_sources() {
    local src="$1"
    local f
    for f in "$src"/*.swift "$src"/vendor/Highlightr/*.swift; do
        [ -e "$f" ] || continue
        [[ "$(basename "$f")" == "MakeIcon.swift" ]] && continue
        printf '%s\n' "$f"
    done
}
