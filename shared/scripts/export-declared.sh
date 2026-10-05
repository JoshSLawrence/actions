#!/usr/bin/env bash
#
# Exports what a deployment file declares as environment variables for the
# rest of the job: literal values, and GitHub variables and secrets by name.
# Only declared names are exported, so a deployment gets exactly what its file
# lists, whatever else its environment holds.
#
# GitHub resolves variables and secrets in the job's environment, so the job
# passes everything it can see (toJSON(vars), toJSON(secrets)) and this picks
# out the declared names. A name resolves to the job environment's value,
# else the repository's, else the organization's (GitHub's own order).
#
# Environment variables:
#   DEPLOYMENT_FILE - the file that declares them, for messages
#   JOB_ENVIRONMENT - the job's GitHub environment, for messages
#   ENV_JSON        - JSON object of literal values, NAME: value (optional)
#   VAR_NAMES       - GitHub variables to export, space- or newline-separated:
#                     NAME, or EXPORT_NAME=GITHUB_NAME to export one under
#                     another name (optional)
#   SECRET_NAMES    - the same for GitHub secrets, masked in the log
#                     (optional)
#   VARS_JSON       - the job's toJSON(vars)
#   SECRETS_JSON    - the job's toJSON(secrets) (only needed with SECRET_NAMES)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool jq

FILE="${DEPLOYMENT_FILE:-the deployment file}"
WHERE="the repository or the organization"
if [ -n "${JOB_ENVIRONMENT:-}" ]; then
  WHERE="environment '${JOB_ENVIRONMENT}', ${WHERE}"
fi

problems=()
names=()
kinds=()
values=()
declare -A SEEN

# Queue one export, refusing names that can't be set or are declared twice
add() {
  local name="$1" kind="$2" value="$3" problem
  problem="$(env_name_problem "$name")"
  if [ -n "$problem" ]; then
    problems+=("${FILE}: ${problem}")
    return
  fi
  if [ -n "${SEEN[$name]+set}" ]; then
    problems+=("${FILE}: ${name} is declared twice (${SEEN[$name]} and ${kind}). Keep one.")
    return
  fi
  SEEN["$name"]="$kind"
  names+=("$name")
  kinds+=("$kind")
  values+=("$value")
}

# Print the value of a name in a toJSON(vars|secrets) object, base64-encoded
# (values may span lines), matching names case-insensitively as GitHub does.
# Nothing if it's missing or empty.
lookup() {
  jq -r --arg name "$2" '
    [to_entries[] | select((.key | ascii_upcase) == ($name | ascii_upcase)) | .value]
    | map(select(. != null and . != "")) | first // empty | tostring | @base64
  ' <<< "$1"
}

# Queue the GitHub variables or secrets declared in a list
add_declared() {
  local kind="$1" items="$2" store="$3" item export_name source encoded key
  key="vars"
  [ "$kind" = "secret" ] && key="secrets"
  while IFS= read -r item; do
    export_name="${item%%=*}"
    source="${item#*=}"
    if ! [[ "$source" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      problems+=("${FILE}: '${item}' in ${key} isn't NAME or EXPORT_NAME=GITHUB_NAME.")
      continue
    fi
    if [[ "$(printf '%s' "$source" | tr '[:lower:]' '[:upper:]')" == GITHUB_* ]]; then
      problems+=("${FILE}: GitHub doesn't allow ${kind}s named GITHUB_*, so '${source}' can't be one. Store it under another name and export it as ${export_name}, e.g. ${export_name}=GH_${source#GITHUB_}.")
      continue
    fi
    encoded="$(lookup "$store" "$source")"
    if [ -z "$encoded" ]; then
      problems+=("${FILE}: no GitHub ${kind} named ${source} in ${WHERE}. Set it in one of them, or remove it from ${key} in the file.")
      continue
    fi
    add "$export_name" "$kind" "$(printf '%s' "$encoded" | base64 --decode)"
  done < <(list_items "$items")
}

# --- Literal values ------------------------------------------------------------

if [ -n "${ENV_JSON:-}" ] && [ "${ENV_JSON}" != "{}" ]; then
  if ! entries="$(jq -r 'to_entries[] | "\(.key)\t\(.value | tostring | @base64)"' <<< "$ENV_JSON" 2> /dev/null)"; then
    log_error "ENV_JSON isn't a JSON object of NAME: value. It comes from ${FILE}'s env; check the workflow passes it unchanged."
    exit 1
  fi
  while IFS=$'\t' read -r name encoded; do
    [ -z "$name" ] && continue
    add "$name" "literal" "$(printf '%s' "$encoded" | base64 --decode)"
  done <<< "$entries"
fi

# --- GitHub variables and secrets ----------------------------------------------

if [ -n "$(list_items "${VAR_NAMES:-}")" ]; then
  vars_json="${VARS_JSON:-}"
  add_declared variable "$VAR_NAMES" "${vars_json:-"{}"}"
fi
if [ -n "$(list_items "${SECRET_NAMES:-}")" ]; then
  if [ -z "${SECRETS_JSON:-}" ]; then
    log_error "${FILE} declares secrets, but the job didn't pass its secrets to this step. Pass secrets-json: \${{ toJSON(secrets) }} to shared/setup."
    exit 1
  fi
  add_declared secret "$SECRET_NAMES" "$SECRETS_JSON"
fi

if [ ${#problems[@]} -gt 0 ]; then
  for problem in "${problems[@]}"; do
    log_error "$problem"
  done
  exit 1
fi

# --- Export --------------------------------------------------------------------

summary=()
for i in "${!names[@]}"; do
  if [ "${kinds[$i]}" = "secret" ]; then
    mask_value "${values[$i]}"
  fi
  export_job_env "${names[$i]}" "${values[$i]}"
  summary+=("${names[$i]} (${kinds[$i]})")
done

if [ ${#summary[@]} -eq 0 ]; then
  log_info "${FILE} declares no environment variables."
else
  log_success "Exported from ${FILE} for the rest of the job: ${summary[*]}"
fi
