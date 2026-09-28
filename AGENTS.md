# AGENTS.md

Instructions for agents (and people) working in this repository.

## What this repo is

A library of reusable GitHub Actions workflows and composite actions,
consumed from other repositories as
`JoshSLawrence/actions/.github/workflows/<name>.yaml@<ref>` and
`JoshSLawrence/actions/<area>/<action>@<ref>`. See README.md for the
catalog, layout and principles.

## Principles

1. We use mise for every tool.
2. We use OpenTofu (`tofu`), not Terraform.
3. We don't inline scripts in YAML: a `run:` step is one command, normally
   one script. `.github/scripts/check-no-inline-scripts.sh` enforces it.
4. Easy-to-follow code beats early abstraction.
5. Abstractions keep things DRY only while they don't hurt readability or
   break the rules above.

## Architecture

- **Scripts hold the logic** (`<area>/scripts/`). Composite actions
  (`<area>/<action>/action.yaml`) and workflows only wire inputs to scripts
  through `env:`. Shared helpers live in `opentofu/scripts/common.sh`, in
  named sections; check there before writing a helper.
- **OpenTofu workflows nest:** `opentofu.yaml` (discover root modules) →
  `opentofu-config.yaml` (validate once, resolve deployments) →
  `opentofu-deploy.yaml` (plan → apply one deployment).
  `opentofu-drift.yaml` stands alone.
  - An input means the same thing everywhere it appears.
  - Callers pass shared inputs through unchanged.
  - `.github/scripts/check-workflow-inputs.sh` enforces both. When you add
    or change an input, change it in every workflow that has it; the
    script's `check_pair` lines list what each workflow adds or computes.
- **Self-references use `uses: $/...`**, never `./` or `owner/repo@ref`. It
  resolves to this repository at the commit being run, so everything
  matches the caller's pinned ref and CI tests a PR's own changes.
  actionlint 1.7.12 doesn't know `$/` yet: `.github/actionlint.yaml`
  ignores exactly those messages (user-approved). Remove it once actionlint
  supports `$/`.
- **Composite actions find their scripts** via
  `"${GITHUB_ACTION_PATH}/../scripts/<script>.sh"`.
- **Tools are per root module.** Every script that runs a tool goes through
  `cd_working_dir`, which scopes mise to the module's own `mise.toml`. That
  means nothing from parent directories or global config. Run tools with
  `mise exec -- <tool>`.
- **Deployments** (a root module × one `.tfvars`, plus a same-named
  `.tfbackend`) are resolved by `list_deployments` in `common.sh`, used by
  both `deployments.sh` and `discover.sh`.
- **Paths:** composite action inputs are relative to the workspace, which is
  the repository root; var/backend files are relative to the module.
- **Every script runs locally too.** Outputs and summaries degrade to
  logging outside Actions (see `set_output` and `append_step_summary`).

## Conventions

- **Pin third-party actions to a full commit SHA** with a `# vX.Y.Z` comment.
  Dependabot updates them in `.github/` and in every `opentofu/*` action.
  Bump `mise-version` (default in `opentofu/setup/action.yaml`) by hand.
- **Least privilege.** Workflows set `permissions: {}` and grant per job. A
  permission a reusable workflow's job requests becomes every caller's
  minimum, so adding one is a breaking change: update the README and
  examples.
- **No untrusted input in `run:`.** Pass `${{ }}` values through `env:`
  (zizmor enforces it).
- **YAML descriptions containing a colon followed by a space** must be quoted
  or folded (`>-`), or the file doesn't parse.
- **Boolean inputs** of composite actions are the strings `"true"`/`"false"`;
  compare with `== 'true'`.
- **Error messages say what to do next**, not just what failed.
- **Docs:** 80 columns, with tables wrapped in
  `<!-- markdownlint-disable MD013 -->`. Update the workflow descriptions,
  `opentofu/README.md` tables and affected examples together.

## Shell scripts

- Start with `#!/usr/bin/env bash` and `set -euo pipefail`, then source
  `common.sh`. Document the environment variables and outputs in a header
  comment. Run `chmod +x` on new scripts.
- Log with `log_info` / `log_warn` / `log_error`; warnings and errors become
  annotations in Actions.
- Capture exit codes with `set +e` ... `set -e`.
- Target bash 4+ (the runners' bash 5; on macOS, Homebrew's bash).

## Validation

- Run `.github/scripts/lint.sh` (all pre-commit hooks) before finishing:
  - shellcheck, actionlint (workflows and `examples/`), zizmor,
    markdownlint;
  - the workflow input sync check and the no-inline-scripts check;
  - the OpenTofu hooks on the fixtures.
- Exercise changed scripts against `tests/fixtures/opentofu/` locally, e.g.
  `WORKING_DIR=tests/fixtures/opentofu/basic opentofu/scripts/check-fmt.sh`,
  or `SEARCH_ROOT=tests/fixtures/opentofu CHANGED_ONLY=false
  DEPLOYMENTS='deployments/*.tfvars' opentofu/scripts/discover.sh`.
- `act` can run the composite actions in a container if a throwaway
  workflow references them with `./` (act doesn't support `$/`). CI runs
  the real workflows end to end.
- If a hook fails, fix the cause. Never add a suppression (shellcheck,
  actionlint, zizmor, tflint, trivy) without the user's approval, and
  explain why in a comment when you do.

## Versioning

Tag releases `vX.Y.Z` and move the major tag (`v1`). Breaking changes need
a new major version. Breaking changes include:

- removing or renaming an input or output;
- changing a default in a way that changes behavior;
- requiring a new permission from callers.
