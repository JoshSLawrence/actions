#!/usr/bin/env bash
#
# Evaluates a plan against Rego policies with conftest, and renders the
# results as a markdown fragment for the plan summary. Always exits 0 once
# it has rendered the fragment; the pass/fail decision is the `passed` output,
# which the plan action enforces after the PR comment is posted (so a blocked
# plan still shows reviewers why).
#
# Fails closed: if conftest can't run (no policies found, a Rego syntax error,
# an unreadable plan), the check counts as failed.
#
# Environment variables:
#   PLAN_JSON           - `tofu show -json` output to evaluate (required)
#   FRAGMENT_FILE       - where to write the markdown fragment (required)
#   POLICY_PATH         - policy directories, space- or newline-separated,
#                         relative to the current directory (optional if
#                         POLICY_SOURCE is set)
#   POLICY_SOURCE       - a go-getter URL to pull policies from, e.g.
#                         git::https://github.com/org/policies.git//policy?ref=v1
#                         (optional; private GitHub repositories use
#                         MODULES_GITHUB_TOKEN)
#   POLICY_NAMESPACES   - Rego namespaces to evaluate, space- or
#                         newline-separated (default: all namespaces)
#   POLICY_FAIL_ON_WARN - "true" to also fail on warn rules (default: false)
#   WORK_DIR            - scratch directory for pulled policies (default:
#                         a temporary directory)
#
# Outputs:
#   passed   - true if no deny (and, with POLICY_FAIL_ON_WARN, no warn) fired
#   denies   - number of deny results
#   warnings - number of warn results
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ensure_mise
require_tool jq
require_env PLAN_JSON "The plan action sets it to the plan's JSON; check the policy step runs after the plan step."
require_env FRAGMENT_FILE

log_config PLAN_JSON POLICY_PATH POLICY_SOURCE POLICY_NAMESPACES POLICY_FAIL_ON_WARN

set_output passed false

# Writes a "could not run" fragment and fails closed
could_not_run() {
  local reason="$1" details="${2:-}"
  {
    echo "### ⚠️ Policy check could not run"
    echo ""
    echo "${reason} The plan is treated as failing policy until this is fixed."
    if [ -n "$details" ]; then
      echo ""
      echo "<details><summary>conftest output</summary>"
      echo ""
      echo "\`\`\`\`text"
      echo "$details" | head -n 50
      echo "\`\`\`\`"
      echo ""
      echo "</details>"
    fi
  } > "$FRAGMENT_FILE"
  log_error "Policy check could not run: ${reason}"
  exit 0
}

if [ -z "$(mise current conftest 2> /dev/null)" ]; then
  could_not_run "conftest isn't installed: add conftest to the opentofu/setup action's tools input (the reusable workflow does this when policy is enabled)."
fi
if [ ! -s "$PLAN_JSON" ]; then
  could_not_run "The plan JSON (${PLAN_JSON}) is missing or empty."
fi

policy_args=()
while IFS= read -r path; do
  if [ ! -d "$path" ]; then
    could_not_run "Policy directory '${path}' not found (paths are relative to the repository root)."
  fi
  policy_args+=(--policy "$path")
done < <(list_items "${POLICY_PATH:-}")

if [ -n "${POLICY_SOURCE:-}" ]; then
  configure_git_github_auth
  pulled="${WORK_DIR:-$(mktemp -d)}/policy-source"
  rm -rf "$pulled"
  log_cmd conftest pull "$POLICY_SOURCE" --policy "$pulled"
  set +e
  pull_output=$(mise exec -- conftest pull "$POLICY_SOURCE" --policy "$pulled" 2>&1)
  pull_exit=$?
  set -e
  if [ "$pull_exit" -ne 0 ]; then
    could_not_run "Pulling policies from the policy-source URL failed (exit ${pull_exit})." "$pull_output"
  fi
  policy_args+=(--policy "$pulled")
fi

if [ ${#policy_args[@]} -eq 0 ]; then
  could_not_run "No policies configured: set policy-path and/or policy-source."
fi

namespace_args=()
while IFS= read -r ns; do
  namespace_args+=(--namespace "$ns")
done < <(list_items "${POLICY_NAMESPACES:-}")
if [ ${#namespace_args[@]} -eq 0 ]; then
  namespace_args=(--all-namespaces)
fi

# conftest exits 1 both for policy failures and for errors, so the exit code
# alone can't tell them apart: parse the JSON it prints, and treat output that
# isn't a results array as conftest failing to run.
cmd=(conftest test "$PLAN_JSON" --no-color --output json "${policy_args[@]}" "${namespace_args[@]}")
log_cmd "${cmd[@]}"
set +e
results=$(mise exec -- "${cmd[@]}" 2> "${FRAGMENT_FILE}.stderr")
conftest_exit=$?
set -e
stderr_output="$(cat "${FRAGMENT_FILE}.stderr")"
rm -f "${FRAGMENT_FILE}.stderr"

if ! jq -e 'type == "array"' <<< "$results" > /dev/null 2>&1; then
  could_not_run "conftest exited with code ${conftest_exit} without producing results." "${stderr_output:-$results}"
fi

denies=$(jq '[.[].failures // [] | length] | add // 0' <<< "$results")
warnings=$(jq '[.[].warnings // [] | length] | add // 0' <<< "$results")
successes=$(jq '[.[].successes // 0] | add // 0' <<< "$results")

passed=true
if [ "$denies" -gt 0 ]; then
  passed=false
elif [ "$warnings" -gt 0 ] && is_true "${POLICY_FAIL_ON_WARN:-false}"; then
  passed=false
fi

{
  if [ "$passed" = "true" ] && [ "$warnings" -eq 0 ]; then
    echo "### 🛡️ Policy: ✅ passed"
    echo ""
    echo "All ${successes} policy check(s) passed."
  else
    if [ "$passed" = "true" ]; then
      echo "### 🛡️ Policy: ⚠️ passed with ${warnings} warning(s)"
    else
      echo "### 🛡️ Policy: ❌ failed (${denies} denied, ${warnings} warning(s))"
      echo ""
      if [ "$denies" -gt 0 ]; then
        echo "This plan can't be applied until the denied changes are fixed (or the policy is changed)."
      else
        echo "This plan can't be applied: warnings fail the policy check for this configuration (policy-fail-on-warn)."
      fi
    fi
    echo ""
    jq -r '
      .[] | .namespace as $ns
      | ((.failures // [])[] | "- 🛑 **deny** `\($ns)`: \(.msg)"),
        ((.warnings // [])[] | "- ⚠️ **warn** `\($ns)`: \(.msg)")
    ' <<< "$results"
  fi
} > "$FRAGMENT_FILE"

set_output passed "$passed"
set_output denies "$denies"
set_output warnings "$warnings"

if [ "$passed" = "true" ]; then
  log_success "Policy check passed (${denies} denied, ${warnings} warning(s), ${successes} passed)"
else
  log_error "Policy check failed: ${denies} denied, ${warnings} warning(s). The plan won't be uploaded, so it can't be applied. See the policy section of the plan summary."
fi
