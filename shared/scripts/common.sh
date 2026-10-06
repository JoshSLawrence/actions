#!/usr/bin/env bash
# The shared library: generic functions every area's scripts use
# (opentofu/*, datafactory/*, synapse/*, arm/*, shared/*, .github/scripts/*),
# in sections: logging, preconditions and step outputs, lists, the working
# directory and mise, paths and globs, markdown summaries, and GitHub
# comments/issues. Nothing area-specific belongs here: that goes in the
# area's own helpers (opentofu/scripts/common.sh, arm/scripts/arm.sh), which
# source this. Source it with:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=shared/scripts/common.sh
#   source "$SCRIPT_DIR/../../shared/scripts/common.sh"
#
# Every script also runs outside GitHub Actions (for debugging against a
# local checkout): outputs and summaries are then just logged.

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

# Print the SHA-256 of a string. Usage: text_sha256 "<text>"
text_sha256() {
  if command_exists sha256sum; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

# Print an artifact name for a key that must be unique within a run (e.g.
# "<stack>:<deployment>:<environment>"). Artifact names can't contain
# " : < > | * ? \ / or CR/LF, so the key is made readable by replacing those,
# which can map two keys to one name ("a/b" and "a-b"); a digest of the
# exact key keeps every name distinct.
# Usage: artifact_name "<prefix>" "<key>"
artifact_name() {
  local readable digest
  readable="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '-')"
  digest="$(text_sha256 "$2")"
  echo "${1}-${readable}-${digest:0:12}"
}

# Mask a value in the rest of the job's log. The runner decodes %25, %0D and
# %0A in a workflow command's data, so they're encoded first (as the Actions
# toolkit's setSecret does): otherwise a value containing "%25" would mask
# the decoded text, not the value as written. Outside Actions: nothing.
# Usage: mask_value "<value>"
mask_value() {
  local value="$1"
  if ! is_github_actions || [ -z "$value" ]; then
    return 0
  fi
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  echo "::add-mask::${value}"
}

# Print one SHA-256 for a whole directory: the digest of its files' relative
# paths and digests, in a fixed order, so it changes if any file is added,
# removed, renamed or edited. Usage: dir_sha256 "<dir>"
dir_sha256() {
  local dir="$1" file
  (
    cd "$dir" || exit 1
    while IFS= read -r file; do
      printf '%s  %s\n' "$(file_sha256 "$file")" "$file"
    done < <(find . -type f | LC_ALL=C sort)
  ) > "${TMPDIR:-/tmp}/dir_sha256.$$" || return 1
  file_sha256 "${TMPDIR:-/tmp}/dir_sha256.$$"
  rm -f "${TMPDIR:-/tmp}/dir_sha256.$$"
}

# --- Job environment ---------------------------------------------------------

# Export NAME=VALUE for the rest of the job through $GITHUB_ENV, with a random
# heredoc delimiter so a value can't end the assignment early and inject
# further variables. Values may span lines. Outside Actions: nothing.
# Usage: export_job_env "<name>" "<value>"
export_job_env() {
  local delimiter
  if [ -z "${GITHUB_ENV:-}" ]; then
    return 0
  fi
  delimiter="EOF_$(openssl rand -hex 16)"
  {
    echo "${1}<<${delimiter}"
    echo "${2}"
    echo "${delimiter}"
  } >> "$GITHUB_ENV"
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
# name=value parameters). Blank lines and # comments are skipped.
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
# scope_mise_to_module). "Module" here is whatever directory pins its own
# tools: an OpenTofu root module, a factory or workspace folder.
cd_working_dir() {
  require_env "WORKING_DIR" "Set the working-directory input to the directory to run in (e.g. the root module or factory folder)."
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
  local nowhere="/nonexistent/actions-mise"
  MISE_CEILING_PATHS="$(cd .. && pwd -P)"
  export MISE_CEILING_PATHS
  export MISE_CONFIG_DIR="$nowhere"
  export MISE_GLOBAL_CONFIG_FILE="$nowhere/config.toml"
  export MISE_SYSTEM_CONFIG_DIR="$nowhere"
  export MISE_SYSTEM_CONFIG_FILE="$nowhere/config.toml"
}

ensure_mise() {
  if ! command_exists mise; then
    log_error "mise is not installed or not on PATH. Run the shared/setup action earlier in the job."
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

# Print an anchored regex for one entry of a list of watched paths, so change
# detection and the apply preflight read entries the same way: an entry with
# * or ? is a glob (see glob_to_regex), anything else a directory (or file)
# and everything under it. A leading ./ is ignored. Fails if the entry climbs
# out of the repository. Usage: path_entry_regex "<entry>"
path_entry_regex() {
  local entry="${1#./}" path
  if [[ "$entry" == *[*?]* ]]; then
    glob_to_regex "$entry"
  else
    path="$(normalize_path "$entry")" || return 1
    dir_regex "$path"
  fi
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

# --- Markdown summaries -------------------------------------------------------

# One line saying what was planned and where the run is, so a comment that's
# been updated several times still says which push it describes. Reads
# HEAD_SHA, TARGET_BRANCH, TARGET_SHA and PR_NUMBER (all optional).
context_line() {
  local repo_url=""
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    repo_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"
  fi

  commit_ref() {
    if [ -n "$repo_url" ]; then
      printf "[\`%s\`](%s/commit/%s)" "${1:0:7}" "$repo_url" "$1"
    else
      printf "\`%s\`" "${1:0:7}"
    fi
  }

  local parts=()
  local head="${HEAD_SHA:-${GITHUB_SHA:-}}"
  [ -n "$head" ] && parts+=("commit $(commit_ref "$head")")
  # PR runs plan GitHub's merge of the PR into the target branch, not the PR
  # branch on its own -- say so, since that's what an apply would deploy.
  if [ -n "${PR_NUMBER:-}" ] && [ -n "${TARGET_SHA:-}" ]; then
    parts+=("merged into \`${TARGET_BRANCH:-main}\` at $(commit_ref "$TARGET_SHA")")
  fi
  if [ -n "$repo_url" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    parts+=("[run #${GITHUB_RUN_NUMBER:-$GITHUB_RUN_ID}](${repo_url}/actions/runs/${GITHUB_RUN_ID})")
  fi
  parts+=("$(date -u '+%Y-%m-%d %H:%M UTC')")

  local line="" part
  for part in "${parts[@]}"; do
    line="${line:+$line · }$part"
  done
  echo "<sub>$line</sub>"
}

# Print a file in a collapsible fenced block, truncated to MAX_PLAN_CHARS
# (default 40000; at a line boundary) with a pointer to the full output in
# the run log. A four-backtick fence, so a ``` inside the file can't close it
# early. Usage: collapsible_block "<summary>" "<language>" "<file>"
collapsible_block() {
  local summary="$1" language="$2" file="$3"
  local max="${MAX_PLAN_CHARS:-40000}" size
  size=$(wc -c < "$file" | tr -d ' ')

  echo "<details><summary>${summary}</summary>"
  echo ""
  echo "\`\`\`\`${language}"
  if [ "$size" -gt "$max" ]; then
    head -c "$max" "$file" | sed '$d'
    echo "... truncated (${size} characters) -- see the run log for the full output"
  else
    cat "$file"
  fi
  echo "\`\`\`\`"
  echo ""
  echo "</details>"
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
