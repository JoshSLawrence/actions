#!/usr/bin/env bash
#
# Derives the names that must be unique per root module, deployment and
# environment -- the PR comment key, the plan artifact name, the title -- so
# many of them can run in one workflow run without clobbering each other.
#
# Environment variables:
#   WORKING_DIRECTORY - root module directory, relative to the repository root
#   STACK_NAME        - display name (default: the working directory, or the
#                       repository name when that's the root)
#   DEPLOYMENT        - deployment name (the .tfvars file's), if any
#   APPLY_ENVIRONMENT - environment the plan is for, if any
#   REPOSITORY_NAME   - repository name, for a root-level module
#
# Outputs:
#   key           - "<stack>", plus ":<deployment>" and ":<environment>"
#                   when set (the environment only when it isn't the same
#                   as the deployment)
#   artifact-name - plan artifact name derived from key
#   title         - e.g. OpenTofu: `infra` · `prod` → `production`
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

stack="${STACK_NAME:-$dir}"
deployment="${DEPLOYMENT:-}"
environment="${APPLY_ENVIRONMENT:-}"
if [ "$environment" = "$deployment" ]; then
  environment=""
fi

key="${stack}${deployment:+:${deployment}}${environment:+:${environment}}"

# Artifact names can't contain " : < > | * ? \ / or CR/LF
artifact_name="tofu-plan-$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '-')"

title="OpenTofu: \`${stack}\`"
if [ -n "$deployment" ]; then
  title="${title} · \`${deployment}\`"
fi
if [ -n "$environment" ]; then
  title="${title} → \`${environment}\`"
fi

log_config stack key artifact_name title
set_output key "$key"
set_output artifact-name "$artifact_name"
set_output title "$title"
