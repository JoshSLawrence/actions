# CLAUDE.md

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

- **Areas depend on the shared library, never on each other.** `shared/`
  is generic: helpers, and the setup, PR comment, result, apply-preflight
  and environment-check steps every area runs. It holds nothing
  area-specific. OpenTofu (`opentofu/`, `opentofu*.yaml`) and the ARM
  areas (`datafactory/`, `synapse/`, and `arm/`, which those two share)
  never reference each other. A change to `shared/` affects every area, by
  design; a change to an area must not.
- **Scripts hold the logic** (`<area>/scripts/`). Composite actions
  (`<area>/<action>/action.yaml`) and workflows only wire inputs to scripts
  through `env:`. Check for a helper before writing one, in named sections:
  - `shared/scripts/common.sh`: what every area uses (logging, outputs,
    lists, mise, globs, markdown, GitHub comments);
  - `opentofu/scripts/common.sh`: OpenTofu and its deployments (it sources
    the shared one);
  - `arm/scripts/arm.sh`: what Data Factory and Synapse share (deployments
    of ARM parameters files, parameter layering, the export bundle,
    plans).
- **OpenTofu is one reusable workflow, `opentofu.yaml`, called once per
  deployment:** one root module, its var files, one apply environment.
  Callers write one job per deployment in their own workflow files; there's
  no discovery and no file format of our own. The design, with the
  decisions behind it, is `docs/design/opentofu-per-root-module.md`: don't
  change the interface without updating it (and without the user's
  agreement). Jobs: prepare (`validate-inputs.sh`: every input problem at
  once; tool pins through `shared/setup` with `install: false`;
  `require-environments.sh`; `changes.sh`) → checks → integration-tests →
  plan → apply → result. The composite actions are internals.
- **OpenTofu change detection is inside the run** (`changes.sh`): it watches
  the module directory, the var files, the calling workflow file
  (`github.workflow_ref`) and `extra-paths`; the same paths make a plan
  stale. State keys come from a backend variable set in the var files;
  there's no `backend-config` or `.tfbackend` support.
- **OpenTofu credentials are named provider inputs**, Azure only for now:
  `azure-client-id` (the apply identity, and the integration tests' unless
  overridden), `plan-azure-client-id` and `integration-test-azure-client-id`
  (overrides for their job, each switching as a pair with its secret),
  `azure-tenant-id`, `azure-subscription-id`, `azure-use-azuread` (default
  true), and the `azure-client-secret` / `plan-azure-client-secret` /
  `integration-test-azure-client-secret` secrets; a secret means secret
  auth, none means OIDC. `azure-env.sh` maps them to `ARM_*`; its rules
  live in `azure_input_problems` (`opentofu/scripts/common.sh`), shared with
  input validation. Add other providers as their own optional inputs.
- **Data Factory and Synapse workflows** follow the same nested shape:
  `datafactory.yaml` (build the template once, resolve deployments) →
  `datafactory-deploy.yaml` (plan → apply one deployment); likewise
  `synapse.yaml` → `synapse-deploy.yaml`. Every area's workflows use
  `shared/setup`, `shared/pr-comment` and `shared/result`.
- **Workflow inputs stay in sync:**
  - An input means the same thing in every workflow of a family that has
    it (the Data Factory and Synapse workflows). OpenTofu has a single
    workflow.
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
- **Runners:** `runs-on` is every job's runner; the jobs that do the work
  (OpenTofu checks, integration tests, plan, apply; Data Factory and
  Synapse build, plan, apply) also take their own (`plan-runs-on`, ...),
  which falls back to it. Each is a label, or JSON when it starts with `{`
  or `[` (an array of labels or a runner group), parsed by the job's
  `runs-on` expression: copy that expression to a new job. OpenTofu checks
  the overrides up front (`runs_on_problem` in `shared/scripts/common.sh`).
