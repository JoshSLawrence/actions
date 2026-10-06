#!/usr/bin/env bash
#
# Rolls a workflow's jobs up into one pass/fail, for the single check to
# require in branch protection: every job must have succeeded or been
# skipped (skipped = nothing to do, e.g. no changes to apply).
#
# Environment variables:
#   NEEDS      - the result job's `toJSON(needs)` (required)
#   IS_FORK_PR - "true" on a pull request from a fork, which is validated
#                but never planned (no cloud credentials); a warning says so
#   NOTE       - another warning for the log, e.g. why a job was skipped on
#                purpose (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool jq
require_env NEEDS

jq -r 'to_entries[] | "  \(.key): \(.value.result)"' <<< "$NEEDS"

if is_true "${IS_FORK_PR:-false}"; then
  log_warn "This PR comes from a fork, which gets no cloud credentials, so it was validated but not planned. A maintainer can plan it by pushing the branch to this repository."
fi
if [ -n "${NOTE:-}" ]; then
  log_warn "$NOTE"
fi

mapfile -t failed < <(jq -r 'to_entries[] | select(.value.result != "success" and .value.result != "skipped") | .key' <<< "$NEEDS")
if [ ${#failed[@]} -gt 0 ]; then
  for job in "${failed[@]}"; do
    log_error "Job '${job}' did not succeed ($(jq -r --arg job "$job" '.[$job].result' <<< "$NEEDS")). See its log."
  done
  exit 1
fi

log_success "Every job succeeded or had nothing to do"
