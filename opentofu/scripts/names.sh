#!/usr/bin/env bash
#
# Derives the names that must be unique per root module, deployment and
# environment -- the PR comment key, the plan artifact name, the title -- so
# many of them can run in one workflow run without clobbering each other.
#
# Environment variables:
#   WORKING_DIRECTORY - root module directory, relative to the repository root
#                       (shown as the repository name when that's the root)
#   DEPLOYMENT        - the call's name (e.g. prod-eastus), if any
#   APPLY_ENVIRONMENT - environment the plan is for, if any
#   VAR_FILES         - the call's var files, space- or newline-separated
#   REPOSITORY_NAME   - repository name, for a root-level module
#
# Outputs:
#   key           - "<stack>", plus ":<deployment>" and ":<environment>"
#                   when set, and "@<digest of the var files>" with var files
#   artifact-name - plan artifact name derived from key (see artifact_name)
#   title         - what applies where, e.g.
#                   OpenTofu: `iac/identity` · `beans` → `prod`
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

dir="${WORKING_DIRECTORY:-.}"
dir="${dir#./}"
dir="${dir%/}"
if [ -z "$dir" ] || [ "$dir" = "." ]; then
  dir="${REPOSITORY_NAME:-root}"
fi

stack="$dir"
deployment="${DEPLOYMENT:-}"
environment="${APPLY_ENVIRONMENT:-}"

key="${stack}${deployment:+:${deployment}}${environment:+:${environment}}"
# The default name is only the last var file's base name, so two calls of a
# module whose var files share one (eastus/prod.tfvars, westus/prod.tfvars)
# would share a comment, an artifact and their concurrency groups. The var
# files themselves keep them apart.
var_files="$(list_items "${VAR_FILES:-}")"
if [ -n "$var_files" ]; then
  digest="$(text_sha256 "$var_files")"
  key="${key}@${digest:0:12}"
fi
artifact="$(artifact_name tofu-plan "$key")"

title="OpenTofu: \`${stack}\`"
if [ -n "$deployment" ]; then
  title="${title} · \`${deployment}\`"
fi
if [ -n "$environment" ]; then
  title="${title} → \`${environment}\`"
fi

log_config stack VAR_FILES key artifact title
set_output key "$key"
set_output artifact-name "$artifact"
set_output title "$title"
