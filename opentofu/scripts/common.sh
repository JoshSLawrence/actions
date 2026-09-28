#!/usr/bin/env bash
# Common functions for the opentofu/* action scripts: everything in
# shared/scripts/common.sh (logging, outputs, lists, mise, globs, markdown,
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

# Print the init arguments shared by plan and apply: -backend-config for each
# line of BACKEND_CONFIG (key=value, or a file such as a .tfbackend, relative
# to WORKING_DIR), -var-file for each line of VAR_FILES (OpenTofu supports
# variables in the backend block), and -lockfile=readonly when the module
# commits a lock file, so plan and apply use exactly the provider versions and
# checksums recorded there.
# One argument per line; read with mapfile.
tofu_init_args() {
  echo "-input=false"
  # Deployments of one module share its .terraform directory when run in the
  # same workspace (locally, or a reused runner); -reconfigure makes init use
  # this deployment's backend config instead of refusing because the last
  # one's differs. It never migrates state.
  echo "-reconfigure"
  if [ -f .terraform.lock.hcl ]; then
    echo "-lockfile=readonly"
  fi
  local line
  while IFS= read -r line; do
    echo "-backend-config=${line}"
  done < <(list_lines "${BACKEND_CONFIG:-}")
  # OpenTofu supports variables in the backend block, so pass var-files to init.
  # When VAR_FILES is empty (module without deployments), also check for
  # terraform.tfvars which OpenTofu would auto-load during plan/apply, but we
  # need to explicitly pass to init for backend variable resolution.
  local var_files_list
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
# A deployment is one root module applied with one .tfvars file: the same
# configuration deployed several times (dev/prod, per region, per customer)
# with different variables and state. Each deployment is named after its
# .tfvars file (deployments/prod.tfvars -> "prod"), and a .tfbackend file
# next to it with the same name (deployments/prod.tfbackend) is added to its
# backend config -- OpenTofu's own file for -backend-config values, so each
# deployment can keep its state apart. A root module without deployments is
# planned once, as it is.

# Print a deployment's name from its .tfvars path
deployment_name() {
  local name
  name="$(basename "$1")"
  name="${name%.json}"
  echo "${name%.tfvars}"
}

# Print one deployment of a root module as a compact JSON object:
#   name             - "" for a root module without deployments
#   var_files        - VAR_FILES plus the deployment's .tfvars (newline-
#                      separated, relative to the root module)
#   backend_config   - BACKEND_CONFIG, then the deployment's .tfbackend if
#                      there is one (one per line)
#   plan_environment, apply_environment
#                    - PLAN_ENVIRONMENT / APPLY_ENVIRONMENT with {deployment}
#                      replaced
#   preflight_paths  - PREFLIGHT_PATHS plus every var and backend file, as
#                      repository paths: a change to any of them on the
#                      target branch makes a plan stale
# Usage: deployment_json "<root module dir>" "<name>" "<.tfvars path or empty>"
deployment_json() {
  local dir="$1" name="$2" tfvars="$3"
  local var_files backend_config plan_environment apply_environment
  local backend_file="" file preflight

  var_files="$(list_items "${VAR_FILES:-}")"
  if [ -n "$tfvars" ]; then
    var_files="$(printf '%s\n%s' "$var_files" "$tfvars" | sed '/^$/d')"
    backend_file="${tfvars%.json}"
    backend_file="${backend_file%.tfvars}.tfbackend"
    [ -f "${dir}/${backend_file}" ] || backend_file=""
  fi

  backend_config="$(expand_deployment_placeholder backend-config "$(list_lines "${BACKEND_CONFIG:-}")" "$name" "$dir")" || return 1
  if [ -n "$backend_file" ]; then
    backend_config="$(printf '%s\n%s' "$backend_config" "$backend_file" | sed '/^$/d')"
  fi
  plan_environment="$(expand_deployment_placeholder plan-environment "${PLAN_ENVIRONMENT:-}" "$name" "$dir")" || return 1
  apply_environment="$(expand_deployment_placeholder apply-environment "${APPLY_ENVIRONMENT:-}" "$name" "$dir")" || return 1

  preflight="$(list_items "${PREFLIGHT_PATHS:-}")"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Only files: key=value backend settings aren't paths
    [ -f "${dir}/${file}" ] || continue
    file="$(normalize_path "${dir}/${file}")" || continue
    preflight="$(printf '%s\n%s' "$preflight" "$file")"
  done <<< "$(printf '%s\n%s' "$var_files" "$backend_config")"
  preflight="$(sed '/^$/d' <<< "$preflight" | sort -u)"

  jq -cn --arg name "$name" --arg var_files "$var_files" \
    --arg backend_config "$backend_config" --arg plan_environment "$plan_environment" \
    --arg apply_environment "$apply_environment" --arg preflight_paths "$preflight" \
    '{name: $name, var_files: $var_files, backend_config: $backend_config,
      plan_environment: $plan_environment, apply_environment: $apply_environment,
      preflight_paths: $preflight_paths}'
}

# Print a root module's deployments, one JSON object (see deployment_json)
# per line. DEPLOYMENTS lists .tfvars files relative to the root module,
# space- or newline-separated: globs (matched within the module, e.g.
# "deployments/*.tfvars") and/or plain paths (which may point outside it).
# Without DEPLOYMENTS, prints the single unnamed deployment. With DEPLOYMENTS
# matching nothing, prints nothing: the caller decides whether that's an
# error. Returns 1 on a missing plain path or two files with the same name.
# Also reads VAR_FILES, BACKEND_CONFIG, PLAN_ENVIRONMENT, APPLY_ENVIRONMENT
# and PREFLIGHT_PATHS (see deployment_json).
# Usage: list_deployments "<root module dir>"
list_deployments() {
  local dir="$1" pattern regex file name
  local -a files=()

  if [ -z "$(list_items "${DEPLOYMENTS:-}")" ]; then
    deployment_json "$dir" "" ""
    return
  fi

  while IFS= read -r pattern; do
    pattern="${pattern#./}"
    if [[ "$pattern" == *[*?]* ]]; then
      regex="$(glob_to_regex "$pattern")"
      while IFS= read -r file; do
        if [[ "$file" =~ $regex ]]; then
          files+=("$file")
        fi
      done < <(cd "$dir" && find . \( -name .terraform -o -name .git \) -prune -o \
        -type f \( -name '*.tfvars' -o -name '*.tfvars.json' \) -print | sed 's|^\./||')
    elif [ -f "${dir}/${pattern}" ]; then
      files+=("$pattern")
    else
      log_error "Deployment var file '${pattern}' not found in ${dir}. deployments paths are relative to the root module."
      return 1
    fi
  done < <(list_items "$DEPLOYMENTS")

  local -A seen=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    name="$(deployment_name "$file")"
    if [ -n "${seen[$name]+set}" ]; then
      log_error "Two deployments of ${dir} are named '${name}': ${seen[$name]} and ${file}. Deployments are named after their .tfvars file, so rename one."
      return 1
    fi
    seen["$name"]="$file"
    deployment_json "$dir" "$name" "$file" || return 1
  done < <(printf '%s\n' "${files[@]+"${files[@]}"}" | sort -u)
}
