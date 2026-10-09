#!/usr/bin/env bash
#
# Derives the names that must be unique per project, deployment and
# environment for the sqlproject/* actions -- the PR comment key, the
# artifact names, the title -- so many of them can run in one workflow run
# without clobbering each other.
#
#   WORKING_DIRECTORY=database/core DEPLOYMENT=dev sqlproject/scripts/names.sh
#
# Environment variables:
#   WORKING_DIRECTORY - the SQL project's folder, relative to the repository
#                       root
#   STACK_NAME        - display name (default: the working directory, or the
#                       repository name when that's the root)
#   DEPLOYMENT        - deployment name (its publish profile's), if any
#   APPLY_ENVIRONMENT - environment the plan is for, if any
#   REPOSITORY_NAME   - repository name, for a root-level project
#   DEPLOYMENTS, TARGET_DACPAC
#                     - the call's deployments and target-dacpac inputs. They
#                       key the dacpac artifact, so two calls for one folder
#                       and stack name (say, one per deploy mode) in one run
#                       don't overwrite each other's.
#
# Outputs:
#   key                  - "sqlproject:<stack>", plus ":<deployment>" and
#                          ":<environment>" when set
#   artifact-name        - plan artifact name derived from key (see
#                          artifact_name)
#   dacpac-artifact-name - build artifact name (per call: stack,
#                          deployments and target-dacpac)
#   title                - e.g. SQL project: `core` · `dev` → `core-dev`
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"

dir="${WORKING_DIRECTORY:-.}"
dir="${dir#./}"
dir="${dir%/}"
if [ -z "$dir" ] || [ "$dir" = "." ]; then
  dir="${REPOSITORY_NAME:-root}"
fi

stack="${STACK_NAME:-$dir}"
deployment="${DEPLOYMENT:-}"
environment="${APPLY_ENVIRONMENT:-}"

key="sqlproject:${stack}${deployment:+:${deployment}}${environment:+:${environment}}"
artifact="$(artifact_name sqlproject-plan "${stack}${deployment:+:${deployment}}${environment:+:${environment}}")"
# A short digest of the call's inputs keeps the name within artifact limits
# (the readable part of the stack name is cut; the digest covers all of it)
call_key="${stack}|$(list_items "${DEPLOYMENTS:-}" | paste -sd, -)|${TARGET_DACPAC:-}"
call_digest="$(text_sha256 "$call_key")"
dacpac_artifact="$(artifact_name sqlproject-dacpac "${stack:0:80}")-${call_digest:0:8}"

title="SQL project: \`${stack}\`"
if [ -n "$deployment" ]; then
  title="${title} · \`${deployment}\`"
fi
if [ -n "$environment" ]; then
  title="${title} → \`${environment}\`"
fi

log_config stack key artifact dacpac_artifact title
set_output key "$key"
set_output artifact-name "$artifact"
set_output dacpac-artifact-name "$dacpac_artifact"
set_output title "$title"
