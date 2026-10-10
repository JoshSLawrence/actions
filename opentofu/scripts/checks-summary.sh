#!/usr/bin/env bash
#
# Renders the checks' results as a table, so one glance shows every failing
# check instead of only the first red step. Two uses:
#
# - In the checks job (no FRAGMENT_FILE): writes the table to the job
#   summary, logs the failed checks, and outputs the results on one line for
#   later jobs.
# - In the plan job (FRAGMENT_FILE set): writes a "Checks" section for the
#   plan summary and the PR comment, from the results the checks job output.
#
# Environment variables:
#   WORKING_DIR   - root module that was checked (for the heading)
#   RESULTS       - "<check name>=<step outcome>" entries, one per line or
#                   comma-separated, where the outcome is success, failure,
#                   cancelled or skipped; or "off" when the call turned the
#                   checks off
#   FRAGMENT_FILE - where to write the plan summary's section (optional)
#
# Outputs:
#   results - RESULTS on one line, comma-separated (checks job only)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

if [ -n "${FRAGMENT_FILE:-}" ]; then
  mkdir -p "$(dirname "$FRAGMENT_FILE")"
fi

if [ "${RESULTS:-}" = "off" ]; then
  if [ -n "${FRAGMENT_FILE:-}" ]; then
    echo "#### Checks: off (\`checks: false\`)" > "$FRAGMENT_FILE"
  fi
  log_info "Checks were turned off for this call (checks: false)."
  exit 0
fi

failed=()
rows=()
entries=()
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
    *) result="⏭️ off" ;;
  esac
  rows+=("| ${name} | ${result} |")
  entries+=("${name}=${outcome}")
done < <(list_lines "$(tr ',' '\n' <<< "${RESULTS:-}")")

table() {
  echo "| Check | Result |"
  echo "| --- | --- |"
  printf '%s\n' "${rows[@]+"${rows[@]}"}"
}

if [ -n "${FRAGMENT_FILE:-}" ]; then
  {
    details_open "Checks: ${#failed[@]} failed of ${#rows[@]}"
    table
    echo ""
    echo "</details>"
  } > "$FRAGMENT_FILE"
  exit 0
fi

{
  echo "### OpenTofu checks: \`${WORKING_DIR:-.}\`"
  echo ""
  table
  echo ""
} | append_step_summary

table
set_output results "$(IFS=,; echo "${entries[*]+"${entries[*]}"}")"

if [ ${#failed[@]} -gt 0 ]; then
  log_error "${#failed[@]} check(s) failed in ${WORKING_DIR:-.}: ${failed[*]}. See each step's log for the findings."
fi
