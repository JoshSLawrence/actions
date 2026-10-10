#!/usr/bin/env bash
#
# Estimates the monthly cost of a plan with Infracost, and renders it as a
# markdown fragment for the plan summary. Informational only: any failure
# (no API key, Infracost down) is a warning in the fragment, never a failed
# job. With cost estimates turned off, the fragment just says so, so readers
# of the PR comment know why there's no cost section.
#
# Environment variables:
#   COST_ESTIMATE     - "true" to estimate; anything else writes the "off"
#                       note instead (default: true)
#   WORKING_DIR       - root module whose mise config pins infracost
#                       (required)
#   PLAN_JSON         - `tofu show -json` output to price (required)
#   FRAGMENT_FILE     - where to write the markdown fragment (required)
#   INFRACOST_API_KEY - Infracost API key (required for an estimate; get one
#                       with `infracost auth login`)
#   MAX_RESOURCES     - most expensive resources to list (default: 20)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ensure_mise
require_tool jq
require_env PLAN_JSON
require_env FRAGMENT_FILE

# Absolute, so they stay valid once the script moves into the module
PLAN_JSON="$(abs_path "$PLAN_JSON")"
FRAGMENT_FILE="$(abs_path "$FRAGMENT_FILE")"

if ! is_true "${COST_ESTIMATE:-true}"; then
  echo "<sub>💰 No cost estimate: Infracost is turned off for this deployment</sub>" > "$FRAGMENT_FILE"
  log_info "Cost estimates are off; noted in the plan summary"
  exit 0
fi

MAX_RESOURCES="${MAX_RESOURCES:-20}"
export INFRACOST_SKIP_UPDATE_CHECK=true
export INFRACOST_NO_COLOR=true

unavailable() {
  local reason="$1" details="${2:-}"
  {
    echo "### 💰 Cost estimate unavailable"
    echo ""
    echo "$reason"
    if [ -n "$details" ]; then
      echo ""
      details_open "infracost output"
      echo "\`\`\`\`text"
      echo "$details" | tail -n 30
      echo "\`\`\`\`"
      echo ""
      echo "</details>"
    fi
  } > "$FRAGMENT_FILE"
  log_warn "Cost estimate unavailable: ${reason}"
  exit 0
}

if [ -z "${INFRACOST_API_KEY:-}" ]; then
  unavailable "No Infracost API key: pass one as the infracost-api-key secret (get a free key with \`infracost auth login\`)."
fi
# Infracost runs with the module's own mise pins
cd_working_dir
if [ -z "$(mise current infracost 2> /dev/null)" ]; then
  unavailable "Infracost isn't pinned for ${WORKING_DIR}. $(mise_pin_hint infracost)"
fi

cost_json="$(mktemp)"
trap 'rm -f "$cost_json"' EXIT

log_cmd infracost breakdown --path "$PLAN_JSON" --format json
set +e
output=$(mise exec -- infracost breakdown --path "$PLAN_JSON" --format json --out-file "$cost_json" 2>&1)
exit_code=$?
set -e
if [ "$exit_code" -ne 0 ] || ! jq -e . "$cost_json" > /dev/null 2>&1; then
  unavailable "\`infracost breakdown\` failed (exit ${exit_code})." "$output"
fi

# Infracost reports costs as decimal strings, or null when it can't price
# anything. Usage: money "<value>" [signed]
money() {
  local value="$1"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "–"
    return
  fi
  local formatted
  formatted=$(LC_ALL=C printf '%.2f' "$value")
  if [ "${2:-}" = "signed" ] && [[ "$formatted" != -* ]] && [ "$formatted" != "0.00" ]; then
    formatted="+${formatted}"
  fi
  echo "$formatted"
}

currency=$(jq -r '.currency // "USD"' "$cost_json")
past=$(money "$(jq -r '.pastTotalMonthlyCost' "$cost_json")")
total=$(money "$(jq -r '.totalMonthlyCost' "$cost_json")")
diff=$(money "$(jq -r '.diffTotalMonthlyCost' "$cost_json")" signed)

{
  echo "### 💰 Cost estimate (${currency}/month)"
  echo ""
  echo "| Before | After | Change |"
  echo "| ---: | ---: | ---: |"
  echo "| ${past} | ${total} | **${diff}** |"
  echo ""
  resources=$(jq -r --argjson max "$MAX_RESOURCES" '
    [ .projects[]?.breakdown.resources[]?
      | select(.monthlyCost != null)
      | {name, cost: (.monthlyCost | tonumber)} ]
    | sort_by(-.cost)
    | .[:$max][]
    | "\(.name)\t\(.cost)"' "$cost_json")
  if [ -n "$resources" ]; then
    details_open "Most expensive resources after this plan"
    echo "| Resource | Monthly cost |"
    echo "| --- | ---: |"
    while IFS=$'\t' read -r name cost; do
      echo "| \`${name}\` | $(money "$cost") |"
    done <<< "$resources"
    echo ""
    echo "</details>"
    echo ""
  fi
  echo "<sub>Estimated by Infracost from list prices; usage-based costs are not included.</sub>"
} > "$FRAGMENT_FILE"

log_success "Cost estimate: ${past} -> ${total} ${currency}/month (${diff})"
