#!/usr/bin/env bash
#
# Tests the OpenTofu workflows' own scripts, which run before anything is
# planned: change detection (changes.sh, with the watched-path rules from
# shared/scripts/common.sh), input validation
# (validate-inputs.sh, runners and the drift mode included), the Azure
# credentials mapping (azure-env.sh), the provider cache (provider-cache.sh),
# the plan names (names.sh), and the drift report (drift-report.sh, with a
# stubbed gh), plus two shared helpers the
# OpenTofu workflow depends on: the apply preflight's git fallback
# (apply-preflight.sh, with a stubbed gh) and scope_mise_to_module. Change
# detection and the preflight run in throwaway Git repositories, the way a
# pull_request run does. Run by pre-commit and CI.
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
#   ├── deployments/stg.tfvars    another deployment's var file
#   ├── deployments/prod.tfvars   this call's
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
  echo 'name = "x"' > iac/app/deployments/stg.tfvars
  echo 'name = "x"' > shared.tfvars
  for f in iac/app/modules/label iac/modules/shared iac/other; do
    echo 'output "x" { value = 1 }' > "$f/main.tf"
  done
  git add -A
  git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

# Usage: change <file>...   (creates missing files and directories)
change() {
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "$file")"
    echo '# change' >> "$file"
  done
  git add -A
  git commit -qm change
}

