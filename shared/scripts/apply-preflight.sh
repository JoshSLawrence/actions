#!/usr/bin/env bash
#
# Refuses to apply a plan that no longer describes what would merge. Runs
# after the approval and before anything is applied: an approval can come
# hours or days after the plan, and nothing else notices the code moved on
# (OpenTofu only rejects a saved plan when the *state* changed; an ARM
# deployment never does). Used by every area's apply action. So check that:
#
#   - (PR runs) the PR is still open and has no newer commits: a newer push
#     has its own plan, which is the one to review and approve, and
#   - none of PREFLIGHT_PATHS changed on the target branch since the plan:
#     applying would undo whatever merged there.
#
# The changes come from the compare API, which lists at most 300 files; with
# that many it lists them with git instead, which needs the job's checkout
# (its origin remote; shallow is fine). The fetch is filtered (no blobs), which
# turns the checkout into a partial clone with origin as its promisor remote;
# that's harmless this late in a job.
#
# Environment variables:
#   GH_TOKEN          - token for the GitHub API (contents: read and
#                       pull-requests: read)
#   GITHUB_REPOSITORY - owner/name
#   TARGET_BRANCH     - branch the change lands on (e.g. main)
#   TARGET_SHA        - commit of TARGET_BRANCH the plan was made against
#   PREFLIGHT_PATHS   - what the plan depends on, space- or newline-separated:
#                       directories (the root module or factory/workspace
#                       folder; "." means any change) and/or globs such as
#                       "modules/**" (required)
#   PR_NUMBER, HEAD_SHA - the PR and the head commit that was planned (PR
#                       runs only)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
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
  regex="$(path_entry_regex "$entry")" || {
    log_error "preflight-paths entry '${entry}' climbs out of the repository. Use repository-relative paths."
    exit 1
  }
  regexes+=("$regex")
done < <(list_items "$PREFLIGHT_PATHS")

# Files changed on TARGET_BRANCH since TARGET_SHA, from git. For when the
# compare API's list is cut off: needs the checkout's origin remote, and no
# history beyond the two commits, so shallow checkouts work. The token goes
# in a one-off header (never in the URL or the log) because checkout runs
# with persist-credentials: false.
# Needs git_auth (the encoded token), set and masked by the caller: this runs
# in a command substitution, where a mask command would be captured as output.
# Usage: git_changed_files   (prints one path per line; fails if git can't)
git_changed_files() {
  local depth=()
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    depth=(--depth=1)
  fi
  # The header goes through the environment, scoped to this one command, so
  # it isn't on a command line
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${git_auth}" \
    git fetch --quiet --no-tags --filter=blob:none "${depth[@]+"${depth[@]}"}" \
    origin "$TARGET_SHA" "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" || return 1
  git diff --name-only --no-renames "$TARGET_SHA" "origin/${TARGET_BRANCH}"
}

log_info "Checking ${PREFLIGHT_PATHS//$'\n'/, } hasn't changed on ${TARGET_BRANCH} since ${TARGET_SHA:0:7}..."
comparison="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${TARGET_SHA}...${TARGET_BRANCH}")"
ahead_by="$(jq -r .ahead_by <<< "$comparison")"
file_count="$(jq -r '.files | length' <<< "$comparison")"
file_list="$(jq -r '.files[]?.filename' <<< "$comparison")"

# The compare API lists at most 300 files: with more, a relevant change could
# be missing from the list. Ask git for the full list instead; only if that
# fails is it too much to be sure either way.
if [ "$file_count" -ge 300 ]; then
  log_info "The compare API lists at most 300 files (${file_count} here); listing the changes with git instead..."
  # The encoded value is as good as the token itself
  git_auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  mask_value "$git_auth"
  set +e
  git_stderr="$(mktemp)"
  file_list="$(git_changed_files 2> "$git_stderr")"
  git_exit=$?
  set -e
  git_error="$(cat "$git_stderr")"
  rm -f "$git_stderr"
  if [ "$git_exit" -ne 0 ]; then
    if [ -n "$git_error" ]; then
      git_error="${git_error//"$GH_TOKEN"/***}"
      git_error="${git_error//"$git_auth"/***}"
      log_warn "git said: ${git_error}"
    fi
    log_error "${TARGET_BRANCH} has changed too much since this plan (${ahead_by} commits, ${file_count}+ files) to check what it deploys is unaffected, and git couldn't list the changes (the job needs a checkout with an origin remote and a token that can read it). ${RERUN_HINT}"
    exit 1
  fi
fi

changed_files=()
while IFS= read -r file; do
  [ -z "$file" ] && continue
  for regex in "${regexes[@]}"; do
    if [[ "$file" =~ $regex ]]; then
      changed_files+=("$file")
      break
    fi
  done
done <<< "$file_list"
changed="$(printf '%s\n' "${changed_files[@]+"${changed_files[@]}"}" | sed '/^$/d' | sort -u | paste -sd, - | sed 's/,/, /g')"

if [ -n "$changed" ]; then
  log_error "Files this plan depends on changed on ${TARGET_BRANCH} since it was made (${changed}). Applying it would revert those changes. ${RERUN_HINT} (If those paths don't affect what this deploys, narrow the preflight-paths input.)"
  exit 1
fi

log_success "Plan is still current (${TARGET_BRANCH} is ${ahead_by} commit(s) ahead, none touching what it deploys)"
