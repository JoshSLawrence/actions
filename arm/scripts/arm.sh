#!/usr/bin/env bash
# Helpers for the datafactory/* and synapse/* scripts. Both services keep
# their content as JSON files in a Git folder, export that folder to one
# ARM-style template plus a parameters file, and deploy the same template to
# every environment with different parameters. Sections: deployments,
# parameters, export bundles, templates, Azure CLI, infrastructure kinds,
# live state, and plans. Source it after common.sh:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=shared/scripts/common.sh
#   source "$SCRIPT_DIR/../../shared/scripts/common.sh"
#   # shellcheck source=arm/scripts/arm.sh
#   source "$SCRIPT_DIR/../../arm/scripts/arm.sh"

# --- Deployments --------------------------------------------------------------
#
# A deployment is the exported template deployed with one ARM parameters file
# (the standard deploymentParameters JSON): the same factory or workspace
# content for dev and prod, each with its own target name, endpoints and
# resource group. It's named after its file (deployments/prod.json, or
# prod.parameters.json -> "prod"). Without deployments, the template is
# deployed once, with only the shared parameter files and parameters.

# Replace "{deployment}" in a setting with the deployment's name. Settings
# that use it (e.g. an apply-environment of "{deployment}") need a named
# deployment, so a directory without deployments is an error.
# Usage: expand_deployment_placeholder <setting> <value> <deployment> <dir>
expand_deployment_placeholder() {
  local setting="$1" value="$2" name="$3" dir="$4"
  if [[ "$value" == *"{deployment}"* ]] && [ -z "$name" ]; then
    log_error "${setting} uses {deployment}, but ${dir} has no deployments (files matching the deployments input), so there's no name to put there."
    return 1
  fi
  echo "${value//"{deployment}"/$name}"
}

# Print a deployment's name from its parameters file path
arm_deployment_name() {
  local name
  name="$(basename "$1")"
  name="${name%.json}"
  echo "${name%.parameters}"
}

# Print "!<path>" for every other .json file next to a deployment's
# parameters file (in the same folder, never in the working directory
# itself: its .json files are the exporter's, like
# arm-template-parameters-definition.json) that the call doesn't use as a
# shared parameters file. Prints nothing for the template on its own.
# Usage: arm_sibling_exclusions "<folder>" "<deployment file>" "<parameter files>"
arm_sibling_exclusions() {
  local dir="$1" file="$2" parameter_files="$3" sub other base path
  [ -n "$file" ] || return 0
  sub="$(dirname "$file")"
  [ "$sub" != "." ] || return 0
  [ -d "${dir}/${sub}" ] || return 0
  while IFS= read -r other; do
    base="${sub}/$(basename "$other")"
    [ "$base" != "$file" ] || continue
    grep -qxF -- "$base" <<< "$parameter_files" && continue
    path="$(normalize_path "${dir}/${base}")" || continue
    echo "!${path}"
  done < <(find "${dir}/${sub}" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
}

# Print one deployment as a compact JSON object:
#   name              - "" for the template on its own
#   parameter_files   - PARAMETER_FILES plus the deployment's file
#                       (newline-separated, relative to the folder)
#   parameters        - PARAMETERS with {deployment} replaced (one per line)
#   resource_group, plan_environment, apply_environment
#                     - RESOURCE_GROUP / PLAN_ENVIRONMENT / APPLY_ENVIRONMENT
#                       with {deployment} replaced
#   preflight_paths   - PREFLIGHT_PATHS, less the other deployments'
#                       parameters files, plus every parameter file of this
#                       one, as repository paths (ordered: the last match
#                       wins): a change to any of them on the target branch
#                       makes a plan stale
# Usage: arm_deployment_json "<folder>" "<name>" "<parameters file or empty>"
arm_deployment_json() {
  local dir="$1" name="$2" file="$3"
  local parameter_files parameters resource_group plan_environment apply_environment
  local preflight entry

  parameter_files="$(list_items "${PARAMETER_FILES:-}")"
  if [ -n "$file" ]; then
    parameter_files="$(printf '%s\n%s' "$parameter_files" "$file" | sed '/^$/d')"
  fi

  parameters="$(expand_deployment_placeholder parameters "$(list_lines "${PARAMETERS:-}")" "$name" "$dir")" || return 1
  resource_group="$(expand_deployment_placeholder resource-group "${RESOURCE_GROUP:-}" "$name" "$dir")" || return 1
  plan_environment="$(expand_deployment_placeholder plan-environment "${PLAN_ENVIRONMENT:-}" "$name" "$dir")" || return 1
  apply_environment="$(expand_deployment_placeholder apply-environment "${APPLY_ENVIRONMENT:-}" "$name" "$dir")" || return 1

  # The call's paths, then the deployment's sibling parameters files
  # excluded, then the call's parameters files (the shared ones and this
  # deployment's own): the last match wins, as apply-preflight.sh reads the
  # list. So another deployment's file changing on the target branch doesn't
  # make this plan stale, but a shared one does.
  preflight="$(list_items "${PREFLIGHT_PATHS:-}")"
  preflight="$(printf '%s\n%s' "$preflight" "$(arm_sibling_exclusions "$dir" "$file" "$parameter_files")")"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry="$(normalize_path "${dir}/${entry}")" || continue
    preflight="$(printf '%s\n%s' "$preflight" "$entry")"
  done <<< "$parameter_files"
  preflight="$(sed '/^$/d' <<< "$preflight" | awk '!seen[$0]++')"

  jq -cn --arg name "$name" --arg parameter_files "$parameter_files" \
    --arg parameters "$parameters" --arg resource_group "$resource_group" \
    --arg plan_environment "$plan_environment" --arg apply_environment "$apply_environment" \
    --arg preflight_paths "$preflight" \
    '{name: $name, parameter_files: $parameter_files, parameters: $parameters,
      resource_group: $resource_group, plan_environment: $plan_environment,
      apply_environment: $apply_environment, preflight_paths: $preflight_paths}'
}

