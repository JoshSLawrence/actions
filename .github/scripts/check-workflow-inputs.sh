#!/usr/bin/env bash
#
# Checks the OpenTofu reusable workflows stay in sync where they share
# inputs, so an input means the same thing -- with the same type, default and
# description -- whichever workflow a caller uses:
#
#   opentofu.yaml         --calls-->  opentofu-config.yaml  (job: config)
#   opentofu-config.yaml  --calls-->  opentofu-deploy.yaml  (job: deploy)
#   opentofu-drift.yaml   shares inputs with opentofu.yaml  (no call)
#
# For a calling pair it checks that:
#   1. every input of the called workflow is also an input of the caller,
#      unless the called workflow owns it (INNER_ONLY) or the caller works it
#      out itself (COMPUTED), and the caller adds only OUTER_ONLY inputs;
#   2. shared inputs are defined identically;
#   3. both declare the same secrets; and
#   4. the caller passes every shared input and secret through unchanged.
# For a non-calling pair, only that the inputs and secrets they share are
# defined identically (except COMPUTED ones).
#
# Run by pre-commit and CI. Needs yq and jq.
#

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=opentofu/scripts/common.sh
source opentofu/scripts/common.sh

require_tool jq
if ! command_exists yq; then
  log_error "yq is not installed. Run 'mise install' in the repository root."
  exit 1
fi

WORKFLOWS=.github/workflows
failures=0

# Usage: check_pair <outer> <inner> <call job, or "" for none>
#                   <INNER_ONLY json> <OUTER_ONLY json> <COMPUTED json>
check_pair() {
  local outer="$WORKFLOWS/$1" inner="$WORKFLOWS/$2" job="$3"
  local problems
  problems="$(jq -rn \
    --arg outer_file "$outer" --arg inner_file "$inner" --arg job "$job" \
    --argjson outer "$(yq -o=json '.' "$outer")" \
    --argjson inner "$(yq -o=json '.' "$inner")" \
    --argjson inner_only "$4" --argjson outer_only "$5" --argjson computed "$6" '
    ($outer.on.workflow_call) as $o
    | ($inner.on.workflow_call) as $i
    | ($o.inputs | keys) as $ok
    | ($i.inputs | keys) as $ik
    | (($ok - ($ok - $ik)) - $computed) as $shared
    | ($o.secrets // {}) as $os
    | ($i.secrets // {}) as $is
    | (
        # 2: shared inputs identical
        ( $shared[] | select($o.inputs[.] != $i.inputs[.])
          | "\(.): defined differently in \($outer_file) and \($inner_file) (type, default or description). Make them identical." ),
        # secrets both have identical
        ( ($os | keys) - (($os | keys) - ($is | keys)) | .[] | select($os[.] != $is[.])
          | "secret \(.): defined differently in \($outer_file) and \($inner_file). Make them identical." ),
        ( if $job == "" then empty else
            # 1: nothing missing, nothing extra
            ( ($ik - $ok - $inner_only - $computed)[]
              | "\(.): input of \($inner_file) missing from \($outer_file). Add it there with the same definition." ),
            ( ($ok - $ik - $outer_only)[]
              | "\(.): input of \($outer_file) that \($inner_file) does not have. Add it there, or list it as OUTER_ONLY in this script if only \($outer_file) uses it." ),
            # 3: same secrets
            ( if ($os | keys) != ($is | keys) then
                "\($outer_file) and \($inner_file) declare different secrets. Declare the same ones in both."
              else empty end ),
            # 4: passed through unchanged
            ( $outer.jobs[$job].with as $with
              | $shared[] | select(($with[.] // "") != "${{ inputs.\(.) }}")
              | "\(.): \($outer_file) jobs.\($job) must pass it as `${{ inputs.\(.) }}`." ),
            ( $outer.jobs[$job].secrets as $with
              | ($is | keys)[] | select(($with[.] // "") != "${{ secrets.\(.) }}")
              | "secret \(.): \($outer_file) jobs.\($job) must pass it as `${{ secrets.\(.) }}`." )
          end )
      )')"
  if [ -n "$problems" ]; then
    while IFS= read -r problem; do
      log_error "$problem"
      failures=$((failures + 1))
    done <<< "$problems"
  else
    log_success "$1 and $2 are in sync"
  fi
}

check_pair opentofu.yaml opentofu-config.yaml config \
  '["working-directory", "stack-name", "preflight-paths"]' \
  '["search-root", "exclude", "modules", "changed-only", "shared-paths"]' \
  '["deployments"]'

check_pair opentofu-config.yaml opentofu-deploy.yaml deploy \
  '["deployment"]' \
  '["deployments", "max-parallel", "fmt", "validate", "tflint", "trivy", "trivy-severity", "docs", "tests", "test-filter", "test-verbose", "integration-tests", "integration-test-filter", "integration-test-environment", "integration-test-timeout-minutes"]' \
  '["var-files", "backend-config", "plan-environment", "apply-environment", "preflight-paths"]'

check_pair opentofu-drift.yaml opentofu.yaml "" '[]' '[]' '["plan-environment"]'

if [ "$failures" -gt 0 ]; then
  log_error "${failures} problem(s) keeping the OpenTofu workflows in sync. See .github/scripts/check-workflow-inputs.sh for the rules."
  exit 1
fi
