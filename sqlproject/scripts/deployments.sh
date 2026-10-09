#!/usr/bin/env bash
#
# Validates a SQL project's inputs and lists its deployments -- one per
# publish profile matching DEPLOYMENTS -- as a matrix for the per-deployment
# plan/apply jobs. Every input problem is reported at once, then the script
# fails, so a caller fixes them in one go.
#
#   WORKING_DIR=database/core DEPLOYMENTS='deployments/*.publish.xml' \
#     APPLY=false sqlproject/scripts/deployments.sh
#
# Environment variables:
#   WORKING_DIR        - the SQL project's folder (required)
#   DEPLOYMENTS        - publish profiles (*.publish.xml), one deployment each:
#                        globs within the folder (e.g.
#                        "deployments/*.publish.xml") and/or paths, relative to
#                        it (required)
#   DEPLOY_MODE        - additive (default) or truth
#   KEEP_OBJECT_TYPES  - truth mode: object types never dropped, ";"- or
#                        newline-separated (default: the list in
#                        sqlproject.sh); empty keeps nothing
#   DEPLOYMENT_SCRIPTS - changed (default) or always
#   PROPERTIES         - Name=Value lines of deploy properties
#   VARIABLES          - Name=Value lines of SQLCMD variables;
#                        "{deployment}" is replaced with the deployment's name
#   PLAN_ENVIRONMENT, APPLY_ENVIRONMENT
#                      - GitHub environment names; "{deployment}" is replaced
#   PREFLIGHT_PATHS    - paths every deployment's plan depends on (default:
#                        WORKING_DIR)
#   APPLY              - "true" (default): the apply job runs, so it needs an
#                        APPLY_ENVIRONMENT
#   TARGET_DACPAC      - plan against this dacpac instead of the database
#                        (needs APPLY=false)
#
# Outputs:
#   matrix       - {"deployment": [{name, profile, variables,
#                  plan_environment, apply_environment, preflight_paths}]}
#   deployments  - JSON array of the deployment names
#   count        - number of deployments
#   environments - the plan and apply environments, unique, space-separated
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=sqlproject/scripts/sqlproject.sh
source "$SCRIPT_DIR/sqlproject.sh"

require_tool jq
ensure_mise
require_env WORKING_DIR "Set the working-directory input to the SQL project's folder."
require_env DEPLOYMENTS "Set the deployments input to the publish profiles, e.g. deployments/*.publish.xml."
DEPLOY_MODE="${DEPLOY_MODE:-additive}"
DEPLOYMENT_SCRIPTS="${DEPLOYMENT_SCRIPTS:-changed}"
APPLY="${APPLY:-true}"
KEEP_OBJECT_TYPES="${KEEP_OBJECT_TYPES-$SQL_DEFAULT_KEEP_OBJECT_TYPES}"
PREFLIGHT_PATHS="${PREFLIGHT_PATHS:-$WORKING_DIR}"
log_config WORKING_DIR DEPLOYMENTS DEPLOY_MODE KEEP_OBJECT_TYPES DEPLOYMENT_SCRIPTS PLAN_ENVIRONMENT APPLY_ENVIRONMENT PREFLIGHT_PATHS APPLY TARGET_DACPAC

problems=()
problem() {
  problems+=("$1")
}

dir="$(normalize_path "$WORKING_DIR")" || {
  log_error "working-directory '${WORKING_DIR}' climbs out of the repository. Use a path relative to the repository root."
  exit 1
}
if [ ! -d "$dir" ]; then
  log_error "working-directory '${dir}' doesn't exist. It's relative to the repository root."
  exit 1
fi

# --- The project ------------------------------------------------------------
projects=("$dir"/*.sqlproj)
if [ ! -f "${projects[0]}" ]; then
  problem "No *.sqlproj in ${dir}. Point working-directory at the SQL project's folder."
elif [ ${#projects[@]} -gt 1 ]; then
  problem "More than one SQL project in ${dir}: $(printf '%s ' "${projects[@]##*/}")Put one SQL project per folder."
