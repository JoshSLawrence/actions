#!/usr/bin/env bash
#
# Plans one deployment of a Synapse workspace template: renders its
# parameters, optionally compares the template with the live workspace
# (which artifacts are new, and which the deployment deletes), and writes
# the plan -- the template, the parameters and the target, which the apply
# deploys exactly -- with a markdown summary. Never changes anything, so
# it's safe to run locally:
#
#   WORKING_DIR=synapse TEMPLATE_DIR=/tmp/synapse-template \
#     PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev \
#     synapse/scripts/plan.sh
#
# Environment variables:
#   WORKING_DIR       - the workspace's Git root folder (required); parameter
#                       files are relative to it
#   TEMPLATE_DIR      - the exported template (synapse/build's template-dir)
#                       (required)
#   PLAN_DIR          - where the plan goes (default:
#                       $RUNNER_TEMP/synapse-plan): deploy/ (template,
#                       parameters.json, target.json) and summary.md. The plan
#                       artifact; it never holds secrets.
#   WORK_DIR          - scratch directory, deleted at the end (default:
#                       $RUNNER_TEMP/synapse-plan-work)
#   DEPLOYMENT        - the deployment's name, for the summary
#   PARAMETER_FILES   - ARM parameters files, in order (space- or
#                       newline-separated)
#   PARAMETERS        - name=value lines, after the files
#   PARAMETER_SECRETS - name=value lines for secure parameters; only their
#                       names are used here
#   RESOURCE_GROUP    - the target workspace's resource group (required)
#   WHAT_IF           - "true": list the live workspace's artifacts (needs az
#                       signed in, and network access to the workspace's
#                       development endpoint). Default false.
#   DELETE_ARTIFACTS  - "true" (default) if the apply deletes artifacts that
#                       aren't in the template
#   TITLE             - heading for the job summary
#   HEAD_SHA, TARGET_BRANCH, TARGET_SHA, PR_NUMBER
#                     - describe what's being planned, for the summary
#
# Outputs:
#   has-changes    - always "true": the deployment republishes every artifact
#   plan-sha256    - digest of the plan's deploy/ directory
#   plan-dir       - absolute path of PLAN_DIR
#   summary-file   - the markdown summary (also on failure)
#   workspace-name, resource-group - the target
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$SCRIPT_DIR/../../arm/scripts/arm.sh"

require_tool jq
require_env TEMPLATE_DIR "Set it to the template-dir of synapse/build (or the downloaded template artifact)."
require_env RESOURCE_GROUP "Set the resource-group input."

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PLAN_DIR="${PLAN_DIR:-$TMP_ROOT/synapse-plan}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/synapse-plan-work}"
WHAT_IF="${WHAT_IF:-false}"
DELETE_ARTIFACTS="${DELETE_ARTIFACTS:-true}"

log_config WORKING_DIR TEMPLATE_DIR PLAN_DIR DEPLOYMENT PARAMETER_FILES RESOURCE_GROUP WHAT_IF DELETE_ARTIFACTS

rm -rf "$PLAN_DIR" "$WORK_DIR"
mkdir -p "$PLAN_DIR/deploy" "$WORK_DIR"
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
SUMMARY_FILE="$PLAN_DIR/summary.md"
set_output plan-dir "$PLAN_DIR"
set_output summary-file "$SUMMARY_FILE"
set_output has-changes false

# Always leave a summary behind -- a failure's too, for the PR comment -- and
# delete the scratch files.
finish() {
  local exit_code=$?
  if [ ! -s "$SUMMARY_FILE" ]; then
    arm_failure_markdown "${FAILED:-The plan failed.}" "${FAILED_LOG:-/dev/null}" > "$SUMMARY_FILE"
  fi
  {
    echo "## ${TITLE:-Synapse plan}"
    echo ""
    cat "$SUMMARY_FILE"
    echo ""
  } | append_step_summary
  rm -rf "$WORK_DIR"
  exit "$exit_code"
}
trap finish EXIT

# Record why the plan failed, for the summary, then fail
# Usage: fail "<what failed>" [<log file>]
fail() {
  FAILED="$1"
  FAILED_LOG="${2:-}"
  log_error "$1"
  exit 1
}

TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" 2> /dev/null && pwd)" || fail "TEMPLATE_DIR doesn't exist. Point it at synapse/build's template-dir."
[ -f "$TEMPLATE_DIR/TemplateForWorkspace.json" ] || fail "No TemplateForWorkspace.json in ${TEMPLATE_DIR}. Point TEMPLATE_DIR at synapse/build's template-dir."
cp -R "$TEMPLATE_DIR" "$PLAN_DIR/deploy/template"
TEMPLATE="$PLAN_DIR/deploy/template/TemplateForWorkspace.json"
PARAMETERS_FILE="$PLAN_DIR/deploy/parameters.json"

cd_working_dir

log_step "Parameters"
merged="$WORK_DIR/parameters-result.json"
arm_merge_parameters "$TEMPLATE" "$PLAN_DIR/deploy/template/TemplateParametersForWorkspace.json" \
  "$(list_lines "${PARAMETERS:-}")" "parameters input" "$(list_items "${PARAMETER_FILES:-}")" > "$merged" 2> "$WORK_DIR/parameters.log" ||
  { cat "$WORK_DIR/parameters.log" >&2; fail "Couldn't read the parameters (see the output below)." "$WORK_DIR/parameters.log"; }
secret_names="$(list_lines "${PARAMETER_SECRETS:-}" | sed 's/=.*//; s/[[:space:]]*$//')"
if ! arm_check_parameters "$merged" workspaceName 2> "$WORK_DIR/parameters.log"; then
  cat "$WORK_DIR/parameters.log" >&2
  fail "The deployment's parameters are invalid." "$WORK_DIR/parameters.log"
fi
references="$(jq -r '.parameters | to_entries[] | select(.value | has("reference")) | .key' "$merged")"
if [ -n "$references" ]; then
  fail "Key Vault references ($(paste -sd, - <<< "$references" | sed 's/,/, /g')) only work in ARM deployments, and Synapse artifacts aren't deployed through ARM. Pass the value in parameter-secrets instead, or point the linked service at Key Vault."
fi
missing="$(jq -r --arg s "$secret_names" '.missing - ($s | split("\n")) | .[]' "$merged")"
if [ -n "$missing" ]; then
  fail "No value for $(paste -sd, - <<< "$missing" | sed 's/,/, /g'), and the template has no default. Set them in a parameters file, the parameters input, or parameter-secrets."
fi
arm_write_parameters_file "$merged" "$PARAMETERS_FILE"

workspace="$(jq -r '.parameters.workspaceName.value // empty' "$PARAMETERS_FILE")"
[ -n "$workspace" ] || fail "workspaceName is empty. Set it to the target workspace's name."
jq -n --arg service synapse --arg deployment "${DEPLOYMENT:-}" --arg resource_group "$RESOURCE_GROUP" --arg name "$workspace" \
  '{service: $service, deployment: $deployment, resource_group: $resource_group, name: $name}' > "$PLAN_DIR/deploy/target.json"
set_output workspace-name "$workspace"
set_output resource-group "$RESOURCE_GROUP"
log_success "Parameters rendered for workspace ${workspace} in ${RESOURCE_GROUP}"

# The template's artifacts, keyed like the live ones below. Pools and the
# managed virtual network aren't deployed by the Synapse deployer (they're
# infrastructure), so they're left out.
arm_template_resources "$TEMPLATE" |
  jq -c 'select(.type != "bigDataPools" and .type != "sqlPools" and .type != "managedVirtualNetworks")
    | . + {key: "\(.type | ascii_downcase)/\(.name | ascii_downcase)"}' > "$WORK_DIR/template.jsonl"
artifacts="$(wc -l < "$WORK_DIR/template.jsonl" | tr -d ' ')"