- **Providers are cached** by `opentofu/provider-cache` (restore and save
  through `actions/cache`, keyed on the lock file), called by every job that
  runs `tofu init`; `provider-cache: false` disables it. It never sets
  `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE`: the lock file keeps
  verifying cached providers.
- **Composite actions find their scripts** via
  `"${GITHUB_ACTION_PATH}/../scripts/<script>.sh"`, or
  `"${GITHUB_ACTION_PATH}/../../shared/scripts/<script>.sh"` (and
  `../../arm/scripts/` for Data Factory and Synapse).
- **Tools are per root module** (or factory/workspace folder). Every script
  that runs a tool goes through `cd_working_dir`, which scopes mise to the
  module's own `mise.toml`. That means nothing from parent directories or
  global config. Run tools with `mise exec -- <tool>` (`arm_az` for az).
  mise installs `azure-cli` with `uv`, so a folder pinning one pins both.
- **Data Factory and Synapse deployments** are the template × one ARM
  parameters file, resolved by `arm_list_deployments` in `arm.sh`. Their
  plans hold `deploy/` (template, rendered parameters, `target.json`) and
  `summary.md`. The digest covers `deploy/`, and the apply takes its target
  from `target.json`, never from inputs. `parameter-secrets` are merged only
  into temporary files at plan (what-if) and apply time, never into an
  artifact.
- **Paths:** composite action inputs are relative to the workspace, which is
  the repository root; var files are relative to the module.
- **Every script runs locally too.** Outputs and summaries degrade to
  logging outside Actions (see `set_output` and `append_step_summary`).

## Conventions

- **Pin third-party actions to a full commit SHA** with a `# vX.Y.Z` comment.
  The Synapse deployer in `synapse/apply` is a fork adding GitHub OIDC to an
  upstream release (`v<upstream>-oidc.N`): port and bump it by hand when
  upstream releases.
  Dependabot updates them in `.github/` and in every `opentofu/*`,
  `shared/*`, `datafactory/*` and `synapse/*` action. Bump by hand:
  `mise-version` (default in `shared/setup/action.yaml`) and the Az
  PowerShell modules pinned in
  `datafactory/scripts/pre-post-deployment.ps1`.
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
  the area README tables (`opentofu/`, `datafactory/`, `synapse/`) and
  affected examples together.

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
  - the OpenTofu script tests (`tests/opentofu/scripts-test.sh`: change
    detection, input validation, the Azure mapping, names);
  - the OpenTofu hooks on the fixtures.
- The apply scripts need a real factory or workspace: CI stops the Data
  Factory and Synapse e2e runs at the plan.
- Exercise changed scripts against `tests/fixtures/` locally, e.g.
  `WORKING_DIR=tests/fixtures/opentofu/basic opentofu/scripts/check-fmt.sh`,
  or `WORKING_DIR=tests/fixtures/opentofu/basic
  VAR_FILES=deployments/dev.tfvars APPLY_ENVIRONMENT=dev
  opentofu/scripts/validate-inputs.sh`, or
  `WORKING_DIR=tests/fixtures/datafactory/basic
  datafactory/scripts/build.sh` then `plan.sh` with `TEMPLATE_DIR`,
  `PARAMETER_FILES` and `RESOURCE_GROUP` (the same for `synapse/`). Plans
  without `WHAT_IF` and builds need no Azure access.
- `act` can run the composite actions in a container if a throwaway
  workflow references them with `./` (act doesn't support `$/`). CI runs
  the real workflows end to end.
- If a hook fails, fix the cause. Never add a suppression (shellcheck,
  actionlint, zizmor, tflint, trivy) without the user's approval, and
  explain why in a comment when you do.

## Versioning

Tag releases `vX.Y.Z` and move the major tag (`v1`). Breaking changes need
a new major version; before `v1.0.0`, a new minor version. Breaking changes
include:

- removing or renaming an input or output;
- changing a default in a way that changes behavior;
- requiring a new permission from callers.
