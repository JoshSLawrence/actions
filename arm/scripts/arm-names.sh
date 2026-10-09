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
#   DEPLOYMENTS, PARAMETER_FILES
#                     - the call's deployments and shared parameters files:
#                       they key the template artifact, so two calls for one
#                       folder and stack name in one run don't overwrite
#                       each other's
#   APPLY_ENVIRONMENT - environment the plan is for, if any
#   REPOSITORY_NAME   - repository name, for a root-level folder
#
# Outputs:
#   key                    - "<service>:<stack>", plus ":<deployment>" and
#                            ":<environment>" when set
#   artifact-name          - plan artifact name derived from key (see
#                            artifact_name)
#   template-artifact-name - build artifact name (per call: stack,
#                            deployments and parameter files)
#   title                  - e.g. Data Factory: `adf` · `prod` → `production`
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"

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

# The service prefix keeps a Data Factory and a Synapse folder at the same
# path apart: PR comments are found by key.
key="${SERVICE}:${stack}${deployment:+:${deployment}}${environment:+:${environment}}"

artifact="$(artifact_name "${SERVICE}-plan" "${stack}${deployment:+:${deployment}}${environment:+:${environment}}")"
# A short digest of the call's inputs keeps the name within artifact limits
# (the readable part of the stack name is cut; the digest covers all of it)
call_key="${stack}|$(list_items "${DEPLOYMENTS:-}" | paste -sd, -)|$(list_items "${PARAMETER_FILES:-}" | paste -sd, -)"
call_digest="$(text_sha256 "$call_key")"
template_artifact="$(artifact_name "${SERVICE}-template" "${stack:0:80}")-${call_digest:0:8}"

title="${label}: \`${stack}\`"
if [ -n "$deployment" ]; then
  title="${title} · \`${deployment}\`"
fi
if [ -n "$environment" ]; then
  title="${title} → \`${environment}\`"
fi

log_config stack key artifact template_artifact title
set_output key "$key"
set_output artifact-name "$artifact"
set_output template-artifact-name "$template_artifact"
set_output title "$title"
