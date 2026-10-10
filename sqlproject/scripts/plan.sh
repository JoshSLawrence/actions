#!/usr/bin/env bash
#
# Plans one deployment of a SQL project -- its dacpac x one publish profile --
# against the live database: SqlPackage's DeployReport says what would
# change, Script writes the T-SQL that would run, both with exactly the
# options the apply will publish with. Writes the plan (the dacpacs, the
# profile, the target and the report, which the apply publishes exactly) with
# a markdown summary. Never changes anything, so it's safe to run locally:
#
#   WORKING_DIR=database/core DACPAC_DIR=/tmp/sqlproject-dacpac \
#     PROFILE=deployments/dev.publish.xml TARGET_DACPAC=ci/baseline.dacpac \
#     sqlproject/scripts/plan.sh
#
# Environment variables:
#   WORKING_DIR        - the SQL project's folder, with its own mise.toml
#                        (required); PROFILE and TARGET_DACPAC are relative
#                        to it
#   DACPAC_DIR         - sqlproject/build's dacpac-dir (required)
#   PROFILE            - the deployment's publish profile (required)
#   DEPLOYMENT         - the deployment's name, for the summary
#   DEPLOY_MODE        - additive (default): nothing outside the project is
#                        dropped, and the plan lists what is kept; truth:
#                        drop what isn't in the project
#   KEEP_OBJECT_TYPES  - truth mode: object types never dropped, ";"- or
#                        newline-separated (default: users, logins, roles,
#                        permissions, credentials and keys; empty = none)
#   DEPLOYMENT_SCRIPTS - changed (default) or always, as given to the build
#   PROPERTIES         - Name=Value lines of deploy properties, after the
#                        profile's
#   VARIABLES          - Name=Value lines of SQLCMD variables, after the
#                        profile's (never secrets: they are in the plan)
#   ALLOW_DATA_LOSS    - "true": a plan with possible data loss may be applied
#                        (and publishes with BlockOnPossibleDataLoss=False).
#                        Default false: such a plan is blocked.
#   TARGET_DACPAC      - plan against this dacpac instead of the database: no
#                        Azure access (tests and offline previews)
#   PLAN_DIR           - where the plan goes (default:
#                        $RUNNER_TEMP/sqlproject-plan): deploy/ (dacpac/,
#                        deploy-report.xml, deployment-scripts.json,
#                        profile.publish.xml, target.json, and target.dacpac
#                        offline), kept-report.xml (additive), script.sql and
#                        summary.md. The plan artifact; it holds no secrets.
#   WORK_DIR           - scratch directory, deleted at the end (default:
#                        $RUNNER_TEMP/sqlproject-plan-work)
#   TITLE              - heading for the job summary
#   HEAD_SHA, TARGET_BRANCH, TARGET_SHA, PR_NUMBER
#                      - describe what's being planned, for the summary
#   SQL_AUTH           - entra (default): a token from az, so azure/login
#                        first; sql: SQL_USER and SQL_PASSWORD, for local runs
#                        against a container. The workflows never set it.
#
# Outputs:
#   has-changes    - "true" if the report has any operation, or the project's
#                    deployment scripts count as changed
#   data-loss      - "true" if the report has possible data loss
#   blocked        - "true" if it has, and ALLOW_DATA_LOSS isn't on (the
#                    script then fails after writing everything)
#   blocked-reason - one line saying why, when blocked
#   plan-sha256    - digest of the plan's deploy/ directory
#   plan-dir       - absolute path of PLAN_DIR
#   summary-file   - the markdown summary (also on failure)
#   server, database - the target ("" for server when planning offline)
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
require_tool unzip
require_env DACPAC_DIR "Set it to the dacpac-dir of sqlproject/build (or the downloaded dacpac artifact)."
require_env PROFILE "Set the publish profile of the deployment, relative to the working directory, e.g. deployments/dev.publish.xml."

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PLAN_DIR="${PLAN_DIR:-$TMP_ROOT/sqlproject-plan}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/sqlproject-plan-work}"
DEPLOY_MODE="${DEPLOY_MODE:-additive}"
KEEP_OBJECT_TYPES="${KEEP_OBJECT_TYPES-$SQL_DEFAULT_KEEP_OBJECT_TYPES}"
DEPLOYMENT_SCRIPTS="${DEPLOYMENT_SCRIPTS:-changed}"
ALLOW_DATA_LOSS="${ALLOW_DATA_LOSS:-false}"
TARGET_DACPAC="${TARGET_DACPAC:-}"
SQL_AUTH="${SQL_AUTH:-entra}"

