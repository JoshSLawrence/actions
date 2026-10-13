#!/usr/bin/env bash
#
# Plans one deployment of a Data Factory template: leaves out what
# infrastructure as code owns (see "Infrastructure kinds" in arm.sh), renders
# its parameters, optionally previews the deployment against the live
# factory, and writes the plan -- the template, the parameters and the
# target, which the apply deploys exactly -- with a markdown summary. Never
# changes anything, so it's safe to run locally:
#
#   WORKING_DIR=adf TEMPLATE_DIR=/tmp/datafactory-template \
#     PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev \
#     datafactory/scripts/plan.sh
#
# Environment variables:
#   WORKING_DIR       - the factory's Git root folder (required); parameter
#                       files are relative to it
#   TEMPLATE_DIR      - the exported template (datafactory/build's
#                       template-dir) (required)
#   PLAN_DIR          - where the plan goes (default:
#                       $RUNNER_TEMP/datafactory-plan): deploy/ (template,
#                       parameters.json, target.json and, with a what-if,
#                       live.json) and summary.md. The plan artifact; it
#                       never holds secrets.
#   WORK_DIR          - scratch directory, deleted at the end (default:
#                       $RUNNER_TEMP/datafactory-plan-work)
#   DEPLOYMENT        - the deployment's name, for the summary
#   PARAMETER_FILES   - ARM parameters files, in order (space- or
#                       newline-separated)
#   PARAMETERS        - name=value lines, after the files
#   PARAMETER_SECRETS - name=value lines for secure parameters; only used for
#                       the what-if (and to compare a secure property with
#                       the live one), never written to the plan or shown
#   RESOURCE_GROUP    - the target factory's resource group (required)
#   WHAT_IF           - "true": preview with az deployment group what-if,
#                       list what the post-deployment script would delete and
#                       record the live factory's fingerprint, which the
#                       apply checks (needs az signed in). Default false.
#   DEPLOY_MANAGED_PRIVATE_ENDPOINTS, DEPLOY_INTEGRATION_RUNTIMES
#                     - "true" deploys the folder's managed private
#                       endpoints / integration runtimes; the default false
#                       leaves them to infrastructure as code: they're taken
#                       out of the template, and the integration runtimes
#                       are left out of the deletions.
#   ALWAYS_APPLY      - "true": has-changes is true even when the what-if
#                       found nothing to change (to redeploy everything,
#                       e.g. after a change the what-if can't see). Default
#                       false.
#   PRE_POST_SCRIPT   - "true" (default) if the apply runs the
#                       pre/post-deployment script, which deletes resources
#                       that are no longer in the folder
#   TITLE             - heading for the job summary
#   HEAD_SHA, TARGET_BRANCH, TARGET_SHA, PR_NUMBER
#                     - describe what's being planned, for the summary
#
# Outputs:
#   has-changes    - "true" unless the what-if found nothing to change or
#                    delete ("true" without a what-if: it can't tell, and
#                    with ALWAYS_APPLY). A secure value the factory hides
#                    counts as a change.
#   plan-sha256    - digest of the plan's deploy/ directory
#   plan-dir       - absolute path of PLAN_DIR
#   summary-file   - the markdown summary (also on failure)
#   factory-name, resource-group - the target
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$SCRIPT_DIR/../../arm/scripts/arm.sh"

require_tool jq
require_env TEMPLATE_DIR "Set it to the template-dir of datafactory/build (or the downloaded template artifact)."
require_env RESOURCE_GROUP "Set the resource-group input."

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PLAN_DIR="${PLAN_DIR:-$TMP_ROOT/datafactory-plan}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/datafactory-plan-work}"
WHAT_IF="${WHAT_IF:-false}"
ALWAYS_APPLY="${ALWAYS_APPLY:-false}"
PRE_POST_SCRIPT="${PRE_POST_SCRIPT:-true}"
export DEPLOY_MANAGED_PRIVATE_ENDPOINTS="${DEPLOY_MANAGED_PRIVATE_ENDPOINTS:-false}"
export DEPLOY_INTEGRATION_RUNTIMES="${DEPLOY_INTEGRATION_RUNTIMES:-false}"

log_config WORKING_DIR TEMPLATE_DIR PLAN_DIR DEPLOYMENT PARAMETER_FILES RESOURCE_GROUP WHAT_IF ALWAYS_APPLY PRE_POST_SCRIPT DEPLOY_MANAGED_PRIVATE_ENDPOINTS DEPLOY_INTEGRATION_RUNTIMES

