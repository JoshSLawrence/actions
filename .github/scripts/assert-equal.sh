#!/usr/bin/env bash
#
# Fails unless ACTUAL equals EXPECTED: CI's way to assert on a reusable
# workflow's output without an inline script (the e2e drift call must
# report drift, for instance).
#
# Environment variables:
#   WHAT     - what is compared, for the message (required)
#   EXPECTED - the value it should have (required)
#   ACTUAL   - the value it has (may be empty)
#

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=shared/scripts/common.sh
source shared/scripts/common.sh

require_env WHAT
require_env EXPECTED

if [ "${ACTUAL:-}" != "$EXPECTED" ]; then
  log_error "${WHAT} is '${ACTUAL:-}', expected '${EXPECTED}'. See the job that produced it."
  exit 1
fi
log_success "${WHAT} is '${EXPECTED}'"
