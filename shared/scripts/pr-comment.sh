#!/usr/bin/env bash
#
# Creates or updates the plan/apply comment on a PR: the plan summary plus
# where the apply stands. There's one comment per PR and COMMENT_KEY (i.e.
# per root module or folder, deployment and environment), edited in place by
# every run, so the PR
# shows the latest plan instead of a growing stack of stale ones. Earlier
# versions stay in the comment's edit history, and every run's summary stays
# on its run page.
#
# Environment variables:
#   GH_TOKEN          - token for the GitHub API (needs pull-requests: write)
#   GITHUB_REPOSITORY - owner/name
#   PR_NUMBER         - PR to comment on. Unset (not a PR run): does nothing.
#   HEAD_SHA          - PR head commit this run planned
#   COMMENT_KEY       - identifies this comment among others on the PR
#   TITLE             - comment heading (default: Plan)
#   SUMMARY_FILE      - plan summary markdown. If missing (the run failed
#                       before planning), a pointer to the run log is posted.
#   APPLY_STATUS      - none, awaiting-approval, after-merge, blocked,
#                       succeeded, or failed
#   APPLY_ENVIRONMENT - GitHub environment the apply runs in (for the text)
#   BLOCKED_REASON    - with APPLY_STATUS blocked: the text saying why.
#                       Default: the policy check text (OpenTofu's).
#   COMMENT_AUTHOR    - login the comment is posted as (default:
#                       github-actions[bot]; e.g. my-app[bot] for a GitHub App
#                       token). Only its comments are ever edited.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

if [ -z "${PR_NUMBER:-}" ]; then
  log_info "Not a pull request run; nothing to comment on"
  exit 0
fi

require_tool gh "GitHub CLI (gh)"
require_tool jq
require_env GH_TOKEN
require_env GITHUB_REPOSITORY
require_env HEAD_SHA
require_env COMMENT_KEY
require_env APPLY_STATUS

case "$APPLY_STATUS" in
  none | awaiting-approval | after-merge | blocked | succeeded | failed) ;;
  *)
    log_error "Unknown APPLY_STATUS '${APPLY_STATUS}'. Use none, awaiting-approval, after-merge, blocked, succeeded, or failed."
    exit 1
    ;;
esac

# Named before there was more than OpenTofu; kept so the comments already on
# open PRs are still found. Keys differ per area (Data Factory and Synapse
# prefix theirs with the service).
MARKER="<!-- opentofu-actions:${COMMENT_KEY} -->"
COMMENT_AUTHOR="${COMMENT_AUTHOR:-github-actions[bot]}"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"
RUN_URL="${REPO_URL}/actions/runs/${GITHUB_RUN_ID:-}"
ENVIRONMENT="${APPLY_ENVIRONMENT:-}"

log_config GITHUB_REPOSITORY PR_NUMBER HEAD_SHA COMMENT_KEY APPLY_STATUS APPLY_ENVIRONMENT

# Runs for older pushes can finish after newer ones (a late approval, a slow
# apply). Leave the comment to the newest push's run instead of overwriting
# its plan with an outdated one.
current_head="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq .head.sha)"
if [ "$current_head" != "$HEAD_SHA" ]; then
  log_warn "PR #${PR_NUMBER} is now at ${current_head:0:7}, newer than this run's ${HEAD_SHA:0:7}; leaving the PR comment to the newer run. This run's result is in its job summary."
  exit 0
fi

# Who approved this run's deployment, for the record. Best effort (needs
# actions: read): the comment is still worth posting without it.
approvers() {
  gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}/approvals" \
    --jq '[.[] | select(.state == "approved") | "@" + .user.login] | unique | join(", ")' 2> /dev/null || true
}

apply_section() {
  case "$APPLY_STATUS" in
    none) ;;
    awaiting-approval)
      if [ -n "$ENVIRONMENT" ]; then
        echo "### 🔒 Apply: awaiting approval"
        echo ""
        echo "Review the plan above, then approve the \`${ENVIRONMENT}\` deployment on the [workflow run](${RUN_URL}) to apply exactly this plan. It's refused if the PR gets new commits, or what it deploys changes on the target branch, first: that push plans again, and its run is the one to approve."
      else
        echo "### 🚀 Apply: running"
        echo ""
        echo "No approval environment is configured, so this plan is being applied automatically by the [workflow run](${RUN_URL})."
      fi
      ;;
    after-merge)
      echo "### ⏭️ Apply: after merge"
      echo ""
      echo "This plan is for review only. Once the PR merges, the target branch is planned again and applied${ENVIRONMENT:+ after approval of the \`${ENVIRONMENT}\` deployment}."
      ;;
    blocked)
      echo "### 🚫 Apply: blocked"
      echo ""
      if [ -n "${BLOCKED_REASON:-}" ]; then
        echo "${BLOCKED_REASON}"
      else
        echo "The policy check failed, so this plan wasn't saved and can't be applied. Fix the violations above and push to plan again."
      fi
      ;;
    succeeded)
      local by
      by="$(approvers)"
      echo "### ✅ Applied"
      echo ""
      echo "This plan was applied by the [workflow run](${RUN_URL})${by:+, approved by ${by}}. Merge the PR to record it on the target branch. If it won't be merged, roll back by running the workflow on the target branch, which re-applies what's there."
      ;;
    failed)
      echo "### ❌ Apply failed"
      echo ""
      echo "See the [workflow run](${RUN_URL}) log. If the apply started, some changes may already be live: fix the problem and push to plan again, or roll back by running the workflow on the target branch. If the plan was refused as out of date, nothing was applied."
      ;;
  esac
}

BODY_FILE="$(mktemp)"
SUMMARY_COPY="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$SUMMARY_COPY"' EXIT

if [ -n "${SUMMARY_FILE:-}" ] && [ -s "$SUMMARY_FILE" ]; then
  cp "$SUMMARY_FILE" "$SUMMARY_COPY"
else
  {
    echo "### ❌ No plan"
    echo ""
    echo "The [workflow run](${RUN_URL}) failed before it produced a plan. See its log."
  } > "$SUMMARY_COPY"
fi

# plan-summary.sh already budgets the plan output, but a huge policy report
# could still push the comment over GitHub's limit
fit_github_body "$SUMMARY_COPY" "the [workflow run](${RUN_URL})'s job summary"

{
  echo "$MARKER"
  echo "## ${TITLE:-Plan}"
  echo ""
  cat "$SUMMARY_COPY"
  section="$(apply_section)"
  if [ -n "$section" ]; then
    echo ""
    echo "$section"
  fi
  # The comment is rewritten by every run, so point readers at GitHub's edit
  # history for earlier plans and apply results
  echo ""
  echo "<sub>📜 This comment is updated in place by every run. For earlier plans and apply results, open the <b>edited</b> menu at the top of this comment.</sub>"
} > "$BODY_FILE"

# The oldest match wins, should two runs ever have raced to create it
comment_id="$(gh_find_by_marker "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" "$COMMENT_AUTHOR" "$MARKER" id)"

payload="$(jq -n --rawfile body "$BODY_FILE" '{body: $body}')"
if [ -n "$comment_id" ]; then
  log_info "Updating comment ${comment_id} on PR #${PR_NUMBER}..."
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" --input - <<< "$payload" > /dev/null
else
  log_info "Creating comment on PR #${PR_NUMBER}..."
  gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --input - <<< "$payload" > /dev/null
fi

log_success "PR #${PR_NUMBER} comment is up to date (apply status: ${APPLY_STATUS})"
