#!/usr/bin/env bash
#
# Decides whether a push to the default branch skips the checks and the
# integration tests (checks-on-push). always runs them; never skips them;
# unchecked skips them only when the PR the push merged already ran them on
# the same content, which is when all of these hold:
#
# - the pushed commit is a PR's merge into the default branch (its
#   merge_commit_sha: a merge, squash or rebase merge), not a direct push;
# - the PR's latest run of the calling workflow on its head commit
#   succeeded;
# - in that run, this same call's checks job concluded success (not
#   skipped) to skip the checks, and its integration-tests job to skip the
#   integration tests: each is decided on its own;
# - every watched path (changes.sh's list) has the same content in the
#   pushed commit as in the PR's head commit, compared by blob SHA. A PR
#   merged while behind the default branch, which changed a watched path
#   since, merges content the PR never checked, so that push checks.
#
# The integration tests are skipped only if the PR could run them: PRs from
# forks and Dependabot get no OIDC token or secrets, so their merge runs
# them.
#
# A reusable workflow's jobs show in the caller's run as "<caller job> /
# <job name>" (e.g. "prod / Checks"; nested calls add more prefixes). This
# job's own name, read through JOB_CHECK_RUN_ID, ends in " / Prepare"; the
# rest names the call, the same in the PR's run as long as the caller's job
# name doesn't depend on the event. The job names Prepare, Checks and
# Integration tests are opentofu.yaml's. Anything this can't establish runs
# the checks.
#
# Not detected: a caller that references the workflow by a ref that moved
# between the PR's run and the push (uses: ...@v1), and inputs that differ
# between them (e.g. an expression on github.event_name): the PR's jobs
# ran, but maybe not the same checks. Pin a commit SHA or a tag you don't
# move, and give both events the same inputs, or keep checks-on-push always.
#
# Environment variables:
#   CHECKS_ON_PUSH    - always (default), never or unchecked
#   EVENT_NAME        - github.event_name
#   REF               - github.ref
#   DEFAULT_BRANCH    - the repository's default branch
#   SHA               - the pushed commit (github.sha)
#   PATHS             - the watched paths, in order, with ! entries
#                       (changes.sh's paths output)
#   GITHUB_REPOSITORY - owner/name
#   GITHUB_RUN_ID     - this run, to find its workflow
#   JOB_CHECK_RUN_ID  - this job's check run ID (job.check_run_id), to find
#                       which call this is. Empty: the checks run.
#   GH_TOKEN          - token for the GitHub API (contents, pull-requests and
#                       actions: read)
#
# Outputs:
#   skip-checks            - "true" to skip the checks job
#   skip-integration-tests - "true" to skip the integration tests
#   note                   - what was skipped and why, when anything was
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

CHECKS_ON_PUSH="${CHECKS_ON_PUSH:-always}"
log_config CHECKS_ON_PUSH EVENT_NAME REF DEFAULT_BRANCH SHA PATHS JOB_CHECK_RUN_ID

# Usage: decide <skip-checks> <skip-integration-tests>
decide() {
  set_output skip-checks "$1"
  set_output skip-integration-tests "$2"
}

# Usage: skip <skip-checks> <skip-integration-tests> "<note>"
skip() {
  decide "$1" "$2"
  set_output note "$3"
  log_notice "$3"
  echo "**checks-on-push:** $3" | append_step_summary
  exit 0
}

if [ "$CHECKS_ON_PUSH" = always ]; then
  decide false false
  exit 0
fi
if [ "${EVENT_NAME:-}" != push ] || [ "${REF:-}" != "refs/heads/${DEFAULT_BRANCH:-}" ]; then
  log_info "Not a push to the default branch, so the checks run"
  decide false false
  exit 0
fi
if [ "$CHECKS_ON_PUSH" = never ]; then
  skip true true "checks-on-push is never, so this push skipped the checks and integration tests."
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

