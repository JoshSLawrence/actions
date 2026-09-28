#!/usr/bin/env bash
#
# Derives the names that must be unique per root module and environment --
# the PR comment key, the plan artifact name, the comment title -- so several
# modules/environments can be planned in one run (a matrix, or chained calls)
# without clobbering each other.
#
# Environment variables:
#   WORKING_DIRECTORY - root module directory, relative to the repository root
#   STACK_NAME        - display name (default: the working directory, or the
#                       repository name when that's the root)
#   APPLY_ENVIRONMENT - environment the plan is for, if any
#   REPOSITORY_NAME   - repository name, for a root-level module
#
# Outputs:
#   stack         - display name of the module
#   key           - "<stack>" or "<stack>:<environment>"
#   artifact-name - plan artifact name derived from key
#   title         - heading for the PR comment and job summary
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
environment="${APPLY_ENVIRONMENT:-}"
key="${stack}${environment:+:${environment}}"

# Artifact names can't contain " : < > | * ? \ / or CR/LF
artifact_name="tofu-plan-$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '-')"

title="OpenTofu: \`${stack}\`"
if [ -n "$environment" ]; then
  title="${title} → \`${environment}\`"
fi

log_config stack key artifact_name title
set_output stack "$stack"
set_output key "$key"
set_output artifact-name "$artifact_name"
set_output title "$title"
