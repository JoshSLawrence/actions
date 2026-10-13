#!/usr/bin/env bash
#
# Tests the scripts Data Factory and Synapse share offline, with stubs for
# the tools that need Azure (mise, az, pwsh): the infrastructure boundary
# (what the deployed template leaves out, and that nothing is left depending
# on it), the names of the template artifact, the stale-plan paths (a
# sibling deployment's parameters file doesn't count), the apply-environment
# rule, the live fingerprint, and the plan and apply scripts of both
# services: deletion lists, the pool check, the live re-check, and the
# integration runtimes the Data Factory post-deployment script is told to
# keep, the comparison with the live definitions (the deployer's expressions,
# the normalization, secure values) and the Data Factory what-if's secure
# deltas. The deployer, the pre/post-deployment script and what-if need Azure
# and are not covered. Run by pre-commit and CI. Needs jq.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANNED="$REPO_ROOT/tests/arm/fixtures"
# shellcheck source=shared/scripts/common.sh
source "$REPO_ROOT/shared/scripts/common.sh"
# shellcheck source=arm/scripts/arm.sh
source "$REPO_ROOT/arm/scripts/arm.sh"

# The scripts behave differently under GitHub Actions (they mask secrets with
# workflow commands and require PLAN_SHA256), so run as a plain shell even
# when this test itself runs in a job
unset GITHUB_ACTIONS

require_tool jq

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
failures=0
cases=0

# --- Stubs -----------------------------------------------------------------------------
#
# First on PATH, so the scripts' `mise exec -- <tool>` runs them.

STUBS="$WORK/stubs"
STUB_LOG="$WORK/stub-log"
STUB_LIVE="$WORK/live"
mkdir -p "$STUBS" "$STUB_LOG" "$STUB_LIVE"
export STUBS STUB_LOG STUB_LIVE

cat > "$STUBS/mise" << 'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  exec)
    shift
    [ "${1:-}" = "--" ] && shift
    tool="$1"
    shift
    exec "$STUBS/$tool" "$@"
    ;;
  current)
    case " ${MISE_PINNED:-azure-cli powershell} " in
      *" $2 "*) echo "1.0.0" ;;
    esac
    ;;
esac
exit 0
STUB

# Logs its arguments. `az rest` answers from $STUB_LIVE/<last path segment
# of the URL>.json (an empty list without one; <name>.2.json for a second
# page, <name>.404 to answer ResourceNotFound, <name>.400 to answer a
# workspace without a managed virtual network), so a test sets what a factory
# or workspace holds by writing those files. `az deployment group what-if`
# prints $STUB_LIVE/what-if.json when it exists.
cat > "$STUBS/az" << 'STUB'
#!/usr/bin/env bash
echo "az $*" >> "$STUB_LOG/az.log"
case "$1 $2" in
  "account show")
    case "$*" in
      *tenantId*) echo "tenant-1" ;;
      *user.name*) echo "client-1" ;;
      *) echo "sub-1" ;;
    esac
    ;;
  "account get-access-token") echo "TOKEN" ;;
  "deployment group")
    if [ "$3" = "what-if" ]; then
      if [ -f "$STUB_LIVE/what-if.json" ]; then cat "$STUB_LIVE/what-if.json"; else echo '{"changes": []}'; fi
    fi
    ;;
  "synapse trigger") echo "[]" ;;
  rest*)
    url=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--url" ] && url="$2"
      shift
    done
    path="${url%%\?*}"
    name="${path##*/}"
    file="$STUB_LIVE/${name}.json"
    # The second page of a list: nextLink ...page=2, or continuationToken
    case "$url" in
      *page=2* | *continuationToken=*) file="$STUB_LIVE/${name}.2.json" ;;
      *page=3*)
        echo "ERROR: (ResourceNotFound) the page is gone" >&2
        exit 1
        ;;
    esac
    if [ -f "$STUB_LIVE/${name}.400" ] && [ "$file" = "$STUB_LIVE/${name}.json" ]; then
      echo "ERROR: (ManagedVnetNotFound) The workspace Does Not Have a managed virtual network associated with it." >&2
      exit 1
    fi
    if [ -f "$STUB_LIVE/${name}.404" ] && [ "$file" = "$STUB_LIVE/${name}.json" ]; then
      echo "ERROR: (ResourceNotFound) not found" >&2
      exit 1
    fi
    if [ -f "$file" ]; then cat "$file"; else echo '{"value": []}'; fi
    ;;
esac
STUB

# Keeps the template the pre/post-deployment script is given
cat > "$STUBS/pwsh" << 'STUB'
#!/usr/bin/env bash
phase="" dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -Phase) phase="$2" ;;
    -TemplateDir) dir="$2" ;;
  esac
  shift
done
echo "pwsh $phase" >> "$STUB_LOG/pwsh.log"
/bin/cp "$dir/ARMTemplateForFactory.json" "$STUB_LOG/pwsh-template-$phase.json"
STUB
# cp, for a test to make the copy of a template fail (STUB_CP=fail) or do
# nothing (STUB_CP=skip)
cat > "$STUBS/cp" << 'STUB'
#!/usr/bin/env bash
case "${STUB_CP:-}" in
  fail) exit 1 ;;
  skip) exit 0 ;;
esac
exec /bin/cp "$@"
STUB
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# --- Harness -----------------------------------------------------------------------------

