#!/usr/bin/env bash
#
# Makes sure every tool a job needs has a version, after jdx/mise-action has
# installed whatever the repository's mise config pins. A tool pinned in the
# repository's mise config (mise.toml, .tool-versions, ... in WORKING_DIR or
# any parent) always wins; one that isn't pinned is installed globally at the
# version from its *_VERSION variable, or the default below.
#
# Environment variables:
#   WORKING_DIR            - root module the tools run in (default: .)
#   TOOLS                  - mise tool names to make available, space- or
#                            newline-separated (default: opentofu)
#   OPENTOFU_VERSION, TFLINT_VERSION, TRIVY_VERSION, TERRAFORM_DOCS_VERSION,
#   CONFTEST_VERSION, INFRACOST_VERSION
#                          - fallback version for a tool the mise config
#                            doesn't pin (default: see DEFAULT_VERSIONS)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

# Fallback versions for tools the repository doesn't pin. Keep in sync with
# the repo-root mise.toml (which the test fixture is checked with) and the
# tables in opentofu/README.md.
declare -A DEFAULT_VERSIONS=(
  [opentofu]="1.12.6"
  [tflint]="0.64.0"
  [trivy]="0.74.0"
  [terraform-docs]="0.24.0"
  [conftest]="0.69.0"
  [infracost]="0.10.45"
)

ensure_mise
export WORKING_DIR="${WORKING_DIR:-.}"
TOOLS="${TOOLS:-opentofu}"
log_config WORKING_DIR TOOLS
cd_working_dir

# "tofu" is accepted as an alias for mise's "opentofu"
mapfile -t tools < <(list_items "$TOOLS" | sed 's/^tofu$/opentofu/' | sort -u)

for tool in "${tools[@]}"; do
  if [ -z "${DEFAULT_VERSIONS[$tool]+set}" ]; then
    log_error "Unknown tool '$tool' in the tools input. Supported: ${!DEFAULT_VERSIONS[*]}."
    exit 1
  fi

  # opentofu -> OPENTOFU_VERSION, terraform-docs -> TERRAFORM_DOCS_VERSION
  version_var="$(echo "${tool}_VERSION" | tr '[:lower:]-' '[:upper:]_')"
  requested="${!version_var:-}"
  pinned="$(mise current "$tool" 2> /dev/null || true)"

  if [ -n "$pinned" ]; then
    log_success "$tool $pinned (pinned by the repository's mise config)"
    if [ -n "$requested" ] && [ "$requested" != "$pinned" ]; then
      log_warn "Ignoring ${tool} version input '${requested}': the repository's mise config pins ${pinned}, and the mise config always wins. Change the pin there instead."
    fi
    continue
  fi

  version="${requested:-${DEFAULT_VERSIONS[$tool]}}"
  log_info "$tool isn't pinned by the repository's mise config; installing fallback version $version"
  log_cmd mise use --global "${tool}@${version}"
  if ! mise use --global "${tool}@${version}"; then
    log_error "Could not install ${tool}@${version}. Check the version exists ('mise ls-remote ${tool}') and fix the ${version_var,,} input, or pin ${tool} in your mise.toml."
    exit 1
  fi
done

# Installs anything pinned but not yet installed (e.g. when mise-action's
# cache was restored from a different config)
mise install

log_info "Tool versions for ${WORKING_DIR}:"
mise ls --current