# Print a folder's deployments, one JSON object (see arm_deployment_json) per
# line. DEPLOYMENTS lists parameters files relative to the folder, space- or
# newline-separated: globs (matched within the folder, e.g.
# "deployments/*.json") and/or plain paths (which may point outside it).
# Without DEPLOYMENTS, prints the single unnamed deployment. With DEPLOYMENTS
# matching nothing, prints nothing: the caller decides whether that's an
# error. Returns 1 on a missing plain path or two files with the same name.
# Usage: arm_list_deployments "<folder>"
arm_list_deployments() {
  local dir="$1" pattern regex file name
  local -a files=()

  if [ -z "$(list_items "${DEPLOYMENTS:-}")" ]; then
    arm_deployment_json "$dir" "" ""
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
      done < <(cd "$dir" && find . \( -name .git -o -name node_modules \) -prune -o \
        -type f -name '*.json' -print | sed 's|^\./||')
    elif [ -f "${dir}/${pattern}" ]; then
      files+=("$pattern")
    else
      log_error "Deployment parameters file '${pattern}' not found in ${dir}. deployments paths are relative to the working directory."
      return 1
    fi
  done < <(list_items "$DEPLOYMENTS")

  local -A seen=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    name="$(arm_deployment_name "$file")"
    if [ -n "${seen[$name]+set}" ]; then
      log_error "Two deployments of ${dir} are named '${name}': ${seen[$name]} and ${file}. Deployments are named after their parameters file, so rename one."
      return 1
    fi
    seen["$name"]="$file"
    arm_deployment_json "$dir" "$name" "$file" || return 1
  done < <(printf '%s\n' "${files[@]+"${files[@]}"}" | sort -u)
}

# --- Parameters ---------------------------------------------------------------
#
# A deployment's parameters are layered, later ones winning:
#   1. the exported parameters file (the development values),
#   2. each parameter file, in order (the shared ones, then the deployment's),
#   3. the `parameters` input's name=value lines,
#   4. at plan and deploy time only, the `parameter-secrets` lines -- never
#      written to an artifact.
# Every name must be a parameter of the template, so a typo fails instead of
# being ignored. Values from name=value lines are typed by the template:
# strings stay as written; int, bool, object and array values are JSON.

