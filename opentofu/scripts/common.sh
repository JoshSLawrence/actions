#!/usr/bin/env bash
# Common functions for the opentofu/* action scripts, in sections: logging,
# preconditions and step outputs, lists, the working directory and mise,
# paths and globs, GitHub comments/issues, OpenTofu, and deployments.
# Source it with:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=opentofu/scripts/common.sh
#   source "$SCRIPT_DIR/common.sh"
#
# Every script also runs outside GitHub Actions (for debugging against a local
# checkout): outputs and summaries are then just logged.

# --- Logging ------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_START_TIME=${EPOCHSECONDS:-$(date +%s)}

is_github_actions() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

# Notices, warnings and errors are also emitted as workflow commands, so they
# show up as annotations on the run and the PR instead of only in the log.
# The commands go to stderr (the runner reads both streams), so a helper
# whose stdout is captured -- e.g. an issue body -- doesn't swallow them.
log_notice() {
  echo -e "${BLUE}[NOTE]${NC} $1"
  if is_github_actions; then
    echo "::notice::$1" >&2
  fi
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
  if is_github_actions; then
    echo "::warning::$1" >&2
  fi
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  if is_github_actions; then
    echo "::error::$1" >&2
  fi
}

log_debug() {
  echo -e "${BLUE}[DEBUG]${NC} $1" >&2
}

log_step() {
  echo ""
  echo -e "${CYAN}========================================${NC}"
  echo -e "${CYAN}== ${1}${NC}"
  echo -e "${CYAN}========================================${NC}"
}

# Log the command about to run. To stderr, so it can't pollute captured output.
log_cmd() {
  echo -e "${GRAY}> $*${NC}" >&2
}

