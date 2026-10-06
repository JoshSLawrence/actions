#!/usr/bin/env bash
#
# Checks the workflow's inputs before anything else runs, so a mistake fails
# the run at the start, with every problem listed at once and what to do
# about each, instead of a job failing halfway through. Tool pins and
# environments are checked by their own steps (shared/setup with install
# false, require-environments.sh).
#
# Environment variables (the workflow's inputs):
#   WORKING_DIR, VAR_FILES, NAME, APPLY_ENVIRONMENT, EXTRA_PATHS
#   CHECKS, TESTS, TEST_FILTER, INTEGRATION_TESTS, INTEGRATION_TEST_FILTER
#   POLICY, POLICY_PATH, POLICY_SOURCE, COST_ESTIMATE
#   AZURE_CLIENT_ID, AZURE_TENANT_ID, PLAN_AZURE_CLIENT_ID
#   INTEGRATION_TEST_RUNS_ON, PLAN_RUNS_ON, APPLY_RUNS_ON
#   HAS_INFRACOST_API_KEY, HAS_AZURE_CLIENT_SECRET,
#   HAS_PLAN_AZURE_CLIENT_SECRET
#                 - "true" if that secret was passed
#   IS_FORK_PR    - "true" on a pull request from a fork, which gets no
#                   secrets and isn't planned: secret rules are skipped
#   IS_DEPENDABOT - "true" on a pull request run by Dependabot, which gets
#                   no Actions secrets or OIDC token either: the same
#
# Outputs:
#   name - NAME, or the last var file's name without .tfvars (empty without
#          var files): the call's label in titles and names
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

log_config WORKING_DIR VAR_FILES NAME APPLY_ENVIRONMENT EXTRA_PATHS CHECKS TESTS TEST_FILTER \
  INTEGRATION_TESTS INTEGRATION_TEST_FILTER POLICY POLICY_PATH POLICY_SOURCE COST_ESTIMATE \
  AZURE_CLIENT_ID AZURE_TENANT_ID PLAN_AZURE_CLIENT_ID INTEGRATION_TEST_RUNS_ON PLAN_RUNS_ON \
  APPLY_RUNS_ON IS_FORK_PR IS_DEPENDABOT

problems=()
problem() {
  problems+=("$1")
}

# Succeed if every glob in a list matches at least one file in a directory;
# add a problem for each one that doesn't. Usage: filter_matches <dir> <input> <globs>
filter_matches() {
  local dir="$1" input="$2" pattern
  while IFS= read -r pattern; do
    if ! (cd "$dir" && compgen -G "$pattern" > /dev/null); then
      problem "${input}: '${pattern}' matches no file in ${dir}. Paths are relative to the root module."
    fi
  done < <(list_items "$3")
}

# --- The root module and its var files -----------------------------------------

module_ok=false
if [ -z "${WORKING_DIR:-}" ]; then
  problem "working-directory is empty. Set it to the root module, relative to the repository root."
elif ! module="$(normalize_path "$WORKING_DIR")"; then
  problem "working-directory '${WORKING_DIR}' climbs out of the repository. Use a path relative to the repository root."
elif [ ! -d "$module" ]; then
  problem "working-directory '${module}' doesn't exist. It's relative to the repository root."
else
  module_ok=true
  if ! compgen -G "${module}/*.tf" > /dev/null; then
    problem "working-directory '${module}' has no .tf files. Point it at the root module itself."
  fi
  if [ ! -f "${module}/mise.toml" ] && [ ! -f "${module}/.mise.toml" ]; then
    problem "'${module}' has no mise.toml. Every root module pins its own tools: run 'mise use opentofu@<version>' there."
  fi
fi

last_var_file=""
while IFS= read -r var_file; do
  last_var_file="$var_file"
  if [ "$module_ok" = true ] && [ ! -f "${module}/${var_file}" ]; then
    problem "var-files: '${var_file}' doesn't exist in ${module}. Var files are relative to the root module."
  fi
done < <(list_items "${VAR_FILES:-}")

while IFS= read -r entry; do
  if ! path_entry_regex "$entry" > /dev/null; then
    problem "extra-paths: '${entry}' climbs out of the repository. Use paths relative to the repository root."
  fi
done < <(list_items "${EXTRA_PATHS:-}")

# --- Name and environments -------------------------------------------------------

