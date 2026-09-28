#!/usr/bin/env bash
#
# Validate check: `tofu init -backend=false` then `tofu validate`. Needs no
# credentials: the backend isn't configured, only modules and providers are
# downloaded.
#
# Environment variables:
#   WORKING_DIR          - root module to check (required)
#   MODULES_GITHUB_TOKEN - lets init fetch module sources from private GitHub
#                          repositories (optional)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

cd_working_dir
ensure_mise
require_mise_tool opentofu
configure_git_github_auth

log_cmd tofu init -backend=false -input=false
set +e
init_output=$(mise exec -- tofu init -backend=false -input=false 2>&1)
init_exit=$?
set -e

if [ "$init_exit" -ne 0 ]; then
  echo "$init_output"
  # Surface the common auth failure with a fix, rather than letting validate
  # fail later with a vaguer "module not installed" error.
  if echo "$init_output" | grep -qiE "could not read (Username|Password)|permission denied|repository.*not found|authentication failed|401|403"; then
    log_error "tofu init failed with what looks like a Git authentication error. If a module source is another private repository, the default token can't read it: pass a token that can (e.g. a GitHub App token) as the modules-token secret."
    exit 1
  fi
  # Otherwise carry on: validate reports what's missing more clearly
  log_warn "tofu init -backend=false failed (exit ${init_exit}); running validate anyway for a clearer error."
fi

log_cmd tofu validate
if mise exec -- tofu validate; then
  log_success "Validate passed"
else
  log_error "tofu validate failed in ${WORKING_DIR}. Run 'tofu init -backend=false && tofu validate' there to reproduce."
  exit 1
fi
