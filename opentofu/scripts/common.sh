#!/usr/bin/env bash
# Common functions for the opentofu/* scripts: the shared library
# (shared/scripts/common.sh: logging, outputs, lists, mise, globs, markdown,
# GitHub comments), plus the OpenTofu and deployments sections below. Source
# it with:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=opentofu/scripts/common.sh
#   source "$SCRIPT_DIR/common.sh"

OPENTOFU_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$OPENTOFU_COMMON_DIR/../../shared/scripts/common.sh"

# --- OpenTofu -----------------------------------------------------------------

# Let `tofu init` fetch module sources from private GitHub repositories
# (git::https://github.com/..., git@github.com:...). Uses MODULES_GITHUB_TOKEN
# when set, otherwise GITHUB_TOKEN; a no-op without either (local runs use
# your own git credentials). The rewrite goes in a throwaway config file via
# GIT_CONFIG_GLOBAL, so the token never lands in a persistent config.
configure_git_github_auth() {
  local token="${MODULES_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ]; then
    return 0
  fi

  log_info "Configuring Git credentials for GitHub-hosted module sources..."
  local git_config
  git_config="$(mktemp)"
  export GIT_CONFIG_GLOBAL="$git_config"

  local server="${GITHUB_SERVER_URL:-https://github.com}"
  local host="${server#https://}"
  local authed="https://x-access-token:${token}@${host}/"
  git config --global url."${authed}".insteadOf "https://${host}/"
  git config --global --add url."${authed}".insteadOf "ssh://git@${host}/"
  git config --global --add url."${authed}".insteadOf "git@${host}:"
}

# Print the init arguments shared by plan and apply: -var-file for each line
# of VAR_FILES -- a deployment's .tfvars sets its backend's variables (its
# state key) -- and -lockfile=readonly when the module commits a lock file,
# so plan and apply use exactly the provider versions and checksums recorded
# there.
# One argument per line; read with mapfile.
tofu_init_args() {
  echo "-input=false"
  # Deployments of one module share its .terraform directory when run in the
  # same workspace (locally, or a reused runner); -reconfigure makes init use
  # this deployment's backend settings instead of refusing because the last
  # one's differ. It never migrates state.
  echo "-reconfigure"
  if [ -f .terraform.lock.hcl ]; then
    echo "-lockfile=readonly"
  fi
  # A module without deployments has no var files; pass terraform.tfvars
  # explicitly, which plan would auto-load, in case the backend reads it.
  local line var_files_list
  var_files_list="$(list_items "${VAR_FILES:-}")"
  if [ -z "$var_files_list" ] && [ -f terraform.tfvars ]; then
    echo "-var-file=terraform.tfvars"
  elif [ -z "$var_files_list" ] && [ -f terraform.tfvars.json ]; then
    echo "-var-file=terraform.tfvars.json"
  elif [ -n "$var_files_list" ]; then
    while IFS= read -r line; do
      echo "-var-file=${line}"
    done <<< "$var_files_list"
  fi
}

# Warn once per job when the root module has no lock file: providers then
# resolve to whatever is newest at init time.
warn_if_no_lock_file() {
  if [ ! -f .terraform.lock.hcl ]; then
    log_warn "No .terraform.lock.hcl in ${WORKING_DIR}: provider versions aren't locked. Run 'tofu init' (or 'tofu providers lock -platform=linux_amd64 ...') and commit the lock file so every run uses the same provider builds."
  fi
}

# --- Deployments --------------------------------------------------------------
#
# A deployment is one root module applied in one GitHub environment, with the
# variables and secrets its file declares. A root module has either:
#   - deployments/<name>.yaml files, one per deployment, in a flat
#     deployments/ directory, each with an optional deployments/<name>.tfvars
#     of the same name (its OpenTofu variables); or
#   - one deployment.yaml in the module root: the module deployed once, as
#     it is (OpenTofu still loads its terraform.tfvars).
# A module with neither is validated and tested, but never deployed.
#
# A deployment file (YAML) has these keys:
#   environment      - GitHub environment the apply job runs in (required)
#   plan-environment - GitHub environment the plan job runs in (optional)
#   env              - literal values to export, NAME: value (optional)
#   vars             - GitHub variables to export, by name (optional)
#   secrets          - GitHub secrets to export, by name (optional)
# vars and secrets entries are NAME, or EXPORT_NAME=GITHUB_NAME. Each
# resolves where the job runs: its environment, else the repository, else
# the organization (see shared/scripts/export-declared.sh).

