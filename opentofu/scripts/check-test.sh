#!/usr/bin/env bash
#
# Runs OpenTofu's native tests (tofu test). Skips, with a notice, when the
# module has no test files.
#
# Environment variables:
#   WORKING_DIR          - root module to test (required)
#   TEST_FILTER          - test files to run, relative to WORKING_DIR,
#                          space- or newline-separated; globs allowed, e.g.
#                          "tests/0*.tftest.hcl" (default: every test file)
#   TEST_VERBOSE         - "true" to pass -verbose (default: false)
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

if ! compgen -G "*.tftest.hcl" > /dev/null && ! compgen -G "tests/*.tftest.hcl" > /dev/null; then
  log_notice "No test files in ${WORKING_DIR} (*.tftest.hcl or tests/*.tftest.hcl); skipping tofu test."
  exit 0
fi

args=()
if is_true "${TEST_VERBOSE:-false}"; then
  args+=(-verbose)
fi

if [ -n "${TEST_FILTER:-}" ]; then
  matched=()
  while IFS= read -r pattern; do
    mapfile -t files < <(compgen -G "$pattern" | sort || true)
    if [ ${#files[@]} -eq 0 ]; then
      log_warn "Test filter '${pattern}' matches no files in ${WORKING_DIR}."
    fi
    matched+=("${files[@]+"${files[@]}"}")
  done < <(list_items "$TEST_FILTER")

  if [ ${#matched[@]} -eq 0 ]; then
    log_error "The test filter matches no test files in ${WORKING_DIR}, so nothing would be tested. Fix the test-filter input (paths are relative to the working directory)."
    exit 1
  fi
  for file in "${matched[@]}"; do
    args+=("-filter=${file}")
  done
fi

# tofu test needs an initialized directory; don't rely on an earlier step
# having run init (the integration job starts from a fresh checkout).
log_cmd tofu init -backend=false -input=false
if ! mise exec -- tofu init -backend=false -input=false > /dev/null; then
  log_error "tofu init failed in ${WORKING_DIR}. Run 'tofu init -backend=false' there to see the full error."
  exit 1
fi

log_cmd tofu test "${args[@]+"${args[@]}"}"
if mise exec -- tofu test "${args[@]+"${args[@]}"}"; then
  log_success "Tests passed"
else
  log_error "tofu test failed in ${WORKING_DIR}. Run 'tofu test' there to reproduce (tests that create real infrastructure need cloud credentials)."
  exit 1
fi