fi
if [ ! -f "$dir/mise.toml" ] && [ ! -f "$dir/.mise.toml" ]; then
  problem "No mise.toml in ${dir}. The project pins its own tools: run 'mise use dotnet@<version> \"dotnet:microsoft.sqlpackage@<version>\" yq@<version> azure-cli@<version> uv@<version>' there."
fi

# --- Inputs -----------------------------------------------------------------
case "$DEPLOY_MODE" in
  additive | truth) ;;
  *) problem "deploy-mode '${DEPLOY_MODE}' isn't valid. Use additive (never drop what isn't in the project) or truth (drop it)." ;;
esac
case "$DEPLOYMENT_SCRIPTS" in
  changed | always) ;;
  *) problem "deployment-scripts '${DEPLOYMENT_SCRIPTS}' isn't valid. Use changed (they count when they differ from what is deployed) or always." ;;
esac
while IFS= read -r type; do
  [ -n "$type" ] || continue
  if ! [[ "$type" =~ ^[A-Za-z]+$ ]]; then
    problem "keep-object-types has '${type}', which isn't an object type name. Use SqlPackage's names (Users, Logins, Permissions, ...), separated by ; or newlines."
  fi
done < <(list_lines "$(tr ';' '\n' <<< "$KEEP_OBJECT_TYPES")")
for kind in properties variables; do
  case "$kind" in
    properties) text="${PROPERTIES:-}" ;;
    variables) text="${VARIABLES:-}" ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] && problem "$line"
  done < <(sql_assignment_problems "$kind" "$text")
done
if is_true "$APPLY" && [ -z "${APPLY_ENVIRONMENT:-}" ]; then
  problem "apply is true, but apply-environment is empty. Set apply-environment to a GitHub environment with required reviewers (e.g. \"{deployment}\"), or set apply to false to only plan."
fi
if [ -n "${TARGET_DACPAC:-}" ]; then
  if is_true "$APPLY"; then
    problem "target-dacpac plans against a file, not the database, so it can't be applied. Set apply to false, or clear target-dacpac."
  fi
  if [ ! -f "$dir/$TARGET_DACPAC" ]; then
    problem "target-dacpac '${TARGET_DACPAC}' not found in ${dir}. It's relative to the working directory."
  fi
fi

