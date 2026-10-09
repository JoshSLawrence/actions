#!/usr/bin/env bash
#
# Builds a SQL project (SDK-style, Microsoft.Build.Sql) into its dacpac. Runs
# offline: it needs no credentials and changes nothing, so it's safe to run
# locally and on PRs from forks.
#
#   WORKING_DIR=database/core sqlproject/scripts/build.sh
#
# A report of what a deployment would do never shows the project's pre- and
# post-deployment scripts, so the build also decides whether they count as a
# change (see "Deployment scripts" in sqlproject/README.md): it compares them
# with a build of the base commit, which on a pull request is what is
# deployed.
#
# Environment variables:
#   WORKING_DIR        - the SQL project's folder, with its own mise.toml
#                        pinning dotnet (required)
#   OUTPUT_DIR         - where the dacpac goes (default:
#                        $RUNNER_TEMP/sqlproject-dacpac)
#   DEPLOYMENT_SCRIPTS - "changed" (default): compare with SCRIPTS_BASE;
#                        "always": count them as changed whenever there are any
#   SCRIPTS_BASE       - a commit SHA to build and compare with (the checkout
#                        needs that commit: fetch-depth 0), or "none"
#                        (default): no comparison, so scripts count as changed
#   WORK_DIR           - scratch directory (default:
#                        $RUNNER_TEMP/sqlproject-build-work)
#
# Outputs:
#   dacpac-dir                 - absolute path of OUTPUT_DIR: the dacpac (and
#                                any dacpac it references), build.json and
#                                deployment-scripts.json
#   dacpac-name                - e.g. core.dacpac
#   dacpac-sha256              - digest of that dacpac
#   deployment-scripts-changed - "true" if the project has deployment scripts
#                                that count as changed
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=sqlproject/scripts/sqlproject.sh
source "$SCRIPT_DIR/sqlproject.sh"

# Telemetry off, unless the caller chose otherwise
export DOTNET_CLI_TELEMETRY_OPTOUT="${DOTNET_CLI_TELEMETRY_OPTOUT:-1}"
export DOTNET_NOLOGO="${DOTNET_NOLOGO:-1}"
export DACFX_TELEMETRY_OPTOUT="${DACFX_TELEMETRY_OPTOUT:-1}"

ensure_mise
require_tool jq
require_tool unzip

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
OUTPUT_DIR="${OUTPUT_DIR:-$TMP_ROOT/sqlproject-dacpac}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/sqlproject-build-work}"
DEPLOYMENT_SCRIPTS="${DEPLOYMENT_SCRIPTS:-changed}"
SCRIPTS_BASE="${SCRIPTS_BASE:-none}"
log_config WORKING_DIR OUTPUT_DIR DEPLOYMENT_SCRIPTS SCRIPTS_BASE

case "$DEPLOYMENT_SCRIPTS" in
  changed | always) ;;
  *)
    log_error "deployment-scripts '${DEPLOYMENT_SCRIPTS}' isn't valid. Use changed (compare with the base commit) or always."
    exit 1
    ;;
esac
if [ "$SCRIPTS_BASE" != none ] && ! [[ "$SCRIPTS_BASE" =~ ^[0-9a-f]{7,64}$ ]]; then
  log_error "scripts-base '${SCRIPTS_BASE}' isn't a commit SHA or none. Pass the base commit's SHA, or none to skip the comparison."
  exit 1
fi

