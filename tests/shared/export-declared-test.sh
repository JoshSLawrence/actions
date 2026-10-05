#!/usr/bin/env bash
#
# Tests shared/scripts/export-declared.sh: what a deployment file's env,
# vars and secrets export, given a job's toJSON(vars) and toJSON(secrets),
# and what it refuses. Run by pre-commit and CI. Needs jq.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORT="$REPO_ROOT/shared/scripts/export-declared.sh"
# shellcheck source=shared/scripts/common.sh
source "$REPO_ROOT/shared/scripts/common.sh"

require_tool jq

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
cases=0

VARS_JSON='{"ARM_CLIENT_ID":"client-prod","ARM_TENANT_ID":"tenant"}'
SECRETS_JSON="$(jq -n --arg pem $'-----BEGIN-----\nabc\n-----END-----' \
  '{"TF_ENCRYPTION":"p%25ss","GH_PROVIDER_TOKEN":"ghp_x","APP_PEM":$pem,"github_token":"run-token"}')"

# Run the script as a job would (extra env as arguments); print what it put
# in $GITHUB_ENV as NAME=VALUE lines (newlines in values as \n), sorted
run() {
  : > "$WORK/env"
  env GITHUB_ACTIONS=true GITHUB_ENV="$WORK/env" DEPLOYMENT_FILE=beans.yaml JOB_ENVIRONMENT=prod \
    VARS_JSON="$VARS_JSON" "$@" "$EXPORT" > "$WORK/log" 2>&1 || return 1
  awk '/<<EOF_/ { split($0, a, "<<"); name = a[1]; delim = a[2]; value = ""; first = 1; next }
       $0 == delim { print name "=" value; next }
       { value = first ? $0 : value "\\n" $0; first = 0 }' "$WORK/env" | sort | paste -sd' ' -
}

# Usage: expect "<case name>" "<expected>" "<actual>"
expect() {
  cases=$((cases + 1))
  if [ "$3" == "$2" ]; then
    log_success "$1"
  else
    log_error "$1: expected '$2', got '$3'"
    cat "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

# Usage: expect_refused "<case name>" "<text the refusal names>" [VAR=value ...]
expect_refused() {
  local name="$1" text="$2"
  shift 2
  cases=$((cases + 1))
  if run "$@" > /dev/null; then
    log_error "${name}: it exported"
    failures=$((failures + 1))
  elif grep -qF -- "$text" "$WORK/log"; then
    log_success "$name"
  else
    log_error "${name}: refused, but '${text}' isn't in the log:"
    cat "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

expect "literals, variables and secrets are exported, and nothing else" \
  'ARM_CLIENT_ID=client-prod ARM_USE_OIDC=true GITHUB_TOKEN=ghp_x TF_ENCRYPTION=p%25ss TF_VAR_count=3' \
  "$(run ENV_JSON='{"ARM_USE_OIDC":"true","TF_VAR_count":"3"}' VAR_NAMES="ARM_CLIENT_ID" \
    SECRET_NAMES="TF_ENCRYPTION GITHUB_TOKEN=GH_PROVIDER_TOKEN" SECRETS_JSON="$SECRETS_JSON")"

cases=$((cases + 1))
if grep -qxF '::add-mask::p%2525ss' "$WORK/log" && grep -qxF '::add-mask::ghp_x' "$WORK/log" \
  && ! grep -q 'add-mask::client-prod' "$WORK/log"; then
  log_success "secrets are masked (encoded as the runner expects), variables aren't"
else
  log_error "secrets are masked (encoded as the runner expects), variables aren't:"
  cat "$WORK/log" >&2
  failures=$((failures + 1))
fi

expect "names match GitHub's case-insensitively, and export as written" \
  'arm_tenant_id=tenant' "$(run VAR_NAMES="arm_tenant_id")"

expect "a multi-line secret is exported whole" \
  'APP_PEM=-----BEGIN-----\nabc\n-----END-----' "$(run SECRET_NAMES="APP_PEM" SECRETS_JSON="$SECRETS_JSON")"

expect "nothing declared exports nothing" "" "$(run)"

expect_refused "a missing variable, naming where it was looked for" \
  "no GitHub variable named NOPE in environment 'prod', the repository or the organization" \
  VAR_NAMES="NOPE"

expect_refused "secrets declared but not passed" "didn't pass its secrets" SECRET_NAMES="TF_ENCRYPTION"

expect_refused "a GITHUB_* source name, which GitHub can't store" "GitHub doesn't allow secrets named GITHUB_*" \
  SECRET_NAMES="GITHUB_TOKEN" SECRETS_JSON="$SECRETS_JSON"

expect_refused "a name that controls the runner" "'BASH_ENV' controls the runner" ENV_JSON='{"BASH_ENV":"/tmp/x"}'

expect_refused "a name declared twice" "ARM_CLIENT_ID is declared twice" \
  ENV_JSON='{"ARM_CLIENT_ID":"x"}' VAR_NAMES="ARM_CLIENT_ID"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} export-declared test(s) failed. Run tests/shared/export-declared-test.sh to reproduce."
  exit 1
fi
log_success "All ${cases} export-declared tests passed"
