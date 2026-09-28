#!/usr/bin/env bash
#
# Trivy misconfiguration scan. Trivy reads the module's trivy.yaml from the
# working directory when there is one (the same file a pre-commit hook would
# use), so local and CI results match.
#
# Environment variables:
#   WORKING_DIR    - root module to scan (required)
#   TRIVY_SEVERITY - severities that fail the scan, e.g. CRITICAL,HIGH.
#                    Default: trivy.yaml's setting if it has one, otherwise
#                    CRITICAL,HIGH.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

cd_working_dir
ensure_mise
require_mise_tool trivy

# --exit-code 1 always: a trivy.yaml without it would make the scan report
# findings and still pass, silently disabling the check.
args=(config --skip-version-check --format table --exit-code 1)

config_file=""
for candidate in trivy.yaml trivy.yml; do
  if [ -f "$candidate" ]; then
    config_file="$candidate"
    break
  fi
done

if [ -n "${TRIVY_SEVERITY:-}" ]; then
  args+=(--severity "$TRIVY_SEVERITY")
elif [ -n "$config_file" ] && grep -qE '^[[:space:]]*severity:' "$config_file"; then
  log_info "Using the severity from ${config_file}"
else
  args+=(--severity "CRITICAL,HIGH")
fi

if [ -n "$config_file" ]; then
  args+=(--config "$config_file")
else
  log_notice "No trivy.yaml in ${WORKING_DIR}; scanning with the workflow's settings. Add a trivy.yaml to share settings with local runs."
fi

log_info "Trivy version: $(mise exec -- trivy --version | head -1)"
log_cmd trivy "${args[@]}" .
if mise exec -- trivy "${args[@]}" .; then
  log_success "Trivy scan passed"
else
  log_error "Trivy found misconfigurations in ${WORKING_DIR} (or failed to run). Fix the findings above; only add a trivy:ignore with reviewer sign-off."
  exit 1
fi
