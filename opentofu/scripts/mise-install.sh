#!/usr/bin/env bash
#
# Installs exactly the tools a root module's own mise config pins (its
# mise.toml) -- nothing from parent directories such as the repository root,
# or from global config -- and checks that every tool the job needs is among
# them. Missing ones are listed all at once, rather than failing one check
# at a time. See scope_mise_to_module in common.sh for how.
#
# Environment variables:
#   WORKING_DIR    - root module directory (required)
#   REQUIRED_TOOLS - mise tool names the job needs, space- or
#                    newline-separated (default: opentofu). "tofu" is
#                    accepted for opentofu.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ensure_mise
REQUIRED_TOOLS="${REQUIRED_TOOLS:-opentofu}"
log_config WORKING_DIR REQUIRED_TOOLS
cd_working_dir

config_found=false
for config in mise.toml .mise.toml mise/config.toml .mise/config.toml .config/mise.toml .config/mise/config.toml; do
  if [ -f "$config" ]; then
    config_found=true
    break
  fi
done
if [ "$config_found" = false ]; then
  log_error "No mise config in ${WORKING_DIR}. Every root module pins its own tools: add a mise.toml there, e.g. 'mise use opentofu@<version>' (plus tflint, trivy, ... for the checks you enable)."
  exit 1
fi

log_cmd mise install
if ! mise install; then
  log_error "mise install failed in ${WORKING_DIR}. Check each tool and version in its mise config exists ('mise ls-remote <tool>')."
  exit 1
fi

log_info "Tools for ${WORKING_DIR}:"
mise ls --current

missing=()
while IFS= read -r tool; do
  if [ -z "$(mise current "$tool" 2> /dev/null)" ]; then
    missing+=("$tool")
  fi
done < <(list_items "$REQUIRED_TOOLS" | sed 's/^tofu$/opentofu/' | sort -u)

if [ ${#missing[@]} -gt 0 ]; then
  log_error "${WORKING_DIR}'s mise config doesn't pin: ${missing[*]}. The enabled checks need them; add them there (e.g. 'mise use ${missing[0]}@<version>'), or turn those checks off. Tools pinned in parent directories, like the repository root, aren't used."
  exit 1
fi

log_success "Every tool the job needs is pinned: $(list_items "$REQUIRED_TOOLS" | tr '\n' ' ')"