# Usage: log_config "VAR1" "VAR2" ...
log_config() {
  local max_len=0 var_name
  for var_name in "$@"; do
    ((${#var_name} > max_len)) && max_len=${#var_name}
  done
  for var_name in "$@"; do
    printf "  ${BOLD}%-${max_len}s${NC} = %s\n" "$var_name" "${!var_name:-<not set>}"
  done
}

format_duration() {
  local seconds=$1
  if ((seconds < 60)); then
    echo "${seconds}s"
  elif ((seconds < 3600)); then
    echo "$((seconds / 60))m $((seconds % 60))s"
  else
    echo "$((seconds / 3600))h $((seconds % 3600 / 60))m $((seconds % 60))s"
  fi
}

log_summary() {
  local message="${1:-Script completed}"
  local now=${EPOCHSECONDS:-$(date +%s)}
  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}== ${message}${NC}"
  echo -e "${GREEN}== Total time: $(format_duration $((now - SCRIPT_START_TIME)))${NC}"
  echo -e "${GREEN}========================================${NC}"
}

# --- Preconditions, inputs and outputs ----------------------------------------

command_exists() {
  command -v "$1" &> /dev/null
}

# Usage: require_tool "<command>" ["<display name>"]
require_tool() {
  local cmd="$1"
  local name="${2:-$cmd}"
  if ! command_exists "$cmd"; then
    log_error "$name is not installed or not on PATH. It ships with GitHub-hosted runners; on a self-hosted runner, install $name and retry."
    exit 1
  fi
}

# Usage: require_env "VAR_NAME" ["hint on how to set it"]
require_env() {
  local name="$1"
  local hint="${2:-}"
  if [ -z "${!name:-}" ]; then
    log_error "$name is not set.${hint:+ $hint}"
    exit 1
  fi
}

# True for the usual spellings of a boolean input's "on" value
is_true() {
  case "${1:-}" in
    true | TRUE | True | 1 | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Set a step output. Outside GitHub Actions the value is just logged.
# Usage: set_output "name" "value"
set_output() {
  local name="$1"
  local value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  else
    log_debug "output: ${name}=${value}"
  fi
}

# Append markdown to the job summary (stdin). Outside GitHub Actions: discard.
append_step_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat >> "$GITHUB_STEP_SUMMARY"
  else
    cat > /dev/null
  fi
}

# Print a file's SHA-256 (sha256sum on Linux runners, shasum on macOS)
file_sha256() {
  if command_exists sha256sum; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# --- Lists (inputs are space- or newline-separated) ---------------------------

# Print the non-empty, non-comment lines of a newline- (or space-) separated
# list input, one per line, trimmed. Usage: list_items "$INPUT"
list_items() {
  local -a items=()
  local item
  # read -a splits on IFS (spaces, tabs, newlines) without glob expansion;
  # -d '' reads the whole input, and returns 1 at EOF, which is expected.
  read -r -d '' -a items <<< "${1:-}" || true
  for item in "${items[@]+"${items[@]}"}"; do
    [[ "$item" == \#* ]] && continue
    echo "$item"
  done
}

# Like list_items, but one item per line: items may contain spaces (e.g.
# backend-config values). Blank lines and # comments are skipped.
list_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    echo "$line"
  done <<< "${1:-}"
}

# --- Working directory and mise -----------------------------------------------

# cd into WORKING_DIR (required) and scope mise to the module (see
# scope_mise_to_module)
cd_working_dir() {
  require_env "WORKING_DIR" "Set the working-directory input to the root module to run in."
  if ! cd "${WORKING_DIR}"; then
    log_error "Could not cd into working directory '${WORKING_DIR}' (from $PWD). Check the working-directory input is relative to the repository root and the directory exists."
    exit 1
  fi
  log_info "Working directory: ${WORKING_DIR}"
  scope_mise_to_module
}

# Every root module pins its own tools in its own mise config (its
# mise.toml), and only those are installed or used for it:
# - Stopping mise's config search at the module's parent directory shuts out
#   parents, e.g. the repository root's dev tools. The ceiling must be a
#   physical path (mise compares resolved paths), and must be the parent: a
#   ceiling at the module itself would hide the module's own config too.
# - Pointing the global and system config at a directory that doesn't exist
#   shuts out a runner's (or your machine's) ~/.config/mise and /etc/mise.
#   Installed tools are unaffected: they live in mise's data directory.
scope_mise_to_module() {
  local nowhere="/nonexistent/opentofu-actions-mise"
  MISE_CEILING_PATHS="$(cd .. && pwd -P)"
  export MISE_CEILING_PATHS
  export MISE_CONFIG_DIR="$nowhere"
  export MISE_GLOBAL_CONFIG_FILE="$nowhere/config.toml"
  export MISE_SYSTEM_CONFIG_DIR="$nowhere"
  export MISE_SYSTEM_CONFIG_FILE="$nowhere/config.toml"
}

ensure_mise() {
  if ! command_exists mise; then
    log_error "mise is not installed or not on PATH. Run the opentofu/setup action earlier in the job."
    exit 1
  fi
}

# Hint for a tool the module's mise config doesn't pin
mise_pin_hint() {
  local tool="$1"
  echo "Pin it in ${WORKING_DIR:-this module}'s own mise.toml (e.g. run 'mise use ${tool}@<version>' there). Only the module's config counts: tools pinned in parent directories, like the repository root, aren't used."
}

# Fail unless the module's mise config pins a tool. A check whose tool isn't
# pinned fails rather than skips: otherwise deleting e.g. trivy from a
# module's mise.toml would silently disable its security scan.
# Usage: require_mise_tool "<mise tool name>"
require_mise_tool() {
  local tool="$1"
  if [ -z "$(mise current "$tool" 2> /dev/null)" ]; then
    log_error "$tool isn't pinned for ${WORKING_DIR:-$PWD}. $(mise_pin_hint "$tool")"
    exit 1
  fi
}

# --- Paths and globs ----------------------------------------------------------

# Print a glob as an anchored extended regex, with GitHub's `paths:` filter
# semantics: `*` matches within one path segment, `**` across segments, and
# `**/` also matches no directory at all. Matching globs through a regex
# (`[[ $path =~ $regex ]]`) avoids unquoted pattern expansions.
glob_to_regex() {
  local glob="$1" out="" c i
  for ((i = 0; i < ${#glob}; i++)); do
    c="${glob:i:1}"
    case "$c" in
      '*')
        if [ "${glob:i+1:1}" = "*" ]; then
          if [ "${glob:i+2:1}" = "/" ]; then
            out+="(.*/)?"
            i=$((i + 2))
          else
            out+=".*"
            i=$((i + 1))
          fi
        else
          out+="[^/]*"
        fi
        ;;
      '?') out+="[^/]" ;;
      '.' | '+' | '(' | ')' | '{' | '}' | '|' | '^' | '$' | '[' | ']' | \\) out+="\\${c}" ;;
      *) out+="$c" ;;
    esac
  done
  printf '^%s$' "$out"
}

# Print an anchored regex matching a directory and everything under it ("."
# matches everything). The directory must not contain glob characters.
dir_regex() {
  if [ "$1" = "." ]; then
    printf '^.*$'
    return
  fi
  local regex
  regex="$(glob_to_regex "$1")"
  printf '%s(/.*)?$' "${regex%\$}"
}

# True if a path matches any glob in a space-/newline-separated list
# Usage: matches_any_glob "<path>" "<globs>"
matches_any_glob() {
  local path="$1" pattern regex
  while IFS= read -r pattern; do
    regex="$(glob_to_regex "$pattern")"
    if [[ "$path" =~ $regex ]]; then
      return 0
    fi
  done < <(list_items "${2:-}")
  return 1
}

# Print the absolute path of a file (which may not exist yet) in an existing
# directory, so it stays valid after a cd. Usage: abs_path "<path>"
abs_path() {
  local dir
  dir="$(cd "$(dirname "$1")" && pwd)" || return 1
  echo "${dir}/$(basename "$1")"
}

# Resolve . and .. in a relative path without touching the filesystem
# ("a/./b/../c" -> "a/c", "" -> "."). Fails if it climbs above its start.
normalize_path() {
  local -a parts=() out=()
  local part joined
  IFS=/ read -r -a parts <<< "$1"
  for part in "${parts[@]+"${parts[@]}"}"; do
    case "$part" in
      "" | .) ;;
      ..)
        if [ ${#out[@]} -eq 0 ]; then
          return 1
        fi
        unset 'out[${#out[@]}-1]'
        ;;
      *) out+=("$part") ;;
    esac
  done
  if [ ${#out[@]} -eq 0 ]; then
    echo "."
  else
    joined="$(printf '%s/' "${out[@]}")"
    echo "${joined%/}"
  fi
}

# --- GitHub comments and issues -----------------------------------------------

# GitHub rejects comment and issue bodies over 65536 characters
GITHUB_BODY_LIMIT=65000

# Truncate a markdown file in place, if needed, so that a body built around
# it (with up to 2000 characters more) fits GitHub's limit. The note it adds
# says where the full text is.
# Usage: fit_github_body "<file>" "<where the full text is, as markdown>"
fit_github_body() {
  local file="$1" where="$2" size keep
  size=$(wc -m < "$file" | tr -d ' ')
  keep=$((GITHUB_BODY_LIMIT - 2000))
  if [ "$size" -le "$keep" ]; then
    return 0
  fi
  log_warn "The summary is ${size} characters, too long for GitHub; posting the first ${keep}. The rest is in ${where}."
  {
    head -c "$keep" "$file"
    echo ""
    echo ""
    echo "_... truncated: see ${where} for the rest._"
  } > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

# Print the number/id of the oldest item in a (paginated) GitHub API list --
# comments, issues -- posted by AUTHOR whose body starts with MARKER. Only
# AUTHOR's items count, so nobody can hijack an update by quoting the marker.
# Empty if there's none.
# Usage: gh_find_by_marker "<api path>" "<author login>" "<marker>" "<id field>"
gh_find_by_marker() {
  local path="$1" author marker filter ids
  author="$(jq -rn --arg v "$2" '$v | tojson')"
  marker="$(jq -rn --arg v "$3" '$v | tojson')"
  filter=".[] | select(.user.login == ${author} and ((.body // \"\") | startswith(${marker}))) | .${4}"
  # Not piped into `head`: that could kill gh mid-pagination
  ids="$(gh api --paginate "$path" --jq "$filter")"
  echo "${ids%%$'\n'*}"
}

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
  else
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

# Replace "{deployment}" in a setting with the deployment's name. Settings
# that use it (e.g. an apply-environment of "{deployment}") need a named
# deployment, so a root module without deployments is an error.
# Usage: expand_deployment_placeholder <setting> <value> <deployment> <dir>
expand_deployment_placeholder() {
  local setting="$1" value="$2" name="$3" dir="$4"
  if [[ "$value" == *"{deployment}"* ]] && [ -z "$name" ]; then
    log_error "${setting} uses {deployment}, but ${dir} has no deployments (.tfvars files matching the deployments input), so there's no name to put there."
    return 1
  fi
  echo "${value//"{deployment}"/$name}"
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
