#!/usr/bin/env bash
#
# Runs the SQL project scripts (build, plan, apply) against a real SQL Server
# in a throwaway container, with SQL authentication (SQL_AUTH=sql): the
# parts the offline tests (scripts-test.sh) can't cover -- SqlPackage's
# reports, scripts and publishes, deploy modes, refactorlog renames, data
# loss, deployment scripts, and the apply's refusals. Entra authentication,
# private endpoints and OIDC need Azure and are not covered.
#
# CI only (the "SQL project engine" job); locally it needs docker, mise (with
# the fixture's tools: dotnet, SqlPackage, yq), git, jq, openssl, and the
# fixture committed (the deployment-scripts comparison builds HEAD):
#
#   tests/sqlproject/engine-test.sh
#
# Environment variables:
#   SQL_ENGINE_IMAGE    - the image to run (default: SQL Server 2022, pinned
#                         by digest; bump the digest by hand now and then)
#   SQL_ENGINE_PLATFORM - docker --platform (default linux/amd64: the
#                         image has no arm64 build, so it runs emulated on
#                         Apple silicon). Empty: docker's default.
#   SQL_ENGINE_SQLCMD   - the image's sqlcmd (default
#                         /opt/mssql-tools18/bin/sqlcmd; azure-sql-edge
#                         doesn't ship one and can't run this test)
#   SQL_ENGINE_PORT     - host port to publish on (default 14330, the one
#                         ci/engine.publish.xml names)
#
# The password is generated into a mode-600 file, given to the container
# with --env-file and to the scripts through the environment: never on a
# command line. The container and the file are removed on exit.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_ROOT/sqlproject/scripts"
# shellcheck source=shared/scripts/common.sh
source "$REPO_ROOT/shared/scripts/common.sh"
# shellcheck source=sqlproject/scripts/sqlproject.sh
source "$SCRIPTS/sqlproject.sh"

# Never inherit a repository from a caller (a pre-commit hook sets GIT_DIR)
unset $(git rev-parse --local-env-vars)

require_tool docker
require_tool git
require_tool jq
require_tool openssl
ensure_mise

SQL_ENGINE_IMAGE="${SQL_ENGINE_IMAGE:-mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090}"
SQL_ENGINE_PLATFORM="${SQL_ENGINE_PLATFORM-linux/amd64}"
SQL_ENGINE_SQLCMD="${SQL_ENGINE_SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
SQL_ENGINE_PORT="${SQL_ENGINE_PORT:-14330}"
FIXTURE="tests/fixtures/sqlproject/basic"
CONTAINER="sqlproject-engine-$$"
PROFILE="ci/engine.publish.xml"
MISSING_PROFILE="obj/engine-missing.publish.xml"

WORK="$(mktemp -d)"
failures=0
cases=0

cleanup() {
  docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
  rm -f "${REPO_ROOT:?}/${FIXTURE:?}/${MISSING_PROFILE:?}"
  rm -rf "${WORK:?}"
}
trap cleanup EXIT

# The password: generated, never printed, never on a command line. The
# prefix satisfies SQL Server's complexity rules.
(umask 077 && : > "$WORK/engine.env")
SQL_PASSWORD="Aa1!$(openssl rand -hex 12)"
{
  echo "ACCEPT_EULA=Y"
  echo "MSSQL_SA_PASSWORD=${SQL_PASSWORD}"
} >> "$WORK/engine.env"
mask_value "$SQL_PASSWORD"
export SQL_AUTH=sql SQL_USER=sa SQL_PASSWORD
export SQLCMDPASSWORD="$SQL_PASSWORD"
mkdir -p "$WORK/runner"
export RUNNER_TEMP="$WORK/runner"

# Usage: expect "<case name>" "<expected>" "<actual>"
expect() {
  cases=$((cases + 1))
  if [ "$3" == "$2" ]; then
    log_success "$1"
  else
    log_error "$1: expected '$2', got '$3'"
    sed 's/^/    /' "$WORK/log" >&2 || true
    failures=$((failures + 1))
  fi
}

