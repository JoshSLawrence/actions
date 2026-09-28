# AGENTS.md

Instructions for agents working in this repository.

## What this repo is

A library of reusable GitHub Actions workflows and composite actions,
consumed from other repositories as
`JoshSLawrence/actions/.github/workflows/<name>.yaml@<ref>` and
`JoshSLawrence/actions/<area>/<action>@<ref>`. See README.md for the
catalog and layout.

## Architecture

- **Scripts hold the logic.** Composite actions (`<area>/<action>/action.yaml`)
  and workflows wire inputs to scripts in `<area>/scripts/` through `env:`.
  Keep `run:` blocks to a line or two; put anything more in a script.
- **Reusable workflows compose composite actions** with the self-repository
  syntax, `uses: $/<area>/<action>`, never `./` or `owner/repo@ref`. `$/`
  resolves to this repository at the commit being run, so the actions match
  the caller's pinned ref, and CI tests a PR's own changes. actionlint 1.7.12
  doesn't know `$/` yet; `.github/actionlint.yaml` ignores exactly those
  messages (user-approved). Remove it when actionlint supports `$/`.
- **Composite actions find their scripts** via
  `"${GITHUB_ACTION_PATH}/../scripts/<script>.sh"`.
- **Paths:** composite action inputs are relative to the workspace. With the
  caller's repository checked out at the workspace root, that's the same as
  relative to the repository root.
- **Every script runs locally too.** Outputs and summaries degrade to logging
  outside Actions (see `set_output` and `append_step_summary` in
  `common.sh`).

## Conventions

- **Pin third-party actions to a full commit SHA** with a `# vX.Y.Z` comment.
  Dependabot updates them in `.github/` and in every `opentofu/*` action.
  Bump `mise-version` by hand.
- **Least privilege.** Workflows set `permissions: {}` and grant per job.
  The permissions a reusable workflow's jobs request become the caller's
  minimum, so adding one is a breaking change: document it in the README's
  quick start and examples.
- **No untrusted input in `run:`.** Pass `${{ }}` values through `env:`.
  zizmor enforces this.
- **Boolean inputs** in composite actions are the strings `"true"`/`"false"`;
  compare with `== 'true'`.
- **Keep defaults in one place.** Fallback tool versions live in
  `opentofu/scripts/setup-tools.sh`. Keep them in sync with the repo-root
  `mise.toml` and the table in `opentofu/README.md`. The mise version lives
  in `opentofu/setup/action.yaml`.
- **Error messages say what to do next**, not just what failed.
- **Docs:** 80 columns; tables wrapped in
  `<!-- markdownlint-disable MD013 -->`. When an input changes, update the
  `action.yaml` or workflow description, the README tables, and any affected
  example together.

## Shell scripts

- Start with `#!/usr/bin/env bash` and `set -euo pipefail`, then source
  `common.sh`. Document the environment variables and outputs in a header
  comment. Run `chmod +x` on new scripts.
- Log with `log_info` / `log_warn` / `log_error`. Warnings and errors become
  annotations in Actions.
- Capture exit codes with `set +e` ... `set -e`.

## Validation

- Run `pre-commit run --all-files` before finishing. It runs shellcheck,
  actionlint (workflows and `examples/`), zizmor, markdownlint, and the
  OpenTofu hooks on the fixture.
- Exercise changed scripts against `tests/fixtures/opentofu/basic` locally,
  for example
  `WORKING_DIR=tests/fixtures/opentofu/basic opentofu/scripts/check-fmt.sh`.
  CI runs the whole workflow against it.
- If a hook fails, fix the cause. Never add a suppression (shellcheck,
  actionlint, zizmor, tflint, trivy) without the user's approval, and
  explain why in a comment when you do.

## Versioning

Tag releases `vX.Y.Z` and move the major tag (`v1`). Breaking changes need
a new major version. Breaking changes include:

- removing or renaming an input or output;
- changing a default in a way that changes behavior;
- requiring a new permission from callers.
