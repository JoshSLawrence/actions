#!/usr/bin/env bash
#
# Finds the root modules under SEARCH_ROOT, at any depth, and decides which
# of them -- and which of their deployments -- to run. A root module is a
# directory with *.tf files and its own mise config (mise.toml or
# .mise.toml): every root module pins its own tools, so the mise config
# doubles as the marker. Root modules may nest inside each other.
#
# A deployment is a deployments/<name>.yaml file, with an optional
# deployments/<name>.tfvars of the same name, or a deployment.yaml in the
# module root (see "Deployments" in common.sh). On pull_request and push
# runs only what a change affects is selected (CHANGED_ONLY). A changed file
# belongs to the deepest root module containing it -- its .tf files, child
# modules (e.g. modules/x below it), tests, lock file, mise.toml -- and
# selects:
#   - deployments/<name>.yaml or <name>.tfvars: just that deployment (one
#     whose .yaml was deleted is only warned about: nothing destroys what it
#     managed);
#   - anything else: every deployment of that module, or the module alone
#     (validated and tested) if it has none.
# A file matching SHARED_PATHS selects everything. Any other file -- outside
# every root module, including a module directory shared between root
# modules -- selects nothing: list it in SHARED_PATHS if it should.
# Any other event, MODULES, or a diff that can't be computed selects every
# deployment of the modules concerned: planning too much is safe, skipping
# one isn't.
#
# Every module's deployment layout is checked (see deployment_layout_problems
# in common.sh), and the selected deployments' files are parsed: a problem
# anywhere fails the run, listing them all. Root module paths can't contain
# whitespace.
#
# Environment variables:
#   SEARCH_ROOT  - directory to search, relative to the repository root
#                  (default: .)
#   EXCLUDE      - globs of module paths to skip, space- or newline-separated
#                  (e.g. "legacy/**")
#   MODULES      - run exactly these modules (paths), every deployment,
#                  ignoring changes; each must be a discovered root module
#                  (optional)
#   CHANGED_ONLY - "true" to select only what changed on PR/push runs
#                  (default: true)
#   SHARED_PATHS - globs whose change selects everything, e.g.
#                  ".github/workflows/opentofu.yaml" or "iac/modules/**"
#                  (optional). Also added to each deployment's preflight
#                  paths.
#   EVENT_NAME   - github.event_name
#   BASE_SHA     - base commit of the PR (pull_request runs)
#   BEFORE_SHA   - commit before the push (push runs)
#   HEAD_REF     - commit to diff to (default: HEAD)
#
# Outputs:
#   matrix       - {"module":[{"path", "deployments"}, ...]}
#                  where deployments is a JSON array string of the selected
#                  deployments (see deployment_json in common.sh): "[]" for
#                  a module that's only validated and tested
#   deployments-matrix
#                - {"deployment":[...]}: every selected deployment of every
#                  selected module, flattened (plus "path"), for jobs that
#                  run per deployment directly
#   environments - the GitHub environments the selected deployments use,
#                  space-separated (for require-environments.sh)
#   modules      - JSON array of the selected module paths
#   count        - number of selected modules
#   has-modules  - "true" if any module is selected
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_tool jq
require_tool git
require_tool yq

CHANGED_ONLY="${CHANGED_ONLY:-true}"
HEAD_REF="${HEAD_REF:-HEAD}"
log_config SEARCH_ROOT EXCLUDE MODULES CHANGED_ONLY SHARED_PATHS EVENT_NAME BASE_SHA BEFORE_SHA

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

# Paths are passed between jobs as space-separated lists, so a space would
# split one path into two; deployment names are checked with the layout.
# Refuse every problem up front, by name.
problems=()
for module in "${modules[@]}"; do
  if [[ "$module" =~ [[:space:]] ]]; then
    problems+=("'${module}' contains whitespace, which isn't supported in root module paths. Rename it (e.g. with - or _), or exclude it.")
    continue
  fi
  while IFS= read -r problem; do
    [ -n "$problem" ] && problems+=("$problem")
  done < <(deployment_layout_problems "$module")