DEPLOYMENTS_DIR="deployments"
ROOT_DEPLOYMENT_FILE="deployment.yaml"
DEPLOYMENT_NAME_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Print the deployment a path (relative to a root module) belongs to, if it's
# one of a deployment's own files -- deployments/<name>.yaml or
# deployments/<name>.tfvars -- whether or not it still exists. Prints
# nothing (and fails) for any other path.
deployment_of_file() {
  local file="$1" name
  [[ "$file" == "${DEPLOYMENTS_DIR}/"* ]] || return 1
  name="${file#"${DEPLOYMENTS_DIR}/"}"
  [[ "$name" == */* ]] && return 1
  case "$name" in
    *.yaml) echo "${name%.yaml}" ;;
    *.tfvars) echo "${name%.tfvars}" ;;
    *) return 1 ;;
  esac
}

# Print what's wrong with a root module's deployment files, one problem per
# line; nothing if the layout is valid. The layout couples each
# deployments/<name>.tfvars to its <name>.yaml, so anything that could break
# that coupling unnoticed is refused rather than ignored.
# Usage: deployment_layout_problems "<root module dir>"
deployment_layout_problems() {
  local dir="$1" file name
  local deployments="${dir}/${DEPLOYMENTS_DIR}"
  if [ -f "${dir}/deployment.yml" ]; then
    echo "${dir}/deployment.yml: name it deployment.yaml."
  fi
  [ -d "$deployments" ] || return 0
  while IFS= read -r file; do
    name="${file#"${deployments}/"}"
    case "$name" in
      */*)
        echo "${file}: deployments/ is flat: one <name>.yaml (and <name>.tfvars) per deployment. Move it up, e.g. to deployments/${name//\//-}."
        ;;
      *.yml) echo "${file}: name it ${name%.yml}.yaml." ;;
      *.tfvars.json) echo "${file}: deployments use .tfvars files. Convert it to ${name%.tfvars.json}.tfvars." ;;
      *.yaml | *.tfvars)
        name="${name%.yaml}"
        name="${name%.tfvars}"
        if ! [[ "$name" =~ $DEPLOYMENT_NAME_REGEX ]]; then
          echo "${file}: deployment names use letters, digits, '.', '_' and '-', starting with a letter or digit. Rename it."
        elif [[ "$file" == *.tfvars ]] && [ ! -f "${deployments}/${name}.yaml" ]; then
          echo "${file}: no ${name}.yaml next to it, so no deployment uses it. Add deployments/${name}.yaml (its environment, variables and secrets), or delete it."
        fi
        ;;
    esac
  done < <(find "$deployments" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.tfvars' -o -name '*.tfvars.json' \) | LC_ALL=C sort)
  if [ -f "${dir}/${ROOT_DEPLOYMENT_FILE}" ] && compgen -G "${deployments}/*.yaml" > /dev/null; then
    echo "${dir}: has both ${ROOT_DEPLOYMENT_FILE} and deployments/*.yaml. Keep deployments/ (one file per deployment), or ${ROOT_DEPLOYMENT_FILE} for the module deployed once as is."
  fi
}

