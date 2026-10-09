#!/usr/bin/env bash
#
# Deploys a plan made by datafactory/scripts/plan.sh -- exactly that plan:
# its digest must match the plan job's, and the target (factory, resource
# group) comes from the plan, not from inputs. Around an incremental ARM
# deployment, it runs the export's PrePostDeploymentScript.ps1 (see
# pre-post-deployment.ps1): stop the changed triggers before; delete what's
# no longer in the folder and start triggers after. Before anything changes,
# it lists the factory again and refuses if it differs from the plan's
# (live.json): something else changed it since.
#
# Environment variables:
#   WORKING_DIR       - the factory's Git root folder, with its mise.toml
#                       (required)
#   PLAN_DIR          - the downloaded plan artifact (default:
#                       $RUNNER_TEMP/datafactory-plan)
#   PLAN_SHA256       - expected digest, from the plan job (required in
#                       GitHub Actions)
#   PARAMETER_SECRETS - name=value lines for secure parameters
#   PRE_POST_SCRIPT   - "true" (default) runs the pre/post-deployment script
#   DEPLOY_MANAGED_PRIVATE_ENDPOINTS, DEPLOY_INTEGRATION_RUNTIMES
#                     - what the plan was made with (default: the plan's);
#                       a different value is refused
#   DEPLOYMENT_NAME   - name of the ARM deployment (default:
#                       ArmTemplateForFactory-<run id>-<attempt>)
#   ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
#                     - the identity az is signed in as, for the pre/post
#                       script (default: read from az)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$SCRIPT_DIR/../../arm/scripts/arm.sh"

ensure_mise
require_tool jq

PLAN_DIR="${PLAN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/datafactory-plan}"
INPUT_PRE_POST_SCRIPT="${PRE_POST_SCRIPT:-}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-ArmTemplateForFactory-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
log_config WORKING_DIR PLAN_DIR PLAN_SHA256 PRE_POST_SCRIPT DEPLOYMENT_NAME DEPLOY_MANAGED_PRIVATE_ENDPOINTS DEPLOY_INTEGRATION_RUNTIMES

arm_verify_plan "$PLAN_DIR"
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
TEMPLATE_DIR="$PLAN_DIR/deploy/template"
TEMPLATE="$TEMPLATE_DIR/ARMTemplateForFactory.json"
PARAMETERS_FILE="$PLAN_DIR/deploy/parameters.json"

if [ "$(jq -r .service "$PLAN_DIR/deploy/target.json")" != "datafactory" ]; then
  log_error "The plan at ${PLAN_DIR} isn't a Data Factory plan. Download the datafactory/plan artifact there."
  exit 1
fi
resource_group="$(jq -r .resource_group "$PLAN_DIR/deploy/target.json")"
factory="$(jq -r .name "$PLAN_DIR/deploy/target.json")"
log_info "Deploying factory ${factory} in resource group ${resource_group}"

# What the plan left out, and whether it previewed the post-deployment
# script's deletions, decide what the apply may delete: a different input is
# refused rather than trusted
deploy_integration_runtimes="$(arm_planned_setting "$PLAN_DIR" deploy_integration_runtimes deploy-integration-runtimes "${DEPLOY_INTEGRATION_RUNTIMES:-}" false)" || exit 1
arm_planned_setting "$PLAN_DIR" deploy_managed_private_endpoints deploy-managed-private-endpoints "${DEPLOY_MANAGED_PRIVATE_ENDPOINTS:-}" false > /dev/null || exit 1
PRE_POST_SCRIPT="$(arm_planned_setting "$PLAN_DIR" pre_post_script pre-post-script "$INPUT_PRE_POST_SCRIPT" true)" || exit 1

cd_working_dir
require_mise_tool azure-cli
if is_true "$PRE_POST_SCRIPT"; then
  require_mise_tool powershell
fi

SECRETS_DIR="$(mktemp -d)"
trap 'rm -rf "$SECRETS_DIR"' EXIT
parameters_with_secrets="$SECRETS_DIR/parameters.json"
arm_parameters_with_secrets "$TEMPLATE" "$PARAMETERS_FILE" "$parameters_with_secrets"

