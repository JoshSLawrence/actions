#!/usr/bin/env bash
#
# Format check: fails if any .tf/.tfvars/.tftest.hcl file under WORKING_DIR
# isn't formatted the way `tofu fmt` would write it.
#
# Environment variables:
#   WORKING_DIR - root module to check (required)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

cd_working_dir
ensure_mise
require_mise_tool opentofu

log_cmd tofu fmt -check -recursive -diff
if mise exec -- tofu fmt -check -recursive -diff; then
  log_success "Format check passed"
else
  log_error "Format check failed in ${WORKING_DIR}. Run 'tofu fmt -recursive' there and commit the result."
  exit 1
fi
