#!/usr/bin/env bash
#
# Finds the root modules under SEARCH_ROOT and decides which to run, for the
# reusable workflow's matrix. A root module is a directory with *.tf files
# and its own mise config (mise.toml or .mise.toml) -- every root module pins
# its own tools, so the mise config doubles as the marker. That covers a
# single-root repository (SEARCH_ROOT is the module) and a monorepo alike.
#
# On pull_request and push runs only the modules a change affects are
# selected (CHANGED_ONLY). A changed file affects:
#   - the root module it belongs to: the deepest one containing it, unless
#     the file is inside a local module directory nested deeper still (a
#     root module at "." doesn't claim files of the root modules nested
#     under it, nor of a shared modules/ directory it doesn't use),
#   - every root module that uses the directory it's in as a local module
#     (source = "../modules/x", found by following local sources
#     recursively), and
#   - every root module, if it matches SHARED_PATHS.
# Any other event, or a diff that can't be computed, selects every module:
# planning too much is safe, skipping a module isn't.
#
# Environment variables:
#   SEARCH_ROOT  - directory to search, relative to the repository root
#                  (default: .)
#   EXCLUDE      - globs of module paths to skip, space- or newline-separated
#                  (e.g. "legacy/**")
#   MODULES      - run exactly these modules (paths), ignoring changes; each
#                  must be a discovered root module (optional)
#   CHANGED_ONLY - "true" to select only affected modules on PR/push runs
#                  (default: true)
#   SHARED_PATHS - globs whose change affects every module, e.g.
#                  ".github/workflows/opentofu.yaml" (optional). Also added to
#                  each module's preflight paths.
#   DEPLOYMENTS  - .tfvars globs/paths relative to each module, one
#                  deployment each (see "Deployments" in common.sh). A module
#                  they match nothing in is planned on its own.
#   VAR_FILES, BACKEND_CONFIG, PLAN_ENVIRONMENT
#                - shared deployment settings, for deployments-matrix
#   EVENT_NAME   - github.event_name
#   BASE_SHA     - base commit of the PR (pull_request runs)
#   BEFORE_SHA   - commit before the push (push runs)
#   HEAD_REF     - commit to diff to (default: HEAD)
#
# Outputs:
#   matrix      - {"module":[{"path", "preflight_paths", "deployments"}, ...]}
#                 where deployments is DEPLOYMENTS, or "" for a module it
#                 matches nothing in
#   deployments-matrix
#               - {"deployment":[...]}: every deployment of every selected
#                 module, flattened (see deployment_json, plus "path"), for
#                 jobs that run per deployment directly (drift detection)
#   modules     - JSON array of the selected module paths
#   count       - number of selected modules
#   has-modules - "true" if any module is selected
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool jq
require_tool git

CHANGED_ONLY="${CHANGED_ONLY:-true}"
HEAD_REF="${HEAD_REF:-HEAD}"
log_config SEARCH_ROOT EXCLUDE MODULES CHANGED_ONLY SHARED_PATHS DEPLOYMENTS EVENT_NAME BASE_SHA BEFORE_SHA

if ! search_root="$(normalize_path "${SEARCH_ROOT:-.}")"; then
  log_error "search-root '${SEARCH_ROOT}' climbs out of the repository. Use a path relative to the repository root."
  exit 1
fi
if [ ! -d "$search_root" ]; then
  log_error "search-root '${search_root}' doesn't exist (from $PWD). Paths are relative to the repository root."
  exit 1
fi

# --- Discover --------------------------------------------------------------

modules=()
excluded=()
while IFS= read -r config; do
  dir="$(normalize_path "$(dirname "$config")")"
  if ! compgen -G "${dir}/*.tf" > /dev/null; then
    continue
  fi
  if matches_any_glob "$dir" "${EXCLUDE:-}"; then
    excluded+=("$dir")
    continue
  fi
  modules+=("$dir")
done < <(find "$search_root" \( -name .git -o -name .terraform \) -prune -o \
  -type f \( -name mise.toml -o -name .mise.toml \) -print | sort)