# Every page of a list (the pages one after another: read with jq -s)
# Usage: api_pages <file> <path>
api_pages() {
  gh api --paginate "$2" > "$WORK_DIR/$1" 2> "$WORK_DIR/error"
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
pr_run="$(jq -r '.workflow_runs | sort_by(.created_at) | last | .id' "$WORK_DIR/runs.json")"

# --- Which of this call's jobs it ran -------------------------------------------

# A run can succeed without running the checks or the integration tests
# (they're skipped when off, or by an input that depends on the event), so
# each is skipped only if this call's job in that run concluded success

if [ -z "${JOB_CHECK_RUN_ID:-}" ]; then
  log_warn "job.check_run_id is empty, so this call's jobs can't be found in PR #${pr}'s run. Check the prepare action passes it."
  run_checks "this call's jobs couldn't be found in PR #${pr}'s run"
fi
if ! api job.json "repos/${GITHUB_REPOSITORY}/actions/jobs/${JOB_CHECK_RUN_ID}"; then
  log_warn "Couldn't read this job's name: $(tail -n 1 "$WORK_DIR/error"). Give the job actions: read."
  run_checks "this call's jobs couldn't be found in PR #${pr}'s run"
fi
own_name="$(jq -r '.name // ""' "$WORK_DIR/job.json")"
if [[ "$own_name" != *" / Prepare" ]]; then
  run_checks "this job's name ('${own_name}') isn't a call's '<job> / Prepare', so its jobs can't be found in PR #${pr}'s run"
fi
call="${own_name% / Prepare}"

if ! api_pages jobs.json "repos/${GITHUB_REPOSITORY}/actions/runs/${pr_run}/jobs?filter=latest&per_page=100"; then
  log_warn "Couldn't list the jobs of PR #${pr}'s run: $(tail -n 1 "$WORK_DIR/error"). Give the job actions: read."
  run_checks "PR #${pr}'s jobs couldn't be listed"
fi

# The conclusion of the PR run's job of this call with that name; none
# unless exactly one job has it
# Usage: pr_job <job name>
pr_job() {
  jq -rs --arg name "${call} / $1" \
    '[.[].jobs[] | select(.name == $name)] | if length == 1 then .[0].conclusion // "none" else "none" end' \
    "$WORK_DIR/jobs.json"
}
checks_job="$(pr_job Checks)"
tests_job="$(pr_job "Integration tests")"
log_info "PR #${pr}'s run of '${call}': checks ${checks_job}, integration tests ${tests_job}"
if [ "$checks_job" != success ] && [ "$tests_job" != success ]; then
  run_checks "PR #${pr}'s run on ${head:0:7} ran neither the checks (${checks_job}) nor the integration tests (${tests_job})"
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

# PRs from forks and Dependabot couldn't run the integration tests
if [ "$(jq -r '.head.repo.full_name // ""' "$WORK_DIR/pr.json")" != "$GITHUB_REPOSITORY" ] ||
  [ "$(jq -r .user.login "$WORK_DIR/pr.json")" = "dependabot[bot]" ]; then
  if [ "$checks_job" != success ]; then
    run_checks "PR #${pr}'s run on ${head:0:7} didn't run the checks (${checks_job}), and its integration tests can't have run (a fork's or Dependabot's PR)"
  fi
  skip true false "PR #${pr} checked the same content (${head:0:7}), so this push skipped the checks. It's from a fork or Dependabot, which can't run integration tests, so they run here."
fi
if [ "$checks_job" != success ]; then
  skip false true "PR #${pr} ran the integration tests on the same content (${head:0:7}), so this push skipped them; not the checks, which that run didn't run (${checks_job})."
fi
if [ "$tests_job" != success ]; then
  skip true false "PR #${pr} checked the same content (${head:0:7}), so this push skipped the checks; not the integration tests, which that run didn't run (${tests_job})."
fi
skip true true "PR #${pr} checked the same content (${head:0:7}), so this push skipped the checks and integration tests."
