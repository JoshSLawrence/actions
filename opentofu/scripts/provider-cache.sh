#!/usr/bin/env bash
#
# Prepares OpenTofu's provider plugin cache for the rest of the job: creates
# CACHE_DIR and points TF_PLUGIN_CACHE_DIR at it. Every `tofu init` in the job
# (checks, tests, plan, apply) then installs a provider into the cache once
# and links it into .terraform, and the actions/cache step that follows this
# one brings the cache back from an earlier run or job.
#
# This is safe with the module's lock file, including -lockfile=readonly,
# which is why TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE is not set:
# OpenTofu uses a cached provider only if its checksum is one of the lock
# file's. Otherwise (a lock file that records only zh: hashes, or h1: hashes
# of other platforms) it downloads and verifies the provider as usual, and
# the cache just doesn't save the download. Commit h1: hashes for the
# runner's platform for it to pay off:
#   tofu providers lock -platform=linux_amd64
#
# Environment variables:
#   CACHE_DIR   - where the cache lives (required); made absolute, because
#                 every tool runs from inside the root module
#   WORKING_DIR - the root module, to say whether it has a lock file
#                 (optional)
#
# Outputs:
#   dir - absolute path of the cache directory
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

require_env CACHE_DIR
log_config CACHE_DIR WORKING_DIR

mkdir -p "$CACHE_DIR"
dir="$(cd "$CACHE_DIR" && pwd)"

export_job_env TF_PLUGIN_CACHE_DIR "$dir"
set_output dir "$dir"

if [ -n "${WORKING_DIR:-}" ] && [ ! -f "${WORKING_DIR}/.terraform.lock.hcl" ]; then
  log_info "No .terraform.lock.hcl in ${WORKING_DIR}: the provider cache is keyed on the runner's OS and architecture only, so it won't follow provider upgrades."
fi
log_success "Providers are cached in ${dir} (TF_PLUGIN_CACHE_DIR)"