done
if [ ${#problems[@]} -gt 0 ]; then
  for problem in "${problems[@]}"; do
    log_error "$problem"
  done
  exit 1
fi

# --- Select ----------------------------------------------------------------
#
# ALL[module]: run every deployment, for REASON[module]. CHANGED[module]: only
# these changed deployments. A module is selected if either is set.

declare -A ALL CHANGED REASON
select_module() {
  local module="$1" reason="$2"
  if [ -z "${ALL[$module]+set}" ]; then
    ALL["$module"]=1
    REASON["$module"]="$reason"
  fi
}
select_all() {
  local module
  for module in "${modules[@]}"; do
    select_module "$module" "$1"
  done
}

# Path of a file relative to a root module
module_relative() {
  local module="$1" file="$2"
  if [ "$module" = "." ]; then
    echo "$file"
  else
    echo "${file#"${module}/"}"
  fi
}

deleted_deployments=()
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
    select_module "$wanted" "listed in modules"
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
    select_all "${EVENT_NAME:-this} run: everything"
  fi

  if [ -n "$base" ]; then
    # --no-renames: a renamed deployment shows as its old files (deleted) and
    # its new ones (added), so both are handled
    if ! changed="$(git diff --name-only --no-renames "$base" "$HEAD_REF" 2>&1)"; then
      log_warn "Couldn't diff ${base:0:7}..${HEAD_REF} (${changed##*$'\n'}), so everything is selected. Check out with fetch-depth: 0."
      select_all "diff unavailable: everything"
      changed=""
    fi

    while IFS= read -r file; do
      [ -z "$file" ] && continue
      # Every file is still looked at once everything is selected: it can
      # be a deleted deployment, which is warned about below
      if matches_any_glob "$file" "${SHARED_PATHS:-}"; then
        select_all "shared path changed (${file})"
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
      [ -z "$owner" ] && continue
      relative="$(module_relative "$owner" "$file")"
      if ! name="$(deployment_of_file "$relative")"; then
        select_module "$owner" "changed"
      elif [ -f "${owner}/${DEPLOYMENTS_DIR}/${name}.yaml" ]; then
        # Its .yaml or .tfvars changed, or the .tfvars was deleted: the
        # deployment still exists, with new inputs
        CHANGED["$owner"]+="${name}"$'\n'
      else
        deleted_deployments+=("${owner}/${DEPLOYMENTS_DIR}/${name}")
      fi
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

# Likewise a deleted deployment: its .yaml is gone, so nothing plans it
mapfile -t deleted_deployments < <(printf '%s\n' "${deleted_deployments[@]+"${deleted_deployments[@]}"}" | sed '/^$/d' | sort -u)
for deployment in "${deleted_deployments[@]+"${deleted_deployments[@]}"}"; do
  log_warn "${deployment}.yaml was deleted, so that deployment isn't planned. Removing it doesn't destroy what it managed: plan its resources away (or run 'tofu destroy' with its settings) before deleting it."
done

# --- Output ----------------------------------------------------------------

matrix_entries=()
deployment_entries=()
selected=()
failed=false
declare -A SUMMARY
for module in "${modules[@]}"; do
  if [ -n "${ALL[$module]+set}" ]; then
    selected_names=""
  elif [ -n "${CHANGED[$module]:-}" ]; then
    selected_names="$(sed '/^$/d' <<< "${CHANGED[$module]}" | LC_ALL=C sort -u)"
    REASON["$module"]="deployments changed"
  else
    continue
  fi
  selected+=("$module")
  preflight="$(printf '%s\n%s\n' "$module" "$(list_items "${SHARED_PATHS:-}")" | sed '/^$/d')"

  if ! module_deployments="$(NAMES="$selected_names" PREFLIGHT_PATHS="$preflight" list_deployments "$module")"; then
    failed=true
    continue
  fi
  if [ -z "$module_deployments" ]; then
    SUMMARY["$module"]="validate and test only: no deployment files"
  else
    # What applies where, e.g. `beans` → `prod`
    SUMMARY["$module"]="$(jq -r '"\(if .name == "" then "(module as is)" else "`\(.name)`" end) → `\(.apply_environment)`"' \
      <<< "$module_deployments" | paste -sd, - | sed 's/,/, /g')"
  fi

  deployments_json="$(jq -cs '.' <<< "${module_deployments:-}")"
  matrix_entries+=("$(jq -cn --arg path "$module" --arg deployments "$deployments_json" \
    '{path: $path, deployments: $deployments}')")
  while IFS= read -r deployment; do
    [ -n "$deployment" ] && deployment_entries+=("$(jq -c --arg path "$module" '. + {path: $path}' <<< "$deployment")")
  done <<< "$module_deployments"
done
if [ "$failed" = true ]; then
  log_error "Fix the deployment files above and push again."
  exit 1
fi

matrix="$(printf '%s\n' "${matrix_entries[@]+"${matrix_entries[@]}"}" | jq -cs '{module: .}')"
deployments_matrix="$(printf '%s\n' "${deployment_entries[@]+"${deployment_entries[@]}"}" | jq -cs '{deployment: .}')"
environments="$(jq -r '.deployment[] | .apply_environment, .plan_environment | select(. != "")' <<< "$deployments_matrix" | LC_ALL=C sort -u | paste -sd' ' -)"
selected_json="$(printf '%s\n' "${selected[@]+"${selected[@]}"}" | sed '/^$/d' | jq -Rcs 'split("\n") | map(select(. != ""))')"

{
  echo "### OpenTofu root modules under \`${search_root}\`"
  echo ""
  echo "| Module | Runs | Deployments |"
  echo "| --- | --- | --- |"
  for module in "${modules[@]}"; do
    if [ -n "${SUMMARY[$module]+set}" ]; then
      echo "| \`${module}\` | ✅ ${REASON[$module]} | ${SUMMARY[$module]} |"
    else
      echo "| \`${module}\` | ⏭️ unchanged | – |"
    fi
  done
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output matrix "$matrix"
set_output deployments-matrix "$deployments_matrix"
set_output environments "$environments"
set_output modules "$selected_json"
set_output count "${#selected[@]}"
if [ ${#selected[@]} -gt 0 ]; then
  set_output has-modules true
  log_success "${#selected[@]} of ${#modules[@]} root module(s) selected: ${selected[*]}"
else
  set_output has-modules false
  log_notice "No root module is affected by this change, so nothing is planned."
fi
