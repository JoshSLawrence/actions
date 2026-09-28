#!/usr/bin/env bash
# Common functions for the opentofu/* action scripts. Source it with:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=opentofu/scripts/common.sh
#   source "$SCRIPT_DIR/common.sh"
#
# Every script also runs outside GitHub Actions (for debugging against a local
# checkout): outputs and summaries are then just logged.

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
log_notice() {
  echo -e "${BLUE}[NOTE]${NC} $1"
  if is_github_actions; then
    echo "::notice::$1"
  fi
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
  if is_github_actions; then
    echo "::warning::$1"
  fi
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  if is_github_actions; then
    echo "::error::$1"
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

# cd into WORKING_DIR (required)
cd_working_dir() {
  require_env "WORKING_DIR" "Set the working-directory input to the root module to run in."
  if ! cd "${WORKING_DIR}"; then
    log_error "Could not cd into working directory '${WORKING_DIR}' (from $PWD). Check the working-directory input is relative to the repository root and the directory exists."
    exit 1
  fi
  log_info "Working directory: ${WORKING_DIR}"
}

ensure_mise() {
  if ! command_exists mise; then
    log_error "mise is not installed or not on PATH. Run the opentofu/setup action earlier in the job."
    exit 1
  fi
}

# Fail unless mise resolves a version for a tool in the current directory. The
# setup action installs a fallback version for every tool a job needs, so
# this only fails if setup wasn't run, or was run without that tool.
# Usage: require_mise_tool "<mise tool name>"
require_mise_tool() {
  local tool="$1"
  if [ -z "$(mise current "$tool" 2> /dev/null)" ]; then
    log_error "No version of $tool is available in ${WORKING_DIR:-$PWD}. Add '$tool' to the opentofu/setup action's tools input (the reusable workflow does this for enabled checks), or pin it in your mise.toml."
    exit 1
  fi
}

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
# line of BACKEND_CONFIG (key=value, or a file path relative to WORKING_DIR),
# and -lockfile=readonly when the module commits a lock file, so plan and
# apply use exactly the provider versions and checksums recorded there.
# One argument per line; read with mapfile.
tofu_init_args() {
  echo "-input=false"
  if [ -f .terraform.lock.hcl ]; then
    echo "-lockfile=readonly"
  fi
  local line
  while IFS= read -r line; do
    echo "-backend-config=${line}"
  done < <(list_lines "${BACKEND_CONFIG:-}")
}

# Warn once per job when the root module has no lock file: providers then
# resolve to whatever is newest at init time.
warn_if_no_lock_file() {
  if [ ! -f .terraform.lock.hcl ]; then
    log_warn "No .terraform.lock.hcl in ${WORKING_DIR}: provider versions aren't locked. Run 'tofu init' (or 'tofu providers lock -platform=linux_amd64 ...') and commit the lock file so every run uses the same provider builds."
  fi
}
