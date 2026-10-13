#!/usr/bin/env bash
#
# Plans one deployment of a Synapse workspace template: leaves out what
# infrastructure as code owns (see "Infrastructure kinds" in arm.sh), renders
# its parameters, optionally compares the template with the live workspace
# (which artifacts differ from their live definitions, which are new, which
# the deployment deletes, that the Spark and SQL pools the artifacts use
# exist), and writes the plan -- the template,
# the parameters and the target, which the apply deploys exactly -- with a
# markdown summary. Never changes anything, so it's safe to run locally:
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
#                       parameters.json, target.json and, with what-if,
#                       live.json) and summary.md. The plan artifact; it
#                       never holds secrets.
#   WORK_DIR          - scratch directory, deleted at the end (default:
#                       $RUNNER_TEMP/synapse-plan-work)
#   DEPLOYMENT        - the deployment's name, for the summary
#   PARAMETER_FILES   - ARM parameters files, in order (space- or
#                       newline-separated)
#   PARAMETERS        - name=value lines, after the files
#   PARAMETER_SECRETS - name=value lines for secure parameters; the names
#                       are used here and, with WHAT_IF, also the values, to
#                       compare secure properties with the live ones (in a
#                       scratch file, never in the plan, and never shown)
#   RESOURCE_GROUP    - the target workspace's resource group (required)
#   WHAT_IF           - "true": list the live workspace's artifacts, compare
#                       each with its template definition (as the deployer
#                       would publish it), check its pools exist, and record
#                       its fingerprint, which the apply checks (needs az
#                       signed in, and network access to the workspace's
#                       development endpoint). Default false.
#   ALWAYS_APPLY      - "true": has-changes is true even when the comparison
#                       found nothing to change (to deploy everything
#                       anyway, e.g. after a change in the portal that the
#                       comparison ignores or can't see). Default false.
#   DELETE_ARTIFACTS  - "true" (default) if the apply deletes artifacts that
#                       aren't in the template
#   DEPLOY_MANAGED_PRIVATE_ENDPOINTS, DEPLOY_INTEGRATION_RUNTIMES
#                     - "true" deploys the folder's managed private
#                       endpoints / integration runtimes; the default false
#                       leaves them to infrastructure as code: they're taken
#                       out of the template. With endpoints deployed and
#                       DELETE_ARTIFACTS, those not in the template are
#                       deleted (integration runtimes never are).
#   TITLE             - heading for the job summary
#   HEAD_SHA, TARGET_BRANCH, TARGET_SHA, PR_NUMBER
#                     - describe what's being planned, for the summary
#
# Outputs:
#   has-changes    - "true" unless the comparison found nothing to create,
#                    change or delete (true without WHAT_IF, which can't
#                    tell, and with ALWAYS_APPLY). An artifact the plan can't
#                    compare, or whose secure value the service hides, counts
#                    as a change.
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
ALWAYS_APPLY="${ALWAYS_APPLY:-false}"
DELETE_ARTIFACTS="${DELETE_ARTIFACTS:-true}"
export DEPLOY_MANAGED_PRIVATE_ENDPOINTS="${DEPLOY_MANAGED_PRIVATE_ENDPOINTS:-false}"
export DEPLOY_INTEGRATION_RUNTIMES="${DEPLOY_INTEGRATION_RUNTIMES:-false}"

log_config WORKING_DIR TEMPLATE_DIR PLAN_DIR DEPLOYMENT PARAMETER_FILES RESOURCE_GROUP WHAT_IF ALWAYS_APPLY DELETE_ARTIFACTS DEPLOY_MANAGED_PRIVATE_ENDPOINTS DEPLOY_INTEGRATION_RUNTIMES

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

