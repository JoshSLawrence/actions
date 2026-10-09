#!/usr/bin/env bash
#
# Tests the SQL project scripts offline, with stubs for the tools that need
# a network or a database (mise, dotnet, sqlpackage, az, gh): names
# (names.sh), input validation and the deployment matrix (deployments.sh),
# the build and its deployment-scripts comparison (build.sh, in throwaway Git
# repositories), the report parser, the plan (plan.sh: arguments per deploy
# mode, summaries, data loss, offline plans), how SqlPackage is run with a
# secret (a response file: never on a command line, never in a log or the
# plan), the apply (apply.sh: every refusal, and that it publishes with the
# plan's own arguments), and two shared pieces the area depends on: the PR
# comment's blocked-reason and the stale-plan check's sibling profiles. The
# real SqlPackage is covered by engine-test.sh. Run by pre-commit and CI.
# Needs git, jq, yq, zip and unzip.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_ROOT/sqlproject/scripts"
CANNED="$REPO_ROOT/tests/sqlproject/fixtures"
# shellcheck source=shared/scripts/common.sh
source "$REPO_ROOT/shared/scripts/common.sh"

# Never inherit a repository from a caller (a pre-commit hook sets GIT_DIR and
# friends): every git command below must act on a throwaway repository
while IFS= read -r git_var; do
  unset "$git_var"
done < <(git rev-parse --local-env-vars)

require_tool git
require_tool jq
require_tool yq
require_tool zip
require_tool unzip

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
failures=0
cases=0

# --- Stubs -----------------------------------------------------------------------------
#
# First on PATH, so the scripts' `mise exec -- <tool>` runs them. mise itself
# dispatches to a stub of the tool when there is one, else to the real one
# (yq).

STUBS="$WORK/stubs"
STUB_LOG="$WORK/stub-log"
mkdir -p "$STUBS" "$STUB_LOG/calls"
export STUBS STUB_LOG CANNED

cat > "$STUBS/mise" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  exec)
    shift
    [ "${1:-}" = "--" ] && shift
    tool="$1"
    shift
    if [ -x "$STUBS/$tool" ]; then
      exec "$STUBS/$tool" "$@"
    fi
    PATH="${PATH#"$STUBS":}" exec "$tool" "$@"
    ;;
  current)
    case " ${MISE_PINNED:-dotnet dotnet:microsoft.sqlpackage yq azure-cli} " in
      *" $2 "*) echo "1.0.0" ;;
    esac
    ;;
esac
exit 0
STUB

# Records its argv and the response file (and its mode), then writes canned
# reports and scripts. Env: STUB_REPORT, STUB_KEPT, STUB_SCRIPT (canned
# names), STUB_FAIL (an action to fail), STUB_PUBLISH_EXIT, STUB_ECHO_SECRET
# (echo the secret lines, as SqlPackage does with malformed arguments).
cat > "$STUBS/sqlpackage" << 'STUB'
#!/usr/bin/env bash
rsp="${1#@}"
printf '%s\n' "$@" >> "$STUB_LOG/argv.log"
n=$(($(find "$STUB_LOG/calls" -name '*.rsp' | wc -l) + 1))
cp "$rsp" "$STUB_LOG/calls/$n.rsp"
(stat -c %a "$rsp" 2> /dev/null || stat -f %Lp "$rsp") > "$STUB_LOG/calls/$n.mode"
action="" out=""
while IFS= read -r line; do
  line="${line#\"}"
  line="${line%\"}"
  case "$line" in
    /Action:*) action="${line#/Action:}" ;;
    /OutputPath:*) out="${line#/OutputPath:}" ;;
    /AccessToken:* | /TargetPassword:*)
      if [ -n "${STUB_ECHO_SECRET:-}" ]; then
        echo "*** Unrecognized command line argument '${line#*:}'"
      fi
      ;;
  esac
done < "$rsp"
echo "$action" >> "$STUB_LOG/actions.log"
if [ "${STUB_FAIL:-}" = "$action" ]; then
  echo "stub sqlpackage: ${action} failed"
  exit 1
fi
case "$action" in
  DeployReport)
    case "$out" in
      *kept-report.xml) cp "$CANNED/report-${STUB_KEPT:-kept}.xml" "$out" ;;
      *) cp "$CANNED/report-${STUB_REPORT:-changes}.xml" "$out" ;;
    esac
    ;;
  Script) cp "$CANNED/${STUB_SCRIPT:-script.sql}" "$out" ;;
  Publish) exit "${STUB_PUBLISH_EXIT:-0}" ;;
esac
echo "stub sqlpackage: ${action} done"
STUB

cat > "$STUBS/az" << 'STUB'
#!/usr/bin/env bash
echo "az $*" >> "$STUB_LOG/az.log"
echo "FAKE.TOKEN.VALUE"
STUB