subscription="$(arm_az account show --query id --output tsv)"
factory_url="https://management.azure.com/subscriptions/${subscription}/resourceGroups/${resource_group}/providers/Microsoft.DataFactory/factories/${factory}"

if [ -f "$PLAN_DIR/deploy/live.json" ]; then
  log_step "Check the factory is as planned"
  mapfile -t kinds < <(jq -r '.kinds[]' "$PLAN_DIR/deploy/live.json")
  if ! arm_live_lines "$factory_url" 2018-06-01 "" "${kinds[@]}" > "$SECRETS_DIR/live.jsonl" 2> "$SECRETS_DIR/live.log"; then
    cat "$SECRETS_DIR/live.log" >&2
    arm_refuse "$PLAN_DIR" "Couldn't list the resources of factory ${factory} to check it hasn't changed since the plan. The apply identity needs read access to it; then re-run all jobs of the workflow."
    exit 1
  fi
  now="$(arm_live_fingerprint "$SECRETS_DIR/live.jsonl")" || exit 1
  arm_verify_live Factory "$factory" "$PLAN_DIR" "$now" || exit 1
else
  log_warn "The plan has no live.json (what-if was off), so the check that the factory is unchanged since the plan is skipped."
fi

# The post-deployment script deletes every integration runtime that isn't in
# the template. The template has none when infrastructure as code owns them
# (the factory's AutoResolveIntegrationRuntime is one), so the script reads a
# copy whose template also lists every live integration runtime, by name
# only: all it reads of one is its type and name, and it takes the name out
# of "[concat(parameters('factoryName'), '/<name>')]" by position. The ARM
# deployment still uses the plan's template. Built right before the post
# phase, because the deployment before it can take minutes and the list must
# be the one the script deletes against; a list cut short would delete
# runtimes, so any failure stops here.
# Sets SCRIPT_TEMPLATE_DIR.
keep_integration_runtimes() {
  local stub_failed live_count plan_count expected
  SCRIPT_TEMPLATE_DIR="$TEMPLATE_DIR"
  is_true "$deploy_integration_runtimes" && return 0
  log_step "Keep the integration runtimes"
  if ! arm_rest_list "${factory_url}/integrationRuntimes?api-version=2018-06-01" > "$SECRETS_DIR/integration-runtimes.jsonl" 2> "$SECRETS_DIR/live.log"; then
    cat "$SECRETS_DIR/live.log" >&2
    log_error "The deployment succeeded, but listing the integration runtimes of factory ${factory} failed, so the post-deployment script can't be told to keep them and wasn't run: removed resources may not be deleted, and triggers not started. The apply identity needs read access to the factory; then re-run all jobs of the workflow."
    return 1
  fi
  # Every command here ends the function on failure: set -e is off in a
  # function the caller tests with ||, and a template left empty would make
  # the script delete everything, as an empty template lists nothing to keep.
  stub_failed="The deployment succeeded, but building the template that tells the post-deployment script which integration runtimes to keep failed, so the script was not run: removed resources may not be deleted, and triggers not started. Re-run all jobs of the workflow."
  rm -rf "$SECRETS_DIR/script-template" || return 1
  SCRIPT_TEMPLATE_DIR="$SECRETS_DIR/script-template"
  if ! cp -R "$TEMPLATE_DIR" "$SCRIPT_TEMPLATE_DIR" ||
    ! jq --slurpfile live "$SECRETS_DIR/integration-runtimes.jsonl" '
    .resources += [ $live[] | {
      type: "Microsoft.DataFactory/factories/integrationRuntimes",
      name: ("[concat(parameters(\u0027factoryName\u0027), \u0027/" + .name + "\u0027)]")
    } ]' "$TEMPLATE" > "$SCRIPT_TEMPLATE_DIR/ARMTemplateForFactory.json"; then
    log_error "$stub_failed"
    return 1
  fi
  live_count="$(jq -s length "$SECRETS_DIR/integration-runtimes.jsonl")" || { log_error "$stub_failed"; return 1; }
  plan_count="$(jq '.resources | length' "$TEMPLATE")" || { log_error "$stub_failed"; return 1; }
  expected=$((plan_count + live_count))
  if ! arm_verify_resource_count "$SCRIPT_TEMPLATE_DIR/ARMTemplateForFactory.json" "$expected"; then
    log_error "The template for the post-deployment script is not valid JSON with the plan's resources plus the ${live_count} live integration runtime(s) (${expected} in all), so the script was not run: it would delete every resource it does not find. Removed resources may not be deleted, and triggers not started. Re-run all jobs of the workflow."
    return 1
  fi
  log_info "${live_count} integration runtime(s) kept"
}