mapfile -t modules < <(printf '%s\n' "${modules[@]+"${modules[@]}"}" | sed '/^$/d' | sort -u)
if [ ${#excluded[@]} -gt 0 ]; then
  log_info "Excluded: ${excluded[*]}"
fi
if [ ${#modules[@]} -eq 0 ]; then
  log_error "No root modules found under '${search_root}'. A root module is a directory with *.tf files and its own mise.toml pinning its tools (e.g. 'mise use opentofu@<version>' in it). Check search-root and exclude."
  exit 1
fi
log_info "Root modules under ${search_root}: ${modules[*]}"

# Local module directories a root module uses, followed recursively, as
# repository-relative paths. Directories inside the module are left out:
# the module's own path already covers them.
declare -A DEPS
local_deps() {
  local module="$1" dir file source dep
  local -a queue=("$module") found=()
  local -A seen=(["$module"]=1)
  while [ ${#queue[@]} -gt 0 ]; do
    dir="${queue[0]}"
    queue=("${queue[@]:1}")
    for file in "$dir"/*.tf; do
      [ -f "$file" ] || continue
      while IFS= read -r source; do
        dep="$(normalize_path "${dir}/${source}")" || continue
        [ -d "$dep" ] || continue
        [ -n "${seen[$dep]+set}" ] && continue
        seen["$dep"]=1
        queue+=("$dep")
        if [ "$module" != "." ] && [[ "$dep" != "$module" && "$dep" != "$module"/* ]]; then
          found+=("$dep")
        fi
      done < <(grep -hoE 'source[[:space:]]*=[[:space:]]*"\.\.?/[^"]*"' "$file" | sed -E 's/.*"(.*)"/\1/' || true)
    done
  done
  printf '%s\n' "${found[@]+"${found[@]}"}" | sed '/^$/d' | sort -u
}

ALL_DEPS=()
for module in "${modules[@]}"; do
  DEPS["$module"]="$(local_deps "$module")"
  while IFS= read -r dep; do
    [ -n "$dep" ] && ALL_DEPS+=("$dep")
  done <<< "${DEPS[$module]}"
done

# --- Select ----------------------------------------------------------------

declare -A SELECTED
declare -A REASON
select_all() {
  local reason="$1" module
  for module in "${modules[@]}"; do
    SELECTED["$module"]=1
    REASON["$module"]="$reason"
  done
}

if [ -n "${MODULES:-}" ]; then
  while IFS= read -r wanted; do
    wanted="$(normalize_path "$wanted")" || wanted="?"
    is_module=false
    for module in "${modules[@]}"; do
      if [ "$module" = "$wanted" ]; then
        is_module=true
      fi
    done
    if [ "$is_module" = false ]; then
      log_error "modules input: '${wanted}' isn't a root module under ${search_root} (found: ${modules[*]})."
      exit 1
    fi
    SELECTED["$wanted"]=1
    REASON["$wanted"]="listed in modules"
  done < <(list_items "$MODULES")
else
  base=""
  if ! is_true "$CHANGED_ONLY"; then
    select_all "changed-only is off"
  elif [ "${EVENT_NAME:-}" = "pull_request" ] && [ -n "${BASE_SHA:-}" ]; then
    base="$BASE_SHA"
  elif [ "${EVENT_NAME:-}" = "push" ] && [ -n "${BEFORE_SHA:-}" ] && [[ ! "$BEFORE_SHA" =~ ^0+$ ]]; then
    base="$BEFORE_SHA"
  else
    select_all "${EVENT_NAME:-this} run: every module"
  fi

  if [ -n "$base" ]; then
    if ! changed="$(git diff --name-only "$base" "$HEAD_REF" 2>&1)"; then
      log_warn "Couldn't diff ${base:0:7}..${HEAD_REF} (${changed##*$'\n'}), so every module is selected. Check out with fetch-depth: 0."
      select_all "diff unavailable: every module"
      changed=""
    fi

    while IFS= read -r file; do
      [ -z "$file" ] && continue
      if matches_any_glob "$file" "${SHARED_PATHS:-}"; then
        select_all "shared path changed (${file})"
        break
      fi
      # The deepest root module containing the file owns it
      owner="" owner_len=-1
      for module in "${modules[@]}"; do
        if [ "$module" = "." ] || [[ "$file" == "$module"/* ]]; then
          len=${#module}
          [ "$module" = "." ] && len=0
          if [ "$len" -gt "$owner_len" ]; then
            owner="$module"
            owner_len=$len
          fi
        fi
      done
      # A file in a local module directory below the owner belongs to that
      # local module: only the modules using it (below) are affected
      for dep in "${ALL_DEPS[@]+"${ALL_DEPS[@]}"}"; do
        if [[ "$file" == "$dep"/* ]] && [ "${#dep}" -gt "$owner_len" ]; then
          owner=""
          break
        fi
      done
      if [ -n "$owner" ] && [ -z "${SELECTED[$owner]+set}" ]; then
        SELECTED["$owner"]=1
        REASON["$owner"]="changed"
      fi
      # ...and every module using the file's directory as a local module
      for module in "${modules[@]}"; do
        [ -n "${SELECTED[$module]+set}" ] && continue
        while IFS= read -r dep; do
          if [ -n "$dep" ] && [[ "$file" == "$dep"/* ]]; then
            SELECTED["$module"]=1
            REASON["$module"]="local module ${dep} changed"
            break
          fi
        done <<< "${DEPS[$module]}"
      done
    done <<< "$changed"

    # A deleted root module isn't discovered, so nothing destroys what it
    # managed. Say so rather than silently skipping it.
    while IFS= read -r deleted; do
      [ -z "$deleted" ] && continue
      dir="$(dirname "$deleted")"
      if [ ! -d "$dir" ] || ! compgen -G "${dir}/*.tf" > /dev/null; then
        log_warn "${dir} no longer has any .tf files. If it was a root module, its infrastructure isn't destroyed by removing it: run 'tofu destroy' for it (or remove its resources in a plan) before deleting it."
      fi
    done < <(git diff --name-only --diff-filter=D "$base" "$HEAD_REF" -- '*.tf' 2> /dev/null || true)
  fi
fi

# --- Output ----------------------------------------------------------------

matrix_entries=()
deployment_entries=()
selected=()
declare -A DEPLOYMENT_NAMES
for module in "${modules[@]}"; do
  [ -n "${SELECTED[$module]+set}" ] || continue
  selected+=("$module")
  preflight="$(printf '%s\n%s\n%s\n' "$module" "${DEPS[$module]}" "$(list_items "${SHARED_PATHS:-}")" | sed '/^$/d')"

  # The deployments input applies to every module; one it matches nothing
  # in is planned on its own
  patterns="${DEPLOYMENTS:-}"
  if ! module_deployments="$(PREFLIGHT_PATHS="$preflight" list_deployments "$module")"; then
    exit 1
  fi
  if [ -z "$module_deployments" ]; then
    patterns=""
    module_deployments="$(DEPLOYMENTS="" PREFLIGHT_PATHS="$preflight" list_deployments "$module")" || exit 1
  fi
  DEPLOYMENT_NAMES["$module"]="$(jq -r '.name' <<< "$module_deployments" | paste -sd, - | sed 's/,/, /g')"

  matrix_entries+=("$(jq -cn --arg path "$module" --arg preflight "$preflight" --arg deployments "$patterns" \
    '{path: $path, preflight_paths: $preflight, deployments: $deployments}')")
  while IFS= read -r deployment; do
    deployment_entries+=("$(jq -c --arg path "$module" '. + {path: $path}' <<< "$deployment")")
  done <<< "$module_deployments"
done

matrix="$(printf '%s\n' "${matrix_entries[@]+"${matrix_entries[@]}"}" | jq -cs '{module: .}')"
deployments_matrix="$(printf '%s\n' "${deployment_entries[@]+"${deployment_entries[@]}"}" | jq -cs '{deployment: .}')"
selected_json="$(printf '%s\n' "${selected[@]+"${selected[@]}"}" | sed '/^$/d' | jq -Rcs 'split("\n") | map(select(. != ""))')"

{
  echo "### OpenTofu root modules under \`${search_root}\`"
  echo ""
  echo "| Module | Runs | Deployments | Local modules |"
  echo "| --- | --- | --- | --- |"
  for module in "${modules[@]}"; do
    deps=""
    while IFS= read -r dep; do
      [ -n "$dep" ] && deps+="\`${dep}\` "
    done <<< "${DEPS[$module]}"
    if [ -n "${SELECTED[$module]+set}" ]; then
      runs="✅ ${REASON[$module]}"
      names="${DEPLOYMENT_NAMES[$module]}"
      names="${names:-(module as is)}"
    else
      runs="⏭️ unchanged"
      names="–"
    fi
    echo "| \`${module}\` | ${runs} | ${names} | ${deps:-–} |"
  done
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output matrix "$matrix"
set_output deployments-matrix "$deployments_matrix"
set_output modules "$selected_json"
set_output count "${#selected[@]}"
if [ ${#selected[@]} -gt 0 ]; then
  set_output has-modules true
  log_success "${#selected[@]} of ${#modules[@]} root module(s) selected: ${selected[*]}"
else
  set_output has-modules false
  log_notice "No root module is affected by this change, so nothing is planned."
fi
