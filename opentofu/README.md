# OpenTofu

Validate, test, lint, scan, plan and apply OpenTofu, with the plan and the
apply result posted on the PR, plus scheduled drift detection. It works for
a repository with one root module, a monorepo of many, and a configuration
deployed many times with different `.tfvars` files.

## Contents

- [Which workflow?](#which-workflow)
- [Concepts](#concepts)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reference](#reference)
- [Composite actions](#composite-actions)
- [PR comments and drift issues](#pr-comments-and-drift-issues)
- [Security notes](#security-notes)
- [Coming from the Azure DevOps templates](#coming-from-the-azure-devops-templates)

## Which workflow?

<!-- markdownlint-disable MD013 -->

| Workflow | Use it for | Point it at |
| --- | --- | --- |
| [`opentofu.yaml`](../.github/workflows/opentofu.yaml) | A repository: one root module or a monorepo. **Start here.** | `search-root` |
| [`opentofu-config.yaml`](../.github/workflows/opentofu-config.yaml) | One configuration, deployed once or with many `.tfvars` files | `working-directory` |
| [`opentofu-drift.yaml`](../.github/workflows/opentofu-drift.yaml) | Scheduled drift detection, for any of the above | `search-root` |
| [`opentofu-deploy.yaml`](../.github/workflows/opentofu-deploy.yaml) | Building block: plan + apply of one deployment, no checks | `working-directory` |

<!-- markdownlint-enable MD013 -->

They nest: `opentofu.yaml` calls `opentofu-config.yaml` for each root
module, which calls `opentofu-deploy.yaml` for each deployment. An input
means the same thing in every workflow that has it.

## Concepts

- **Root module** (a "config"): a directory with `*.tf` files and its own
  `mise.toml`. `opentofu.yaml` and `opentofu-drift.yaml` find every one
  under `search-root`, which may itself be the only one.
- **Deployment**: a root module applied with one `.tfvars` file. It could
  be dev and prod, one per region, or one per customer, each with its own
  state.
  - `deployments` lists the files, as globs or paths relative to the
    module, e.g. `deployments/*.tfvars`. Each deployment is named after its
    file (`prod.tfvars` → `prod`).
  - **Backend config per deployment:** put a `.tfbackend` file with the same
    name next to the `.tfvars` (`prod.tfbackend`). It's added to that
    deployment's `-backend-config`. Or use `{deployment}` in
    `backend-config`, e.g. `key=app-{deployment}.tfstate`.
  - `{deployment}` also works in `apply-environment` and `plan-environment`.
    With `apply-environment: "{deployment}"`, dev and prod get their own
    GitHub environments, reviewers and identities.
  - A module that `deployments` matches nothing in is deployed once, as it
    is.
- **Tools come from mise, per root module.** Every job runs `mise install`
  in the module and gets **exactly** what the module's own `mise.toml`
  pins.
  - Nothing is inherited from the repository root, or from a runner's
    global mise config, so a root `mise.toml` full of dev tools is never
    installed in CI.
  - Every enabled check's tool must be pinned (for example `trivy` for the
    Trivy scan). A missing pin fails the job, listing everything that's
    missing, rather than silently skipping the check.
  - Why in each module rather than one shared file? It's where mise, your
    editor and your local hooks already look, so CI runs what you run. It
    also lets each module move independently (Renovate and Dependabot can
    both bump `mise.toml` pins).

## Quick start

```yaml
name: OpenTofu

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

jobs:
  opentofu:
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v1
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      search-root: infra
      apply-environment: production
```

The caller must grant the four permissions shown: a reusable workflow's jobs
can only narrow them, and GitHub rejects the run if one asks for more. The
drift workflow needs `contents: read`, `id-token: write` and
`issues: write`.

Complete callers are in [`examples/`](../examples/):

<!-- markdownlint-disable MD013 -->

| Example | Shows |
| --- | --- |
| [`opentofu-repo.yaml`](../examples/opentofu-repo.yaml) | A repository's root module(s) on Azure, applied from the PR, with the setup it needs |
| [`opentofu-monorepo.yaml`](../examples/opentofu-monorepo.yaml) | Many root modules, each with dev/prod deployments and environments |
| [`opentofu-config-deployments.yaml`](../examples/opentofu-config-deployments.yaml) | One configuration deployed per customer, state keys via `{deployment}` |
| [`opentofu-drift.yaml`](../examples/opentofu-drift.yaml) | Nightly drift detection with issues |
| [`opentofu-apply-on-merge.yaml`](../examples/opentofu-apply-on-merge.yaml) | PRs only plan; apply after merge |
| [`opentofu-composite-actions.yaml`](../examples/opentofu-composite-actions.yaml) | Your own plan/apply workflow from the composite actions |

<!-- markdownlint-enable MD013 -->

## How it works

```text
opentofu.yaml    discover ──> config (per root module) ──> result
                                 │
opentofu-config  deployments ─┬─> deploy (per deployment) ──> result
                 validate ────┤      │
                 integration ─┘      │
                                     │
opentofu-deploy                   plan ──> apply (after approval)
```

- **discover** finds the root modules under `search-root`. On `pull_request`
  and `push` runs it keeps only those the change affects: their own files,
  a local module they use (`source = "../modules/x"`, followed
  recursively), or anything matching `shared-paths`. Other events run
  everything, and so does a diff that can't be computed; planning too much
  is safe. A root module that's deleted gets a warning, because deleting it
  doesn't destroy what it managed.
- **validate** runs once per root module: fmt, validate, TFLint, Trivy, the
  terraform-docs check and `tofu test`, each switchable. Every enabled check
  runs even when an earlier one fails, and a results table goes to the job
  summary. It gets no cloud credentials, so PRs from forks can run it.
- **integration-tests** (off by default) runs `tofu test` with cloud
  credentials after validate passes, optionally behind an environment
  approval. Deployments wait for it.
- **plan** (per deployment) plans to a saved file and renders a summary:
  counts, destroys called out, resources, and the full plan as a diff. It
  can add an Infracost estimate and a conftest policy check (failing policy
  deletes the plan, so it can't be applied). It uploads the plan and
  comments the summary on the PR. Skipped for fork PRs, which get no OIDC
  token.
- **apply** (per deployment) runs only when the plan has changes, and waits
  for the `apply-environment`'s reviewers. Then:
  1. it refuses a stale plan: the PR moved on, or anything the plan depends
     on (the module, its local modules, its var and backend files,
     `shared-paths`) changed on the target branch since;
  2. it checks the plan file's SHA-256;
  3. it applies exactly that plan;
  4. it updates the PR comment.
- **result** rolls everything up into one check to require in branch
  protection: `<caller job> / Result`.

### Apply from the PR (default) or on merge

With `apply-from-pr: true` (the default), the reviewed plan is applied from
the PR, before merge.

- **The default branch only ever holds configuration that applied
  successfully.** If you require the `Result` check, a PR with changes
  can't merge until it's applied.
- **Rolling back an unmerged PR:** if a PR is applied but then not merged,
  run the workflow on the default branch (`workflow_dispatch`) to re-apply
  what's there.

`apply-from-pr: false` makes PRs plan only. The push to the default branch
then plans again and applies after approval. Runs that aren't PRs only
apply on the default branch; use environment deployment branch policies for
more control.

### Drift detection

`opentofu-drift.yaml` plans every deployment of every root module (all of
them, whatever changed) with the same plan action, lock-free.

- **Drift found:** it opens an issue for that deployment, labelled `drift`.
  Later checks update the issue's body in place, so a daily check doesn't
  notify anyone again.
- **Drift gone:** it comments on the issue and closes it.
- **Failing the run:** a check that can't run fails it. With
  `fail-on-drift`, drift fails it too.

## Setup

1. **Pin each root module's tools** in its own `mise.toml`, for example
   `mise use opentofu@1.12.6 tflint@0.64.0 trivy@0.74.0` in the module
   directory. Commit `.terraform.lock.hcl` too.
2. **Apply environment:** a GitHub environment with **required reviewers**,
   passed as `apply-environment` (or `"{deployment}"`, for one per
   deployment). GitHub creates any environment a workflow names on first
   use, without protection rules. The apply job warns when its environment
   has no required reviewers.
   - Required reviewers on a **private** repository need GitHub Enterprise.
     Without them, `apply-from-pr: true` applies every PR's plan
     unattended; `apply-from-pr: false` makes merging the approval.
3. **Plan environment (optional):** one without reviewers, passed as
   `plan-environment`, to scope read-only credentials to plans and drift
   checks.
4. **Azure OIDC.** No secrets are needed: set the variables
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, or pass
   `azure-client-id` and friends.
   - Variables scoped to an environment win in that environment's jobs, so
     each environment can hold its own identity.
   - Add a federated credential for each subject the jobs present:
     `<prefix>:environment:<name>`; for jobs without an environment,
     `<prefix>:pull_request` (PR plans) and `<prefix>:ref:refs/heads/main`
     (push, dispatch and drift runs).
   - `<prefix>` is `repo:<owner>/<repo>`, or on newer repositories
     `repo:<owner>@<owner-id>/<repo>@<repo-id>`. Get yours with
     `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`
     (`sub_claim_prefix`). A mismatch fails `tofu init` with AADSTS700213,
     which quotes the subject presented.
   - The azurerm backend and providers fetch OIDC tokens themselves. Set
     `azure-login: true` only if your configuration shells out to the az
     CLI.
5. **Other providers:** put credentials in a secret with one `KEY=VALUE` per
   line and pass it as the `env-vars` secret. `apply-env-vars` adds
   write-only credentials for the apply job.
6. **Branch protection:** require `<caller job> / Result`. With
   `apply-from-pr`, also consider "Require branches to be up to date before
   merging".

## Reference

Paths are relative to the repository root, except `deployments`,
`var-files`, `backend-config` files and `test-filter`, which (as in
OpenTofu) are relative to the root module. List inputs accept spaces or
newlines. `{deployment}` is replaced where noted.

<!-- markdownlint-disable MD013 -->

### Discovery (`opentofu.yaml`, `opentofu-drift.yaml`)

| Input | Default | Description |
| --- | --- | --- |
| `search-root` | `.` | Directory to search for root modules |
| `exclude` | none | Globs of module paths to skip, e.g. `legacy/**` |
| `modules` | all | Run exactly these module paths (e.g. from a dispatch input) |
| `changed-only` | `true` | PR/push runs only run affected modules (`opentofu.yaml` only) |
| `shared-paths` | none | Globs whose change affects every module, and makes plans stale (`opentofu.yaml` only) |

Globs follow GitHub's `paths:` rules: `*` stays within a directory, `**`
crosses directories.

### Which root module (`opentofu-config.yaml`, `opentofu-deploy.yaml`)

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | The root module |
| `stack-name` | working directory | Display name; set distinct ones when calling a workflow twice for the same module |

### Deployments

| Input | Default | Description |
| --- | --- | --- |
| `deployments` | none | `.tfvars` files, one deployment each; globs match within the module |
| `var-files` | none | Var files every deployment uses, before its own |
| `backend-config` | none | `-backend-config` values every deployment uses, one per line; `{deployment}` |

### Checks (`opentofu.yaml`, `opentofu-config.yaml`)

| Input | Default | Description |
| --- | --- | --- |
| `fmt` | `true` | `tofu fmt -check -recursive` |
| `validate` | `true` | `tofu init -backend=false` + `tofu validate` |
| `tflint` | `true` | TFLint, recursive; uses `.tflint.hcl` if present |
| `trivy` | `true` | Trivy misconfiguration scan; uses `trivy.yaml` if present |
| `trivy-severity` | `trivy.yaml`'s, else `CRITICAL,HIGH` | Severities that fail the scan |
| `docs` | `false` | Fail if the terraform-docs README is stale |
| `tests` | `true` | `tofu test` without cloud credentials (skipped without test files) |
| `test-filter` | all | Test files (globs allowed) |
| `test-verbose` | `false` | `tofu test -verbose` |
| `integration-tests` | `false` | `tofu test` again with cloud credentials |
| `integration-test-filter` | all | Test files for the integration run |
| `integration-test-environment` | none | Environment for the integration job |
| `integration-test-timeout-minutes` | `90` | Its timeout (a timeout leaks what the test created) |

### Plan

| Input | Default | Description |
| --- | --- | --- |
| `plan-environment` | none | Environment for plan jobs (and drift checks); `{deployment}` |
| `plan-retention-days` | `7` | Plan artifact retention; a later approval fails |
| `pr-comment` | `true` | Comment the plan and apply result on the PR |
| `policy` | `false` | conftest policy check; failing blocks the apply |
| `policy-path` | `policy` | Policy directories |
| `policy-source` | none | go-getter URL for (more) policies |
| `policy-namespaces` | all | Rego namespaces to evaluate |
| `policy-fail-on-warn` | `false` | Also block on `warn` rules |
| `cost-estimate` | `false` | Infracost estimate (needs `infracost-api-key`) |

### Apply

| Input | Default | Description |
| --- | --- | --- |
| `apply` | `true` | Include the apply job (`false` = plan only) |
| `apply-from-pr` | `true` | Apply from the PR before merge; `false` = on the default branch only |
| `apply-environment` | none | Environment with required reviewers; `{deployment}` |
| `preflight-paths` | working directory | What plans depend on (`opentofu-config.yaml`, `opentofu-deploy.yaml`; `opentofu.yaml` works it out) |

### Drift (`opentofu-drift.yaml`)

| Input | Default | Description |
| --- | --- | --- |
| `create-issues` | `true` | One issue per drifted deployment, updated, closed when resolved |
| `issue-labels` | `drift` | Labels, comma-separated; the first finds existing issues |
| `fail-on-drift` | `false` | Fail the run on drift |

### Runners, tools and cloud auth

| Input | Default | Description |
| --- | --- | --- |
| `runs-on` | `ubuntu-latest` | Runner label for every job |
| `timeout-minutes` | `30` | Timeout for each job |
| `max-parallel` | `4` | Most jobs of one matrix at once (root modules; each one's deployments) |
| `mise-version` | `2026.9.12` | mise version |
| `azure-client-id` | `vars.AZURE_CLIENT_ID` | Azure identity for OIDC |
| `apply-azure-client-id` | `azure-client-id` | Separate (write) identity for apply |
| `azure-tenant-id` | `vars.AZURE_TENANT_ID` | Azure tenant |
| `azure-subscription-id` | `vars.AZURE_SUBSCRIPTION_ID` | Azure subscription |
| `azure-login` | `false` | Also `azure/login`, for the az CLI |

### Secrets

| Secret | Description |
| --- | --- |
| `env-vars` | `KEY=VALUE` lines exported (masked): other providers' credentials, `TF_VAR_*`, `TF_ENCRYPTION` |
| `apply-env-vars` | `KEY=VALUE` lines for apply jobs only, overriding `env-vars` |
| `modules-token` | Token that can read private GitHub repositories used as module or policy sources |
| `infracost-api-key` | Infracost API key |

The drift workflow takes `env-vars` and `modules-token`.

### Outputs

| Workflow | Output | Description |
| --- | --- | --- |
| `opentofu.yaml` | `modules` | JSON array of the root modules that ran |
| `opentofu-config.yaml` | `deployments` | JSON array of the deployment names |
| `opentofu-deploy.yaml` | `has-changes`, `applied` | Whether the plan had changes / was applied |

<!-- markdownlint-enable MD013 -->

## Composite actions

The workflows are made of these; use them directly for a different job
layout. Each action's inputs are documented in its `action.yaml`, and paths
are relative to the workspace. Run `setup` first in every job.

<!-- markdownlint-disable MD013 -->

| Action | Does |
| --- | --- |
| [`opentofu/discover`](discover/action.yaml) | Root modules under a directory, filtered to a change; module and deployment matrices |
| [`opentofu/deployments`](deployments/action.yaml) | One root module's deployments as a matrix |
| [`opentofu/setup`](setup/action.yaml) | Installs mise, then exactly the module's pinned tools; checks the required ones are pinned |
| [`opentofu/checks`](checks/action.yaml) | fmt, validate, TFLint, Trivy, docs, tests, each switchable |
| [`opentofu/plan`](plan/action.yaml) | Plan to a file, summary, optional cost estimate and policy check |
| [`opentofu/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, apply |
| [`opentofu/pr-comment`](pr-comment/action.yaml) | Create or update the PR comment for one deployment |
| [`opentofu/drift-report`](drift-report/action.yaml) | Open, update or close a deployment's drift issue |
| [`opentofu/result`](result/action.yaml) | Roll a workflow's jobs up into one check |

<!-- markdownlint-enable MD013 -->

The logic is in [`scripts/`](scripts/). Each script documents its
environment variables at the top, uses the helpers in
[`scripts/common.sh`](scripts/common.sh), and runs locally too. For example:

```bash
WORKING_DIR=infra DEPLOYMENTS='deployments/*.tfvars' opentofu/scripts/deployments.sh
```

## PR comments and drift issues

- **One comment per deployment per PR**, edited in place by every run:
  - **Contents:** the plan summary (plus the cost and policy sections) and
    where the apply stands: awaiting approval, applying after merge,
    blocked by policy, applied (and by whose approval), or failed.
  - **History:** earlier versions stay in the comment's edit history.
  - **Out-of-order runs:** a run for an outdated PR head leaves the comment
    alone.
  - **Size:** plan output is truncated to fit GitHub's limit; the full plan
    is in the run log.
- **One issue per drifted deployment**, found by a hidden marker among open
  issues with the first of `issue-labels`. Its body is replaced by each
  check while the drift lasts, and it's closed once the drift is gone.
- **Author:** only comments and issues by `github-actions[bot]` are edited.
  If you use a GitHub App token, set the actions' `comment-author` /
  `issue-author`.

## Security notes

- **Plans hold state, and drift issues hold plan output.** A plan file
  embeds a copy of the state. Artifacts and issues of a public repository
  are readable by anyone. Keep secrets out of state (`tofu show` hides
  values marked sensitive), or use OpenTofu's native state and plan
  encryption: pass `TF_ENCRYPTION` through `env-vars`.
- **Least privilege.** validate never gets cloud credentials. Plans, drift
  checks and applies can use different identities, and apply credentials
  exist only after approval.
- **Private repositories.** The default `GITHUB_TOKEN` can only read the
  calling repository. Pass a token that can read the others as
  `modules-token`. This library itself needs no token: its Actions access
  setting grants the calling repositories (see the top-level README).
- **Fork PRs** are validated, never planned.

## Coming from the Azure DevOps templates

<!-- markdownlint-disable MD013 -->

| Azure DevOps (`pipeline-templates`) | Here |
| --- | --- |
| `opentofu-pipeline.yml` (single root) | `opentofu-config.yaml` (or `opentofu.yaml` pointed at the module) |
| `opentofu-multi-root-pipeline.yml` (discover + matrix) | `opentofu.yaml`; the marker is `mise.toml`, not `backend.tf` |
| One pipeline call per environment with `varFile` | `deployments: env/*.tfvars` (+ a `.tfbackend` each) in one call |
| `requireFormatCheck`, `requireLintCheck`, ... | `fmt`, `tflint`, `trivy`, `docs`, `tests`, ... |
| Environment approval on the deployment job | `apply-environment` with required reviewers; `{deployment}` for one per deployment |
| `azureServiceConnection` / `applyAzureServiceConnection` | Environment-scoped `AZURE_CLIENT_ID`, or `azure-client-id` / `apply-azure-client-id` |
| `tfplan_<env>` artifact | One plan artifact per deployment, SHA-256 checked before apply |
| PR thread with a reply per run | One comment per deployment, edited in place |
| `enableConftest`, `enableInfracost` | `policy`, `cost-estimate` |
| ResultGate stage | `result` job |
| Drift pipeline + ADO work items | `opentofu-drift.yaml` + GitHub issues (closed automatically once resolved) |

<!-- markdownlint-enable MD013 -->
