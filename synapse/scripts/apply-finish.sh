#!/usr/bin/env bash
#
# Second half of deploying a Synapse plan, after the deployer action, whether
# it succeeded or not: starts triggers again and deletes the parameters file
# (it holds the secret parameters).
#
# Which triggers start:
#   - after a successful deployment, every trigger the template marks
#     Started, plus any that apply-prepare.sh stopped and the template doesn't
#     mark Stopped;
#   - after a failed one, only those apply-prepare.sh stopped, so the
#     workspace keeps running as it was.
#
# Environment variables:
#   WORKING_DIR     - the workspace's Git root folder, with its mise.toml
#                     (required)
#   STATE_DIR       - apply-prepare.sh's state-dir (required)
#   TEMPLATE_FILE   - the deployed TemplateForWorkspace.json (required)
#   WORKSPACE_NAME  - the target workspace (required)
#   DEPLOY_OUTCOME  - the deployer step's outcome (success, failure, ...)
#   MANAGE_TRIGGERS - "true" (default) starts triggers
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$SCRIPT_DIR/../../arm/scripts/arm.sh"

require_env STATE_DIR
trap 'rm -f "$STATE_DIR/parameters.json"' EXIT

ensure_mise
require_tool jq
require_env TEMPLATE_FILE
require_env WORKSPACE_NAME
MANAGE_TRIGGERS="${MANAGE_TRIGGERS:-true}"
log_config WORKING_DIR STATE_DIR WORKSPACE_NAME DEPLOY_OUTCOME MANAGE_TRIGGERS

if ! is_true "$MANAGE_TRIGGERS"; then
  log_info "manage-triggers is off; not starting triggers"
  exit 0
fi

cd_working_dir
require_mise_tool azure-cli

if ! triggers="$(arm_az synapse trigger list --workspace-name "$WORKSPACE_NAME" --output json)"; then
  log_error "Couldn't list the triggers of workspace ${WORKSPACE_NAME}, so none were started. Start them in Synapse Studio, or re-run the deploy."
  exit 1
fi

stopped="$(cat "$STATE_DIR/stopped-triggers.txt" 2> /dev/null || true)"
to_start="$(jq -r --arg stopped "$stopped" --arg outcome "${DEPLOY_OUTCOME:-}" --slurpfile template "$TEMPLATE_FILE" '
  ($stopped | split("\n") | map(select(length > 0))) as $was_started
  | ($template[0].resources // []
      | map(select(.type == "Microsoft.Synapse/workspaces/triggers")
        | {key: (.name | capture("\u0027/(?<n>[^\u0027]*)\u0027\\)\\]$").n), value: (.properties.runtimeState // "")})
      | from_entries) as $wanted
  | map(select(.properties.runtimeState != "Started") | .name) as $not_running
  | $not_running[]
  | . as $name
  | (($was_started | index($name)) != null) as $stopped_here
  | select(
      if $outcome == "success" then
        $wanted[$name] == "Started" or ($stopped_here and $wanted[$name] != "Stopped")
      else
        $stopped_here
      end)' <<< "$triggers")"

if [ -z "$to_start" ]; then
  log_success "No triggers to start"
  exit 0
fi

failed=0
while IFS= read -r trigger; do
  log_info "Starting trigger ${trigger}"
  if ! arm_az synapse trigger start --workspace-name "$WORKSPACE_NAME" --name "$trigger" --output none; then
    log_warn "Couldn't start trigger ${trigger}. Start it in Synapse Studio."
    failed=$((failed + 1))
  fi
done <<< "$to_start"

if [ "$failed" -gt 0 ]; then
  log_error "${failed} trigger(s) didn't start. See the warnings above."
  exit 1
fi
log_success "Started $(grep -c . <<< "$to_start") trigger(s)"
