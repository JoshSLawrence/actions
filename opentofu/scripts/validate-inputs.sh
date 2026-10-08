#!/usr/bin/env bash
#
# Checks the workflow's inputs before anything else runs, so a mistake fails
# the run at the start, with every problem listed at once and what to do
# about each, instead of a job failing halfway through. Tool pins and
# environments are checked by their own steps (shared/setup with install
# false, require-environments.sh).
#
# Environment variables (the workflow's inputs):
#   DRIFT         - "true" for the drift workflow, which has no apply job:
#                   APPLY_ENVIRONMENT isn't required, and PLAN_ENVIRONMENT is
#                   the drift job's environment (optional). Also read in
#                   this mode: ISSUES and ISSUE_LABELS.
#   WORKING_DIR, VAR_FILES, NAME, APPLY_ENVIRONMENT, EXTRA_PATHS
#   CHECKS, TESTS, TEST_FILTER, INTEGRATION_TESTS, INTEGRATION_TEST_FILTER
#   POLICY, POLICY_PATH, POLICY_SOURCE, COST_ESTIMATE
#   AZURE_CLIENT_ID, AZURE_TENANT_ID, PLAN_AZURE_CLIENT_ID, PLAN_ENVIRONMENT
#   INTEGRATION_TEST_AZURE_CLIENT_ID, INTEGRATION_TEST_ENVIRONMENT
#   CHECKS_RUNS_ON, INTEGRATION_TEST_RUNS_ON, PLAN_RUNS_ON, APPLY_RUNS_ON
#   HAS_INFRACOST_API_KEY, HAS_AZURE_CLIENT_SECRET,
#   HAS_PLAN_AZURE_CLIENT_SECRET, HAS_INTEGRATION_TEST_AZURE_CLIENT_SECRET
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

log_config DRIFT ISSUES ISSUE_LABELS WORKING_DIR VAR_FILES NAME APPLY_ENVIRONMENT EXTRA_PATHS CHECKS TESTS TEST_FILTER \
  INTEGRATION_TESTS INTEGRATION_TEST_FILTER POLICY POLICY_PATH POLICY_SOURCE COST_ESTIMATE \
  AZURE_CLIENT_ID AZURE_TENANT_ID PLAN_AZURE_CLIENT_ID PLAN_ENVIRONMENT \
  INTEGRATION_TEST_AZURE_CLIENT_ID INTEGRATION_TEST_ENVIRONMENT CHECKS_RUNS_ON INTEGRATION_TEST_RUNS_ON \
  PLAN_RUNS_ON APPLY_RUNS_ON IS_FORK_PR IS_DEPENDABOT

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

drift=false
if is_true "${DRIFT:-false}"; then
  drift=true
fi

if [ "$drift" = false ] && [ -z "${APPLY_ENVIRONMENT:-}" ]; then
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

# --- Drift: issues ---------------------------------------------------------------

# The first label finds the deployment's issue again, so there has to be one
if [ "$drift" = true ] && is_true "${ISSUES:-true}" && [ -z "$(tr -d ', \t\n' <<< "${ISSUE_LABELS-opentofu-drift}")" ]; then
  problem "issue-labels is empty, but issues is on. Set at least one label (the first finds the deployment's issue again), or turn issues off."
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
  azure="$(HAS_AZURE_CLIENT_SECRET=false HAS_PLAN_AZURE_CLIENT_SECRET=false \
    HAS_INTEGRATION_TEST_AZURE_CLIENT_SECRET=false azure_input_problems)"
else
  azure="$(azure_input_problems)"
fi
while IFS= read -r line; do
  [ -n "$line" ] && problem "$line"
done <<< "$azure"

# Not a problem (many callers accept it), but worth saying: without a plan
# identity, the plan job signs in as the apply identity. plan-environment
# doesn't change that: the apply identity then has to trust that environment,
# which usually has no required reviewers.
if [ "$drift" = true ]; then
  # A scheduled check only reads, and runs unattended: it needs no write access
  if [ -n "${AZURE_CLIENT_ID:-}" ] && [ -z "${PLAN_AZURE_CLIENT_ID:-}" ]; then
    log_warn "Drift checks sign in with azure-client-id because plan-azure-client-id isn't set. They only read and run unattended, so set plan-azure-client-id to a read-only identity (Reader on the resources, plus whatever reading the configuration needs, e.g. Reader and Data Access, Key Vault reader roles; and Storage Blob Data Reader on the state container) and keep the identity that can write out of scheduled runs."
  fi
elif [ -z "$secrets_skipped" ] && [ -n "${AZURE_CLIENT_ID:-}" ] && [ -z "${PLAN_AZURE_CLIENT_ID:-}" ]; then
  if is_true "${HAS_AZURE_CLIENT_SECRET:-false}"; then
    log_warn "Plans use the apply identity (azure-client-id) because plan-azure-client-id isn't set, so pull request plans receive its client secret: anyone who can open a PR could get a credential that can write. Set plan-azure-client-id (with plan-azure-client-secret) to a read-only identity."
  else
    log_warn "Plans sign in with the apply identity (azure-client-id) because plan-azure-client-id isn't set, so its federated credentials must trust the plan job's subject (pull_request and main, or environment:${PLAN_ENVIRONMENT:-<plan-environment>}, which usually has no required reviewers): anyone who can open a PR could get a token that can write. Set plan-azure-client-id to a read-only identity and federate azure-client-id only to environment:${APPLY_ENVIRONMENT:-<apply-environment>}."
  fi
fi

# Likewise the integration tests, which run before the plan and any approval:
# without their own identity (integration-test-azure-client-id) they sign in
# as the apply identity on every non-fork pull request. An environment only
# helps if it has required reviewers, which isn't known here (the apply job's
# gate is checked at run time).
if [ -z "$secrets_skipped" ] && is_true "${INTEGRATION_TESTS:-false}" && [ -n "${AZURE_CLIENT_ID:-}" ] &&
  [ -z "${INTEGRATION_TEST_AZURE_CLIENT_ID:-}" ]; then
  log_warn "Integration tests sign in with the apply identity (azure-client-id) and run before any approval, because integration-test-azure-client-id isn't set: anyone who can open a PR could run code with a token that can write. Set integration-test-azure-client-id to an identity scoped to a test subscription or resource group. integration-test-environment only helps if that environment has required reviewers${INTEGRATION_TEST_ENVIRONMENT:+ (check ${INTEGRATION_TEST_ENVIRONMENT})}."
fi

# --- Runners ---------------------------------------------------------------------

# Checked here, or GitHub only refuses one when its job starts, perhaps
# after minutes of other jobs. Empty: the job runs on runs-on, which needs no check (this job
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
check_runs_on checks-runs-on "${CHECKS_RUNS_ON:-}"
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