name="${NAME:-}"
if [ -z "$name" ] && [ -n "$last_var_file" ]; then
  name="$(basename "$last_var_file")"
  name="${name%.json}"
  name="${name%.tfvars}"
fi
if [ -n "$name" ] && ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  if [ -n "${NAME:-}" ]; then
    problem "name '${name}' can't be used in names: use letters, digits, '.', '_' and '-'."
  else
    problem "The name taken from '${last_var_file}' ('${name}') can't be used in names. Set the name input (letters, digits, '.', '_', '-')."
  fi
fi

if [ -z "${APPLY_ENVIRONMENT:-}" ]; then
  problem "apply-environment is empty. Set it to the GitHub environment the apply job runs in (with required reviewers)."
fi

# --- Checks and tests ------------------------------------------------------------

if [ "$module_ok" = true ]; then
  if is_true "${CHECKS:-true}" && is_true "${TESTS:-true}" && [ -n "${TEST_FILTER:-}" ]; then
    filter_matches "$module" test-filter "$TEST_FILTER"
  fi
  if is_true "${INTEGRATION_TESTS:-false}" && [ -n "${INTEGRATION_TEST_FILTER:-}" ]; then
    filter_matches "$module" integration-test-filter "$INTEGRATION_TEST_FILTER"
  fi
fi

# --- Plan: policy and cost -------------------------------------------------------

# Every policy-path directory is used, policy-source or not: the default
# (policy) has to exist too, unless the caller empties policy-path
if is_true "${POLICY:-false}"; then
  policy_paths="$(list_items "${POLICY_PATH:-}")"
  if [ -z "$policy_paths" ] && [ -z "${POLICY_SOURCE:-}" ]; then
    problem "policy is on, but neither policy-path nor policy-source is set. Point policy-path at your policies, or policy-source at a URL."
  fi
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ ! -d "$path" ]; then
      problem "policy-path: '${path}' doesn't exist. It's relative to the repository root. To use only policy-source, set policy-path to \"\"."
    fi
  done <<< "$policy_paths"
fi

# Runs that get no secrets or OIDC token: checked, never planned
secrets_skipped=""
if is_true "${IS_FORK_PR:-false}"; then
  secrets_skipped="Pull request from a fork"
elif is_true "${IS_DEPENDABOT:-false}"; then
  secrets_skipped="Dependabot pull request"
fi
if [ -z "$secrets_skipped" ] && is_true "${COST_ESTIMATE:-false}" && ! is_true "${HAS_INFRACOST_API_KEY:-false}"; then
  problem "cost-estimate is on, but the infracost-api-key secret isn't passed. Pass it under secrets:, or turn cost-estimate off."
fi

# --- Azure -----------------------------------------------------------------------

if [ -n "$secrets_skipped" ]; then
  # A fork's (or Dependabot's) run gets no secrets, so only the inputs can be checked
  azure="$(HAS_AZURE_CLIENT_SECRET=false HAS_PLAN_AZURE_CLIENT_SECRET=false azure_input_problems)"
else
  azure="$(azure_input_problems)"
fi
while IFS= read -r line; do
  [ -n "$line" ] && problem "$line"
done <<< "$azure"

# --- Runners ---------------------------------------------------------------------

# Checked here, or GitHub only refuses one when its job starts, after the
# checks. Empty: the job runs on runs-on, which needs no check (this job
# runs on it).
check_runs_on() {
  local found
  if [ -n "$2" ]; then
    found="$(runs_on_problem "$1" "$2")"
    if [ -n "$found" ]; then
      problem "$found"
    fi
  fi
}
check_runs_on integration-test-runs-on "${INTEGRATION_TEST_RUNS_ON:-}"
check_runs_on plan-runs-on "${PLAN_RUNS_ON:-}"
check_runs_on apply-runs-on "${APPLY_RUNS_ON:-}"

# --- Result ----------------------------------------------------------------------

if [ -n "$secrets_skipped" ]; then
  log_notice "${secrets_skipped}: no secrets or OIDC token, so nothing is planned and the rules about secrets aren't checked. The push after merge plans it."
fi
if [ ${#problems[@]} -gt 0 ]; then
  for p in "${problems[@]}"; do
    log_error "$p"
  done
  log_error "${#problems[@]} problem(s) with the inputs; nothing else runs until they're fixed."
  exit 1
fi

set_output name "$name"
log_success "Inputs are consistent${name:+ (name: ${name})}"
