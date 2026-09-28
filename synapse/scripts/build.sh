#!/usr/bin/env bash
#
# Validates a Synapse workspace Git folder and exports its workspace
# template -- what "Publish" does in Synapse Studio, without Studio or a
# workspace_publish branch. Runs offline: it needs no Azure credentials, and
# changes nothing, so it's safe to run locally and on PRs from forks.
#
#   WORKING_DIR=synapse synapse/scripts/build.sh
#
# Environment variables:
#   WORKING_DIR    - the workspace's Git root folder, with its own mise.toml
#                    pinning node (required)
#   WORKSPACE_NAME - name of the development workspace (default: taken from
#                    its <name>-WorkspaceDefaultStorage linked service, else
#                    the folder's name). Every deployment sets its own
#                    workspaceName.
#   OUTPUT_DIR     - where the template goes (default:
#                    $RUNNER_TEMP/synapse-template)
#   WORK_DIR       - scratch directory (default: $RUNNER_TEMP/synapse-build)
#   BUNDLE_URL     - where to download the export bundle from (default:
#                    Microsoft's, as used by Azure/Synapse-workspace-deployment)
#   BUNDLE_PATH    - a downloaded copy of the bundle to use instead
#
# Outputs:
#   template-dir   - absolute path of OUTPUT_DIR: TemplateForWorkspace.json
#                    and TemplateParametersForWorkspace.json
#   resource-count - artifacts in the template
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
OUTPUT_DIR="${OUTPUT_DIR:-$TMP_ROOT/synapse-template}"
WORK_DIR="${WORK_DIR:-$TMP_ROOT/synapse-build}"
BUNDLE_URL="${BUNDLE_URL:-https://web.azuresynapse.net/assets/cmd-api/main.js}"

rm -rf "$OUTPUT_DIR" "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd_working_dir
require_mise_tool node

if [ -z "${WORKSPACE_NAME:-}" ]; then
  WORKSPACE_NAME="$(jq -rs 'map(.name // empty | select(endswith("-WorkspaceDefaultStorage")) | rtrimstr("-WorkspaceDefaultStorage")) | first // empty' linkedService/*.json 2> /dev/null || true)"
  WORKSPACE_NAME="${WORKSPACE_NAME:-$(basename "$PWD")}"
fi
log_config WORKING_DIR WORKSPACE_NAME OUTPUT_DIR BUNDLE_URL BUNDLE_PATH

log_step "Stage the workspace's artifacts"
if ! resource_files="$(arm_stage_json_files . "$WORK_DIR/src")"; then
  exit 1
fi
log_info "${resource_files} .json file(s) staged"
if [ "$resource_files" -eq 0 ]; then
  log_error "No .json files in ${WORKING_DIR}. working-directory must be the workspace's Git root folder (the one holding notebook/, pipeline/, linkedService/, ...)."
  exit 1
fi

log_step "Download the export bundle"
bundle_sha256="$(arm_download_bundle "$BUNDLE_URL" "$WORK_DIR/main.js")"
log_info "Bundle sha256: ${bundle_sha256}"

log_step "Validate and export the workspace template"
if ! arm_run_bundle "$WORK_DIR" "$WORK_DIR/main.js" "$WORK_DIR/export.log" export "$WORK_DIR/src" "$WORKSPACE_NAME" out; then
  log_error "Validation or export failed. Fix the errors above (the same ones Synapse Studio shows on publish) and push again."
  exit 1
fi
if [ ! -f "$WORK_DIR/out/TemplateForWorkspace.json" ]; then
  log_error "The export bundle didn't write TemplateForWorkspace.json. See its output above; if it reports 'Publishable resource count: 0', check working-directory is the workspace's Git root folder."
  exit 1
fi
cp -R "$WORK_DIR/out/." "$OUTPUT_DIR/"

template="$OUTPUT_DIR/TemplateForWorkspace.json"
resource_count="$(jq '.resources | length' "$template")"
parameter_count="$(jq '.parameters | length' "$template")"

{
  echo "### 🏗️ Synapse template: \`${WORKING_DIR}\`"
  echo ""
  echo "Validated and exported ${resource_count} artifact(s) with ${parameter_count} parameter(s). Export bundle sha256 \`${bundle_sha256:0:12}\`."
  echo ""
  arm_template_markdown "$template"
  echo ""
} | tee >(append_step_summary) | sed 's/^/  /'

set_output template-dir "$OUTPUT_DIR"
set_output resource-count "$resource_count"
set_output bundle-sha256 "$bundle_sha256"
log_summary "Exported ${resource_count} artifact(s) to ${OUTPUT_DIR}"
