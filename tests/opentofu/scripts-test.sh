#!/usr/bin/env bash
#
# Tests the OpenTofu workflow's own scripts, which run before anything is
# planned: change detection (changes.sh), input validation
# (validate-inputs.sh, runners included), the Azure credentials mapping
# (azure-env.sh), and the plan names (names.sh), plus two shared helpers the
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
  grep -qF "Plans sign in with the apply identity" "$WORK/log" && got=yes
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
expect_warned "...not with a plan environment" no PLAN_ENVIRONMENT=prod-plan
expect_warned "...not on a fork PR, which isn't planned" no IS_FORK_PR=true

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

compare_response 300
expect_refused "300 files: git finds the relevant change the API list cut off" \
  "Files this plan depends on changed on main since it was made (iac/app/main.tf)" \
  ../../shared/scripts/apply-preflight.sh PATH="$WORK/bin:$PATH" GH_STUB_RESPONSE="$WORK/compare.json" \
  GH_TOKEN=secret-token GITHUB_REPOSITORY=org/repo TARGET_BRANCH=main TARGET_SHA="$BASE" PREFLIGHT_PATHS=iac/app
cases=$((cases + 1))
if grep -q "secret-token" "$WORK/log"; then
  log_error "the token never reaches the log: it was logged"
  failures=$((failures + 1))
else
  log_success "...and the token never reaches the log"
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
git -C "$WORK/shallow" fetch -q --depth 1 origin "$BASE"
cd "$WORK/shallow"
cases=$((cases + 1))
if preflight PREFLIGHT_PATHS=iac/other; then
  log_success "300 files: works in a shallow checkout"
else
  log_error "300 files: works in a shallow checkout: refused"
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
else
  log_error "300 files without a usable checkout: refused, but not saying why:"
  sed 's/^/    /' "$WORK/log" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} OpenTofu script test(s) failed. Run tests/opentofu/scripts-test.sh to reproduce."
  exit 1
fi
log_success "All ${cases} OpenTofu script tests passed"
