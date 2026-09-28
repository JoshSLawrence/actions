#!/usr/bin/env bash
#
# Runs every pre-commit hook against every file: CI's lint job, and the
# same check you can run locally before pushing. Tools come from the
# repository-root mise.toml.
#
# check-added-large-files is skipped: it only looks at staged files, so it
# can only ever fire on a local commit.
#

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=opentofu/scripts/common.sh
source opentofu/scripts/common.sh

ensure_mise

log_cmd pre-commit run --all-files --show-diff-on-failure
if ! SKIP=check-added-large-files mise exec -- pre-commit run --all-files --show-diff-on-failure; then
  log_error "Lint failed. Run '.github/scripts/lint.sh' locally to reproduce, fix the findings, and commit."
  exit 1
fi
log_success "Lint passed"
