#!/usr/bin/env bash
#
# Validates a Data Factory Git folder and exports its ARM template -- what
# "Validate all" and "Publish" do in the Data Factory UI, without the UI and
# without an adf_publish branch. Runs offline: it needs no Azure credentials,
# and changes nothing, so it's safe to run locally and on PRs from forks.
#
#   WORKING_DIR=adf datafactory/scripts/build.sh
#
# Environment variables:
#   WORKING_DIR  - the factory's Git root folder, with its own mise.toml
#                  pinning node (required)
#   FACTORY_NAME - name of the development factory, the default value of the
#                  template's factoryName parameter (default: the name in the
#                  folder's factory/*.json, else the folder's name). Every
#                  deployment sets its own.
#   OUTPUT_DIR   - where the template goes (default:
#                  $RUNNER_TEMP/datafactory-template)
#   WORK_DIR     - scratch directory (default: $RUNNER_TEMP/datafactory-build)
#   BUNDLE_URL   - where to download the export bundle from (default:
#                  Microsoft's, as used by @microsoft/azure-data-factory-utilities)
#   BUNDLE_PATH  - a downloaded copy of the bundle to use instead
#
# Outputs:
#   template-dir   - absolute path of OUTPUT_DIR: ARMTemplateForFactory.json,
#                    ARMTemplateParametersForFactory.json,
#                    PrePostDeploymentScript.ps1, ...
#   resource-count - resources in the template
#   bundle-sha256  - digest of the export bundle that ran
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$SCRIPT_DIR/../../shared/scripts/common.sh"
# shellcheck source=shared/scripts/arm.sh
source "$SCRIPT_DIR/../../shared/scripts/arm.sh"

ensure_mise
require_tool jq
require_tool curl

TMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
OUTPUT_DIR="${OUTPUT_DIR:-$TMP_ROOT/datafactory-template}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/datafactory-build}"
BUNDLE_URL="${BUNDLE_URL:-https://adf.azure.com/assets/cmd-api/main.js}"

# ARM rejects templates over 4 MB. Factories that big need linked templates
# (hosted in a storage account), which these actions don't deploy.
ARM_TEMPLATE_LIMIT=$((4 * 1024 * 1024))

rm -rf "$OUTPUT_DIR" "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd_working_dir
require_mise_tool node

if [ -z "${FACTORY_NAME:-}" ]; then
  FACTORY_NAME="$(jq -rs 'map(.name // empty) | first // empty' factory/*.json 2> /dev/null || true)"
  FACTORY_NAME="${FACTORY_NAME:-$(basename "$PWD")}"
fi
log_config WORKING_DIR FACTORY_NAME OUTPUT_DIR BUNDLE_URL BUNDLE_PATH

log_step "Stage the factory's resources"
if ! resource_files="$(arm_stage_json_files . "$WORK_DIR/src")"; then
  exit 1
fi
log_info "${resource_files} .json file(s) staged"
if [ "$resource_files" -eq 0 ]; then
  log_error "No .json files in ${WORKING_DIR}. working-directory must be the factory's Git root folder (the one holding pipeline/, dataset/, linkedService/, ...)."
  exit 1
fi

log_step "Download the export bundle"
bundle_sha256="$(arm_download_bundle "$BUNDLE_URL" "$WORK_DIR/main.js")"
log_info "Bundle sha256: ${bundle_sha256}"

log_step "Validate and export the ARM template"
# The factory ID only names the development factory in the template's
# defaults: the export never contacts Azure, so a placeholder subscription
# and resource group are fine.
factory_id="/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/build/providers/Microsoft.DataFactory/factories/${FACTORY_NAME}"
if ! arm_run_bundle "$WORK_DIR" "$WORK_DIR/main.js" "$WORK_DIR/export.log" export "$WORK_DIR/src" "$factory_id" out; then
  log_error "Validation or export failed. Fix the errors above (the same ones 'Validate all' shows in the Data Factory UI) and push again."
  exit 1
fi
if [ ! -f "$WORK_DIR/out/ARMTemplateForFactory.json" ]; then
  log_error "The export bundle didn't write ARMTemplateForFactory.json. See its output above; if it reports 'Publishable resource count: 0', check working-directory is the factory's Git root folder."
  exit 1
fi
cp -R "$WORK_DIR/out/." "$OUTPUT_DIR/"

template="$OUTPUT_DIR/ARMTemplateForFactory.json"
size=$(wc -c < "$template" | tr -d ' ')
if [ "$size" -gt "$ARM_TEMPLATE_LIMIT" ]; then
  log_error "ARMTemplateForFactory.json is ${size} bytes, over ARM's 4 MB template limit. Deploying a factory this large needs linked templates, which these actions don't support; split the factory, or deploy linkedTemplates/ from a storage account yourself."
  exit 1
fi

resource_count="$(jq '.resources | length' "$template")"
parameter_count="$(jq '.parameters | length' "$template")"

{
  echo "### 🏗️ Data Factory template: \`${WORKING_DIR}\`"
  echo ""
  echo "Validated and exported ${resource_count} resource(s) with ${parameter_count} parameter(s). Export bundle sha256 \`${bundle_sha256:0:12}\`."
  echo ""
  arm_template_markdown "$template"
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output template-dir "$OUTPUT_DIR"
set_output resource-count "$resource_count"
set_output bundle-sha256 "$bundle_sha256"
log_summary "Exported ${resource_count} resource(s) to ${OUTPUT_DIR}"