# Usage: rename <from> <to>   (git mv, then commit)
rename() {
  mkdir -p "$(dirname "$2")"
  git mv "$1" "$2"
  git commit -qm rename
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

# Several calls share a module, each with its own var files
make_repo
change iac/app/deployments/stg.tfvars
expect "another deployment's var file doesn't plan" false "$(changes)"
expect "...nor without var files of its own (OpenTofu doesn't load it)" false "$(changes VAR_FILES=)"
expect "...unless extra-paths names it" true "$(changes EXTRA_PATHS=iac/app/deployments/stg.tfvars)"
expect "...or a glob matches it" true "$(changes EXTRA_PATHS='iac/app/deployments/*.tfvars')"

make_repo
change iac/app/deployments/stg.tfvars.json
expect "...nor its .tfvars.json form" false "$(changes)"

make_repo
change iac/app/modules/label/example.tfvars
expect "...nor a var file anywhere else in the module" false "$(changes)"

make_repo
change iac/app/deployments/eastus/prod.tfvars
expect "a var file in a subdirectory plans its own call" true "$(changes VAR_FILES=deployments/eastus/prod.tfvars)"
expect "...but not a call with another file of the same name" false "$(changes)"

make_repo
change iac/app/deployments/stg.tfvars iac/app/main.tf
expect "another deployment's var file with a module change plans" true "$(changes)"

make_repo
change iac/app/deployments/stg.tfvars.example
expect "a file only named like a var file plans" true "$(changes)"

for auto in terraform.tfvars terraform.tfvars.json common.auto.tfvars common.auto.tfvars.json \
  tests/terraform.tfvars tests/unit.auto.tfvars; do
  make_repo
  change "iac/app/${auto}"
  expect "${auto}, which OpenTofu loads on its own, plans" true "$(changes)"
  expect "...also without var files" true "$(changes VAR_FILES=)"
done

make_repo
git rm -q iac/app/deployments/stg.tfvars
git commit -qm remove
expect "deleting another deployment's var file doesn't plan" false "$(changes)"

make_repo
git rm -q iac/app/deployments/prod.tfvars
git commit -qm remove
expect "deleting the call's var file plans" true "$(changes)"

make_repo
rename iac/app/deployments/prod.tfvars iac/app/deployments/production.tfvars
expect "renaming the call's var file plans (its old path changed)" true "$(changes)"

make_repo
rename iac/app/deployments/stg.tfvars iac/app/common.auto.tfvars
expect "renaming another var file to one OpenTofu loads plans" true "$(changes)"

make_repo
change iac/app/deployments/stg.tfvars
expect "a module at the repository root ignores other deployments' var files" false \
  "$(changes WORKING_DIR=. VAR_FILES=iac/app/deployments/prod.tfvars)"
change iac/other/main.tf
expect "...and plans for anything else" true "$(changes WORKING_DIR=. VAR_FILES=iac/app/deployments/prod.tfvars)"

expect_refused "extra-paths can't exclude" "starts with !" \
  changes.sh WORKING_DIR=iac/app EXTRA_PATHS='!iac/app/main.tf' EVENT_NAME=pull_request BASE_SHA="$BASE"

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
expect "the watched paths: the module, less other var files, then the var files, workflow and extra paths" \
  "iac/app !iac/app/**/*.tfvars !iac/app/**/*.tfvars.json iac/app/**/terraform.tfvars iac/app/**/terraform.tfvars.json iac/app/**/*.auto.tfvars iac/app/**/*.auto.tfvars.json iac/app/deployments/prod.tfvars .github/workflows/tofu.yaml iac/modules/**" \
  "$(output_of paths changes.sh WORKING_DIR=iac/app VAR_FILES=deployments/prod.tfvars \
    EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=org/repo \
    WORKFLOW_REF=org/repo/.github/workflows/tofu.yaml@refs/heads/main EXTRA_PATHS='iac/modules/**')"

# --- Watched path rules ----------------------------------------------------------

# Usage: rules_match <path> <entry>...   (prints true or false)
rules_match() {
  local path="$1" entry
  local -a rules=()
  shift
  for entry in "$@"; do
    rules+=("$(path_entry_rule "$entry")")
  done
  path_rules_match "$path" "${rules[@]+"${rules[@]}"}" && echo true || echo false
}

expect "rules: a directory entry matches what's under it" true "$(rules_match iac/app/main.tf iac/app)"
expect "rules: a ! entry excludes what's before it" false "$(rules_match iac/app/x.tfvars iac/app '!iac/app/**/*.tfvars')"
expect "rules: a later entry includes it again" true \
  "$(rules_match iac/app/x.tfvars iac/app '!iac/app/**/*.tfvars' iac/app/x.tfvars)"
expect "rules: a ! entry first excludes nothing that comes after it" true \
  "$(rules_match iac/app/x.tfvars '!iac/app/**/*.tfvars' iac/app)"
expect "rules: a ! entry with ./ is read like one without" false "$(rules_match iac/app/x.tfvars iac/app '!./iac/app/*.tfvars')"
expect "rules: nothing matched isn't watched" false "$(rules_match docs/x.md iac/app)"
cases=$((cases + 1))
if path_entry_rule '!../x' > /dev/null; then
  log_error "rules: a ! entry that climbs out of the repository: accepted"
  failures=$((failures + 1))
else
  log_success "rules: a ! entry that climbs out of the repository is refused"
fi

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
expect_refused "an integration test identity without the apply identity" "integration-test-azure-client-id is set, but azure-client-id isn't" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod INTEGRATION_TEST_AZURE_CLIENT_ID=i
expect_refused "an integration test secret without its client ID" "integration-test-azure-client-id isn't" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod AZURE_CLIENT_ID=c AZURE_TENANT_ID=t \
  HAS_INTEGRATION_TEST_AZURE_CLIENT_SECRET=true
expect "...but a consistent integration test identity passes" prod \
  "$(valid AZURE_CLIENT_ID=c AZURE_TENANT_ID=t INTEGRATION_TEST_AZURE_CLIENT_ID=i HAS_INTEGRATION_TEST_AZURE_CLIENT_SECRET=true)"
expect_refused "extra-paths can't start with !" "extra-paths: '!iac/app' starts with !" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod EXTRA_PATHS='!iac/app'
expect "runners: a label, an array of labels, a runner group" prod \
  "$(valid INTEGRATION_TEST_RUNS_ON=self-hosted PLAN_RUNS_ON='["self-hosted", "linux"]' \
    APPLY_RUNS_ON=$'{"group": "private-network",\n "labels": ["linux-x64"]}\n')"
expect_refused "a runner that isn't valid JSON" "plan-runs-on: '{\"group\": x}' isn't valid JSON" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod PLAN_RUNS_ON='{"group": x}'
expect_refused "a runner group with an unknown key" "apply-runs-on: '{\"grop\": \"g\"}' isn't a runner" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod APPLY_RUNS_ON='{"grop": "g"}'
expect_refused "a runner group whose labels aren't strings" "checks-runs-on: '{\"group\": \"g\", \"labels\": [1]}' isn't a runner" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod CHECKS_RUNS_ON='{"group": "g", "labels": [1]}'
expect_refused "a label with a space" "integration-test-runs-on: 'self hosted' isn't a label" \
  validate-inputs.sh WORKING_DIR=iac/app APPLY_ENVIRONMENT=prod INTEGRATION_TEST_RUNS_ON='self hosted'

# The apply identity doubling as the plan identity is allowed, with a warning
# Usage: expect_warned "<case name>" <yes|no> [VAR=value ...]
expect_warned() {
  local name="$1" want="$2" got=no
  shift 2
  cases=$((cases + 1))
  if ! valid AZURE_CLIENT_ID=c AZURE_TENANT_ID=t "$@" > /dev/null; then
    log_error "${name}: the inputs were refused"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
    return
  fi
  grep -qF "apply identity (azure-client-id) because plan-azure-client-id isn't set" "$WORK/log" && got=yes
  if [ "$got" == "$want" ]; then
    log_success "$name"
  else
    log_error "${name}: expected warning=${want}, got ${got}"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}
expect_warned "no plan identity or environment: passes, but warns" yes
expect_warned "...not with a plan identity" no PLAN_AZURE_CLIENT_ID=p
expect_warned "...and still with a plan environment, which isn't protection by itself" yes PLAN_ENVIRONMENT=prod-plan
expect_warned "...with a client secret, the risk is the secret" yes HAS_AZURE_CLIENT_SECRET=true
expect_warned "...not on a Dependabot PR, which isn't planned" no IS_DEPENDABOT=true
expect_warned "...not on a fork PR, which isn't planned" no IS_FORK_PR=true

# Integration tests running as the apply identity, ungated, warn too
# Usage: expect_test_warned "<case name>" <yes|no> [VAR=value ...]
expect_test_warned() {
  local name="$1" want="$2" got=no
  shift 2
  cases=$((cases + 1))
  if ! valid AZURE_CLIENT_ID=c AZURE_TENANT_ID=t PLAN_AZURE_CLIENT_ID=p "$@" > /dev/null; then
    log_error "${name}: the inputs were refused"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
    return
  fi
  grep -qF "Integration tests sign in with the apply identity" "$WORK/log" && got=yes
  if [ "$got" == "$want" ]; then
    log_success "$name"
  else
    log_error "${name}: expected warning=${want}, got ${got}"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}
expect_test_warned "integration tests as the apply identity, ungated: passes, but warns" yes INTEGRATION_TESTS=true
expect_test_warned "...not with their own identity" no INTEGRATION_TESTS=true INTEGRATION_TEST_AZURE_CLIENT_ID=i
expect_test_warned "...also with an environment, which only helps with reviewers" yes INTEGRATION_TESTS=true INTEGRATION_TEST_ENVIRONMENT=test
expect_test_warned "...not with integration tests off" no
expect_test_warned "...not on a Dependabot PR, which isn't planned" no INTEGRATION_TESTS=true IS_DEPENDABOT=true

# The drift workflow has no apply job, so no apply environment
drift_inputs() {
  output_of name validate-inputs.sh DRIFT=true WORKING_DIR=iac/app VAR_FILES=deployments/prod.tfvars "$@"
}
expect "drift: no apply environment needed, named after the last var file" prod "$(drift_inputs)"
expect_refused "drift: a missing var file is still refused" "'deployments/dev.tfvars' doesn't exist" \
  validate-inputs.sh DRIFT=true WORKING_DIR=iac/app VAR_FILES=deployments/dev.tfvars
expect_refused "drift: issues without a label" "issue-labels is empty, but issues is on" \
  validate-inputs.sh DRIFT=true WORKING_DIR=iac/app ISSUES=true ISSUE_LABELS=" , "
expect "drift: ...unless issues are off" "" "$(drift_inputs VAR_FILES= ISSUES=false ISSUE_LABELS=)"
expect "drift: a label list passes" prod "$(drift_inputs ISSUES=true ISSUE_LABELS='opentofu-drift, infra')"
expect_refused "drift: the Azure rules apply" "azure-tenant-id isn't" \
  validate-inputs.sh DRIFT=true WORKING_DIR=iac/app AZURE_CLIENT_ID=c

# Drift checks should plan as a read-only identity
# Usage: expect_drift_warned "<case name>" <yes|no> [VAR=value ...]
expect_drift_warned() {
  local name="$1" want="$2" got=no
  shift 2
  cases=$((cases + 1))
  if ! drift_inputs AZURE_CLIENT_ID=c AZURE_TENANT_ID=t "$@" > /dev/null; then
    log_error "${name}: the inputs were refused"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
    return
  fi
  grep -qF "Drift checks sign in with azure-client-id" "$WORK/log" && got=yes
  if [ "$got" == "$want" ]; then
    log_success "$name"
  else
    log_error "${name}: expected warning=${want}, got ${got}"
    sed 's/^/    /' "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}
expect_drift_warned "drift: no plan identity: passes, but warns" yes
expect_drift_warned "drift: ...not with a plan identity" no PLAN_AZURE_CLIENT_ID=p
expect_drift_warned "drift: ...even in an environment, which a scheduled run can't wait on" yes ENVIRONMENT=x PLAN_ENVIRONMENT=x

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
expect "the integration test job uses the apply identity by default" \
  "ARM_CLIENT_ID=apply ARM_CLIENT_SECRET=shh ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true" \
  "$(azure ROLE=test AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh)"
expect "integration-test-azure-client-id switches the test job's identity, as a pair (OIDC)" \
  "ARM_CLIENT_ID=tester ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true ARM_USE_OIDC=true" \
  "$(azure ROLE=test AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh INTEGRATION_TEST_AZURE_CLIENT_ID=tester)"
expect "...or with its own secret" \
  "ARM_CLIENT_ID=tester ARM_CLIENT_SECRET=tt ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true" \
  "$(azure ROLE=test AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t AZURE_CLIENT_SECRET=shh INTEGRATION_TEST_AZURE_CLIENT_ID=tester INTEGRATION_TEST_AZURE_CLIENT_SECRET=tt)"
expect "the plan and apply jobs ignore the integration test identity" \
  "ARM_CLIENT_ID=apply ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true ARM_USE_OIDC=true" \
  "$(azure ROLE=apply AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t INTEGRATION_TEST_AZURE_CLIENT_ID=tester)"
expect "...the plan job too" \
  "ARM_CLIENT_ID=apply ARM_STORAGE_USE_AZUREAD=true ARM_TENANT_ID=t ARM_USE_AZUREAD=true ARM_USE_OIDC=true" \
  "$(azure ROLE=plan AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t INTEGRATION_TEST_AZURE_CLIENT_ID=tester)"
cases=$((cases + 1))
if azure ROLE=test AZURE_CLIENT_ID=apply AZURE_TENANT_ID=t INTEGRATION_TEST_AZURE_CLIENT_SECRET=tt > /dev/null; then
  log_error "an integration test secret without its client ID fails the job: it succeeded"
  failures=$((failures + 1))
else
  log_success "an integration test secret without its client ID fails the job"
fi
cases=$((cases + 1))
if azure ROLE=plan AZURE_CLIENT_ID=apply > /dev/null; then
  log_error "inconsistent Azure inputs fail the job: it succeeded"
  failures=$((failures + 1))
else
  log_success "inconsistent Azure inputs fail the job"
fi

# --- Provider cache --------------------------------------------------------------

# Print what provider-cache.sh exports (TF_PLUGIN_CACHE_DIR) and outputs (dir)
provider_cache() {
  local env_file="$WORK/github_env"
  : > "$env_file"
  : > "$WORK/output"
  env GITHUB_ACTIONS=true GITHUB_ENV="$env_file" GITHUB_OUTPUT="$WORK/output" "$@" \
    "$SCRIPTS/provider-cache.sh" > "$WORK/log" 2>&1 || return 1
  awk '/<<EOF_/ { split($0, a, "<<"); name = a[1]; getline; print name "=" $0 }' "$env_file"
}

cache_dir="$WORK/cache/providers"
expect "the provider cache is created and exported to the job" \
  "TF_PLUGIN_CACHE_DIR=$cache_dir" "$(provider_cache CACHE_DIR="$cache_dir")"
cases=$((cases + 1))
if [ -d "$cache_dir" ] && [ "$(sed -n 's/^dir=//p' "$WORK/output")" == "$cache_dir" ]; then
  log_success "...as a directory, and its path is the step's output"
else
  log_error "...as a directory, and its path is the step's output: not created, or the wrong output"
  failures=$((failures + 1))
fi
expect "a relative cache directory is made absolute, since tofu runs from the module" \
  "TF_PLUGIN_CACHE_DIR=$WORK/relative-cache" \
  "$(cd "$WORK" && provider_cache CACHE_DIR=relative-cache)"
expect "an existing cache is kept as it is" "TF_PLUGIN_CACHE_DIR=$cache_dir" \
  "$(echo cached > "$cache_dir/provider"; provider_cache CACHE_DIR="$cache_dir")"
cases=$((cases + 1))
if [ "$(cat "$cache_dir/provider")" == "cached" ]; then
  log_success "...and its contents too"
else
  log_error "...and its contents too: they changed"
  failures=$((failures + 1))
fi
cases=$((cases + 1))
if provider_cache > /dev/null; then
  log_error "no cache directory is refused: it succeeded"
  failures=$((failures + 1))
else
  log_success "no cache directory is refused"
fi
cases=$((cases + 1))
make_repo
provider_cache CACHE_DIR="$cache_dir" WORKING_DIR=iac/app > /dev/null
if grep -qF "No .terraform.lock.hcl in iac/app" "$WORK/log"; then
  log_success "a module without a lock file is mentioned"
else
  log_error "a module without a lock file is mentioned: no note in the log"
  failures=$((failures + 1))
fi

# --- Drift report ----------------------------------------------------------------

# A stub gh that records each call (and the JSON body it was given, on one
# line) and answers the few reads the report makes:
#   GH_STUB_FIND     - the number of the deployment's open issue, if any
#   GH_STUB_RESOLVED - "true" if that issue carries the drift-resolved label
#   GH_STUB_MISSING_LABELS=1 - labels don't exist yet
#   GH_STUB_NO_BRANCH=1 - the default branch lookup fails
#   GH_STUB_DROP_LABEL=1 - a created issue comes back without its labels
#   GH_STUB_FAIL=1   - every call fails
mkdir -p "$WORK/driftbin"
cat > "$WORK/driftbin/gh" << 'STUB'
#!/usr/bin/env bash
args="$*"
echo "gh $args" >> "$GH_STUB_LOG"
for arg in "$@"; do
  if [ "$arg" == "-" ]; then
    echo "  body: $(jq -c . < /dev/stdin)" >> "$GH_STUB_LOG"
    break
  fi
done
if [ -n "${GH_STUB_FAIL:-}" ]; then
  echo "gh: HTTP 403" >&2
  exit 1
fi
case "$args" in
  *"repos/org/repo --jq .default_branch"*) [ -z "${GH_STUB_NO_BRANCH:-}" ] || exit 1; echo main ;;
  *--paginate*) echo "${GH_STUB_FIND:-}" ;;
  *'\(.number)'*) if [ -n "${GH_STUB_DROP_LABEL:-}" ]; then echo "42 false"; else echo "42 true"; fi ;;
  *"/labels/"*"--method"*) ;;
  *"/labels/"*) [ -z "${GH_STUB_MISSING_LABELS:-}" ] || exit 1 ;;
  *"/issues/"*"--jq"*) echo "${GH_STUB_RESOLVED:-false}" ;;
