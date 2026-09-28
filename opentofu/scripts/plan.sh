#!/usr/bin/env bash
#
# Plans a root module to a saved plan file, and renders the plan's markdown
# summary. Never changes infrastructure or state, so it's safe to run locally
# with your own credentials.
#
# Environment variables:
#   WORKING_DIR          - root module to plan (required)
#   PLAN_DIR             - where tfplan (and a copy of the lock file) go
#                          (default: $RUNNER_TEMP/tofu-plan). The plan action
#                          uploads this directory as the plan artifact, so
#                          nothing sensitive beyond the plan itself goes here.
#   WORK_DIR             - scratch directory for plan.json, plan.txt, the log
#                          and summary fragments (default:
#                          $RUNNER_TEMP/tofu-plan-work). plan.json holds
#                          sensitive values unmasked: never upload it. The
#                          plan action deletes it at the end of the job.
#   VAR_FILES            - -var-file paths relative to WORKING_DIR, space- or
#                          newline-separated (optional)
#   BACKEND_CONFIG       - -backend-config values, one per line: key=value, or
#                          a file relative to WORKING_DIR (optional)
#   MODULES_GITHUB_TOKEN - lets init fetch module sources from private GitHub
#                          repositories (optional)
#   HEAD_SHA, TARGET_BRANCH, TARGET_SHA, PR_NUMBER
#                        - describe what's being planned, for the summary
#                          (set by the plan action; optional locally)
#
# Outputs:
#   has-changes - true if applying the plan would change anything
#   plan-sha256 - digest of tfplan (only when has-changes), checked before
#                 it's applied
#   exit-code   - exit code of init/plan (0 or 2 when the plan succeeded)
#   plan-dir    - absolute path of PLAN_DIR
#   work-dir    - absolute path of WORK_DIR
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ensure_mise
require_tool jq

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PLAN_DIR="${PLAN_DIR:-$TMP_ROOT/tofu-plan}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/tofu-plan-work}"

log_config WORKING_DIR PLAN_DIR WORK_DIR VAR_FILES BACKEND_CONFIG HEAD_SHA TARGET_BRANCH PR_NUMBER

# Absolute paths: everything below runs from inside WORKING_DIR
rm -rf "$PLAN_DIR" "$WORK_DIR"
mkdir -p "$PLAN_DIR" "$WORK_DIR/fragments"
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
PLAN_FILE="$PLAN_DIR/tfplan"
PLAN_LOG="$WORK_DIR/plan.log"
: > "$PLAN_LOG"
set_output plan-dir "$PLAN_DIR"
set_output work-dir "$WORK_DIR"

cd_working_dir
require_mise_tool opentofu
configure_git_github_auth
warn_if_no_lock_file

set_output has-changes false

# Render the plan summary fragment. Runs for failures too, so the PR comment
# says the plan failed instead of silently showing the previous push's plan.
finish() {
  local exit_code="$1"
  set_output exit-code "$exit_code"
  PLAN_EXIT_CODE="$exit_code" PLAN_LOG="$PLAN_LOG" \
    PLAN_JSON="$WORK_DIR/plan.json" PLAN_TEXT="$WORK_DIR/plan.txt" \
    bash "$SCRIPT_DIR/plan-summary.sh" > "$WORK_DIR/fragments/10-plan.md"
}

var_file_args=()
while IFS= read -r var_file; do
  if [ ! -f "$var_file" ]; then
    log_error "Var file '${var_file}' not found in ${WORKING_DIR}. var-files paths are relative to the working directory."
    finish 1
    exit 1
  fi
  var_file_args+=("-var-file=${var_file}")
done < <(list_items "${VAR_FILES:-}")

mapfile -t init_args < <(tofu_init_args)

log_step "tofu init"
log_cmd tofu init "${init_args[@]}"
set +e
mise exec -- tofu init "${init_args[@]}" 2>&1 | tee -a "$PLAN_LOG"
init_exit=${PIPESTATUS[0]}
set -e
if [ "$init_exit" -ne 0 ]; then
  finish "$init_exit"
  log_error "tofu init failed (exit ${init_exit}). If it can't reach the state backend, check the job's cloud credentials (e.g. the Azure identity has a federated credential for this repository/environment and data access to the state storage). If the lock file is out of date, run 'tofu init -upgrade' and commit .terraform.lock.hcl."
  exit "$init_exit"
fi

# -lock=false: a plan never writes state, and a saved plan is safe without the
# lock -- apply takes the lock and refuses the plan if the state changed since
# it was made. Not locking also means a plan cancelled by a newer push can't
# leave a stale lock behind.
plan_args=(-input=false -lock=false -detailed-exitcode "-out=${PLAN_FILE}" "${var_file_args[@]+"${var_file_args[@]}"}")

log_step "tofu plan"
log_cmd tofu plan "${plan_args[@]}"
set +e
mise exec -- tofu plan "${plan_args[@]}" 2>&1 | tee -a "$PLAN_LOG"
plan_exit=${PIPESTATUS[0]}
set -e

case "$plan_exit" in
  0 | 2) ;;
  *)
    finish "$plan_exit"
    log_error "tofu plan failed (exit ${plan_exit}). See the errors above; reproduce with 'tofu plan' in ${WORKING_DIR}."
    exit "$plan_exit"
    ;;
esac

mise exec -- tofu show -json "$PLAN_FILE" > "$WORK_DIR/plan.json"
mise exec -- tofu show -no-color "$PLAN_FILE" > "$WORK_DIR/plan.txt"
finish "$plan_exit"

if [ "$plan_exit" -eq 2 ]; then
  # Apply re-runs init from the same commit, but a module without a committed
  # lock file would resolve providers afresh; ship the lock file init just
  # wrote with the plan, so apply uses exactly the providers that planned.
  if [ -f .terraform.lock.hcl ]; then
    cp .terraform.lock.hcl "$PLAN_DIR/.terraform.lock.hcl"
  fi
  plan_sha256="$(file_sha256 "$PLAN_FILE")"
  set_output has-changes true
  set_output plan-sha256 "$plan_sha256"
  log_summary "Plan has changes (tfplan sha256 ${plan_sha256})"
else
  # Nothing to apply: don't leave a plan file around to be uploaded
  rm -f "$PLAN_FILE"
  log_summary "No changes: infrastructure matches the configuration"
fi
