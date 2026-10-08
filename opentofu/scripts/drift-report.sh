#!/usr/bin/env bash
#
# Reports the result of a drift check -- a plan of the default branch, where
# any change means the live infrastructure (or its state) no longer matches
# the configuration -- for one deployment:
#
# - Error (the plan failed, or never ran): fails the job and leaves the
#   issues alone, so a broken check can't claim drift is gone.
# - Drift: opens one issue for the deployment, or updates the open one's
#   body with the latest plan, in place (an edit notifies nobody, so a daily
#   check doesn't nag). If the issue had been marked resolved and the drift
#   is back, it removes the label and comments once that it's back.
# - No drift: if the deployment has an open drift issue, comments once and
#   adds the resolved label. It never closes the issue: a person does.
# - FAIL_ON_DRIFT: also fails the job when there's drift.
#
# One issue per deployment, found by a hidden marker in its body (the same
# way PR comments are) among the open issues carrying the first of
# ISSUE_LABELS. Don't remove that label from an issue, or the next check
# opens another.
#
# Environment variables:
#   PLAN_EXIT_CODE  - the plan action's exit-code output: 0 = no drift,
#                     2 = drift, anything else or empty = error (required)
#   KEY             - identifies the deployment: the plan action's key
#                     output (required to touch issues)
#   TITLE           - what the check covers, as the plan action's title
#                     output (default: from KEY)
#   SUMMARY_FILE    - the plan action's summary-file output: the issue body.
#                     The plan itself is deleted by then, and never uploaded.
#   CREATE_ISSUES   - "true" to open, update and resolve issues (default
#                     true). Issues are only touched on the default branch
#                     (RUN_REF is DEFAULT_BRANCH's): the issue isn't keyed
#                     by ref, so a run on a feature branch would otherwise
#                     open, update or resolve the default branch's issue.
#   DEFAULT_BRANCH  - the repository's default branch (default: looked up with
#                     the API, since scheduled runs' event has no repository)
#   RUN_REF         - the ref being checked (default: GITHUB_REF)
#   ISSUE_PLAN      - "false" keeps the plan text out of the issue: its body
#                     has only the counts, the changed resource addresses and
#                     the run link (default true)
#   ISSUE_LABELS    - labels of new issues, comma-separated (default:
#                     opentofu-drift); the first also finds the issue
#   ISSUE_ASSIGNEES - who new issues are assigned to, comma-separated
#                     (default: nobody)
#   ISSUE_AUTHOR    - login the issues are posted as (default:
#                     github-actions[bot]); only its issues are updated
#   FAIL_ON_DRIFT   - "true" to fail when there's drift (default false)
#   GH_TOKEN        - token for the GitHub API (issues: write)
#   GITHUB_REPOSITORY - owner/name
#
# Outputs:
#   drift - true, false or error
#   issue - number of the deployment's open drift issue, if there is one
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

CREATE_ISSUES="${CREATE_ISSUES:-true}"
ISSUE_LABELS="${ISSUE_LABELS:-opentofu-drift}"
ISSUE_AUTHOR="${ISSUE_AUTHOR:-github-actions[bot]}"
ISSUE_PLAN="${ISSUE_PLAN:-true}"
RESOLVED_LABEL="drift-resolved"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

log_config PLAN_EXIT_CODE KEY CREATE_ISSUES DEFAULT_BRANCH RUN_REF GITHUB_REF ISSUE_PLAN ISSUE_LABELS ISSUE_ASSIGNEES FAIL_ON_DRIFT

case "${PLAN_EXIT_CODE:-}" in
  0) drift=false ;;
  2) drift=true ;;
  *) drift=error ;;
esac
set_output drift "$drift"

if [ "$drift" = error ]; then
  echo "### Drift check failed" | append_step_summary
  log_error "The drift check failed: the plan ended with exit code '${PLAN_EXIT_CODE:-none}' (0 = no drift, 2 = drift). Issues were left as they were. See the earlier steps' logs; common causes are an identity without read access to the state or the resources, and a state backend that can't be reached."
  exit 1
fi

# What the check covers, as markdown: the plan action's title without its
# "OpenTofu: " prefix, e.g. `iac/identity` · `prod`
key_label="${KEY:-this deployment}"
what="${TITLE:-\`${key_label%@*}\`}"
what="${what#OpenTofu: }"
what_plain="${what//\`/}"

if [ "$drift" = true ]; then
  echo "### Drift detected: ${what}" | append_step_summary
  log_warn "Drift detected in ${what_plain}: the infrastructure no longer matches the configuration. See the plan in the job summary."
else
  echo "### No drift: ${what}" | append_step_summary
  log_success "No drift in ${what_plain}"
fi