esac
STUB
chmod +x "$WORK/driftbin/gh"

printf '## Plan\n\n3 to add\n' > "$WORK/summary.md"

# Run drift-report.sh as the drift workflow's report step does; print what
# it outputs as "drift=<> issue=<>". Fails if the script did.
# Usage: drift_report [VAR=value ...]
drift_report() {
  local status=0
  : > "$WORK/gh.log"
  : > "$WORK/output"
  env PATH="$WORK/driftbin:$PATH" GH_STUB_LOG="$WORK/gh.log" GITHUB_OUTPUT="$WORK/output" \
    GH_TOKEN=t GITHUB_REPOSITORY=org/repo GITHUB_RUN_ID=9 GITHUB_REF_NAME=main \
    GITHUB_REF=refs/heads/main RUN_REF=refs/heads/main DEFAULT_BRANCH=main \
    KEY='iac/app:prod@abc' TITLE="OpenTofu: \`iac/app\` · \`prod\`" SUMMARY_FILE="$WORK/summary.md" \
    "$@" "$SCRIPTS/drift-report.sh" > "$WORK/log" 2>&1 || status=$?
  echo "drift=$(sed -n 's/^drift=//p' "$WORK/output") issue=$(sed -n 's/^issue=//p' "$WORK/output")"
  return "$status"
}

