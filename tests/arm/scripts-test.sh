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
# keep. The deployer, the pre/post-deployment script and what-if need Azure
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
# of the URL>.json (an empty list without one), so a test sets what a
# factory or workspace holds by writing those files.
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
    [ "$3" != "what-if" ] || echo '{"changes": []}'
    ;;
  "synapse trigger") echo "[]" ;;
  rest*)
    url=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--url" ] && url="$2"
      shift
    done
    path="${url%%\?*}"
    file="$STUB_LIVE/${path##*/}.json"
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
cp "$dir/ARMTemplateForFactory.json" "$STUB_LOG/pwsh-template-$phase.json"
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

reset_live() {
  rm -f "$STUB_LIVE"/*.json "$STUB_LOG"/*
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
expect_log "adf apply: ... saying what to do" "Factory adf-test changed since this plan (another deployment, or a change made in the portal). Re-run the workflow to plan again, then approve that run."
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
expect "synapse plan: has-changes stays true" "true" "$(output has-changes)"
synapse_first="$(output plan-sha256)"
live_list linkedServices syn-test-WorkspaceDefaultStorage:d2 ls_storage:l1
workspace_plan WHAT_IF=true
expect "synapse plan: a change to a default artifact doesn't change the plan" "$synapse_first" "$(output plan-sha256)"

workspace_plan WHAT_IF=true DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect_file_has "synapse plan: with endpoints deployed, one missing from the folder is deleted" "$PLAN/summary.md" "> - \`managedVirtualNetworks/managedPrivateEndpoints/mpe_live\`"
expect_file_lacks "synapse plan: ... never the service's own" "$PLAN/summary.md" "> - \`managedVirtualNetworks/managedPrivateEndpoints/synapse-ws-sql"
expect "synapse plan: ... and the endpoints are in the fingerprint" "1" "$(jq -r '.kinds[]' "$PLAN/deploy/live.json" | grep -c 'managedPrivateEndpoints')"

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
expect_log "synapse apply: ... saying what to do" "Workspace syn-test changed since this plan (another deployment, or a change made in the portal). Re-run the workflow to plan again, then approve that run."
live_list notebooks nb_old:n1
workspace_prepare DEPLOY_MANAGED_PRIVATE_ENDPOINTS=true
expect "synapse apply: an apply that disagrees with the plan about endpoints is refused" "1" "$status"
expect_log "synapse apply: ... saying why" "The apply has deploy-managed-private-endpoints true, but the plan was made with false."
workspace_plan
workspace_prepare
expect "synapse apply: a plan without what-if is prepared" "0" "$status"
expect_log "synapse apply: ... with a warning that the live check is skipped" "so the check that the workspace is unchanged since the plan is skipped"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} test(s) failed"
  exit 1
fi
log_success "All ${cases} Data Factory and Synapse script tests passed"
