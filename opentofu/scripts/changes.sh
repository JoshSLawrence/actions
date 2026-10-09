#!/usr/bin/env bash
#
# Decides whether this call plans: on pull_request and push runs (with
# CHANGED_ONLY), only if a watched path changed. The workflow always runs --
# a workflow skipped by on.*.paths leaves its required checks pending -- and
# this tells its plan and apply jobs whether to.
#
# Watched, always: the root module directory (every file in it, except other
# deployments' var files: see below), the var files (even outside the
# module), and the calling workflow file, so editing the call runs it.
# EXTRA_PATHS adds directories or globs to these; it can't remove them.
#
# Several calls can share one module, each with its own var files
# (deployments/dev.tfvars, deployments/prod.tfvars): a .tfvars or
# .tfvars.json file in the module that isn't one of this call's var files
# isn't read by its plan, so it doesn't count. The ones OpenTofu loads on its
# own still do, wherever they are in the module (terraform.tfvars,
# *.auto.tfvars and their .json forms: the plan loads them from the module,
# tofu test from tests/).
#
# The watched paths are a list of entries read the way GitHub reads
# on.<event>.paths (path_entry_rule, path_rules_match): directories or
# globs, ! excludes, the last match decides. The same list makes a plan
# stale at apply time (apply-preflight.sh), which reads it the same way.
#
# Environment variables:
#   WORKING_DIR  - the root module (required)
#   VAR_FILES    - var files relative to the module, space- or
#                  newline-separated (optional)
#   EXTRA_PATHS  - more paths to watch, space- or newline-separated:
#                  directories (everything under them) or globs (optional)
#   WORKFLOW_REF - github.workflow_ref: the calling workflow, as
#                  owner/repo/.github/workflows/<file>@<ref> (optional)
#   CHANGED_ONLY - "true" (default) to plan only when a watched path changed
#   EVENT_NAME   - github.event_name
#   BASE_SHA     - base commit of the PR (pull_request runs)
#   BEFORE_SHA   - commit before the push (push runs)
#   HEAD_REF     - commit to diff to (default: HEAD)
#
# Outputs:
#   changed - "true" if this call plans
#   paths   - the watched paths, space-separated, in order, with ! entries
#             (the apply's preflight paths)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool git
require_env WORKING_DIR "Set the working-directory input to the root module."
CHANGED_ONLY="${CHANGED_ONLY:-true}"
HEAD_REF="${HEAD_REF:-HEAD}"
log_config WORKING_DIR VAR_FILES EXTRA_PATHS WORKFLOW_REF CHANGED_ONLY EVENT_NAME BASE_SHA BEFORE_SHA

if ! module="$(normalize_path "$WORKING_DIR")"; then
  log_error "working-directory '${WORKING_DIR}' climbs out of the repository. Use a path relative to the repository root."
  exit 1
fi

# --- What's watched --------------------------------------------------------------

# In order: the last entry that matches a path decides (path_rules_match)
watched=("$module")

# Other deployments' var files in the module don't count; the ones OpenTofu
# loads on its own do. Every entry is a glob under the module ("**/" also
# matches the module itself).
prefix="${module}/"
[ "$module" = "." ] && prefix=""
watched+=("!${prefix}**/*.tfvars" "!${prefix}**/*.tfvars.json")
for auto in terraform.tfvars terraform.tfvars.json '*.auto.tfvars' '*.auto.tfvars.json'; do
  watched+=("${prefix}**/${auto}")
done

# This call's var files count, after the exclusions above
while IFS= read -r var_file; do
  if path="$(normalize_path "${module}/${var_file}")"; then
    watched+=("$path")
  else
    log_warn "var-files entry '${var_file}' climbs out of the repository, so changes to it aren't watched. Use a path inside the repository."
  fi
done < <(list_items "${VAR_FILES:-}")

# owner/repo/.github/workflows/x.yaml@refs/heads/main -> .github/workflows/x.yaml
# It's the run's top-level workflow: a call made from a caller's own reusable
# workflow watches the top-level file, not that one (extra-paths can add it).
workflow="${WORKFLOW_REF:-}"
workflow="${workflow%%@*}"
if [ -n "$workflow" ]; then
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [[ "$workflow" == "${GITHUB_REPOSITORY}/"* ]]; then
    workflow="${workflow#"${GITHUB_REPOSITORY}/"}"
  else
    workflow="$(cut -d/ -f3- <<< "$workflow")"
  fi
  watched+=("$workflow")
fi

# Last, so an extra path can watch another var file again. A ! entry would
# remove what's watched, which extra-paths can't.
while IFS= read -r entry; do
  if [[ "$entry" == '!'* ]]; then
    log_error "extra-paths entry '${entry}' starts with !, but extra-paths only adds paths to watch. Remove the entry."
    exit 1
  fi
  if ! path_entry_regex "$entry" > /dev/null; then
    log_error "extra-paths entry '${entry}' climbs out of the repository. Use paths relative to the repository root."
    exit 1
  fi
  watched+=("$entry")
done < <(list_items "${EXTRA_PATHS:-}")

rules=()
for entry in "${watched[@]}"; do
  if ! rule="$(path_entry_rule "$entry")"; then
    log_error "Watched path '${entry}' climbs out of the repository. Check working-directory and var-files are relative to the repository root and the module."
    exit 1
  fi
  rules+=("$rule")
done

set_output paths "${watched[*]}"
log_info "Watched: ${watched[*]}"

# Succeed if a changed file is one of the watched paths
is_watched() {
  path_rules_match "$1" "${rules[@]+"${rules[@]}"}"
}

# --- Decide ----------------------------------------------------------------------

# Usage: decide true|false "<why>"
decide() {
  set_output changed "$1"
  if [ "$1" = true ]; then
    log_success "Planning: $2"
  else
    log_notice "Not planning: $2"
  fi
  echo "**Change detection:** $([ "$1" = true ] && echo "plans" || echo "skips plan and apply"): $2" | append_step_summary
}

base=""
if ! is_true "$CHANGED_ONLY"; then
  decide true "changed-only is off"
  exit 0
elif [ "${EVENT_NAME:-}" = "pull_request" ] && [ -n "${BASE_SHA:-}" ]; then
  base="$BASE_SHA"
elif [ "${EVENT_NAME:-}" = "push" ] && [ -n "${BEFORE_SHA:-}" ] && [[ ! "$BEFORE_SHA" =~ ^0+$ ]]; then
  base="$BEFORE_SHA"
else
  decide true "${EVENT_NAME:-this} runs always plan"
  exit 0
fi

if ! changed="$(git diff --name-only --no-renames "$base" "$HEAD_REF" 2>&1)"; then
  log_warn "Couldn't diff ${base:0:7}..${HEAD_REF} (${changed##*$'\n'}), so this call plans. Check out with fetch-depth: 0."
  decide true "the diff couldn't be computed"
  exit 0
fi

while IFS= read -r file; do
  [ -z "$file" ] && continue
  if is_watched "$file"; then
    decide true "${file} changed"
    exit 0
  fi
done <<< "$changed"

decide false "nothing watched changed (${watched[*]})"