trim_list() {
  tr ',' '\n' <<< "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'
}

uri_encode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# Make sure a label exists: creating an issue with a missing one fails.
# Usage: ensure_label "<name>" "<color>" "<description>"
ensure_label() {
  if ! gh api "repos/${GITHUB_REPOSITORY}/labels/$(uri_encode "$1")" > /dev/null 2>&1; then
    log_info "Creating label '${1}'..."
    gh api --method POST "repos/${GITHUB_REPOSITORY}/labels" \
      -f name="$1" -f color="$2" -f description="$3" > /dev/null
  fi
}

# Write the issue body for the current drift to stdout
issue_body() {
  local summary
  summary="$(mktemp)"
  if [ -n "${SUMMARY_FILE:-}" ] && [ -s "$SUMMARY_FILE" ]; then
    if is_true "$ISSUE_PLAN"; then
      cp "$SUMMARY_FILE" "$summary"
    else
      # Everything above the collapsed full plan: the counts, destroys and
      # the table of resource addresses (see plan-summary.sh). Fails closed:
      # if the full plan's block isn't found, nothing of the summary but its
      # heading is used, never the plan text.
      local marker_line
      marker_line="$(grep -nxF "<details><summary>${FULL_PLAN_SUMMARY}</summary>" "$SUMMARY_FILE" || true)"
      marker_line="${marker_line%%:*}"
      if [ -n "$marker_line" ]; then
        head -n $((marker_line - 1)) "$SUMMARY_FILE" > "$summary"
      else
        log_warn "The plan summary format wasn't recognised (no '${FULL_PLAN_SUMMARY}' block), so issue-plan: false puts only its heading in the issue. This is a bug in the drift report: please report it."
        grep -m1 '^### ' "$SUMMARY_FILE" > "$summary" || true
      fi
      echo "" >> "$summary"
      echo "_The plan text is left out of this issue (issue-plan is off): see the [drift check](${RUN_URL})'s job summary._" >> "$summary"
    fi
  else
    echo "_The plan summary is missing: see the [drift check](${RUN_URL})._" > "$summary"
  fi
  fit_github_body "$summary" "the [drift check](${RUN_URL})'s job summary"

  echo "$MARKER"
  echo "The live infrastructure of ${what} no longer matches its configuration on \`${GITHUB_REF_NAME:-the default branch}\`, as of the [drift check](${RUN_URL}) at $(date -u '+%Y-%m-%d %H:%M UTC')."
  echo ""
  echo "Every drift check that still finds drift updates this issue in place. Once one finds none, it comments and adds the \`${RESOLVED_LABEL}\` label; close the issue yourself when you agree. To resolve the drift, either apply the configuration again (run the deploy workflow on the default branch) to revert what changed, or change the configuration to match and apply that."
  echo ""
  cat "$summary"
  rm -f "$summary"
}

if is_true "$CREATE_ISSUES"; then
  require_tool gh "GitHub CLI (gh)"
  require_env GH_TOKEN
  require_env GITHUB_REPOSITORY
  # A scheduled run's event has no repository object, so the workflow can't
  # pass it; failing to find out must not look like "not the default branch"
  if [ -z "${DEFAULT_BRANCH:-}" ]; then
    if ! DEFAULT_BRANCH="$(gh api "repos/${GITHUB_REPOSITORY}" --jq .default_branch)" || [ -z "$DEFAULT_BRANCH" ]; then
      log_error "Couldn't look up ${GITHUB_REPOSITORY}'s default branch, which decides whether this run may touch the drift issue. Check the token can read the repository, or set it as DEFAULT_BRANCH (default-branch). The drift result (${drift}) is in the output 'drift'."
      exit 1
    fi
  fi
  run_ref="${RUN_REF:-${GITHUB_REF:-}}"
fi

if is_true "$CREATE_ISSUES" && [ "$run_ref" != "refs/heads/${DEFAULT_BRANCH}" ]; then
  log_notice "Not on the default branch (${DEFAULT_BRANCH}; this run is ${run_ref:-unknown}): issues are only touched on the default branch, so this run can't open, update or resolve the deployment's issue. The drift result is in the job summary and the outputs."
  CREATE_ISSUES=false
fi

