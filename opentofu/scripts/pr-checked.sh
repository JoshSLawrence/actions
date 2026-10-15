#!/usr/bin/env bash
#
# Decides whether a push to the default branch skips the checks and the
# integration tests (checks-on-push: false) because the PR it merged already
# ran them on the same content. It skips only when all of these hold, and
# runs them otherwise:
#
# - the pushed commit is a PR's merge into the default branch (its
#   merge_commit_sha: a merge, squash or rebase merge), not a direct push;
# - the PR's latest run of the calling workflow on its head commit
#   succeeded;
# - every watched path (changes.sh's list) has the same content in the
#   pushed commit as in the PR's head commit, compared by blob SHA. A PR
#   merged while behind the default branch, which changed a watched path
#   since, merges content the PR never checked, so that push checks.
#
# The integration tests are skipped only if the PR could run them: PRs from
# forks and Dependabot get no OIDC token or secrets, so their merge runs
# them.
#
# Environment variables:
#   CHECKS_ON_PUSH    - "false" to skip what the PR already ran (default:
#                       true, which always runs them)
#   EVENT_NAME        - github.event_name
#   REF               - github.ref
#   DEFAULT_BRANCH    - the repository's default branch
#   SHA               - the pushed commit (github.sha)
#   PATHS             - the watched paths, in order, with ! entries
#                       (changes.sh's paths output)
#   GITHUB_REPOSITORY - owner/name
#   GITHUB_RUN_ID     - this run, to find its workflow
#   GH_TOKEN          - token for the GitHub API (contents, pull-requests and
#                       actions: read)
#
# Outputs:
#   skip-checks            - "true" to skip the checks job
#   skip-integration-tests - "true" to skip the integration tests
#   pr                     - the merged PR's number, when they're skipped
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

CHECKS_ON_PUSH="${CHECKS_ON_PUSH:-true}"
log_config CHECKS_ON_PUSH EVENT_NAME REF DEFAULT_BRANCH SHA PATHS

# Usage: decide <skip-checks> <skip-integration-tests>
decide() {
  set_output skip-checks "$1"
  set_output skip-integration-tests "$2"
}

if is_true "$CHECKS_ON_PUSH"; then
  decide false false
  exit 0
fi
if [ "${EVENT_NAME:-}" != push ] || [ "${REF:-}" != "refs/heads/${DEFAULT_BRANCH:-}" ]; then
  log_info "Not a push to the default branch, so the checks run"
  decide false false
  exit 0
fi

require_tool gh "GitHub CLI (gh)"
require_tool jq
require_env GH_TOKEN
require_env GITHUB_REPOSITORY
require_env GITHUB_RUN_ID
require_env SHA

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Usage: run_checks "<why>"
run_checks() {
  decide false false
  log_notice "Running the checks on this push: $1"
  echo "**checks-on-push:** runs the checks: $1" | append_step_summary
  exit 0
}

# Usage: api <file> <path>   (the response into WORK_DIR/<file>)
api() {
  gh api "$2" > "$WORK_DIR/$1" 2> "$WORK_DIR/error"
}

# --- The merged PR -------------------------------------------------------------

if ! api pulls.json "repos/${GITHUB_REPOSITORY}/commits/${SHA}/pulls"; then
  log_warn "Couldn't list the PRs of ${SHA:0:7}: $(tail -n 1 "$WORK_DIR/error"). Give the job pull-requests: read."
  run_checks "its PR couldn't be looked up"
fi
jq --arg sha "$SHA" --arg branch "$DEFAULT_BRANCH" \
  '[.[] | select(.merged_at != null and .merge_commit_sha == $sha and .base.ref == $branch)] | first // empty' \
  "$WORK_DIR/pulls.json" > "$WORK_DIR/pr.json"
if ! [ -s "$WORK_DIR/pr.json" ]; then
  run_checks "${SHA:0:7} isn't a PR's merge (a direct push)"
fi
pr="$(jq -r .number "$WORK_DIR/pr.json")"
head="$(jq -r .head.sha "$WORK_DIR/pr.json")"

# --- Its run passed -------------------------------------------------------------

if ! api run.json "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" ||
  ! api runs.json "repos/${GITHUB_REPOSITORY}/actions/workflows/$(jq -r .workflow_id "$WORK_DIR/run.json")/runs?event=pull_request&head_sha=${head}"; then
  log_warn "Couldn't list the runs of PR #${pr}: $(tail -n 1 "$WORK_DIR/error"). Give the job actions: read."
  run_checks "PR #${pr}'s runs couldn't be listed"
fi
conclusion="$(jq -r '.workflow_runs | sort_by(.created_at) | last | .conclusion // "none"' "$WORK_DIR/runs.json")"
if [ "$conclusion" != success ]; then
  run_checks "PR #${pr}'s latest run on ${head:0:7} didn't succeed (${conclusion})"
fi

# --- The same content -----------------------------------------------------------

for commit in "$head" "$SHA"; do
  if ! api "tree-${commit}.json" "repos/${GITHUB_REPOSITORY}/git/trees/${commit}?recursive=1"; then
    log_warn "Couldn't read the tree of ${commit:0:7}: $(tail -n 1 "$WORK_DIR/error")."
    run_checks "the tree of ${commit:0:7} couldn't be read"
  fi
  if [ "$(jq -r .truncated "$WORK_DIR/tree-${commit}.json")" = true ]; then
    run_checks "the repository is too large to compare through the API"
  fi
done

rules=()
while IFS= read -r entry; do
  rules+=("$(path_entry_rule "$entry")")
done < <(list_items "${PATHS:-}")

# Paths whose content differs, or that only one commit has
differ="$(jq -rn --slurpfile a "$WORK_DIR/tree-${head}.json" --slurpfile b "$WORK_DIR/tree-${SHA}.json" '
  def blobs($t): [$t.tree[] | select(.type != "tree") | {key: .path, value: .sha}] | from_entries;
  ($a[0] | blobs(.)) as $x | ($b[0] | blobs(.)) as $y
  | ($x + $y | keys[]) | select($x[.] != $y[.])')"
while IFS= read -r file; do
  [ -z "$file" ] && continue
  if path_rules_match "$file" "${rules[@]+"${rules[@]}"}"; then
    run_checks "${file} differs from PR #${pr}'s head ${head:0:7} (the default branch changed it after the PR branched)"
  fi
done <<< "$differ"

# --- Skip -----------------------------------------------------------------------

set_output pr "$pr"
log_success "PR #${pr} checked this content: its run on ${head:0:7} passed, and nothing watched differs. Skipping the checks."
what="the checks"
if [ "$(jq -r '.head.repo.full_name // ""' "$WORK_DIR/pr.json")" != "$GITHUB_REPOSITORY" ] ||
  [ "$(jq -r .user.login "$WORK_DIR/pr.json")" = "dependabot[bot]" ]; then
  log_info "PR #${pr} is from a fork or Dependabot, which can't run integration tests, so they run here"
  decide true false
else
  decide true true
  what="the checks and integration tests"
fi
echo "**checks-on-push:** skips ${what}: PR #${pr} ran them on the same content (${head:0:7})" | append_step_summary
