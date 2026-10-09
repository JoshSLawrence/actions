#!/usr/bin/env bash
#
# Publishes a plan made by sqlproject/scripts/plan.sh -- exactly that plan:
# its digest must match the plan job's, the target comes from the plan, not
# from inputs, and the arguments are built only from the plan directory. It
# first plans again against the live database; if that report differs from
# the reviewed one, the database changed since and nothing is published.
#
# Environment variables:
#   WORKING_DIR - the SQL project's folder, with its mise.toml (required)
#   PLAN_DIR    - the downloaded plan artifact (default:
#                 $RUNNER_TEMP/sqlproject-plan)
#   PLAN_SHA256 - expected digest, from the plan job (required in GitHub
#                 Actions)
#   WORK_DIR    - scratch directory, deleted at the end (default:
#                 $RUNNER_TEMP/sqlproject-apply-work)
#   SQL_AUTH    - entra (default): a token from az, so azure/login first;
#                 sql: SQL_USER and SQL_PASSWORD, for local runs against a
#                 container. The workflows never set it.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=sqlproject/scripts/sqlproject.sh
source "$SCRIPT_DIR/sqlproject.sh"

export DOTNET_CLI_TELEMETRY_OPTOUT="${DOTNET_CLI_TELEMETRY_OPTOUT:-1}"
export DOTNET_NOLOGO="${DOTNET_NOLOGO:-1}"
export DACFX_TELEMETRY_OPTOUT="${DACFX_TELEMETRY_OPTOUT:-1}"

ensure_mise
require_tool jq

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PLAN_DIR="${PLAN_DIR:-$TMP_ROOT/sqlproject-plan}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/sqlproject-apply-work}"
SQL_AUTH="${SQL_AUTH:-entra}"
log_config WORKING_DIR PLAN_DIR PLAN_SHA256 SQL_AUTH

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
cleanup() {
  sql_cleanup_run
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

sql_verify_plan "$PLAN_DIR" || exit 1
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
TARGET="$PLAN_DIR/deploy/target.json"

if [ "$(jq -r .service "$TARGET")" != "sqlproject" ]; then
  log_error "The plan at ${PLAN_DIR} isn't a SQL project plan. Download the sqlproject/plan artifact there."
  exit 1
fi
if [ "$(jq -r .offline "$TARGET")" = true ]; then
  log_error "This plan was made against a dacpac (target-dacpac), not the database, so it can't be published. Plan with target-dacpac empty."
  exit 1
fi
server="$(jq -r .server "$TARGET")"
database="$(jq -r .database "$TARGET")"
dacpac="$(jq -r .dacpac "$TARGET")"

# Defense in depth: the plan job fails a plan with possible data loss that
# isn't allowed, so none should get here
planned_json="$(sql_report_json "$PLAN_DIR/deploy/deploy-report.xml")" || exit 1
if [ -n "$(sql_data_loss "$planned_json")" ] && [ "$(jq -r .allow_data_loss "$TARGET")" != true ]; then
  log_error "The plan has possible data loss, and allow-data-loss is off, so it can't be published. Change the project to avoid the loss, or re-run the workflow with allow-data-loss on."
  exit 1
fi
log_info "Publishing ${dacpac} to ${database} on ${server}"

cd_working_dir
require_mise_tool dotnet
require_mise_tool dotnet:microsoft.sqlpackage
require_mise_tool yq
if [ "$SQL_AUTH" != sql ]; then
  require_mise_tool azure-cli
fi

mapfile -t common_args < <(sql_common_args "$PLAN_DIR")

# Plan again, against the database as it is now: SqlPackage's equivalent of
# OpenTofu's saved plan going stale
log_step "Check the database is as planned"
SQL_ONLINE=true
sql_run DeployReport "$WORK_DIR/live.log" "${common_args[@]}" "/OutputPath:${WORK_DIR}/live-report.xml" || {
  log_error "SqlPackage couldn't report on ${database}. The runner must reach ${server} (a private endpoint needs a runner in the network), and the identity must be a user of ${database} (e.g. the server's Entra admin)."
  exit 1
}
live_json="$(sql_report_json "$WORK_DIR/live-report.xml")" || exit 1
if [ "$(jq -cS . <<< "$planned_json")" != "$(jq -cS . <<< "$live_json")" ]; then
  log_error "${database} changed since this plan (someone deployed or changed it), so the plan no longer describes what Publish would do. Re-run the workflow to plan again."
  log_info "Planned:"
  sql_report_lines "$planned_json" | sed 's/^/  /'
  log_info "Now:"
  sql_report_lines "$live_json" | sed 's/^/  /'
  exit 1
fi
log_success "The database still yields the planned report"

log_step "Publish"
if ! sql_run Publish "$WORK_DIR/publish.log" "${common_args[@]}"; then
  log_error "Publish failed; some changes may be live (SqlPackage deploys in steps; IncludeTransactionalScripts in the profile makes it all-or-nothing where possible). Fix the error above and push to plan again, or roll back by running the workflow on the target branch."
  exit 1
fi

echo "### ✅ Published \`${dacpac}\` to \`${database}\` on \`${server}\` (plan sha256 \`${PLAN_SHA256:-unknown}\`)" | append_step_summary
log_summary "Published ${dacpac} to ${database} on ${server}"
