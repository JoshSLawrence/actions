#!/usr/bin/env bash
#
# Lists the deployments of one root module -- one per .tfvars file matching
# DEPLOYMENTS, or the module on its own without it -- as a matrix for the
# per-deployment plan/apply jobs. See "Deployments" in common.sh for how a
# deployment's var files, backend config and environments are put together.
#
# Environment variables:
#   WORKING_DIR       - root module directory (required)
#   DEPLOYMENTS       - .tfvars files, one deployment each: globs within the
#                       module (e.g. "deployments/*.tfvars") and/or paths,
#                       relative to it. Must match at least one file if set.
#   VAR_FILES         - var files every deployment uses, before its own
#   BACKEND_CONFIG    - backend config every deployment uses, one per line;
#                       "{deployment}" is replaced with the deployment's name
#   PLAN_ENVIRONMENT, APPLY_ENVIRONMENT
#                     - GitHub environment names; "{deployment}" is replaced
#   PREFLIGHT_PATHS   - paths every deployment's plan depends on (default:
#                       WORKING_DIR)
#
# Outputs:
#   matrix      - {"deployment": [<deployment JSON>, ...]}
#   deployments - JSON array of the deployment names
#   count       - number of deployments
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool jq
require_env WORKING_DIR "Set the working-directory input to the root module."
export PREFLIGHT_PATHS="${PREFLIGHT_PATHS:-$WORKING_DIR}"
log_config WORKING_DIR DEPLOYMENTS VAR_FILES BACKEND_CONFIG PLAN_ENVIRONMENT APPLY_ENVIRONMENT PREFLIGHT_PATHS

dir="$(normalize_path "$WORKING_DIR")" || {
  log_error "working-directory '${WORKING_DIR}' climbs out of the repository. Use a path relative to the repository root."
  exit 1
}
if [ ! -d "$dir" ]; then
  log_error "working-directory '${dir}' doesn't exist. It's relative to the repository root."
  exit 1
fi

if ! deployments="$(list_deployments "$dir")"; then
  exit 1
fi
if [ -z "$deployments" ]; then
  log_error "The deployments input (${DEPLOYMENTS//$'\n'/ }) matches no .tfvars files in ${dir}. Paths and globs are relative to the root module; leave deployments empty to plan the module on its own."
  exit 1
fi

matrix="$(jq -cs '{deployment: .}' <<< "$deployments")"
names="$(jq -cs 'map(.name)' <<< "$deployments")"
count="$(jq -s 'length' <<< "$deployments")"

{
  echo "### Deployments of \`${dir}\`"
  echo ""
  echo "| Deployment | Var files | Backend config | Apply environment |"
  echo "| --- | --- | --- | --- |"
  jq -r '
    def cell: if . == "" then "–" else split("\n") | map("`\(.)`") | join("<br>") end;
    "| \(if .name == "" then "(module as is)" else "`\(.name)`" end) | \(.var_files | cell) | \(.backend_config | cell) | \(.apply_environment | cell) |"
  ' <<< "$deployments"
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output matrix "$matrix"
set_output deployments "$names"
set_output count "$count"
log_success "${count} deployment(s) of ${dir}: $(jq -r 'map(if . == "" then "(module as is)" else . end) | join(", ")' <<< "$names")"