rm -rf "$OUTPUT_DIR" "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
BASE_TREE=""
cleanup() {
  if [ -n "$BASE_TREE" ]; then
    git worktree remove --force "$BASE_TREE" > /dev/null 2>&1 || true
    git worktree prune > /dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cd_working_dir
require_mise_tool dotnet

# Build the project in the current directory into a directory, keeping only
# its dacpacs (a referenced dacpac must travel with the project's). Prints the
# project's dacpac name.
# Usage: build_here "<output dir>"
build_here() {
  local target_dir="$1" project name
  project="$(sql_find_project)" || return 1

  log_cmd dotnet build "$project" -c Release -nologo -o "$target_dir"
  # No -warnaserror: the SDK warns whenever a newer Microsoft.Build.Sql exists
  if ! mise exec -- dotnet build "$project" -c Release -nologo -o "$target_dir" >&2; then
    log_error "The project didn't build. Fix the errors above (T-SQL model or code analysis errors, or SDK restore errors), then push."
    return 1
  fi

  name="$(mise exec -- dotnet msbuild "$project" -getProperty:SqlTargetName -p:Configuration=Release 2> /dev/null)" || name=""
  # Older MSBuilds print JSON for -getProperty; newer ones the bare value
  if [[ "$name" == "{"* ]]; then
    name="$(jq -r '.Properties.SqlTargetName // empty' <<< "$name")"
  fi
  name="$(tr -d '[:space:]' <<< "$name")"
  if [ -z "$name" ] || [ ! -f "$target_dir/${name}.dacpac" ]; then
    log_error "The build didn't produce a dacpac${name:+ named ${name}.dacpac} in ${target_dir}. Check the project builds with the Microsoft.Build.Sql SDK ('<Sdk Name=\"Microsoft.Build.Sql\" ...>') and that SqlTargetName, if you set it, names the output."
    return 1
  fi
  find "$target_dir" -type f ! -name '*.dacpac' -delete
  find "$target_dir" -mindepth 1 -type d -empty -delete
  echo "${name}.dacpac"
}

log_step "Build the project"
dacpac_name="$(build_here "$OUTPUT_DIR")" || exit 1
dacpac="$OUTPUT_DIR/$dacpac_name"
dacpac_sha256="$(file_sha256 "$dacpac")"
log_success "Built ${dacpac_name} (sha256 ${dacpac_sha256})"

log_step "Deployment scripts"
scripts="$(sql_dacpac_scripts "$dacpac")"
has_scripts="$(jq -r '(.pre_sha256 != null) or (.post_sha256 != null)' <<< "$scripts")"
base_scripts='{"pre_sha256": null, "post_sha256": null}'
changed=false
why="the project has no deployment scripts"
if [ "$has_scripts" = true ]; then
  if [ "$DEPLOYMENT_SCRIPTS" = always ]; then
    changed=true
    why="deployment-scripts is always"
  elif [ "$SCRIPTS_BASE" = none ]; then
    changed=true
    why="there is no base to compare with"
  else
    # Where the project is in the repository, to find it in the base commit
    prefix="$(git rev-parse --show-prefix)"
    BASE_TREE="$WORK_DIR/base-tree"
    changed=true
    why="the base commit ${SCRIPTS_BASE:0:7} couldn't be built, so they count as changed"
    if ! git cat-file -e "${SCRIPTS_BASE}^{commit}" 2> /dev/null; then
      log_warn "Commit ${SCRIPTS_BASE:0:7} isn't in this checkout, so the deployment scripts count as changed. Check out with fetch-depth: 0 so the comparison can build the base commit."
    elif ! git worktree add --detach "$BASE_TREE" "$SCRIPTS_BASE" > /dev/null 2>&1; then
      log_warn "Couldn't check out ${SCRIPTS_BASE:0:7} to compare deployment scripts, so they count as changed."
    elif [ ! -d "$BASE_TREE/${prefix}" ]; then
      why="the project doesn't exist in the base commit ${SCRIPTS_BASE:0:7}"
      log_warn "${WORKING_DIR} doesn't exist in ${SCRIPTS_BASE:0:7} (a new project), so its deployment scripts count as changed."
    else
      log_info "Building ${SCRIPTS_BASE:0:7} to compare deployment scripts"
      set +e
      base_name="$(
        cd "$BASE_TREE/${prefix}" && scope_mise_to_module && build_here "$WORK_DIR/base-out"
      )"
      base_status=$?
      set -e
      if [ "$base_status" -ne 0 ] || [ ! -f "$WORK_DIR/base-out/${base_name}" ]; then
        log_warn "The base commit ${SCRIPTS_BASE:0:7} didn't build, so the deployment scripts count as changed."
      else
        base_scripts="$(sql_dacpac_scripts "$WORK_DIR/base-out/${base_name}")"
        if [ "$scripts" = "$base_scripts" ]; then
          changed=false
          why="they are the same as in the base commit ${SCRIPTS_BASE:0:7}"
        else
          why="they differ from the base commit ${SCRIPTS_BASE:0:7}"
        fi
      fi
    fi
  fi
fi
log_info "Deployment scripts: ${why} (changed: ${changed})"

jq -n --arg mode "$DEPLOYMENT_SCRIPTS" --arg base "$SCRIPTS_BASE" --arg why "$why" \
  --argjson changed "$changed" --argjson scripts "$scripts" --argjson base_scripts "$base_scripts" '
  {mode: $mode, base: $base, pre_sha256: $scripts.pre_sha256, post_sha256: $scripts.post_sha256,
   base_pre_sha256: $base_scripts.pre_sha256, base_post_sha256: $base_scripts.post_sha256,
   changed: $changed, why: $why}' > "$OUTPUT_DIR/deployment-scripts.json"
jq -n --arg dacpac "$dacpac_name" --arg sha256 "$dacpac_sha256" '{dacpac: $dacpac, sha256: $sha256}' > "$OUTPUT_DIR/build.json"

if [ "$has_scripts" != true ]; then
  scripts_summary="none"
elif [ "$changed" = true ]; then
  scripts_summary="changed (${why})"
else
  scripts_summary="unchanged (${why})"
fi
{
  echo "### 🏗️ SQL project: \`${WORKING_DIR}\`"
  echo ""
  echo "Built \`${dacpac_name}\` (sha256 \`${dacpac_sha256:0:12}\`); deployment scripts: ${scripts_summary}."
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output dacpac-dir "$OUTPUT_DIR"
set_output dacpac-name "$dacpac_name"
set_output dacpac-sha256 "$dacpac_sha256"
set_output deployment-scripts-changed "$([ "$has_scripts" = true ] && echo "$changed" || echo false)"
log_summary "Built ${dacpac_name}"
