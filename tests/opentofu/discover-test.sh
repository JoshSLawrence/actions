#!/usr/bin/env bash
#
# Tests what opentofu/scripts/discover.sh selects -- which root modules, and
# which of their deployments -- for a change, how it reads deployment files,
# and which layouts it refuses; and the plan names (names.sh). Each case
# builds a throwaway Git repository, commits a change on top of a base
# commit, and runs discovery the way a pull_request run does. Run by
# pre-commit and CI. Needs git, jq, yq.
#
# Layout of the test repository:
#
#   infra/
#   ├── app/                      root module, uses ./modules/label and
#   │   │                         ../modules/shared
#   │   ├── deployments/
#   │   │   ├── dev.yaml          no dev.tfvars
#   │   │   ├── prod-eu.tfvars
#   │   │   ├── prod-eu.yaml      plan-environment, env, vars, secrets
#   │   │   ├── prod-us.tfvars
#   │   │   └── prod-us.yaml
#   │   ├── main.tf
#   │   ├── mise.toml
#   │   ├── modules/label/main.tf child module of app (no mise.toml)
#   │   └── nested/               root module inside app, also uses
#   │       │                     ../modules/label
#   │       ├── deployments/
#   │       │   ├── sandbox.tfvars
#   │       │   └── sandbox.yaml
#   │       ├── main.tf
#   │       └── mise.toml
#   ├── deep/a/b/c/               root module deployed as is
#   │   ├── deployment.yaml
#   │   ├── main.tf
#   │   └── mise.toml
#   ├── modules/shared/main.tf    module outside every root module
#   └── plain/                    root module without deployments
#       ├── main.tf
#       └── mise.toml
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISCOVER="$REPO_ROOT/opentofu/scripts/discover.sh"
NAMES="$REPO_ROOT/opentofu/scripts/names.sh"
# shellcheck source=opentofu/scripts/common.sh
source "$REPO_ROOT/opentofu/scripts/common.sh"

require_tool git
require_tool jq
require_tool yq

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
cases=0

# Build the base repository in $WORK/repo and commit it
make_repo() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo"
  cd "$WORK/repo"
  git init -q -b main
  git config user.email test@example.com
  git config user.name test
  mkdir -p infra/app/deployments infra/app/modules/label infra/app/nested/deployments \
    infra/deep/a/b/c infra/modules/shared infra/plain
  printf '%s\n' 'module "label" { source = "./modules/label" }' \
    'module "shared" { source = "../modules/shared" }' > infra/app/main.tf
  echo 'module "label" { source = "../modules/label" }' > infra/app/nested/main.tf
  echo 'resource "terraform_data" "deep" {}' > infra/deep/a/b/c/main.tf
  echo 'resource "terraform_data" "plain" {}' > infra/plain/main.tf
  echo 'output "x" { value = 1 }' > infra/app/modules/label/main.tf
  echo 'output "x" { value = 1 }' > infra/modules/shared/main.tf
  for module in infra/app infra/app/nested infra/deep/a/b/c infra/plain; do
    printf '[tools]\nopentofu = "1.12.6"\n' > "$module/mise.toml"
  done
  echo 'environment: dev' > infra/app/deployments/dev.yaml
  cat > infra/app/deployments/prod-eu.yaml << 'EOF'
environment: prod
plan-environment: prod-plan
env:
  ARM_USE_OIDC: true
vars:
  - ARM_CLIENT_ID
  - ARM_TENANT_ID
secrets:
  - TF_ENCRYPTION
  - GITHUB_TOKEN=GH_PROVIDER_TOKEN
EOF
  echo 'environment: prod' > infra/app/deployments/prod-us.yaml
  echo 'environment: sandbox' > infra/app/nested/deployments/sandbox.yaml
  echo 'environment: deep' > infra/deep/a/b/c/deployment.yaml
  for file in app/deployments/prod-eu app/deployments/prod-us app/nested/deployments/sandbox; do
    echo 'name = "x"' > "infra/${file}.tfvars"
  done
  git add -A
  git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

# Commit whatever the case changed
commit_change() {
  git add -A
  git commit -qm change
}

