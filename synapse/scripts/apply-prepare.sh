#!/usr/bin/env bash
#
# First half of deploying a plan made by synapse/scripts/plan.sh: checks the
# plan's digest, writes the parameters file the Synapse deployer reads (the
# plan's parameters plus PARAMETER_SECRETS), and stops the workspace's
# started triggers -- the deployer can't update a started trigger, or delete
# one. The deployer action runs next, then apply-finish.sh starts triggers
# again and deletes the parameters file.
#
# Environment variables:
#   WORKING_DIR       - the workspace's Git root folder, with its mise.toml
#                       (required)
#   PLAN_DIR          - the downloaded plan artifact (default:
#                       $RUNNER_TEMP/synapse-plan)
#   PLAN_SHA256       - expected digest, from the plan job (required in
#                       GitHub Actions)
#   PARAMETER_SECRETS - name=value lines for secure parameters
#   MANAGE_TRIGGERS   - "true" (default) stops started triggers first
#   STATE_DIR         - where to keep the parameters file and the stopped
#                       triggers until apply-finish.sh (default:
#                       $RUNNER_TEMP/synapse-apply)
#
# Outputs:
#   template-file, parameters-file - for the deployer
#   workspace-name, resource-group - the target, from the plan
#   state-dir                      - STATE_DIR, for apply-finish.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$SCRIPT_DIR/../../arm/scripts/arm.sh"

ensure_mise
require_tool jq

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PLAN_DIR="${PLAN_DIR:-$TMP_ROOT/synapse-plan}"
STATE_DIR="${STATE_DIR:-$TMP_ROOT/synapse-apply}"
MANAGE_TRIGGERS="${MANAGE_TRIGGERS:-true}"
log_config WORKING_DIR PLAN_DIR PLAN_SHA256 MANAGE_TRIGGERS STATE_DIR

arm_verify_plan "$PLAN_DIR"
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
TEMPLATE="$PLAN_DIR/deploy/template/TemplateForWorkspace.json"

if [ "$(jq -r .service "$PLAN_DIR/deploy/target.json")" != "synapse" ]; then
  log_error "The plan at ${PLAN_DIR} isn't a Synapse plan. Download the synapse/plan artifact there."
  exit 1
fi
resource_group="$(jq -r .resource_group "$PLAN_DIR/deploy/target.json")"
workspace="$(jq -r .name "$PLAN_DIR/deploy/target.json")"
log_info "Deploying to workspace ${workspace} in resource group ${resource_group}"

rm -rf "$STATE_DIR"
(umask 077 && mkdir -p "$STATE_DIR")
STATE_DIR="$(cd "$STATE_DIR" && pwd)"
# Set before anything can fail half-way (e.g. stopping triggers), so
# apply-finish.sh can still clean up and restart what was stopped
set_output state-dir "$STATE_DIR"
set_output template-file "$TEMPLATE"
set_output parameters-file "$STATE_DIR/parameters.json"
set_output workspace-name "$workspace"
set_output resource-group "$resource_group"

cd_working_dir
arm_parameters_with_secrets "$TEMPLATE" "$PLAN_DIR/deploy/parameters.json" "$STATE_DIR/parameters.json"

: > "$STATE_DIR/stopped-triggers.txt"
if is_true "$MANAGE_TRIGGERS"; then
  require_mise_tool azure-cli
  log_step "Stop started triggers"
  if ! triggers="$(arm_az synapse trigger list --workspace-name "$workspace" --output json)"; then
    log_error "Couldn't list the triggers of workspace ${workspace}. The job needs network access to https://${workspace}.dev.azuresynapse.net (a private workspace needs a runner in its network) and a Synapse role that can publish artifacts (Synapse Artifact Publisher)."
    exit 1
  fi
  jq -r '.[] | select(.properties.runtimeState == "Started") | .name' <<< "$triggers" > "$STATE_DIR/stopped-triggers.txt"
  while IFS= read -r trigger; do
    [ -n "$trigger" ] || continue
    log_info "Stopping trigger ${trigger}"
    arm_az synapse trigger stop --workspace-name "$workspace" --name "$trigger" --output none
  done < "$STATE_DIR/stopped-triggers.txt"
  log_success "Stopped $(grep -c . "$STATE_DIR/stopped-triggers.txt" || true) trigger(s)"
fi

log_success "Ready to deploy ${workspace}"