# Print a root module's deployment names, one per line, sorted: its
# deployments/*.yaml, or "" (one empty line) for a module deployed as is
# through deployment.yaml. Nothing for a module without deployments.
# Usage: module_deployment_names "<root module dir>"
module_deployment_names() {
  local dir="$1" file
  if compgen -G "${dir}/${DEPLOYMENTS_DIR}/*.yaml" > /dev/null; then
    for file in "${dir}/${DEPLOYMENTS_DIR}"/*.yaml; do
      basename "$file" .yaml
    done | LC_ALL=C sort
  elif [ -f "${dir}/${ROOT_DEPLOYMENT_FILE}" ]; then
    echo ""
  fi
}

# Print one deployment of a root module as a compact JSON object, from its
# file, or fail with every problem in it logged:
#   name              - "" for a module deployed as is
#   file              - its deployment file, relative to the module
#   var_files         - deployments/<name>.tfvars if it exists, else ""
#   apply_environment - its environment
#   plan_environment  - its plan-environment, or ""
#   env_json          - its env, as a JSON object string ("{}" for none)
#   vars, secrets     - its vars and secrets, space-separated
#   preflight_paths   - PREFLIGHT_PATHS (default: the module): a change to
#                       any of them on the target branch makes a plan stale
# Usage: deployment_json "<root module dir>" "<name, or empty>"
deployment_json() {
  local dir="$1" name="$2" file var_files="" config problems problem name_to_check
  if [ -n "$name" ]; then
    file="${DEPLOYMENTS_DIR}/${name}.yaml"
    if [ -f "${dir}/${DEPLOYMENTS_DIR}/${name}.tfvars" ]; then
      var_files="${DEPLOYMENTS_DIR}/${name}.tfvars"
    fi
  else
    file="$ROOT_DEPLOYMENT_FILE"
  fi
  if [ ! -f "${dir}/${file}" ]; then
    log_error "${dir}/${file} doesn't exist. A deployment is a deployments/<name>.yaml file (or deployment.yaml in the module root)."
    return 1
  fi
  if ! config="$(yq -o=json '.' "${dir}/${file}" 2>&1)"; then
    log_error "${dir}/${file} isn't valid YAML: ${config##*$'\n'}"
    return 1
  fi

  problems="$(jq -r --arg file "${dir}/${file}" '
    def name_ok: test("^[A-Za-z_][A-Za-z0-9_]*$");
    def item_ok: test("^[A-Za-z_][A-Za-z0-9_]*(=[A-Za-z_][A-Za-z0-9_]*)?$");
    def env_ok: type == "string" and length > 0 and (test("\\s") | not);
    if type != "object" then "\($file): needs at least environment: <GitHub environment>."
    else
      ((keys - ["environment", "plan-environment", "env", "vars", "secrets"])[]
        | "\($file): unknown key \(.). Use environment, plan-environment, env, vars and secrets."),
      (if (.environment | env_ok) then empty
        else "\($file): environment must name the GitHub environment the apply job runs in (no spaces)." end),
      (if has("plan-environment") and (.["plan-environment"] | env_ok | not)
        then "\($file): plan-environment must name a GitHub environment (no spaces), or be left out." else empty end),
      (if has("env") and (.env | type) != "object" then "\($file): env must be a map of NAME: value."
        else (.env // {} | to_entries[]
          | if (.key | name_ok | not) then "\($file): env name \(.key) must match [A-Za-z_][A-Za-z0-9_]*."
            elif (.value | type) == "object" or (.value | type) == "array" or (.value == null)
              then "\($file): env \(.key) must be a single value (quote it if in doubt)."
            else empty end) end),
      (("vars", "secrets") as $k
        | if has($k) and (.[$k] | type) != "array" then "\($file): \($k) must be a list of names."
          else (.[$k] // [] | .[]
            | if (type == "string" and item_ok) then empty
              else "\($file): \($k) entry \(tojson) must be NAME, or EXPORT_NAME=GITHUB_NAME." end) end)
    end' <<< "$config")"
  if [ -n "$problems" ]; then
    while IFS= read -r problem; do
      log_error "$problem"
    done <<< "$problems"
    return 1
  fi

  # Exported names must be settable, and declared once
  problems="$(jq -r '[(.env // {} | keys[]), ((.vars // []) + (.secrets // []) | .[] | sub("=.*"; ""))]
    | group_by(.) | .[] | select(length > 1) | .[0]' <<< "$config")"
  if [ -n "$problems" ]; then
    log_error "${dir}/${file}: ${problems//$'\n'/, } declared more than once across env, vars and secrets. Keep one of each."
    return 1
  fi
  while IFS= read -r name_to_check; do
    [ -z "$name_to_check" ] && continue
    problem="$(env_name_problem "$name_to_check")"
    if [ -n "$problem" ]; then
      log_error "${dir}/${file}: ${problem}"
      return 1
    fi
  done < <(jq -r '(.env // {} | keys[]), ((.vars // []) + (.secrets // []) | .[] | sub("=.*"; ""))' <<< "$config")

  jq -c --arg name "$name" --arg file "$file" --arg var_files "$var_files" \
    --arg preflight "$(list_items "${PREFLIGHT_PATHS:-$dir}")" '
    {name: $name, file: $file, var_files: $var_files,
     apply_environment: .environment,
     plan_environment: (.["plan-environment"] // ""),
     env_json: (.env // {} | map_values(tostring) | tojson),
     vars: ((.vars // []) | join(" ")),
     secrets: ((.secrets // []) | join(" ")),
     preflight_paths: $preflight}' <<< "$config"
}

# Print deployments of a root module, one JSON object (see deployment_json)
# per line. NAMES lists the deployment names to print, space- or
# newline-separated; without NAMES, every deployment of the module. Fails if
# any is invalid, after logging every problem.
# Usage: NAMES="..." list_deployments "<root module dir>"
list_deployments() {
  local dir="$1" name failed=false
  local -a names=()
  if [ -n "$(list_items "${NAMES:-}")" ]; then
    mapfile -t names < <(list_items "$NAMES" | LC_ALL=C sort -u)
  else
    mapfile -t names < <(module_deployment_names "$dir")
  fi
  for name in "${names[@]+"${names[@]}"}"; do
    deployment_json "$dir" "$name" || failed=true
  done
  [ "$failed" = false ]
}
