#!/usr/bin/env bash
#
# TFLint check. Uses the module's .tflint.hcl when there is one (tflint finds
# it in the working directory), otherwise tflint's defaults.
#
# Environment variables:
#   WORKING_DIR      - root module to check (required)
#   TFLINT_RECURSIVE - also lint every module under WORKING_DIR (default: true)
#   VAR_FILES        - var files relative to WORKING_DIR, space- or
#                      newline-separated: the call's .tfvars, so rules see its
#                      values (optional)
#   GITHUB_TOKEN     - authenticates plugin downloads, avoiding GitHub API
#                      rate limits (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

cd_working_dir
ensure_mise
require_mise_tool tflint

if [ ! -f .tflint.hcl ]; then
  log_notice "No .tflint.hcl in ${WORKING_DIR}; linting with tflint's default rules. Add a .tflint.hcl to enable provider rulesets (e.g. azurerm)."
fi

log_cmd tflint --init
if ! mise exec -- tflint --init; then
  log_error "tflint --init failed in ${WORKING_DIR}: a plugin in .tflint.hcl couldn't be installed. Check its source and version exist."
  exit 1
fi

args=(--format compact)
if is_true "${TFLINT_RECURSIVE:-true}"; then
  args+=(--recursive)
fi
# Absolute paths: with --recursive, tflint resolves a relative --var-file in
# each module it visits, not in the root module
while IFS= read -r var_file; do
  if [ ! -f "$var_file" ]; then
    log_error "Var file '${var_file}' not found in ${WORKING_DIR}. Paths are relative to the root module."
    exit 1
  fi
  args+=("--var-file=${PWD}/${var_file}")
done < <(list_items "${VAR_FILES:-}")

log_cmd tflint "${args[@]}"
if mise exec -- tflint "${args[@]}"; then
  log_success "TFLint passed"
else
  log_error "TFLint found issues in ${WORKING_DIR}. Fix the findings above; only add a tflint-ignore with reviewer sign-off."
  exit 1
fi