# Merge parameters into one result JSON object, printed to stdout:
#   {parameters: {<name>: {value} | {reference}}, sources: {<name>: <where
#    from>}, errors: [<message>, ...]}
# The files and lines are relative to the current directory.
# Usage: arm_merge_parameters <template> <base parameters file> <lines>
#          <label for the lines> <parameter files (newline-separated)>
arm_merge_parameters() {
  local template="$1" base="$2" lines="$3" label="$4" parameter_files="$5"
  local file files_json="[]" invalid=()

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ ! -f "$file" ]; then
      invalid+=("Parameters file '${file}' not found in ${PWD}. Parameter file paths are relative to the working directory.")
    elif ! jq -e '.parameters | type == "object"' "$file" > /dev/null 2>&1; then
      invalid+=("Parameters file '${file}' isn't an ARM parameters file: it needs a \"parameters\" object, e.g. {\"parameters\": {\"factoryName\": {\"value\": \"adf-prod\"}}}.")
    else
      files_json="$(jq -c --arg path "$file" --slurpfile f "$file" '. + [{path: $path, parameters: $f[0].parameters}]' <<< "$files_json")"
    fi
  done <<< "$parameter_files"

  jq -n --slurpfile template "$template" --slurpfile base "$base" \
    --argjson files "$files_json" --arg lines "$lines" --arg label "$label" \
    --argjson invalid "$(printf '%s\n' "${invalid[@]+"${invalid[@]}"}" | jq -R . | jq -sc 'map(select(length > 0))')" '
    ($template[0].parameters // {}) as $declared
    | def kind($n): ($declared[$n].type // "string" | ascii_downcase);
      def unknown($n; $where):
        ($declared | keys) as $k
        | "\($where) sets \($n), which isn\u0027t a parameter of the template (check the spelling). Its parameters: \($k[:20] | join(", "))\(if ($k | length) > 20 then ", ... (\($k | length) in all: see the exported parameters file)" else "" end).";
      def typed($n; $raw):
        kind($n) as $t
        | if $t == "string" or $t == "securestring" then {value: $raw}
          elif $t == "int" then
            (try ($raw | tonumber) catch null) as $v
            | if $v != null and ($v | floor) == $v then {value: $v}
              else {error: "\($label): \($n) is an int parameter, but \u0027\($raw)\u0027 isn\u0027t an integer."} end
          elif $t == "bool" then
            ($raw | ascii_downcase) as $b
            | if $b == "true" then {value: true} elif $b == "false" then {value: false}
              else {error: "\($label): \($n) is a bool parameter; use true or false."} end
          else
            (try {value: ($raw | fromjson)} catch {error: "\($label): \($n) is a \($t) parameter, so its value must be JSON."})
          end;

      # 1. the exported values
      (($base[0].parameters // {}) | with_entries(.value = {param: .value, source: "template"})) as $start

      # 2. parameter files
      | reduce $files[] as $f ({entries: $start, errors: $invalid};
          reduce ($f.parameters | to_entries[]) as $p (.;
            if ($declared | has($p.key) | not) then .errors += [unknown($p.key; $f.path)]
            elif ($p.value | type) != "object" or (($p.value | has("value")) or ($p.value | has("reference")) | not) then
              .errors += ["\($f.path): \($p.key) needs a \"value\" (or a Key Vault \"reference\"), e.g. \"\($p.key)\": {\"value\": ...}."]
            else .entries[$p.key] = {
                param: ($p.value | if has("reference") then {reference} else {value} end),
                source: $f.path
              }
            end))

      # 3./4. name=value lines
      | reduce ($lines | split("\n")[] | select(length > 0)) as $line (.;
          ($line | index("=")) as $eq
          | if $eq == null or $eq == 0 then
              .errors += ["\($label): a line has no name=value (line not shown, it may be secret). Use one name=value per line."]
            else
              ($line[:$eq] | gsub("\\s+$"; "")) as $n
              | if ($declared | has($n) | not) then .errors += [unknown($n; $label)]
                else typed($n; $line[$eq + 1:] | sub("^\\s+"; "")) as $t
                  | if $t.error then .errors += [$t.error]
                    else .entries[$n] = {param: {value: $t.value}, source: $label} end
                end
            end)

      # A parameter with neither a value nor a default fails the deployment;
      # before the secrets are merged it may still get one from them
      | .entries as $entries
      | {
          parameters: (.entries | map_values(.param)),
          sources: (.entries | map_values(.source)),
          errors: .errors,
          missing: [$declared | to_entries[]
            | .key as $k
            | select((.value | has("defaultValue") | not) and ($entries | has($k) | not))
            | $k]
        }'
}

# Fail (with every error logged) unless a merge result has no errors, and
# the deployment's target (factoryName/workspaceName) was set by a parameter
# file or line: the exported value is the development factory's or
# workspace's, so deploying with it would overwrite that one.
# Usage: arm_check_parameters <merge result> <target parameter>
arm_check_parameters() {
  local result="$1" target="$2" message failed=false
  while IFS= read -r message; do
    [ -n "$message" ] || continue
    log_error "$message"
    failed=true
  done < <(jq -r '.errors[]' "$result")
  if [ "$(jq -r --arg t "$target" '.sources[$t] // "template"' "$result")" = "template" ]; then
    log_error "No deployment parameter sets ${target}, so the exported (development) value would be used. Set it in the deployment's parameters file, e.g. \"${target}\": {\"value\": \"<name>\"}, or in the parameters input."
    failed=true
  fi
  [ "$failed" = false ]
}

# Write a merge result's parameters as an ARM parameters file
# Usage: arm_write_parameters_file <merge result> <out file>
arm_write_parameters_file() {
  jq '{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    contentVersion: "1.0.0.0",
    parameters: .parameters
  }' "$1" > "$2"
}

# Mask every value of PARAMETER_SECRETS (name=value lines) in the log
arm_mask_secrets() {
  local line
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    mask_value "${line#*=}"
  done < <(list_lines "${PARAMETER_SECRETS:-}")
}

# Write <out file>: the parameters file plus PARAMETER_SECRETS, for one
# az/deployer call. Owner-only, and the caller deletes it.
# Usage: arm_parameters_with_secrets <template> <parameters file> <out file>
arm_parameters_with_secrets() {
  local template="$1" parameters="$2" out="$3" result
  arm_mask_secrets
  result="$(mktemp)"
  (umask 077 && arm_merge_parameters "$template" "$parameters" "$(list_lines "${PARAMETER_SECRETS:-}")" "parameter-secrets" "" > "$result")
  local message failed=false
  while IFS= read -r message; do
    [ -n "$message" ] || continue
    log_error "$message"
    failed=true
  done < <(jq -r '.errors[], (.missing[] | "\(.) has no value and the template has no default. Set it in a parameters file, the parameters input, or parameter-secrets.")' "$result")
  if [ "$failed" = true ]; then
    rm -f "$result"
    return 1
  fi
  (umask 077 && arm_write_parameters_file "$result" "$out")
  rm -f "$result"
}

# Print a markdown table of a merge result's parameters: value (secure
# parameters and secrets hidden) and where each came from.
# Usage: arm_parameters_markdown <merge result> <template> [secret names]
arm_parameters_markdown() {
  local result="$1" template="$2" secrets="${3:-}"
  jq -r --slurpfile template "$template" --arg secrets "$secrets" '
    ($template[0].parameters // {}) as $declared
    | .sources as $sources
    | ($secrets | split("\n") | map(select(length > 0))) as $secret_names
    | def show:
        (if type == "string" then . else tojson end)
        | gsub("\n"; " ")
        | if length > 80 then .[0:77] + "..." else . end
        | gsub("\\|"; "\\|") | gsub("`"; "\u0027");
    "| Parameter | Value | From |",
    "| --- | --- | --- |",
    (.parameters | to_entries[] | .key as $n
      | (($declared[$n].type // "string") | ascii_downcase) as $type
      | (if ($secret_names | index($n)) != null then "🔒 `parameter-secrets`"
         elif .value | has("reference") then "🔑 Key Vault reference"
         elif ($type | startswith("secure")) then "🔒 secure"
         elif .value.value == "" then "_(empty)_"
         else "`\(.value.value | show)`" end) as $shown
      | (if ($secret_names | index($n)) != null then "parameter-secrets" else ($sources[$n] // "template") end) as $from
      | "| `\($n)` | \($shown) | \(if $from == "template" then "exported" else "`\($from)`" end) |")
  ' "$result"
}

# --- Export bundles -----------------------------------------------------------
#
# Data Factory's "Validate all"/"Export ARM template" and Synapse's
# "validate" each ship as one JavaScript bundle that runs offline, with no
# Azure credentials: the npm package @microsoft/azure-data-factory-utilities
# and the Synapse deployment action only download it and run it with node.
# Running it directly works the same for both services. The bundle isn't
# versioned (every run downloads the latest), so its SHA-256 goes in the
# summary.

# Download a bundle and print its SHA-256 (logs go to stderr). BUNDLE_PATH,
# if set, is used instead (e.g. behind a proxy, or offline).
# Usage: arm_download_bundle "<url>" "<dest>"
arm_download_bundle() {
  local url="$1" dest="$2"
  if [ -n "${BUNDLE_PATH:-}" ]; then
    if [ ! -f "$BUNDLE_PATH" ]; then
      log_error "BUNDLE_PATH '${BUNDLE_PATH}' doesn't exist. Point it at a downloaded copy of ${url}, or unset it to download."
      return 1
    fi
    log_info "Using the export bundle at ${BUNDLE_PATH}" >&2
    cp "$BUNDLE_PATH" "$dest"
  else
    log_info "Downloading the export bundle from ${url}..." >&2
    log_cmd curl -fsSL --retry 3 -o "$dest" "$url"
    if ! curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url"; then
      log_error "Couldn't download ${url}. The runner needs HTTPS access to it (allow it through any proxy or firewall), or set BUNDLE_PATH to a downloaded copy."
      return 1
    fi
  fi
  file_sha256 "$dest"
}

# Copy a folder's *.json files (keeping their paths) into <dest>, the input
# for the bundle, and print how many there are (logs go to stderr). Anything else is left out: a
# stray file in a resource folder -- a .keep, a README -- makes the bundle
# find no resources at all, without saying why. Fails if a .json file isn't
# valid JSON, which the bundle would otherwise skip with a vague warning.
# Usage: arm_stage_json_files "<folder>" "<dest>"
arm_stage_json_files() {
  local src="$1" dest="$2" file count=0
  local -a invalid=() skipped=()
  mkdir -p "$dest"
  while IFS= read -r file; do
    case "$file" in
      *.json)
        if ! jq -e . "${src}/${file}" > /dev/null 2>&1; then
          invalid+=("$file")
          continue
        fi
        mkdir -p "${dest}/$(dirname "$file")"
        cp "${src}/${file}" "${dest}/${file}"
        count=$((count + 1))
        ;;
      *) skipped+=("$file") ;;
    esac
  done < <(cd "$src" && find . \( -name .git -o -name node_modules \) -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort)

  if [ ${#skipped[@]} -gt 0 ]; then
    log_info "Left out ${#skipped[@]} file(s) that aren't .json: ${skipped[*]}" >&2
  fi
  if [ ${#invalid[@]} -gt 0 ]; then
    log_error "Not valid JSON: ${invalid[*]}. Fix or remove them (check with 'jq . <file>'), then re-run."
    return 1
  fi
  echo "$count"
}

# Run an export bundle with the folder's node (call it from the folder),
# inside <run dir>: the bundle writes its output folder relative to its
# working directory, even when given an absolute path. Logs to <log>, and
# returns the bundle's exit code.
# Usage: arm_run_bundle "<run dir>" "<bundle>" "<log>" <bundle arguments...>
arm_run_bundle() {
  local run_dir="$1" bundle="$2" log="$3" node exit_code
  shift 3
  if ! node="$(mise which node 2> /dev/null)"; then
    log_error "node isn't installed for ${WORKING_DIR:-$PWD}. $(mise_pin_hint node)"
    return 1
  fi
  log_cmd node "$bundle" "$@"
  set +e
  (cd "$run_dir" && "$node" "$bundle" "$@") 2>&1 | tee "$log"
  exit_code=${PIPESTATUS[0]}
  set -e
  return "$exit_code"
}

# --- Templates ----------------------------------------------------------------

# Print a template's resources as JSON lines: {type, name}. The type is the
# part after the service's own type (pipelines, linkedServices, ...); the
# name is the resource's own name, taken from its
# "[concat(parameters('factoryName'), '/<name>')]" expression.
# Usage: arm_template_resources "<template>"
arm_template_resources() {
  jq -c '
    .resources[]?
    | {
        type: (.type | split("/")[2:] | join("/")),
        name: (.name | (capture("\u0027/(?<n>[^\u0027]*)\u0027\\)\\]$").n // .) | split("/") | last)
      }' "$1"
}

# Print a markdown table of a template's resources by type
# Usage: arm_template_markdown "<template>"
arm_template_markdown() {
  echo "| Type | Count |"
  echo "| --- | --- |"
  arm_template_resources "$1" | jq -rs '
    group_by(.type)[] | "| `\(.[0].type)` | \(length) |"'
}

# --- Azure CLI ----------------------------------------------------------------

# Run the folder's az (pinned in its mise.toml; the azure/login step signed
# it in). Call it from the folder.
arm_az() {
  mise exec -- az "$@" --only-show-errors
}

# Print every item of a paged Azure REST list (ARM or a data plane), one
# compact JSON object per line, following nextLink. Prints nothing for a 404
# (e.g. a factory that doesn't exist yet); fails on other errors.
# Usage: arm_rest_list "<url>" [az rest options, e.g. --resource <audience>]
arm_rest_list() {
  local url="$1" page err
  shift
  err="$(mktemp)"
  while [ -n "$url" ]; do
    if ! page="$(arm_az rest --method get --url "$url" "$@" 2> "$err")"; then
      if grep -q -e 'Not Found' -e 'ResourceNotFound' -e 'NotFound' "$err"; then
        break
      fi
      cat "$err" >&2
      rm -f "$err"
      return 1
    fi
    jq -c '.value[]?' <<< "$page"
    url="$(jq -r '.nextLink // empty' <<< "$page")"
  done
  rm -f "$err"
}

# --- Infrastructure kinds -----------------------------------------------------
#
# Infrastructure as code owns the network and compute of a factory or
# workspace; Git owns its logic. So the deployed template leaves out:
#   - always: managed virtual networks, Spark and SQL pools (a Synapse export
#     adds an empty stub for each pool a pipeline or notebook uses), and the
#     Data Factory itself;
#   - unless deployed (DEPLOY_MANAGED_PRIVATE_ENDPOINTS,
#     DEPLOY_INTEGRATION_RUNTIMES): managed private endpoints and
#     integration runtimes.
# Resources of those kinds that are in the folder are still exported, because
# Studio may write them, but they're never deployed (and so never deleted).

# Print the resource types to leave out of the deployed template, one JSON
# object per line: {type, kind, input}. "input" is the workflow input that
# deploys the kind, or "" if nothing does.
# Usage: arm_infrastructure_types <datafactory|synapse>
arm_infrastructure_types() {
  local service="$1" prefix
  case "$service" in
    datafactory) prefix="Microsoft.DataFactory/factories" ;;
    synapse) prefix="Microsoft.Synapse/workspaces" ;;
    *)
      log_error "Unknown service '${service}'. Use datafactory or synapse."
      return 1
      ;;
  esac
  # Usage: emit <type> <kind> [input]
  emit() {
    jq -cn --arg type "$1" --arg kind "$2" --arg input "${3:-}" '{type: $type, kind: $kind, input: $input}'
  }
  case "$service" in
    datafactory)
      emit "$prefix" "the factory itself"
      emit "${prefix}/managedVirtualNetworks" "managed virtual networks"
      ;;
    synapse)
      emit "${prefix}/managedVirtualNetworks" "managed virtual networks"
      emit "${prefix}/bigDataPools" "Spark pools"
      emit "${prefix}/sqlPools" "SQL pools"
      ;;
  esac
  if ! is_true "${DEPLOY_MANAGED_PRIVATE_ENDPOINTS:-false}"; then
    emit "${prefix}/managedVirtualNetworks/managedPrivateEndpoints" "managed private endpoints" "deploy-managed-private-endpoints"
  fi
  if ! is_true "${DEPLOY_INTEGRATION_RUNTIMES:-false}"; then
    emit "${prefix}/integrationRuntimes" "integration runtimes" "deploy-integration-runtimes"
  fi
}

# Remove the resources of the given types (arm_infrastructure_types) from a
# template, and from every remaining resource's dependsOn the entries that
# name a removed resource (or something under it: a virtual network's
# endpoints), so nothing is left depending on what isn't deployed. Types
# compare case-insensitively: templates mix integrationRuntimes and
# integrationruntimes. Writes the template to <out template> and what was
# removed to <out list>, one JSON object per line:
#   {type, name, path, kind, input, default}
# where type is the part after the service's own type (integrationRuntimes),
# path is the resource's place under the factory or workspace
# (managedVirtualNetworks/default/managedPrivateEndpoints/x), and default is
# true for what the service itself creates: the factory, the generated pool
# stubs, AutoResolveIntegrationRuntime, the default managed virtual network
# and Synapse's own synapse-ws-* endpoints.
# Usage: arm_strip_resources <template> <types file> <out template> <out list>
arm_strip_resources() {
  local template="$1" types="$2" out_template="$3" out_list="$4" result
  result="$(mktemp)"
  jq --slurpfile types "$types" '
    def segments: (.type | split("/")[2:]);
    def names:
      (.name
        | if startswith("[") then (capture("\u0027/(?<n>[^\u0027]*)\u0027\\)\\]$").n // "") else . end
        | split("/") | map(select(length > 0)));
    def place($s):
      (names) as $n
      | [range(0; $s | length) | $s[.], ($n[.] // empty)] | join("/");
    def kind_of: (.type | ascii_downcase) as $t
      | $types | map(select(.type | ascii_downcase == $t)) | first;
    def service_default:
      (segments | join("/") | ascii_downcase) as $tail
      | (names | last // "") as $name
      | if $tail == "" then true
        elif $tail == "bigdatapools" or $tail == "sqlpools" then true
        elif $tail == "integrationruntimes" then ($name | ascii_downcase) == "autoresolveintegrationruntime"
        elif $tail == "managedvirtualnetworks" then ($name | ascii_downcase) == "default"
        elif $tail == "managedvirtualnetworks/managedprivateendpoints" then ($name | test("^synapse-ws-(sql|sqlondemand|kusto)"; "i"))
        else false end;

    ($types | map(.type | ascii_downcase)) as $strip
    | (.resources // []) as $all
    | ($all | map(select((.type | ascii_downcase) as $t | $strip | index($t)))) as $removed
    | ($removed | map({
        path: ("/" + place(segments) | ascii_downcase),
        type: (.type | ascii_downcase),
        last: ((names | last // "") | ascii_downcase)})) as $gone
    # An entry names a removed resource when its path is that resource, or
    # under one that is not deployed itself (a virtual network with endpoints
    # that are deployed). The resourceId() form carries the type and name as
    # strings.
    | ($all | map(select((.type | ascii_downcase) as $t | $strip | index($t) | not)
        | "/" + place(segments) | ascii_downcase)) as $kept
    | def dangling:
        ascii_downcase as $e
        | if ($e | startswith("[concat(")) then
            (($e | capture("\u0027(?<p>/[^\u0027]*)\u0027\\)\\]$").p) // null) as $p
            | $p != null and ($kept | index($p) | not)
              and ($gone | any(. as $g | $g.path != "/" and ($p == $g.path or ($p | startswith($g.path + "/")))))
          elif ($e | startswith("[resourceid(")) then
            $gone | any(. as $g | $g.last != "" and ($e | contains("\u0027" + $g.type + "\u0027")) and ($e | contains("\u0027" + $g.last + "\u0027")))
          else false end;
      {
        template: (.resources = [ $all[]
          | select((.type | ascii_downcase) as $t | $strip | index($t) | not)
          | if (.dependsOn | type) == "array" then .dependsOn |= map(select(dangling | not)) else . end ]),
        removed: ($removed | map(kind_of as $k | {
          type: ($k.type | split("/")[2:] | join("/")),
          name: (names | last // ""),
          path: (place($k.type | split("/")[2:]) | if . == "" then "factory" else . end),
          kind: $k.kind,
          input: $k.input,
          default: service_default }))
      }' "$template" > "$result"
  jq '.template' "$result" > "$out_template"
  jq -c '.removed[]' "$result" > "$out_list"
  rm -f "$result"
}

# Print the "Left to infrastructure as code" section for a list made by
# arm_strip_resources: a warning for each file the author wrote that is left
# out, and the whole list. Prints nothing for an empty list.
# Usage: arm_left_to_iac_markdown <list>
arm_left_to_iac_markdown() {
  local list="$1" count
  count="$(grep -c . "$list" || true)"
  [ "$count" -gt 0 ] || return 0
  if [ -n "$(jq -r 'select(.default | not) | .path' "$list")" ]; then
    echo "> **Warning:** these are in the folder, but this workflow leaves them to infrastructure as code, so they aren't deployed. Define them in your infrastructure as code, or remove the files:"
    jq -r 'select(.default | not) | "> - `\(.path)`"' "$list"
    echo ""
  fi
  echo "<details><summary>Left to infrastructure as code (${count})</summary>"
  echo ""
  echo "| Resource | Kind | In the folder as |"
  echo "| --- | --- | --- |"
  jq -r '"| `\(.path)` | \(.kind) | \(if .default then "service default or generated" else "a file you wrote" end) |"' "$list"
  echo ""
  echo "</details>"
}

# Log a warning for each resource of the list (arm_strip_resources) that
# isn't a service default, so it's an annotation on the run
# Usage: arm_left_to_iac_warn <list>
arm_left_to_iac_warn() {
  local path kind input reason
  while IFS=$'\t' read -r path kind input; do
    [ -n "$path" ] || continue
    if [ -n "$input" ]; then
      reason="(${input} is false)"
    else
      reason="(this workflow never deploys them)"
    fi
    log_warn "${path} is in the folder, but this workflow leaves ${kind} to infrastructure as code ${reason}: it isn't deployed. Define it in your infrastructure as code, or remove the file."
  done < <(jq -r 'select(.default | not) | [.path, .kind, .input] | @tsv' "$1")
}

# --- Live state ---------------------------------------------------------------
#
# A plan records a fingerprint of the live factory or workspace's logic
# (and of the infrastructure kinds the call deploys), and the apply lists the
# same kinds again: a different fingerprint means something else changed it
# since the plan (another deployment, or the portal), and applying would
# undo that or delete it.

# Print the resources of some collections of a factory or workspace, one
# compact JSON object {type, name, etag} per line, listing each collection
# under <base url> (a virtual network's endpoints, managedVirtualNetworks/
# default/managedPrivateEndpoints, are typed managedVirtualNetworks/
# managedPrivateEndpoints). Fails if a collection can't be listed; az's
# error goes to stderr.
# Usage: arm_live_lines <base url> <api version> <audience or ""> <collection>...
arm_live_lines() {
  local base="$1" version="$2" audience="$3" collection type
  local -a options=()
  shift 3
  if [ -n "$audience" ]; then
    options=(--resource "$audience")
  fi
  for collection in "$@"; do
    type="${collection/\/default\//\/}"
    arm_rest_list "${base}/${collection}?api-version=${version}" "${options[@]+"${options[@]}"}" |
      jq -c --arg type "$type" '{type: $type, name: .name, etag: (.etag // "")}' || return 1
  done
}

# Print the fingerprint of a file of arm_live_lines: the SHA-256 of its
# lines, sorted, so the order of listing doesn't matter.
# Usage: arm_live_fingerprint <lines file>
arm_live_fingerprint() {
  local lines
  lines="$(jq -c '{type: .type, name: .name, etag: .etag}' "$1" | LC_ALL=C sort)"
  text_sha256 "$lines"
}

# The same for a Synapse workspace's listing, less what the service creates
# itself (the default linked services and credential, and the synapse-ws-*
# endpoints): deployments skip them, so they say nothing about a change.
# Usage: arm_synapse_fingerprint <lines file>
arm_synapse_fingerprint() {
  local lines
  lines="$(mktemp)"
  jq -c 'select(.name | test("workspacedefaultsqlserver|workspacedefaultstorage|workspacesystemidentity|^synapse-ws-(sql|sqlondemand|kusto)"; "i") | not)' "$1" > "$lines"
  arm_live_fingerprint "$lines"
  rm -f "$lines"
}

# Fail unless a fresh fingerprint (arm_live_fingerprint, or
# arm_synapse_fingerprint) is the one the plan recorded in its
# deploy/live.json.
# Usage: arm_verify_live "<Factory|Workspace>" "<name>" "<plan dir>" "<fingerprint now>"
arm_verify_live() {
  local what="$1" name="$2" plan_dir="$3" now="$4" planned
  planned="$(jq -r .fingerprint "$plan_dir/deploy/live.json")"
  if [ "$planned" != "$now" ]; then
    log_error "${what} ${name} changed since this plan (another deployment, or a change made in the portal). Re-run the workflow to plan again, then approve that run."
    return 1
  fi
  log_success "${what} ${name} is as it was when planned"
}

# --- Plans --------------------------------------------------------------------
#
# A plan directory holds summary.md and deploy/: the template, the rendered
# parameters (no secrets) and target.json (what to deploy to). The plan's
# SHA-256 covers deploy/, so the apply deploys exactly what was reviewed.

# Print the markdown for a failed plan: what failed, and the end of its log
# (colour codes and workflow commands stripped), so the PR comment says the
# plan failed instead of showing the previous push's plan.
# Usage: arm_failure_markdown "<what failed>" "<log file>"
arm_failure_markdown() {
  local message="$1" log="$2" cleaned
  echo "### ❌ Plan failed"
  echo ""
  context_line
  echo ""
  echo "${message} Nothing can be deployed until the plan succeeds."
  echo ""
  if [ -s "$log" ]; then
    cleaned="$(mktemp)"
    tail -n 100 "$log" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -v '^::' > "$cleaned" || true
    collapsible_block "Output (last 100 lines)" "text" "$cleaned"
    rm -f "$cleaned"
  fi
}

# Print a plan's SHA-256. Usage: arm_plan_sha256 "<plan dir>"
arm_plan_sha256() {
  dir_sha256 "$1/deploy"
}

# Fail unless a plan directory is there and matches the plan job's digest.
# PLAN_SHA256 is required in GitHub Actions.
# Usage: arm_verify_plan "<plan dir>"
arm_verify_plan() {
  local plan_dir="$1" actual
  if [ ! -f "$plan_dir/deploy/target.json" ]; then
    log_error "No plan at ${plan_dir}/deploy. Plan artifacts expire (plan-retention-days); re-run the whole workflow to plan again."
    return 1
  fi
  if is_github_actions; then
    require_env PLAN_SHA256 "It comes from the plan job's plan-sha256 output; check the workflow passes it to the apply action."
  fi
  if [ -n "${PLAN_SHA256:-}" ]; then
    actual="$(arm_plan_sha256 "$plan_dir")"
    if [ "$actual" != "$PLAN_SHA256" ]; then
      log_error "The plan's sha256 is ${actual}, but the plan job produced ${PLAN_SHA256}. Refusing to deploy a plan that isn't the one that was reviewed; re-run the whole workflow."
      return 1
    fi
    log_success "Plan matches the reviewed plan (sha256 ${PLAN_SHA256})"
  fi
}
