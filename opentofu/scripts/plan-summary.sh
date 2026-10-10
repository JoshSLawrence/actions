#!/usr/bin/env bash
#
# Renders the markdown summary of a plan to stdout (plan.sh calls it). Safe to
# run locally against a saved plan:
#
#   tofu show -json tfplan > plan.json && tofu show -no-color tfplan > plan.txt
#   PLAN_JSON=plan.json PLAN_TEXT=plan.txt opentofu/scripts/plan-summary.sh
#
# Environment variables:
#   PLAN_EXIT_CODE - exit code of `tofu plan -detailed-exitcode` (default 0).
#                    0 or 2 renders the plan; anything else renders a failure.
#   PLAN_JSON      - `tofu show -json` output (required unless the plan failed)
#   PLAN_TEXT      - `tofu show -no-color` output (required unless the plan
#                    failed)
#   PLAN_LOG       - init/plan output, quoted when the plan failed
#   MAX_PLAN_CHARS - budget for the quoted plan/log (default 40000). GitHub
#                    rejects comments over 65536 characters, and the policy
#                    and cost sections have to fit in what's left.
#   HEAD_SHA, TARGET_BRANCH, TARGET_SHA, PR_NUMBER - describe what was planned
#                    (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

PLAN_EXIT_CODE="${PLAN_EXIT_CODE:-0}"
MAX_PLAN_CHARS="${MAX_PLAN_CHARS:-40000}"

TMP_FILES=()
cleanup() {
  rm -f "${TMP_FILES[@]+"${TMP_FILES[@]}"}"
}
trap cleanup EXIT

# context_line and collapsible_block (MAX_PLAN_CHARS) are in
# shared/scripts/common.sh

if [ "$PLAN_EXIT_CODE" -ne 0 ] && [ "$PLAN_EXIT_CODE" -ne 2 ]; then
  echo "### ❌ Plan failed"
  echo ""
  context_line
  echo ""
  echo "\`tofu init\` or \`tofu plan\` exited with code ${PLAN_EXIT_CODE}. Nothing can be applied until the plan succeeds."
  echo ""
  if [ -n "${PLAN_LOG:-}" ] && [ -s "$PLAN_LOG" ]; then
    # Only the end of the log, where the error diagnostics are. ANSI colour
    # codes are stripped: they render as garbage in markdown.
    log_tail="$(mktemp)"
    TMP_FILES+=("$log_tail")
    tail -n 100 "$PLAN_LOG" | sed "s/$(printf '\033')\[[0-9;]*m//g" > "$log_tail"
    collapsible_block "Output (last 100 lines)" "text" "$log_tail"
  fi
  exit 0
fi

require_tool jq
require_env PLAN_JSON "Set it to the output of 'tofu show -json <planfile>'."
require_env PLAN_TEXT "Set it to the output of 'tofu show -no-color <planfile>'."

# Classify every resource change in one jq pass. Replacements count as both an
# add and a destroy, matching tofu's own "Plan: X to add, ..." line. A no-op
# still matters when it's an import or a move. Data source reads change
# nothing, so they're left out.
CHANGES=$(jq -c '
  [ .resource_changes[]?
    | .change.actions as $a
    | {
        address,
        action: (
          if   $a == ["create"] then "create"
          elif $a == ["update"] then "update"
          elif $a == ["delete"] then "delete"
          elif $a == ["delete", "create"] or $a == ["create", "delete"] then "replace"
          elif $a == ["forget"] then "forget"
          elif $a == ["no-op"] then "no-op"
          else ($a | join("/"))
          end
        ),
        importing: (.change.importing != null),
        moved_from: .previous_address
      }
    | select(.action != "read")
    | select(.action != "no-op" or .importing or .moved_from != null)
  ]' "$PLAN_JSON")

count() {
  jq -r "[.[] | select($1)] | length" <<< "$CHANGES"
}

add=$(count '.action == "create" or .action == "replace"')
change=$(count '.action == "update"')
destroy=$(count '.action == "delete" or .action == "replace"')
import=$(count '.importing')
move=$(count '.moved_from != null')
forget=$(count '.action == "forget"')
outputs=$(jq -r '[.output_changes // {} | .[] | select(.actions != ["no-op"])] | length' "$PLAN_JSON")
resources=$(jq -r 'length' <<< "$CHANGES")

if [ "$resources" -eq 0 ] && [ "$outputs" -eq 0 ]; then
  echo "### ✅ No changes"
  echo ""
  context_line
  echo ""
  echo "The infrastructure matches the configuration. Nothing to apply."
  exit 0
fi

echo "### 📋 Plan: ${add} to add, ${change} to change, ${destroy} to destroy"
echo ""
context_line
echo ""

extras=()
[ "$import" -gt 0 ] && extras+=("${import} to import")
[ "$move" -gt 0 ] && extras+=("${move} moved")
[ "$forget" -gt 0 ] && extras+=("${forget} to forget")
[ "$outputs" -gt 0 ] && extras+=("${outputs} output(s) changed")
if [ ${#extras[@]} -gt 0 ]; then
  extras_line=""
  for extra in "${extras[@]}"; do
    extras_line="${extras_line:+$extras_line, }$extra"
  done
  echo "Also: ${extras_line}."
  echo ""
fi

# Destroys are what a reviewer must not miss, so they go above the fold
# instead of only in the collapsed table.
if [ "$destroy" -gt 0 ]; then
  echo "> **Warning:** this plan destroys ${destroy} resource(s):"
  jq -r '.[] | select(.action == "delete" or .action == "replace")
    | "> - `\(.address)`\(if .action == "replace" then " (replaced)" else "" end)"' <<< "$CHANGES"
  echo ""
fi

if [ "$resources" -gt 0 ]; then
  details_open "Resources (${resources})"
  echo "| Action | Resource |"
  echo "| --- | --- |"
  jq -r '
    sort_by([
      ({delete: 0, replace: 1, forget: 2, update: 3, create: 4}[.action] // 5),
      .address
    ])[]
    | (
        {
          create: "🟢 create",
          update: "🟡 update",
          replace: "🟠 replace",
          delete: "🔴 destroy",
          forget: "⚪ forget",
          "no-op": "🔵 state only"
        }[.action] // .action
      ) as $label
    | [
        (if .importing then "import" else empty end),
        (if .moved_from then "moved from `\(.moved_from)`" else empty end)
      ] as $notes
    | "| \($label) | `\(.address)`\(if ($notes | length) > 0 then " (\($notes | join(", ")))" else "" end) |"
  ' <<< "$CHANGES"
  echo ""
  echo "</details>"
  echo ""
fi

# Move each line's change marker (+, -, ~, -/+) to the start of the line so
# GitHub's diff highlighting colours additions and removals.
plan_diff="$(mktemp)"
TMP_FILES+=("$plan_diff")
sed -E 's/^([[:space:]]+)(-\/\+|\+\/-|[-+~])( )/\2\1\3/' "$PLAN_TEXT" > "$plan_diff"
collapsible_block "$FULL_PLAN_SUMMARY" "diff" "$plan_diff"
