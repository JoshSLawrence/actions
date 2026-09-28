#!/usr/bin/env bash
#
# Refuses to apply a plan that no longer describes what would merge. Runs
# after the approval and before anything is applied: an approval can come
# hours or days after the plan, and OpenTofu only rejects a saved plan when
# the *state* changed since -- not when the code did. So check that:
#
#   - (PR runs) the PR is still open and has no newer commits: a newer push
#     has its own plan, which is the one to review and approve, and
#   - none of PREFLIGHT_PATHS changed on the target branch since the plan:
#     applying would undo whatever merged there.
#
# Environment variables:
#   GH_TOKEN          - token for the GitHub API (contents: read and
#                       pull-requests: read)
#   GITHUB_REPOSITORY - owner/name
#   TARGET_BRANCH     - branch the change lands on (e.g. main)
#   TARGET_SHA        - commit of TARGET_BRANCH the plan was made against
#   PREFLIGHT_PATHS   - what the plan depends on, space- or newline-separated:
#                       directories (the root module, local modules outside
#                       it; "." means any change) and/or globs such as
#                       "modules/**" (required)
#   PR_NUMBER, HEAD_SHA - the PR and the head commit that was planned (PR
#                       runs only)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool gh "GitHub CLI (gh)"
require_tool jq
require_env GH_TOKEN
require_env GITHUB_REPOSITORY
require_env TARGET_BRANCH
require_env TARGET_SHA
require_env PREFLIGHT_PATHS "Set the preflight-paths input (the reusable workflow defaults it to the working directory)."

log_config GITHUB_REPOSITORY PR_NUMBER HEAD_SHA TARGET_BRANCH TARGET_SHA PREFLIGHT_PATHS

if [ -n "${PR_NUMBER:-}" ]; then
  RERUN_HINT="Update the PR branch with ${TARGET_BRANCH} (or push a commit) to plan again, then approve that run instead."
else
  RERUN_HINT="Run the workflow on ${TARGET_BRANCH} again to plan its current state."
fi

if [ -n "${PR_NUMBER:-}" ]; then
  require_env HEAD_SHA
  log_info "Checking PR #${PR_NUMBER} is open and still at ${HEAD_SHA:0:7}..."
  pr="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")"
  state="$(jq -r .state <<< "$pr")"
  current_head="$(jq -r .head.sha <<< "$pr")"

  if [ "$state" != "open" ]; then
    log_error "PR #${PR_NUMBER} is ${state}; plans are only applied from open PRs. To apply what's on ${TARGET_BRANCH}, run the workflow on ${TARGET_BRANCH}."
    exit 1
  fi
  if [ "$current_head" != "$HEAD_SHA" ]; then
    log_error "PR #${PR_NUMBER} has moved on to ${current_head:0:7} since this plan (${HEAD_SHA:0:7}). Approve the newer run's apply instead: its plan includes the new commits."
    exit 1
  fi
  log_success "PR #${PR_NUMBER} is open and unchanged"
fi

# Each entry is a directory (everything under it counts) or a glob
regexes=()
while IFS= read -r entry; do
  if [[ "$entry" == *[*?]* ]]; then
    regexes+=("$(glob_to_regex "${entry#./}")")
  else
    dir="$(normalize_path "$entry")" || {
      log_error "preflight-paths entry '${entry}' climbs out of the repository. Use repository-relative paths."
      exit 1
    }
    regexes+=("$(dir_regex "$dir")")
  fi
done < <(list_items "$PREFLIGHT_PATHS")

log_info "Checking ${PREFLIGHT_PATHS//$'\n'/, } hasn't changed on ${TARGET_BRANCH} since ${TARGET_SHA:0:7}..."
comparison="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${TARGET_SHA}...${TARGET_BRANCH}")"
ahead_by="$(jq -r .ahead_by <<< "$comparison")"
file_count="$(jq -r '.files | length' <<< "$comparison")"
changed_files=()
while IFS= read -r file; do
  for regex in "${regexes[@]}"; do
    if [[ "$file" =~ $regex ]]; then
      changed_files+=("$file")
      break
    fi
  done
done < <(jq -r '.files[]?.filename' <<< "$comparison")
changed="$(printf '%s\n' "${changed_files[@]+"${changed_files[@]}"}" | sed '/^$/d' | sort -u | paste -sd, - | sed 's/,/, /g')"

# The compare API lists at most 300 files: with more, a relevant change could
# be missing from the list. Too much has changed to be sure either way.
if [ "$file_count" -ge 300 ]; then
  log_error "${TARGET_BRANCH} has changed too much since this plan (${ahead_by} commits, ${file_count}+ files) to check the module is unaffected. ${RERUN_HINT}"
  exit 1
fi
if [ -n "$changed" ]; then
  log_error "Files this plan depends on changed on ${TARGET_BRANCH} since it was made (${changed}). Applying it would revert those changes. ${RERUN_HINT} (If those paths don't affect the module, narrow the preflight-paths input.)"
  exit 1
fi

log_success "Plan is still current (${TARGET_BRANCH} is ${ahead_by} commit(s) ahead, none touching the module)"
