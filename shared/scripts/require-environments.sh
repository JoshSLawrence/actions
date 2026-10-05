#!/usr/bin/env bash
#
# Fails unless every GitHub environment a run is about to use already
# exists. GitHub creates an environment the first time a job names it --
# with no reviewers, branch rules or credentials -- so a typo, or a new
# directory naming an environment, would otherwise run unprotected. The
# caller creates each environment up front, with the rules it needs; this
# runs before any job names one, so nothing is ever created implicitly.
#
# Environment variables:
#   GH_TOKEN          - token for the GitHub API (actions: read)
#   GITHUB_REPOSITORY - owner/name
#   ENVIRONMENTS      - environment names, space- or newline-separated
#                       (empty: nothing to check)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

mapfile -t environments < <(list_items "${ENVIRONMENTS:-}" | LC_ALL=C sort -u)
if [ ${#environments[@]} -eq 0 ]; then
  log_info "No GitHub environments to check."
  exit 0
fi

require_tool gh "GitHub CLI (gh)"
require_tool jq
require_env GH_TOKEN
require_env GITHUB_REPOSITORY

log_info "Checking that these GitHub environments exist in ${GITHUB_REPOSITORY}: ${environments[*]}"

missing=()
unchecked=()
for environment in "${environments[@]}"; do
  encoded="$(jq -rn --arg v "$environment" '$v | @uri')"
  set +e
  error="$(gh api "repos/${GITHUB_REPOSITORY}/environments/${encoded}" 2>&1 > /dev/null)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    log_success "Environment '${environment}' exists"
  elif [[ "$error" == *"HTTP 404"* ]]; then
    missing+=("$environment")
  else
    log_warn "Couldn't read environment '${environment}': ${error}"
    unchecked+=("$environment")
  fi
done

for environment in "${missing[@]+"${missing[@]}"}"; do
  log_error "GitHub environment '${environment}' doesn't exist in ${GITHUB_REPOSITORY}, and environments are never created implicitly. Create it in Settings -> Environments, with the reviewers and credentials it needs, then re-run; or fix the name (a deployments/ subdirectory, default-apply-environment, plan-environment or integration-test-environment). On a private repository, environments need a paid plan."
done
if [ ${#unchecked[@]} -gt 0 ]; then
  log_error "Couldn't confirm these environments exist: ${unchecked[*]} (see the warnings above). Grant the calling job 'actions: read' and re-run."
fi
if [ ${#missing[@]} -gt 0 ] || [ ${#unchecked[@]} -gt 0 ]; then
  exit 1
fi

log_success "All ${#environments[@]} GitHub environment(s) exist"
