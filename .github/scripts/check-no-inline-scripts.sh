#!/usr/bin/env bash
#
# Enforces "no inline scripts in YAML": every `run:` in the workflows,
# composite actions and examples must be a single command -- normally one
# script -- with no newlines, `;`, `&&`, `||` or pipes. Logic belongs in a
# script, where it can be read, shellchecked and run locally.
#
# Run by pre-commit and CI. Needs yq and jq.
#

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=shared/scripts/common.sh
source shared/scripts/common.sh

require_tool jq
if ! command_exists yq; then
  log_error "yq is not installed. Run 'mise install' in the repository root."
  exit 1
fi

failures=0
while IFS= read -r file; do
  [ -f "$file" ] || continue
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    log_error "${file}: inline script in a run step: ${run}. Move it into a script (e.g. <area>/scripts/<name>.sh) and run that."
    failures=$((failures + 1))
  done < <(yq -o=json '[.. | select(tag == "!!map" and has("run")) | .run]' "$file" |
    jq -r '.[] | select(test("\n|;|&&|\\|")) | gsub("\n"; "⏎")')
done < <(git ls-files --cached --others --exclude-standard \
  '.github/workflows/*.yaml' '.github/workflows/*.yml' '*/action.yaml' '*/action.yml' \
  'examples/*.yaml' 'examples/*.yml' | sort -u)

if [ "$failures" -gt 0 ]; then
  log_error "${failures} inline script(s) found."
  exit 1
fi
log_success "Every run step is a single command"
