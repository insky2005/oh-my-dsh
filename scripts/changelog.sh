#!/bin/bash
#
# changelog.sh — generate the "Unreleased" CHANGELOG section from git history
# between the last semver tag and HEAD, grouped by conventional-commit type.
# Prints Markdown to stdout (meant to be reviewed + pasted into CHANGELOG.md).
#
# Usage:
#   scripts/changelog.sh              # from last tag → HEAD
#   scripts/changelog.sh v1.7.1       # from given tag → HEAD
#
set -euo pipefail
cd "$(dirname "$0")/.."

FROM="${1:-$(git tag --list 'v*' | sort -V | tail -1)}"
if [ -z "$FROM" ]; then
  echo "## [Unreleased]" >&2
  git log --oneline --no-merges | sed 's/^/  - /' >&2
  exit 0
fi

RANGE="$FROM..HEAD"
echo "## [Unreleased] (${RANGE})"
echo ""

group() { # group <label> <pattern>
  local label="$1" pattern="$2" count
  count=$(git log --oneline --no-merges --grep="$pattern" -i "$RANGE" | wc -l | tr -d ' ')
  [ "$count" = 0 ] && return
  echo "### $label"
  git log --oneline --no-merges --grep="$pattern" -i "$RANGE" | sed -E 's/^[0-9a-f]+ /- /'
  echo ""
}

group "Added"      "^feat"
group "Fixed"      "^fix"
group "Docs"       "^docs"
group "Build & CI" "^build|^ci|^chore\\((ci|deps|version)\\)"
group "Tests"      "^test"
group "Refactor"   "^refactor|^perf"
group "Other"      "^(chore|style|revert|merge|wip)"