# Succeeds if the stub gh was called with / given the text (fixed string)
gh_called() {
  grep -qF -- "$1" "$WORK/gh.log"
}

# Usage: expect_gh "<case name>" <called|not-called> "<text>"
expect_gh() {
  local got=not-called
  cases=$((cases + 1))
  gh_called "$3" && got=called
  if [ "$got" == "$2" ]; then
    log_success "$1"
  else
    log_error "$1: expected gh to be ${2} with '${3}', it was ${got}:"
    sed 's/^/    /' "$WORK/gh.log" >&2
    failures=$((failures + 1))
  fi
}

# Usage: expect_drift_report "<case name>" "<drift=.. issue=..>" [VAR=value ...]
expect_drift_report() {
  local name="$1" want="$2" got status=0
  shift 2
  got="$(drift_report "$@")" || status=$?
  expect "$name" "$want" "$got"
  return 0
}

# Exit code mapping: 0 no drift, 2 drift, anything else an error
expect_drift_report "plan exit code 0 is no drift" "drift=false issue=" PLAN_EXIT_CODE=0
expect_drift_report "plan exit code 2 is drift" "drift=true issue=42" PLAN_EXIT_CODE=2
for code in 1 3 ""; do
  expect_drift_report "plan exit code '${code}' is an error" "drift=error issue=" PLAN_EXIT_CODE="$code"
  cases=$((cases + 1))
  if drift_report PLAN_EXIT_CODE="$code" > /dev/null; then
    log_error "plan exit code '${code}' fails the job: it succeeded"
    failures=$((failures + 1))
  elif [ ! -s "$WORK/gh.log" ] && grep -qF "Issues were left as they were" "$WORK/log"; then
    log_success "...which fails the job and leaves the issues alone, even an open one"
  else
    log_error "plan exit code '${code}' fails the job, leaving issues alone: failed differently"
    sed 's/^/    /' "$WORK/log" "$WORK/gh.log" >&2
    failures=$((failures + 1))
  fi