# Run one phase of the pre/post-deployment script, signed in with a fresh
# token from the az session (a long deployment can outlive the first one).
# The pre phase reads the plan's template; the post phase, the one
# keep_integration_runtimes made.
pre_post() {
  local phase="$1" token account tenant subscription
  token="$(arm_az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv)"
  mask_value "$token"
  account="${ARM_CLIENT_ID:-$(arm_az account show --query user.name --output tsv)}"
  tenant="${ARM_TENANT_ID:-$(arm_az account show --query tenantId --output tsv)}"
  subscription="${ARM_SUBSCRIPTION_ID:-$(arm_az account show --query id --output tsv)}"

  log_step "${phase}-deployment script"
  log_cmd pwsh -File pre-post-deployment.ps1 -Phase "$phase" -DataFactoryName "$factory" -ResourceGroupName "$resource_group"
  AZURE_ACCESS_TOKEN="$token" AZURE_ACCOUNT_ID="$account" AZURE_TENANT_ID="$tenant" AZURE_SUBSCRIPTION_ID="$subscription" \
    mise exec -- pwsh -NoProfile -NonInteractive -File "$SCRIPT_DIR/pre-post-deployment.ps1" \
    -Phase "$phase" -TemplateDir "$SCRIPT_TEMPLATE_DIR" -ParametersFile "$PARAMETERS_FILE" \
    -ResourceGroupName "$resource_group" -DataFactoryName "$factory"
}

SCRIPT_TEMPLATE_DIR="$TEMPLATE_DIR"
if is_true "$PRE_POST_SCRIPT"; then
  if ! pre_post pre; then
    log_error "The pre-deployment script failed, so nothing was deployed. Some triggers may already be stopped: fix the error above and re-run all jobs of the workflow, not just the failed one (the factory has changed since the plan, so that plan would be refused); the new apply's post-deployment step restarts them."
    exit 1
  fi
fi

log_step "ARM deployment"
log_cmd az deployment group create --resource-group "$resource_group" --name "$DEPLOYMENT_NAME" --template-file "$TEMPLATE" --parameters "@<parameters>" --mode Incremental
if ! arm_az deployment group create --resource-group "$resource_group" --name "$DEPLOYMENT_NAME" \
  --template-file "$TEMPLATE" --parameters "@${parameters_with_secrets}" \
  --mode Incremental --output none; then
  stopped=""
  if is_true "$PRE_POST_SCRIPT"; then
    stopped=" Triggers the pre-deployment script stopped are still stopped; a successful new apply starts them again."
  fi
  log_error "The ARM deployment ${DEPLOYMENT_NAME} failed; some resources may already be updated.${stopped} Fix the error above and re-run all jobs of the workflow (or push) to plan again, not just the failed one (the factory has changed since the plan, so that plan would be refused), or roll back by running the workflow on the target branch."
  exit 1
fi
log_success "Deployed ${DEPLOYMENT_NAME}"

if is_true "$PRE_POST_SCRIPT"; then
  keep_integration_runtimes || exit 1
  if ! pre_post post; then
    log_error "The deployment succeeded, but the post-deployment script failed: some removed resources may not be deleted, or triggers not started. Fix the error above and re-run all jobs of the workflow, not just the failed one (the factory has changed since the plan, so that plan would be refused)."
    exit 1
  fi
fi

echo "### ✅ Deployed factory \`${factory}\` in \`${resource_group}\` (plan sha256 \`${PLAN_SHA256:-unknown}\`)" | append_step_summary
log_summary "Deployed factory ${factory} in ${resource_group}"
