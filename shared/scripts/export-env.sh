#!/usr/bin/env bash
#
# Exports KEY=VALUE lines as environment variables for the rest of the job:
# provider settings and credentials (ARM_CLIENT_ID, TF_ENCRYPTION, ...) passed
# to a reusable workflow as one block, which can't take arbitrary env from its
# caller (opentofu-drift.yaml's env-vars secret). Deployments declare theirs
# by name instead: see export-declared.sh.
#
# Environment variables:
#   ENV_VARS - one KEY=VALUE per line. Blank lines and lines starting with #
#              are skipped. Values are taken verbatim (no quote stripping),
#              and can't span lines.
#   SOURCE   - where the lines come from, for messages (default: env-vars)
#   MASK     - "true" (default) masks every value in the log first: for
#              secrets. "false" for settings that aren't secret, whose short
#              values (like "true") would otherwise be masked everywhere.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

if [ -z "${ENV_VARS:-}" ]; then
  exit 0
fi
SOURCE="${SOURCE:-env-vars}"
MASK="${MASK:-true}"

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
    log_error "A ${SOURCE} line has no '=' (line not shown, it may be secret). Use one KEY=VALUE per line."
    exit 1
  fi
  key="${trimmed%%=*}"
  value="${trimmed#*=}"
  key="${key%"${key##*[![:space:]]}"}"

  problem="$(env_name_problem "$key")"
  if [ -n "$problem" ]; then
    log_error "Refusing a ${SOURCE} line: ${problem} Remove or rename it in ${SOURCE}."
    exit 1
  fi

  if is_true "$MASK"; then
    mask_value "$value"
  fi
  export_job_env "$key" "$value"
  names+=("$key")
  count=$((count + 1))
done <<< "$ENV_VARS"

log_success "Exported ${count} environment variable(s) from ${SOURCE} for the rest of the job: ${names[*]:-none}"
