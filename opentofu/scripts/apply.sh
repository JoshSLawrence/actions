#!/usr/bin/env bash
#
# Applies a saved plan made by plan.sh. It applies exactly that plan -- the
# one that was reviewed and approved -- never a fresh one: its digest must
# match the plan job's, and OpenTofu refuses it if the state changed since it
# was made.
#
# Environment variables:
#   WORKING_DIR          - root module to apply (required)
#   PLAN_DIR             - directory holding tfplan, as downloaded from the
#                          plan artifact (default: $RUNNER_TEMP/tofu-plan)
#   PLAN_SHA256          - expected digest of tfplan, from the plan job
#                          (required in GitHub Actions)
#   BACKEND_CONFIG       - the same -backend-config values the plan used, one
#                          per line (optional)
#   MODULES_GITHUB_TOKEN - lets init fetch module sources from private GitHub
#                          repositories (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ensure_mise

PLAN_DIR="${PLAN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tofu-plan}"
if is_github_actions; then
  require_env PLAN_SHA256 "It comes from the plan job's plan-sha256 output; check the workflow passes it to the apply action."
fi

log_config WORKING_DIR PLAN_DIR PLAN_SHA256 BACKEND_CONFIG

if [ ! -f "$PLAN_DIR/tfplan" ]; then
  log_error "No plan file at ${PLAN_DIR}/tfplan. Plan artifacts expire (plan-retention-days); re-run the whole workflow to plan again."
  exit 1
fi
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
PLAN_FILE="$PLAN_DIR/tfplan"

if [ -n "${PLAN_SHA256:-}" ]; then
  actual_sha256="$(file_sha256 "$PLAN_FILE")"
  if [ "$actual_sha256" != "$PLAN_SHA256" ]; then
    log_error "tfplan's sha256 is ${actual_sha256}, but the plan job produced ${PLAN_SHA256}. Refusing to apply a plan that isn't the one that was reviewed; re-run the whole workflow."
    exit 1
  fi
  log_success "tfplan matches the reviewed plan (sha256 ${PLAN_SHA256})"
fi

cd_working_dir
require_mise_tool opentofu
configure_git_github_auth

# A module that doesn't commit its lock file gets the one the plan was made
# with, so init installs exactly the providers that planned (and the saved
# plan's provider checksums match).
if [ ! -f .terraform.lock.hcl ] && [ -f "$PLAN_DIR/.terraform.lock.hcl" ]; then
  log_info "Using the lock file saved with the plan (${WORKING_DIR} doesn't commit one)"
  cp "$PLAN_DIR/.terraform.lock.hcl" .terraform.lock.hcl
fi

mapfile -t init_args < <(tofu_init_args)

log_step "tofu init"
log_cmd tofu init "${init_args[@]}"
if ! mise exec -- tofu init "${init_args[@]}"; then
  log_error "tofu init failed. If it can't reach the state backend, check the apply job's cloud credentials (e.g. the Azure identity has a federated credential for the apply environment and data access to the state storage)."
  exit 1
fi

# A saved plan applies without prompting. The lock timeout rides out a local
# plan/apply briefly holding the state lock.
log_step "tofu apply"
APPLY_LOG="$(mktemp)"
trap 'rm -f "$APPLY_LOG"' EXIT
log_cmd tofu apply -input=false -lock-timeout=5m "$PLAN_FILE"
set +e
mise exec -- tofu apply -input=false -lock-timeout=5m "$PLAN_FILE" 2>&1 | tee "$APPLY_LOG"
apply_exit=${PIPESTATUS[0]}
set -e

if [ "$apply_exit" -ne 0 ]; then
  if grep -q "Saved plan is stale" "$APPLY_LOG"; then
    log_error "The state changed after this plan was made (another apply ran), so OpenTofu refused it. Nothing was applied. Re-run the whole workflow to plan against the current state."
  else
    log_error "tofu apply failed (exit ${apply_exit}); some changes may already be applied. Fix the error above and push to plan again, or roll back by running the workflow on the target branch."
  fi
  exit "$apply_exit"
fi

echo "### ✅ Applied \`${WORKING_DIR}\` (plan sha256 \`${PLAN_SHA256:-unknown}\`)" | append_step_summary
log_summary "Applied ${WORKING_DIR}"