done
GH_STUB_FIND=7 drift_report PLAN_EXIT_CODE=1 > /dev/null || true
expect_gh "an error doesn't even look for the issue" not-called "gh"

# fail-on-drift
cases=$((cases + 1))
if drift_report PLAN_EXIT_CODE=2 FAIL_ON_DRIFT=true > /dev/null; then
  log_error "fail-on-drift fails the job on drift: it succeeded"
  failures=$((failures + 1))
elif [ "$(sed -n 's/^drift=//p' "$WORK/output")" == "true" ] && gh_called "POST repos/org/repo/issues"; then
  log_success "fail-on-drift fails the job on drift, after reporting it"
else
  log_error "fail-on-drift fails the job on drift, after reporting it: failed differently"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi
cases=$((cases + 1))
if drift_report PLAN_EXIT_CODE=0 FAIL_ON_DRIFT=true > /dev/null && drift_report PLAN_EXIT_CODE=2 > /dev/null; then
  log_success "...but no drift passes, and so does drift without it"
else
  log_error "...but no drift passes, and so does drift without it: failed"
  failures=$((failures + 1))
fi

# issues: false only reports
expect_drift_report "issues off: drift is only reported" "drift=true issue=" PLAN_EXIT_CODE=2 CREATE_ISSUES=false
expect_gh "...without touching GitHub" not-called "gh"

# Drift, no issue yet: one is opened
expect_drift_report "drift opens an issue" "drift=true issue=42" PLAN_EXIT_CODE=2
expect_gh "...found by the hidden marker among open issues with the first label" called \
  "gh api --paginate repos/org/repo/issues?state=open&labels=opentofu-drift&per_page=100"
expect_gh "...with the author and the marker in the filter" called 'github-actions[bot]'
expect_gh "...creating it" called "gh api --method POST repos/org/repo/issues --input - --jq"
expect_gh "...with the marker for its key" called '<!-- opentofu-drift:iac/app:prod@abc -->'
expect_gh "...the plan summary as its body" called '3 to add'
expect_gh "...titled after the deployment" called '"title":"OpenTofu drift: iac/app · prod"'
expect_gh "...and labelled" called '"labels":["opentofu-drift"]'
expect_gh "...without assignees by default" not-called '"assignees"'
expect_gh "...without creating labels that exist" not-called "--method POST repos/org/repo/labels"
drift_report PLAN_EXIT_CODE=2 ISSUE_LABELS="opentofu-drift, infra" ISSUE_ASSIGNEES="alice, bob" > /dev/null
expect_gh "labels and assignees come as lists" called '"labels":["opentofu-drift","infra"]'
expect_gh "...assignees too" called '"assignees":["alice","bob"]'
expect_gh "...checking the first label stuck, and it did" not-called "issues/42/labels"
drift_report PLAN_EXIT_CODE=2 GH_STUB_DROP_LABEL=1 > /dev/null
expect_gh "a label GitHub dropped is added to the new issue" called '{"labels":["opentofu-drift"]}'
expect_gh "...on that issue" called "gh api --method POST repos/org/repo/issues/42/labels --input -"
drift_report PLAN_EXIT_CODE=2 GH_STUB_MISSING_LABELS=1 > /dev/null
expect_gh "a missing label is created first" called "gh api --method POST repos/org/repo/labels -f name=opentofu-drift"

# issue-plan off: counts and addresses only
cat > "$WORK/full-summary.md" << 'SUMMARY'
### Plan: 1 to add

<details><summary>Resources (1)</summary>

| Action | Resource |
| --- | --- |
| create | `random_pet.this` |

</details>

<details><summary>Full plan</summary>

````diff
+ secret_value = "hunter2"
````

</details>
SUMMARY
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/full-summary.md" > /dev/null
expect_gh "the plan text is in the issue by default" called 'hunter2'
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/full-summary.md" ISSUE_PLAN=false > /dev/null
expect_gh "issue-plan off: the plan text is left out" not-called 'hunter2'
expect_gh "...keeping the counts" called '1 to add'
expect_gh "...the resource addresses" called 'random_pet.this'
expect_gh "...and a pointer to the run" called 'issue-plan is off'