new="[]"
deletions="[]"
if is_true "$WHAT_IF"; then
  ensure_mise
  require_mise_tool azure-cli
  log_step "Compare with the live workspace"
  : > "$WORK_DIR/live.jsonl"
  endpoint="https://${workspace}.dev.azuresynapse.net"
  # What the deployer lists (and may delete); integration runtimes are never
  # deleted, and the workspace's own default linked services, credential and
  # managed private endpoints are skipped.
  for collection in credentials dataflows datasets linkedServices notebooks pipelines sparkJobDefinitions \
    sqlScripts triggers kqlScripts sparkConfigurations databases managedVirtualNetworks/default/managedPrivateEndpoints integrationRuntimes; do
    type="${collection/\/default\//\/}"
    if ! arm_rest_list "${endpoint}/${collection}?api-version=2019-06-01-preview" --resource https://dev.azuresynapse.net 2> "$WORK_DIR/live.log" |
      jq -c --arg type "$type" '{type: $type, name, key: "\($type | ascii_downcase)/\(.name | ascii_downcase)"}' >> "$WORK_DIR/live.jsonl"; then
      cat "$WORK_DIR/live.log" >&2
      fail "Couldn't list the ${collection} of workspace ${workspace}. The plan job needs network access to ${endpoint} (a private workspace needs a runner in its network) and the Synapse Artifact User role; or set what-if to false." "$WORK_DIR/live.log"
    fi
  done
  default_artifact='test("workspacedefaultsqlserver|workspacedefaultstorage|workspacesystemidentity|^synapse-ws-(sql|sqlondemand|kusto)"; "i")'
  new="$(jq -cs --slurpfile live <(jq -s . "$WORK_DIR/live.jsonl") '
    ($live[0] | map(.key)) as $existing | map(select(.key as $k | $existing | index($k) | not))' "$WORK_DIR/template.jsonl")"
  if is_true "$DELETE_ARTIFACTS"; then
    deletions="$(jq -cs --slurpfile template <(jq -s . "$WORK_DIR/template.jsonl") "
      (\$template[0] | map(.key)) as \$keep
      | map(select(.type != \"integrationRuntimes\" and (.name | ${default_artifact} | not)))
      | map(select(.key as \$k | \$keep | index(\$k) | not))" "$WORK_DIR/live.jsonl")"
  fi
  log_info "$(jq length <<< "$new") new artifact(s), $(jq length <<< "$deletions") to delete"
fi

log_step "Summary"
deleted="$(jq length <<< "$deletions")"
{
  if is_true "$WHAT_IF"; then
    echo "### 📋 Plan: deploy ${artifacts} artifact(s) ($(jq length <<< "$new") new), delete ${deleted}"
  else
    echo "### 📋 Plan: deploy ${artifacts} artifact(s)"
  fi
  echo ""
  context_line
  echo ""
  echo "Workspace \`${workspace}\` in resource group \`${RESOURCE_GROUP}\`. Every artifact in the template is published again; Synapse has no what-if, so this can't show which ones change."
  if ! is_true "$WHAT_IF"; then
    echo "What-if is off, so this doesn't show which artifacts are new$(is_true "$DELETE_ARTIFACTS" && echo ", or which the deployment deletes")."
  fi
  echo ""
  if [ "$deleted" -gt 0 ]; then
    echo "> **Warning:** the deployment deletes ${deleted} artifact(s) that are no longer in the folder:"
    jq -r '.[] | "> - `\(.type)/\(.name)`"' <<< "$deletions"
    echo ""
  fi
  echo "<details><summary>Artifacts (${artifacts})</summary>"
  echo ""
  echo "| Action | Artifact |"
  echo "| --- | --- |"
  jq -rs --argjson new "$new" --arg what_if "$WHAT_IF" '
    ($new | map(.key)) as $new_keys
    | sort_by(.type, .name)[]
    | .key as $key
    | (if $what_if != "true" then "🔵 publish"
       elif ($new_keys | index($key)) != null then "🟢 create"
       else "🟡 update" end) as $action
    | "| \($action) | `\(.type)/\(.name)` |"' "$WORK_DIR/template.jsonl"
  echo ""
  echo "</details>"
  echo ""
  echo "<details><summary>Parameters</summary>"
  echo ""
  arm_parameters_markdown "$merged" "$TEMPLATE" "$secret_names"
  echo ""
  echo "</details>"
} > "$SUMMARY_FILE"
fit_github_body "$SUMMARY_FILE" "the workflow run's job summary"

plan_sha256="$(arm_plan_sha256 "$PLAN_DIR")"
set_output has-changes true
set_output plan-sha256 "$plan_sha256"
log_summary "Planned workspace ${workspace} in ${RESOURCE_GROUP} (plan sha256 ${plan_sha256})"
