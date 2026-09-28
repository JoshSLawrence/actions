#!/usr/bin/env bash
#
# Writes a table of the checks' results to the job summary, so one glance at
# the run shows every failing check instead of only the first red step.
#
# Environment variables:
#   WORKING_DIR - root module that was checked (for the heading)
#   RESULTS     - one "<check name>=<step outcome>" per line, where the outcome
#                 is success, failure, cancelled or skipped
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

failed=()
rows=()
while IFS= read -r line; do
  name="${line%%=*}"
  outcome="${line#*=}"
  case "$outcome" in
    success) result="✅ passed" ;;
    failure)
      result="❌ failed"
      failed+=("$name")
      ;;
    cancelled) result="⚪ cancelled" ;;
    *) result="⏭️ skipped" ;;
  esac
  rows+=("| ${name} | ${result} |")
done < <(list_lines "${RESULTS:-}")

{
  echo "### OpenTofu checks: \`${WORKING_DIR:-.}\`"
  echo ""
  echo "| Check | Result |"
  echo "| --- | --- |"
  printf '%s\n' "${rows[@]+"${rows[@]}"}"
  echo ""
} | append_step_summary

printf '%s\n' "${rows[@]+"${rows[@]}"}"

if [ ${#failed[@]} -gt 0 ]; then
  log_error "${#failed[@]} check(s) failed in ${WORKING_DIR:-.}: ${failed[*]}. See each step's log for the findings."
fi