# build writes <project name>.dacpac (a zip) holding the cwd's
# Scripts/Script.{Pre,Post}Deployment.sql as predeploy.sql/postdeploy.sql,
# and a stray file to be cleaned; msbuild -getProperty prints the name.
cat > "$STUBS/dotnet" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  build)
    [ -z "${STUB_DOTNET_FAIL:-}" ] || {
      echo "error SQL71501: stub build error"
      exit 1
    }
    project="$2"
    shift 2
    out=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-o" ] && out="$2"
      shift
    done
    name="$(basename "$project" .sqlproj)"
    tmp="$(mktemp -d)"
    echo "<model/>" > "$tmp/model.xml"
    [ ! -f Scripts/Script.PreDeployment.sql ] || cp Scripts/Script.PreDeployment.sql "$tmp/predeploy.sql"
    [ ! -f Scripts/Script.PostDeployment.sql ] || cp Scripts/Script.PostDeployment.sql "$tmp/postdeploy.sql"
    mkdir -p "$out"
    (cd "$tmp" && zip -q "$out/$name.dacpac" ./*)
    echo stray > "$out/$name.pdb"
    rm -rf "$tmp"
    ;;
  msbuild)
    echo "${STUB_TARGET_NAME:-$(basename "$2" .sqlproj)}"
    ;;
esac
STUB

# Records the comment body the PR comment script posts
cat > "$STUBS/gh" << 'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pulls/"*"--jq .head.sha"*) echo "abc1234def" ;;
  *"--paginate"*) ;;
  *"--input -"*) cat > "$STUB_LOG/gh-body.json" ;;
esac
STUB
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# --- Harness -----------------------------------------------------------------------------

# Run a script with extra env (VAR=value arguments), from the current
# directory. The exit code is in $status, the log in $WORK/log and the step
# outputs in $WORK/output.
# Usage: run <script> [VAR=value ...]
run() {
  local script="$1"
  shift
  : > "$WORK/output"
  set +e
  env GITHUB_OUTPUT="$WORK/output" RUNNER_TEMP="$WORK/runner" "$@" "$SCRIPTS/$script" > "$WORK/log" 2>&1
  status=$?
  set -e
}

# Print an output of the last run
output() {
  sed -n "s/^${1}=//p" "$WORK/output" | tail -1
}

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

# Usage: expect_log "<case name>" "<text the last run's log has>"
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

# Usage: expect_not_log "<case name>" "<text the last run's log lacks>"
expect_not_log() {
  cases=$((cases + 1))
  if grep -qF -- "$2" "$WORK/log"; then
    log_error "$1: '$2' is in the log:"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  else
    log_success "$1"
  fi
}

# Usage: expect_file_has "<case name>" "<file>" "<text>"
expect_file_has() {
  cases=$((cases + 1))
  if grep -qF -- "$3" "$2"; then
    log_success "$1"
  else
    log_error "$1: '$3' isn't in ${2}:"
    sed 's/^/    /' "$2" >&2
    failures=$((failures + 1))
  fi
}

# Usage: expect_file_lacks "<case name>" "<file>" "<text>"
expect_file_lacks() {
  cases=$((cases + 1))
  if grep -qF -- "$3" "$2"; then
    log_error "$1: '$3' is in ${2}:"
    sed 's/^/    /' "$2" >&2
    failures=$((failures + 1))
  else
    log_success "$1"
  fi
}

# Usage: expect_refused "<case name>" "<text the refusal says>" <script> [VAR=value ...]
expect_refused() {
  local name="$1" text="$2" script="$3"
  shift 3
  run "$script" "$@"
  cases=$((cases + 1))
  if [ "$status" -eq 0 ]; then
    log_error "${name}: it succeeded"
    failures=$((failures + 1))
  elif grep -qF -- "$text" "$WORK/log"; then
    log_success "$name"
  else
    log_error "${name}: refused, but '${text}' isn't in the log:"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

# Print the names in a directory, sorted the same everywhere, on one line
# Usage: names_in <dir>
names_in() {
  (
    cd "$1"
    LC_ALL=C
    printf '%s ' *
  ) | sed 's/ $//'
}

# The recorded SqlPackage calls: the response files, numbered from 1
reset_stub_log() {
  rm -rf "${STUB_LOG:?}/calls"
  mkdir -p "$STUB_LOG/calls"
  : > "$STUB_LOG/argv.log"
  : > "$STUB_LOG/actions.log"
  : > "$STUB_LOG/az.log"
  rm -rf "${WORK:?}/runner"
  mkdir -p "$WORK/runner"
}

# The number of recorded SqlPackage calls of an action
calls_of() {
  grep -c "^${1}\$" "$STUB_LOG/actions.log" || true
}

# The number of the last recorded call of an action
last_call_of() {
  grep -n "^${1}\$" "$STUB_LOG/actions.log" | tail -1 | cut -d: -f1
}

# --- A project and its repository -------------------------------------------------------------

PROFILE_XMLNS='http://schemas.microsoft.com/developer/msbuild/2003'

# Usage: write_profile <file> <server> <database> [extra property lines]
write_profile() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" << XML
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="Current" xmlns="${PROFILE_XMLNS}">
  <PropertyGroup>
    <TargetDatabaseName>${3}</TargetDatabaseName>
    <TargetConnectionString>Data Source=${2};Encrypt=True</TargetConnectionString>
    <IncludeTransactionalScripts>True</IncludeTransactionalScripts>
    ${4:-}
  </PropertyGroup>
  <ItemGroup>
    <SqlCmdVariable Include="Environment">
      <Value>dev</Value>
    </SqlCmdVariable>
  </ItemGroup>
</Project>
XML
}

# A project folder: a .sqlproj, a mise.toml, two profiles, and (with
# "scripts") a pre- and a post-deployment script.
# Usage: make_project <dir> [scripts]
make_project() {
  local dir="$1"
  mkdir -p "$dir/deployments" "$dir/Scripts"
  echo '<Project><Sdk Name="Microsoft.Build.Sql" Version="2.2.0" /></Project>' > "$dir/x.sqlproj"
  echo '[tools]' > "$dir/mise.toml"
  write_profile "$dir/deployments/dev.publish.xml" sql-dev.database.windows.net sqldb-dev
  write_profile "$dir/deployments/prod.publish.xml" sql-prod.database.windows.net sqldb-prod
  if [ "${2:-}" = scripts ]; then
    echo "PRINT 'pre';" > "$dir/Scripts/Script.PreDeployment.sql"
    echo "PRINT 'post';" > "$dir/Scripts/Script.PostDeployment.sql"
  else
    rm -rf "${dir:?}/Scripts"
  fi
}

# A repository with a project in proj/, committed
make_repo() {
  rm -rf "${WORK:?}/repo"
  mkdir -p "$WORK/repo"
  cd "$WORK/repo"
  git init -q -b main
  # Refuse to configure or commit anywhere but the throwaway repository
  case "$(git rev-parse --absolute-git-dir)" in
    "$(cd "$WORK" && pwd -P)"/*) ;;
    *)
      log_error "make_repo: git would act on $(git rev-parse --absolute-git-dir), outside ${WORK}. Aborting before touching its config."
      exit 1
      ;;
  esac
  git config user.email test@example.com
  git config user.name test
  make_project proj scripts
  git add -A
  git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

# Build the project of the current repository
# Usage: build_project <output dir> [VAR=value ...]
build_project() {
  local output_dir="$1"
  shift
  run build.sh WORKING_DIR=proj OUTPUT_DIR="$output_dir" WORK_DIR="$WORK/build-work" "$@"
}

# --- names.sh -----------------------------------------------------------------------------------

mkdir -p "$WORK/runner"
cd "$WORK"

names() {
  run names.sh "$@"
}

names WORKING_DIRECTORY=. REPOSITORY_NAME=myrepo
expect "names: a root folder is named after the repository" "sqlproject:myrepo" "$(output key)"
expect "names: its title" "SQL project: \`myrepo\`" "$(output title)"
names WORKING_DIRECTORY=database/core
expect "names: a nested folder" "sqlproject:database/core" "$(output key)"
names WORKING_DIRECTORY=database/core STACK_NAME=core DEPLOYMENT=dev APPLY_ENVIRONMENT=core-dev
expect "names: key with deployment and environment" "sqlproject:core:dev:core-dev" "$(output key)"
expect "names: title with deployment and environment" "SQL project: \`core\` · \`dev\` → \`core-dev\`" "$(output title)"
plan_artifact="$(output artifact-name)"
names WORKING_DIRECTORY=database/core STACK_NAME=core DEPLOYMENT=dev
expect "names: the artifact name differs per environment" "true" "$([ "$(output artifact-name)" != "$plan_artifact" ] && echo true)"
names WORKING_DIRECTORY=a/b
first="$(output artifact-name)"
names WORKING_DIRECTORY=a-b
expect "names: keys that sanitize alike get distinct artifacts" "true" "$([ "$(output artifact-name)" != "$first" ] && echo true)"
names WORKING_DIRECTORY=a/b DEPLOYMENTS=deployments/*.publish.xml
dacpac_a="$(output dacpac-artifact-name)"
names WORKING_DIRECTORY=a/b DEPLOYMENTS=deployments/*.publish.xml
expect "names: identical calls share the dacpac artifact" "$dacpac_a" "$(output dacpac-artifact-name)"
names WORKING_DIRECTORY=a/b DEPLOYMENTS=deployments/dev.publish.xml
expect "names: other deployments get another dacpac artifact" "true" "$([ "$(output dacpac-artifact-name)" != "$dacpac_a" ] && echo true)"
names WORKING_DIRECTORY=a/b DEPLOYMENTS=deployments/*.publish.xml TARGET_DACPAC=ci/baseline.dacpac
expect "names: so does a target-dacpac" "true" "$([ "$(output dacpac-artifact-name)" != "$dacpac_a" ] && echo true)"
names WORKING_DIRECTORY=a/b STACK_NAME="$(printf 'x%.0s' $(seq 1 300))" DEPLOYMENTS=d
expect "names: the dacpac artifact name keeps to 255 characters" "true" "$([ "$(output dacpac-artifact-name | wc -c)" -le 256 ] && echo true)"
names WORKING_DIRECTORY=a/b
expect "names: the dacpac artifact is per project and distinct from the plan's" "true" "$([ "$(output dacpac-artifact-name)" != "$(output artifact-name)" ] && echo true)"

# --- deployments.sh -----------------------------------------------------------------------------

rm -rf "${WORK:?}/repo"
mkdir -p "$WORK/repo"
cd "$WORK/repo"
make_project proj
mkdir -p proj/ci
write_profile proj/ci/engine.publish.xml localhost,14330 fixture
deployments() {
  run deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY_ENVIRONMENT='core-{deployment}' "$@"
}

deployments VARIABLES='Environment={deployment}' PLAN_ENVIRONMENT='plan-{deployment}'
expect "deployments: a glob matches the profiles" '["dev","prod"]' "$(output deployments)"
expect "deployments: the count" "2" "$(output count)"
matrix="$(output matrix)"
expect "deployments: the profile of a deployment" "deployments/prod.publish.xml" "$(jq -r '.deployment[] | select(.name == "prod") | .profile' <<< "$matrix")"
expect "deployments: {deployment} is replaced in variables" "Environment=prod" "$(jq -r '.deployment[] | select(.name == "prod") | .variables' <<< "$matrix")"
expect "deployments: {deployment} is replaced in the apply environment" "core-dev" "$(jq -r '.deployment[] | select(.name == "dev") | .apply_environment' <<< "$matrix")"
expect "deployments: {deployment} is replaced in the plan environment" "plan-dev" "$(jq -r '.deployment[] | select(.name == "dev") | .plan_environment' <<< "$matrix")"
expect "deployments: the environments, unique" "core-dev core-prod plan-dev plan-prod" "$(output environments)"
expect "deployments: the preflight paths default to the folder" "proj" "$(jq -r '.deployment[0].preflight_paths | split("\n")[0]' <<< "$matrix")"
expect "deployments: sibling profiles are left out of the preflight paths" "!proj/deployments/prod.publish.xml" "$(jq -r '.deployment[] | select(.name == "dev") | .preflight_paths | split("\n")[] | select(. == "!proj/deployments/prod.publish.xml")' <<< "$matrix")"
expect "deployments: so is every other profile in the folder" "!proj/ci/engine.publish.xml" "$(jq -r '.deployment[] | select(.name == "dev") | .preflight_paths | split("\n")[] | select(. == "!proj/ci/engine.publish.xml")' <<< "$matrix")"
expect "deployments: the deployment's own profile comes last" "proj/deployments/dev.publish.xml" "$(jq -r '.deployment[] | select(.name == "dev") | .preflight_paths | split("\n") | last' <<< "$matrix")"

# The stale-plan check reads those paths as rules (shared/scripts/apply-preflight.sh)
rules_for() {
  local entry rule
  local -a rules=()
  while IFS= read -r entry; do
    rule="$(path_entry_rule "$entry")"
    rules+=("$rule")
  done < <(jq -r --arg n "$1" '.deployment[] | select(.name == $n) | .preflight_paths | split("\n")[]' <<< "$matrix")
  printf '%s\n' "${rules[@]}"
}
watched() {
  local -a rules
  mapfile -t rules < <(rules_for "$1")
  if path_rules_match "$2" "${rules[@]}"; then echo true; else echo false; fi
}
expect "stale plan: a project file counts" "true" "$(watched dev proj/dbo/Tables/T.sql)"
expect "stale plan: the deployment's own profile counts" "true" "$(watched dev proj/deployments/dev.publish.xml)"
expect "stale plan: a sibling's profile doesn't" "false" "$(watched dev proj/deployments/prod.publish.xml)"
expect "stale plan: nor does another profile of the folder" "false" "$(watched dev proj/ci/engine.publish.xml)"
expect "stale plan: a file outside the folder doesn't" "false" "$(watched dev README.md)"
deployments PREFLIGHT_PATHS="proj/src shared.sql"
matrix="$(output matrix)"
expect "stale plan: the profile counts even outside the preflight paths" "true" "$(watched prod proj/deployments/prod.publish.xml)"
expect "stale plan: the given paths count" "true" "$(watched prod shared.sql)"

expect_refused "deployments: no match" "matches no *.publish.xml files" deployments.sh WORKING_DIR=proj DEPLOYMENTS='nothing/*.publish.xml' APPLY=false
echo '<Project/>' > proj/deployments/other.xml
expect_refused "deployments: a profile that isn't *.publish.xml" "doesn't end in .publish.xml" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/other.xml' APPLY=false
expect_refused "deployments: a missing path" "not found in proj" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/missing.publish.xml' APPLY=false
write_profile proj/ci/dev.publish.xml sql-x.database.windows.net sqldb-x
expect_refused "deployments: duplicate names" "Two deployments of proj are named 'dev'" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml ci/dev.publish.xml' APPLY=false
expect_refused "deployments: apply without apply-environment" "apply-environment is empty" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml'
expect_refused "deployments: target-dacpac with apply" "so it can't be applied" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY_ENVIRONMENT=x TARGET_DACPAC=ci/t.dacpac
expect_refused "deployments: target-dacpac that doesn't exist" "target-dacpac 'ci/t.dacpac' not found" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false TARGET_DACPAC=ci/t.dacpac
echo dacpac > proj/ci/t.dacpac
deployments APPLY=false TARGET_DACPAC=ci/t.dacpac
expect "deployments: a target-dacpac without apply is fine" "0" "$status"
expect_refused "deployments: bad deploy-mode" "deploy-mode 'both' isn't valid" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false DEPLOY_MODE=both
expect_refused "deployments: bad deployment-scripts" "deployment-scripts 'never' isn't valid" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false DEPLOYMENT_SCRIPTS=never
expect_refused "deployments: bad keep-object-types" "keep-object-types has 'Bad Type!'" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false "KEEP_OBJECT_TYPES=Users;Bad Type!"
expect_refused "deployments: a missing working directory" "working-directory 'nope' doesn't exist" deployments.sh WORKING_DIR=nope DEPLOYMENTS='x.publish.xml' APPLY=false
expect_refused "deployments: a working directory outside the repository" "climbs out of the repository" deployments.sh WORKING_DIR=../x DEPLOYMENTS='x.publish.xml' APPLY=false
expect_refused "deployments: a bad properties line" "properties: entry 1 isn't Name=Value" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false PROPERTIES='not an assignment'
expect_refused "deployments: an owned property in the properties input" "properties: DropObjectsNotInSource is owned by the workflow" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false PROPERTIES='DropObjectsNotInSource=True'
expect_refused "deployments: a bad variables line" "variables: entry 2 isn't Name=Value" deployments.sh WORKING_DIR=proj DEPLOYMENTS='deployments/*.publish.xml' APPLY=false "VARIABLES=Good=1
=bad"

# Every profile problem is reported at once
mkdir -p proj/bad
cat > proj/bad/one.publish.xml << XML
<Project ToolsVersion="Current">
  <PropertyGroup>
    <IncludeTransactionalScripts>True</IncludeTransactionalScripts>
  </PropertyGroup>
</Project>
XML
cat > proj/bad/two.publish.xml << XML
<Project ToolsVersion="Current" xmlns="${PROFILE_XMLNS}">
  <PropertyGroup>
    <TargetDatabaseName>db"quote</TargetDatabaseName>
    <TargetConnectionString>Data Source=tcp:srv.database.windows.net;User ID=sa;Password=hunter2;Authentication=Active Directory Default</TargetConnectionString>
    <BlockOnPossibleDataLoss>False</BlockOnPossibleDataLoss>
    <DropObjectsNotInSource>True</DropObjectsNotInSource>
    <DoNotDropObjectTypes>Users</DoNotDropObjectTypes>
    <CreateNewDatabase>True</CreateNewDatabase>
    <TargetPassword>x</TargetPassword>
  </PropertyGroup>
</Project>
XML
run deployments.sh WORKING_DIR=proj DEPLOYMENTS='bad/*.publish.xml' APPLY=false
expect "deployments: bad profiles are refused" "1" "$status"
expect_log "profile: no MSBuild namespace" "has no MSBuild namespace"
expect_log "profile: no TargetDatabaseName" "no TargetDatabaseName"
expect_log "profile: no server" "no server in TargetConnectionString"
expect_log "profile: credentials in the connection string" "has credentials (user id, password, authentication)"
expect_log "profile: BlockOnPossibleDataLoss is owned" "BlockOnPossibleDataLoss is set, but the workflow owns it. Remove it from the profile; set the allow-data-loss input instead"
expect_log "profile: DropObjectsNotInSource is owned" "set the deploy-mode input instead"
expect_log "profile: DoNotDropObjectTypes is owned" "set the keep-object-types (and deploy-mode) input instead"
expect_log "profile: CreateNewDatabase is refused" "CreateNewDatabase is True"
expect_log "profile: TargetPassword is refused" "TargetPassword is set"
expect_log "profile: a double quote in a value" "contains a double quote or a line break"
expect_not_log "profile: the password never reaches the log" "hunter2"

# --- The report parser --------------------------------------------------------------------------

# shellcheck source=sqlproject/scripts/sqlproject.sh
source "$SCRIPTS/sqlproject.sh"
cd "$WORK/repo/proj"
report() {
  sql_report_json "$CANNED/report-$1.xml"
}
expect "report: nothing to do (no Operations at all)" '{"alerts":[],"operations":[]}' "$(report none)"
expect "report: one operation with one item" '{"alerts":[],"operations":[{"items":[{"type":"SqlTable","value":"[dbo].[Status]"}],"operation":"Create"}]}' "$(report one)"
expect "report: several operations and items" "Alter Create Rename" "$(report changes | jq -r '[.operations[].operation] | join(" ")')"
expect "report: several items of one operation, sorted" "[dbo].[Status] [dbo].[WidgetNames]" "$(report changes | jq -r '.operations[] | select(.operation == "Create") | [.items[].value] | join(" ")')"
expect "report: the same report in another order compares equal" "$(report changes)" "$(report changes-reordered)"
expect "report: a different report doesn't" "true" "$([ "$(report changes)" != "$(report one)" ] && echo true)"
expect "report: a rename" "[dbo].[Widget].[Name]" "$(report changes | jq -r '.operations[] | select(.operation == "Rename") | .items[0].value')"
expect "report: data loss" "The column [dbo].[Widget].[Title] is being dropped, data loss could occur." "$(sql_data_loss "$(report dataloss)")"
expect "report: other alerts are kept apart from data loss" "Warning" "$(report dataloss | jq -r '.alerts[] | select(.name != "DataIssue") | .name')"
expect "report: no data loss" "" "$(sql_data_loss "$(report changes)")"
expect "report: a missing database is in the script" "yes" "$(sql_missing_database "$CANNED/script-create-database.sql" && echo yes)"
expect "report: an existing database isn't" "no" "$(sql_missing_database "$CANNED/script.sql" && echo yes || echo no)"
cd "$WORK"

# --- build.sh ------------------------------------------------------------------------------------

make_repo
build_project "$WORK/dacpac"
expect "build: succeeds" "0" "$status"
expect "build: the dacpac's name" "x.dacpac" "$(output dacpac-name)"
expect "build: only dacpacs and the json files stay" "build.json deployment-scripts.json x.dacpac" "$(names_in "$WORK/dacpac")"
expect "build: the dacpac digest" "$(file_sha256 "$WORK/dacpac/x.dacpac")" "$(output dacpac-sha256)"
expect "build: scripts count as changed without a base" "true" "$(output deployment-scripts-changed)"
expect "build: why, in deployment-scripts.json" "there is no base to compare with" "$(jq -r .why "$WORK/dacpac/deployment-scripts.json")"

build_project "$WORK/dacpac" SCRIPTS_BASE="$BASE"
expect "build: scripts equal to the base's don't count" "false" "$(output deployment-scripts-changed)"
expect "build: the comparison is recorded" "$(jq -r .pre_sha256 "$WORK/dacpac/deployment-scripts.json")" "$(jq -r .base_pre_sha256 "$WORK/dacpac/deployment-scripts.json")"
expect "build: the base worktree is gone" "1" "$(git worktree list | wc -l | tr -d ' ')"
build_project "$WORK/dacpac" SCRIPTS_BASE="$BASE" DEPLOYMENT_SCRIPTS=always
expect "build: deployment-scripts always counts them" "true" "$(output deployment-scripts-changed)"
echo "PRINT 'post 2';" > proj/Scripts/Script.PostDeployment.sql
git commit -qam "change the post-deployment script"
build_project "$WORK/dacpac" SCRIPTS_BASE="$BASE"
expect "build: scripts different from the base's count" "true" "$(output deployment-scripts-changed)"
build_project "$WORK/dacpac" SCRIPTS_BASE="$(git rev-parse HEAD)"
expect "build: ... and not against the commit that has them" "false" "$(output deployment-scripts-changed)"
make_project proj2 scripts
git add -A
git commit -qm "a new project"
run build.sh WORKING_DIR=proj2 OUTPUT_DIR="$WORK/dacpac2" WORK_DIR="$WORK/build-work" SCRIPTS_BASE="$BASE"
expect "build: a project missing from the base counts as changed" "true" "$(output deployment-scripts-changed)"
expect_log "build: ... with a warning" "doesn't exist in"
rm -rf proj/Scripts
git add -A
git commit -qm "no scripts"
build_project "$WORK/dacpac" SCRIPTS_BASE="$BASE"
expect "build: a project without scripts has none to count" "false" "$(output deployment-scripts-changed)"
expect "build: ... and says so" "null" "$(jq -r .pre_sha256 "$WORK/dacpac/deployment-scripts.json")"
run build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" SCRIPTS_BASE="0123456789abcdef0123456789abcdef01234567" DEPLOYMENT_SCRIPTS=changed
expect "build: no scripts, nothing to compare" "0" "$status"
git checkout -q "$BASE"
run build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" SCRIPTS_BASE="0123456789abcdef0123456789abcdef01234567"
expect "build: a base commit that isn't in the checkout counts as changed" "true" "$(output deployment-scripts-changed)"
expect_log "build: ... and says to fetch the history" "fetch-depth: 0"
git checkout -q main
expect_refused "build: a failing build" "The project didn't build" build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" STUB_DOTNET_FAIL=1
expect_refused "build: a dacpac that isn't there" "didn't produce a dacpac named other.dacpac" build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" STUB_TARGET_NAME=other
expect_refused "build: a bad scripts-base" "isn't a commit SHA or none" build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" SCRIPTS_BASE=main
expect_refused "build: a bad deployment-scripts" "deployment-scripts 'x' isn't valid" build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" DEPLOYMENT_SCRIPTS=x
expect_refused "build: dotnet must be pinned" "dotnet isn't pinned" build.sh WORKING_DIR=proj OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work" MISE_PINNED=yq
mkdir -p twoprojects
cp proj/x.sqlproj twoprojects/a.sqlproj
cp proj/x.sqlproj twoprojects/b.sqlproj
cp proj/mise.toml twoprojects/mise.toml
expect_refused "build: two projects in a folder" "More than one SQL project" build.sh WORKING_DIR=twoprojects OUTPUT_DIR="$WORK/dacpac" WORK_DIR="$WORK/build-work"

# --- plan.sh ---------------------------------------------------------------------------------------

# The dacpac directory every plan below uses: a build of a project with
# scripts that count as changed, and one without scripts
rm -rf "${WORK:?}/repo"
mkdir -p "$WORK/repo"
cd "$WORK/repo"
make_project proj scripts
build_project "$WORK/dacpac-scripts"
make_project proj
build_project "$WORK/dacpac-plain"
make_project proj scripts
PLAN="$WORK/plan"

# Usage: plan [VAR=value ...]   (online, the dev profile, the scripts build)
plan() {
  reset_stub_log
  run plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml DEPLOYMENT=dev \
    PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" TITLE="SQL project: x" "$@"
}
# The response file of an action's last call, one argument per line, without
# its quotes
rsp_of() {
  sed 's/^"//; s/"$//' "$STUB_LOG/calls/$(last_call_of "$1").rsp"
}

plan
expect "plan: succeeds" "0" "$status"
expect "plan: has changes" "true" "$(output has-changes)"
expect "plan: no data loss" "false" "$(output data-loss)"
expect "plan: not blocked" "false" "$(output blocked)"
expect "plan: server" "sql-dev.database.windows.net" "$(output server)"
expect "plan: database" "sqldb-dev" "$(output database)"
expect "plan: digest" "$(dir_sha256 "$PLAN/deploy")" "$(output plan-sha256)"
expect "plan: the summary file" "$PLAN/summary.md" "$(output summary-file)"
expect "plan: target.json" '{"service":"sqlproject","deployment":"dev","server":"sql-dev.database.windows.net","database":"sqldb-dev","dacpac":"x.dacpac","profile":"deployments/dev.publish.xml","deploy_mode":"additive","offline":false}' "$(jq -c '{service, deployment, server, database, dacpac, profile, deploy_mode, offline}' "$PLAN/deploy/target.json")"
expect "plan: the layout" "build.json dacpac deploy-report.xml deployment-scripts.json profile.publish.xml target.json" "$(names_in "$PLAN/deploy")"
expect "plan: the other files" "deploy kept-report.xml script.sql summary.md" "$(names_in "$PLAN")"
expect "plan: the profile is the committed one" "" "$(diff proj/deployments/dev.publish.xml "$PLAN/deploy/profile.publish.xml" || true)"
expect "plan: a report, a script and a kept report were made" "DeployReport DeployReport Script" "$(sort "$STUB_LOG/actions.log" | tr '\n' ' ' | sed 's/ $//')"
rsp_of Script > "$WORK/script.args"
expect_file_has "plan: the source is the plan's own dacpac" "$WORK/script.args" "/SourceFile:${PLAN}/deploy/dacpac/x.dacpac"
expect_file_has "plan: the profile is the plan's own copy" "$WORK/script.args" "/Profile:${PLAN}/deploy/profile.publish.xml"
expect_file_has "plan: the server is passed explicitly" "$WORK/script.args" "/TargetServerName:sql-dev.database.windows.net"
expect_file_has "plan: and the database" "$WORK/script.args" "/TargetDatabaseName:sqldb-dev"
expect_file_has "plan: additive mode" "$WORK/script.args" "/p:DropObjectsNotInSource=False"
expect_file_has "plan: possible data loss blocks the publish" "$WORK/script.args" "/p:BlockOnPossibleDataLoss=True"
expect_file_lacks "plan: additive mode has no keep list" "$WORK/script.args" "DoNotDropObjectTypes"
kept_call="$(grep -l 'DropObjectsNotInSource=True' "$STUB_LOG"/calls/*.rsp | head -1)"
sed 's/^"//; s/"$//' "$kept_call" > "$WORK/kept.args"
expect_file_has "plan: the kept report asks what truth mode would drop" "$WORK/kept.args" "/p:DoNotDropObjectTypes=Users;Logins;DatabaseRoles;ApplicationRoles;RoleMembership;ServerRoles;ServerRoleMembership;Permissions;Credentials;DatabaseScopedCredentials;MasterKeys"
expect_file_has "plan: the summary headline" "$PLAN/summary.md" "### 📋 Plan: 2 to create, 1 to alter, 1 to rename, deployment scripts changed"
expect_file_has "plan: the summary names the database" "$PLAN/summary.md" "Database \`sqldb-dev\` on \`sql-dev.database.windows.net\`, profile \`deployments/dev.publish.xml\`, additive mode."
expect_file_has "plan: the changes table" "$PLAN/summary.md" "| 🟡 rename | \`[dbo].[Widget].[Name]\` | SqlSimpleColumn |"
expect_file_has "plan: what is kept" "$PLAN/summary.md" "Kept: in the database, not in the project (2)"
expect_file_has "plan: the kept objects" "$PLAN/summary.md" "| \`[dbo].[Extra]\` | SqlTable |"
expect_file_has "plan: the deployment scripts" "$PLAN/summary.md" "PRINT 'post';"
expect_file_has "plan: the deployment script" "$PLAN/summary.md" "CREATE TABLE [dbo].[Status]"
expect_file_has "plan: the deploy options" "$PLAN/summary.md" "Profile SQLCMD variables: \`Environment=dev\`"
expect_file_lacks "plan: no byte order mark in the summary" "$PLAN/summary.md" $'\xef\xbb\xbf'

# Order of the changes table: drops first, then renames, alters, creates
plan STUB_REPORT=dataloss ALLOW_DATA_LOSS=true
expect "plan: data loss allowed passes" "0" "$status"
expect "plan: ... and is reported" "true" "$(output data-loss)"
expect "plan: ... but not blocked" "false" "$(output blocked)"
expect_file_has "plan: allowed data loss is said so" "$PLAN/summary.md" "possible data loss, allowed by allow-data-loss"
expect_file_has "plan: unknown operations are counted" "$PLAN/summary.md" "1 to alter, 1 to table rebuild"
expect_file_has "plan: other alerts are listed" "$PLAN/summary.md" "- **Warning:** Something to know about."
rsp_of Script > "$WORK/script.args"
expect_file_has "plan: allow-data-loss publishes without blocking" "$WORK/script.args" "/p:BlockOnPossibleDataLoss=False"
expect "plan: ... and records it" "true" "$(jq .allow_data_loss "$PLAN/deploy/target.json")"

plan STUB_REPORT=dataloss
expect "plan: data loss blocks the plan (exit 1)" "1" "$status"
expect "plan: blocked output" "true" "$(output blocked)"
expect "plan: data-loss output" "true" "$(output data-loss)"
expect "plan: blocked-reason" "Possible data loss (see the plan), so it can't be applied. Change the project to avoid it, or, if the loss is intended, re-run with the workflow's allow-data-loss input on." "$(output blocked-reason)"
expect "plan: a blocked plan still has its digest" "$(dir_sha256 "$PLAN/deploy")" "$(output plan-sha256)"
expect_file_has "plan: the summary says it is blocked" "$PLAN/summary.md" "so this plan is blocked"
expect_file_has "plan: and lists the issue" "$PLAN/summary.md" "> - The column [dbo].[Widget].[Title] is being dropped"

plan DEPLOY_MODE=truth
expect "plan: truth mode succeeds" "0" "$status"
rsp_of Script > "$WORK/script.args"
expect_file_has "plan: truth mode drops what isn't in the project" "$WORK/script.args" "/p:DropObjectsNotInSource=True"
expect_file_has "plan: ... except the keep list" "$WORK/script.args" "/p:DoNotDropObjectTypes=Users;Logins;"
expect "plan: truth mode makes no kept report" "DeployReport Script" "$(sort "$STUB_LOG/actions.log" | tr '\n' ' ' | sed 's/ $//')"
expect_file_lacks "plan: ... so the summary has no kept list" "$PLAN/summary.md" "Kept:"
expect_file_has "plan: the summary says truth" "$PLAN/summary.md" "truth mode."
plan DEPLOY_MODE=truth KEEP_OBJECT_TYPES=
rsp_of Script > "$WORK/script.args"
expect_file_lacks "plan: an empty keep list sends no DoNotDropObjectTypes" "$WORK/script.args" "DoNotDropObjectTypes"
plan DEPLOY_MODE=truth "KEEP_OBJECT_TYPES=Users
Permissions"
rsp_of Script > "$WORK/script.args"
expect_file_has "plan: a newline-separated keep list is joined with ;" "$WORK/script.args" "/p:DoNotDropObjectTypes=Users;Permissions"
plan PROPERTIES='CommandTimeout=600' VARIABLES='Extra=1'
rsp_of Script > "$WORK/script.args"
expect_file_has "plan: the properties input is passed after the owned ones" "$WORK/script.args" "/p:CommandTimeout=600"
expect_file_has "plan: the variables input is passed" "$WORK/script.args" "/v:Extra=1"
expect "plan: ... and recorded in target.json" "600 1" "$(jq -r '"\(.properties.CommandTimeout) \(.variables.Extra)"' "$PLAN/deploy/target.json")"

plan STUB_REPORT=none DACPAC_DIR="$WORK/dacpac-plain"
expect "plan: nothing to do, no scripts" "false" "$(output has-changes)"
expect_file_has "plan: no changes headline" "$PLAN/summary.md" "### ✅ No changes"
expect_file_has "plan: and says it matches" "$PLAN/summary.md" "\`sqldb-dev\` matches the project. Nothing to publish."
expect_file_has "plan: the kept list is still shown" "$PLAN/summary.md" "Kept: in the database, not in the project (2)"
plan STUB_REPORT=none
expect "plan: scripts alone make a change" "true" "$(output has-changes)"
expect_file_has "plan: ... and the headline says so" "$PLAN/summary.md" "### 📋 Plan: deployment scripts changed"
unchanged="$WORK/dacpac-unchanged"
cp -R "$WORK/dacpac-scripts" "$unchanged"
jq '.changed = false | .why = "they are the same as in the base commit"' "$WORK/dacpac-scripts/deployment-scripts.json" > "$unchanged/deployment-scripts.json"
plan STUB_REPORT=none DACPAC_DIR="$unchanged"
expect "plan: scripts that are unchanged are no change" "false" "$(output has-changes)"
expect_file_has "plan: ... and the summary says so" "$PLAN/summary.md" "Deployment scripts: unchanged"
plan STUB_REPORT=one DACPAC_DIR="$unchanged"
expect_file_has "plan: a single operation" "$PLAN/summary.md" "### 📋 Plan: 1 to create"

expect_refused "plan: a missing database" "Database sqldb-dev doesn't exist on sql-dev.database.windows.net" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" STUB_SCRIPT=script-create-database.sql
expect_file_has "plan: ... also in the summary" "$PLAN/summary.md" "Plan failed"
expect "plan: ... with no changes reported" "false" "$(output has-changes)"
reset_stub_log
expect_refused "plan: a SqlPackage failure says what to check" "must reach sql-dev.database.windows.net (a private endpoint needs a runner in the network)" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" STUB_FAIL=DeployReport
expect_file_has "plan: ... and the summary has its output" "$PLAN/summary.md" "stub sqlpackage: DeployReport failed"
expect_refused "plan: a bad deploy-mode" "deploy-mode 'x' isn't valid" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" DEPLOY_MODE=x
expect_refused "plan: a missing profile" "publish profile deployments/none.publish.xml doesn't exist" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/none.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work"
write_profile proj/creds.publish.xml "srv;Password=x" db
expect_refused "plan: a profile with problems" "has credentials" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=creds.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work"
write_profile bad3.publish.xml srv db '<CreateNewDatabase>True</CreateNewDatabase>'
expect_refused "plan: CreateNewDatabase is refused" "CreateNewDatabase is True" plan.sh WORKING_DIR=. DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=bad3.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work"
expect_refused "plan: a bad properties input" "The properties input is invalid" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" PROPERTIES='BlockOnPossibleDataLoss=False'
expect_refused "plan: a dacpac directory that isn't a build's" "No build.json" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work"
expect_refused "plan: sqlpackage must be pinned" "dotnet:microsoft.sqlpackage isn't pinned" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" MISE_PINNED="dotnet yq"
expect_refused "plan: azure-cli must be pinned online" "azure-cli isn't pinned" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" MISE_PINNED="dotnet dotnet:microsoft.sqlpackage yq"

# Offline: against a dacpac, no Azure
mkdir -p proj/ci
cp "$WORK/dacpac-plain/x.dacpac" proj/ci/baseline.dacpac
plan TARGET_DACPAC=ci/baseline.dacpac MISE_PINNED="dotnet dotnet:microsoft.sqlpackage yq"
expect "plan: offline succeeds without azure-cli" "0" "$status"
expect "plan: offline is recorded" "true" "$(jq .offline "$PLAN/deploy/target.json")"
expect "plan: offline has no server" "null" "$(jq .server "$PLAN/deploy/target.json")"
rsp_of Script > "$WORK/script.args"
expect_file_has "plan: offline plans against the file" "$WORK/script.args" "/TargetFile:${PLAN}/deploy/target.dacpac"
expect_file_lacks "plan: ... not a server" "$WORK/script.args" "/TargetServerName"
expect_file_lacks "plan: ... with no credentials" "$WORK/script.args" "/AccessToken"
expect "plan: no token was fetched" "" "$(cat "$STUB_LOG/az.log")"
expect "plan: the target dacpac is in the plan" "yes" "$([ -f "$PLAN/deploy/target.dacpac" ] && echo yes)"
expect_file_lacks "plan: the offline profile has no connection string" "$PLAN/deploy/profile.publish.xml" "TargetConnectionString"
expect_file_has "plan: ... but keeps its namespace" "$PLAN/deploy/profile.publish.xml" "$PROFILE_XMLNS"
expect_file_has "plan: the summary says it isn't a database" "$PLAN/summary.md" "Planned against \`ci/baseline.dacpac\`, not a database"
expect_refused "plan: a missing target-dacpac" "target-dacpac ci/none.dacpac doesn't exist" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" TARGET_DACPAC=ci/none.dacpac

# --- Secrets ------------------------------------------------------------------------------------------

plan STUB_ECHO_SECRET=1
expect "secrets: the plan succeeds" "0" "$status"
expect_not_log "secrets: the token isn't in the log" "FAKE.TOKEN.VALUE"
expect "secrets: the token isn't on any command line" "0" "$(grep -c 'FAKE.TOKEN.VALUE' "$STUB_LOG/argv.log" || true)"
expect "secrets: the token isn't in the plan" "0" "$(grep -rl 'FAKE.TOKEN.VALUE' "$PLAN" | wc -l | tr -d ' ')"
expect "secrets: the token is in the response file" "1" "$(grep -c '^"/AccessToken:FAKE.TOKEN.VALUE"$' "$STUB_LOG/calls/1.rsp")"
expect "secrets: SqlPackage's echo of it was scrubbed" "0" "$(grep -c 'Unrecognized command line argument .FAKE' "$WORK/log" || true)"
expect "secrets: ... leaving a mark" "true" "$(grep -q "Unrecognized command line argument '\*\*\*'" "$WORK/log" && echo true)"
expect "secrets: a token for every call" "3" "$(grep -c 'get-access-token' "$STUB_LOG/az.log")"
expect "secrets: the token request names Azure SQL" "1" "$(grep -c 'https://database.windows.net/' <<< "$(head -1 "$STUB_LOG/az.log")")"
badlines=0
for rsp in "$STUB_LOG"/calls/*.rsp; do
  badlines=$((badlines + $(grep -vc '^".*"$' "$rsp" || true)))
done
expect "secrets: every response-file line is quoted" "0" "$badlines"
expect "secrets: the response file is mode 600" "600" "$(sort -u "$STUB_LOG"/calls/*.mode | tr '\n' ' ' | sed 's/ $//')"
expect "secrets: the response files are deleted" "0" "$(find "$WORK/runner" -name 'sqlpackage.*' | wc -l | tr -d ' ')"
expect "secrets: the first line is the action, quoted" '"/Action:DeployReport"' "$(head -1 "$STUB_LOG/calls/1.rsp")"
plan STUB_FAIL=Script STUB_ECHO_SECRET=1
expect "secrets: a failing run leaves no response file either" "0" "$(find "$WORK/runner" -name 'sqlpackage.*' | wc -l | tr -d ' ')"
expect "secrets: ... nor the token in its summary" "0" "$(grep -c 'FAKE.TOKEN.VALUE' "$PLAN/summary.md" || true)"
# SQL authentication, for local runs against a container
plan SQL_AUTH=sql SQL_USER=sa SQL_PASSWORD=Sup3rSecret STUB_ECHO_SECRET=1
expect "secrets: SQL authentication succeeds" "0" "$status"
expect "secrets: the password is in the response file" "1" "$(grep -c '^"/TargetPassword:Sup3rSecret"$' "$STUB_LOG/calls/1.rsp")"
expect "secrets: ... and the user" "1" "$(grep -c '^"/TargetUser:sa"$' "$STUB_LOG/calls/1.rsp")"
expect_not_log "secrets: the password isn't in the log" "Sup3rSecret"
expect "secrets: the password isn't on a command line" "0" "$(grep -c 'Sup3rSecret' "$STUB_LOG/argv.log" || true)"
expect "secrets: the password isn't in the plan" "0" "$(grep -rl 'Sup3rSecret' "$PLAN" | wc -l | tr -d ' ')"
expect "secrets: no token is fetched" "" "$(cat "$STUB_LOG/az.log")"
expect_refused "secrets: SQL authentication needs a password" "set SQL_USER and SQL_PASSWORD" plan.sh WORKING_DIR=proj DACPAC_DIR="$WORK/dacpac-scripts" PROFILE=deployments/dev.publish.xml PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" SQL_AUTH=sql

# --- apply.sh ---------------------------------------------------------------------------------------------

# Usage: apply [VAR=value ...]   (the plan in $PLAN)
apply() {
  reset_stub_log
  run apply.sh WORKING_DIR=proj PLAN_DIR="$PLAN" PLAN_SHA256="$SHA" WORK_DIR="$WORK/apply-work" "$@"
}
plan
SHA="$(output plan-sha256)"
cp -R "$PLAN" "$WORK/plan-good"
plan_rsp="$STUB_LOG/calls/1.rsp"
sed 's/^"//; s/"$//' "$plan_rsp" | grep -v '^/Action:\|^/OutputPath:\|^/AccessToken:' > "$WORK/plan.args"

apply
expect "apply: succeeds" "0" "$status"
expect "apply: a live report, then a publish" "DeployReport Publish" "$(tr '\n' ' ' < "$STUB_LOG/actions.log" | sed 's/ $//')"
sed 's/^"//; s/"$//' "$STUB_LOG/calls/2.rsp" | grep -v '^/Action:\|^/OutputPath:\|^/AccessToken:' > "$WORK/publish.args"
expect "apply: publishes with the plan's arguments" "" "$(diff "$WORK/plan.args" "$WORK/publish.args" || true)"
expect_file_has "apply: ... from the plan's own profile" "$WORK/publish.args" "/Profile:${PLAN}/deploy/profile.publish.xml"
expect "apply: a fresh token for each call" "2" "$(grep -c 'get-access-token' "$STUB_LOG/az.log")"
expect "apply: the response files are deleted" "0" "$(find "$WORK/runner" -name 'sqlpackage.*' | wc -l | tr -d ' ')"

apply STUB_REPORT=changes-reordered
expect "apply: the same report in another order is still the plan" "0" "$status"
apply STUB_REPORT=one
expect "apply: the database changed since the plan: refused" "1" "$status"
expect_log "apply: ... and says to plan again" "sqldb-dev changed since this plan"
expect "apply: ... without publishing" "0" "$(calls_of Publish)"
expect_log "apply: ... listing what was planned" "Planned:"
apply STUB_PUBLISH_EXIT=1
expect "apply: a failing publish fails" "1" "$status"
expect_log "apply: ... and says what may be live" "some changes may be live"
apply STUB_FAIL=DeployReport
expect "apply: an unreachable database fails before publishing" "1" "$status"
expect "apply: ... without publishing" "0" "$(calls_of Publish)"

echo tampered >> "$PLAN/deploy/target.json"
apply
expect "apply: a changed plan is refused" "1" "$status"
expect_log "apply: ... with the digest" "Refusing to publish a plan that isn't the one that was reviewed"
rm -rf "${PLAN:?}"
cp -R "$WORK/plan-good" "$PLAN"
reset_stub_log
expect_refused "apply: a missing plan" "Plan artifacts expire" apply.sh WORKING_DIR=proj PLAN_DIR="$WORK/nowhere" PLAN_SHA256="$SHA" WORK_DIR="$WORK/apply-work"
plan TARGET_DACPAC=ci/baseline.dacpac
apply PLAN_SHA256="$(output plan-sha256)"
expect "apply: an offline plan is refused" "1" "$status"
expect_log "apply: ... with the reason" "was made against a dacpac"
plan STUB_REPORT=dataloss ALLOW_DATA_LOSS=true
apply PLAN_SHA256="$(output plan-sha256)" STUB_REPORT=dataloss
expect "apply: a plan with allowed data loss applies" "0" "$status"
jq '.allow_data_loss = false' "$PLAN/deploy/target.json" > "$WORK/target.json"
cp "$WORK/target.json" "$PLAN/deploy/target.json"
apply PLAN_SHA256= STUB_REPORT=dataloss
expect "apply: data loss that isn't allowed is refused" "1" "$status"
expect_log "apply: ... with the reason" "has possible data loss, and allow-data-loss is off"
jq '.service = "datafactory"' "$PLAN/deploy/target.json" > "$WORK/target.json"
cp "$WORK/target.json" "$PLAN/deploy/target.json"
apply PLAN_SHA256=
expect_log "apply: another service's plan is refused" "isn't a SQL project plan"
plan
expect_refused "apply: the tools must be pinned" "azure-cli isn't pinned" apply.sh WORKING_DIR=proj PLAN_DIR="$PLAN" PLAN_SHA256="$(output plan-sha256)" WORK_DIR="$WORK/apply-work" MISE_PINNED="dotnet dotnet:microsoft.sqlpackage yq"

# --- shared/pr-comment: blocked-reason ----------------------------------------------------------------

comment() {
  rm -f "$STUB_LOG/gh-body.json"
  run "../../shared/scripts/pr-comment.sh" GH_TOKEN=x GITHUB_REPOSITORY=org/repo PR_NUMBER=7 HEAD_SHA=abc1234def COMMENT_KEY=k APPLY_STATUS=blocked SUMMARY_FILE="$PLAN/summary.md" "$@"
  jq -r .body "$STUB_LOG/gh-body.json"
}
body="$(comment BLOCKED_REASON='Possible data loss (see the plan), so it cannot be applied.')"
expect "pr-comment: a blocked reason is shown" "1" "$(grep -c 'Possible data loss (see the plan), so it cannot be applied.' <<< "$body")"
expect "pr-comment: ... instead of the policy text" "0" "$(grep -c 'The policy check failed' <<< "$body" || true)"
body="$(comment)"
expect "pr-comment: without one, OpenTofu's text stays" "1" "$(grep -c 'The policy check failed' <<< "$body")"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} test(s) failed"
  exit 1
fi
log_success "All ${cases} SQL project script tests passed"