if is_true "$CREATE_ISSUES"; then
  require_tool gh "GitHub CLI (gh)"
  require_tool jq
  require_env GH_TOKEN
  require_env GITHUB_REPOSITORY
  require_env KEY
  MARKER="<!-- opentofu-drift:${KEY} -->"

  first_label="$(trim_list "$ISSUE_LABELS" | head -n 1)"
  if [ -z "$first_label" ]; then
    log_error "ISSUE_LABELS (issue-labels) has no label, so the deployment's issue can't be found again. Set at least one, e.g. opentofu-drift."
    exit 1
  fi

  set +e
  (
    set -e
    issue="$(gh_find_by_marker \
      "repos/${GITHUB_REPOSITORY}/issues?state=open&labels=$(uri_encode "$first_label")&per_page=100" \
      "$ISSUE_AUTHOR" "$MARKER" number)"
    issue_api="repos/${GITHUB_REPOSITORY}/issues"

    if [ "$drift" = true ]; then
      if [ -n "$issue" ]; then
        was_resolved="$(gh api "${issue_api}/${issue}" --jq "[.labels[].name] | index(\"${RESOLVED_LABEL}\") != null")"
        log_info "Updating drift issue #${issue}..."
        issue_body | jq -Rs '{body: .}' | gh api --method PATCH "${issue_api}/${issue}" --input - > /dev/null
        if [ "$was_resolved" = true ]; then
          log_info "Drift issue #${issue} was marked resolved: the drift is back..."
          gh api --method DELETE "${issue_api}/${issue}/labels/$(uri_encode "$RESOLVED_LABEL")" > /dev/null
          jq -n --arg body "Drift is back as of the [drift check](${RUN_URL}) at $(date -u '+%Y-%m-%d %H:%M UTC'): the infrastructure no longer matches the configuration. The \`${RESOLVED_LABEL}\` label is removed; the plan above is updated." '{body: $body}' |
            gh api --method POST "${issue_api}/${issue}/comments" --input - > /dev/null
        fi
      else
        while IFS= read -r label; do
          ensure_label "$label" d93f0b "Infrastructure drift found by the OpenTofu drift check"
        done < <(trim_list "$ISSUE_LABELS")
        payload="$(issue_body | jq -Rs \
          --arg title "OpenTofu drift: ${what_plain}" --arg labels "$(trim_list "$ISSUE_LABELS" | paste -sd, -)" \
          --arg assignees "$(trim_list "${ISSUE_ASSIGNEES:-}" | paste -sd, -)" '
          {title: $title, body: ., labels: ($labels | split(","))}
          + (($assignees | split(",") | map(select(length > 0))) as $a | if ($a | length) > 0 then {assignees: $a} else {} end)')"
        first_json="$(jq -rn --arg v "$first_label" '$v | tojson')"
        created="$(gh api --method POST "$issue_api" --input - \
          --jq "\"\(.number) \([.labels[].name] | index(${first_json}) != null)\"" <<< "$payload")"
        issue="${created%% *}"
        log_warn "Opened drift issue #${issue} for ${what_plain}."
        # Without its first label the next check wouldn't find this issue and
        # would open another, every day
        if [ "${created##* }" != true ]; then
          log_warn "Drift issue #${issue} was created without the label '${first_label}' (GitHub dropped it). Adding it, so the next check finds this issue."
          jq -n --arg label "$first_label" '{labels: [$label]}' |
            gh api --method POST "${issue_api}/${issue}/labels" --input - > /dev/null
        fi
      fi
    elif [ -n "$issue" ]; then
      was_resolved="$(gh api "${issue_api}/${issue}" --jq "[.labels[].name] | index(\"${RESOLVED_LABEL}\") != null")"
      if [ "$was_resolved" = true ]; then
        log_info "Drift issue #${issue} is already marked resolved; nothing to add."
      else
        log_info "Marking drift issue #${issue} resolved: the drift is gone..."
        ensure_label "$RESOLVED_LABEL" 0e8a16 "The drift check found no drift anymore; close the issue when you agree"
        jq -n --arg label "$RESOLVED_LABEL" '{labels: [$label]}' |
          gh api --method POST "${issue_api}/${issue}/labels" --input - > /dev/null
        jq -n --arg body "No drift as of the [drift check](${RUN_URL}) at $(date -u '+%Y-%m-%d %H:%M UTC'): the infrastructure matches the configuration again. The issue is left open with the \`${RESOLVED_LABEL}\` label; close it when you agree. If the drift comes back, this issue is updated and the label removed." '{body: $body}' |
          gh api --method POST "${issue_api}/${issue}/comments" --input - > /dev/null
        log_success "Marked drift issue #${issue} resolved"
      fi
    fi
    set_output issue "$issue"
  )
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    log_error "Couldn't update the drift issue (see the error above). The calling job needs 'issues: write'; check the token, and that issues are enabled in the repository. The drift result itself is in the output 'drift' (${drift}) and the job summary."
    exit 1
  fi
fi

if [ "$drift" = true ] && is_true "${FAIL_ON_DRIFT:-false}"; then
  log_error "Failing because of drift in ${what_plain} (fail-on-drift). Resolve it by applying the configuration again, or by changing the configuration to match."
  exit 1
fi
