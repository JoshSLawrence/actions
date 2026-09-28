#!/usr/bin/env bash
#
# Derives the names that must be unique per folder, deployment and
# environment for the datafactory/* and synapse/* actions -- the PR comment
# key, the artifact names, the title -- so many of them can run in one
# workflow run without clobbering each other.
#
# Environment variables:
#   SERVICE           - "datafactory" or "synapse" (required): prefixes the
#                       key and artifacts, and picks the title
#   WORKING_DIRECTORY - factory/workspace folder, relative to the repository
#                       root
#   STACK_NAME        - display name (default: the working directory, or the
#                       repository name when that's the root)
#   DEPLOYMENT        - deployment name (its parameters file's), if any
#   APPLY_ENVIRONMENT - environment the plan is for, if any
#   REPOSITORY_NAME   - repository name, for a root-level folder
#
# Outputs:
#   key                    - "<service>:<stack>", plus ":<deployment>" and
#                            ":<environment>" when set (the environment only
#                            when it isn't the same as the deployment)
#   artifact-name          - plan artifact name derived from key
#   template-artifact-name - build artifact name (per folder, not deployment)
#   title                  - e.g. Data Factory: `adf` · `prod` → `production`
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_env SERVICE
case "$SERVICE" in
  datafactory) label="Data Factory" ;;
  synapse) label="Synapse" ;;
  *)
    log_error "Unknown SERVICE '${SERVICE}'. Use datafactory or synapse."
    exit 1
    ;;
esac

dir="${WORKING_DIRECTORY:-.}"
dir="${dir#./}"
dir="${dir%/}"
if [ -z "$dir" ] || [ "$dir" = "." ]; then
  dir="${REPOSITORY_NAME:-root}"
fi

stack="${STACK_NAME:-$dir}"
deployment="${DEPLOYMENT:-}"
environment="${APPLY_ENVIRONMENT:-}"
if [ "$environment" = "$deployment" ]; then
  environment=""
fi

# The service prefix keeps these apart from an OpenTofu stack in the same
# directory: PR comments are found by key.
key="${SERVICE}:${stack}${deployment:+:${deployment}}${environment:+:${environment}}"

# Artifact names can't contain " : < > | * ? \ / or CR/LF
sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}
artifact_name="${SERVICE}-plan-$(sanitize "${stack}${deployment:+:${deployment}}${environment:+:${environment}}")"
template_artifact_name="${SERVICE}-template-$(sanitize "$stack")"

title="${label}: \`${stack}\`"
if [ -n "$deployment" ]; then
  title="${title} · \`${deployment}\`"
fi
if [ -n "$environment" ]; then
  title="${title} → \`${environment}\`"
fi

log_config stack key artifact_name template_artifact_name title
set_output key "$key"
set_output artifact-name "$artifact_name"
set_output template-artifact-name "$template_artifact_name"
set_output title "$title"
