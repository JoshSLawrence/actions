#!/usr/bin/env bash
#
# Checks the module's terraform-docs generated README.md is up to date:
# regenerates it and fails if that changes anything. Uses the module's
# .terraform-docs.yml/.yaml when there is one (same as the pre-commit hook);
# otherwise injects a markdown table between the terraform-docs markers
# (<!-- BEGIN_TF_DOCS --> / <!-- END_TF_DOCS -->) in README.md.
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
require_mise_tool terraform-docs
require_tool git

if [ -f .terraform-docs.yml ] || [ -f .terraform-docs.yaml ]; then
  cmd=(terraform-docs .)
  regen_hint="terraform-docs ."
else
  log_notice "No .terraform-docs.yml in ${WORKING_DIR}; checking the markdown table between the terraform-docs markers in README.md."
  cmd=(terraform-docs markdown table --output-file README.md --output-mode inject .)
  regen_hint="terraform-docs markdown table --output-file README.md --output-mode inject ."
fi

log_cmd "${cmd[@]}"
if ! mise exec -- "${cmd[@]}"; then
  log_error "terraform-docs failed in ${WORKING_DIR}. Check .terraform-docs.yml (and the header file it references)."
  exit 1
fi

# README.md may be brand new (untracked) in the PR that adds it; with
# --intent-to-add git diff reports it instead of ignoring it.
git add --intent-to-add README.md
if git diff --exit-code -- README.md; then
  log_success "README.md is up to date"
else
  log_error "README.md is out of date in ${WORKING_DIR}. Run '${regen_hint}' there and commit the result."
  exit 1
fi
