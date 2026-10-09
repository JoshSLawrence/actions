#!/usr/bin/env bash
#
# Lists the deployments of one Data Factory or Synapse folder -- one per ARM
# parameters file matching DEPLOYMENTS, or the template on its own without
# it -- as a matrix for the per-deployment plan/deploy jobs. See
# "Deployments" in arm.sh for how a deployment is put together.
#
# Environment variables:
#   WORKING_DIR       - the factory/workspace folder (required)
#   DEPLOYMENTS       - parameters files, one deployment each: globs within
#                       the folder (e.g. "deployments/*.json") and/or paths,
#                       relative to it. Must match at least one file if set.
#   PARAMETER_FILES   - parameters files every deployment uses, before its own
#   PARAMETERS        - name=value lines every deployment uses; "{deployment}"
#                       is replaced with the deployment's name
#   RESOURCE_GROUP    - resource group to deploy to (required); "{deployment}"
#                       is replaced
#   PLAN_ENVIRONMENT, APPLY_ENVIRONMENT
#                     - GitHub environment names; "{deployment}" is replaced
#   PREFLIGHT_PATHS   - paths every deployment's plan depends on (default:
#                       WORKING_DIR); each deployment's list leaves out the
#                       other deployments' parameters files
#   APPLY             - "true" (default): the apply job runs, so it needs an
#                       APPLY_ENVIRONMENT
#
# Outputs:
#   matrix      - {"deployment": [<deployment JSON>, ...]}
#   deployments - JSON array of the deployment names
#   count       - number of deployments
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$SCRIPT_DIR/arm.sh"

require_tool jq
require_env WORKING_DIR "Set the working-directory input to the factory or workspace folder."
require_env RESOURCE_GROUP "Set the resource-group input to the target resource group, e.g. rg-{deployment} for one per deployment."
export PREFLIGHT_PATHS="${PREFLIGHT_PATHS:-$WORKING_DIR}"
APPLY="${APPLY:-true}"
log_config WORKING_DIR DEPLOYMENTS PARAMETER_FILES RESOURCE_GROUP PLAN_ENVIRONMENT APPLY_ENVIRONMENT PREFLIGHT_PATHS APPLY

# Without an environment the apply has no approval gate, so a plan from a PR
# would deploy unreviewed
if is_true "$APPLY" && [ -z "${APPLY_ENVIRONMENT:-}" ]; then
  log_error "apply is true, but apply-environment is empty. Set apply-environment to a GitHub environment with required reviewers (e.g. \"{deployment}\"), or set apply to false to only plan."
  exit 1
fi

dir="$(normalize_path "$WORKING_DIR")" || {
  log_error "working-directory '${WORKING_DIR}' climbs out of the repository. Use a path relative to the repository root."
  exit 1
}
if [ ! -d "$dir" ]; then
  log_error "working-directory '${dir}' doesn't exist. It's relative to the repository root."
  exit 1
fi

if ! deployments="$(arm_list_deployments "$dir")"; then
  exit 1
fi
if [ -z "$deployments" ]; then
  log_error "The deployments input (${DEPLOYMENTS//$'\n'/ }) matches no .json files in ${dir}. Paths and globs are relative to the working directory; leave deployments empty to deploy once with parameter-files and parameters."
  exit 1
fi

matrix="$(jq -cs '{deployment: .}' <<< "$deployments")"
names="$(jq -cs 'map(.name)' <<< "$deployments")"
count="$(jq -s 'length' <<< "$deployments")"

{
  echo "### Deployments of \`${dir}\`"
  echo ""
  echo "| Deployment | Parameter files | Resource group | Apply environment |"
  echo "| --- | --- | --- | --- |"
  jq -r '
    def cell: if . == "" then "–" else split("\n") | map("`\(.)`") | join("<br>") end;
    "| \(if .name == "" then "(template as is)" else "`\(.name)`" end) | \(.parameter_files | cell) | \(.resource_group | cell) | \(.apply_environment | cell) |"
  ' <<< "$deployments"
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output matrix "$matrix"
set_output deployments "$names"
set_output count "$count"
log_success "${count} deployment(s) of ${dir}: $(jq -r 'map(if . == "" then "(template as is)" else . end) | join(", ")' <<< "$names")"
