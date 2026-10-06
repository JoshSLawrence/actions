#!/usr/bin/env bash
#
# Tests the OpenTofu workflow's own scripts, which run before anything is
# planned: change detection (changes.sh), input validation
# (validate-inputs.sh), the Azure credentials mapping (azure-env.sh), and
# the plan names (names.sh). Change detection runs in throwaway Git
# repositories, the way a pull_request run does. Run by pre-commit and CI.
# Needs git, jq.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$REPO_ROOT/opentofu/scripts"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPTS/common.sh"

require_tool git
require_tool jq

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
cases=0

# Run a script with extra env (VAR=value arguments), from the current
# directory; print one of its outputs. Fails if the script failed.
# Usage: output_of <output> <script> [VAR=value ...]
output_of() {
  local field="$1" script="$2" output="$WORK/output"
  shift 2
  : > "$output"
  env GITHUB_OUTPUT="$output" "$@" "$SCRIPTS/$script" > "$WORK/log" 2>&1 || return 1
  sed -n "s/^${field}=//p" "$output"
}

# Usage: expect "<case name>" "<expected>" "<actual>"
expect() {
  cases=$((cases + 1))
  if [ "$3" == "$2" ]; then
    log_success "$1"
  else
    log_error "$1: expected '$2', got '$3'"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

# Usage: expect_refused "<case name>" "<text the refusal says>" <script> [VAR=value ...]
expect_refused() {
  local name="$1" text="$2" script="$3"
  shift 3
  cases=$((cases + 1))
  if output_of name "$script" "$@" > /dev/null; then
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

# --- Change detection ------------------------------------------------------------
#
#   .github/workflows/tofu.yaml   the calling workflow
#   iac/app/                      the root module
#   ├── deployments/prod.tfvars
#   ├── main.tf
#   ├── mise.toml
#   └── modules/label/main.tf     a child module
#   iac/modules/shared/main.tf    a module outside it
#   iac/other/main.tf             another root module
#   shared.tfvars                 a var file outside the module

make_repo() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo"
  cd "$WORK/repo"
  git init -q -b main
  git config user.email test@example.com
  git config user.name test
  mkdir -p .github/workflows iac/app/deployments iac/app/modules/label iac/modules/shared iac/other
  echo 'on: push' > .github/workflows/tofu.yaml
  echo 'module "label" { source = "./modules/label" }' > iac/app/main.tf
  echo '[tools]' > iac/app/mise.toml
  echo 'name = "x"' > iac/app/deployments/prod.tfvars
  echo 'name = "x"' > shared.tfvars
  for f in iac/app/modules/label iac/modules/shared iac/other; do
    echo 'output "x" { value = 1 }' > "$f/main.tf"
  done
  git add -A
  git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

change() {
  echo '# change' >> "$1"
  git add -A
  git commit -qm change
}

# Run changes.sh as a pull_request run of the calling workflow would
changes() {
  output_of changed changes.sh WORKING_DIR=iac/app VAR_FILES=deployments/prod.tfvars \
    EVENT_NAME=pull_request BASE_SHA="$BASE" GITHUB_REPOSITORY=org/repo \
    WORKFLOW_REF=org/repo/.github/workflows/tofu.yaml@refs/pull/1/merge "$@"
}

make_repo
change iac/app/main.tf
expect "a module change plans" true "$(changes)"

make_repo
change iac/app/modules/label/main.tf
expect "a child module change plans" true "$(changes)"

make_repo
change iac/app/deployments/prod.tfvars
expect "a var file change plans" true "$(changes)"

make_repo
change shared.tfvars
expect "a var file outside the module is watched too" true "$(changes VAR_FILES='deployments/prod.tfvars ../../shared.tfvars')"

make_repo
change .github/workflows/tofu.yaml
expect "a change to the calling workflow plans" true "$(changes)"

make_repo
change iac/other/main.tf
expect "another module's change doesn't plan" false "$(changes)"

make_repo
change iac/modules/shared/main.tf
expect "a module outside the root module doesn't plan" false "$(changes)"
expect "...unless extra-paths watches it" true "$(changes EXTRA_PATHS='iac/modules/**')"
expect "...as a directory, without a glob" true "$(changes EXTRA_PATHS=iac/modules)"
expect "...or a directory with a trailing slash" true "$(changes EXTRA_PATHS=iac/modules/)"
expect "...or a glob starting with ./" true "$(changes EXTRA_PATHS='./iac/modules/**')"
expect "...but not a sibling directory sharing its prefix" false "$(changes EXTRA_PATHS=iac/mod)"
expect_refused "extra-paths can't climb out of the repository" "climbs out of the repository" \
  changes.sh WORKING_DIR=iac/app EXTRA_PATHS=../elsewhere EVENT_NAME=pull_request BASE_SHA="$BASE"

make_repo
change iac/other/main.tf
expect "changed-only off always plans" true "$(changes CHANGED_ONLY=false)"
expect "a workflow_dispatch run always plans" true "$(changes EVENT_NAME=workflow_dispatch)"
expect "a diff that can't be computed plans" true "$(changes BASE_SHA=0123456789abcdef0123456789abcdef01234567)"

make_repo
expect "the watched paths are the module, var files, workflow and extra paths" \
  "iac/app iac/app/deployments/prod.tfvars .github/workflows/tofu.yaml iac/modules/**" \
  "$(output_of paths changes.sh WORKING_DIR=iac/app VAR_FILES=deployments/prod.tfvars \
    EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=org/repo \
    WORKFLOW_REF=org/repo/.github/workflows/tofu.yaml@refs/heads/main EXTRA_PATHS='iac/modules/**')"

# --- Input validation ------------------------------------------------------------

make_repo
valid() {
  output_of name validate-inputs.sh WORKING_DIR=iac/app VAR_FILES=deployments/prod.tfvars \
    APPLY_ENVIRONMENT=prod "$@"
}
expect "valid inputs pass, named after the last var file" prod "$(valid)"
expect "the name input wins" eastus "$(valid NAME=eastus)"
expect "no var files, no name" "" "$(valid VAR_FILES=)"

expect_refused "a missing module" "working-directory 'iac/nope' doesn't exist" \
  validate-inputs.sh WORKING_DIR=iac/nope APPLY_ENVIRONMENT=prod
expect_refused "a module without mise.toml" "has no mise.toml" \
  validate-inputs.sh WORKING_DIR=iac/other APPLY_ENVIRONMENT=prod
expect_refused "a missing var file" "'deployments/dev.tfvars' doesn't exist" \
  validate-inputs.sh WORKING_DIR=iac/app VAR_FILES=deployments/dev.tfvars APPLY_ENVIRONMENT=prod
expect_refused "an unusable name" "name 'prod east' can't be used" \
  validate-inputs.sh WORKING_DIR=iac/app "NAME=prod east" APPLY_ENVIRONMENT=prod
expect_refused "no apply environment" "apply-environment is empty" \
  validate-inputs.sh WORKING_DIR=iac/app
expect_refused "cost-estimate without its key" "infracost-api-key secret isn't passed" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod COST_ESTIMATE=true
expect "...but not on a fork PR, which gets no secrets" "" \
  "$(valid VAR_FILES= COST_ESTIMATE=true IS_FORK_PR=true)"
expect "...or on a Dependabot PR" "" \
  "$(valid VAR_FILES= COST_ESTIMATE=true IS_DEPENDABOT=true)"
expect_refused "policy without a policy" "neither policy-path nor policy-source" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod POLICY=true
expect_refused "a missing policy path" "policy-path: 'policy' doesn't exist" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod POLICY=true POLICY_PATH=policy
expect "...a policy source is enough" "" "$(valid VAR_FILES= POLICY=true POLICY_PATH= POLICY_SOURCE=git::x)"
expect_refused "...but a missing policy path still fails with one" "set policy-path to \"\"" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod POLICY=true POLICY_PATH=policy POLICY_SOURCE=git::x
expect_refused "extra-paths climbing out of the repository" "extra-paths: '../x' climbs out" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod EXTRA_PATHS=../x
expect_refused "a test filter matching nothing" "test-filter: 'tests/*.tftest.hcl' matches no file" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod TEST_FILTER='tests/*.tftest.hcl'
expect_refused "a client ID without a tenant" "azure-tenant-id isn't" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod AZURE_CLIENT_ID=c
expect_refused "a client secret without a client ID" "azure-client-id isn't" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod HAS_AZURE_CLIENT_SECRET=true
expect_refused "a plan identity without the apply identity" "plan-azure-client-id is set, but azure-client-id isn't" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod PLAN_AZURE_CLIENT_ID=p
expect_refused "a plan secret without a plan client ID" "plan-azure-client-id isn't" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod AZURE_CLIENT_ID=c AZURE_TENANT_ID=t \
  HAS_PLAN_AZURE_CLIENT_SECRET=true

cases=$((cases + 1))
if output_of name validate-inputs.sh WORKING_DIR=iac/app VAR_FILES=missing.tfvars \
  COST_ESTIMATE=true POLICY=true > /dev/null; then
  log_error "every problem is reported at once: it succeeded"
  failures=$((failures + 1))
elif grep -q "4 problem(s)" "$WORK/log"; then
  log_success "every problem is reported at once"
else
  log_error "every problem is reported at once: expected 4 problems:"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

# --- Azure credentials -----------------------------------------------------------

# Print what azure-env.sh exports, as sorted NAME=VALUE pairs on one line
azure() {
  local env_file="$WORK/github_env"
  : > "$env_file"
  env GITHUB_ACTIONS=true GITHUB_ENV="$env_file" "$@" "$SCRIPTS/azure-env.sh" > "$WORK/log" 2>&1 || return 1
  awk '/<<EOF_/ { split($0, a, "<<"); name = a[1]; getline; print name "=" $0 }' "$env_file" | sort | paste -sd' ' -
}

expect "no Azure identity: only Entra ID storage auth, on by default" \
  "ARM_STORAGE_USE_AZUREAD=true ARM_USE_AZUREAD=true" "$(azure ROLE=plan)"
expect "...which a caller can turn off" \
  "ARM_STORAGE_USE_AZUREAD=false ARM_USE_AZUREAD=false" "$(azure ROLE=plan AZURE_USE_AZUREAD=false)"
expect "OIDC without a client secret" \
  "ARM_CLIENT_ID=apply ARM_STORAGE_USE_AZUREAD=true ARM_SUBSCRIPTION_ID=s ARM_TENANT_ID=t ARM_USE_AZUREAD=true ARM_USE_OIDC=true" \
  "$(azure ROLE=apply AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_SUBSCRIPTION_ID=s)"
expect "a client secret instead of OIDC" \
  "ARM_CLIENT_ID=apply ARM_CLIENT_SECRET=shh ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true" \
  "$(azure ROLE=apply AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh)"
cases=$((cases + 1))
if grep -qxF '::add-mask::shh' "$WORK/log"; then
  log_success "the client secret is masked"
else
  log_error "the client secret is masked: no add-mask in the log"
  failures=$((failures + 1))
fi
expect "the plan job uses the apply identity by default" \
  "ARM_CLIENT_ID=apply ARM_CLIENT_SECRET=shh ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true" \
  "$(azure ROLE=plan AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh)"
expect "plan-azure-client-id switches the plan job's identity, as a pair (OIDC)" \
  "ARM_CLIENT_ID=read ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true ARM_USE_OIDC=true" \
  "$(azure ROLE=plan AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh PLAN_AZURE_CLIENT_ID=read)"
expect "...or with its own secret" \
  "ARM_CLIENT_ID=read ARM_CLIENT_SECRET=ro ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true" \
  "$(azure ROLE=plan AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh PLAN_AZURE_CLIENT_ID=read PLAN_AZURE_CLIENT_SECRET=ro)"
expect "the apply and test jobs ignore the plan identity" \
  "ARM_CLIENT_ID=apply ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true ARM_USE_OIDC=true" \
  "$(azure ROLE=test AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t PLAN_AZURE_CLIENT_ID=read)"
cases=$((cases + 1))
if azure ROLE=plan AZURE_CLIENT_ID=apply > /dev/null; then
  log_error "inconsistent Azure inputs fail the job: it succeeded"
  failures=$((failures + 1))
else
  log_success "inconsistent Azure inputs fail the job"
fi

# --- Plan names ------------------------------------------------------------------

# A call named after a module path, and "-" vs "/", used to sanitize to the
# same artifact name
first="$(output_of artifact-name names.sh WORKING_DIRECTORY=iac/identity DEPLOYMENT=tools APPLY_ENVIRONMENT=prod)"
second="$(output_of artifact-name names.sh WORKING_DIRECTORY=iac/identity/tools APPLY_ENVIRONMENT=prod)"
third="$(output_of artifact-name names.sh WORKING_DIRECTORY=iac-identity DEPLOYMENT=tools APPLY_ENVIRONMENT=prod)"
cases=$((cases + 1))
if [ -n "$first" ] && [ "$first" != "$second" ] && [ "$first" != "$third" ] && [ "$second" != "$third" ]; then
  log_success "plan artifact names never collide"
else
  log_error "plan artifact names never collide: got '${first}', '${second}', '${third}'"
  failures=$((failures + 1))
fi

# The default name is the var file's base name, so these two are both
# "prod": their var files keep them apart
key() {
  output_of key names.sh WORKING_DIRECTORY=iac/app DEPLOYMENT=prod APPLY_ENVIRONMENT=prod "$@"
}
east="$(key VAR_FILES=deployments/eastus/prod.tfvars)"
west="$(key VAR_FILES=deployments/westus/prod.tfvars)"
cases=$((cases + 1))
if [ -n "$east" ] && [ "$east" != "$west" ]; then
  log_success "calls whose var files share a name get their own key"
else
  log_error "calls whose var files share a name get their own key: got '${east}' and '${west}'"
  failures=$((failures + 1))
fi
expect "...which doesn't depend on how the list is spaced" "$east" \
  "$(key VAR_FILES=$'  deployments/eastus/prod.tfvars\n')"

expect "the title shows the call and its environment, always" \
  "OpenTofu: \`iac/app\` · \`prod\` → \`prod\`" \
  "$(output_of title names.sh WORKING_DIRECTORY=iac/app DEPLOYMENT=prod APPLY_ENVIRONMENT=prod)"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} OpenTofu script test(s) failed. Run tests/opentofu/scripts-test.sh to reproduce."
  exit 1
fi
log_success "All ${cases} OpenTofu script tests passed"