preflight_rules=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if ! rule="$(path_entry_rule "${entry#./}")"; then
    problem "preflight-paths entry '${entry}' climbs out of the repository. Use paths relative to the repository root."
  else
    preflight_rules+=("$rule")
  fi
done < <(list_items "$PREFLIGHT_PATHS")

# --- The publish profiles -----------------------------------------------------
files=()
while IFS= read -r pattern; do
  pattern="${pattern#./}"
  if [[ "$pattern" == *[*?]* ]]; then
    regex="$(glob_to_regex "$pattern")"
    while IFS= read -r file; do
      if [[ "$file" =~ $regex ]]; then
        files+=("$file")
      fi
    done < <(cd "$dir" && find . \( -name .git -o -name bin -o -name obj \) -prune -o -type f -name '*.publish.xml' -print | sed 's|^\./||')
  elif [ -f "$dir/$pattern" ]; then
    files+=("$pattern")
  else
    problem "Publish profile '${pattern}' not found in ${dir}. deployments paths are relative to the working directory."
  fi
done < <(list_items "$DEPLOYMENTS")

if [ ${#files[@]} -eq 0 ] && [ ${#problems[@]} -eq 0 ]; then
  problem "The deployments input (${DEPLOYMENTS//$'\n'/ }) matches no *.publish.xml files in ${dir}. Paths and globs are relative to the working directory."
fi

# Every other profile of the project, for the stale-plan check: a sibling
# deployment's profile changing on the target branch doesn't make this plan
# stale (OpenTofu leaves out sibling var files the same way)
all_profiles=()
while IFS= read -r file; do
  all_profiles+=("$file")
done < <(cd "$dir" && find . \( -name .git -o -name bin -o -name obj \) -prune -o -type f -name '*.publish.xml' -print | sed 's|^\./||' | LC_ALL=C sort)

deployment_list="[]"
declare -A seen=()
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if [[ "$file" != *.publish.xml ]]; then
    problem "Deployment profile '${file}' doesn't end in .publish.xml. A deployment is named after its profile (deployments/prod.publish.xml is 'prod')."
    continue
  fi
  name="$(basename "$file")"
  name="${name%.publish.xml}"
  if [ -n "${seen[$name]+set}" ]; then
    problem "Two deployments of ${dir} are named '${name}': ${seen[$name]} and ${file}. Deployments are named after their profile file, so rename one."
    continue
  fi
  seen["$name"]="$file"

  # The profile itself, read with the project's own yq (mise scopes to the
  # folder it runs in)
  if profile_json="$(cd "$dir" && scope_mise_to_module && sql_profile_json "$file")"; then
    while IFS= read -r line; do
      [ -n "$line" ] && problem "$line"
    done < <(sql_profile_problems "$profile_json" "${dir}/${file}")
  else
    problem "Couldn't read ${dir}/${file} as XML. Check it is well-formed (open it in VS Code, or run 'xmllint ${dir}/${file}'), and that yq is pinned in ${dir}/mise.toml."
  fi

  variables="${VARIABLES:-}"
  variables="${variables//"{deployment}"/$name}"
  plan_environment="${PLAN_ENVIRONMENT:-}"
  plan_environment="${plan_environment//"{deployment}"/$name}"
  apply_environment="${APPLY_ENVIRONMENT:-}"
  apply_environment="${apply_environment//"{deployment}"/$name}"

  # What a change to makes this plan stale: the call's paths, less the other
  # profiles, plus this one (last, so it always counts)
  preflight="$(list_items "$PREFLIGHT_PATHS")"
  for other in "${all_profiles[@]+"${all_profiles[@]}"}"; do
    [ "$other" = "$file" ] && continue
    if other_path="$(normalize_path "${dir}/${other}")"; then
      preflight="$(printf '%s\n!%s' "$preflight" "$other_path")"
    fi
  done
  preflight="$(printf '%s\n%s' "$preflight" "$(normalize_path "${dir}/${file}")" | sed '/^$/d')"

  deployment_list="$(jq -c --arg name "$name" --arg profile "$file" --arg variables "$variables" \
    --arg plan_environment "$plan_environment" --arg apply_environment "$apply_environment" \
    --arg preflight_paths "$preflight" \
    '. + [{name: $name, profile: $profile, variables: $variables,
           plan_environment: $plan_environment, apply_environment: $apply_environment,
           preflight_paths: $preflight_paths}]' <<< "$deployment_list")"
done < <(printf '%s\n' "${files[@]+"${files[@]}"}" | LC_ALL=C sort -u)

if [ ${#problems[@]} -gt 0 ]; then
  for message in "${problems[@]}"; do
    log_error "$message"
  done
  log_error "${#problems[@]} problem(s) with the inputs. Fix them all and re-run."
  exit 1
fi

matrix="$(jq -c '{deployment: .}' <<< "$deployment_list")"
names="$(jq -c 'map(.name)' <<< "$deployment_list")"
count="$(jq 'length' <<< "$deployment_list")"
environments="$(jq -r '[.[] | .plan_environment, .apply_environment | select(. != "")] | unique | join(" ")' <<< "$deployment_list")"

{
  echo "### Deployments of \`${dir}\`"
  echo ""
  echo "| Deployment | Profile | Plan environment | Apply environment |"
  echo "| --- | --- | --- | --- |"
  jq -r '
    def cell: if . == "" then "–" else "`\(.)`" end;
    .[] | "| `\(.name)` | \(.profile | cell) | \(.plan_environment | cell) | \(.apply_environment | cell) |"
  ' <<< "$deployment_list"
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output matrix "$matrix"
set_output deployments "$names"
set_output count "$count"
set_output environments "$environments"
log_success "${count} deployment(s) of ${dir}: $(jq -r 'join(", ")' <<< "$names")"