# Run a script from the repository with extra env (VAR=value arguments), from
# the current directory. The exit code is in $status, the log in $WORK/log and
# the step outputs in $WORK/output.
# Usage: run <script, relative to the repository> [VAR=value ...]
run() {
  local script="$1"
  shift
  : > "$WORK/output"
  set +e
  env GITHUB_OUTPUT="$WORK/output" RUNNER_TEMP="$WORK/runner" "$@" "$REPO_ROOT/$script" > "$WORK/log" 2>&1
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

# A resource list as the stubbed `az rest` returns it
# Usage: live_list <collection> [<name>:<etag> ...]
live_list() {
  local collection="$1" item
  shift
  {
    for item in "$@"; do
      jq -nc --arg name "${item%%:*}" --arg etag "${item#*:}" '{name: $name, etag: $etag}'
    done
  } | jq -sc '{value: .}' > "$STUB_LIVE/${collection}.json"
}

# A list in two pages: the first links to the second (nextLink)
# Usage: live_pages <collection> <first item> <second item>, items name:etag
live_pages() {
  live_list "$1" "$2"
  jq --arg next "https://management.azure.com/x/$1?api-version=1&page=2" '. + {nextLink: $next}' "$STUB_LIVE/${1}.json" > "$WORK/page.json"
  mv "$WORK/page.json" "$STUB_LIVE/${1}.json"
  live_list "${1}.2" "$3"
}

reset_live() {
  rm -f "$STUB_LIVE"/*.json "$STUB_LIVE"/*.404 "$STUB_LIVE"/*.400 "$STUB_LOG"/*
}

# The resources of a template that have a type, as "type" lines (lower case)
# Usage: template_types <template>
template_types() {
  jq -r '.resources[].type | ascii_downcase' "$1" | sort
}

# --- Infrastructure kinds ------------------------------------------------------------------

# Usage: strip <service> <template> <mpes> <irs>: writes $WORK/stripped.json
# and $WORK/left.jsonl
strip() {
  (
    export DEPLOY_MANAGED_PRIVATE_ENDPOINTS="$3" DEPLOY_INTEGRATION_RUNTIMES="$4"
    arm_infrastructure_types "$1" > "$WORK/types.jsonl"
    arm_strip_resources "$2" "$WORK/types.jsonl" "$WORK/stripped.json" "$WORK/left.jsonl"
  ) > "$WORK/log" 2>&1
}

# Whether a dependsOn anywhere in a template names something
# Usage: depends_on_count <template> <text>
depends_on_count() {
  jq --arg t "$2" '[.resources[].dependsOn[]? | select(ascii_downcase | contains($t | ascii_downcase))] | length' "$1"
}

ADF="$CANNED/adf-template.json"
SYN="$CANNED/synapse-template.json"

strip datafactory "$ADF" false false
expect "adf strip: only logic is left by default" "linkedservices
pipelines
triggers" "$(template_types "$WORK/stripped.json" | sed 's|microsoft.datafactory/factories/||')"
expect "adf strip: no dependency on the integration runtimes is left" "0" "$(depends_on_count "$WORK/stripped.json" integrationRuntimes)"
expect "adf strip: ... nor on the endpoints" "0" "$(depends_on_count "$WORK/stripped.json" managedPrivateEndpoints)"
expect "adf strip: the other dependencies stay" "1" "$(depends_on_count "$WORK/stripped.json" 'pipelines/pl_wait')"
expect "adf strip: the types compare without regard to case (ir_custom is integrationruntimes)" "1" "$(jq -s '[.[] | select(.name == "ir_custom")] | length' "$WORK/left.jsonl")"
expect "adf strip: AutoResolveIntegrationRuntime is a default" "true" "$(jq -s '.[] | select(.name == "AutoResolveIntegrationRuntime") | .default' "$WORK/left.jsonl")"
expect "adf strip: a custom runtime isn't" "false" "$(jq -s '.[] | select(.name == "ir_custom") | .default' "$WORK/left.jsonl")"
expect "adf strip: the default managed virtual network is a default" "true" "$(jq -s '.[] | select(.type == "managedVirtualNetworks") | .default' "$WORK/left.jsonl")"
expect "adf strip: an endpoint isn't, and is named by its place" "managedVirtualNetworks/default/managedPrivateEndpoints/mpe_bronze" "$(jq -rs '.[] | select(.default | not) | select(.type | test("Endpoints")) | .path' "$WORK/left.jsonl")"
expect "adf strip: the factory itself is left out, as a default" "true" "$(jq -s '.[] | select(.path == "factory") | .default' "$WORK/left.jsonl")"

strip datafactory "$ADF" true false
expect "adf strip: deploying endpoints keeps them" "1" "$(template_types "$WORK/stripped.json" | grep -c managedprivateendpoints)"
expect "adf strip: ... without the dependency on the virtual network, which isn't deployed" "0" "$(depends_on_count "$WORK/stripped.json" "/managedVirtualNetworks/default'")"
expect "adf strip: ... but with what depends on an endpoint" "1" "$(depends_on_count "$WORK/stripped.json" managedPrivateEndpoints/mpe_bronze)"
expect "adf strip: ... and the runtimes are still left out" "0" "$(template_types "$WORK/stripped.json" | grep -c integrationruntimes || true)"

strip datafactory "$ADF" false true
expect "adf strip: deploying runtimes keeps both" "2" "$(template_types "$WORK/stripped.json" | grep -c integrationruntimes)"
expect "adf strip: ... and their dependencies, in the concat and resourceId forms" "3" "$(depends_on_count "$WORK/stripped.json" integrationRuntimes)"
expect "adf strip: ... and the endpoints are left out" "0" "$(template_types "$WORK/stripped.json" | grep -c managedprivateendpoints || true)"

strip datafactory "$ADF" true true
expect "adf strip: with both deployed, only the factory and the virtual network go" "2" "$(jq -s length "$WORK/left.jsonl")"

strip synapse "$SYN" false false
expect "synapse strip: only logic is left by default" "linkedservices
notebooks
pipelines
sparkjobdefinitions" "$(template_types "$WORK/stripped.json" | sed 's|microsoft.synapse/workspaces/||')"
expect "synapse strip: no dependency on a pool or a runtime is left" "0" "$(($(depends_on_count "$WORK/stripped.json" bigDataPools) + $(depends_on_count "$WORK/stripped.json" sqlPools) + $(depends_on_count "$WORK/stripped.json" integrationRuntimes)))"
expect "synapse strip: the service's own endpoint is a default" "true" "$(jq -s '.[] | select(.name == "synapse-ws-sql--syn-dev") | .default' "$WORK/left.jsonl")"
expect "synapse strip: another endpoint isn't" "false" "$(jq -s '.[] | select(.name == "mpe_bronze") | .default' "$WORK/left.jsonl")"
expect "synapse strip: pool stubs are defaults" "true" "$(jq -s 'map(select(.kind | test("pools"))) | all(.default)' "$WORK/left.jsonl")"

strip synapse "$SYN" true true
expect "synapse strip: deploying endpoints and runtimes keeps them" "3" "$(template_types "$WORK/stripped.json" | grep -c 'managedprivateendpoints\|integrationruntimes')"
expect "synapse strip: pools and the virtual network are left out whatever the inputs" "managedVirtualNetworks
bigDataPools
bigDataPools
sqlPools" "$(jq -r '.type' "$WORK/left.jsonl")"

# The warnings name each resource that isn't a service default
strip synapse "$SYN" false false
arm_left_to_iac_warn "$WORK/left.jsonl" > "$WORK/log" 2>&1
expect_log "warn: a file you wrote is named" "managedVirtualNetworks/default/managedPrivateEndpoints/mpe_bronze is in the folder, but this workflow leaves managed private endpoints to infrastructure as code (deploy-managed-private-endpoints is false)"
cases=$((cases + 1))
if grep -q "synapse-ws-sql\|bigDataPools" "$WORK/log"; then
  log_error "warn: defaults must be silent"
  failures=$((failures + 1))
else
  log_success "warn: defaults are silent"
fi
arm_left_to_iac_markdown "$WORK/left.jsonl" > "$WORK/summary.md"
expect_file_has "markdown: the section lists the left-out resources" "$WORK/summary.md" "Left to infrastructure as code (7)"
expect_file_has "markdown: ... and warns about files" "$WORK/summary.md" "> - \`managedVirtualNetworks/default/managedPrivateEndpoints/mpe_bronze\`"
: > "$WORK/empty.jsonl"
expect "markdown: nothing for an empty list" "" "$(arm_left_to_iac_markdown "$WORK/empty.jsonl")"

# --- Names ----------------------------------------------------------------------------------

names() {
  run arm/scripts/arm-names.sh SERVICE=datafactory WORKING_DIRECTORY=adf STACK_NAME=core "$@"
}
names DEPLOYMENTS='deployments/*.json'
first="$(output template-artifact-name)"
names DEPLOYMENTS='deployments/*.json'
expect "names: the template artifact is stable for a call" "$first" "$(output template-artifact-name)"
names DEPLOYMENTS='deployments/dev.json'
expect "names: ... and differs with the deployments" "1" "$([ "$(output template-artifact-name)" != "$first" ] && echo 1 || echo 0)"
names DEPLOYMENTS='deployments/*.json' PARAMETER_FILES=common.json
expect "names: ... and with the parameter files" "1" "$([ "$(output template-artifact-name)" != "$first" ] && echo 1 || echo 0)"
run arm/scripts/arm-names.sh SERVICE=synapse WORKING_DIRECTORY=adf STACK_NAME=core DEPLOYMENTS='deployments/*.json'
expect "names: ... and with the service" "1" "$([ "$(output template-artifact-name)" != "$first" ] && echo 1 || echo 0)"
names DEPLOYMENTS='deployments/*.json' DEPLOYMENT=dev APPLY_ENVIRONMENT=core-dev
expect "names: the plan artifact doesn't depend on the call's inputs" "$(output artifact-name)" "$(
  names DEPLOYMENTS=other DEPLOYMENT=dev APPLY_ENVIRONMENT=core-dev
  output artifact-name
)"
names STACK_NAME="$(printf 'x%.0s' {1..300})"
expect "names: a long stack name stays within the artifact limit" "1" "$([ "$(output template-artifact-name | wc -c)" -lt 140 ] && echo 1 || echo 0)"

# --- Deployments and the stale-plan paths --------------------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO/adf/deployments" "$REPO/adf/ci" "$REPO/adf/pipeline"
cd "$REPO"
for f in dev prod stg; do
  echo '{"parameters": {}}' > "adf/deployments/$f.json"
done
echo '{"parameters": {}}' > adf/common.json
echo '{"parameters": {}}' > adf/deployments/shared.json
echo '{"parameters": {}}' > adf/ci/dev.json
echo '{}' > adf/arm-template-parameters-definition.json
echo '{}' > adf/pipeline/pl.json

deployment_paths() {
  jq -r --arg name "$1" 'select(.name == $name) | .preflight_paths' "$WORK/matrix.jsonl"
}
deployments() {
  run arm/scripts/arm-deployments.sh WORKING_DIR=adf RESOURCE_GROUP='rg-{deployment}' APPLY_ENVIRONMENT='core-{deployment}' "$@"
  jq -c '.deployment[]' <<< "$(output matrix)" > "$WORK/matrix.jsonl" 2> /dev/null || true
}
deployments DEPLOYMENTS='deployments/dev.json deployments/prod.json' PARAMETER_FILES=common.json
expect "deployments: resolved" "0" "$status"
expect "deployments: a deployment's list ends with its own file" "adf/deployments/dev.json" "$(deployment_paths dev | tail -1)"
expect "deployments: ... after the call's paths and the other files of its folder" "adf
!adf/deployments/prod.json
!adf/deployments/shared.json
!adf/deployments/stg.json
adf/common.json
adf/deployments/dev.json" "$(deployment_paths dev)"

# What the stale-plan check would watch, read the way apply-preflight.sh does
# Usage: watched <deployment> <path>
watched() {
  local -a rules=()
  local entry
  while IFS= read -r entry; do
    rules+=("$(path_entry_rule "$entry")")
  done < <(deployment_paths "$1")
  if path_rules_match "$2" "${rules[@]}"; then echo watched; else echo ignored; fi
}
expect "preflight: another deployment's parameters file doesn't make dev's plan stale" "ignored" "$(watched dev adf/deployments/prod.json)"
expect "preflight: dev's own file does" "watched" "$(watched dev adf/deployments/dev.json)"
expect "preflight: ... and an artifact" "watched" "$(watched dev adf/pipeline/pl.json)"
expect "preflight: ... and a shared parameters file" "watched" "$(watched dev adf/common.json)"
expect "preflight: ... and the exporter's definition at the root" "watched" "$(watched dev adf/arm-template-parameters-definition.json)"
expect "preflight: ... and a file elsewhere with the same name" "watched" "$(watched dev adf/ci/dev.json)"

deployments DEPLOYMENTS='deployments/dev.json' PARAMETER_FILES='deployments/shared.json'
expect "preflight: a shared parameters file beside the deployments is never excluded" "watched" "$(watched dev adf/deployments/shared.json)"
expect "preflight: ... though its other siblings are" "ignored" "$(watched dev adf/deployments/stg.json)"

cp adf/deployments/dev.json adf/dev-root.json
deployments DEPLOYMENTS='dev-root.json'
expect "preflight: a deployment file at the folder root excludes nothing" "adf
adf/dev-root.json" "$(deployment_paths dev-root)"

deployments RESOURCE_GROUP=rg APPLY_ENVIRONMENT=core
expect "preflight: the template on its own excludes nothing" "adf" "$(jq -r '.preflight_paths' <<< "$(output matrix | jq -c '.deployment[0]')")"

deployments DEPLOYMENTS='deployments/*.json' PREFLIGHT_PATHS="adf shared"
expect "preflight: the caller's paths come first" "adf
shared" "$(deployment_paths dev | head -2)"

expect_refused "apply: an apply without an environment is refused" "apply is true, but apply-environment is empty" arm/scripts/arm-deployments.sh WORKING_DIR=adf RESOURCE_GROUP=rg DEPLOYMENTS='deployments/*.json'
expect_refused "apply: ... also when apply is explicitly true" "apply is true, but apply-environment is empty" arm/scripts/arm-deployments.sh WORKING_DIR=adf RESOURCE_GROUP=rg DEPLOYMENTS='deployments/*.json' APPLY=true
run arm/scripts/arm-deployments.sh WORKING_DIR=adf RESOURCE_GROUP=rg DEPLOYMENTS='deployments/*.json' APPLY=false
expect "apply: plan only needs no environment" "0" "$status"

# --- The live fingerprint ------------------------------------------------------------------------

printf '%s\n' '{"type":"pipelines","name":"a","etag":"1"}' '{"type":"pipelines","name":"b","etag":"2"}' > "$WORK/l1.jsonl"
printf '%s\n' '{"type":"pipelines","name":"b","etag":"2"}' '{"type":"pipelines","name":"a","etag":"1"}' > "$WORK/l2.jsonl"
printf '%s\n' '{"etag":"1","name":"a","type":"pipelines"}' '{"type":"pipelines","name":"b","etag":"3"}' > "$WORK/l3.jsonl"
expect "fingerprint: the same for reordered listings" "$(arm_live_fingerprint "$WORK/l1.jsonl")" "$(arm_live_fingerprint "$WORK/l2.jsonl")"
expect "fingerprint: different when an etag changes" "1" "$([ "$(arm_live_fingerprint "$WORK/l1.jsonl")" != "$(arm_live_fingerprint "$WORK/l3.jsonl")" ] && echo 1 || echo 0)"
printf '%s\n' '{"type":"linkedServices","name":"ws-WorkspaceDefaultStorage","etag":"1"}' '{"type":"pipelines","name":"a","etag":"1"}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"linkedServices","name":"ws-WorkspaceDefaultStorage","etag":"9"}' '{"type":"pipelines","name":"a","etag":"1"}' > "$WORK/s2.jsonl"
expect "fingerprint: Synapse's default artifacts don't count" "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" "$(arm_synapse_fingerprint "$WORK/s2.jsonl")"

# --- Plans and applies ---------------------------------------------------------------------------

# A folder the scripts can cd into, holding the deployments' parameters
mkdir -p "$REPO/factory/deployments" "$REPO/workspace/deployments"
echo '[tools]' > "$REPO/factory/mise.toml"
echo '[tools]' > "$REPO/workspace/mise.toml"
echo '{"parameters": {"factoryName": {"value": "adf-test"}}}' > "$REPO/factory/deployments/dev.json"
echo '{"parameters": {"workspaceName": {"value": "syn-test"}}}' > "$REPO/workspace/deployments/dev.json"

FACTORY_TEMPLATE="$WORK/factory-template"
mkdir -p "$FACTORY_TEMPLATE/linkedTemplates"
cp "$ADF" "$FACTORY_TEMPLATE/ARMTemplateForFactory.json"
echo '{}' > "$FACTORY_TEMPLATE/linkedTemplates/ArmTemplate_0.json"
echo '# script' > "$FACTORY_TEMPLATE/PrePostDeploymentScript.ps1"
jq '{parameters: (.parameters | map_values({value: .defaultValue}))}' "$ADF" > "$FACTORY_TEMPLATE/ARMTemplateParametersForFactory.json"

WORKSPACE_TEMPLATE="$WORK/workspace-template"
mkdir -p "$WORKSPACE_TEMPLATE"
cp "$SYN" "$WORKSPACE_TEMPLATE/TemplateForWorkspace.json"
jq '{parameters: (.parameters | map_values({value: .defaultValue}))}' "$SYN" > "$WORKSPACE_TEMPLATE/TemplateParametersForWorkspace.json"

# Usage: factory_plan [VAR=value ...]  (the plan is in $PLAN)
PLAN="$WORK/plan"
factory_plan() {
  rm -rf "$PLAN"
  run datafactory/scripts/plan.sh WORKING_DIR=factory TEMPLATE_DIR="$FACTORY_TEMPLATE" PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" \
    PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev DEPLOYMENT=dev "$@"
}
workspace_plan() {
  rm -rf "$PLAN"
  run synapse/scripts/plan.sh WORKING_DIR=workspace TEMPLATE_DIR="$WORKSPACE_TEMPLATE" PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" \
    PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev DEPLOYMENT=dev "$@"
}

reset_live
live_list pipelines pl_wait:e1 pl_old:e2
live_list triggers trg_daily:e3
live_list linkedservices ls_storage:e4
live_list integrationRuntimes AutoResolveIntegrationRuntime:e5 ir_live:e6
live_list managedPrivateEndpoints mpe_live:e7

factory_plan WHAT_IF=true
expect "adf plan: succeeds" "0" "$status"
expect "adf plan: the deployed template has only logic" "linkedservices
pipelines
triggers" "$(template_types "$PLAN/deploy/template/ARMTemplateForFactory.json" | sed 's|microsoft.datafactory/factories/||')"
expect "adf plan: ... and the export's linked templates aren't shipped" "0" "$(find "$PLAN/deploy/template" -name 'ArmTemplate_*' | wc -l | tr -d ' ')"
expect_file_has "adf plan: only the resource missing from the folder is deleted" "$PLAN/summary.md" "> - \`pipelines/pl_old\`"
expect_file_lacks "adf plan: integration runtimes aren't deleted when they belong to infrastructure as code" "$PLAN/summary.md" "ir_live"
expect_file_lacks "adf plan: ... nor the default one" "$PLAN/summary.md" "> - \`integrationRuntimes/AutoResolve"
expect_file_lacks "adf plan: endpoints are never deleted" "$PLAN/summary.md" "mpe_live"
expect_file_has "adf plan: the summary says what was left out" "$PLAN/summary.md" "Left to infrastructure as code"
expect "adf plan: the target records the boundary" "false false" "$(jq -r '"\(.deploy_managed_private_endpoints) \(.deploy_integration_runtimes)"' "$PLAN/deploy/target.json")"
expect "adf plan: the kinds in the fingerprint are the logic" "triggers pipelines dataflows datasets linkedservices" "$(jq -r '.kinds | join(" ")' "$PLAN/deploy/live.json")"
expect "adf plan: the digest covers the plan" "$(arm_plan_sha256 "$PLAN")" "$(output plan-sha256)"
first_plan="$(output plan-sha256)"

factory_plan WHAT_IF=true DEPLOY_INTEGRATION_RUNTIMES=true
expect_file_has "adf plan: with runtimes deployed, one missing from the folder is deleted" "$PLAN/summary.md" "> - \`integrationRuntimes/ir_live\`"
expect "adf plan: ... and runtimes are in the fingerprint" "triggers pipelines dataflows datasets linkedservices integrationRuntimes" "$(jq -r '.kinds | join(" ")' "$PLAN/deploy/live.json")"
expect "adf plan: ... and in the template" "2" "$(template_types "$PLAN/deploy/template/ARMTemplateForFactory.json" | grep -c integrationruntimes)"

factory_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect "adf plan: with endpoints deployed, they're in the fingerprint" "triggers pipelines dataflows datasets linkedservices managedVirtualNetworks/default/managedPrivateEndpoints" "$(jq -r '.kinds | join(" ")' "$PLAN/deploy/live.json")"
expect_file_lacks "adf plan: ... but never deleted" "$PLAN/summary.md" "mpe_live"

factory_plan WHAT_IF=true
expect "adf plan: the same live state makes the same plan" "$first_plan" "$(output plan-sha256)"
live_list pipelines pl_wait:e1b pl_old:e2
factory_plan WHAT_IF=true
expect "adf plan: a changed etag makes another plan" "1" "$([ "$(output plan-sha256)" != "$first_plan" ] && echo 1 || echo 0)"
live_list pipelines pl_wait:e1 pl_old:e2

factory_plan
expect "adf plan: without what-if there's no live state" "0" "$([ -f "$PLAN/deploy/live.json" ] && echo 1 || echo 0)"
expect_log "adf plan: ... a file left to infrastructure as code is warned about" "integrationRuntimes/ir_custom is in the folder, but this workflow leaves integration runtimes to infrastructure as code (deploy-integration-runtimes is false)"

# The apply: stubs for az and pwsh
factory_apply() {
  : > "$STUB_LOG/pwsh.log"
  : > "$STUB_LOG/az.log"
  run datafactory/scripts/apply.sh WORKING_DIR=factory PLAN_DIR="$PLAN" "$@"
}
factory_plan WHAT_IF=true
factory_apply
expect "adf apply: deploys a plan whose factory is as planned" "0" "$status"
expect "adf apply: ... around the ARM deployment" "pwsh pre
pwsh post" "$(cat "$STUB_LOG/pwsh.log")"
# The generated script takes a name out as Substring(37, Length - 40): the
# 37 characters of "[concat(parameters('factoryName'), '/" and the 3 of "')]"
expect "adf apply: the script is told about the runtimes it must keep, in the form it parses" "AutoResolveIntegrationRuntime,ir_live" "$(jq -r '[.resources[] | select(.type == "Microsoft.DataFactory/factories/integrationRuntimes") | .name | .[37:length - 3]] | join(",")' "$STUB_LOG/pwsh-template-post.json")"
expect "adf apply: ... on top of the plan's resources" "3" "$(jq '[.resources[] | select(.type != "Microsoft.DataFactory/factories/integrationRuntimes")] | length' "$STUB_LOG/pwsh-template-post.json")"
expect "adf apply: the ARM deployment uses the plan's template, which has none" "0" "$(template_types "$PLAN/deploy/template/ARMTemplateForFactory.json" | grep -c integrationruntimes || true)"

factory_plan WHAT_IF=true DEPLOY_INTEGRATION_RUNTIMES=true
factory_apply DEPLOY_INTEGRATION_RUNTIMES=true
expect "adf apply: with runtimes deployed, the script gets the plan's template as it is" "$(jq -S . "$PLAN/deploy/template/ARMTemplateForFactory.json")" "$(jq -S . "$STUB_LOG/pwsh-template-post.json")"

factory_plan WHAT_IF=true
live_list pipelines pl_wait:e1 pl_old:e2 pl_new:e9
factory_apply
expect "adf apply: a resource added since the plan is refused" "1" "$status"
expect_log "adf apply: ... saying what to do" "Factory adf-test changed since this plan (another deployment, a change made in the portal, or an earlier attempt of this apply). Re-run all jobs of the workflow, not just the failed one (that would reuse this plan), to plan again, then approve that run."
expect "adf apply: ... before anything is changed" "0" "$(cat "$STUB_LOG/pwsh.log" "$STUB_LOG/az.log" | grep -c 'pwsh\|deployment group create' || true)"
live_list pipelines pl_wait:e1x pl_old:e2
factory_apply
expect "adf apply: so is an etag that changed" "1" "$status"
live_list pipelines pl_wait:e1 pl_old:e2

factory_plan WHAT_IF=true
factory_apply DEPLOY_INTEGRATION_RUNTIMES=true
expect "adf apply: an apply that disagrees with the plan about runtimes is refused" "1" "$status"
expect_log "adf apply: ... saying why" "The apply has deploy-integration-runtimes true, but the plan was made with false."

factory_plan
factory_apply
expect "adf apply: a plan without what-if is applied" "0" "$status"
expect_log "adf apply: ... with a warning that the live check is skipped" "so the check that the factory is unchanged since the plan is skipped"

# Synapse
live_list pipelines pl_wait:p1
live_list linkedServices syn-test-WorkspaceDefaultStorage:d1 ls_storage:l1
live_list notebooks nb_old:n1
live_list integrationRuntimes AutoResolveIntegrationRuntime:i1
rm -f "$STUB_LIVE/managedPrivateEndpoints.json"
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 mpe_live:m2
live_list bigDataPools spark:b1 spark_big:b2
live_list sqlPools dw:q1

workspace_plan WHAT_IF=true
expect "synapse plan: succeeds when every pool exists" "0" "$status"
expect "synapse plan: the deployed template has only logic" "linkedservices
notebooks
pipelines
sparkjobdefinitions" "$(template_types "$PLAN/deploy/template/TemplateForWorkspace.json" | sed 's|microsoft.synapse/workspaces/||')"
expect_file_has "synapse plan: an artifact missing from the folder is deleted" "$PLAN/summary.md" "> - \`notebooks/nb_old\`"
expect_file_lacks "synapse plan: endpoints aren't deleted when they belong to infrastructure as code" "$PLAN/summary.md" "mpe_live"
expect_file_lacks "synapse plan: runtimes never are" "$PLAN/summary.md" "> - \`integrationRuntimes"
expect "synapse plan: the target records the boundary" "false" "$(jq -r '.deploy_managed_private_endpoints' "$PLAN/deploy/target.json")"
expect "synapse plan: the kinds in the fingerprint leave out endpoints and runtimes" "0" "$(jq -r '.kinds[]' "$PLAN/deploy/live.json" | grep -c 'managedPrivateEndpoints\|integrationRuntimes' || true)"
expect "synapse plan: has-changes is true when the live definitions weren't listed (nothing is compared as unchanged)" "true" "$(output has-changes)"
synapse_first="$(output plan-sha256)"
live_list linkedServices syn-test-WorkspaceDefaultStorage:d2 ls_storage:l1
workspace_plan WHAT_IF=true
expect "synapse plan: a change to a default artifact doesn't change the plan" "$synapse_first" "$(output plan-sha256)"

workspace_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect_file_has "synapse plan: with endpoints deployed, one missing from the folder is deleted" "$PLAN/summary.md" "> - \`managedVirtualNetworks/managedPrivateEndpoints/mpe_live\`"
expect_file_lacks "synapse plan: ... never the service's own" "$PLAN/summary.md" "> - \`managedVirtualNetworks/managedPrivateEndpoints/synapse-ws-sql"
expect "synapse plan: ... and the endpoints are in the fingerprint" "1" "$(jq -r '.kinds[]' "$PLAN/deploy/live.json" | grep -c 'managedPrivateEndpoints')"

# The deployer's default rules: by type, and any synapse-ws-* endpoint
live_list pipelines pl_wait:p1 syn-test-WorkspaceDefaultStorage:p2
live_list managedPrivateEndpoints synapse-ws-custstgacct--syn-test-ab12cd:m1 SYNAPSE-WS-sql--syn-test:m3 mpe_live:m2
workspace_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect_file_has "synapse plan: a default's name is only a default for its type (a pipeline named like one is deleted)" "$PLAN/summary.md" "> - \`pipelines/syn-test-WorkspaceDefaultStorage\`"
expect_file_lacks "synapse plan: ... the linked service of that name never is" "$PLAN/summary.md" "> - \`linkedServices/syn-test-WorkspaceDefaultStorage\`"
expect_file_lacks "synapse plan: a primary storage endpoint (synapse-ws-custstgacct--...) is a default" "$PLAN/summary.md" "synapse-ws-custstgacct"
expect_file_lacks "synapse plan: ... whatever its case" "$PLAN/summary.md" "SYNAPSE-WS-sql"
expect_file_has "synapse plan: ... while another endpoint is deleted" "$PLAN/summary.md" "> - \`managedVirtualNetworks/managedPrivateEndpoints/mpe_live\`"
live_list pipelines pl_wait:p1
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 mpe_live:m2

# Each type has its own default pattern: these are ordinary artifacts, deleted
live_list linkedServices syn-test-WorkspaceDefaultStorage:d1 ls_storage:l1 synapse-ws-x:l2 WorkspaceSystemIdentity:l3
live_list credentials WorkspaceSystemIdentity:c1 x-WorkspaceDefaultStorage:c2
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 x-WorkspaceDefaultSqlServer:m2
workspace_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect_file_has "synapse plan: a linked service named synapse-ws-* is deleted (that pattern is for endpoints)" "$PLAN/summary.md" "> - \`linkedServices/synapse-ws-x\`"
expect_file_has "synapse plan: ... a linked service named WorkspaceSystemIdentity too" "$PLAN/summary.md" "> - \`linkedServices/WorkspaceSystemIdentity\`"
expect_file_has "synapse plan: ... a credential named like a default linked service too" "$PLAN/summary.md" "> - \`credentials/x-WorkspaceDefaultStorage\`"
expect_file_lacks "synapse plan: ... the real credential never" "$PLAN/summary.md" "> - \`credentials/WorkspaceSystemIdentity\`"
expect_file_has "synapse plan: ... an endpoint named like a default linked service too" "$PLAN/summary.md" "> - \`managedVirtualNetworks/managedPrivateEndpoints/x-WorkspaceDefaultSqlServer\`"
live_list linkedServices syn-test-WorkspaceDefaultStorage:d1 ls_storage:l1
rm -f "$STUB_LIVE/credentials.json"
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 mpe_live:m2

# Lake databases: only Spark, SyMS ones are the deployer's
rm -f "$STUB_LIVE/databases.json"
jq -n '{items: [
  {id: "1", type: "DATABASE", name: "lake_syms", properties: {Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: true}}},
  {id: "2", type: "DATABASE", name: "lake_lower", properties: {Origin: {Type: "spark"}, Properties: {IsSyMSCDMDatabase: true}}},
  {id: "3", type: "DATABASE", name: "lake_notsyms", properties: {Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: false}}},
  {id: "4", type: "DATABASE", name: "lake_string", properties: {Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: "true"}}},
  {id: "5", type: "DATABASE", name: "lake_noflag", properties: {Origin: {Type: "SPARK"}, Properties: {}}},
  {id: "6", type: "DATABASE", name: "lake_other", properties: {Origin: {Type: "SYNAPSE"}, Properties: {IsSyMSCDMDatabase: true}}},
  {Name: "lake_flat", Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: true}},
  {Name: "lake_flat_no", Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: "true"}}
]}' > "$STUB_LIVE/databases.json"
workspace_plan WHAT_IF=true
for lake in lake_syms lake_lower lake_flat; do
  expect_file_has "synapse plan: a SyMS lake database missing from the folder is deleted ($lake)" "$PLAN/summary.md" "> - \`databases/${lake}\`"
done
for lake in lake_notsyms lake_string lake_noflag lake_other lake_flat_no; do
  expect_file_lacks "synapse plan: ... but not one that isn't a Spark SyMS database ($lake)" "$PLAN/summary.md" "databases/${lake}"
done
expect_file_lacks "synapse plan: no note about lake tables without a lake database in the folder" "$PLAN/summary.md" "tables and relationships"
rm -f "$STUB_LIVE/databases.json"

# With a lake database in the folder, its tables and relationships are deleted too
LAKE_TEMPLATE="$WORK/workspace-template-lake"
mkdir -p "$LAKE_TEMPLATE"
jq '.resources += [{"name": "[concat(parameters(\u0027workspaceName\u0027), \u0027/lake_syms\u0027)]", "type": "Microsoft.Synapse/workspaces/databases", "apiVersion": "2019-06-01-preview", "properties": {}, "dependsOn": []}]' "$SYN" > "$LAKE_TEMPLATE/TemplateForWorkspace.json"
cp "$WORKSPACE_TEMPLATE/TemplateParametersForWorkspace.json" "$LAKE_TEMPLATE/"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$LAKE_TEMPLATE"
expect_file_has "synapse plan: lake tables and relationships are deleted too, and the summary says they aren't counted" "$PLAN/summary.md" "tables and relationships that a lake database in the folder no longer has are deleted too"
workspace_plan WHAT_IF=true DELETE_ARTIFACTS=false TEMPLATE_DIR="$LAKE_TEMPLATE"
expect_file_lacks "synapse plan: ... not without delete-artifacts" "$PLAN/summary.md" "tables and relationships"

# A template's linked service named like an endpoint default is an ordinary artifact
SYNWS_TEMPLATE="$WORK/workspace-template-synws"
mkdir -p "$SYNWS_TEMPLATE"
jq '.resources += [{"name": "[concat(parameters(\u0027workspaceName\u0027), \u0027/synapse-ws-x\u0027)]", "type": "Microsoft.Synapse/workspaces/linkedServices", "apiVersion": "2019-06-01-preview", "properties": {}, "dependsOn": []}]' "$SYN" > "$SYNWS_TEMPLATE/TemplateForWorkspace.json"
cp "$WORKSPACE_TEMPLATE/TemplateParametersForWorkspace.json" "$SYNWS_TEMPLATE/"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$SYNWS_TEMPLATE"
expect_file_lacks "synapse plan: a template linked service named synapse-ws-x isn't a skipped default" "$PLAN/summary.md" "skipped (service default) | \`linkedServices/synapse-ws-x\`"
expect_file_has "synapse plan: ... it is published like any other" "$PLAN/summary.md" "\`linkedServices/synapse-ws-x\`"

# A workspace without a managed virtual network answers the endpoint list with a 400
live_list managedPrivateEndpoints
touch "$STUB_LIVE/managedPrivateEndpoints.400"
NOEP_TEMPLATE="$WORK/workspace-template-noep"
mkdir -p "$NOEP_TEMPLATE"
jq '.resources |= map(select(.name | contains("mpe_bronze") | not))' "$SYN" > "$NOEP_TEMPLATE/TemplateForWorkspace.json"
cp "$WORKSPACE_TEMPLATE/TemplateParametersForWorkspace.json" "$NOEP_TEMPLATE/"
workspace_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true TEMPLATE_DIR="$NOEP_TEMPLATE"
expect "synapse plan: no managed virtual network and no endpoint of the template's own is an empty list" "0" "$status"
NOVNET_PLAN="$WORK/novnet-plan"
cp -R "$PLAN" "$NOVNET_PLAN"
workspace_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect "synapse plan: no managed virtual network and an endpoint to deploy fails the plan" "1" "$status"
expect_log "synapse plan: ... saying so and what to do" "has no managed virtual network, so the managed private endpoints in the folder can't be deployed to it."
workspace_plan WHAT_IF=true
expect "synapse plan: ... but the endpoints aren't listed when they aren't deployed" "0" "$status"
rm -f "$STUB_LIVE/managedPrivateEndpoints.400"
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 mpe_live:m2

workspace_plan WHAT_IF=true DELETE_ARTIFACTS=false
expect_file_lacks "synapse plan: nothing is deleted without delete-artifacts" "$PLAN/summary.md" "nb_old"

live_list bigDataPools spark:b1
workspace_plan WHAT_IF=true
expect "synapse plan: a missing pool fails the plan" "1" "$status"
expect_log "synapse plan: ... naming the artifact, the pool and what to do" "sparkJobDefinitions/sjd_run uses Spark pool 'spark_big', which workspace syn-test doesn't have. Pools are infrastructure: create it with your infrastructure as code (same name in every environment) and apply that first."
live_list sqlPools
workspace_plan WHAT_IF=true
expect_log "synapse plan: a missing SQL pool is named" "The template uses SQL pool 'dw', which workspace syn-test doesn't have."
expect_file_has "synapse plan: ... in the summary of the failed plan" "$PLAN/summary.md" "Plan failed"
live_list bigDataPools spark:b1 spark_big:b2
live_list sqlPools dw:q1

workspace_plan WHAT_IF=true
APPLY_STATE="$WORK/synapse-apply"
workspace_prepare() {
  run synapse/scripts/apply-prepare.sh WORKING_DIR=workspace PLAN_DIR="$PLAN" STATE_DIR="$APPLY_STATE" "$@"
}
workspace_prepare
expect "synapse apply: prepares a plan whose workspace is as planned" "0" "$status"
live_list notebooks nb_old:n1 nb_new:n2
workspace_prepare
expect "synapse apply: an artifact added since the plan is refused" "1" "$status"
expect_log "synapse apply: ... saying what to do" "Workspace syn-test changed since this plan (another deployment, a change made in the portal, or an earlier attempt of this apply). Re-run all jobs of the workflow, not just the failed one (that would reuse this plan), to plan again, then approve that run."
live_list notebooks nb_old:n1
workspace_prepare DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect "synapse apply: an apply that disagrees with the plan about endpoints is refused" "1" "$status"
expect_log "synapse apply: ... saying why" "The apply has deploy-managed-private-endpoints true, but the plan was made with false."

# ... and the apply sees the same empty endpoint list as the plan that allowed it
touch "$STUB_LIVE/managedPrivateEndpoints.400"
rm -rf "$PLAN"
cp -R "$NOVNET_PLAN" "$PLAN"
workspace_prepare DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect "synapse apply: a workspace without a managed virtual network is as planned" "0" "$status"
rm -f "$STUB_LIVE/managedPrivateEndpoints.400"
workspace_prepare STATE_DIR="$WORK/state with space"
expect "synapse apply: a state directory with whitespace is refused (the deployer splits on it)" "1" "$status"
expect_log "synapse apply: ... saying why" "has whitespace in its path"
workspace_plan
workspace_prepare
expect "synapse apply: a plan without what-if is prepared" "0" "$status"
expect_log "synapse apply: ... with a warning that the live check is skipped" "so the check that the workspace is unchanged since the plan is skipped"


# --- Review fixes ---------------------------------------------------------------------------

# The boundary's helpers leave nothing behind
arm_infrastructure_types datafactory > /dev/null
expect "strip: the helper for the types stays private" "0" "$(declare -F emit > /dev/null && echo 1 || echo 0)"
mkdir -p "$WORK/tmp-empty"
echo 'not json' > "$WORK/bad-template.json"
: > "$WORK/types-empty.jsonl"
set +e
TMPDIR="$WORK/tmp-empty" arm_strip_resources "$WORK/bad-template.json" "$WORK/types-empty.jsonl" "$WORK/o1" "$WORK/o2" > /dev/null 2>&1
bad_status=$?
set -e
expect "strip: a template jq can't read fails" "1" "$bad_status"
expect "strip: ... without leaving its scratch file" "0" "$(find "$WORK/tmp-empty" -type f | wc -l | tr -d ' ')"

# Dependencies on what isn't deployed, in the forms ARM templates write them
forms_template() {
  jq --argjson deps "$1" '(.resources[] | select(.name | contains("/ls_storage")) | .dependsOn) = $deps' "$ADF" > "$WORK/forms.json"
}
forms_template '["[resourceId(\u0027Microsoft.DataFactory/factories\u0027, parameters(\u0027factoryName\u0027))]", "[variables(\u0027factoryId\u0027)]", "[concat(variables(\u0027factoryId\u0027), \u0027/integrationRuntimes/\u0027, parameters(\u0027irName\u0027))]", "[concat(variables(\u0027factoryId\u0027), \u0027/pipelines/pl_wait\u0027)]"]'
arm_infrastructure_types datafactory > "$WORK/types.jsonl"
arm_strip_resources "$WORK/forms.json" "$WORK/types.jsonl" "$WORK/stripped.json" "$WORK/left.jsonl" "$WORK/dangling.jsonl"
expect "dependsOn: the factory itself and a computed runtime name are dropped, the rest stays" "[concat(variables('factoryId'), '/pipelines/pl_wait')]" "$(jq -r '.resources[] | select(.name | contains("/ls_storage")) | .dependsOn[]' "$WORK/stripped.json")"
expect "dependsOn: ... and nothing is left to complain about" "0" "$(wc -l < "$WORK/dangling.jsonl" | tr -d ' ')"

forms_template '["[resourceId(\u0027Microsoft.DataFactory/factories/integrationRuntimes\u0027, parameters(\u0027factoryName\u0027), parameters(\u0027irName\u0027))]"]'
arm_strip_resources "$WORK/forms.json" "$WORK/types.jsonl" "$WORK/stripped.json" "$WORK/left.jsonl" "$WORK/dangling.jsonl"
expect "dependsOn: a resourceId with a computed name is reported" "linkedServices/ls_storage" "$(jq -r '.resource' "$WORK/dangling.jsonl")"
arm_strip_problems "$WORK/dangling.jsonl" > "$WORK/log" 2>&1 || true
expect_log "dependsOn: ... saying which dependency and what to do" "depends on [resourceId('Microsoft.DataFactory/factories/integrationRuntimes', parameters('factoryName'), parameters('irName'))], which names something this workflow leaves to infrastructure as code"
expect_log "dependsOn: ... with the way out" "set deploy-integration-runtimes / deploy-managed-private-endpoints to true"

forms_template '["[resourceId(\u0027Microsoft.DataFactory/factories/integrationRuntimes\u0027, parameters(\u0027factoryName\u0027), parameters(\u0027irName\u0027))]"]'
mkdir -p "$WORK/dangling-template"
cp "$FACTORY_TEMPLATE"/* "$WORK/dangling-template/" 2> /dev/null || true
cp "$WORK/forms.json" "$WORK/dangling-template/ARMTemplateForFactory.json"
rm -rf "$PLAN"
run datafactory/scripts/plan.sh WORKING_DIR=factory TEMPLATE_DIR="$WORK/dangling-template" PLAN_DIR="$PLAN" WORK_DIR="$WORK/plan-work" PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev DEPLOYMENT=dev
expect "dependsOn: a plan with one fails" "1" "$status"
expect_file_has "dependsOn: ... and says why in the summary" "$PLAN/summary.md" "dependencies on resources this workflow leaves to infrastructure as code"

# The same, for the Synapse forms
jq '(.resources[] | select(.name | contains("/nb_load")) | .dependsOn) += ["[resourceId(\u0027Microsoft.Synapse/workspaces\u0027, parameters(\u0027workspaceName\u0027))]", "[concat(variables(\u0027workspaceId\u0027), \u0027/bigDataPools/\u0027, parameters(\u0027pool\u0027))]"]' "$SYN" > "$WORK/forms.json"
arm_infrastructure_types synapse > "$WORK/types.jsonl"
arm_strip_resources "$WORK/forms.json" "$WORK/types.jsonl" "$WORK/stripped.json" "$WORK/left.jsonl" "$WORK/dangling.jsonl"
expect "dependsOn: Synapse's workspace and a computed pool name are dropped" "[concat(variables('workspaceId'), '/linkedServices/ls_storage')]" "$(jq -r '.resources[] | select(.name | contains("/nb_load")) | .dependsOn[]' "$WORK/stripped.json")"

# Global parameters are logic: the export's resource for them is deployed
jq '.resources += [{"name": "[concat(parameters(\u0027factoryName\u0027), \u0027/default\u0027)]", "type": "Microsoft.DataFactory/factories/globalparameters", "apiVersion": "2018-06-01", "properties": {}, "dependsOn": []}]' "$ADF" > "$WORK/gp.json"
arm_infrastructure_types datafactory > "$WORK/types.jsonl"
arm_strip_resources "$WORK/gp.json" "$WORK/types.jsonl" "$WORK/stripped.json" "$WORK/left.jsonl"
expect "global parameters: the resource stays in the deployed template" "1" "$(template_types "$WORK/stripped.json" | grep -c globalparameters)"

# Default names are anchored
printf '%s\n' '{"type":"linkedServices","name":"x-WorkspaceDefaultStorage-copy","etag":"1"}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"linkedServices","name":"x-WorkspaceDefaultStorage-copy","etag":"2"}' > "$WORK/s2.jsonl"
expect "defaults: a user artifact that merely contains a default's name counts" "1" "$([ "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" != "$(arm_synapse_fingerprint "$WORK/s2.jsonl")" ] && echo 1 || echo 0)"
printf '%s\n' '{"type":"credentials","name":"WorkspaceSystemIdentity","etag":"1"}' '{"type":"managedVirtualNetworks/managedPrivateEndpoints","name":"synapse-ws-sql--w","etag":""}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"credentials","name":"WorkspaceSystemIdentity","etag":"2"}' '{"type":"managedVirtualNetworks/managedPrivateEndpoints","name":"synapse-ws-sql--w","etag":"9"}' > "$WORK/s2.jsonl"
expect "defaults: the service's own credential and endpoints don't" "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" "$(arm_synapse_fingerprint "$WORK/s2.jsonl")"

# The fingerprint scopes the defaults by type, as the deployer does
printf '%s\n' '{"type":"pipelines","name":"x-WorkspaceDefaultStorage","etag":"1"}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"pipelines","name":"x-WorkspaceDefaultStorage","etag":"2"}' > "$WORK/s2.jsonl"
expect "fingerprint: a pipeline named like a default linked service counts" "1" "$([ "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" != "$(arm_synapse_fingerprint "$WORK/s2.jsonl")" ] && echo 1 || echo 0)"
for pair in 'linkedServices synapse-ws-x' 'linkedServices WorkspaceSystemIdentity' 'credentials x-WorkspaceDefaultStorage' 'managedVirtualNetworks/managedPrivateEndpoints x-WorkspaceDefaultSqlServer'; do
  printf '%s\n' "{\"type\":\"${pair%% *}\",\"name\":\"${pair#* }\",\"etag\":\"1\"}" > "$WORK/s1.jsonl"
  printf '%s\n' "{\"type\":\"${pair%% *}\",\"name\":\"${pair#* }\",\"etag\":\"2\"}" > "$WORK/s2.jsonl"
  expect "fingerprint: ${pair% *} ${pair#* } isn't a default of its type" "1" "$([ "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" != "$(arm_synapse_fingerprint "$WORK/s2.jsonl")" ] && echo 1 || echo 0)"
done
printf '%s\n' '{"type":"managedVirtualNetworks/managedPrivateEndpoints","name":"synapse-ws-custstgacct--w-ab12","etag":""}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"managedVirtualNetworks/managedPrivateEndpoints","name":"synapse-ws-custstgacct--w-ab12","etag":"9"}' > "$WORK/s2.jsonl"
expect "fingerprint: a primary storage endpoint (synapse-ws-custstgacct--...) doesn't" "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" "$(arm_synapse_fingerprint "$WORK/s2.jsonl")"

# Paged lists
reset_live
live_pages pipelines pl_wait:e1 pl_old:e2
live_list triggers trg_daily:e3
live_list linkedservices ls_storage:e4
factory_plan WHAT_IF=true
expect "paging: a plan follows nextLink" "0" "$status"
expect_file_has "paging: ... and sees the second page (a deletion there)" "$PLAN/summary.md" "> - \`pipelines/pl_old\`"
paged="$(output plan-sha256)"
live_pages pipelines pl_wait:e1 pl_old:e2x
factory_plan WHAT_IF=true
expect "paging: ... and fingerprints it" "1" "$([ "$(output plan-sha256)" != "$paged" ] && echo 1 || echo 0)"
jq '.nextLink = "https://management.azure.com/x/pipelines?api-version=1&page=3"' "$STUB_LIVE/pipelines.2.json" > "$WORK/page.json" && mv "$WORK/page.json" "$STUB_LIVE/pipelines.2.json"
factory_plan WHAT_IF=true
expect "paging: a page that disappears fails the plan, not the list" "1" "$status"
expect_log "paging: ... saying so" "Couldn't list the resources of factory adf-test"
live_list pipelines pl_wait:e1
touch "$STUB_LIVE/pipelines.404"
rm -f "$STUB_LIVE/pipelines.2.json"
factory_plan WHAT_IF=true
expect "paging: a missing list (404 on the first page) is empty" "0" "$status"
rm -f "$STUB_LIVE/pipelines.404"

# Lake databases answer {items, continuationToken}
reset_live
jq -n '{items: [{Name: "lake1", Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: true, a: 1}}], continuationToken: "t 1"}' > "$STUB_LIVE/databases.json"
jq -n '{items: [{Name: "lake2", Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: true, b: 2}}]}' > "$STUB_LIVE/databases.2.json"
arm_live_lines https://ws.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net databases > "$WORK/db.jsonl"
expect "databases: both pages are listed, by Name" "lake1 lake2" "$(jq -r .name "$WORK/db.jsonl" | paste -sd' ' -)"
expect "databases: ... typed databases, with a digest for an etag" "databases 64" "$(jq -r '"\(.type) \(.etag | length)"' "$WORK/db.jsonl" | head -1)"
expect "databases: ... asking for the next page by its token" "1" "$(grep -c 'continuationToken=t%201' "$STUB_LOG/az.log")"
first_db="$(arm_live_fingerprint "$WORK/db.jsonl")"
jq -n '{items: [{Name: "lake2", Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: true, b: 3}}]}' > "$STUB_LIVE/databases.2.json"
arm_live_lines https://ws.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net databases > "$WORK/db.jsonl"
expect "databases: a changed database changes the fingerprint" "1" "$([ "$(arm_live_fingerprint "$WORK/db.jsonl")" != "$first_db" ] && echo 1 || echo 0)"

# ... and the lake flag the deletion prediction reads
jq -n '{items: [
  {name: "n1", properties: {Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: true}}},
  {name: "n2", properties: {Origin: {Type: "SPARK"}, Properties: {IsSyMSCDMDatabase: "true"}}},
  {Name: "f1", Origin: {Type: "spark"}, Properties: {IsSyMSCDMDatabase: true}},
  {Name: "f2", Properties: {a: 1}}
]}' > "$STUB_LIVE/databases.json"
rm -f "$STUB_LIVE/databases.2.json"
arm_live_lines https://ws.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net databases > "$WORK/db.jsonl"
expect "databases: the lake flag is read from the nested shape and the flat one, strictly" "n1:true n2:false f1:true f2:false" "$(jq -r '"\(.name):\(.lake)"' "$WORK/db.jsonl" | paste -sd' ' -)"
# ... a Properties that isn't an object, and an item without a name, don't fail the listing
jq -n '{items: [
  {name: "p1", properties: {Origin: {Type: "SPARK"}, Properties: "x"}},
  {name: "p2", properties: {Origin: {Type: "SPARK"}, Properties: [1]}},
  {name: "p3", properties: {Origin: "SPARK", Properties: {IsSyMSCDMDatabase: true}}},
  {name: "", properties: {}},
  {properties: {}}
]}' > "$STUB_LIVE/databases.json"
arm_live_lines https://ws.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net databases > "$WORK/db.jsonl"
expect "databases: odd shapes are not lake databases, nameless items are skipped" "p1:false p2:false p3:false" "$(jq -r '"\(.name):\(.lake)"' "$WORK/db.jsonl" | paste -sd' ' -)"
rm -f "$STUB_LIVE/databases.json"

# The fingerprint skips non-lake databases (a Spark job's)
printf '%s\n' '{"type":"databases","name":"d","etag":"1","lake":false}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"databases","name":"d","etag":"2","lake":false}' > "$WORK/s2.jsonl"
expect "fingerprint: a non-lake database doesn't count" "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" "$(arm_synapse_fingerprint "$WORK/s2.jsonl")"
printf '%s\n' '{"type":"databases","name":"d","etag":"1","lake":true}' > "$WORK/s1.jsonl"
printf '%s\n' '{"type":"databases","name":"d","etag":"2","lake":true}' > "$WORK/s2.jsonl"
expect "fingerprint: a lake database does" "1" "$([ "$(arm_synapse_fingerprint "$WORK/s1.jsonl")" != "$(arm_synapse_fingerprint "$WORK/s2.jsonl")" ] && echo 1 || echo 0)"

# The apply's inputs must be the plan's
reset_live
live_list pipelines pl_wait:e1
factory_plan WHAT_IF=true
factory_apply PRE_POST_SCRIPT=false
expect "adf apply: pre-post-script that differs from the plan's is refused" "1" "$status"
expect_log "adf apply: ... saying why" "The apply has pre-post-script false, but the plan was made with true."
expect_file_has "adf apply: ... in the summary the PR comment posts" "$PLAN/summary.md" "Apply refused:**"
factory_plan WHAT_IF=true PRE_POST_SCRIPT=false
factory_apply
expect "adf apply: with no input the plan's pre-post-script is used" "0" "$status"
expect "adf apply: ... so no script ran" "" "$(cat "$STUB_LOG/pwsh.log")"

# A refused live check says so where the reviewer looks
factory_plan WHAT_IF=true
live_list pipelines pl_wait:e1 pl_new:e9
factory_apply
expect_file_has "adf apply: a refused live check is in the summary" "$PLAN/summary.md" "Apply refused:** Factory adf-test changed since this plan"
expect_log "adf apply: ... advising to re-run all jobs" "Re-run all jobs of the workflow, not just the failed one"

# The integration runtimes the script keeps are listed right before it runs
reset_live
live_list pipelines pl_wait:e1
live_pages integrationRuntimes AutoResolveIntegrationRuntime:e5 ir_live:e6
factory_plan WHAT_IF=true
factory_apply
expect "adf apply: every page of the runtimes is kept" "AutoResolveIntegrationRuntime,ir_live" "$(jq -r '[.resources[] | select(.type == "Microsoft.DataFactory/factories/integrationRuntimes") | .name | .[37:length - 3]] | join(",")' "$STUB_LOG/pwsh-template-post.json")"
create_line="$(grep -n 'deployment group create' "$STUB_LOG/az.log" | tail -1 | cut -d: -f1)"
list_line="$(grep -n 'integrationRuntimes' "$STUB_LOG/az.log" | tail -1 | cut -d: -f1)"
expect "adf apply: ... listed after the ARM deployment, not before" "1" "$([ "$list_line" -gt "$create_line" ] && echo 1 || echo 0)"
jq '.nextLink = "https://management.azure.com/x/integrationRuntimes?api-version=1&page=3"' "$STUB_LIVE/integrationRuntimes.2.json" > "$WORK/page.json" && mv "$WORK/page.json" "$STUB_LIVE/integrationRuntimes.2.json"
factory_apply
expect "adf apply: a list cut short stops before the script can delete" "1" "$status"
expect "adf apply: ... after only the pre phase" "pwsh pre" "$(cat "$STUB_LOG/pwsh.log")"
expect_log "adf apply: ... saying what happened and what to do" "listing the integration runtimes of factory adf-test failed"

# set -e is off inside a function the caller tests with ||: a template for the
# post-deployment script that failed to build must stop the apply before it,
# or the script deletes everything it does not find in an empty template
factory_plan WHAT_IF=true
live_list integrationRuntimes AutoResolveIntegrationRuntime:e5
for mode in fail skip; do
  factory_apply STUB_CP="$mode"
  expect "adf apply: a template for the script that can't be built stops the apply (cp $mode)" "1" "$status"
  expect "adf apply: ... before the post-deployment script" "pwsh pre" "$(cat "$STUB_LOG/pwsh.log")"
  expect_log "adf apply: ... saying what to do (cp $mode)" "Re-run all jobs of the workflow."
done
printf '{"resources": [{}, {}]}' > "$WORK/count.json"
: > "$WORK/empty.json"
expect "template check: the expected count passes" "0" "$(arm_verify_resource_count "$WORK/count.json" 2 && echo 0 || echo 1)"
expect "template check: another count fails" "1" "$(arm_verify_resource_count "$WORK/count.json" 3 && echo 0 || echo 1)"
expect "template check: an empty file fails" "1" "$(arm_verify_resource_count "$WORK/empty.json" 0 && echo 0 || echo 1)"
expect "template check: a missing file fails" "1" "$(arm_verify_resource_count "$WORK/nope.json" 0 && echo 0 || echo 1)"

# A page that is not JSON ends no list
echo '<html>gateway</html>' > "$STUB_LIVE/pipelines.json"
echo '<html>gateway</html>' > "$STUB_LIVE/databases.json"
set +e
arm_rest_list https://management.azure.com/x/pipelines?api-version=1 > "$WORK/out.txt" 2> /dev/null
list_status=$?
arm_rest_items https://ws.dev.azuresynapse.net/databases?api-version=1 > "$WORK/out.txt" 2> /dev/null
items_status=$?
set -e
expect "paging: a page that is not JSON fails the list" "1" "$list_status"
expect "paging: ... also for {items} lists" "1" "$items_status"
rm -f "$STUB_LIVE/databases.json"
live_list pipelines pl_wait:e1
live_list triggers trg_daily:e3
echo '<html>gateway</html>' > "$STUB_LIVE/triggers.json"
factory_plan WHAT_IF=true
expect "paging: ... and so the plan" "1" "$status"
live_list triggers trg_daily:e3

# Reference copies: files of the kinds left to infrastructure as code that
# exist live don't warn
count_warnings() {
  grep -c "is in the folder, but this workflow leaves" "$WORK/log" || true
}
reset_live
live_list pipelines pl_wait:e1
live_list triggers trg_daily:e3
live_list linkedservices ls_storage:e4
live_list integrationRuntimes AutoResolveIntegrationRuntime:e5 IR_CUSTOM:e6
live_list managedPrivateEndpoints MPE_Bronze:e7
factory_plan WHAT_IF=true
expect "reference copies: files that exist live, in any case, don't warn" "0" "$(count_warnings)"
expect_file_has "reference copies: ... and are listed as such" "$PLAN/summary.md" "| \`integrationRuntimes/ir_custom\` | integration runtimes | reference copy of a live resource |"
expect_file_lacks "reference copies: ... with no warning in the comment" "$PLAN/summary.md" "**Warning:**"

# One that doesn't, among others that do, is new
mkdir -p "$WORK/two-irs"
cp -R "$FACTORY_TEMPLATE"/. "$WORK/two-irs/"
jq '.resources += [(.resources[] | select(.name | endswith("/ir_custom\u0027)]")) | .name |= sub("ir_custom"; "ir_new"))]' "$ADF" > "$WORK/two-irs/ARMTemplateForFactory.json"
factory_plan WHAT_IF=true TEMPLATE_DIR="$WORK/two-irs"
expect "reference copies: a file with no live counterpart warns, when its kind has copies that match" "1" "$(count_warnings)"
expect_log "reference copies: ... naming it" "integrationRuntimes/ir_new is in the folder"

# Another environment's copies (stg and prod see dev's names): one note, no warning per file
live_list integrationRuntimes AutoResolveIntegrationRuntime:e5
live_list managedPrivateEndpoints stexample-dfs:e7
factory_plan WHAT_IF=true
expect "reference copies: files matching nothing live warn nowhere" "0" "$(count_warnings)"
expect_log "reference copies: ... and are noted once per kind" "of the folder's managed private endpoints match nothing live in this target"
expect_file_has "reference copies: ... in the plan too" "$PLAN/summary.md" "**Note:** 1 of the folder's integration runtimes match nothing live in this target"
expect_file_lacks "reference copies: ... without a warning" "$PLAN/summary.md" "**Warning:**"

# Without what-if there is no way to tell
factory_plan
expect "reference copies: what-if off warns for each file" "2" "$(count_warnings)"

# A listing that fails only costs the plan its quiet: it warns about each
# file, as without what-if, and still plans
live_list integrationRuntimes AutoResolveIntegrationRuntime:e5
jq '.nextLink = "https://management.azure.com/x/integrationRuntimes?api-version=1&page=3"' "$STUB_LIVE/integrationRuntimes.json" > "$WORK/page.json" && mv "$WORK/page.json" "$STUB_LIVE/integrationRuntimes.json"
factory_plan WHAT_IF=true
expect "reference copies: a failed listing doesn't fail the plan" "0" "$status"
expect "reference copies: ... warns about each file" "2" "$(count_warnings)"
expect_log "reference copies: ... saying what failed" "Couldn't list the integration runtimes and managed private endpoints of factory adf-test"

# Synapse: the same, with the endpoint's name under the default virtual network
reset_live
live_list pipelines pl_wait:p1
live_list linkedServices ls_storage:l1
live_list bigDataPools spark:b1 spark_big:b2
live_list sqlPools dw:q1
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 MPE_BRONZE:m2
live_list integrationRuntimes AutoResolveIntegrationRuntime:i1
workspace_plan WHAT_IF=true
expect "reference copies (synapse): an endpoint that exists live doesn't warn" "0" "$(count_warnings)"
expect_file_has "reference copies (synapse): ... and is listed as a reference copy" "$PLAN/summary.md" "| \`managedVirtualNetworks/default/managedPrivateEndpoints/mpe_bronze\` | managed private endpoints | reference copy of a live resource |"
live_list managedPrivateEndpoints synapse-ws-sql--syn-test:m1 stexample-dfs:m2
workspace_plan WHAT_IF=true
expect "reference copies (synapse): dev's endpoint names in another environment warn nowhere" "0" "$(count_warnings)"
expect_log "reference copies (synapse): ... they are noted once" "of the folder's managed private endpoints match nothing live in this target"
workspace_plan
expect "reference copies (synapse): what-if off warns" "1" "$(count_warnings)"

# Synapse's delete-artifacts must be the plan's
reset_live
live_list pipelines pl_wait:p1
live_list linkedServices syn-test-WorkspaceDefaultStorage:d1 ls_storage:l1
live_list bigDataPools spark:b1 spark_big:b2
live_list sqlPools dw:q1
workspace_plan WHAT_IF=true DELETE_ARTIFACTS=false
workspace_prepare DELETE_ARTIFACTS=true
expect "synapse apply: delete-artifacts that differs from the plan's is refused" "1" "$status"
expect_log "synapse apply: ... saying why" "The apply has delete-artifacts true, but the plan was made with false."
expect_file_has "synapse apply: ... in the summary the PR comment posts" "$PLAN/summary.md" "Apply refused:**"
workspace_prepare
expect "synapse apply: with no input the plan's is used" "0" "$status"
expect "synapse apply: ... and the deployer is given the plan's values" "false true" "$(output delete-artifacts) $(output deploy-managed-private-endpoints | sed 's/false/true/')"
workspace_plan WHAT_IF=true
live_list pipelines pl_wait:p1 pl_new:p9
workspace_prepare
expect_log "synapse apply: a refused live check advises re-running all jobs" "Re-run all jobs of the workflow, not just the failed one"

# The service's default artifacts are skipped by the deployer, whatever the
# folder holds: a folder exported from another workspace carries its names
reset_live
live_list bigDataPools spark:b1 spark_big:b2
live_list sqlPools dw:q1
live_list linkedServices syn-test-WorkspaceDefaultStorage:d1
mkdir -p "$WORK/syn-defaults"
cp -R "$WORKSPACE_TEMPLATE"/. "$WORK/syn-defaults/"
jq '.resources += [
  {name: "[concat(parameters(\u0027workspaceName\u0027), \u0027/syn-dev-WorkspaceDefaultStorage\u0027)]", type: "Microsoft.Synapse/workspaces/linkedServices", properties: {}, dependsOn: []},
  {name: "[concat(parameters(\u0027workspaceName\u0027), \u0027/syn-dev-WorkspaceDefaultSqlServer\u0027)]", type: "Microsoft.Synapse/workspaces/linkedServices", properties: {}, dependsOn: []},
  {name: "[concat(parameters(\u0027workspaceName\u0027), \u0027/WorkspaceSystemIdentity\u0027)]", type: "Microsoft.Synapse/workspaces/credentials", properties: {}, dependsOn: []}]' "$SYN" > "$WORK/syn-defaults/TemplateForWorkspace.json"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$WORK/syn-defaults"
expect "defaults: a plan against another workspace succeeds" "0" "$status"
expect_file_has "defaults: the heading counts what changes, and the defaults apart" "$PLAN/summary.md" "### 📋 Plan: 4 to create, 0 to modify, 0 to delete"
expect_file_has "defaults: ... and are a count in the sentence" "$PLAN/summary.md" "3 service default(s) skipped"
expect_file_lacks "defaults: ... never listed as created" "$PLAN/summary.md" "create | \`linkedServices/syn-dev-WorkspaceDefaultStorage"
expect_file_lacks "defaults: ... nor as modified" "$PLAN/summary.md" "modify | \`credentials/WorkspaceSystemIdentity"
expect "defaults: has-changes is true (the 4 artifacts are new)" "true" "$(output has-changes)"
workspace_plan TEMPLATE_DIR="$WORK/syn-defaults"
expect_file_has "defaults: without what-if the heading says so too" "$PLAN/summary.md" "### 📋 Plan: deploy 4 artifact(s) (3 service default(s) skipped)"

# Only defaults: honest, and still a plan
mkdir -p "$WORK/syn-only-defaults"
cp -R "$WORKSPACE_TEMPLATE"/. "$WORK/syn-only-defaults/"
jq '.resources |= map(select(.name | test("WorkspaceDefault|WorkspaceSystemIdentity")))' "$WORK/syn-defaults/TemplateForWorkspace.json" > "$WORK/syn-only-defaults/TemplateForWorkspace.json"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$WORK/syn-only-defaults"
expect_file_has "defaults: with nothing else there is nothing to change" "$PLAN/summary.md" "### ✅ No changes"
expect_file_has "defaults: ... and says the defaults were skipped" "$PLAN/summary.md" "(0 artifact(s) unchanged, 3 service default(s) skipped)"
expect "defaults: ... so has-changes is false" "false" "$(output has-changes)"

# A user artifact named like a default is not skipped by the deletion list
live_list pipelines pl_wait:p1
live_list linkedServices syn-test-WorkspaceDefaultStorage:d1 x-WorkspaceDefaultStorage-copy:l9
workspace_plan WHAT_IF=true
expect_file_has "synapse plan: x-WorkspaceDefaultStorage-copy is deleted like any artifact" "$PLAN/summary.md" "> - \`linkedServices/x-WorkspaceDefaultStorage-copy\`"
expect_file_lacks "synapse plan: ... unlike the real default" "$PLAN/summary.md" "> - \`linkedServices/syn-test-WorkspaceDefaultStorage"

# --- The comparison with the live definitions -----------------------------------------------------

# Compare one template artifact (named res, of a kind) with one live item,
# as arm_synapse_compare does, and print its result line.
# Usage: compare_one <kind> '<template properties>' '<live properties>' ['<extra template parameters>' ['<parameter values>' ['<variables>']]]
compare_one() {
  local kind="$1" mine="$2" live="$3" decl="${4:-}" given="${5:-}" vars="${6:-}"
  [ -n "$decl" ] || decl='{}'
  [ -n "$given" ] || given='{}'
  [ -n "$vars" ] || vars='{}'
  jq -n --arg kind "$kind" --argjson props "$mine" --argjson decl "$decl" --argjson vars "$vars" '
    {parameters: ({workspaceName: {type: "string"}} + $decl), variables: $vars,
     resources: [{name: "[concat(parameters(\u0027workspaceName\u0027), \u0027/res\u0027)]",
                  type: "Microsoft.Synapse/workspaces/\($kind)", properties: $props}]}' > "$WORK/cmp-template.json"
  jq -n --argjson given "$given" '{parameters: ($given | map_values({value: .}))}' > "$WORK/cmp-parameters.json"
  arm_template_resources "$WORK/cmp-template.json" |
    jq -c "(.type | ascii_downcase) as \$t | . + {key: \"\(\$t)/\(.name | ascii_downcase)\", default: (${ARM_SYNAPSE_IS_DEFAULT})}" > "$WORK/cmp-entries.jsonl"
  jq -nc --arg kind "$kind" --argjson live "$live" '{type: ($kind | ascii_downcase), name: "res", etag: "e", properties: $live}' > "$WORK/cmp-live.jsonl"
  arm_synapse_compare "$WORK/cmp-template.json" "$WORK/cmp-parameters.json" ws-test "$WORK/cmp-entries.jsonl" "$WORK/cmp-live.jsonl"
}

# The same, as "<status> <path>:<change>,..."
compare_summary() {
  compare_one "$@" | jq -r '"\(.status) \(.paths | map("\(.path):\(.change)") | join(","))" | rtrimstr(" ")'
}

expect "compare: a whole-string parameter is evaluated, whatever the case of its name" "unchanged" "$(compare_summary pipelines '{"a": "[parameters('"'"'U'"'"')]", "b": 2}' '{"a": "https://x", "b": 2}' '{"u": {"type": "string"}}' '{"u": "https://x"}')"
expect "compare: concat with workspaceName is the target workspace's" "unchanged" "$(compare_summary pipelines '{"a": "[concat('"'"'abc-'"'"', parameters('"'"'workspaceName'"'"'), '"'"'-'"'"', 7)]"}' '{"a": "abc-ws-test-7"}')"
expect "compare: a default value is evaluated, and so are variables" "unchanged" "$(compare_summary pipelines '{"a": "[variables('"'"'v'"'"')]", "b": "[parameters('"'"'p'"'"')]"}' '{"a": "x-ws-test", "b": "dflt"}' '{"p": {"type": "string", "defaultValue": "dflt"}}' '{}' '{"v": "[concat('"'"'x-'"'"', parameters('"'"'workspaceName'"'"'))]"}')"
expect "compare: [x].[y], [[x], [toLower('x')] and ['x'] are literal text (the deployer's grammar, not ARM's)" "unchanged" "$(compare_summary pipelines '{"a": "[log].[usp_x]", "b": "[[x]", "c": "[toLower('"'"'x'"'"')]", "d": "['"'"'x'"'"']"}' '{"a": "[log].[usp_x]", "b": "[[x]", "c": "[toLower('"'"'x'"'"')]", "d": "['"'"'x'"'"']"}')"
expect "compare: ... and a live value ARM would have produced is a change" "modify properties.b:modified" "$(compare_summary pipelines '{"b": "[[x]"}' '{"b": "[x]"}')"
expect "compare: an undeclared parameter can't be compared" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[parameters('"'"'nope'"'"')]"}' '{"a": "x"}')"
expect "compare: an expression that doesn't parse can't be compared" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[parameters('"'"'a'"'"']"}' '{"a": "x"}')"
expect "compare: a nested unsupported function can't be compared" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[concat(toLower('"'"'x'"'"'))]"}' '{"a": "x"}')"
expect "compare: resourceId in a property can't be compared" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[resourceId('"'"'a'"'"', '"'"'b'"'"')]"}' '{"a": "x"}')"
expect "compare: concat() with no argument can't be compared" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[concat()]"}' '{"a": "x"}')"
expect "compare: a parameter without a value can't be compared" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[parameters('"'"'p'"'"')]"}' '{"a": "x"}' '{"p": {"type": "string"}}')"
expect "compare: a default that refers to itself can't be compared, and doesn't hang" "unknown properties.a:unknown" "$(compare_summary pipelines '{"a": "[parameters('"'"'p'"'"')]"}' '{"a": "x"}' '{"p": {"type": "string", "defaultValue": "[parameters('"'"'p'"'"')]"}}')"
expect "compare: a definite change wins over a value that can't be evaluated" "modify properties.a:unknown,properties.b:modified" "$(compare_summary pipelines '{"a": "[parameters('"'"'nope'"'"')]", "b": 1}' '{"a": "x", "b": 2}')"

# Normalization: each rule, and what it must not hide
expect "compare: null is absent" "unchanged" "$(compare_summary pipelines '{"a": 1, "d": null}' '{"a": 1}')"
expect "compare: ... in either side" "unchanged" "$(compare_summary pipelines '{"a": 1}' '{"a": 1, "d": null}')"
expect "compare: [] and {} are absent" "unchanged" "$(compare_summary pipelines '{"a": 1, "annotations": [], "typeProperties": {}}' '{"a": 1, "outputs": []}')"
expect "compare: lastPublishTime is the service's" "unchanged" "$(compare_summary pipelines '{"a": 1, "lastPublishTime": "x"}' '{"a": 1, "lastPublishTime": "y"}')"
expect "compare: a notebook's kernelspec is only in the template" "unchanged" "$(compare_summary notebooks '{"metadata": {"kernelspec": {"name": "synapse_pyspark"}, "language_info": {"name": "python"}}}' '{"metadata": {"language_info": {"name": "python"}}}')"
expect "compare: a notebook's runAsWorkspaceSystemIdentity false is the default" "unchanged" "$(compare_summary notebooks '{"a": 1}' '{"a": 1, "sessionProperties": {"runAsWorkspaceSystemIdentity": false}}')"
expect "compare: ... true is a change" "modify properties.sessionProperties:removed" "$(compare_summary notebooks '{"a": 1}' '{"a": 1, "sessionProperties": {"runAsWorkspaceSystemIdentity": true}}')"
expect "compare: a notebook's a365ComputeOptions is the workspace's cache of its pool" "unchanged" "$(compare_summary notebooks '{"metadata": {"a365ComputeOptions": {"id": "x"}}}' '{"metadata": {"a365ComputeOptions": {"id": "y"}}}')"
expect "compare: a trigger's runtimeState is read-only" "unchanged" "$(compare_summary triggers '{"a": 1}' '{"a": 1, "runtimeState": "Started"}')"
expect "compare: ... but not a pipeline's" "modify properties.runtimeState:removed" "$(compare_summary pipelines '{"a": 1}' '{"a": 1, "runtimeState": "Started"}')"

# What must never be called unchanged
expect "compare: a key only the live definition has is a change" "modify properties.description:removed" "$(compare_summary pipelines '{"a": 1}' '{"a": 1, "description": "d"}')"
expect "compare: a key only the template has is a change" "modify properties.description:added" "$(compare_summary pipelines '{"a": 1, "description": "d"}' '{"a": 1}')"
expect "compare: two activities swapped are a change" "modify properties.activities[0].name:modified,properties.activities[1].name:modified" "$(compare_summary pipelines '{"activities": [{"name": "a"}, {"name": "b"}]}' '{"activities": [{"name": "b"}, {"name": "a"}]}')"
expect "compare: an activity removed is a change, reported once at the array" "modify properties.activities:modified" "$(compare_summary pipelines '{"activities": [{"name": "a"}]}' '{"activities": [{"name": "a"}, {"name": "b"}]}')"
expect "compare: a folder moved is a change" "modify properties.folder.name:modified" "$(compare_summary notebooks '{"folder": {"name": "a"}}' '{"folder": {"name": "b"}}')"
expect "compare: \"2\" is not 2" "modify properties.a:modified" "$(compare_summary pipelines '{"a": "2"}' '{"a": 2}')"
expect "compare: a key with a dot is shown in brackets" "modify properties.sessionProperties.conf[\"spark.x\"]:modified" "$(compare_summary notebooks '{"sessionProperties": {"conf": {"spark.x": "1"}}}' '{"sessionProperties": {"conf": {"spark.x": "2"}}}')"
expect "compare: a changed line of a cell's source is reported as the source" "modify properties.cells[0].source:modified" "$(compare_summary notebooks '{"cells": [{"source": ["a", "b"]}]}' '{"cells": [{"source": ["a", "c"]}]}')"

# The deployer points references to another workspace's default linked services at its own
expect "compare: a reference to another workspace's default storage is the target's" "unchanged" "$(compare_summary datasets '{"linkedServiceName": {"referenceName": "ws-dev-WorkspaceDefaultStorage", "type": "LinkedServiceReference"}}' '{"linkedServiceName": {"referenceName": "ws-test-WorkspaceDefaultStorage", "type": "LinkedServiceReference"}}')"
expect "compare: ... and the SQL one, whatever the case" "unchanged" "$(compare_summary datasets '{"linkedServiceName": {"referenceName": "other-WORKSPACEDEFAULTSQLSERVER", "type": "LinkedServiceReference"}}' '{"linkedServiceName": {"referenceName": "ws-test-WorkspaceDefaultSqlServer", "type": "LinkedServiceReference"}}')"
expect "compare: a reference that isn't a linked service's is left alone" "modify properties.pipeline.referenceName:modified" "$(compare_summary pipelines '{"pipeline": {"referenceName": "ws-dev-WorkspaceDefaultStorage", "type": "PipelineReference"}}' '{"pipeline": {"referenceName": "ws-test-WorkspaceDefaultStorage", "type": "PipelineReference"}}')"

# Secure values are compared and never shown
SECURE_DECL='{"s": {"type": "secureString"}}'
SECURE_PROPS='{"password": "[parameters('"'"'s'"'"')]", "user": "u"}'
expect "compare: a secure value equal to the live one is unchanged" "unchanged" "$(compare_summary linkedServices "$SECURE_PROPS" '{"password": "placeholder-secret", "user": "u"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"
expect "compare: ... a different readable one is a change" "modify properties.password:secure" "$(compare_summary linkedServices "$SECURE_PROPS" '{"password": "other", "user": "u"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"
expect "compare: ... one the service hides (asterisks) is secure, not compared" "secure properties.password:not-compared" "$(compare_summary linkedServices "$SECURE_PROPS" '{"password": "**********", "user": "u"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"
expect "compare: ... one the service doesn't return is too" "secure properties.password:not-compared" "$(compare_summary linkedServices "$SECURE_PROPS" '{"user": "u"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"
expect "compare: ... but a change elsewhere is a modify" "modify properties.password:not-compared,properties.user:modified" "$(compare_summary linkedServices "$SECURE_PROPS" '{"password": "**********", "user": "v"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"
expect "compare: a secure value is not in the output" "0" "$(compare_one linkedServices "$SECURE_PROPS" '{"password": "other-live", "user": "u"}' "$SECURE_DECL" '{"s": "placeholder-secret"}' | grep -c 'placeholder-secret\|other-live' || true)"
expect "compare: concat with a secure value is secure too" "modify properties.cs:secure" "$(compare_summary linkedServices '{"cs": "[concat('"'"'pwd='"'"', parameters('"'"'s'"'"'))]"}' '{"cs": "pwd=other"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"

# What can't be compared at all
expect "compare: a live item without a definition can't be compared" "unknown properties:unknown" "$(compare_summary pipelines '{"a": 1}' 'null')"
expect "compare: lake databases aren't compared" "unknown properties:unknown" "$(compare_summary databases '{"a": 1}' '{"a": 1}')"
expect "compare: ... and say why" "databases are not compared" "$(compare_one databases '{"a": 1}' '{"a": 1}' | jq -r '.paths[0].why')"
cases=$((cases + 1))
echo '{"parameters": {}, "resources": []}' > "$WORK/cmp-empty.json"
if arm_synapse_compare "$WORK/cmp-empty.json" "$WORK/cmp-parameters.json" ws-test "$WORK/cmp-entries.jsonl" "$WORK/cmp-live.jsonl" > /dev/null 2>&1; then
  log_error "compare: entries that aren't the template's should fail"
  failures=$((failures + 1))
else
  log_success "compare: entries that aren't the template's fail"
fi

# --- Synapse plan: the comparison ------------------------------------------------------

compare_live() {
  reset_live
  cp "$CANNED"/synapse-live/*.json "$STUB_LIVE/"
  live_list bigDataPools spark:b1 spark_big:b2
  live_list sqlPools dw:q1
}

compare_live
workspace_plan WHAT_IF=true
expect "synapse compare: a workspace that matches the folder plans" "0" "$status"
expect_file_has "synapse compare: ... with no changes" "$PLAN/summary.md" "### ✅ No changes"
expect_file_has "synapse compare: ... all four artifacts unchanged" "$PLAN/summary.md" "(4 artifact(s) unchanged)"
expect_file_lacks "synapse compare: ... nothing is listed as modified" "$PLAN/summary.md" "🟡"
expect "synapse compare: ... so has-changes is false" "false" "$(output has-changes)"
expect_file_has "synapse compare: ... and the log says so" "$WORK/log" "has changes: false"

workspace_plan WHAT_IF=true ALWAYS_APPLY=true
expect "synapse compare: always-apply makes has-changes true" "true" "$(output has-changes)"
expect_file_has "synapse compare: ... and the heading says so" "$PLAN/summary.md" "### 📋 Plan: no changes, applied anyway (always-apply)"
expect_file_has "synapse compare: ... and that everything is published again" "$PLAN/summary.md" "Every artifact is published again."

jq '.value[0].properties.bigDataPool.referenceName = "spark_big"' "$STUB_LIVE/notebooks.json" > "$WORK/nb.json" && mv "$WORK/nb.json" "$STUB_LIVE/notebooks.json"
workspace_plan WHAT_IF=true
expect_file_has "synapse compare: one changed property is the heading" "$PLAN/summary.md" "### 📋 Plan: 0 to create, 1 to modify, 0 to delete"
expect_file_has "synapse compare: ... its row names the path" "$PLAN/summary.md" "| 🟡 modify | \`notebooks/nb_load\` | \`properties.bigDataPool.referenceName\` |"
expect_file_has "synapse compare: ... the others are unchanged" "$PLAN/summary.md" "3 artifact(s) unchanged"
expect "synapse compare: ... and has-changes is true" "true" "$(output has-changes)"

compare_live
jq '.value += [{name: "pl_old", etag: "p2", properties: {}}] | .value |= map(select(.name != "pl_wait"))' "$STUB_LIVE/pipelines.json" > "$WORK/pl.json" && mv "$WORK/pl.json" "$STUB_LIVE/pipelines.json"
workspace_plan WHAT_IF=true
expect_file_has "synapse compare: an artifact missing live is created" "$PLAN/summary.md" "| 🟢 create | \`pipelines/pl_wait\` |  |"
expect_file_has "synapse compare: ... and one missing from the folder is deleted" "$PLAN/summary.md" "> - \`pipelines/pl_old\`"
expect_file_has "synapse compare: ... both in the heading" "$PLAN/summary.md" "### 📋 Plan: 1 to create, 0 to modify, 1 to delete"
expect "synapse compare: ... and has-changes is true" "true" "$(output has-changes)"

compare_live
workspace_plan
expect_file_has "synapse compare: without what-if the rows are published again" "$PLAN/summary.md" "| 🔵 publish | \`pipelines/pl_wait\` |"
expect "synapse compare: ... and has-changes is true" "true" "$(output has-changes)"
expect_file_lacks "synapse compare: ... nothing is compared" "$WORK/log" "Compare the artifacts with their live definitions"

# A live list without definitions (the stubs of the other tests): nothing can be called unchanged
reset_live
live_list pipelines pl_wait:p1
live_list linkedServices ls_storage:l1
live_list notebooks nb_load:n1
live_list sparkJobDefinitions sjd_run:s1
live_list bigDataPools spark:b1 spark_big:b2
live_list sqlPools dw:q1
workspace_plan WHAT_IF=true
expect "synapse compare: items without a definition are all artifacts the plan can't compare" "4" "$(grep -c "⚪ can't compare" "$PLAN/summary.md")"
expect "synapse compare: ... so has-changes is true" "true" "$(output has-changes)"

# A comparison that fails counts every existing artifact as changed
compare_live
mkdir -p "$WORK/no-jq-module"
workspace_plan WHAT_IF=true ARM_SCRIPTS_DIR="$WORK/no-jq-module"
expect "synapse compare: a failed comparison doesn't fail the plan" "0" "$status"
expect_log "synapse compare: ... it warns, and says what to do" "Couldn't compare the artifacts with workspace syn-test, so the plan counts every one that exists there as changed. Please report it at https://github.com/JoshSLawrence/actions/issues."
expect "synapse compare: ... every existing artifact is one the plan can't compare" "4" "$(grep -c "⚪ can't compare" "$PLAN/summary.md")"
expect_file_has "synapse compare: ... the summary says so" "$PLAN/summary.md" "the comparison failed"
expect "synapse compare: ... and has-changes is true" "true" "$(output has-changes)"

# The fingerprint doesn't depend on the definitions being listed
compare_live
workspace_plan WHAT_IF=true
with_properties="$(ARM_LIVE_PROPERTIES=true arm_live_lines https://syn-test.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net notebooks pipelines linkedServices | arm_live_fingerprint /dev/stdin)"
without_properties="$(arm_live_lines https://syn-test.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net notebooks pipelines linkedServices | arm_live_fingerprint /dev/stdin)"
expect "synapse compare: the fingerprint is the same with and without the definitions" "$without_properties" "$with_properties"
expect "synapse compare: ... and lines carry them only on request" "1" "$(arm_live_lines https://syn-test.dev.azuresynapse.net 2019-06-01-preview https://dev.azuresynapse.net notebooks | jq -s '[.[] | has("properties")] | any | not | if . then 1 else 0 end')"
workspace_prepare
expect "synapse compare: the apply accepts a plan made with the definitions listed" "0" "$status"

# Secure parameters are compared with the live ones, in a scratch file
SECURE_WS_TEMPLATE="$WORK/workspace-template-secure"
mkdir -p "$SECURE_WS_TEMPLATE"
jq '.parameters.ls_secret = {type: "secureString"}
  | .resources += [{"name": "[concat(parameters(\u0027workspaceName\u0027), \u0027/ls_sql\u0027)]", "type": "Microsoft.Synapse/workspaces/linkedServices", "apiVersion": "2019-06-01-preview", "properties": {"type": "AzureSqlDatabase", "typeProperties": {"password": "[parameters(\u0027ls_secret\u0027)]"}}, "dependsOn": []}]' "$SYN" > "$SECURE_WS_TEMPLATE/TemplateForWorkspace.json"
echo '{"parameters": {"workspaceName": {"value": "syn-dev"}}}' > "$SECURE_WS_TEMPLATE/TemplateParametersForWorkspace.json"
compare_live
jq '.value += [{name: "ls_sql", etag: "l2", properties: {type: "AzureSqlDatabase", typeProperties: {password: "placeholder-secret"}}}]' "$STUB_LIVE/linkedServices.json" > "$WORK/ls.json" && mv "$WORK/ls.json" "$STUB_LIVE/linkedServices.json"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_WS_TEMPLATE" PARAMETER_SECRETS="ls_secret=placeholder-secret"
expect "synapse secure: a secure value equal to the live one is no change" "false" "$(output has-changes)"
expect "synapse secure: ... the plan, its summary and the log never hold it" "0" "$( (grep -r placeholder-secret "$PLAN" "$WORK/log" || true) | wc -l | tr -d ' ')"
expect "synapse secure: ... and the scratch directory is deleted" "no" "$([ -e "$WORK/plan-work" ] && echo yes || echo no)"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_WS_TEMPLATE" PARAMETER_SECRETS="ls_secret=rotated-placeholder"
expect_file_has "synapse secure: a different value is a modify, with the path marked and no value" "$PLAN/summary.md" "| 🟡 modify | \`linkedServices/ls_sql\` | 🔒 \`properties.typeProperties.password\` |"
expect "synapse secure: ... the new value isn't kept" "0" "$( (grep -r rotated-placeholder "$PLAN" "$WORK/log" || true) | wc -l | tr -d ' ')"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_WS_TEMPLATE" PARAMETERS="ls_secret=placeholder-parameter"
expect_file_has "synapse secure: a 🔒 parameter in the table comes with a note on where its value is" "$PLAN/summary.md" "🔒 values aren't shown here."
expect "synapse secure: ... and neither the note nor the table shows a value" "0" "$( (grep 'placeholder' "$PLAN/summary.md" || true) | wc -l | tr -d ' ')"
jq '(.value[] | select(.name == "ls_sql") | .properties.typeProperties.password) = "**********"' "$STUB_LIVE/linkedServices.json" > "$WORK/ls.json" && mv "$WORK/ls.json" "$STUB_LIVE/linkedServices.json"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_WS_TEMPLATE" PARAMETER_SECRETS="ls_secret=placeholder-secret"
expect_file_has "synapse secure: a value the service hides is secure, not compared" "$PLAN/summary.md" "| 🔒 secure, not compared | \`linkedServices/ls_sql\` | 🔒 \`properties.typeProperties.password\` |"
expect_file_has "synapse secure: ... counted in the sentence" "$PLAN/summary.md" "1 with secure values the plan can't compare"
expect "synapse secure: ... as a change" "true" "$(output has-changes)"

# --- Data Factory plan: secure parameters in the what-if --------------------------------------

SECURE_FACTORY_TEMPLATE="$WORK/factory-template-secure"
mkdir -p "$SECURE_FACTORY_TEMPLATE"
jq '.parameters.ls_secret = {type: "secureString"}
  | .resources += [{"name": "[concat(parameters(\u0027factoryName\u0027), \u0027/ls_sql\u0027)]", "type": "Microsoft.DataFactory/factories/linkedServices", "apiVersion": "2018-06-01", "properties": {"type": "AzureSqlDatabase", "typeProperties": {"connectionString": "[parameters(\u0027ls_secret\u0027)]"}}, "dependsOn": []}]' "$ADF" > "$SECURE_FACTORY_TEMPLATE/ARMTemplateForFactory.json"
jq '{parameters: (.parameters | with_entries(select(.value.defaultValue != null) | .value |= {value: .defaultValue}))}' "$SECURE_FACTORY_TEMPLATE/ARMTemplateForFactory.json" > "$SECURE_FACTORY_TEMPLATE/ARMTemplateParametersForFactory.json"

# A canned what-if with one change to ls_sql's connection string
# Usage: whatif_secure <before as JSON> [<after as JSON>]
whatif_secure() {
  jq -n --argjson before "$1" --argjson after "${2:-\"[parameters('ls_secret')]\"}" '
    {changes: [{resourceId: "/subscriptions/sub-1/resourceGroups/rg-dev/providers/Microsoft.DataFactory/factories/adf-test/linkedServices/ls_sql",
                changeType: "Modify",
                delta: [{path: "properties.typeProperties.connectionString", propertyChangeType: "Modify", before: $before, after: $after}]}]}' > "$STUB_LIVE/what-if.json"
}
secure_factory_plan() {
  factory_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_FACTORY_TEMPLATE" PARAMETER_SECRETS="ls_secret=placeholder-secret" "$@"
}

reset_live
whatif_secure '"placeholder-secret"'
secure_factory_plan
expect "adf secure: a secure delta equal to the parameter's value succeeds" "0" "$status"
expect_file_has "adf secure: ... and is no change" "$PLAN/summary.md" "### ✅ No changes"
expect "adf secure: ... so has-changes is false" "false" "$(output has-changes)"
expect "adf secure: ... and the value is nowhere" "0" "$( (grep -r placeholder-secret "$PLAN" "$WORK/log" || true) | wc -l | tr -d ' ')"
secure_factory_plan ALWAYS_APPLY=true
expect "adf secure: always-apply makes has-changes true" "true" "$(output has-changes)"
expect_file_has "adf secure: ... and the heading says so" "$PLAN/summary.md" "### 📋 Plan: no changes, applied anyway (always-apply)"

whatif_secure '"another-placeholder"'
secure_factory_plan
expect_file_has "adf secure: a different readable value is a modify with the path marked" "$PLAN/summary.md" "| 🟡 modify | \`linkedServices/ls_sql\` | 🔒 \`properties.typeProperties.connectionString\` |"
expect "adf secure: ... neither value is shown" "0" "$( (grep -r 'another-placeholder\|placeholder-secret' "$PLAN" "$WORK/log" || true) | wc -l | tr -d ' ')"
expect "adf secure: ... has-changes is true" "true" "$(output has-changes)"

whatif_secure '"**********"'
secure_factory_plan
expect_file_has "adf secure: a value the factory hides is secure, not compared" "$PLAN/summary.md" "| 🔒 secure, not compared | \`linkedServices/ls_sql\` | 🔒 \`properties.typeProperties.connectionString\` |"
expect_file_has "adf secure: ... counted in the sentence" "$PLAN/summary.md" "1 with secure values the what-if can't compare"
expect "adf secure: ... as a change" "true" "$(output has-changes)"
expect_file_has "adf secure: ... the heading still counts nothing to modify" "$PLAN/summary.md" "### 📋 Plan: 0 to create, 0 to modify, 0 to delete"

whatif_secure 'null'
secure_factory_plan
expect_file_has "adf secure: a value the factory doesn't return is not compared either" "$PLAN/summary.md" "🔒 secure, not compared"

whatif_secure '"placeholder-secret"' "\"[parameters('ls_secret')]\""
jq '.changes[0].delta[0] |= {path: "properties.typeProperties", propertyChangeType: "Modify", children: [{path: "connectionString", propertyChangeType: "Modify", before: "placeholder-secret", after: "[parameters('"'"'ls_secret'"'"')]"}]}' "$STUB_LIVE/what-if.json" > "$WORK/wi.json" && mv "$WORK/wi.json" "$STUB_LIVE/what-if.json"
secure_factory_plan
expect_file_has "adf secure: a child delta that resolves equal takes its parent with it" "$PLAN/summary.md" "### ✅ No changes"

# A parameter whose value is a Key Vault reference has no plain value to compare
jq '.changes[0].delta[0] |= {path: "properties.typeProperties.connectionString", propertyChangeType: "Modify", before: "live", after: "[parameters('"'"'ls_secret'"'"')]"}' "$STUB_LIVE/what-if.json" > "$WORK/wi.json" && mv "$WORK/wi.json" "$STUB_LIVE/what-if.json"
printf '%s\n' '{"parameters": {"factoryName": {"value": "adf-test"}, "ls_secret": {"reference": {"keyVault": {"id": "/subscriptions/sub-1/vaults/kv"}, "secretName": "s"}}}}' > "$WORK/secret-reference.json"
cp "$WORK/secret-reference.json" "$REPO/factory/deployments/kv.json"
factory_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_FACTORY_TEMPLATE" PARAMETER_FILES=deployments/kv.json
expect_file_has "adf secure: a Key Vault reference can't be compared" "$PLAN/summary.md" "🔒 secure, not compared"

reset_live
whatif_secure '"x"' '"https://example.net/"'
secure_factory_plan
expect_file_has "adf secure: a delta that isn't a secure reference is untouched" "$PLAN/summary.md" "| 🟡 modify | \`linkedServices/ls_sql\` | \`properties.typeProperties.connectionString\` |"
jq -n '{changes: [{resourceId: "/subscriptions/sub-1/resourceGroups/rg-dev/providers/Microsoft.DataFactory/factories/adf-test/pipelines/pl_wait", changeType: "Modify", delta: [{path: "properties.lastPublishTime", propertyChangeType: "Delete", before: "2000-01-01T00:00:00Z"}]}]}' > "$STUB_LIVE/what-if.json"
secure_factory_plan
expect "adf secure: lastPublishTime is still the service's" "false" "$(output has-changes)"
rm -f "$STUB_LIVE/what-if.json"

# The note under the parameters table
factory_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_FACTORY_TEMPLATE" PARAMETERS="ls_secret=placeholder-parameter"
expect_file_has "parameters: the 🔒 note says where the values are" "$PLAN/summary.md" "are in \`deploy/parameters.json\` of the plan artifact"
expect_file_has "parameters: ... and that parameter-secrets are never shown" "$PLAN/summary.md" "\`parameter-secrets\` are never shown."
factory_plan WHAT_IF=true
expect_file_lacks "parameters: no note without a 🔒 value" "$PLAN/summary.md" "values aren't shown here"

# --- Review fixes: triggers, supplied values, secure wrappers, the position join --------------

# A trigger's runtimeState counts when the template sets it: the apply starts the triggers it marks Started
expect "compare: a trigger the template starts and the workspace has stopped is a change" "modify properties.runtimeState:modified" "$(compare_summary triggers '{"a": 1, "runtimeState": "Started"}' '{"a": 1, "runtimeState": "Stopped"}')"
expect "compare: ... and the reverse is too" "modify properties.runtimeState:modified" "$(compare_summary triggers '{"a": 1, "runtimeState": "Stopped"}' '{"a": 1, "runtimeState": "Started"}')"
expect "compare: ... equal states are unchanged" "unchanged" "$(compare_summary triggers '{"a": 1, "runtimeState": "Started"}' '{"a": 1, "runtimeState": "Started"}')"
expect "compare: ... a template without runtimeState doesn't compare it" "unchanged" "$(compare_summary triggers '{"a": 1}' '{"a": 1, "runtimeState": "Stopped"}')"

# A supplied value is used as it is (the deployer's Scope), never evaluated
LITERAL_DECL='{"u": {"type": "string"}}'
expect "compare: a supplied value that looks like an expression stays literal text" "unchanged" "$(compare_summary pipelines '{"a": "[parameters('"'"'u'"'"')]"}' '{"a": "[concat('"'"'a'"'"','"'"'b'"'"')]"}' "$LITERAL_DECL" '{"u": "[concat('"'"'a'"'"','"'"'b'"'"')]"}')"
expect "compare: ... so what it would evaluate to is a change" "modify properties.a:modified" "$(compare_summary pipelines '{"a": "[parameters('"'"'u'"'"')]"}' '{"a": "ab"}' "$LITERAL_DECL" '{"u": "[concat('"'"'a'"'"','"'"'b'"'"')]"}')"

# The folder emptying a value the workspace has is a change, not an absence
expect "compare: [] in the folder against a live list is a change" "modify properties.annotations:removed" "$(compare_summary pipelines '{"a": 1, "annotations": []}' '{"a": 1, "annotations": ["x"]}')"
expect "compare: {} in the folder against a live object is a change" "modify properties.folder:removed" "$(compare_summary pipelines '{"a": 1, "folder": {}}' '{"a": 1, "folder": {"name": "x"}}')"
expect "compare: null in the folder against a live value is a change" "modify properties.description:removed" "$(compare_summary pipelines '{"a": 1, "description": null}' '{"a": 1, "description": "x"}')"

# A secure value the service omits together with its wrapper
expect "compare: a secure wrapper the service omits is secure, not compared" "secure properties.password:not-compared" "$(compare_summary linkedServices '{"user": "u", "password": {"type": "SecureString", "value": "[parameters('"'"'s'"'"')]"}}' '{"user": "u"}' "$SECURE_DECL" '{"s": "placeholder-secret"}')"

# dependsOn strings are remapped like the deployer does (last segment, linked services only)
expect "compare: a dependsOn path to another workspace's default linked service is the target's" "unchanged" "$(compare_summary pipelines '{"dependsOn": ["a/linkedServices/ws-dev-WorkspaceDefaultStorage"]}' '{"dependsOn": ["a/linkedServices/ws-test-WorkspaceDefaultStorage"]}')"
expect "compare: ... but a pipeline named like one keeps its name" "modify properties.dependsOn:modified" "$(compare_summary pipelines '{"dependsOn": ["a/pipelines/ws-dev-WorkspaceDefaultStorage"]}' '{"dependsOn": ["a/pipelines/ws-test-WorkspaceDefaultStorage"]}')"

# A deletion alone is a change
compare_live
jq '.value += [{name: "pl_old", etag: "p2", properties: {}}]' "$STUB_LIVE/pipelines.json" > "$WORK/pl.json" && mv "$WORK/pl.json" "$STUB_LIVE/pipelines.json"
workspace_plan WHAT_IF=true
expect "synapse compare: a deletion alone is a change" "true" "$(output has-changes)"
expect_file_has "synapse compare: ... in the heading" "$PLAN/summary.md" "### 📋 Plan: 0 to create, 0 to modify, 1 to delete"

# Rows name the right artifacts when service defaults sit between modified ones
DEFAULTS_BETWEEN="$WORK/syn-defaults-between"
mkdir -p "$DEFAULTS_BETWEEN"
cp "$WORKSPACE_TEMPLATE/TemplateParametersForWorkspace.json" "$DEFAULTS_BETWEEN/"
jq '.resources |= (map(select(.name | contains("nb_load"))) + [
  {name: "[concat(parameters(\u0027workspaceName\u0027), \u0027/syn-dev-WorkspaceDefaultStorage\u0027)]", type: "Microsoft.Synapse/workspaces/linkedServices", properties: {}, dependsOn: []},
  {name: "[concat(parameters(\u0027workspaceName\u0027), \u0027/WorkspaceSystemIdentity\u0027)]", type: "Microsoft.Synapse/workspaces/credentials", properties: {}, dependsOn: []}] + map(select(.name | contains("nb_load") | not)))' "$SYN" > "$DEFAULTS_BETWEEN/TemplateForWorkspace.json"
compare_live
jq '.value[0].properties.bigDataPool.referenceName = "spark_big"' "$STUB_LIVE/notebooks.json" > "$WORK/nb.json" && mv "$WORK/nb.json" "$STUB_LIVE/notebooks.json"
jq '.value[0].properties.activities[0].name = "other"' "$STUB_LIVE/pipelines.json" > "$WORK/pl.json" && mv "$WORK/pl.json" "$STUB_LIVE/pipelines.json"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$DEFAULTS_BETWEEN"
expect_file_has "synapse compare: a modified artifact before the defaults is named right" "$PLAN/summary.md" "| 🟡 modify | \`notebooks/nb_load\` | \`properties.bigDataPool.referenceName\` |"
expect_file_has "synapse compare: ... and one after them" "$PLAN/summary.md" "| 🟡 modify | \`pipelines/pl_wait\` | \`properties.activities[0].name\` |"
expect_file_lacks "synapse compare: ... and a default is not a row" "$PLAN/summary.md" "WorkspaceDefaultStorage\` |"

# A result that isn't one line per artifact counts every existing artifact as changed
compare_live
mkdir -p "$WORK/short-jq"
echo '{key: "x", status: "unchanged", paths: []}' > "$WORK/short-jq/synapse-compare.jq"
workspace_plan WHAT_IF=true ARM_SCRIPTS_DIR="$WORK/short-jq"
expect "synapse compare: a result of the wrong length doesn't fail the plan" "0" "$status"
expect_log "synapse compare: ... it warns" "Couldn't compare the artifacts with workspace syn-test"
expect "synapse compare: ... and every existing artifact is one the plan can't compare" "4" "$(grep -c "⚪ can't compare" "$PLAN/summary.md")"
expect "synapse compare: ... so has-changes is true" "true" "$(output has-changes)"

# The note under the parameters table is true whether or not the plan is uploaded
workspace_plan WHAT_IF=true TEMPLATE_DIR="$SECURE_WS_TEMPLATE" PARAMETERS="ls_secret=placeholder-parameter"
expect_file_has "parameters: the note says when the plan artifact exists" "$PLAN/summary.md" "uploaded when the plan has changes and the apply is on"

# An invalid int never echoes the value
INT_WS_TEMPLATE="$WORK/workspace-template-int"
mkdir -p "$INT_WS_TEMPLATE"
jq '.parameters.retries = {type: "int", defaultValue: 1}' "$SYN" > "$INT_WS_TEMPLATE/TemplateForWorkspace.json"
cp "$WORKSPACE_TEMPLATE/TemplateParametersForWorkspace.json" "$INT_WS_TEMPLATE/"
workspace_plan TEMPLATE_DIR="$INT_WS_TEMPLATE" PARAMETERS="retries=placeholder-text"
expect "parameters: a non-integer int fails the plan" "1" "$status"
expect_file_has "parameters: ... naming the parameter and what to do" "$PLAN/summary.md" "retries is an int parameter, but its value isn't a whole number. Set a whole number"
expect "parameters: ... without the value, in the summary or the log" "0" "$( (grep -r placeholder-text "$PLAN" "$WORK/log" || true) | wc -l | tr -d ' ')"
workspace_plan WHAT_IF=true TEMPLATE_DIR="$INT_WS_TEMPLATE" PARAMETER_SECRETS="retries=placeholder-text"
expect "parameters: a non-integer int in parameter-secrets fails the plan" "1" "$status"
expect "parameters: ... without the value, in the summary or the log" "0" "$( (grep -r placeholder-text "$PLAN" "$WORK/log" || true) | wc -l | tr -d ' ')"

# The fingerprint's temporary file holds no definitions
printf '%s\n' '{"type":"notebooks","name":"nb","etag":"e","properties":{"password":"placeholder-secret"}}' > "$WORK/fp-input.jsonl"
(
  arm_live_fingerprint() { cp "$1" "$WORK/fp-lines"; }
  arm_synapse_fingerprint "$WORK/fp-input.jsonl"
)
expect "fingerprint: the file it fingerprints keeps the line" "1" "$(grep -c '"name":"nb"' "$WORK/fp-lines")"
expect "fingerprint: ... without the definition" "0" "$(grep -c placeholder-secret "$WORK/fp-lines" || true)"

# The secrets merge is written next to the output file, nowhere else
mkdir -p "$WORK/merge-out" "$WORK/merge-tmp"
echo '{"parameters": {"workspaceName": {"value": "ws-test"}}}' > "$WORK/merge-parameters.json"
(
  export TMPDIR="$WORK/merge-tmp" PARAMETER_SECRETS="ls_secret=placeholder-secret"
  unset WORK_DIR
  arm_parameters_with_secrets "$SECURE_WS_TEMPLATE/TemplateForWorkspace.json" "$WORK/merge-parameters.json" "$WORK/merge-out/parameters.json"
) > "$WORK/log" 2>&1
expect "secrets merge: the output has the secret" "1" "$(grep -c placeholder-secret "$WORK/merge-out/parameters.json")"
expect "secrets merge: ... the temporary directory stays empty" "0" "$(find "$WORK/merge-tmp" -type f | wc -l | tr -d ' ')"
expect "secrets merge: ... and the intermediate file is removed from beside the output" "parameters.json" "$(ls "$WORK/merge-out")"

# A result with the right length but the wrong order is a failed comparison too
compare_live
mkdir -p "$WORK/reversed-jq"
cat > "$WORK/reversed-jq/synapse-compare.jq" << 'JQ'
$entries | reverse | .[] | {key, status: "unchanged", paths: []}
JQ
workspace_plan WHAT_IF=true ARM_SCRIPTS_DIR="$WORK/reversed-jq"
expect "synapse compare: a result in another order doesn't fail the plan" "0" "$status"
expect_log "synapse compare: ... it warns" "Couldn't compare the artifacts with workspace syn-test"
expect "synapse compare: ... and every existing artifact is one the plan can't compare" "4" "$(grep -c "⚪ can't compare" "$PLAN/summary.md")"
expect "synapse compare: ... so has-changes is true" "true" "$(output has-changes)"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} test(s) failed"
  exit 1
fi
log_success "All ${cases} Data Factory and Synapse script tests passed"