rm -rf "$PLAN_DIR" "$WORK_DIR"
mkdir -p "$PLAN_DIR/deploy" "$WORK_DIR"
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
SUMMARY_FILE="$PLAN_DIR/summary.md"
set_output plan-dir "$PLAN_DIR"
set_output summary-file "$SUMMARY_FILE"
set_output has-changes false

# Always leave a summary behind -- a failure's too, for the PR comment -- and
# delete the scratch files: they can hold secret parameter values.
finish() {
  local exit_code=$?
  if [ ! -s "$SUMMARY_FILE" ]; then
    arm_failure_markdown "${FAILED:-The plan failed.}" "${FAILED_LOG:-/dev/null}" > "$SUMMARY_FILE"
  fi
  {
    echo "## ${TITLE:-Data Factory plan}"
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

TEMPLATE_DIR="$(cd "$TEMPLATE_DIR" 2> /dev/null && pwd)" || fail "TEMPLATE_DIR doesn't exist. Point it at datafactory/build's template-dir."
[ -f "$TEMPLATE_DIR/ARMTemplateForFactory.json" ] || fail "No ARMTemplateForFactory.json in ${TEMPLATE_DIR}. Point TEMPLATE_DIR at datafactory/build's template-dir."
cp -R "$TEMPLATE_DIR" "$PLAN_DIR/deploy/template"
TEMPLATE="$PLAN_DIR/deploy/template/ARMTemplateForFactory.json"
PARAMETERS_FILE="$PLAN_DIR/deploy/parameters.json"

log_step "Infrastructure left to infrastructure as code"
# The plan, the what-if, the digest and the apply all use the stripped
# template, so the plan holds one template. The export's linked templates
# are the unstripped one in pieces, and nothing deploys them.
rm -rf "$PLAN_DIR/deploy/template/linkedTemplates"
arm_infrastructure_types datafactory > "$WORK_DIR/infrastructure-types.jsonl"
arm_strip_resources "$TEMPLATE" "$WORK_DIR/infrastructure-types.jsonl" "$WORK_DIR/stripped.json" "$WORK_DIR/left-to-iac.jsonl" "$WORK_DIR/dangling.jsonl"
mv "$WORK_DIR/stripped.json" "$TEMPLATE"
if ! arm_strip_problems "$WORK_DIR/dangling.jsonl" 2> "$WORK_DIR/strip.log"; then
  cat "$WORK_DIR/strip.log" >&2
  fail "The template has dependencies on resources this workflow leaves to infrastructure as code that the plan can't resolve, so ARM would reject it." "$WORK_DIR/strip.log"
fi
log_info "$(grep -c . "$WORK_DIR/left-to-iac.jsonl" || true) resource(s) left out of the deployment"
# Warned about below, once the live factory says which are reference copies

cd_working_dir

log_step "Parameters"
merged="$WORK_DIR/parameters-result.json"
arm_merge_parameters "$TEMPLATE" "$PLAN_DIR/deploy/template/ARMTemplateParametersForFactory.json" \
  "$(list_lines "${PARAMETERS:-}")" "parameters input" "$(list_items "${PARAMETER_FILES:-}")" > "$merged" 2> "$WORK_DIR/parameters.log" ||
  { cat "$WORK_DIR/parameters.log" >&2; fail "Couldn't read the parameters (see the output below)." "$WORK_DIR/parameters.log"; }
secret_names="$(list_lines "${PARAMETER_SECRETS:-}" | sed 's/=.*//; s/[[:space:]]*$//')"
if ! arm_check_parameters "$merged" factoryName 2> "$WORK_DIR/parameters.log"; then
  cat "$WORK_DIR/parameters.log" >&2
  fail "The deployment's parameters are invalid." "$WORK_DIR/parameters.log"
fi
missing="$(jq -r --arg s "$secret_names" '.missing - ($s | split("\n")) | .[]' "$merged")"
if [ -n "$missing" ]; then
  fail "No value for $(paste -sd, - <<< "$missing" | sed 's/,/, /g'), and the template has no default. Set them in a parameters file, the parameters input, or parameter-secrets."
fi
arm_write_parameters_file "$merged" "$PARAMETERS_FILE"

factory="$(jq -r '.parameters.factoryName.value // empty' "$PARAMETERS_FILE")"
[ -n "$factory" ] || fail "factoryName must be a plain value, not a Key Vault reference."
# What the plan left out, and whether it previewed the script's deletions, is
# recorded so the apply can check its own inputs against it
jq -n --arg service datafactory --arg deployment "${DEPLOYMENT:-}" --arg resource_group "$RESOURCE_GROUP" --arg name "$factory" \
  --argjson mpes "$(is_true "$DEPLOY_MANAGED_PRIVATE_ENDPOINTS" && echo true || echo false)" \
  --argjson irs "$(is_true "$DEPLOY_INTEGRATION_RUNTIMES" && echo true || echo false)" \
  --argjson pre_post "$(is_true "$PRE_POST_SCRIPT" && echo true || echo false)" \
  '{service: $service, deployment: $deployment, resource_group: $resource_group, name: $name,
    deploy_managed_private_endpoints: $mpes, deploy_integration_runtimes: $irs,
    pre_post_script: $pre_post}' > "$PLAN_DIR/deploy/target.json"
set_output factory-name "$factory"
set_output resource-group "$RESOURCE_GROUP"
log_success "Parameters rendered for factory ${factory} in ${RESOURCE_GROUP}"

changes="[]"
deletions="[]"
if is_true "$WHAT_IF"; then
  ensure_mise
  require_mise_tool azure-cli
  secret_parameters="$WORK_DIR/parameters-with-secrets.json"
  arm_parameters_with_secrets "$TEMPLATE" "$PARAMETERS_FILE" "$secret_parameters" 2> "$WORK_DIR/parameters.log" ||
    { cat "$WORK_DIR/parameters.log" >&2; fail "parameter-secrets is invalid." "$WORK_DIR/parameters.log"; }

  log_step "What-if"
  log_cmd az deployment group what-if --resource-group "$RESOURCE_GROUP" --template-file "$TEMPLATE" --parameters "@<parameters>"
  if ! arm_az deployment group what-if --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMPLATE" --parameters "@${secret_parameters}" \
    --no-pretty-print --output json > "$WORK_DIR/what-if.json" 2> "$WORK_DIR/what-if.log"; then
    cat "$WORK_DIR/what-if.log" >&2
    fail "az deployment group what-if failed. If it's a permissions error, the plan identity needs to run what-if on ${RESOURCE_GROUP} (e.g. Data Factory Contributor); or set what-if to false." "$WORK_DIR/what-if.log"
  fi
  # What-if leaves a secure parameter as "[parameters('x')]" in a delta, so a
  # property that comes from one always looks modified. Compare each with
  # its live value instead: equal drops the delta, and only a value the
  # factory hides is left as "not compared".
  arm_whatif_secure "$WORK_DIR/what-if.json" "$TEMPLATE" "$secret_parameters" > "$WORK_DIR/what-if-resolved.json" 2> "$WORK_DIR/what-if-parse.log" ||
    fail "Couldn't read the what-if result (see the output below). Please report it, with the az version, at https://github.com/JoshSLawrence/actions/issues." "$WORK_DIR/what-if-parse.log"
  # Every change to a resource of the factory, named by its type and name
  # under the factory (pipelines/pl_x). The factory itself, and anything else
  # in the resource group, is left alone by an incremental deployment.
  # Properties the service sets itself (a pipeline's lastPublishTime) show
  # up in every what-if as removed; a modification made only of those is no
  # change, or every plan would deploy again. A modification made only of
  # secure values the factory hides is a "Secure" one: it counts as a change.
  changes="$(jq -c --argjson managed "$ARM_SERVICE_MANAGED_PROPERTIES" '
    ($managed | map("properties." + .)) as $service_managed
    | [ .changes[]?
      | select(.changeType != "Ignore")
      | (.resourceId | capture("/factories/[^/]+/(?<rest>.+)$").rest // empty) as $rest
      | ($rest | split("/")) as $s
      | [.delta[]? | select(.path as $p | $service_managed | index($p) | not)] as $delta
      | ([$delta[] | select(.secure != "not-compared") | .path] | unique) as $properties
      | ([$delta[] | select(.secure == "not-compared") | .path] | unique) as $secure
      | ([$delta[] | select(.secure == "differs") | .path] | unique) as $secret_changes
      | {
          action: (if .changeType == "Modify" and ($properties | length) == 0 then
                     (if ($secure | length) > 0 then "Secure" else "NoChange" end)
                   else .changeType end),
          type: ([$s | to_entries[] | select(.key % 2 == 0) | .value] | join("/")),
          name: $s[-1],
          properties: $properties,
          secure: $secure,
          secret_changes: $secret_changes
        }
    ]' "$WORK_DIR/what-if-resolved.json" 2> "$WORK_DIR/what-if-parse.log")" ||
    fail "Couldn't read the what-if result (see the output below). Please report it, with the az version, at https://github.com/JoshSLawrence/actions/issues." "$WORK_DIR/what-if-parse.log"

  log_step "Live factory"
  subscription="$(arm_az account show --query id --output tsv)"
  factory_url="https://management.azure.com/subscriptions/${subscription}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DataFactory/factories/${factory}"
  # The kinds the post-deployment script deletes when they're not in the
  # template, plus the infrastructure kinds the call deploys. The apply lists
  # the same kinds again (live.json) to be sure nothing else changed them.
  kinds=(triggers pipelines dataflows datasets linkedservices)
  if is_true "$DEPLOY_INTEGRATION_RUNTIMES"; then
    kinds+=(integrationRuntimes)
  fi
  if is_true "$DEPLOY_MANAGED_PRIVATE_ENDPOINTS"; then
    kinds+=(managedVirtualNetworks/default/managedPrivateEndpoints)
  fi
  if ! arm_live_lines "$factory_url" 2018-06-01 "" "${kinds[@]}" > "$WORK_DIR/live.jsonl" 2> "$WORK_DIR/live.log"; then
    cat "$WORK_DIR/live.log" >&2
    fail "Couldn't list the resources of factory ${factory}. The plan identity needs read access to it (e.g. Reader on ${RESOURCE_GROUP})." "$WORK_DIR/live.log"
  fi
  # Files of the kinds left to infrastructure as code that exist live are
  # reference copies, and don't warn. This only decides what the plan says,
  # so a failed listing warns about each file, as without what-if, instead
  # of failing the plan.
  if ! arm_classify_left_to_iac "$WORK_DIR/left-to-iac.jsonl" "$factory_url" 2018-06-01 "" 2> "$WORK_DIR/live.log"; then
    cat "$WORK_DIR/live.log" >&2
    log_warn "Couldn't list the integration runtimes and managed private endpoints of factory ${factory}, so the plan can't tell which of the folder's are reference copies of live ones and warns about each. Give the plan identity read access to the factory (e.g. Reader on ${RESOURCE_GROUP}) to quiet them."
  fi
  jq -n --arg fingerprint "$(arm_live_fingerprint "$WORK_DIR/live.jsonl")" --argjson kinds "$(printf '%s\n' "${kinds[@]}" | jq -R . | jq -sc .)" \
    '{fingerprint: $fingerprint, kinds: $kinds}' > "$PLAN_DIR/deploy/live.json"

  # Names are compared without regard to case, as the script does
  if is_true "$PRE_POST_SCRIPT"; then
    log_step "Resources the post-deployment script would delete"
    deletions="$(jq -cs --slurpfile template <(arm_template_resources "$TEMPLATE" | jq -s .) '
      ($template[0] | map("\(.type | ascii_downcase)/\(.name | ascii_downcase)")) as $keep
      | map(select(.type != "managedVirtualNetworks/managedPrivateEndpoints"))
      | map(select(("\(.type | ascii_downcase)/\(.name | ascii_downcase)") as $k | $keep | index($k) | not))
      | map({type, name})' "$WORK_DIR/live.jsonl")"
    log_info "$(jq length <<< "$deletions") resource(s) to delete"
  fi
fi

arm_left_to_iac_warn "$WORK_DIR/left-to-iac.jsonl"

log_step "Summary"
count() {
  jq -r --arg a "$1" '[.[] | select(.action == $a)] | length' <<< "$changes"
}
resources="$(jq '.resources | length' "$TEMPLATE")"
deleted="$(jq length <<< "$deletions")"
{
  if is_true "$WHAT_IF"; then
    created="$(count Create)"
    modified="$(count Modify)"
    unchanged="$(count NoChange)"
    secured="$(count Secure)"
    unknown="$(jq -r '[.[] | select(.action == "Deploy" or .action == "Unsupported")] | length' <<< "$changes")"
    if [ $((created + modified + unknown + secured + deleted)) -eq 0 ] && is_true "$ALWAYS_APPLY"; then
      echo "### 📋 Plan: no changes, applied anyway (always-apply)"
      echo ""
      context_line
      echo ""
      echo "Factory \`${factory}\` in \`${RESOURCE_GROUP}\` matches the template (${unchanged} resource(s) unchanged). Everything is deployed again."
    elif [ $((created + modified + unknown + secured + deleted)) -eq 0 ]; then
      echo "### ✅ No changes"
      echo ""
      context_line
      echo ""
      echo "Factory \`${factory}\` in \`${RESOURCE_GROUP}\` matches the template (${unchanged} resource(s) unchanged). Nothing to deploy."
    else
      echo "### 📋 Plan: ${created} to create, ${modified} to modify, ${deleted} to delete"
      echo ""
      context_line
      echo ""
      unpredictable=""
      if [ "$unknown" -gt 0 ]; then
        unpredictable=", ${unknown} the what-if can't predict"
      fi
      if [ "$secured" -gt 0 ]; then
        unpredictable="${unpredictable}, ${secured} with secure values the what-if can't compare (deployed again so a new value reaches the factory)"
      fi
      echo "Factory \`${factory}\` in resource group \`${RESOURCE_GROUP}\`: ${unchanged} resource(s) unchanged${unpredictable}."
      echo ""
      if [ "$deleted" -gt 0 ]; then
        echo "> **Warning:** the post-deployment script deletes ${deleted} resource(s) that are no longer in the folder:"
        jq -r '.[] | "> - `\(.type)/\(.name)`"' <<< "$deletions"
        echo ""
      fi
      details_open "Resources ($(jq '[.[] | select(.action != "NoChange")] | length' <<< "$changes"))"
      echo "| Action | Resource | Changed properties |"
      echo "| --- | --- | --- |"
      jq -r '
        map(select(.action != "NoChange"))
        | sort_by([({Delete: 0, Modify: 1, Create: 2, Secure: 3}[.action] // 4), .type, .name])[]
        | ({Create: "🟢 create", Modify: "🟡 modify", Delete: "🔴 delete", Secure: "🔒 secure, not compared", Deploy: "⚪ deploy", Unsupported: "⚪ unsupported"}[.action] // .action) as $label
        | .secret_changes as $secret_changes
        | ((.properties | map({path: ., secret: (. as $p | $secret_changes | index($p) != null)})) + (.secure | map({path: ., secret: true}))
           | if length > 5 then (.[:5] | map((if .secret then "🔒 " else "" end) + "`\(.path)`")) + ["..."] else map((if .secret then "🔒 " else "" end) + "`\(.path)`") end
           | join(", ")) as $props
        | "| \($label) | `\(.type)/\(.name)` | \($props) |"' <<< "$changes"
      echo ""
      echo "</details>"
    fi
  else
    echo "### 📋 Plan: deploy ${resources} resource(s)"
    echo ""
    context_line
    echo ""
    echo "Factory \`${factory}\` in resource group \`${RESOURCE_GROUP}\`. What-if is off, so this doesn't show what would change$(is_true "$PRE_POST_SCRIPT" && echo ", or which resources the post-deployment script would delete")."
  fi
  echo ""
  arm_left_to_iac_markdown "$WORK_DIR/left-to-iac.jsonl"
  echo ""
  details_open "Parameters"
  arm_parameters_markdown "$merged" "$TEMPLATE" "$secret_names"
  echo ""
  echo "</details>"
} > "$SUMMARY_FILE"
fit_github_body "$SUMMARY_FILE" "the workflow run's job summary"

has_changes=true
if is_true "$WHAT_IF" && ! is_true "$ALWAYS_APPLY" && [ $(($(count Create) + $(count Modify) + $(count Secure) + $(jq -r '[.[] | select(.action == "Deploy" or .action == "Unsupported" or .action == "Delete")] | length' <<< "$changes") + deleted)) -eq 0 ]; then
  has_changes=false
fi

plan_sha256="$(arm_plan_sha256 "$PLAN_DIR")"
set_output has-changes "$has_changes"
set_output plan-sha256 "$plan_sha256"
log_summary "Planned factory ${factory} in ${RESOURCE_GROUP} (has changes: ${has_changes}, plan sha256 ${plan_sha256})"
