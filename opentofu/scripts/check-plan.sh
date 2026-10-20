#!/usr/bin/env bash
#
# Checks the downloaded plan is the one the plan job made, before anything
# says it's being applied: the plan file must be there and its digest must
# match the plan job's. apply.sh checks it again right before applying.
#
# Environment variables:
#   PLAN_DIR    - directory holding tfplan, as downloaded from the plan
#                 artifact (default: $RUNNER_TEMP/tofu-plan)
#   PLAN_SHA256 - expected digest of tfplan, from the plan job (required in
#                 GitHub Actions)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opentofu/scripts/common.sh
source "$SCRIPT_DIR/common.sh"

PLAN_DIR="${PLAN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tofu-plan}"

log_config PLAN_DIR PLAN_SHA256

check_saved_plan "$PLAN_DIR"
