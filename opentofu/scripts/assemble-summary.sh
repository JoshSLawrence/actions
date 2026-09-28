#!/usr/bin/env bash
#
# Joins the plan summary fragments (plan, policy, cost -- whichever ran) into
# one markdown summary, in file name order, and adds it to the job summary.
# The summary file travels with the plan artifact, so the apply job can
# re-post it with the apply result.
#
# Environment variables:
#   WORK_DIR     - directory whose fragments/*.md to join (required)
#   SUMMARY_FILE - where to write the joined summary (required)
#   TITLE        - heading for the job summary (default: OpenTofu plan)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_env WORK_DIR
require_env SUMMARY_FILE

shopt -s nullglob
fragments=("$WORK_DIR"/fragments/*.md)
shopt -u nullglob

if [ ${#fragments[@]} -eq 0 ]; then
  log_warn "No plan summary was produced (the plan step didn't get far enough to write one). See the plan step's log."
  exit 0
fi

mkdir -p "$(dirname "$SUMMARY_FILE")"
{
  first=true
  for fragment in "${fragments[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      echo ""
    fi
    cat "$fragment"
  done
} > "$SUMMARY_FILE"

{
  echo "## ${TITLE:-OpenTofu plan}"
  echo ""
  cat "$SUMMARY_FILE"
  echo ""
} | append_step_summary

log_success "Plan summary written to ${SUMMARY_FILE}"