# issue-plan off, against the real summary renderer (plan-summary.sh), so a
# change to its layout can't silently put the plan text in an issue
cat > "$WORK/plan.json" << 'PLANJSON'
{"resource_changes": [{"address": "azurerm_thing.main", "change": {"actions": ["create"]}}]}
PLANJSON
printf 'Terraform will perform:\n  # azurerm_thing.main will be created\n+ secret = "hunter2"\n' > "$WORK/plan.txt"
PLAN_EXIT_CODE=2 PLAN_JSON="$WORK/plan.json" PLAN_TEXT="$WORK/plan.txt" "$SCRIPTS/plan-summary.sh" > "$WORK/real-summary.md" 2> /dev/null
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/real-summary.md" > /dev/null
expect_gh "the real summary puts the plan text in the issue by default" called 'hunter2'
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/real-summary.md" ISSUE_PLAN=false > /dev/null
expect_gh "issue-plan off, real summary: no plan text" not-called 'hunter2'
expect_gh "...but the resource address" called 'azurerm_thing.main'
printf '### Plan: 1 to add\n\nsomething new\n+ secret = "hunter2"\n' > "$WORK/odd-summary.md"
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/odd-summary.md" ISSUE_PLAN=false > /dev/null
expect_gh "a summary without the full plan block fails closed: no plan text" not-called 'hunter2'
expect_gh "...keeping its heading" called '### Plan: 1 to add'
cases=$((cases + 1))
if grep -qF "format wasn't recognised" "$WORK/log"; then
  log_success "...and warning that the format wasn't recognised"
else
  log_error "...and warning that the format wasn't recognised: no warning"
  failures=$((failures + 1))
fi

# Only the default branch touches issues
expect_drift_report "a feature branch reports drift..." "drift=true issue=" PLAN_EXIT_CODE=2 RUN_REF=refs/heads/feature
expect_gh "...without any GitHub call" not-called "gh"
expect_drift_report "...even for an open issue and no drift" "drift=false issue=" \
  PLAN_EXIT_CODE=0 RUN_REF=refs/pull/1/merge GH_STUB_FIND=7
expect_gh "...resolving nothing" not-called "gh"
expect_drift_report "an event without the default branch looks it up, and opens the issue" "drift=true issue=42" \
  PLAN_EXIT_CODE=2 DEFAULT_BRANCH=
expect_gh "...with the API" called "gh api repos/org/repo --jq .default_branch"
expect_drift_report "...a feature branch still touches nothing" "drift=true issue=" \
  PLAN_EXIT_CODE=2 DEFAULT_BRANCH= RUN_REF=refs/heads/feature
expect_gh "...after the lookup only" not-called "issues"
cases=$((cases + 1))
if drift_report PLAN_EXIT_CODE=2 DEFAULT_BRANCH= GH_STUB_NO_BRANCH=1 > /dev/null; then
  log_error "a failed default branch lookup fails the job: it succeeded"
  failures=$((failures + 1))
elif grep -qF "Couldn't look up org/repo's default branch" "$WORK/log" && ! gh_called "issues"; then
  log_success "a failed default branch lookup fails the job, saying why, touching no issue"
else
  log_error "a failed default branch lookup fails the job: failed differently"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

# The body is kept under GitHub's limit
head -c 70000 /dev/zero | tr '\0' 'x' > "$WORK/big-summary.md"
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/big-summary.md" > /dev/null
posted_length="$(sed -n 's/^  body: //p' "$WORK/gh.log" | tail -n 1 | jq -r '.body | length')"
cases=$((cases + 1))
if [ "$posted_length" -lt 65536 ] && gh_called "truncated"; then
  log_success "a long summary is truncated to fit the issue body"
else
  log_error "a long summary is truncated to fit the issue body: ${posted_length} characters posted"
  failures=$((failures + 1))
fi
drift_report PLAN_EXIT_CODE=2 SUMMARY_FILE="$WORK/missing.md" > /dev/null
expect_gh "a missing summary is said in the body" called "The plan summary is missing"

# Drift, issue already open: updated in place, nobody notified
expect_drift_report "drift updates the open issue" "drift=true issue=7" PLAN_EXIT_CODE=2 GH_STUB_FIND=7
expect_gh "...by editing its body" called "gh api --method PATCH repos/org/repo/issues/7 --input -"
expect_gh "...not opening another" not-called "POST repos/org/repo/issues"
expect_gh "...or commenting" not-called "/comments"

# Drift back after it was marked resolved
expect_drift_report "drift on a resolved issue updates it" "drift=true issue=7" \
  PLAN_EXIT_CODE=2 GH_STUB_FIND=7 GH_STUB_RESOLVED=true
expect_gh "...removes the resolved label" called "gh api --method DELETE repos/org/repo/issues/7/labels/drift-resolved"
expect_gh "...and says the drift is back, once" called "Drift is back"
expect_gh "...after updating the body" called "gh api --method PATCH repos/org/repo/issues/7 --input -"

