#!/usr/bin/env bash
#
# First half of deploying a plan made by synapse/scripts/plan.sh: checks the
# plan's digest, lists the workspace again and refuses if it differs from
# the plan's (live.json: something else changed it since), writes the
# parameters file the Synapse deployer reads (the plan's parameters plus
# PARAMETER_SECRETS), and stops the workspace's started triggers -- the
# deployer can't update a started trigger, or delete one. The deployer
# action runs next, then apply-finish.sh starts triggers again and deletes
# the parameters file.
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
#   DEPLOY_MANAGED_PRIVATE_ENDPOINTS, DELETE_ARTIFACTS
#                     - what the plan was made with (default: the plan's); a
#                       different value is refused
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
log_config WORKING_DIR PLAN_DIR PLAN_SHA256 MANAGE_TRIGGERS STATE_DIR DEPLOY_MANAGED_PRIVATE_ENDPOINTS DELETE_ARTIFACTS

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

# The deployer deletes endpoints that aren't in the template only when it
# deploys them, and deletes artifacts only with DELETE_ARTIFACTS, so a
# different input from the plan's is refused rather than trusted: the apply
# must not delete what the plan never listed
arm_planned_setting "$PLAN_DIR" deploy_managed_private_endpoints deploy-managed-private-endpoints "${DEPLOY_MANAGED_PRIVATE_ENDPOINTS:-}" false > /dev/null || exit 1
arm_planned_setting "$PLAN_DIR" delete_artifacts delete-artifacts "${DELETE_ARTIFACTS:-}" true > /dev/null || exit 1

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

if [ -f "$PLAN_DIR/deploy/live.json" ]; then
  require_mise_tool azure-cli
  log_step "Check the workspace is as planned"
  endpoint="https://${workspace}.dev.azuresynapse.net"
  mapfile -t kinds < <(jq -r '.kinds[]' "$PLAN_DIR/deploy/live.json")
  if ! arm_live_lines "$endpoint" 2019-06-01-preview https://dev.azuresynapse.net "${kinds[@]}" > "$STATE_DIR/live-lines.jsonl" 2> "$STATE_DIR/live.log"; then
    cat "$STATE_DIR/live.log" >&2
    arm_refuse "$PLAN_DIR" "Couldn't list the artifacts of workspace ${workspace} to check it hasn't changed since the plan. The job needs network access to ${endpoint} (a private workspace needs a runner in its network) and the Synapse Artifact User role; then re-run all jobs of the workflow."
    exit 1
  fi
  arm_verify_live Workspace "$workspace" "$PLAN_DIR" "$(arm_synapse_fingerprint "$STATE_DIR/live-lines.jsonl")" || exit 1
else
  log_warn "The plan has no live.json (what-if was off), so the check that the workspace is unchanged since the plan is skipped."
fi

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