# Run discover.sh as a pull_request run would (extra env as arguments), and
# print what it selected: "<module>=<deployment,...>" per selected module,
# space-separated ("" when nothing is). A module deployed as is shows
# "(root)"; one only validated and tested shows nothing after "=".
discover() {
  local output="$WORK/output"
  : > "$output"
  env SEARCH_ROOT=infra EVENT_NAME=pull_request BASE_SHA="$BASE" \
    GITHUB_OUTPUT="$output" "$@" "$DISCOVER" > "$WORK/log" 2>&1 || {
    echo "discover.sh failed:" >&2
    cat "$WORK/log" >&2
    return 1
  }
  sed -n 's/^matrix=//p' "$output" | jq -r '
    [.module[] | "\(.path)=\(.deployments | fromjson | map(if .name == "" then "(root)" else .name end) | join(","))"]
    | join(" ")'
}

# Print one output of the last discover run
output_of() {
  sed -n "s/^${1}=//p" "$WORK/output"
}

# Usage: expect "<case name>" "<expected>" "<actual>"
expect() {
  cases=$((cases + 1))
  if [ "$3" == "$2" ]; then
    log_success "$1"
  else
    log_error "$1: expected '$2', got '$3'"
    failures=$((failures + 1))
  fi
}

# Usage: expect_in_log "<case name>" "<text the last run logged>"
expect_in_log() {
  cases=$((cases + 1))
  if grep -qF -- "$2" "$WORK/log"; then
    log_success "$1"
  else
    log_error "$1: '$2' not in the log:"
    cat "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

# Usage: expect_refused "<case name>" "<text the refusal names>" [VAR=value ...]
expect_refused() {
  local name="$1" text="$2"
  shift 2
  cases=$((cases + 1))
  if discover "$@" > /dev/null 2>&1; then
    log_error "${name}: discovery succeeded"
    failures=$((failures + 1))
  elif grep -qF -- "$text" "$WORK/log"; then
    log_success "$name"
  else
    log_error "${name}: refused, but '${text}' isn't in the log:"
    cat "$WORK/log" >&2
    failures=$((failures + 1))
  fi
}

ALL_APP="infra/app=dev,prod-eu,prod-us"
EVERYTHING="${ALL_APP} infra/app/nested=sandbox infra/deep/a/b/c=(root) infra/plain="

# --- What a change selects -----------------------------------------------------

make_repo
echo 'name = "y"' > infra/app/deployments/prod-eu.tfvars
commit_change
expect "a changed .tfvars selects only its deployment" "infra/app=prod-eu" "$(discover)"

make_repo
echo 'plan-environment: prod-plan' >> infra/app/deployments/prod-us.yaml
commit_change
expect "a changed .yaml selects only its deployment" "infra/app=prod-us" "$(discover)"

make_repo
echo 'name = "y"' > infra/app/deployments/prod-us.tfvars
echo '# change' >> infra/app/deployments/dev.yaml
commit_change
expect "changes to several deployments select only those" "infra/app=dev,prod-us" "$(discover)"

make_repo
echo 'environment: staging' > infra/app/deployments/staging.yaml
commit_change
expect "an added deployment without a .tfvars selects only it" "infra/app=staging" "$(discover)"

make_repo
git rm -q infra/app/deployments/prod-us.tfvars
commit_change
expect "a deleted .tfvars still selects its deployment, now without it" "infra/app=prod-us" "$(discover)"

make_repo
git rm -q infra/app/deployments/prod-us.yaml infra/app/deployments/prod-us.tfvars
commit_change
expect "a deleted deployment selects nothing" "" "$(discover)"
expect_in_log "a deleted deployment is warned about" "infra/app/deployments/prod-us.yaml was deleted"

make_repo
git mv infra/app/deployments/prod-us.yaml infra/app/deployments/prod-west.yaml
git mv infra/app/deployments/prod-us.tfvars infra/app/deployments/prod-west.tfvars
commit_change
expect "a renamed deployment selects its new name" "infra/app=prod-west" "$(discover)"
expect_in_log "...and warns about its old one" "infra/app/deployments/prod-us.yaml was deleted"

make_repo
echo '# change' >> infra/app/main.tf
echo 'name = "y"' > infra/app/deployments/prod-eu.tfvars
commit_change
expect "a module change selects every deployment, a .tfvars change too" "$ALL_APP" "$(discover)"

make_repo
echo 'notes' > infra/app/deployments/README.md
commit_change
expect "another file in deployments/ selects every deployment" "$ALL_APP" "$(discover)"

make_repo
echo '# change' >> infra/app/modules/label/main.tf
commit_change
expect "a child module change selects its root module only" "$ALL_APP" "$(discover)"

make_repo
mkdir -p infra/app/tests
echo 'run "plan" {}' > infra/app/tests/main.tftest.hcl
commit_change
expect "a test change selects every deployment of its module" "$ALL_APP" "$(discover)"

make_repo
echo 'name = "y"' > infra/app/nested/deployments/sandbox.tfvars
commit_change
expect "a nested root module's deployment belongs to it" "infra/app/nested=sandbox" "$(discover)"

make_repo
echo '# change' >> infra/app/nested/main.tf
commit_change
expect "a nested root module's change selects it, not its parent" "infra/app/nested=sandbox" "$(discover)"

make_repo
echo '# change' >> infra/deep/a/b/c/main.tf
commit_change
expect "a module with deployment.yaml is deployed as is" "infra/deep/a/b/c=(root)" "$(discover)"

make_repo
echo '# change' >> infra/plain/main.tf
commit_change
expect "a module without deployment files is only validated and tested" "infra/plain=" "$(discover)"

make_repo
echo '# change' >> infra/modules/shared/main.tf
commit_change
expect "a module outside every root module selects nothing" "" "$(discover)"
expect "...unless shared-paths lists it: then everything" "$EVERYTHING" \
  "$(discover SHARED_PATHS='infra/modules/**')"

make_repo
echo 'x' > README.md
commit_change
expect "a change outside every module selects nothing" "" "$(discover)"

make_repo
mkdir -p .github/workflows && echo 'x' > .github/workflows/opentofu.yaml
git rm -q infra/app/deployments/dev.yaml
commit_change
expect "a shared path selects everything" "${EVERYTHING/dev,/}" \
  "$(discover SHARED_PATHS='.github/workflows/**')"
expect_in_log "...and a deleted deployment after it is still warned about" \
  "infra/app/deployments/dev.yaml was deleted"

make_repo
expect "a workflow_dispatch run selects everything" "$EVERYTHING" "$(discover EVENT_NAME=workflow_dispatch)"
expect "changed-only off selects everything" "$EVERYTHING" "$(discover CHANGED_ONLY=false)"
expect "modules selects every deployment of exactly those" "infra/app/nested=sandbox" \
  "$(discover MODULES=infra/app/nested)"

make_repo
echo '# change' >> infra/app/main.tf
commit_change
expect "exclude skips a module" "" "$(discover EXCLUDE='infra/app')"

# --- What deployment files resolve to ------------------------------------------

make_repo
discover MODULES=infra/app > /dev/null
expect "a deployment's file resolves to its settings" \
  'prod-eu|deployments/prod-eu.yaml|deployments/prod-eu.tfvars|prod|prod-plan|{"ARM_USE_OIDC":"true"}|ARM_CLIENT_ID ARM_TENANT_ID|TF_ENCRYPTION GITHUB_TOKEN=GH_PROVIDER_TOKEN' \
  "$(output_of matrix | jq -r '.module[0].deployments | fromjson | .[] | select(.name == "prod-eu")
    | [.name, .file, .var_files, .apply_environment, .plan_environment, .env_json, .vars, .secrets] | join("|")')"
expect "a deployment without a .tfvars has no var files" "" \
  "$(output_of matrix | jq -r '.module[0].deployments | fromjson | .[] | select(.name == "dev") | .var_files')"
expect "every environment the deployments use is listed" "dev prod prod-plan" "$(output_of environments)"

make_repo
discover MODULES=infra/deep/a/b/c > /dev/null
expect "deployment.yaml resolves to the module as is" "|deployment.yaml|deep" \
  "$(output_of matrix | jq -r '.module[0].deployments | fromjson | .[0] | [.name, .file, .apply_environment] | join("|")')"

# --- What's refused ------------------------------------------------------------

make_repo
echo 'name = "x"' > infra/app/deployments/qa.tfvars
commit_change
expect_refused "a .tfvars without its .yaml" "no qa.yaml next to it"

make_repo
mkdir -p infra/app/deployments/prod
echo 'environment: prod' > infra/app/deployments/prod/eu.yaml
commit_change
expect_refused "a deployment in a subdirectory" "e.g. to deployments/prod-eu.yaml"

make_repo
echo 'environment: qa' > infra/app/deployments/qa.yml
commit_change
expect_refused "a .yml deployment file" "name it qa.yaml"

make_repo
echo 'environment: qa' > "infra/app/deployments/east us.yaml"
commit_change
expect_refused "a deployment name with whitespace" "deployment names use letters"

make_repo
echo 'environment: qa' > infra/app/deployment.yaml
commit_change
expect_refused "deployment.yaml next to deployments/" "has both deployment.yaml and deployments/*.yaml"

make_repo
echo 'plan-environment: qa' > infra/app/deployments/dev.yaml
commit_change
expect_refused "a deployment without an environment" "deployments/dev.yaml: environment must name"

make_repo
printf 'environment: dev\nvariables:\n  - X\n' > infra/app/deployments/dev.yaml
commit_change
expect_refused "an unknown key" "unknown key variables"

make_repo
printf 'environment: dev\nenv:\n  PATH: /tmp\n' > infra/app/deployments/dev.yaml
commit_change
expect_refused "a name that controls the runner" "'PATH' controls the runner"

make_repo
printf 'environment: dev\nenv:\n  ARM_CLIENT_ID: x\nvars:\n  - ARM_CLIENT_ID\n' > infra/app/deployments/dev.yaml
commit_change
expect_refused "a name declared twice" "ARM_CLIENT_ID declared more than once"

make_repo
printf 'environment: dev\nsecrets:\n  - not a name\n' > infra/app/deployments/dev.yaml
commit_change
expect_refused "a malformed secrets entry" "must be NAME, or EXPORT_NAME=GITHUB_NAME"

# --- Plan names ----------------------------------------------------------------

# Print one output of names.sh. Usage: name_of <output> [VAR=value ...]
name_of() {
  local field="$1" output="$WORK/output"
  shift
  : > "$output"
  env GITHUB_OUTPUT="$output" "$@" "$NAMES" > "$WORK/log" 2>&1 || return 1
  sed -n "s/^${field}=//p" "$output"
}

# A deployment and a nested root module of the same name, and "-" vs "/",
# used to sanitize to the same artifact name
first="$(name_of artifact-name WORKING_DIRECTORY=iac/identity DEPLOYMENT=tools APPLY_ENVIRONMENT=prod)"
second="$(name_of artifact-name WORKING_DIRECTORY=iac/identity/tools APPLY_ENVIRONMENT=prod)"
third="$(name_of artifact-name WORKING_DIRECTORY=iac-identity DEPLOYMENT=tools APPLY_ENVIRONMENT=prod)"
cases=$((cases + 1))
if [ -n "$first" ] && [ "$first" != "$second" ] && [ "$first" != "$third" ] && [ "$second" != "$third" ]; then
  log_success "plan artifact names never collide"
else
  log_error "plan artifact names never collide: got '${first}', '${second}', '${third}'"
  failures=$((failures + 1))
fi

expect "the title shows the deployment and its environment, always" \
  "OpenTofu: \`iac/app\` · \`prod\` → \`prod\`" \
  "$(name_of title WORKING_DIRECTORY=iac/app DEPLOYMENT=prod APPLY_ENVIRONMENT=prod)"

if [ "$failures" -gt 0 ]; then
  log_error "${failures} of ${cases} discovery test(s) failed. Run tests/opentofu/discover-test.sh to reproduce."
  exit 1
fi
log_success "All ${cases} discovery tests passed"
