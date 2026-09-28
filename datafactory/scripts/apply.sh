#!/usr/bin/env bash
#
# Deploys a plan made by datafactory/scripts/plan.sh -- exactly that plan:
# its digest must match the plan job's, and the target (factory, resource
# group) comes from the plan, not from inputs. Around an incremental ARM
# deployment, it runs the export's PrePostDeploymentScript.ps1 (see
# pre-post-deployment.ps1): stop the changed triggers before; delete what's
# no longer in the folder and start triggers after.
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
# shellcheck source=shared/scripts/arm.sh
source "$SCRIPT_DIR/../../shared/scripts/arm.sh"

ensure_mise
require_tool jq

PLAN_DIR="${PLAN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/datafactory-plan}"
PRE_POST_SCRIPT="${PRE_POST_SCRIPT:-true}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-ArmTemplateForFactory-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
log_config WORKING_DIR PLAN_DIR PLAN_SHA256 PRE_POST_SCRIPT DEPLOYMENT_NAME

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

cd_working_dir
require_mise_tool azure-cli
if is_true "$PRE_POST_SCRIPT"; then
  require_mise_tool powershell
fi

SECRETS_DIR="$(mktemp -d)"
trap 'rm -rf "$SECRETS_DIR"' EXIT
parameters_with_secrets="$SECRETS_DIR/parameters.json"
arm_parameters_with_secrets "$TEMPLATE" "$PARAMETERS_FILE" "$parameters_with_secrets"

# Run one phase of the pre/post-deployment script, signed in with a fresh
# token from the az session (a long deployment can outlive the first one)
pre_post() {
  local phase="$1" token account tenant subscription
  token="$(arm_az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv)"
  if is_github_actions; then
    echo "::add-mask::${token}"
  fi
  account="${ARM_CLIENT_ID:-$(arm_az account show --query user.name --output tsv)}"
  tenant="${ARM_TENANT_ID:-$(arm_az account show --query tenantId --output tsv)}"
  subscription="${ARM_SUBSCRIPTION_ID:-$(arm_az account show --query id --output tsv)}"

  log_step "${phase}-deployment script"
  log_cmd pwsh -File pre-post-deployment.ps1 -Phase "$phase" -DataFactoryName "$factory" -ResourceGroupName "$resource_group"
  AZURE_ACCESS_TOKEN="$token" AZURE_ACCOUNT_ID="$account" AZURE_TENANT_ID="$tenant" AZURE_SUBSCRIPTION_ID="$subscription" \
    mise exec -- pwsh -NoProfile -NonInteractive -File "$SCRIPT_DIR/pre-post-deployment.ps1" \
    -Phase "$phase" -TemplateDir "$TEMPLATE_DIR" -ParametersFile "$PARAMETERS_FILE" \
    -ResourceGroupName "$resource_group" -DataFactoryName "$factory"
}

if is_true "$PRE_POST_SCRIPT"; then
  if ! pre_post pre; then
    log_error "The pre-deployment script failed, so nothing was deployed. Some triggers may already be stopped: fix the error above and re-run the deploy (its post-deployment step restarts them)."
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
    stopped=" Triggers the pre-deployment script stopped are still stopped; a successful re-run starts them again."
  fi
  log_error "The ARM deployment ${DEPLOYMENT_NAME} failed; some resources may already be updated.${stopped} Fix the error above and push to plan again, or roll back by running the workflow on the target branch."
  exit 1
fi
log_success "Deployed ${DEPLOYMENT_NAME}"

if is_true "$PRE_POST_SCRIPT"; then
  if ! pre_post post; then
    log_error "The deployment succeeded, but the post-deployment script failed: some removed resources may not be deleted, or triggers not started. Fix the error above and re-run the deploy."
    exit 1
  fi
fi

echo "### ✅ Deployed factory \`${factory}\` in \`${resource_group}\` (plan sha256 \`${PLAN_SHA256:-unknown}\`)" | append_step_summary
log_summary "Deployed factory ${factory} in ${resource_group}"