# No drift
expect_drift_report "no drift and no issue does nothing" "drift=false issue=" PLAN_EXIT_CODE=0
expect_gh "...but looking for one" called "--paginate"
expect_gh "...writing nothing" not-called "--method"
expect_drift_report "no drift resolves the open issue" "drift=false issue=7" PLAN_EXIT_CODE=0 GH_STUB_FIND=7
expect_gh "...with the resolved label" called '{"labels":["drift-resolved"]}'
expect_gh "...and one comment" called "No drift as of"
expect_gh "...never closing it" not-called "state=closed"
expect_gh "...by any other spelling" not-called '"state"'
expect_gh "...without touching its body" not-called "PATCH"
expect_drift_report "...a resolved issue isn't commented on again" "drift=false issue=7" \
  PLAN_EXIT_CODE=0 GH_STUB_FIND=7 GH_STUB_RESOLVED=true
expect_gh "...nor labelled" not-called "--method POST"

# A GitHub API failure fails the job, saying what to check
cases=$((cases + 1))
if drift_report PLAN_EXIT_CODE=2 GH_STUB_FAIL=1 > /dev/null; then
  log_error "an API failure fails the job: it succeeded"
  failures=$((failures + 1))
elif grep -qF "issues: write" "$WORK/log" && [ "$(sed -n 's/^drift=//p' "$WORK/output")" == "true" ]; then
  log_success "an API failure fails the job, saying what to check, with the result still output"
else
  log_error "an API failure fails the job, saying what to check: failed differently"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

# --- Context line ----------------------------------------------------------------

# The line under a PR comment's title, without its date. Usage: context [VAR=value ...]
context() {
  (
    unset GITHUB_REPOSITORY GITHUB_RUN_ID
    local kv
    for kv in "$@"; do declare -x "$kv"; done
    context_line | sed 's/ · [0-9-]* [0-9:]* UTC//'
  )
}
aaa="$(printf 'a%.0s' {1..40})"
bbb="$(printf 'b%.0s' {1..40})"
pr_line="$(context PR_NUMBER=5 HEAD_SHA="$aaa" TARGET_SHA="$bbb" TARGET_BRANCH=main)"
echo "$pr_line" > "$WORK/log"
expect "a PR's context line says what the plan is against" \
  "<sub>commit \`aaaaaaa\` · against \`main\` at \`bbbbbbb\`</sub>" "$pr_line"
cases=$((cases + 1))
if [[ "$pr_line" != *"merged into"* ]]; then
  log_success "...and doesn't claim a merge happened"
else
  log_error "...and doesn't claim a merge happened: '${pr_line}'"
  failures=$((failures + 1))
fi
expect "without a PR there is no 'against'" "<sub>commit \`aaaaaaa\`</sub>" \
  "$(context HEAD_SHA="$aaa" TARGET_SHA="$bbb")"

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

# --- Mise scoping ------------------------------------------------------------------

make_repo
trusted="$(cd iac/app && source "$REPO_ROOT/shared/scripts/common.sh" && scope_mise_to_module && echo "$MISE_TRUSTED_CONFIG_PATHS")"
expect "mise trusts only the module's own directory" "$(cd iac/app && pwd -P)" "$trusted"

# --- Apply preflight -------------------------------------------------------------

# A target branch that moved on by one commit, changing iac/app/main.tf and
# docs/readme.md, and a stub gh whose compare answer lists 300 unrelated
# files (the API's cap) -- so only git can tell what really changed.
PREFLIGHT="$REPO_ROOT/shared/scripts/apply-preflight.sh"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" << 'STUB'
#!/usr/bin/env bash
cat "$GH_STUB_RESPONSE"
STUB
chmod +x "$WORK/bin/gh"

make_origin() {
  make_repo
  git clone -q --bare . "$WORK/origin.git"
  git -C "$WORK/origin.git" config uploadpack.allowFilter true
  git -C "$WORK/origin.git" config uploadpack.allowAnySHA1InWant true
  git remote add origin "file://$WORK/origin.git"
  git fetch -q origin
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    echo '# moved on' >> "$f"
  done
  git add -A
  git commit -qm "moved on"
  git push -q origin main
}

compare_response() {
  jq -n --argjson n "$1" '{ahead_by: 1, files: [range($n) | {filename: "unrelated/f\(.).txt"}]}' > "$WORK/compare.json"
}

# Usage: preflight [VAR=value ...]
preflight() {
  : > "$WORK/output"
  env PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" GH_STUB_RESPONSE="$WORK/compare.json" \
    GH_TOKEN=secret-token GITHUB_REPOSITORY=org/repo TARGET_BRANCH=main TARGET_SHA="$BASE" \
    PREFLIGHT_PATHS=iac/app "$@" "$PREFLIGHT" > "$WORK/log" 2>&1
}

make_origin iac/app/main.tf docs/readme.md
compare_response 3
cases=$((cases + 1))
if preflight; then
  log_success "under 300 files, the API's list is used (git isn't asked)"
else
  log_error "under 300 files, the API's list is used: refused"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

# Usage: compare_files <file>...   (the compare API's answer listing them)
compare_files() {
  jq -n '{ahead_by: 1, files: [$ARGS.positional[] | {filename: .}]}' --args "$@" > "$WORK/compare.json"
}
OWN_VAR_FILE_ONLY='iac/app !iac/app/**/*.tfvars iac/app/deployments/prod.tfvars'

compare_files iac/app/deployments/stg.tfvars
cases=$((cases + 1))
if preflight PREFLIGHT_PATHS="$OWN_VAR_FILE_ONLY"; then
  log_success "an excluded file (another deployment's var file) doesn't make the plan stale"
else
  log_error "an excluded file (another deployment's var file) doesn't make the plan stale: refused"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