log_config WORKING_DIR DACPAC_DIR PLAN_DIR DEPLOYMENT PROFILE DEPLOY_MODE KEEP_OBJECT_TYPES DEPLOYMENT_SCRIPTS ALLOW_DATA_LOSS TARGET_DACPAC SQL_AUTH

rm -rf "$PLAN_DIR" "$WORK_DIR"
mkdir -p "$PLAN_DIR/deploy/dacpac" "$WORK_DIR"
PLAN_DIR="$(cd "$PLAN_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
SUMMARY_FILE="$PLAN_DIR/summary.md"
DACPAC_DIR="$(cd "$DACPAC_DIR" 2> /dev/null && pwd)" || {
  log_error "DACPAC_DIR doesn't exist. Point it at sqlproject/build's dacpac-dir."
  exit 1
}
set_output plan-dir "$PLAN_DIR"
set_output summary-file "$SUMMARY_FILE"
set_output has-changes false
set_output data-loss false
set_output blocked false

# Always leave a summary behind -- a failure's too, for the PR comment -- and
# delete the scratch files and any SqlPackage response file
finish() {
  local exit_code=$?
  if [ ! -s "$SUMMARY_FILE" ]; then
    failure_markdown "${FAILED:-The plan failed.}" "${FAILED_LOG:-/dev/null}" > "$SUMMARY_FILE"
  fi
  {
    echo "## ${TITLE:-SQL project plan}"
    echo ""
    cat "$SUMMARY_FILE"
    echo ""
  } | append_step_summary
  sql_cleanup_run
  rm -rf "$WORK_DIR"
  exit "$exit_code"
}
trap finish EXIT

# The summary of a plan that failed before it had a report
# Usage: failure_markdown "<what failed>" "<log file>"
failure_markdown() {
  local message="$1" log="$2" cleaned
  echo "### ❌ Plan failed"
  echo ""
  context_line
  echo ""
  echo "${message} Nothing can be published until the plan succeeds."
  echo ""
  if [ -s "$log" ]; then
    cleaned="$(mktemp)"
    tail -n 100 "$log" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -v '^::' > "$cleaned" || true
    collapsible_block "Output (last 100 lines)" "text" "$cleaned"
    rm -f "$cleaned"
  fi
}

# Record why the plan failed, for the summary, then fail
# Usage: fail "<what failed>" [<log file>]
fail() {
  FAILED="$1"
  FAILED_LOG="${2:-}"
  log_error "$1"
  exit 1
}

# Print a file without its UTF-8 byte order mark (SqlPackage writes one)
strip_bom() {
  if [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
    tail -c +4 "$1"
  else
    cat "$1"
  fi
}

# --- Check the inputs ---------------------------------------------------------------
cd_working_dir
require_mise_tool dotnet
require_mise_tool dotnet:microsoft.sqlpackage
require_mise_tool yq

case "$DEPLOY_MODE" in
  additive | truth) ;;
  *) fail "deploy-mode '${DEPLOY_MODE}' isn't valid. Use additive (never drop what isn't in the project) or truth (drop it)." ;;
esac
[ -f "$PROFILE" ] || fail "The publish profile ${PROFILE} doesn't exist in ${WORKING_DIR}. It's relative to the working directory."
profile_json="$(sql_profile_json "$PROFILE")" || fail "Couldn't read ${PROFILE} as XML. Check it is well-formed (open it in VS Code, or run 'xmllint ${PROFILE}')."
problems="$(sql_profile_problems "$profile_json" "$PROFILE")"
[ -z "$problems" ] || fail "The publish profile has problems: ${problems//$'\n'/ }"
properties="$(sql_parse_assignments properties "${PROPERTIES:-}" 2> "$WORK_DIR/inputs.log")" || fail "The properties input is invalid." "$WORK_DIR/inputs.log"
variables="$(sql_parse_assignments variables "${VARIABLES:-}" 2> "$WORK_DIR/inputs.log")" || fail "The variables input is invalid." "$WORK_DIR/inputs.log"
keep_types="$(list_lines "$(tr ';' '\n' <<< "$KEEP_OBJECT_TYPES")" | jq -Rn '[inputs]')"
if jq -e 'any(.[]; test("^[A-Za-z]+$") | not)' <<< "$keep_types" > /dev/null; then
  fail "keep-object-types has an entry that isn't an object type name. Use SqlPackage's names (Users, Logins, Permissions, ...), separated by ; or newlines."
fi

