#!/usr/bin/env bash
#
# Last step of the plan action; runs even when an earlier step failed:
#
# 1. Joins the summary fragments (plan, cost, policy -- whichever ran) into
#    one markdown summary, in file name order, and adds it to the job
#    summary. The summary goes in PLAN_DIR, so it travels with the plan
#    artifact and the apply job can re-post it with the apply result.
# 2. Deletes WORK_DIR: plan.json and the logs hold sensitive values unmasked.
#
# Environment variables:
#   WORK_DIR     - scratch directory whose fragments/*.md to join (required)
#   SUMMARY_FILE - where to write the joined summary (required)
#   TITLE        - heading for the job summary (default: OpenTofu plan)
#
# Outputs:
#   summary-file - SUMMARY_FILE, when a summary was written
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_env WORK_DIR
require_env SUMMARY_FILE
trap 'rm -rf "$WORK_DIR"' EXIT

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

set_output summary-file "$SUMMARY_FILE"
log_success "Plan summary written to ${SUMMARY_FILE}"