compare_files iac/app/deployments/prod.tfvars
expect_refused "...but a file included again after the exclusion does" "(iac/app/deployments/prod.tfvars)" \
  ../../shared/scripts/apply-preflight.sh PATH="$WORK/bin:$PATH" GH_STUB_RESPONSE="$WORK/compare.json" \
  GH_TOKEN=secret-token GITHUB_REPOSITORY=org/repo TARGET_BRANCH=main TARGET_SHA="$BASE" PREFLIGHT_PATHS="$OWN_VAR_FILE_ONLY"

jq -n '{ahead_by: 1, files: [{filename: "iac/other/main.tf", previous_filename: "iac/app/main.tf", status: "renamed"}]}' > "$WORK/compare.json"
expect_refused "a file renamed out of a watched path makes the plan stale" "(iac/app/main.tf)" \
  ../../shared/scripts/apply-preflight.sh PATH="$WORK/bin:$PATH" GH_STUB_RESPONSE="$WORK/compare.json" \
  GH_TOKEN=secret-token GITHUB_REPOSITORY=org/repo TARGET_BRANCH=main TARGET_SHA="$BASE" PREFLIGHT_PATHS=iac/app

compare_response 300
expect_refused "300 files: git finds the relevant change the API list cut off" \
  "Files this plan depends on changed on main since it was made (iac/app/main.tf)" \
  ../../shared/scripts/apply-preflight.sh PATH="$WORK/bin:$PATH" GH_STUB_RESPONSE="$WORK/compare.json" \
  GH_TOKEN=secret-token GITHUB_REPOSITORY=org/repo TARGET_BRANCH=main TARGET_SHA="$BASE" PREFLIGHT_PATHS=iac/app
# Neither the token nor its base64 form may reach the log, apart from the
# mask command that tells the runner to hide it (only emitted in Actions)
encoded_token="$(printf 'x-access-token:%s' secret-token | base64 | tr -d '\n')"
assert_token_unlogged() {
  cases=$((cases + 1))
  if grep -v '^::add-mask::' "$WORK/log" | grep -qF -e "secret-token" -e "$encoded_token"; then
    log_error "$1: the token (or its encoded form) was logged"
    failures=$((failures + 1))
  else
    log_success "$1"
  fi
}
assert_token_unlogged "...and the token never reaches the log"

# In Actions, the encoded credential is masked as a command of its own, never
# captured as if it were a changed file
cases=$((cases + 1))
if preflight GITHUB_ACTIONS=true PREFLIGHT_PATHS=. ; then
  log_error "300 files, in Actions: the relevant change went unnoticed"
  failures=$((failures + 1))
elif [ "$(grep -cxF "::add-mask::${encoded_token}" "$WORK/log")" -eq 1 ] \
  && ! grep -qF "since it was made (::add-mask" "$WORK/log" \
  && [ "$(grep -cF "$encoded_token" "$WORK/log")" -eq 1 ]; then
  log_success "300 files, in Actions: the encoded token is masked, and appears nowhere else"
else
  log_error "300 files, in Actions: the encoded token is not masked exactly once:"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

cases=$((cases + 1))
if preflight PREFLIGHT_PATHS=iac/other; then
  log_success "300 files: a change elsewhere doesn't stop the apply"
else
  log_error "300 files: a change elsewhere doesn't stop the apply: refused"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

# A shallow checkout, as actions/checkout makes by default
git clone -q --depth 1 "file://$WORK/origin.git" "$WORK/shallow"
cd "$WORK/shallow"
cases=$((cases + 1))
if preflight; then
  log_error "300 files, shallow checkout: the relevant change went unnoticed"
  failures=$((failures + 1))
elif grep -qF "(iac/app/main.tf)" "$WORK/log"; then
  log_success "300 files: a shallow checkout finds the relevant change"
else
  log_error "300 files, shallow checkout: refused, but not for the change:"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi
cases=$((cases + 1))
if preflight PREFLIGHT_PATHS=iac/other; then
  log_success "...and ignores a change elsewhere"
else
  log_error "...and ignores a change elsewhere: refused"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

cd "$WORK"
mkdir -p "$WORK/not-a-repo"
cd "$WORK/not-a-repo"
cases=$((cases + 1))
if preflight; then
  log_error "300 files without git: it succeeded"
  failures=$((failures + 1))
elif grep -qF "git couldn't list the changes" "$WORK/log"; then
  log_success "300 files without a usable checkout: refused, saying why"
  assert_token_unlogged "...and the token stays out of the log on that path too"
  preflight GITHUB_ACTIONS=true || true
  assert_token_unlogged "...also in Actions"
else
  log_error "300 files without a usable checkout: refused, but not saying why:"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

# A checkout whose origin can't be fetched from: git's own error is logged
git init -q "$WORK/bad-origin"
cd "$WORK/bad-origin"
git remote add origin "file://$WORK/does-not-exist.git"
cases=$((cases + 1))
if preflight; then
  log_error "300 files, unreachable origin: it succeeded"
  failures=$((failures + 1))
elif grep -qF "git said:" "$WORK/log"; then
  log_success "300 files, unreachable origin: refused, with git's error"
  assert_token_unlogged "...and the token stays out of that log too"
  preflight GITHUB_ACTIONS=true || true
  assert_token_unlogged "...also in Actions"
else
  log_error "300 files, unreachable origin: no git error logged:"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} OpenTofu script test(s) failed. Run tests/opentofu/scripts-test.sh to reproduce."
  exit 1
fi
log_success "All ${cases} OpenTofu script tests passed"
