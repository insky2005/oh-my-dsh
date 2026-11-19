#!/bin/bash
# Headless tests for the terminal-state derivation (.dsh/tools/derive-status.mjs):
# accepted / terminal / requirementClosed, including the two negative cases
# (not accepted + merged -> not closed; accepted + open -> not closed).
# No dsh server, no GitHub network. Usage: tests/derive-status/run.sh
set -euo pipefail
cd "$(dirname "$0")"
node --test --test-timeout=60000 derive-status.test.mjs