# Usage: expect_log "<case name>" "<text the last run's log says>"
expect_log() {
  cases=$((cases + 1))
  if grep -qF -- "$2" "$WORK/log"; then
    log_success "$1"
  else
    log_error "$1: '$2' isn't in the log:"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

# Run a script of sqlproject/scripts against the fixture, with extra env
# (VAR=value arguments). Its log goes to $WORK/log (and is shown when a
# case fails), its exit code is in $status and its outputs in $WORK/output.
# Usage: run <script> [VAR=value ...]
run() {
  local script="$1"
  shift
  : > "$WORK/output"
  set +e
  (cd "$REPO_ROOT" && env GITHUB_OUTPUT="$WORK/output" WORKING_DIR="$FIXTURE" "$@" "$SCRIPTS/$script") > "$WORK/log" 2>&1
  status=$?
  set -e
}

# Print an output of the last run
output() {
  sed -n "s/^${1}=//p" "$WORK/output" | tail -1
}

# Run SQL in the container, against the fixture database unless a database
# is given. Usage: sql "<statement>" [database]
sql() {
  docker exec -i -e SQLCMDPASSWORD "$CONTAINER" "$SQL_ENGINE_SQLCMD" -S localhost -U sa -C -b -h -1 -W -d "${2:-fixture}" -Q "SET NOCOUNT ON; $1" | tr -d '\r'
}

# Print the normalized report of a plan. Usage: report_of <name>
report_of() {
  (cd "$REPO_ROOT/$FIXTURE" && scope_mise_to_module && sql_report_json "$WORK/plan-$1/deploy/deploy-report.xml")
}

# Plan the fixture with the engine profile
# Usage: plan <dacpac dir> <name> [VAR=value ...]
plan() {
  local dacpac_dir="$1" name="$2"
  shift 2
  run plan.sh DACPAC_DIR="$dacpac_dir" PROFILE="${PROFILE_OVERRIDE:-$PROFILE}" DEPLOYMENT=engine PLAN_DIR="$WORK/plan-$name" WORK_DIR="$WORK/plan-work-$name" "$@"
  cp "$WORK/output" "$WORK/plan-$name.output"
}

# Publish the plan of a name. Usage: apply <name>
apply() {
  run apply.sh PLAN_DIR="$WORK/plan-$1" PLAN_SHA256="$(sed -n 's/^plan-sha256=//p' "$WORK/plan-$1.output" | tail -1)" WORK_DIR="$WORK/apply-work-$1"
}

# --- Start the engine -----------------------------------------------------------------
log_step "Start SQL Server"
log_info "Image: ${SQL_ENGINE_IMAGE}"
platform_args=()
if [ -n "$SQL_ENGINE_PLATFORM" ]; then
  platform_args=(--platform "$SQL_ENGINE_PLATFORM")
fi
docker run -d --name "$CONTAINER" "${platform_args[@]+"${platform_args[@]}"}" --env-file "$WORK/engine.env" \
  -p "127.0.0.1:${SQL_ENGINE_PORT}:1433" "$SQL_ENGINE_IMAGE" > /dev/null
ready=false
for _ in $(seq 1 90); do
  if sql "SELECT 1" master > /dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  log_error "SQL Server didn't accept connections in 3 minutes. Its log:"
  docker logs "$CONTAINER" 2>&1 | tail -30 >&2
  log_error "Check ${SQL_ENGINE_SQLCMD} exists in the image (azure-sql-edge has no sqlcmd), and that port ${SQL_ENGINE_PORT} is free."
  exit 1
fi
log_success "SQL Server is up"
sql "CREATE DATABASE fixture" master

# --- Builds -------------------------------------------------------------------------------
# One compared with HEAD (the fixture's scripts are unchanged there), one that
# always counts them as changed
log_step "Build"
head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
run build.sh OUTPUT_DIR="$WORK/dacpac-head" SCRIPTS_BASE="$head_sha" WORK_DIR="$WORK/build-work-head"
expect "build (compared with HEAD)" "0" "$status"
expect "the scripts are unchanged since HEAD (commit the fixture first if not)" "false" "$(output deployment-scripts-changed)"
run build.sh OUTPUT_DIR="$WORK/dacpac-always" DEPLOYMENT_SCRIPTS=always WORK_DIR="$WORK/build-work-always"
expect "build (deployment-scripts always)" "0" "$status"
expect "the scripts always count" "true" "$(output deployment-scripts-changed)"
HEAD_DACPAC="$WORK/dacpac-head"
ALWAYS_DACPAC="$WORK/dacpac-always"

# --- The database starts as the baseline --------------------------------------------------
# Widget(Id, Title) with a row, and Extra: the project renames Title to Name
# through its refactorlog and adds Status and a view
log_step "Publish the baseline"
if ! (
  cd "$REPO_ROOT/$FIXTURE"
  scope_mise_to_module
  sql_run Publish "$WORK/baseline.log" "/SourceFile:${REPO_ROOT}/${FIXTURE}/ci/baseline.dacpac" \
    "/TargetServerName:localhost,${SQL_ENGINE_PORT}" "/TargetDatabaseName:fixture" "/p:AllowIncompatiblePlatform=True"
) > "$WORK/log" 2>&1; then
  cat "$WORK/log" >&2
  log_error "Couldn't publish the baseline dacpac to the container."
  exit 1
fi
sql "INSERT INTO dbo.Widget (Id, Title) VALUES (1, N'first')"
expect "baseline: the row is in Widget.Title" "first" "$(sql "SELECT Title FROM dbo.Widget WHERE Id = 1")"

# --- 1. plan, apply, plan again -------------------------------------------------------
log_step "Plan -> apply -> plan"
plan "$HEAD_DACPAC" 1
expect "plan 1 succeeds" "0" "$status"
expect "plan 1 has changes" "true" "$(output has-changes)"
expect "plan 1 has no data loss" "false" "$(output data-loss)"
expect "plan 1 names the server" "localhost,${SQL_ENGINE_PORT}" "$(output server)"
expect "plan 1 renames Widget.Title through the refactorlog" "Rename [dbo].[Widget].[Name]" "$(report_of 1 | jq -r '.operations[] | select(.operation == "Rename") | "Rename \(.items[0].value)"')"
expect "plan 1 keeps Extra" "[dbo].[Extra]" "$(grep -o '\[dbo\]\.\[Extra\]' "$WORK/plan-1/summary.md" | head -1)"
apply 1
expect "apply 1 succeeds" "0" "$status"
expect "the rename kept the data" "first" "$(sql "SELECT Name FROM dbo.Widget WHERE Id = 1")"
expect "the post-deployment script filled Status" "3" "$(sql "SELECT COUNT(*) FROM dbo.Status")"
expect "Extra is still there (additive)" "1" "$(sql "SELECT COUNT(*) FROM sys.tables WHERE name = 'Extra'")"
plan "$HEAD_DACPAC" 2
expect "plan 2 succeeds" "0" "$status"
expect "plan 2 has no changes" "false" "$(output has-changes)"

# --- Deployment scripts: always ---------------------------------------------------------
log_step "Deployment scripts: always"
plan "$ALWAYS_DACPAC" 3
expect "plan 3 (always) has changes from the scripts alone" "true" "$(output has-changes)"
apply 3
expect "apply 3 succeeds" "0" "$status"
expect "the MERGE is idempotent: Status has its rows once" "3" "$(sql "SELECT COUNT(*) FROM dbo.Status")"

# --- 2. out-of-band objects: additive and truth -----------------------------------------
log_step "Out-of-band objects"
sql "CREATE TABLE dbo.OutOfBand (Id INT NOT NULL PRIMARY KEY); INSERT INTO dbo.OutOfBand VALUES (1); CREATE USER oob WITHOUT LOGIN"
plan "$ALWAYS_DACPAC" 4
expect "additive plan 4 succeeds" "0" "$status"
expect "additive plan 4 keeps OutOfBand" "[dbo].[OutOfBand]" "$(grep -o '\[dbo\]\.\[OutOfBand\]' "$WORK/plan-4/summary.md" | head -1)"
apply 4
expect "additive apply 4 succeeds" "0" "$status"
expect "OutOfBand is untouched by the additive apply" "1" "$(sql "SELECT COUNT(*) FROM dbo.OutOfBand")"
plan "$ALWAYS_DACPAC" 5 DEPLOY_MODE=truth
expect "truth plan 5 is blocked: it would drop tables" "1" "$status"
expect "truth plan 5 says blocked" "true" "$(output blocked)"
expect "truth plan 5 has data loss" "true" "$(output data-loss)"
expect_log "truth plan 5 says why" "Possible data loss"
expect "truth plan 5 left a summary" "true" "$([ -s "$WORK/plan-5/summary.md" ] && echo true)"
plan "$ALWAYS_DACPAC" 6 DEPLOY_MODE=truth ALLOW_DATA_LOSS=true
expect "truth plan 6 passes with allow-data-loss" "0" "$status"
expect "truth plan 6 does not drop the out-of-band user (default keep list)" "0" "$(grep -c 'SqlUser' "$WORK/plan-6/deploy/deploy-report.xml" || true)"
apply 6
expect "truth apply 6 succeeds" "0" "$status"
expect "OutOfBand is dropped by truth mode" "0" "$(sql "SELECT COUNT(*) FROM sys.tables WHERE name = 'OutOfBand'")"
expect "Extra is dropped by truth mode" "0" "$(sql "SELECT COUNT(*) FROM sys.tables WHERE name = 'Extra'")"
expect "the out-of-band user survives truth mode" "1" "$(sql "SELECT COUNT(*) FROM sys.database_principals WHERE name = 'oob'")"

# --- 4. a dropped column with rows --------------------------------------------------------
log_step "A dropped column with rows"
sql "ALTER TABLE dbo.Widget ADD Legacy INT NULL"
sql "UPDATE dbo.Widget SET Legacy = 7"
plan "$HEAD_DACPAC" 7 DEPLOY_MODE=truth
expect "plan 7 (a column with data would go) is blocked" "1" "$status"
expect "plan 7 says blocked" "true" "$(output blocked)"
plan "$HEAD_DACPAC" 8 DEPLOY_MODE=truth ALLOW_DATA_LOSS=true
expect "plan 8 passes with allow-data-loss" "0" "$status"
apply 8
expect "apply 8 succeeds (BlockOnPossibleDataLoss=False)" "0" "$status"
expect "the column is gone" "0" "$(sql "SELECT COUNT(*) FROM sys.columns WHERE name = 'Legacy'")"

# --- 5. the database changes after the plan ----------------------------------------------
log_step "The database changes after the plan"
sql "DROP VIEW dbo.WidgetNames"
plan "$HEAD_DACPAC" 9
expect "plan 9 sees the missing view" "true" "$(output has-changes)"
# CREATE VIEW must be first in its batch, so it runs through EXEC
sql "EXEC('CREATE VIEW dbo.WidgetNames AS SELECT 1 AS Other')"
apply 9
expect "apply 9 is refused: the database changed" "1" "$status"
expect_log "apply 9 says to plan again" "changed since this plan"
expect "the view was not touched" "1" "$(sql "SELECT COUNT(*) FROM sys.columns WHERE name = 'Other'")"

# --- 6. a profile naming a missing database ------------------------------------------------
log_step "A missing database"
mkdir -p "${REPO_ROOT:?}/${FIXTURE:?}/obj"
sed 's#<TargetDatabaseName>fixture</TargetDatabaseName>#<TargetDatabaseName>nowhere</TargetDatabaseName>#' "$REPO_ROOT/$FIXTURE/$PROFILE" > "$REPO_ROOT/$FIXTURE/$MISSING_PROFILE"
PROFILE_OVERRIDE="$MISSING_PROFILE" plan "$HEAD_DACPAC" 10
expect "plan 10 is refused" "1" "$status"
expect_log "plan 10 says the database doesn't exist" "doesn't exist on localhost"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} engine test(s) failed"
  exit 1
fi
log_summary "All ${cases} engine tests passed"