# The pools the artifacts use, before the pool stubs the export generates are
# left out of the template: {artifact, kind, pool}. A notebook or Spark job
# definition names its pool; a stub stands for a pool some pipeline activity
# or dataset uses, and is only listed when no artifact above names it.
jq -c '
  def last_name: (.name | (capture("\u0027/(?<n>[^\u0027]*)\u0027\\)\\]$").n // .) | split("/") | last);
  def tail: (.type | split("/")[2:] | join("/") | ascii_downcase);
  [ .resources[]?
    | if tail == "notebooks" then {artifact: "notebooks/\(last_name)", kind: "Spark", pool: .properties.bigDataPool.referenceName}
      elif tail == "sparkjobdefinitions" then {artifact: "sparkJobDefinitions/\(last_name)", kind: "Spark", pool: .properties.targetBigDataPool.referenceName}
      else empty end
    | select(.pool != null and (.pool | startswith("[") | not)) ] as $named
  | $named[],
    ( .resources[]?
      | if tail == "bigdatapools" then {artifact: "The template", kind: "Spark", pool: last_name}
        elif tail == "sqlpools" then {artifact: "The template", kind: "SQL", pool: last_name}
        else empty end
      | select(. as $stub | $named | any(.kind == $stub.kind and (.pool | ascii_downcase) == ($stub.pool | ascii_downcase)) | not) )' \
  "$TEMPLATE" > "$WORK_DIR/pools.jsonl"

log_step "Infrastructure left to infrastructure as code"
arm_infrastructure_types synapse > "$WORK_DIR/infrastructure-types.jsonl"
arm_strip_resources "$TEMPLATE" "$WORK_DIR/infrastructure-types.jsonl" "$WORK_DIR/stripped.json" "$WORK_DIR/left-to-iac.jsonl" "$WORK_DIR/dangling.jsonl"
mv "$WORK_DIR/stripped.json" "$TEMPLATE"
if ! arm_strip_problems "$WORK_DIR/dangling.jsonl" 2> "$WORK_DIR/strip.log"; then
  cat "$WORK_DIR/strip.log" >&2
  fail "The template has dependencies on resources this workflow leaves to infrastructure as code that the plan can't resolve, so the deployer would stop on them." "$WORK_DIR/strip.log"
fi
log_info "$(grep -c . "$WORK_DIR/left-to-iac.jsonl" || true) resource(s) left out of the deployment"
# Warned about below, once the live workspace says which are reference copies

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
# What the plan left out, and whether it listed deletions, is recorded so the
# apply can check its own inputs against it
jq -n --arg service synapse --arg deployment "${DEPLOYMENT:-}" --arg resource_group "$RESOURCE_GROUP" --arg name "$workspace" \
  --argjson mpes "$(is_true "$DEPLOY_MANAGED_PRIVATE_ENDPOINTS" && echo true || echo false)" \
  --argjson delete "$(is_true "$DELETE_ARTIFACTS" && echo true || echo false)" \
  '{service: $service, deployment: $deployment, resource_group: $resource_group, name: $name,
    deploy_managed_private_endpoints: $mpes, delete_artifacts: $delete}' > "$PLAN_DIR/deploy/target.json"
set_output workspace-name "$workspace"
set_output resource-group "$RESOURCE_GROUP"
log_success "Parameters rendered for workspace ${workspace} in ${RESOURCE_GROUP}"

# The template's artifacts, keyed like the live ones below. The deployer
# skips the workspace's own defaults (its default linked services and
# credential, and its synapse-ws-* endpoints), whatever the folder holds
# for them: a folder exported from another workspace carries that
# workspace's names. They are marked, and not counted as deployed.
arm_template_resources "$TEMPLATE" |
  jq -c "(.type | ascii_downcase) as \$t
    | . + {key: \"\(\$t)/\(.name | ascii_downcase)\",
           default: (${ARM_SYNAPSE_IS_DEFAULT})}" > "$WORK_DIR/template.jsonl"
total="$(wc -l < "$WORK_DIR/template.jsonl" | tr -d ' ')"
defaults="$(jq -s 'map(select(.default)) | length' "$WORK_DIR/template.jsonl")"
artifacts=$((total - defaults))

# Number of artifacts the comparison found to differ in any way (anything
# but unchanged and a skipped service default)
count_changed() {
  jq -s 'map(select(.status != "skipped" and .status != "unchanged")) | length' "$WORK_DIR/compare.jsonl"
}

# Number of artifacts with a status in the comparison
# Usage: count_status <status>
count_status() {
  jq -s --arg status "$1" 'map(select(.status == $status)) | length' "$WORK_DIR/compare.jsonl"
}

new="[]"
deletions="[]"
compare_failed=false
if is_true "$WHAT_IF"; then
  ensure_mise
  require_mise_tool azure-cli
  log_step "Compare with the live workspace"
  endpoint="https://${workspace}.dev.azuresynapse.net"
  # What the deployer lists (and may delete), and the infrastructure kinds
  # the call deploys. The apply lists the same kinds again (live.json) to be
  # sure nothing else changed them.
  kinds=(credentials dataflows datasets linkedServices notebooks pipelines sparkJobDefinitions
    sqlScripts triggers kqlScripts sparkConfigurations databases)
  if is_true "$DEPLOY_MANAGED_PRIVATE_ENDPOINTS"; then
    kinds+=(managedVirtualNetworks/default/managedPrivateEndpoints)
  fi
  if is_true "$DEPLOY_INTEGRATION_RUNTIMES"; then
    kinds+=(integrationRuntimes)
  fi
  # A workspace without a managed virtual network has no endpoints to list
  # (the list answers 400). Endpoints are listed only when they're deployed;
  # then that is fine unless the template has an endpoint of its own to
  # deploy, which can't work there. With endpoints left to infrastructure as
  # code they aren't listed, so such a workspace never reaches this
  export ARM_EMPTY_WITHOUT_VNET=false
  if [ "$(jq -s 'map(select((.type | ascii_downcase) == "managedvirtualnetworks/managedprivateendpoints" and (.default | not))) | length' "$WORK_DIR/template.jsonl")" = 0 ]; then
    ARM_EMPTY_WITHOUT_VNET=true
  fi
  # With the definitions, which the comparison below needs; the fingerprint
  # and the deletions use only {type, name, etag}
  if ! ARM_LIVE_PROPERTIES=true arm_live_lines "$endpoint" 2019-06-01-preview https://dev.azuresynapse.net "${kinds[@]}" > "$WORK_DIR/live-lines.jsonl" 2> "$WORK_DIR/live.log"; then
    cat "$WORK_DIR/live.log" >&2
    if grep -qi 'does not have a managed virtual network associated' "$WORK_DIR/live.log"; then
      fail "Workspace ${workspace} has no managed virtual network, so the managed private endpoints in the folder can't be deployed to it. Create the workspace with a managed virtual network (with your infrastructure as code) and apply that first, or set deploy-managed-private-endpoints to false." "$WORK_DIR/live.log"
    fi
    fail "Couldn't list the artifacts of workspace ${workspace}. The plan job needs network access to ${endpoint} (a private workspace needs a runner in its network) and the Synapse Artifact User role; or set what-if to false." "$WORK_DIR/live.log"
  fi
  jq -c '. + {key: "\(.type | ascii_downcase)/\(.name | ascii_downcase)"}' "$WORK_DIR/live-lines.jsonl" > "$WORK_DIR/live.jsonl"
  # Files of the kinds left to infrastructure as code that exist live are
  # reference copies, and don't warn. This only decides what the plan says,
  # so a failed listing warns about each file, as without what-if, instead
  # of failing the plan. A workspace without a managed virtual network
  # answers the endpoint list with a 400; ARM_EMPTY_WITHOUT_VNET (set above)
  # makes that an empty list here too, so the folder's endpoint files get the
  # one-note-per-kind treatment instead of a warning each.
  if ! arm_classify_left_to_iac "$WORK_DIR/left-to-iac.jsonl" "$endpoint" 2019-06-01-preview https://dev.azuresynapse.net 2> "$WORK_DIR/live.log"; then
    cat "$WORK_DIR/live.log" >&2
    log_warn "Couldn't list the integration runtimes and managed private endpoints of workspace ${workspace}, so the plan can't tell which of the folder's are reference copies of live ones and warns about each. The plan identity needs a Synapse role that reads them (Synapse Artifact User) to quiet them."
  fi
  jq -n --arg fingerprint "$(arm_synapse_fingerprint "$WORK_DIR/live-lines.jsonl")" --argjson kinds "$(printf '%s\n' "${kinds[@]}" | jq -R . | jq -sc .)" \
    '{fingerprint: $fingerprint, kinds: $kinds}' > "$PLAN_DIR/deploy/live.json"

  new="$(jq -cs --slurpfile live <(jq -s . "$WORK_DIR/live.jsonl") '
    ($live[0] | map(.key)) as $existing | map(select((.default | not) and (.key as $k | $existing | index($k) | not)))' "$WORK_DIR/template.jsonl")"
  if is_true "$DELETE_ARTIFACTS"; then
    # The deployer never deletes integration runtimes; endpoints are only
    # listed when they're deployed, and then it deletes those not in the
    # template. It leaves the service's defaults alone (by type: a pipeline
    # named like one is deleted as any other) and manages only the lake
    # databases that are Spark, SyMS ones (the others are a Spark job's).
    deletions="$(jq -cs --slurpfile template <(jq -s . "$WORK_DIR/template.jsonl") "
      (\$template[0] | map(.key)) as \$keep
      | map(select(.type != \"integrationRuntimes\"
          and (.type != \"databases\" or .lake == true)
          and (${ARM_SYNAPSE_IS_DEFAULT} | not)))
      | map(select(.key as \$k | \$keep | index(\$k) | not))
      | map({type, name, key})" "$WORK_DIR/live.jsonl")"
  fi
  log_info "$(jq length <<< "$new") new artifact(s), $(jq length <<< "$deletions") to delete"

  # The deployer publishes every artifact again, so the plan says which of
  # them would differ from the workspace: each template artifact, evaluated
  # as the deployer would publish it, against its live definition. Anything
  # the plan can't read or evaluate counts as a change, never as unchanged.
  log_step "Compare the artifacts with their live definitions"
  secret_parameters="$WORK_DIR/parameters-with-secrets.json"
  arm_parameters_with_secrets "$TEMPLATE" "$PARAMETERS_FILE" "$secret_parameters" 2> "$WORK_DIR/parameters.log" ||
    { cat "$WORK_DIR/parameters.log" >&2; fail "parameter-secrets is invalid." "$WORK_DIR/parameters.log"; }
  # The summary joins the result to the template's artifacts by position, so
  # a result that isn't one line per artifact, in the template's order, is as
  # good as a failed comparison
  compare_ok=false
  if arm_synapse_compare "$TEMPLATE" "$secret_parameters" "$workspace" "$WORK_DIR/template.jsonl" "$WORK_DIR/live.jsonl" > "$WORK_DIR/compare.jsonl" 2> "$WORK_DIR/compare.log"; then
    if [ "$(jq -s --slurpfile entries "$WORK_DIR/template.jsonl" '[.[].key] == [$entries[].key]' "$WORK_DIR/compare.jsonl" 2> /dev/null)" = true ]; then
      compare_ok=true
    else
      echo "The comparison didn't return one result per artifact of the template." >> "$WORK_DIR/compare.log"
    fi
  fi
  if [ "$compare_ok" != true ]; then
    cat "$WORK_DIR/compare.log" >&2
    log_warn "Couldn't compare the artifacts with workspace ${workspace}, so the plan counts every one that exists there as changed. Please report it at https://github.com/JoshSLawrence/actions/issues."
    jq -c --argjson new "$new" '
      {key} + (if .default then {status: "skipped", paths: []}
        elif (.key as $k | $new | any(.key == $k)) then {status: "create", paths: []}
        else {status: "unknown", paths: [{path: "properties", change: "unknown", why: "the comparison failed"}]} end)' "$WORK_DIR/template.jsonl" > "$WORK_DIR/compare.jsonl"
    compare_failed=true
  fi
  # The comparison's lines are in the template's order: join them back to
  # the template's names for the summary
  jq -s --slurpfile entries "$WORK_DIR/template.jsonl" '
    [., $entries] | transpose | map(.[0] + {type: .[1].type, name: .[1].name})' "$WORK_DIR/compare.jsonl" > "$WORK_DIR/artifacts.json"
  log_info "$(count_status modify) to modify, $(count_status create) new, $(jq length <<< "$deletions") to delete, $(count_status unknown) the plan can't compare, $(count_status secure) with secure values it can't compare, $(count_status unchanged) unchanged"

  # A pool is infrastructure the deployer neither creates nor checks: an
  # artifact for a missing one fails half-way through the apply
  log_step "Check the pools exist"
  subscription="$(arm_az account show --query id --output tsv)"
  workspace_url="https://management.azure.com/subscriptions/${subscription}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Synapse/workspaces/${workspace}"
  : > "$WORK_DIR/live-pools.jsonl"
  for collection in bigDataPools sqlPools; do
    if ! arm_rest_list "${workspace_url}/${collection}?api-version=2021-06-01" 2> "$WORK_DIR/live.log" |
      jq -c --arg kind "$([ "$collection" = bigDataPools ] && echo Spark || echo SQL)" '{kind: $kind, pool: (.name | ascii_downcase)}' >> "$WORK_DIR/live-pools.jsonl"; then
      cat "$WORK_DIR/live.log" >&2
      fail "Couldn't list the ${collection} of workspace ${workspace}. The plan identity needs read access to it (e.g. Reader on ${RESOURCE_GROUP}); or set what-if to false." "$WORK_DIR/live.log"
    fi
  done
  missing_pools="$(jq -rs --slurpfile pools "$WORK_DIR/live-pools.jsonl" --arg workspace "$workspace" '
    ($pools | map("\(.kind)/\(.pool)")) as $live
    | .[] | select("\(.kind)/\(.pool | ascii_downcase)" as $k | $live | index($k) | not)
    | "\(.artifact) uses \(.kind) pool \u0027\(.pool)\u0027, which workspace \($workspace) doesn\u0027t have. Pools are infrastructure: create it with your infrastructure as code (same name in every environment) and apply that first."' "$WORK_DIR/pools.jsonl")"
  if [ -n "$missing_pools" ]; then
    while IFS= read -r message; do
      log_error "$message"
    done <<< "$missing_pools"
    FAILED="$(paste -sd' ' - <<< "$missing_pools")"
    exit 1
  fi
  log_success "Every pool the artifacts use exists"
fi

arm_left_to_iac_warn "$WORK_DIR/left-to-iac.jsonl"

log_step "Summary"
deleted="$(jq length <<< "$deletions")"
if is_true "$WHAT_IF"; then
  created="$(count_status create)"
  modified="$(count_status modify)"
  unknown="$(count_status unknown)"
  secured="$(count_status secure)"
  unchanged="$(count_status unchanged)"
  nothing_to_change=false
  if [ $(($(count_changed) + deleted)) -eq 0 ]; then
    nothing_to_change=true
  fi
fi
{
  skipped_note=""
  if [ "$defaults" -gt 0 ]; then
    skipped_note="${defaults} service default(s) skipped"
  fi
  if is_true "$WHAT_IF"; then
    if [ "$nothing_to_change" = true ] && is_true "$ALWAYS_APPLY"; then
      echo "### 📋 Plan: no changes, applied anyway (always-apply)"
    elif [ "$nothing_to_change" = true ]; then
      echo "### ✅ No changes"
    else
      echo "### 📋 Plan: ${created} to create, ${modified} to modify, ${deleted} to delete"
    fi
  else
    echo "### 📋 Plan: deploy ${artifacts} artifact(s)${skipped_note:+ ($skipped_note)}"
  fi
  echo ""
  context_line
  echo ""
  if is_true "$WHAT_IF" && [ "$nothing_to_change" = true ]; then
    echo "Workspace \`${workspace}\` in \`${RESOURCE_GROUP}\` matches the template (${unchanged} artifact(s) unchanged${skipped_note:+, $skipped_note}). $(is_true "$ALWAYS_APPLY" && echo "Every artifact is published again." || echo "Nothing to deploy.")"
  elif is_true "$WHAT_IF"; then
    detail=""
    if [ "$unknown" -gt 0 ]; then
      detail="${detail}, ${unknown} the plan can't compare"
    fi
    if [ "$secured" -gt 0 ]; then
      detail="${detail}, ${secured} with secure values the plan can't compare (published again so a new value reaches the workspace)"
    fi
    echo "Workspace \`${workspace}\` in resource group \`${RESOURCE_GROUP}\`: ${unchanged} artifact(s) unchanged${detail}${skipped_note:+, $skipped_note}. The apply publishes every artifact again; these are the ones that differ from the workspace."
    if [ "$compare_failed" = true ]; then
      echo ""
      echo "> **Warning:** the comparison failed, so every artifact that exists in the workspace is listed as one the plan can't compare. Re-run the plan; if it fails again, please report it."
    fi
  else
    echo "Workspace \`${workspace}\` in resource group \`${RESOURCE_GROUP}\`. Every artifact in the template is published again; Synapse has no what-if, so this can't show which ones change."
    echo "What-if is off, so this doesn't show which artifacts differ from the workspace, are new$(is_true "$DELETE_ARTIFACTS" && echo ", or which the deployment deletes")."
  fi
  echo ""
  if [ "$deleted" -gt 0 ]; then
    echo "> **Warning:** the deployment deletes ${deleted} artifact(s) that are no longer in the folder:"
    jq -r '.[] | "> - `\(.type)/\(.name)`"' <<< "$deletions"
    echo ""
  fi
  if is_true "$WHAT_IF" && is_true "$DELETE_ARTIFACTS" && [ "$(jq -s 'map(select(.type == "databases")) | length' "$WORK_DIR/template.jsonl")" -gt 0 ]; then
    echo "> **Note:** the tables and relationships that a lake database in the folder no longer has are deleted too. They aren't counted or listed above."
    echo ""
  fi
  if is_true "$WHAT_IF"; then
    # Rows are the artifacts that differ, are new, or that the plan can't
    # compare; the unchanged and the service defaults are counted above
    artifact_rows="$(jq -r '
      def shown: gsub("\\|"; "\\|") | gsub("`"; "\u0027");
      def action_label: {modify: "🟡 modify", create: "🟢 create", secure: "🔒 secure, not compared", unknown: "⚪ can\u0027t compare"}[.];
      def order: {modify: 0, create: 1, secure: 2, unknown: 3}[.];
      def path_text:
        (if .change | IN("secure", "not-compared") then "🔒 " else "" end) + "`\(.path | shown)`"
        + (if .why then " (\(.why | shown))" else "" end);
      map(select(.status | IN("modify", "create", "secure", "unknown")))
      | sort_by([(.status | order), .type, .name])
      | .[]
      | (.paths | if length > 5 then (.[:5] | map(path_text)) + ["..."] else map(path_text) end | join(", ")) as $paths
      | "| \(.status | action_label) | `\(.type | shown)/\(.name | shown)` | \($paths) |"' "$WORK_DIR/artifacts.json")"
    details_open "Artifacts ($(grep -c . <<< "$artifact_rows" || true))"
    echo "| Action | Artifact | Changed properties |"
    echo "| --- | --- | --- |"
    if [ -n "$artifact_rows" ]; then
      echo "$artifact_rows"
    fi
  else
    details_open "Artifacts (${total})"
    echo "| Action | Artifact |"
    echo "| --- | --- |"
    jq -rs '
      sort_by(.type, .name)[]
      | "| \(if .default then "⚪ skipped (service default)" else "🔵 publish" end) | `\(.type)/\(.name)` |"' "$WORK_DIR/template.jsonl"
  fi
  echo ""
  echo "</details>"
  echo ""
  arm_left_to_iac_markdown "$WORK_DIR/left-to-iac.jsonl"
  echo ""
  details_open "Parameters"
  arm_parameters_markdown "$merged" "$TEMPLATE" "$secret_names"
  echo ""
  echo "</details>"
} > "$SUMMARY_FILE"
fit_github_body "$SUMMARY_FILE" "the workflow run's job summary"

# Without what-if the plan can't tell, so the apply stays on; with it, a
# deployment with nothing to create, change or delete skips its apply unless
# always-apply says otherwise
has_changes=true
if is_true "$WHAT_IF" && ! is_true "$ALWAYS_APPLY" && [ "$nothing_to_change" = true ]; then
  has_changes=false
fi

plan_sha256="$(arm_plan_sha256 "$PLAN_DIR")"
set_output has-changes "$has_changes"
set_output plan-sha256 "$plan_sha256"
log_summary "Planned workspace ${workspace} in ${RESOURCE_GROUP} (has changes: ${has_changes}, plan sha256 ${plan_sha256})"