database="$(jq -r .database <<< "$profile_json")"
server="$(jq -r .server <<< "$profile_json")"
offline=false
if [ -n "$TARGET_DACPAC" ]; then
  offline=true
  [ -f "$TARGET_DACPAC" ] || fail "target-dacpac ${TARGET_DACPAC} doesn't exist in ${WORKING_DIR}. It's relative to the working directory."
  server=""
fi
SQL_ONLINE=true
if [ "$offline" = true ]; then
  SQL_ONLINE=false
elif [ "$SQL_AUTH" != sql ]; then
  require_mise_tool azure-cli
fi
set_output server "$server"
set_output database "$database"

# --- Lay out the plan ---------------------------------------------------------------
log_step "The plan"
[ -f "$DACPAC_DIR/build.json" ] || fail "No build.json in ${DACPAC_DIR}. Point DACPAC_DIR at sqlproject/build's dacpac-dir."
dacpac="$(jq -r .dacpac "$DACPAC_DIR/build.json")"
[ -f "$DACPAC_DIR/$dacpac" ] || fail "${DACPAC_DIR} has no ${dacpac}. Point DACPAC_DIR at sqlproject/build's dacpac-dir."
cp "$DACPAC_DIR"/*.dacpac "$PLAN_DIR/deploy/dacpac/"
cp "$DACPAC_DIR/deployment-scripts.json" "$DACPAC_DIR/build.json" "$PLAN_DIR/deploy/"
if [ "$offline" = true ]; then
  cp "$TARGET_DACPAC" "$PLAN_DIR/deploy/target.dacpac"
  # SqlPackage connects to a profile's TargetConnectionString even with
  # /TargetFile, and would hang on a server that isn't reachable. An offline
  # plan is never applied, so its copy of the profile leaves it out.
  mise exec -- yq -p xml -o xml 'del(.. | select(tag == "!!map" and has("TargetConnectionString")) | .TargetConnectionString)' "$PROFILE" > "$PLAN_DIR/deploy/profile.publish.xml" ||
    fail "Couldn't prepare the profile ${PROFILE} for an offline plan. Check it is well-formed XML."
else
  cp "$PROFILE" "$PLAN_DIR/deploy/profile.publish.xml"
fi
jq -n --arg deployment "${DEPLOYMENT:-}" --arg server "$server" --arg database "$database" \
  --arg dacpac "$dacpac" --arg profile "$PROFILE" --arg deploy_mode "$DEPLOY_MODE" \
  --argjson keep "$keep_types" --argjson allow "$(is_true "$ALLOW_DATA_LOSS" && echo true || echo false)" \
  --argjson offline "$offline" --argjson properties "$properties" --argjson variables "$variables" '
  {service: "sqlproject", deployment: $deployment, server: (if $server == "" then null else $server end),
   database: $database, dacpac: $dacpac, profile: $profile, deploy_mode: $deploy_mode,
   keep_object_types: $keep, allow_data_loss: $allow, offline: $offline,
   properties: $properties, variables: $variables}' > "$PLAN_DIR/deploy/target.json"
if [ "$offline" = true ]; then
  log_success "Plan laid out for ${database}, planned against ${TARGET_DACPAC}"
else
  log_success "Plan laid out for ${database} on ${server}"
fi

# --- SqlPackage ---------------------------------------------------------------------
sql_failed() {
  local what="$1" log="$2"
  if [ "$offline" = true ]; then
    fail "SqlPackage ${what} failed (see the output below). Check the project's dacpac and ${TARGET_DACPAC}." "$log"
  else
    fail "SqlPackage ${what} failed (see the output below). The runner must reach ${server} (a private endpoint needs a runner in the network), and the identity must be a user of ${database} (e.g. the server's Entra admin)." "$log"
  fi
}

mapfile -t common_args < <(sql_common_args "$PLAN_DIR")

log_step "DeployReport"
sql_run DeployReport "$WORK_DIR/report.log" "${common_args[@]}" "/OutputPath:${PLAN_DIR}/deploy/deploy-report.xml" || sql_failed "DeployReport" "$WORK_DIR/report.log"
[ -s "$PLAN_DIR/deploy/deploy-report.xml" ] || fail "SqlPackage wrote no report. Re-run the job; if it persists, report it at https://github.com/JoshSLawrence/actions/issues." "$WORK_DIR/report.log"

log_step "Script"
sql_run Script "$WORK_DIR/script.log" "${common_args[@]}" "/OutputPath:${PLAN_DIR}/script.sql" || sql_failed "Script" "$WORK_DIR/script.log"

# A missing database doesn't show in a report (it lists only the creates),
# but the script would create it
if [ "$offline" != true ] && sql_missing_database "$PLAN_DIR/script.sql"; then
  fail "Database ${database} doesn't exist on ${server}. This workflow never creates databases (SqlPackage would, outside your infrastructure code): create it first, then re-run this job."
fi

kept_json='{"alerts": [], "operations": []}'
if [ "$DEPLOY_MODE" = additive ]; then
  log_step "What additive mode keeps"
  mapfile -t kept_args < <(sql_kept_args "$PLAN_DIR")
  sql_run DeployReport "$WORK_DIR/kept.log" "${kept_args[@]}" "/OutputPath:${PLAN_DIR}/kept-report.xml" || sql_failed "DeployReport (for the objects additive mode keeps)" "$WORK_DIR/kept.log"
  kept_json="$(sql_report_json "$PLAN_DIR/kept-report.xml")" || fail "Couldn't read the kept report."
fi

# --- The report ---------------------------------------------------------------------
log_step "Summary"
report_json="$(sql_report_json "$PLAN_DIR/deploy/deploy-report.xml")" || fail "Couldn't read the deployment report."
operation_count="$(jq '[.operations[].items[]] | length' <<< "$report_json")"
scripts_present="$(jq -r '(.pre_sha256 != null) or (.post_sha256 != null)' "$PLAN_DIR/deploy/deployment-scripts.json")"
scripts_changed="$(jq -r '.changed' "$PLAN_DIR/deploy/deployment-scripts.json")"
scripts_why="$(jq -r '.why // ""' "$PLAN_DIR/deploy/deployment-scripts.json")"
has_changes=false
if [ "$operation_count" -gt 0 ] || { [ "$scripts_present" = true ] && [ "$scripts_changed" = true ]; }; then
  has_changes=true
fi
data_loss=false
blocked=false
blocked_reason=""
loss_lines="$(sql_data_loss "$report_json")"
if [ -n "$loss_lines" ]; then
  data_loss=true
  if ! is_true "$ALLOW_DATA_LOSS"; then
    blocked=true
    blocked_reason="Possible data loss (see the plan), so it can't be applied. Change the project to avoid it, or, if the loss is intended, re-run with the workflow's allow-data-loss input on."
  fi
fi

# Operation names as SqlPackage reports them (Create, Alter, Drop, Rename,
# TableRebuild, ...); unknown ones are counted too
counts="$(jq -r '
  def words: gsub("(?<a>[a-z])(?<b>[A-Z])"; "\(.a) \(.b)") | ascii_downcase;
  ["Create", "Alter", "Rename", "TableRebuild", "Drop"] as $order
  | .operations
  | map({operation, n: (.items | length)} | select(.n > 0))
  | sort_by([(.operation as $op | $order | index($op) // 99), .operation])
  | map("\(.n) to \(.operation | words)") | join(", ")' <<< "$report_json")"

{
  if [ "$has_changes" = true ]; then
    if [ -n "$counts" ]; then
      echo "### 📋 Plan: ${counts}$([ "$scripts_present" = true ] && [ "$scripts_changed" = true ] && echo ", deployment scripts changed")"
    else
      echo "### 📋 Plan: deployment scripts changed"
    fi
  else
    echo "### ✅ No changes"
  fi
  echo ""
  context_line
  echo ""
  if [ "$offline" = true ]; then
    echo "Planned against \`${TARGET_DACPAC}\`, not a database: database name \`${database}\`, profile \`${PROFILE}\`, ${DEPLOY_MODE} mode."
  else
    echo "Database \`${database}\` on \`${server}\`, profile \`${PROFILE}\`, ${DEPLOY_MODE} mode."
  fi
  if [ "$has_changes" != true ]; then
    echo ""
    if [ "$offline" = true ]; then
      echo "\`${TARGET_DACPAC}\` matches the project. Nothing to publish."
    else
      echo "\`${database}\` matches the project. Nothing to publish."
    fi
  fi
  if [ "$data_loss" = true ]; then
    echo ""
    if [ "$blocked" = true ]; then
      echo "> **Warning:** possible data loss, so this plan is blocked:"
    else
      echo "> **Warning:** possible data loss, allowed by allow-data-loss:"
    fi
    while IFS= read -r line; do echo "> - ${line}"; done <<< "$loss_lines"
  fi
  other_alerts="$(jq -r '.alerts[] | select(.name != "DataIssue") | .name as $n | .issues[] | "- **\($n):** \(.)"' <<< "$report_json")"
  if [ -n "$other_alerts" ]; then
    echo ""
    echo "Other alerts:"
    echo ""
    echo "$other_alerts"
  fi

  if [ "$operation_count" -gt 0 ]; then
    echo ""
    details_open "Changes (${operation_count})"
    echo "| Operation | Object | Type |"
    echo "| --- | --- | --- |"
    jq -r '
      ["Drop", "Rename", "Alter", "TableRebuild", "Create"] as $order
      | {Drop: "🔴", Rename: "🟡", Alter: "🟡", TableRebuild: "🟡", Create: "🟢"} as $icon
      | [ .operations[] | .operation as $o | .items[] | {operation: $o, value, type} ]
      | sort_by([(.operation as $op | $order | index($op) // 99), .operation, .value])[]
      | "| \($icon[.operation] // "⚪") \(.operation | gsub("(?<a>[a-z])(?<b>[A-Z])"; "\(.a) \(.b)") | ascii_downcase) | `\(.value | gsub("\\|"; "\\|"))` | \(.type) |"' <<< "$report_json"
    echo ""
    echo "</details>"
  fi

  kept_count="$(jq '[.operations[] | select(.operation == "Drop") | .items[]] | length' <<< "$kept_json")"
  if [ "$kept_count" -gt 0 ]; then
    echo ""
    details_open "Kept: in the database, not in the project (${kept_count})"
    echo "Additive mode leaves these alone; truth mode would drop them."
    echo ""
    echo "| Object | Type |"
    echo "| --- | --- |"
    jq -r '[.operations[] | select(.operation == "Drop") | .items[]] | sort_by(.value)[]
      | "| `\(.value | gsub("\\|"; "\\|"))` | \(.type) |"' <<< "$kept_json"
    echo ""
    echo "</details>"
  fi

  if [ "$scripts_present" = true ]; then
    echo ""
    if [ "$scripts_changed" = true ]; then
      echo "Deployment scripts count as changed: ${scripts_why}. They run with every publish, so they must be idempotent."
      for member in predeploy postdeploy; do
        if unzip -p "$PLAN_DIR/deploy/dacpac/$dacpac" "${member}.sql" > "$WORK_DIR/${member}.raw" 2> /dev/null; then
          strip_bom "$WORK_DIR/${member}.raw" > "$WORK_DIR/${member}.sql"
          echo ""
          collapsible_block "$([ "$member" = predeploy ] && echo Pre || echo Post)-deployment script" sql "$WORK_DIR/${member}.sql"
        fi
      done
    else
      echo "Deployment scripts: unchanged (${scripts_why}), so they don't make this plan a change; they still run if it is published."
    fi
  fi

  echo ""
  strip_bom "$PLAN_DIR/script.sql" > "$WORK_DIR/script.sql"
  collapsible_block "Deployment script" sql "$WORK_DIR/script.sql"

  echo ""
  details_open "Deploy options"
  echo "- Mode: \`${DEPLOY_MODE}\`$([ "$DEPLOY_MODE" = truth ] && echo ", never dropped: $(jq -r 'if length == 0 then "nothing" else map("`\(.)`") | join(", ") end' <<< "$keep_types")")"
  echo "- allow-data-loss: \`$(is_true "$ALLOW_DATA_LOSS" && echo true || echo false)\`"
  echo "- Profile properties: $(jq -r '.properties | del(.TargetDatabaseName, .TargetConnectionString) | to_entries | if length == 0 then "none" else map("`\(.key)=\(.value)`") | join(", ") end' <<< "$profile_json")"
  echo "- properties input: $(jq -r 'to_entries | if length == 0 then "none" else map("`\(.key)=\(.value)`") | join(", ") end' <<< "$properties")"
  echo "- Profile SQLCMD variables: $(jq -r '.variables | to_entries | if length == 0 then "none" else map("`\(.key)=\(.value)`") | join(", ") end' <<< "$profile_json")"
  echo "- variables input: $(jq -r 'to_entries | if length == 0 then "none" else map("`\(.key)=\(.value)`") | join(", ") end' <<< "$variables")"
  echo ""
  echo "</details>"
} > "$SUMMARY_FILE"
fit_github_body "$SUMMARY_FILE" "the workflow run's job summary"

plan_sha256="$(sql_plan_sha256 "$PLAN_DIR")"
set_output has-changes "$has_changes"
set_output data-loss "$data_loss"
set_output blocked "$blocked"
set_output blocked-reason "$blocked_reason"
set_output plan-sha256 "$plan_sha256"
log_summary "Planned ${database}${server:+ on ${server}} (has changes: ${has_changes}, data loss: ${data_loss}, plan sha256 ${plan_sha256})"

if [ "$blocked" = true ]; then
  # The summary and outputs are written, so the PR comment can say why
  log_error "$blocked_reason"
  exit 1
fi
