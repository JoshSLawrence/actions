#!/usr/bin/env bash
#
# Reports the result of a drift check -- a plan of the default branch, where
# any change means the live infrastructure (or its state) no longer matches
# the configuration -- for one deployment:
#
# - Drift: opens an issue for the deployment, or updates the open one's body
#   with the latest plan (edited in place, so a daily check doesn't notify
#   anyone again until something changes on the issue).
# - No drift: comments on and closes the deployment's open issue, if any.
# - FAIL_ON_DRIFT: also fails the job when there's drift.
#
# One issue per deployment, found by a hidden marker in its body (like the PR
# comments) among the open issues labelled with the first of LABELS.
#
# Environment variables:
#   HAS_CHANGES    - "true" if the plan found drift (required)
#   KEY            - identifies the deployment (the plan action's key output)
#                    (required)
#   TITLE          - what drifted, for the issue title (default: from KEY,
#                    e.g. `infra` · `prod`)
#   SUMMARY_FILE   - the plan summary markdown
#   CREATE_ISSUES  - "true" to open/update/close issues (default: true)
#   LABELS         - labels for new issues, comma-separated (default: drift)
#   ISSUE_AUTHOR   - login the issues are posted as (default:
#                    github-actions[bot]); only its issues are updated
#   FAIL_ON_DRIFT  - "true" to fail when there's drift (default: false)
#   GH_TOKEN       - token for the GitHub API (issues: write)
#   GITHUB_REPOSITORY
#
# Outputs:
#   issue - number of the deployment's drift issue, if there is one
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_env HAS_CHANGES
require_env KEY
CREATE_ISSUES="${CREATE_ISSUES:-true}"
LABELS="${LABELS:-drift}"
ISSUE_AUTHOR="${ISSUE_AUTHOR:-github-actions[bot]}"
# "infra:prod" -> `infra` · `prod`
TITLE="${TITLE:-\`${KEY//:/\` · \`}\`}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
MARKER="<!-- opentofu-drift:${KEY} -->"

log_config KEY HAS_CHANGES CREATE_ISSUES LABELS FAIL_ON_DRIFT

if is_true "$HAS_CHANGES"; then
  echo "### 🔀 Drift detected: ${TITLE}" | append_step_summary
  log_warn "Drift detected in ${KEY}: the infrastructure no longer matches the configuration. See the plan in the job summary."
else
  echo "### ✅ No drift: ${TITLE}" | append_step_summary
  log_success "No drift in ${KEY}"
fi

# Make sure every label exists: creating an issue with a missing label fails
ensure_labels() {
  local label
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if ! gh api "repos/${GITHUB_REPOSITORY}/labels/$(jq -rn --arg v "$label" '$v | @uri')" > /dev/null 2>&1; then
      log_info "Creating label '${label}'..."
      gh api --method POST "repos/${GITHUB_REPOSITORY}/labels" \
        -f name="$label" -f color="d93f0b" -f description="Infrastructure drift found by the OpenTofu drift check" > /dev/null
    fi
  done < <(tr ',' '\n' <<< "$LABELS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# Writes the issue body for the current drift to stdout
issue_body() {
  local summary
  summary="$(mktemp)"
  if [ -n "${SUMMARY_FILE:-}" ] && [ -s "$SUMMARY_FILE" ]; then
    cp "$SUMMARY_FILE" "$summary"
  else
    echo "_The plan summary is missing: see the [drift check](${RUN_URL})._" > "$summary"
  fi
  fit_github_body "$summary" "the [drift check](${RUN_URL})'s job summary"

  echo "$MARKER"
  echo "The live infrastructure of ${TITLE} no longer matches its configuration on the default branch, as of the [drift check](${RUN_URL}) at $(date -u '+%Y-%m-%d %H:%M UTC'). This issue is updated by every drift check, and closes itself once one finds no changes."
  echo ""
  echo "To resolve it, either apply the configuration again (run the deploy workflow on the default branch) to revert what changed, or change the configuration to match and apply that."
  echo ""
  cat "$summary"
  rm -f "$summary"
}

if is_true "$CREATE_ISSUES"; then
  require_tool gh "GitHub CLI (gh)"
  require_tool jq
  require_env GH_TOKEN
  require_env GITHUB_REPOSITORY

  first_label="$(cut -d, -f1 <<< "$LABELS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  issue="$(gh_find_by_marker \
    "repos/${GITHUB_REPOSITORY}/issues?state=open&labels=$(jq -rn --arg v "$first_label" '$v | @uri')&per_page=100" \
    "$ISSUE_AUTHOR" "$MARKER" number)"

  if is_true "$HAS_CHANGES"; then
    payload="$(issue_body | jq -Rs --arg title "Drift: ${TITLE//\`/}" --arg labels "$LABELS" \
      '{title: $title, body: ., labels: ($labels | split(",") | map(gsub("^\\s+|\\s+$"; "")))}')"
    if [ -n "$issue" ]; then
      log_info "Updating drift issue #${issue}..."
      jq '{body}' <<< "$payload" | gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/${issue}" --input - > /dev/null
    else
      ensure_labels
      issue="$(gh api --method POST "repos/${GITHUB_REPOSITORY}/issues" --input - --jq .number <<< "$payload")"
      log_warn "Opened drift issue #${issue} for ${KEY}."
    fi
    set_output issue "$issue"
  elif [ -n "$issue" ]; then
    log_info "Closing drift issue #${issue}: the drift is gone..."
    jq -n --arg body "✅ No drift as of the [drift check](${RUN_URL}) at $(date -u '+%Y-%m-%d %H:%M UTC'): the infrastructure matches the configuration again. Closing." '{body: $body}' |
      gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${issue}/comments" --input - > /dev/null
    gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/${issue}" -f state=closed -f state_reason=completed > /dev/null
    log_success "Closed drift issue #${issue}"
  fi
fi

if is_true "$HAS_CHANGES" && is_true "${FAIL_ON_DRIFT:-false}"; then
  log_error "Failing because of drift in ${KEY} (fail-on-drift). Resolve it by applying the configuration again, or by changing the configuration to match."
  exit 1
fi
