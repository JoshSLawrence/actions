# Design: one OpenTofu workflow call per root module

- **Status:** approved (revision 3), 2026-10-06; drift dropped from
  `v0.2.0` in implementation review and back in `v0.4.0` (see
  [Drift detection](#drift-detection))
- **Date:** 2026-10-06
- **Replaces:** the discovery-based design on PR #8 (unmerged), and the
  `v0.1.0` OpenTofu interface on `main`
- **Ships as:** `v0.2.0` (breaking, pre-1.0)

## Summary

`opentofu.yaml` becomes one reusable workflow that checks, tests, plans and
applies **one root module with one set of var files in one environment**.
Callers write ordinary GitHub Actions workflow files: one job per
deployment, each calling `opentofu.yaml` with the module's path, its var
files, its environments, its toggles, and its provider credentials as named
inputs and secrets (Azure first). There's no discovery, no deployment files
and no schema of our own: everything a run does is visible in the caller's
workflow YAML.

```text
.github/workflows/
├── tofu-identity.yaml   jobs dev, prod-eastus, prod-westus
│                        -> each calls opentofu.yaml once
└── tofu-network.yaml    job network -> calls opentofu.yaml once
```

## Where we are

### On `main` (`v0.1.0`)

- `opentofu.yaml` discovers root modules and calls `opentofu-config.yaml`
  per module, which calls `opentofu-deploy.yaml` per deployment: three
  nested reusable workflows.
- `opentofu-config.yaml` can also be called directly for one module. It
  takes a `deployments` glob of `.tfvars`, `backend-config` and
  same-named `.tfbackend` files, Azure-specific inputs (`azure-client-id`,
  `apply-azure-client-id`, ...), and `env-vars` / `apply-env-vars` secrets.
- Five OpenTofu examples cover the different ways of calling it.

### On PR #8 (not merged)

PR #8 pushed discovery further: nested root modules, a
`deployments/<name>.yaml` file per deployment declaring its environment,
literal values, and GitHub variables and secrets by name, resolved in each
job's environment. It works for variables, and CI exercised it end to end.
It also improved things this design keeps (see
[What carries over](#what-carries-over)).

### Why change course

- **Two schemas.** A deployment was half workflow YAML and half our own
  YAML (`environment`, `env`, `vars`, `secrets`), which looks like Actions
  syntax but follows its own rules. Reviewers have to learn both.
- **Implicit behaviour.** What runs depends on directory layout rules
  (marker files, nesting, ownership of changed files, naming coupling), not
  on anything written in a workflow.
- **Secrets don't fit.** Inside a reusable workflow, a job can't read a
  secret by a name chosen at run time (see the constraints below). PR #8
  would have needed one write-only secret blob per environment, or
  `secrets: inherit`.
- **Three levels of nesting** made runs and check names hard to follow.

### GitHub constraints we verified

These shaped both designs; each was checked with actionlint, a CI run on
PR #8, or GitHub's documentation.

<!-- markdownlint-disable MD013 -->

| Constraint                                                                      | Consequence                                         |
| ------------------------------------------------------------------------------- | --------------------------------------------------- |
| A reusable workflow's `uses:` must be a literal string                          | A workflow can't call one it discovered at run time |
| Callable workflows must live in `.github/workflows/`                            | Workflow files next to a module can't be run        |
| A job calling a reusable workflow can't set `environment:` or `env:`            | The caller can't resolve environment-scoped values  |
| The caller's `${{ vars.X }}` / `${{ secrets.X }}` resolve at repo or org level  | Per-environment values need distinct names          |
| In a reusable workflow, a job sees its environment's variables, not its secrets | Environment secrets can't be read by name           |
| A job's implied `success()` fails if any ancestor job was skipped               | Jobs after an optional one need `!cancelled()`      |
| A workflow skipped by `on.*.paths` leaves its required checks pending           | Path filtering has to happen inside the run         |
| `GITHUB_TOKEN` can only read the repository the run belongs to                  | Private modules elsewhere need a token of their own |

<!-- markdownlint-enable MD013 -->

## Goals

- One reusable workflow, called once per root module and deployment.
- The caller's workflow file says everything: which module, which var
  files, which environments, which checks, which credentials.
- Credentials are named, optional inputs and secrets, passed with ordinary
  `${{ vars.* }}` and `${{ secrets.* }}` expressions; the workflow sets the
  provider's environment variables from them.
- Every call checks, tests, plans and applies with its own var files, so a
  deployment whose variables trip a check or a policy is caught.
- Bad inputs fail the run at the start, all at once, before any work.
- Keep what the current workflows do well: plan summaries, PR comments,
  policy and cost, approval-gated apply from the PR, stale-plan refusal,
  plan digest check, one stable check per call.
- Providers are supported one at a time, each with its own inputs: Azure
  (azurerm) now, with OIDC or a client secret.

## Non-goals

- Discovering root modules, or anything inferred from directory layout.
- Change detection finer than "did any of these paths change".
- Providers other than Azure (AWS, Google Cloud, the GitHub provider, ...),
  and generic environment variables or secrets. They're added as named
  inputs when they're needed (see [Adding a provider](#adding-a-provider)).
- Drift detection inside `opentofu.yaml`: it was removed in this release
  and came back in `v0.4.0` as its own workflow (see
  [Drift detection](#drift-detection)).
- Orchestration across calls beyond what Actions offers (`needs:`, `if:`).

## Design

### The caller

One workflow file per root module (or per group of deployments the team
wants together), one job per deployment. A module deployed to dev and two
production regions:

```yaml
# .github/workflows/tofu-identity.yaml
name: OpenTofu identity

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

jobs:
  dev:
    name: identity-dev
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v0.2.0
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: iac/identity
      var-files: deployments/dev.tfvars
      apply-environment: dev
      # OIDC: no client secret
      azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
      azure-subscription-id: ${{ vars.DEV_SUBSCRIPTION_ID }}
      azure-client-id: ${{ vars.DEV_CLIENT_ID }}
      plan-azure-client-id: ${{ vars.DEV_READ_CLIENT_ID }}

  prod-eastus:
    name: identity-prod-eastus
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v0.2.0
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: iac/identity
      var-files: |
        deployments/common.tfvars
        deployments/prod-eastus.tfvars
      plan-environment: prod-plan
      apply-environment: prod
      apply-from-pr: false
      # A client secret instead of OIDC
      azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
      azure-subscription-id: ${{ vars.PROD_SUBSCRIPTION_ID }}
      azure-client-id: ${{ vars.PROD_CLIENT_ID }}
      plan-azure-client-id: ${{ vars.PROD_READ_CLIENT_ID }}
    secrets:
      azure-client-secret: ${{ secrets.PROD_CLIENT_SECRET }}
      plan-azure-client-secret: ${{ secrets.PROD_READ_CLIENT_SECRET }}

  # prod-westus: the same as prod-eastus, with its own var file

  # One check for the whole file (see Branch protection)
  result:
    name: identity
    needs: [dev, prod-eastus]
    if: always()
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: JoshSLawrence/actions/shared/result@v0.2.0
        with:
          needs: ${{ toJSON(needs) }}
```

- **Unrelated root modules** get their own workflow files, so they run,
  pass and fail independently.
- **Ordering** is plain Actions: `needs: dev` on a production job makes it
  wait for dev to plan and apply first.
- **Conditions** are plain Actions too: `if:` on a job, or on the
  workflow's triggers.
- **The cost of explicitness** is repetition: three deployments of one
  module are three similar jobs. YAML anchors aren't supported by Actions,
  so this is accepted, not worked around.

### Inside `opentofu.yaml`

One reusable workflow, no nesting:

```text
prepare ──> checks ──> integration-tests ──> plan ──> apply ──> result
           (no creds)      (opt-in)        (per PR)  (after approval)
```

- **prepare:** validates every input up front (see
  [Input validation](#input-validation)), checks every environment the
  call names exists (GitHub would otherwise create a missing one,
  unprotected), and decides whether this run has anything to plan (see
  [Change detection](#change-detection)).
- **checks:** fmt, validate, TFLint, Trivy, terraform-docs and `tofu test`,
  each switchable, or all off with `checks: false`. They run with the
  call's var files where the tool takes them (see [Checks](#checks)). No
  credentials, so fork PRs can run it.
- **integration-tests:** `tofu test` with the call's var files and the
  apply identity (or `integration-test-azure-client-id`), in
  `integration-test-environment`. Off by default.
- **plan:** plans to a saved file in `plan-environment`, renders the
  summary (with optional policy and cost), uploads the plan, comments on
  the PR. Skipped for PRs from forks and Dependabot.
- **apply:** in `apply-environment`, after its reviewers approve; refuses a
  stale plan, checks the plan's digest, applies exactly that plan, updates
  the PR comment (see [When it applies](#when-it-applies)).
- **result:** one check per call, for branch protection.

Every job that runs `tofu init` (checks, integration-tests, plan, apply)
restores the provider cache first (see [Provider cache](#provider-cache)).

### Drift detection

`opentofu-drift.yaml` (added in `v0.4.0`, additive) plans one deployment on a
schedule and reports whether the live infrastructure still matches the
configuration. It is a second workflow, called once per deployment like
`opentofu.yaml`, and takes the same inputs for what it shares with it
(`working-directory`, `var-files`, `name`, the Azure inputs, `runs-on`,
`provider-cache`, `mise-version`; `.github/scripts/check-workflow-inputs.sh`
keeps them identical), so a deployment's drift call repeats its main call's
values.

```text
prepare ──> drift
          (plan, report)
```

- **prepare:** the same `opentofu/prepare` action, in drift mode
  (`DRIFT=true` in `validate-inputs.sh`): every input problem at once, no
  apply environment to require, no change detection (a drift check always
  plans), and the drift job's `environment`, if any, checked to exist before
  a job names it. A separate job for the same reason as in `opentofu.yaml`:
  naming a missing environment in the job itself would create it,
  unprotected, before any step could notice.
- **drift:** `shared/setup`, the provider cache, `opentofu/azure` as the plan
  role, then `opentofu/plan` (no policy, cost estimate or checks section;
  `-lock=false` like every plan), then `opentofu/drift-report`. The plan is
  never uploaded: it embeds a copy of the state, and nothing needs it.
- **Identity:** the read-only `plan-azure-client-id` is enough on its own;
  `azure-client-id` is only the fallback for a caller with one identity, and
  validation warns when the check signs in with it. `environment` binds the
  OIDC subject like `plan-environment` does; unlike an apply environment it
  can't have required reviewers, since nobody is there to approve a
  scheduled run.
- **The report** reads the plan action's `exit-code` output (0 no drift, 2
  drift, anything else, or none because the plan never ran, an error) and
  its `summary-file` (the plan itself is deleted by the plan action's last
  step). It runs after a failed plan too, so a broken check is reported as
  one:
  - *Error:* the job fails, and the issues are left as they were.
  - *Drift:* one issue per deployment, found by a hidden marker (derived
    from the plan action's key) among the open issues with the first of
    `issue-labels`, authored by the bot. Created with the summary as its
    body (cut to GitHub's limit by `fit_github_body`), or its body updated
    in place, which notifies nobody. An issue carrying the `drift-resolved`
    label gets it removed and one comment that the drift is back.
  - *No drift:* an open drift issue gets one comment and the
    `drift-resolved` label, once. It is not closed: a person decides when
    it's dealt with, and an auto-closing issue would reopen as a new one
    (and a new notification) every time the drift flickers.
  - `fail-on-drift` fails the job when there is drift, after reporting it.
  - `issues: false` only reports in the job summary and the outputs `drift`
    (`true`, `false` or `error`) and `issue` (the number, or empty).
- **Concurrency:** one drift job per deployment at a time (not cancelled), so
  two runs can't both open the issue.
- **Permissions:** `actions: read` (the environment check), `contents: read`,
  `id-token: write` and `issues: write`. A new workflow, so requiring
  `issues: write` of its callers is not a breaking change.
- **Not in the first version:** one issue shared by several deployments, a
  summary dashboard, notifications other than GitHub's own (use
  `fail-on-drift` and Actions' failure notifications, or the outputs), and
  closing issues automatically.

### Provider cache

Every job that runs `tofu init` (checks, integration tests, plan, apply)
restores and saves OpenTofu's provider plugin cache, so providers are
downloaded once and not once per job per run:

- **One place.** The `opentofu/provider-cache` composite action sets
  `TF_PLUGIN_CACHE_DIR` (a directory under `runner.temp`, made absolute
  because tools run from inside the module) and runs `actions/cache` on it,
  keyed on the runner's OS and architecture and the hash of the module's
  `.terraform.lock.hcl`, with the OS-and-architecture prefix as the
  restore key. Each of those jobs calls it once after `shared/setup`.
  `provider-cache: false` makes it do nothing.
- **Compatible with `-lockfile=readonly` and several inits per job.**
  OpenTofu installs into the cache only providers it has verified, and
  uses a cached one only if its checksum is in the lock file; otherwise it
  downloads and verifies the provider again. So the lock file keeps the
  last word, and the checks job's `init -backend=false`, the tests' init
  and the plan's init can share one directory (the cache is locked per
  provider while being written).
- **`TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE` is not set.** It would
  make a lock file with no `h1:` checksum for the runner's platform use the
  cache anyway, by not verifying the cached package. That trades the
  supply-chain check the lock file gives for speed; the documented fix is to
  commit the platform's checksums (`tofu providers lock
  -platform=linux_amd64`).
- **Cache scope.** Pull requests can read the default branch's entries but
  write their own, visible to that PR only.

### Inputs

All paths are relative to the repository root, except `var-files` and
`test-filter`, which are relative to the root module, as in OpenTofu.
Without `var-files`, the module uses its defaults (and its
`terraform.tfvars`). Credentials that are secret are passed under
`secrets:`, not `with:` (GitHub keeps the two apart); they're in the
[Secrets](#secrets) table below.

<!-- markdownlint-disable MD013 -->

| Input                              | Default              | Description                                                            |
| ---------------------------------- | -------------------- | ---------------------------------------------------------------------- |
| **What to deploy**                 |                      |                                                                        |
| `working-directory`                | **required**         | The root module; its own `mise.toml` pins its tools                    |
| `var-files`                        | none                 | `.tfvars` files, in order, for `init`, `plan`, checks and tests        |
| `name`                             | last var file's name | Label for this call (e.g. `prod-eastus`) in titles and names           |
| **Change detection**               |                      |                                                                        |
| `changed-only`                     | `true`               | On PR and push runs, skip plan and apply unless a watched path changed |
| `extra-paths`                      | none                 | Directories or globs watched besides the module, var files, workflow   |
| **Environments**                   |                      |                                                                        |
| `apply-environment`                | **required**         | The apply job's environment: the approval gate                         |
| `plan-environment`                 | none                 | The plan job's environment; none = no environment                      |
| `integration-test-environment`     | none                 | The integration test job's environment; none = no environment          |
| **Azure** (secrets: see below)     |                      |                                                                        |
| `azure-client-id`                  | none                 | Apply identity; also plans and integration tests unless overridden     |
| `azure-tenant-id`                  | none                 | Tenant ID; required with any client ID                                 |
| `azure-subscription-id`            | none                 | Subscription ID                                                        |
| `plan-azure-client-id`             | `azure-client-id`    | Identity for the plan job, e.g. a read-only one                        |
| `integration-test-azure-client-id` | `azure-client-id`    | Identity for the integration test job, e.g. a test-subscription one    |
| `azure-use-azuread`                | `true`               | Microsoft Entra ID (RBAC) auth for storage: state and data plane       |
| **Checks**                         |                      |                                                                        |
| `checks`                           | `true`               | Run the checks job at all; `false` skips every check below             |
| `fmt`                              | `true`               | `tofu fmt -check -recursive`                                           |
| `validate`                         | `true`               | `tofu init -backend=false` and `tofu validate`                         |
| `tflint`                           | `true`               | TFLint, recursive, with the call's var files                           |
| `trivy`                            | `true`               | Trivy misconfiguration scan, with the call's var files                 |
| `trivy-severity`                   | `trivy.yaml`'s       | Severities that fail the scan                                          |
| `docs`                             | `true`               | Fail if the terraform-docs README is stale                             |
| `tests`                            | `true`               | `tofu test` without credentials, with the call's var files             |
| `test-filter`                      | all                  | Test files to run (`-filter`), globs allowed                           |
| `test-verbose`                     | `false`              | `tofu test -verbose`                                                   |
| `integration-tests`                | `false`              | `tofu test` again, with credentials, before the plan                   |
| `integration-test-filter`          | all                  | Test files for the integration run                                     |
| `integration-test-timeout-minutes` | `90`                 | Its timeout                                                            |
| **Plan**                           |                      |                                                                        |
| `pr-comment`                       | `true`               | Comment the plan and apply result on the PR                            |
| `plan-retention-days`              | `7`                  | Plan artifact retention                                                |
| `policy`                           | `false`              | conftest policy check; a `deny` blocks the apply                       |
| `policy-path`                      | `policy`             | Local policy directories (list)                                        |
| `policy-source`                    | none                 | go-getter URL of more policies, evaluated with `policy-path`'s         |
| `policy-namespaces`                | all                  | Rego namespaces to evaluate (list)                                     |
| `policy-fail-on-warn`              | `false`              | Also block on any `warn`                                               |
| `cost-estimate`                    | `false`              | Infracost estimate; needs the `infracost-api-key` secret               |
| **Apply**                          |                      |                                                                        |
| `apply`                            | `true`               | Include the apply job (`false` = plan only)                            |
| `apply-from-pr`                    | `true`               | Apply the reviewed plan from the PR, before merge                      |
| **Runners**                        |                      |                                                                        |
| `runs-on`                          | `ubuntu-latest`      | Runner of every job without its own: a label, or JSON                  |
| `checks-runs-on`                   | `runs-on`            | Runner of the checks job                                               |
| `integration-test-runs-on`         | `runs-on`            | Runner of the integration test job                                     |
| `plan-runs-on`                     | `runs-on`            | Runner of the plan job                                                 |
| `apply-runs-on`                    | `runs-on`            | Runner of the apply job                                                |
| `timeout-minutes`                  | `30`                 | Timeout for each job                                                   |
| `mise-version`                     | the setup pin        | The mise version; the module's `mise.toml` pins its tools              |
| **Providers**                      |                      |                                                                        |
| `provider-cache`                   | `true`               | Cache providers across runs and jobs, keyed on the lock file           |

<!-- markdownlint-enable MD013 -->

Lists (`var-files`, `extra-paths`, `test-filter`, `policy-path`,
`policy-namespaces`, ...) take one item per line, or items separated by
spaces:

```yaml
      policy-namespaces: |
        terraform.azure
        terraform.tags
```

### Secrets

<!-- markdownlint-disable MD013 -->

| Secret                                 | Description                                                        |
| -------------------------------------- | ------------------------------------------------------------------ |
| `azure-client-secret`                  | Secret of `azure-client-id`; without it, OIDC                      |
| `plan-azure-client-secret`             | Secret of `plan-azure-client-id`; without it, OIDC                 |
| `integration-test-azure-client-secret` | Secret of `integration-test-azure-client-id`; without it, OIDC     |
| `modules-token`                        | Reads private GitHub repositories used as module or policy sources |
| `infracost-api-key`                    | For `cost-estimate`                                                |

<!-- markdownlint-enable MD013 -->

### Outputs

<!-- markdownlint-disable MD013 -->

| Output        | Description                                                                   |
| ------------- | ----------------------------------------------------------------------------- |
| `changed`     | `true` if this run planned (a watched path changed, or `changed-only` is off) |
| `has-changes` | `true` if the plan has changes                                                |
| `applied`     | `true` if the apply job applied the plan                                      |

<!-- markdownlint-enable MD013 -->

Removed relative to `v0.1.0`: `deployments`, `stack-name` (now `name`),
`backend-config` and `.tfbackend` files (state keys come from a backend
variable set in the var files), `max-parallel`, `azure-login`,
`apply-azure-client-id` (the apply identity is now `azure-client-id`), and
the `env-vars` and `apply-env-vars` secrets. New: `plan-azure-client-id`,
`azure-use-azuread`, `checks`, `extra-paths`, the `azure-client-secret` and
`plan-azure-client-secret` secrets. Changed: `docs` defaults to `true`.

### Input validation

The prepare job checks every input before anything else runs, reports
every problem it finds at once, and fails the run if there are any, with
what to do about each:

- `working-directory` exists, has `*.tf` files and its own `mise.toml`.
- Each var file exists, relative to the module.
- `apply-environment`, `plan-environment` and
  `integration-test-environment`, when given, exist.
- Every tool the enabled options need is pinned in the module's
  `mise.toml`: `opentofu`; `tflint`, `trivy`, `terraform-docs` for their
  checks; `conftest` for `policy`; `infracost` for `cost-estimate`.
- Azure: a client ID needs `azure-tenant-id`; `azure-client-secret` needs
  `azure-client-id`; `plan-azure-client-id` and
  `integration-test-azure-client-id` need `azure-client-id`;
  `plan-azure-client-secret` needs `plan-azure-client-id`;
  `integration-test-azure-client-secret` needs
  `integration-test-azure-client-id`.
- `cost-estimate` needs the `infracost-api-key` secret.
- `policy` needs `policy-source` or `policy-path`, and every `policy-path`
  directory exists (`policy-path: ""` to use only `policy-source`).
- `extra-paths` stay inside the repository.
- `test-filter` and `integration-test-filter` match at least one file.
- `name` is usable in names (letters, digits, `.`, `_`, `-`).
- `checks-runs-on`, `integration-test-runs-on`, `plan-runs-on` and
  `apply-runs-on`, when given, are a label or a JSON array of labels or
  runner group.

On a pull request from a fork, or one Dependabot runs, secrets (and the
OIDC token) are never passed and nothing is planned, so secret-dependent
rules are skipped there with a note.

### Change detection

The workflow always runs (callers shouldn't use `on.pull_request.paths`: a
workflow skipped that way leaves its required checks pending forever). The
prepare job decides whether the run plans:

- **What's watched:** always the module directory (every file in it: `.tf`
  files, child modules, tests, the lock file, `mise.toml`, ...), the var
  files (even outside the module), and the calling workflow file (from
  `github.workflow_ref`, so editing the call runs it). `extra-paths` adds
  to these; it can't remove them, so a call can never stop watching its
  own module. The calling workflow is the run's top-level one: a call made
  from a caller's own reusable workflow needs that file in `extra-paths`.
- **What `extra-paths` is for:** anything else the module depends on, such
  as a shared module directory outside it or a policy directory. Each entry
  is a directory (`iac/modules`, with everything under it) or a glob
  (`iac/modules/**/*.tf`), read the same way by change detection and the
  apply's stale-plan check.
- **When:** on `pull_request` and `push` with `changed-only`, the prepare
  job diffs the run's base against its head. If no watched path changed,
  plan and apply are skipped and `result` passes; checks still run. Other
  events (`workflow_dispatch`, `schedule`), `changed-only: false`, or a
  diff that can't be computed always plan.
- **Stale plans:** the same watched paths decide whether a plan is stale
  at apply time (something merged into them since).

### When it applies

<!-- markdownlint-disable MD013 -->

| `apply` | `apply-from-pr` | Pull request run                                   | Push or dispatch, default branch               | Other branches |
| ------- | --------------- | -------------------------------------------------- | ---------------------------------------------- | -------------- |
| `true`  | `true`          | Plan, then apply after approval, before merge      | Plan; apply after approval if anything changed | Plan only      |
| `true`  | `false`         | Plan only; the comment says it applies after merge | Plan, then apply after approval                | Plan only      |
| `false` | (ignored)       | Plan only                                          | Plan only                                      | Plan only      |

<!-- markdownlint-enable MD013 -->

- With `apply-from-pr: true`, the default branch only ever holds
  configuration that applied: if the `result` check is required, a PR with
  changes can't merge until it's applied. The push after merge plans again
  and normally finds nothing to do. PRs from forks and Dependabot, which
  aren't planned, are the exception: the push after merge applies them.
- With `apply-from-pr: false`, merging is when it applies: the push to the
  default branch plans again and waits for approval. A rejected or failed
  apply there isn't retried by later pushes that don't touch a watched
  path; a `workflow_dispatch` run on the default branch plans and applies
  it.
- Scheduled runs on the default branch count as pushes.
- Applies only ever happen on a PR (with `apply-from-pr`) or on the default
  branch; use environment deployment branch policies for more.

### Checks

Each call runs its own checks with its own var files, because a
deployment's variables can trip a check the module's defaults don't:

- TFLint gets `--var-file` for each var file, Trivy `--tf-vars`, and
  `tofu test` `-var-file` (overriding what test files don't set).
- fmt, validate and terraform-docs don't depend on variables.
- `checks: false` skips the checks job entirely, for a call that only
  needs to plan and apply, without turning each check off.
- `test-filter` selects test files, as OpenTofu's `-filter` does
  (`tests/unit/*.tftest.hcl`), not test or run block names.
- `docs` is on by default, so a module needs `terraform-docs` pinned and a
  README it generates (or turns the check off); input validation says so
  up front.

### Policy

`policy: true` runs conftest against the plan:

- **Where policies come from:** `policy-path` (one or more local
  directories) and `policy-source` (a go-getter URL, e.g.
  `git::https://github.com/org/policies.git//terraform?ref=v1`) are
  combined: conftest evaluates the local and the pulled policies together,
  in one run.
- **Namespaces:** `policy-namespaces` is a list; each one is evaluated.
  Empty means every namespace.
- **deny and warn:** any `deny` (or `violation`) fails the plan and deletes
  it, so it can't be applied. A `warn` doesn't fail by default; every warn
  is listed in the PR comment with its message. `policy-fail-on-warn:
  true` makes any warn fail too.
- **Warning severities:** Rego has no built-in severity for warnings; it's
  a convention in each rule's message or metadata. Failing only on some
  severities is deferred (see [Decisions](#decisions)).

### Azure credentials

The caller passes the identity as named inputs and secrets, composed with
ordinary expressions, and the workflow sets the azurerm provider's (and
backend's) environment variables from them in the integration test, plan
and apply jobs:

<!-- markdownlint-disable MD013 -->

| Variable                  | Apply job               | Plan job                                       | Integration test job                                       |
| ------------------------- | ----------------------- | ---------------------------------------------- | ---------------------------------------------------------- |
| `ARM_CLIENT_ID`           | `azure-client-id`       | `plan-azure-client-id`, else `azure-client-id` | `integration-test-azure-client-id`, else `azure-client-id` |
| `ARM_CLIENT_SECRET`       | `azure-client-secret`   | the plan identity's secret (see below)         | the integration test identity's secret (see below)         |
| `ARM_TENANT_ID`           | `azure-tenant-id`       | `azure-tenant-id`                              | `azure-tenant-id`                                          |
| `ARM_SUBSCRIPTION_ID`     | `azure-subscription-id` | `azure-subscription-id`                        | `azure-subscription-id`                                    |
| `ARM_USE_OIDC`            | `true` without a secret | `true` without a secret                        | `true` without a secret                                    |
| `ARM_USE_AZUREAD`         | `azure-use-azuread`     | `azure-use-azuread`                            | `azure-use-azuread`                                        |
| `ARM_STORAGE_USE_AZUREAD` | `azure-use-azuread`     | `azure-use-azuread`                            | `azure-use-azuread`                                        |

<!-- markdownlint-enable MD013 -->

- **`azure-client-id` is the apply identity, always**, the one that can
  write. `plan-azure-client-id` overrides it for the plan job only, the way
  `plan-environment` adds a plan-only environment, and
  `integration-test-azure-client-id` does the same for the integration test
  job. Each override switches as a pair: with `plan-azure-client-id`, the
  plan job uses `plan-azure-client-secret` (or OIDC without it), never the
  apply identity's secret; likewise the integration tests with
  `integration-test-azure-client-secret`.
- **OIDC or a client secret, per job.** A job with a client secret uses it;
  one without uses OIDC (`ARM_USE_OIDC=true`; the jobs already request
  `id-token: write`). Nothing else chooses the method, so a job can't end
  up with both.
- **Entra ID (RBAC) for storage, by default.** `ARM_USE_AZUREAD` makes the
  azurerm backend reach the state storage account with the identity
  instead of an access key; `ARM_STORAGE_USE_AZUREAD` does the same for
  the provider's storage data plane. Both are set from `azure-use-azuread`
  (default `true`) on every call, Azure or not, so RBAC is what happens
  unless a caller turns it off.
- **Nothing else Azure is set without `azure-client-id`.** A module that
  doesn't use Azure passes none of these.
- **Values come from the repository or organization.** The caller's job
  has no environment, so `${{ vars.X }}` and `${{ secrets.X }}` there
  resolve at repository or organization level. Per-environment values need
  per-environment names (`PROD_CLIENT_ID`). Environment-level variables
  and secrets can't be referenced by the caller (see
  [Decisions](#decisions)).
- **Approval.** A secret the caller passes reaches only the jobs that use
  it. The apply job's identity (`azure-client-id` and its secret) is also
  the integration test job's by default, and that job runs before the plan,
  with whatever code the PR holds: give it its own
  `integration-test-azure-client-id` (scoped to a test subscription or
  resource group) and/or an `integration-test-environment` with required
  reviewers; otherwise `azure-client-id` needs whatever the tests need. With
  OIDC, each
  identity's federated credential is bound to a subject
  (`environment:prod`, `environment:prod-plan`, `pull_request`), so only
  the job running there can use it. That protects the apply identity only
  if it is federated to `environment:<apply-environment>` alone: without
  `plan-azure-client-id` the plan job uses `azure-client-id` with the
  `pull_request` and main subjects (or `environment:<plan-environment>`),
  which anyone who can open a PR presents; `plan-environment` alone only
  helps if that environment has required reviewers. Use a read-only
  `plan-azure-client-id`: Reader on the resources plus whatever reading the
  configuration makes (*Reader and Data Access*, Key Vault reader roles),
  and Storage Blob Data Reader on the state container (plans run with
  `-lock=false`). `validate-inputs.sh` warns when it isn't set, and likewise
  when integration tests would run as the apply identity with neither
  `integration-test-azure-client-id` nor `integration-test-environment` (it
  can't tell whether a named environment has reviewers).
- **Secrets are masked** in the log, like any secret passed to a workflow.

### Private modules and policies

`tofu init` downloads modules from their `source`, and conftest pulls
`policy-source`, both with git. Local modules (`./modules/x`) and public
repositories need nothing. For private GitHub repositories:

- **Why a token:** the run's `GITHUB_TOKEN` can only read the repository
  the run belongs to. That holds on GitHub Enterprise too, for private and
  internal repositories alike: the Actions "access" setting that lets other
  repositories call this library covers `uses:`, not git clones.
- **What `modules-token` does:** before `tofu init` and `conftest pull`,
  the workflow writes a throwaway git config (in the job's temporary
  directory, through `GIT_CONFIG_GLOBAL`) that rewrites
  `https://github.com/`, `ssh://git@github.com/` and `git@github.com:` to
  `https://x-access-token:<token>@github.com/` (or the Enterprise host).
  So `git::https://github.com/org/modules.git//x?ref=v1` and
  `git@github.com:org/modules.git` sources authenticate with it, without
  changing the module code. The config is never written to the
  repository or the runner's own git config.
- **Which token:** one that can read those repositories, e.g. a
  fine-grained personal access token with read-only Contents on them,
  stored as a secret. Without `modules-token`, the run's `GITHUB_TOKEN` is
  used, which covers modules in the calling repository only.
- **GitHub App tokens** would be better than a personal token, but a token
  minted in an earlier caller job can't be passed to a reusable workflow
  (job outputs that look like secrets are dropped). Supporting app
  credentials directly is a follow-up.

### Adding a provider

Each provider gets its own optional inputs and secrets, named after it
(`aws-*`, `google-*`, `github-provider-*`), mapped to the variables its
provider reads, in the same jobs, with the same plan override where the
provider supports it. Adding one is a new minor version, not a breaking
change, since every provider input is optional.

### Branch protection

The workflow's last job, `result`, passes only if every job of the call
succeeded or was skipped for a good reason (nothing changed, plan only).
GitHub names its check after the calling job: `<calling job name> /
Result`, where the calling job's name is its `name:`, else its ID. A ruleset
(or branch protection rule) then requires checks by those names. Two ways
to set it up:

- **Per call:** require each call's check, e.g. `identity-dev / Result`
  and `identity-prod-eastus / Result`. Simple, but adding a deployment
  means changing the ruleset too, and a forgotten one isn't required.
  Calling job names must be unique across the repository's workflows
  (`prod` in two files would be two checks named `prod / Result`), hence
  `name:` on each job.
- **Per file (recommended):** the caller adds one job that needs every
  call and passes only if they all did (the `result` job in
  [the caller example](#the-caller), using this library's `shared/result`
  action), and the ruleset requires that one check, `identity`. Adding a
  deployment means adding it to that job's `needs:`, in the same PR, and
  the ruleset doesn't change.

The OpenTofu README will document both, with the exact check names, and
how to add them to a ruleset.

### Naming

Each call needs names unique within a run and stable across runs: the PR
comment key, the plan artifact and the concurrency groups. They derive
from `working-directory`, `name` (default: the last var file's base name),
`apply-environment` and a digest of the var files (so `eastus/prod.tfvars`
and `westus/prod.tfvars`, both named `prod`, stay apart), and the artifact
name carries a digest of the exact key, so two calls never share an
artifact. PR comment titles read
`OpenTofu: iac/identity · prod-eastus → prod`.

### What carries over

From the current code (`main` and PR #8), unchanged in substance:

- The shared library (`shared/`): logging, outputs, globs, masking,
  `setup` (mise scoped to the module), `pr-comment`, `result`,
  `apply-preflight`, `check-environment` and `require-environments`.
- The OpenTofu actions and scripts: `checks`, `plan` (summary, policy,
  cost), `apply` (preflight, digest), with var files passed to `init`,
  and the private-module token handling.
- Fixes from PR #8: collision-free artifact names, titles that always name
  the environment, the apply job running after a skipped optional job.
- The `arm/` split and the Data Factory and Synapse areas (untouched).

New: var files for TFLint, Trivy and `tofu test`; the prepare job's input
validation and change detection; the `checks` switch; the Azure mapping
with the plan override and Entra ID storage auth.

### What goes

- Discovery: `opentofu/discover`, `discover.sh` and its tests, nested root
  module handling, `search-root`, `exclude`, `modules`, `shared-paths`.
- Deployment files: `deployments/<name>.yaml`, `deployment.yaml`, their
  validation and `export-declared.sh`.
- The generic `KEY=VALUE` export (`export-env.sh`).
- Drift detection: `opentofu-drift.yaml`, `opentofu/drift-report` and its
  example, until it returned in the per-call shape in `v0.4.0` (see
  [Drift detection](#drift-detection)).
- `opentofu-config.yaml` and `opentofu-deploy.yaml`: their jobs move into
  `opentofu.yaml`.
- The five `v0.1.0` OpenTofu examples, replaced by two: one module with
  several deployments (above), and one module deployed once.

### Documentation

The OpenTofu README is rewritten around this design:

- calling it, with the two examples;
- every input, secret and output (the tables above);
- Azure setup: identities, federated credentials for each subject, OIDC
  or secrets, the plan identity;
- private modules and policies (`modules-token`);
- when it applies (the table above);
- branch protection: the check names, per call or per file, and setting up
  the ruleset;
- moving from `v0.1.0`.

### Testing

- **CI** calls `opentofu.yaml` directly for the fixtures, one job per
  deployment: `basic` with three var files (one a plan-only call, one with
  `changed-only` off, one with `checks: false`), and `minimal` (no var
  files, no lock file), with a per-file `result` job. The fixtures don't
  use Azure, so the Azure mapping is covered by script tests; a real OIDC
  run against Azure comes later (see [Decisions](#decisions)).
- **Drift in CI:** `opentofu-drift.yaml` runs against `basic` with
  `issues: false`; its local state is empty on a fresh runner, so the plan
  always has changes and a follow-up job asserts `drift == 'true'`
  (`.github/scripts/assert-equal.sh`). Opening, updating and resolving
  issues needs a real repository, so those paths are covered by script
  tests with a stubbed `gh`.
- **Script tests:** change detection (watched paths, events, diff
  failures) in throwaway Git repositories, like today's discovery tests;
  input validation (each rule, all problems reported at once); and the
  Azure mapping (OIDC or secret per job, the plan and integration test
  overrides as pairs, Entra ID storage auth); the provider cache setup; and
  the drift report (the exit code mapping, `fail-on-drift`, and the issue
  create, update, resolve and re-flag paths).
- **Lint:** the existing hooks; the input sync check shrinks to the ARM
  families, since OpenTofu has one workflow.

### Versioning

`v0.4.0` adds, without breaking `v0.3.x` callers: `opentofu-drift.yaml`,
`integration-test-azure-client-id` and its secret, and `provider-cache`
(on by default; it changes where providers come from, not what runs). The
examples pin `@v0.4.0` where they use them.

`v0.2.0`, breaking relative to `v0.1.0`: `opentofu.yaml` changes from the
discovery entry point to the per-module workflow, the inner workflows and
the inputs listed as removed (after [Outputs](#outputs)) go, and callers move
from one call per repository to one call per deployment. The examples pin
`@v0.2.0`.

PR #8 is closed unmerged, and the refactor lands on a new branch from
`main` that keeps PR #8's carry-over pieces.

## Decisions

Settled in review, with what we gave up, so they can be revisited:

- **One workflow per call, checks included.** Checks and tests run in every
  call, with its var files, rather than in a separate checks-only workflow
  run once per module. A module deployed three times is checked three
  times, but a deployment whose variables trip TFLint, Trivy, a test or a
  policy is caught in its own call. `checks: false` skips them for a call
  that doesn't need them.
- **Credentials as named provider inputs, Azure first.** Rather than
  generic `KEY=VALUE` lines: each input says what it's for, and nothing
  arbitrary reaches the jobs' environment. Other providers, `az` CLI login
  and sovereign clouds wait until a caller needs them.
- **No environment-scoped variable lookup (for now).** Our jobs could read
  a variable from the environment they run in, by name, which the caller
  can't (its job has no environment). That would let one name, e.g.
  `AZURE_CLIENT_ID` set in both `prod` and `prod-plan`, give the plan and
  apply jobs each their own environment's value, so environments hold
  their own identities instead of the repository holding
  `PROD_CLIENT_ID`, `PROD_READ_CLIENT_ID`, and so on. We leave it out
  because it's a second way to pass values, it only works for variables
  (environment secrets can't be read by name), and the caller's file would
  no longer show where a value comes from. Revisit if per-environment
  names at repository level become hard to manage.
- **Warnings fail all or nothing.** `policy-fail-on-warn` fails on any
  warn; failing only above a severity needs a severity convention in the
  policies and is deferred.
- **Drift detection was removed in `v0.2.0`** (keeping it working would
  have meant keeping discovery just for it) **and came back in `v0.4.0`**
  in the same shape: one call per deployment, the same inputs, as a
  separate workflow so `opentofu.yaml` keeps its meaning and its required
  permissions. Its report is GitHub issues, as the old script's was; issues
  are marked resolved rather than closed (see
  [Drift detection](#drift-detection)).
- **A real Azure run in CI later.** The Data Factory e2e already uses a
  real identity through OIDC; an OpenTofu fixture planning against Azure
  can reuse it.
- **A provider cache by default.** It saves a download per job (a module's
  providers can be hundreds of megabytes) at the price of cache storage
  and one more action (`actions/cache`, SHA-pinned). On by default because
  it never changes what runs, only where providers come from, and the lock
  file still verifies them; `provider-cache: false` for runners with a cache
  of their own or a ban on `actions/cache`.
- **Runners per job.** `checks-runs-on`, `integration-test-runs-on`,
  `plan-runs-on` and `apply-runs-on` override `runs-on` for the jobs that
  do the work: those that reach the cloud (e.g. a runner group in a private
  network) and checks (e.g. an image with the tools installed). prepare and
  result only check inputs and collect results, so they don't get one.
  Each is a label or JSON (from `{` or `[`), the forms `runs-on` itself
  takes, rather than separate group and label inputs per job. A plain label
  stays as before.
- **Integration tests use the apply identity unless told otherwise.**
  `integration-test-azure-client-id` and its secret (added in `v0.4.0`)
  give them an identity of their own, with the same pair semantics as the
  plan identity. It stays optional, so existing callers are unaffected, and
  the validation only warns when the tests would run ungated as the apply
  identity.

## Alternatives considered

<!-- markdownlint-disable MD013 -->

| Alternative                                     | Why not                                                     |
| ----------------------------------------------- | ----------------------------------------------------------- |
| Discovery with deployment files (PR #8)         | A second schema, layout rules, no secrets by name           |
| Discovery calling a caller-written workflow     | `uses:` can't be dynamic; callable files live in `.github/` |
| One secret blob per environment                 | Write-only, single-line values, a format of its own         |
| `secrets: inherit` down to the jobs             | Every repository secret reaches every job                   |
| One call per module, with a matrix of var files | A list schema again; secrets can't vary per deployment      |
| Generic `env-vars` / `env-secrets` lines        | A format inside a string; hides what a module needs         |
| A separate checks workflow, once per module     | Misses problems a deployment's own var files cause          |

<!-- markdownlint-enable MD013 -->

## Open questions

None open. Resolved at approval:

1. **Required checks:** per-file aggregation (the caller's own `result`
   job) is the documented default, with per-call checks as the
   alternative (see [Branch protection](#branch-protection)).
2. **Checks in the PR comment:** the PR comment includes a short table of
   the call's check results.
