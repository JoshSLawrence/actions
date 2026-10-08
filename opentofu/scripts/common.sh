#!/usr/bin/env bash
# Common functions for the opentofu/* scripts: the shared library
# (shared/scripts/common.sh: logging, outputs, lists, mise, globs, markdown,
# GitHub comments), plus the OpenTofu and deployments sections below. Source
# it with:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=opentofu/scripts/common.sh
#   source "$SCRIPT_DIR/common.sh"

OPENTOFU_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$OPENTOFU_COMMON_DIR/../../shared/scripts/common.sh"

# --- OpenTofu -----------------------------------------------------------------

# Let `tofu init` fetch module sources from private GitHub repositories
# (git::https://github.com/..., git@github.com:...). Uses MODULES_GITHUB_TOKEN
# when set, otherwise GITHUB_TOKEN; a no-op without either (local runs use
# your own git credentials). The rewrite goes in a throwaway config file via
# GIT_CONFIG_GLOBAL, so the token never lands in a persistent config: in
# RUNNER_TEMP, which the runner empties after every job, so the token doesn't
# outlive the job on a self-hosted runner either.
configure_git_github_auth() {
  local token="${MODULES_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ]; then
    return 0
  fi

  log_info "Configuring Git credentials for GitHub-hosted module sources..."
  local git_config
  git_config="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/git-config.XXXXXX")"
  export GIT_CONFIG_GLOBAL="$git_config"

  local server="${GITHUB_SERVER_URL:-https://github.com}"
  local host="${server#https://}"
  local authed="https://x-access-token:${token}@${host}/"
  git config --global url."${authed}".insteadOf "https://${host}/"
  git config --global --add url."${authed}".insteadOf "ssh://git@${host}/"
  git config --global --add url."${authed}".insteadOf "git@${host}:"
}

# Print the init arguments shared by plan and apply: -var-file for each line
# of VAR_FILES -- a deployment's .tfvars sets its backend's variables (its
# state key) -- and -lockfile=readonly when the module commits a lock file,
# so plan and apply use exactly the provider versions and checksums recorded
# there.
# One argument per line; read with mapfile.
tofu_init_args() {
  echo "-input=false"
  # Deployments of one module share its .terraform directory when run in the
  # same workspace (locally, or a reused runner); -reconfigure makes init use
  # this deployment's backend settings instead of refusing because the last
  # one's differ. It never migrates state.
  echo "-reconfigure"
  if [ -f .terraform.lock.hcl ]; then
    echo "-lockfile=readonly"
  fi
  # A module without deployments has no var files; pass terraform.tfvars
  # explicitly, which plan would auto-load, in case the backend reads it.
  local line var_files_list
  var_files_list="$(list_items "${VAR_FILES:-}")"
  if [ -z "$var_files_list" ] && [ -f terraform.tfvars ]; then
    echo "-var-file=terraform.tfvars"
  elif [ -z "$var_files_list" ] && [ -f terraform.tfvars.json ]; then
    echo "-var-file=terraform.tfvars.json"
  elif [ -n "$var_files_list" ]; then
    while IFS= read -r line; do
      echo "-var-file=${line}"
    done <<< "$var_files_list"
  fi
}

# Warn once per job when the root module has no lock file: providers then
# resolve to whatever is newest at init time.
warn_if_no_lock_file() {
  if [ ! -f .terraform.lock.hcl ]; then
    log_warn "No .terraform.lock.hcl in ${WORKING_DIR}: provider versions aren't locked. Run 'tofu init' (or 'tofu providers lock -platform=linux_amd64 ...') and commit the lock file so every run uses the same provider builds."
  fi
}

# --- Azure credentials ----------------------------------------------------------
#
# The workflow's azure-* inputs and secrets, mapped to the azurerm provider's
# and backend's ARM_* variables (see azure-env.sh). azure-client-id is the
# apply identity (and, by default, the integration tests'); plan-azure-client-id
# overrides it for the plan job, and integration-test-azure-client-id for the
# integration test job, each as a pair with its client secret. A job with a
# client secret uses it, one without uses OIDC.

# Print what's wrong with the Azure inputs, one problem per line; nothing if
# they're consistent. Reads AZURE_CLIENT_ID, AZURE_TENANT_ID,
# PLAN_AZURE_CLIENT_ID, INTEGRATION_TEST_AZURE_CLIENT_ID, and
# HAS_AZURE_CLIENT_SECRET / HAS_PLAN_AZURE_CLIENT_SECRET /
# HAS_INTEGRATION_TEST_AZURE_CLIENT_SECRET ("true" if that secret was passed).
azure_input_problems() {
  if [ -z "${AZURE_CLIENT_ID:-}" ]; then
    if is_true "${HAS_AZURE_CLIENT_SECRET:-false}"; then
      echo "The azure-client-secret secret is set, but azure-client-id isn't. Pass the client ID it belongs to, or drop the secret."
    fi
    if [ -n "${PLAN_AZURE_CLIENT_ID:-}" ]; then
      echo "plan-azure-client-id is set, but azure-client-id isn't. azure-client-id is the apply identity; plan-azure-client-id only overrides it for the plan job."
    fi
    if [ -n "${INTEGRATION_TEST_AZURE_CLIENT_ID:-}" ]; then
      echo "integration-test-azure-client-id is set, but azure-client-id isn't. azure-client-id is the apply identity; integration-test-azure-client-id only overrides it for the integration test job."
    fi
  elif [ -z "${AZURE_TENANT_ID:-}" ]; then
    echo "azure-client-id is set, but azure-tenant-id isn't. Pass the tenant the identity belongs to."
  fi
  if is_true "${HAS_PLAN_AZURE_CLIENT_SECRET:-false}" && [ -z "${PLAN_AZURE_CLIENT_ID:-}" ]; then
    echo "The plan-azure-client-secret secret is set, but plan-azure-client-id isn't. Pass the plan identity's client ID, or drop the secret (the plan job then uses azure-client-id and its secret)."
  fi
  if is_true "${HAS_INTEGRATION_TEST_AZURE_CLIENT_SECRET:-false}" && [ -z "${INTEGRATION_TEST_AZURE_CLIENT_ID:-}" ]; then
    echo "The integration-test-azure-client-secret secret is set, but integration-test-azure-client-id isn't. Pass the integration test identity's client ID, or drop the secret (the integration tests then use azure-client-id and its secret)."
  fi
}
