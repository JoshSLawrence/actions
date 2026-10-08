#!/usr/bin/env bash
#
# Exports the azurerm provider's and backend's ARM_* variables for the rest
# of the job, from the workflow's azure-* inputs and secrets, for one job's
# role:
#
#   ARM_CLIENT_ID        - azure-client-id; for the plan job,
#                          plan-azure-client-id when given
#   ARM_CLIENT_SECRET    - that identity's secret (azure-client-secret, or
#                          plan-azure-client-secret with plan-azure-client-id)
#   ARM_USE_OIDC         - "true" when that identity has no secret
#   ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
#                        - azure-tenant-id, azure-subscription-id
#   ARM_USE_AZUREAD, ARM_STORAGE_USE_AZUREAD
#                        - azure-use-azuread (default true), on every call:
#                          Microsoft Entra ID (RBAC) auth for the state
#                          storage account and the provider's storage data
#                          plane
#
# Nothing else is set without azure-client-id. The plan identity switches as
# a pair: with plan-azure-client-id, the plan job never uses the apply
# identity's secret.
#
# Environment variables:
#   ROLE                     - plan, apply or test (required)
#   AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
#   AZURE_CLIENT_SECRET, PLAN_AZURE_CLIENT_ID, PLAN_AZURE_CLIENT_SECRET
#                            - the workflow's inputs and secrets (optional)
#   AZURE_USE_AZUREAD        - "true" (default) or "false"
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

case "${ROLE:-}" in
  plan | apply | test) ;;
  *)
    log_error "ROLE is '${ROLE:-}'. Set it to plan, apply or test."
    exit 1
    ;;
esac

HAS_AZURE_CLIENT_SECRET="$([ -n "${AZURE_CLIENT_SECRET:-}" ] && echo true || echo false)"
HAS_PLAN_AZURE_CLIENT_SECRET="$([ -n "${PLAN_AZURE_CLIENT_SECRET:-}" ] && echo true || echo false)"
problems="$(HAS_AZURE_CLIENT_SECRET="$HAS_AZURE_CLIENT_SECRET" \
  HAS_PLAN_AZURE_CLIENT_SECRET="$HAS_PLAN_AZURE_CLIENT_SECRET" azure_input_problems)"
if [ -n "$problems" ]; then
  while IFS= read -r problem; do
    log_error "$problem"
  done <<< "$problems"
  exit 1
fi

use_azuread=true
if ! is_true "${AZURE_USE_AZUREAD:-true}"; then
  use_azuread=false
fi
export_job_env ARM_USE_AZUREAD "$use_azuread"
export_job_env ARM_STORAGE_USE_AZUREAD "$use_azuread"

if [ -z "${AZURE_CLIENT_ID:-}" ]; then
  log_info "No azure-client-id: no Azure identity for the ${ROLE} job (Entra ID storage auth: ${use_azuread})."
  exit 0
fi

identity="azure-client-id"
client_id="$AZURE_CLIENT_ID"
client_secret="${AZURE_CLIENT_SECRET:-}"
if [ "$ROLE" = "plan" ] && [ -n "${PLAN_AZURE_CLIENT_ID:-}" ]; then
  identity="plan-azure-client-id"
  client_id="$PLAN_AZURE_CLIENT_ID"
  client_secret="${PLAN_AZURE_CLIENT_SECRET:-}"
fi

export_job_env ARM_CLIENT_ID "$client_id"
export_job_env ARM_TENANT_ID "$AZURE_TENANT_ID"
if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  export_job_env ARM_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID"
fi
if [ -n "$client_secret" ]; then
  mask_value "$client_secret"
  export_job_env ARM_CLIENT_SECRET "$client_secret"
  method="client secret"
else
  # ARM_OIDC_REQUEST_URL is deliberately not set; providers fall back to
  # ACTIONS_ID_TOKEN_REQUEST_URL
  export_job_env ARM_USE_OIDC true
  method="OIDC"
fi

log_success "Azure for the ${ROLE} job: ${identity} (${client_id}) with ${method}; Entra ID storage auth: ${use_azuread}"
