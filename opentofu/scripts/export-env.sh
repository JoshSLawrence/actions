#!/usr/bin/env bash
#
# Exports KEY=VALUE lines from a (usually secret) input as environment
# variables for the rest of the job, masking every value in the log first.
# It's how non-Azure providers get credentials (e.g. AWS_ACCESS_KEY_ID,
# TF_VAR_*, TF_ENCRYPTION) through a reusable workflow, which can't take
# arbitrary env from its caller.
#
# Environment variables:
#   ENV_VARS - one KEY=VALUE per line. Blank lines and lines starting with #
#              are skipped. Values are taken verbatim (no quote stripping),
#              and can't span lines.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

if [ -z "${ENV_VARS:-}" ]; then
  exit 0
fi

# Variables that would let a value take over the runner or the job rather than
# configure a tool. Refused outright instead of silently exported.
RESERVED_REGEX='^(PATH|BASH_ENV|ENV|LD_PRELOAD|LD_LIBRARY_PATH|NODE_OPTIONS|GITHUB_.*|RUNNER_.*|ACTIONS_.*)$'

count=0
names=()
while IFS= read -r line || [ -n "$line" ]; do
  # Strip a trailing CR, so values pasted from Windows editors don't end in \r
  line="${line%$'\r'}"
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [ -z "$trimmed" ] && continue
  [[ "$trimmed" == \#* ]] && continue

  if [[ "$trimmed" != *=* ]]; then
    # Never log the line itself: it may be a secret missing its KEY=
    log_error "An env-vars line has no '=' (line not shown, it may be secret). Use one KEY=VALUE per line."
    exit 1
  fi
  key="${trimmed%%=*}"
  value="${trimmed#*=}"
  key="${key%"${key##*[![:space:]]}"}"

  if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    log_error "Invalid env-vars name '${key}'. Names must match [A-Za-z_][A-Za-z0-9_]*."
    exit 1
  fi
  if [[ "$key" =~ $RESERVED_REGEX ]]; then
    log_error "Refusing to set '${key}' from env-vars: it controls the runner itself, not a tool. Remove it from env-vars."
    exit 1
  fi

  if [ -n "$value" ]; then
    echo "::add-mask::${value}"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    # Heredoc syntax with a random delimiter, so a value can't end the
    # assignment early and inject further variables.
    delimiter="EOF_$(openssl rand -hex 16)"
    {
      echo "${key}<<${delimiter}"
      echo "${value}"
      echo "${delimiter}"
    } >> "$GITHUB_ENV"
  fi
  names+=("$key")
  count=$((count + 1))
done <<< "$ENV_VARS"

log_success "Exported ${count} environment variable(s) for the rest of the job: ${names[*]:-none}"
