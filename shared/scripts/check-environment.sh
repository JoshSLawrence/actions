#!/usr/bin/env bash
#
# Warns when the apply job runs without a reviewer gate. GitHub creates an
# environment the first time a workflow names it -- with no protection rules
# -- so a typo in an environment name, or a forgotten setup step, silently
# turns "apply after approval" into "apply immediately". Best effort: never
# fails the job, since some teams deliberately auto-apply (e.g. dev).
#
# Environment variables:
#   GH_TOKEN          - token for the GitHub API (actions: read)
#   GITHUB_REPOSITORY - owner/name
#   APPLY_ENVIRONMENT - the apply job's environment (empty: none)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

if [ -z "${APPLY_ENVIRONMENT:-}" ]; then
  log_warn "No apply environment is set, so nothing confirms this apply was approved. Run the apply job in a GitHub environment with required reviewers, and pass its name to the reusable workflow (apply-environment)."
  exit 0
fi

require_tool gh "GitHub CLI (gh)"
require_tool jq
require_env GITHUB_REPOSITORY

encoded="$(jq -rn --arg v "$APPLY_ENVIRONMENT" '$v | @uri')"
if ! environment="$(gh api "repos/${GITHUB_REPOSITORY}/environments/${encoded}" 2> /dev/null)"; then
  log_info "Couldn't read the protection rules of environment '${APPLY_ENVIRONMENT}' (the token may lack access); not checking them."
  exit 0
fi

if jq -e '[.protection_rules[]? | select(.type == "required_reviewers")] | length > 0' <<< "$environment" > /dev/null; then
  log_success "Environment '${APPLY_ENVIRONMENT}' requires a reviewer's approval"
else
  log_warn "Environment '${APPLY_ENVIRONMENT}' has no required reviewers, so this apply ran without approval. If that's not intended, add required reviewers in Settings -> Environments -> ${APPLY_ENVIRONMENT}."
fi
