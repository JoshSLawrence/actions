# OpenTofu

One reusable workflow, [`opentofu.yaml`](../.github/workflows/opentofu.yaml),
for every OpenTofu root module in a repository: point it at a directory and
it finds every root module under it, at any depth, then validates, tests,
lints, scans, plans and applies each of its deployments in its own GitHub
environment, with the plan and apply result posted on the PR. On a PR it
runs only what the change affects.

## Contents

- [The model](#the-model)
- [Deployment files](#deployment-files)
- [Quick start](#quick-start)
- [What a change runs](#what-a-change-runs)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reference](#reference)
- [PR comments](#pr-comments)
- [Security notes](#security-notes)
- [Drift detection](#drift-detection)
- [Coming from the Azure DevOps templates](#coming-from-the-azure-devops-templates)
- [Internals](#internals)

## The model

```text
iac/                          search-root
├── identity/                 a root module: *.tf and a mise.toml
│   ├── backend.tf
│   ├── deployments/
│   │   ├── dev.yaml          deployment "dev" (no .tfvars: defaults)
│   │   ├── prod-eastus.tfvars
│   │   ├── prod-eastus.yaml  deployment "prod-eastus"
│   │   ├── prod-westus.tfvars
│   │   └── prod-westus.yaml  deployment "prod-westus"
│   ├── main.tf
│   ├── mise.toml
│   ├── modules/              child modules of identity: no mise.toml
│   │   └── groups/
│   └── tools/                a root module nested inside identity
│       └── ...
├── network/                  a root module deployed once, as it is
│   ├── deployment.yaml
│   ├── main.tf
│   └── mise.toml
└── sandbox/                  a root module without deployment files:
    ├── main.tf               validated and tested, never deployed
    └── mise.toml
```

- **Root module:** a directory with `*.tf` files and its own `mise.toml`,
  anywhere under `search-root`, including inside another root module.
  Every job installs exactly what that `mise.toml` pins, nothing from the
  repository root, so CI runs the tools you run locally.
- **Child module:** a directory inside a root module without its own
  `mise.toml` (e.g. `modules/groups`, used as `source = "./modules/groups"`):
  part of that root module. A module directory outside every root module
  (e.g. one several root modules share) belongs to none: changing it runs
  nothing unless `shared-paths` lists it.
- **Deployment:** the module applied once, in one GitHub environment,
  with its own variables and state. Each is a pair of files in a flat
  `deployments/` directory, named after the deployment:
  - `<name>.yaml` (required): the
    [deployment file](#deployment-files), saying which environment it
    applies in and which settings and credentials its jobs get;
  - `<name>.tfvars` (optional): its OpenTofu variables. Without one, the
    deployment uses the variables' defaults, and any `TF_VAR_*` its file
    sets.

  The two are coupled by name and nothing else: a `.tfvars` without its
  `.yaml`, a subdirectory, a `.yml` or a `.tfvars.json` fails the run,
  naming the file, rather than being ignored.
- **A module deployed as is:** instead of `deployments/`, a single
  `deployment.yaml` in the module root (OpenTofu still loads its
  `terraform.tfvars`). A module with neither is validated and tested, but
  never deployed.
- **State per deployment:** each deployment sets its own state key through
  a variable the backend block reads (OpenTofu evaluates variables there),
  in its `.tfvars` or as a `TF_VAR_*` in its file. The deployment's
  `.tfvars` is passed to `tofu init` as well as plan and apply:

  ```hcl
  variable "state_key" {
    description = "State file for this deployment, set in its .tfvars."
    type        = string
  }

  terraform {
    backend "azurerm" {
      resource_group_name  = "rg-tfstate"
      storage_account_name = "sttfstate"
      container_name       = "tfstate"
      key                  = var.state_key
    }
  }
  ```

  Then `deployments/prod-eastus.tfvars` sets its key:

  ```hcl
  state_key = "identity-prod-eastus.tfstate"
  ```

  - `tofu init -var-file=deployments/prod-eastus.tfvars` works the same
    locally.
  - Leave the variable without a default: a deployment that forgets it
    fails at `init` instead of using another deployment's state.
  - Set it in `tofu test` files too, in a file-level `variables` block.
    Tests keep state in memory, but a required variable still needs a
    value.
- **Names** of root modules can't contain whitespace; deployment names use
  letters, digits, `.`, `_` and `-`.

## Deployment files

A deployment's `.yaml` says where it applies and what its jobs get as
environment variables. Only what it lists is exported, so two deployments
in the same environment can get different credentials, and one that uses
no cloud gets none:

```yaml
# deployments/prod-eastus.yaml
environment: prod                 # the apply job's GitHub environment
plan-environment: prod-plan       # optional: the plan job's
env:                              # literal values
  ARM_USE_OIDC: "true"
  TF_VAR_location: eastus
vars:                             # GitHub variables, by name
  - ARM_CLIENT_ID
  - ARM_TENANT_ID
  - ARM_SUBSCRIPTION_ID
secrets:                          # GitHub secrets, by name
  - TF_ENCRYPTION
```

<!-- markdownlint-disable MD013 -->

| Key | Required | What it is |
| --- | --- | --- |
| `environment` | yes | GitHub environment the apply job runs in. Give it required reviewers: that's the approval gate |
| `plan-environment` | no | GitHub environment the plan job runs in (no reviewers), e.g. to scope a read-only identity. Without it, plans run without an environment |
| `env` | no | Literal values, `NAME: value`: provider settings, `TF_VAR_*` |
| `vars` | no | GitHub variables to export, by name |
| `secrets` | no | GitHub secrets to export, by name, masked in logs |

<!-- markdownlint-enable MD013 -->

**Where `vars` and `secrets` come from.** Each job looks the names up
where it runs: in its own environment, else at repository level (variables
also at organization level). So one name gives each job its own value:
`ARM_CLIENT_ID` can be a read-only identity in `prod-plan` and a write
identity in `prod`, with nothing more in the file. Shared values (a tenant
ID) can live once at repository level. A listed name with no value fails
the job, naming it and where it looked.

<!-- markdownlint-disable MD013 -->

| Job | Environment its names resolve in |
| --- | --- |
| integration tests | `integration-test-environment` (else repository level) |
| plan | the file's `plan-environment` (else repository level) |
| apply | the file's `environment`, only once its reviewers approve |

<!-- markdownlint-enable MD013 -->

- **Secrets come from environments.** A job sees its environment's
  secrets on its own; repository and organization secrets reach a reusable
  workflow only through its caller, and this workflow doesn't take them.
  Keep the secrets a deployment needs in its environments.
- **Exporting under another name:** `EXPORT_NAME=GITHUB_NAME`. GitHub
  doesn't allow variable or secret names starting with `GITHUB_`, so the
  GitHub provider's token is stored as, say, `GH_PROVIDER_TOKEN` and
  listed as `GITHUB_TOKEN=GH_PROVIDER_TOKEN`.
- **Refused names:** ones that would take over the runner (`PATH`,
  `BASH_ENV`, `RUNNER_*`, `ACTIONS_*`, ...), and every `GITHUB_*` except
  the GitHub provider's own (`GITHUB_TOKEN`, `GITHUB_OWNER`,
  `GITHUB_BASE_URL`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`,
  `GITHUB_APP_PEM_FILE`). A name may be declared only once across `env`,
  `vars` and `secrets`. Unknown keys fail the run.
- **How secrets are read.** GitHub has no way to read a secret by a name
  chosen at run time, so a job whose deployment lists `secrets` passes
  every secret it can see (`toJSON(secrets)`) to the step that exports
  them, which keeps only the listed ones. A deployment that lists none
  never does. Secret values can span lines (a PEM key).
- **PR comments don't use these settings.** They're posted with the run's
  own `github.token`, so a `GITHUB_TOKEN` that deploys GitHub configuration
  never posts comments, and the other way round.

### Azure (OIDC)

No secrets: the azurerm backend and provider fetch GitHub's OIDC token
themselves. Store each environment's identity as GitHub variables
(`ARM_CLIENT_ID` in each environment, `ARM_TENANT_ID` and
`ARM_SUBSCRIPTION_ID` at repository level if they're shared), and list them:

```yaml
environment: prod
plan-environment: prod-plan
env:
  ARM_USE_OIDC: "true"
vars: [ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID]
```

- Add a federated credential to each identity for each subject its jobs
  present: `<prefix>:environment:<name>` for jobs in an environment;
  `<prefix>:pull_request` (PR plans) and `<prefix>:ref:refs/heads/main`
  (push and dispatch plans) for jobs without one.
- `<prefix>` is `repo:<owner>/<repo>`, or on newer repositories
  `repo:<owner>@<owner-id>/<repo>@<repo-id>`. Get yours with
  `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`
  (`sub_claim_prefix`). A mismatch fails `tofu init` with AADSTS700213,
  which quotes the subject presented.
- Plans need to read state and the resources; applies need to change them.
  Give plans a read-only identity in a `plan-environment`.

### Other providers

The same keys, with the variables the provider reads. For example:

<!-- markdownlint-disable MD013 -->

| Provider | `env` or `vars` | `secrets` |
| --- | --- | --- |
| AWS (access keys) | `AWS_REGION` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Google Cloud | `GOOGLE_PROJECT` | `GOOGLE_CREDENTIALS` (service account key JSON) |
| Azure DevOps | `AZDO_ORG_SERVICE_URL` | `AZDO_PERSONAL_ACCESS_TOKEN` |
| GitHub | `GITHUB_OWNER` | `GITHUB_TOKEN=GH_PROVIDER_TOKEN` |
| State and plan encryption | | `TF_ENCRYPTION` |
| Any variable | `TF_VAR_region` | `TF_VAR_db_password` |

<!-- markdownlint-enable MD013 -->

**AWS and Google Cloud OIDC aren't supported.** Their providers can't fetch
GitHub's OIDC token themselves (azurerm can); it takes a step this workflow
doesn't run. Use their static credentials as above, or open an issue.

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
      search-root: iac
```

The caller must grant the four permissions shown: a reusable workflow's jobs
can only narrow them, and GitHub rejects the run if one asks for more.
[`examples/opentofu.yaml`](../examples/opentofu.yaml) is a complete caller,
with the Azure setup.

## What a change runs

On `pull_request` and `push` runs (with `changed-only`, the default), each
changed file selects:

<!-- markdownlint-disable MD013 -->

| Changed file | Runs |
| --- | --- |
| A deployment's `deployments/<name>.yaml` or `<name>.tfvars` (added, changed, or the `.tfvars` deleted) | Just that deployment |
| Anything else in a root module (`.tf` files, `deployment.yaml`, child modules, tests, `mise.toml`, a lock file, other files in `deployments/`) | Every deployment of that module (a module without any is validated and tested) |
| A file matching `shared-paths` | Everything |
| Anything else (including a module directory outside every root module) | Nothing |

<!-- markdownlint-enable MD013 -->

- A file belongs to the deepest root module containing it, so a nested
  root module's changes don't run its parent, and a child module's
  changes run only the root module it's in, even if another root module
  also points at it.
- List anything else that should run everything in `shared-paths` (e.g.
  `iac/modules/**`, or the caller workflow itself).
- `workflow_dispatch`, `schedule` and other events, `modules`, and a diff
  that can't be computed run every deployment of the modules concerned:
  planning too much is safe.
- **Deleting is not destroying.** A deleted deployment (its `.yaml`) or
  root module isn't planned, so nothing destroys what it managed; the run
  warns about it. Plan its resources away (or run `tofu destroy`) first.
- Discovery's job summary shows every root module, what it runs and why,
  and which environment each deployment applies in.

## How it works

```text
opentofu.yaml    discover ──> config (per root module) ──> result
                                 │
opentofu-config  validate ──> deploy (per deployment) ──> result
                                 │
opentofu-deploy  integration tests ──> plan ──> apply (after approval)
```

- **discover** finds the root modules, selects what to run (above) and
  reads the selected deployments' files. Then it fails unless every
  environment they name (and `integration-test-environment`) exists. It
  runs before any job names one, so GitHub never creates an environment
  implicitly (it would, without protection rules).
- **validate** runs once per root module: fmt, validate, TFLint, Trivy, the
  terraform-docs check and `tofu test`, each switchable. fmt, TFLint and
  Trivy cover the module's subdirectories too, nested root modules
  included. Every enabled check runs even when an earlier one fails, and a
  results table goes to the job summary. It gets no cloud credentials, so
  PRs from forks can run it.
- **integration tests** (off by default) run `tofu test` again per
  deployment, before its plan, with its `.tfvars` and what its file
  declares, in `integration-test-environment`.
- **plan** (per deployment) plans to a saved file and renders a summary:
  counts, destroys called out, resources, and the full plan as a diff. It
  can add an Infracost estimate and a conftest policy check (failing policy
  deletes the plan, so it can't be applied). It uploads the plan and
  comments the summary on the PR. Skipped for fork PRs, which get no OIDC
  token.
- **apply** (per deployment) runs only when the plan has changes, and waits
  for its environment's reviewers. Then:
  1. it refuses a stale plan: the PR moved on, or anything the plan depends
     on (the module, `shared-paths`) changed on the target branch since;
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

## Setup

1. **Pin each root module's tools** in its own `mise.toml`, for example
   `mise use opentofu@1.12.6 tflint@0.64.0 trivy@0.74.0` in the module
   directory. Commit `.terraform.lock.hcl` too.
   - A plain `mise install` in a module also installs what every
     `mise.toml` above it pins, and your global config. CI installs only
     the module's own tools; to do the same locally, run this in the
     module:

     ```bash
     MISE_CEILING_PATHS="$(dirname "$PWD")" MISE_GLOBAL_CONFIG_FILE=/nonexistent/config.toml mise install
     ```

     `MISE_CEILING_PATHS` stops mise looking above the module, and the
     global config path points at nothing. Drop the second variable to
     keep your global tools.
2. **Lay out deployments** as in [the model](#the-model): a `<name>.yaml`
   per deployment, each setting its own state key (in its `.tfvars`, or a
   `TF_VAR_*`).
3. **Create every environment the deployment files name**, before the
   first run: a run that would use one that doesn't exist fails, naming
   it. Give apply environments **required reviewers**; plan environments
   none. The apply job also warns when its environment has no required
   reviewers.
   - Required reviewers on a **private** repository need GitHub Enterprise.
     Without them, `apply-from-pr: true` applies every PR's plan
     unattended; `apply-from-pr: false` makes merging the approval.
4. **Credentials:** the GitHub variables and secrets the deployment files
   list, in those environments (or variables at repository level). See
   [Deployment files](#deployment-files).
5. **Branch protection:** require `<caller job> / Result`. With
   `apply-from-pr`, also consider "Require branches to be up to date before
   merging".

## Reference

Paths are relative to the repository root, except `test-filter`, which (as
in OpenTofu) is relative to the root module. List inputs accept spaces or
newlines. Globs follow GitHub's `paths:` rules: `*` stays within a
directory, `**` crosses directories.

<!-- markdownlint-disable MD013 -->

### Discovery

| Input | Default | Description |
| --- | --- | --- |
| `search-root` | `.` | Directory to search for root modules (it may be the only one) |
| `exclude` | none | Globs of module paths to skip, e.g. `legacy/**` |
| `modules` | all | Run exactly these module paths, every deployment (e.g. from a dispatch input) |
| `changed-only` | `true` | PR/push runs only run what changed (see [What a change runs](#what-a-change-runs)) |
| `shared-paths` | none | Globs whose change runs everything, and makes plans stale |

### Checks

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
| `integration-tests` | `false` | `tofu test` again per deployment, with its `.tfvars` and declared settings |
| `integration-test-filter` | all | Test files for the integration runs |
| `integration-test-environment` | none | Environment for the integration jobs (must exist) |
| `integration-test-timeout-minutes` | `90` | Their timeout (a timeout leaks what the test created) |

### Plan

| Input | Default | Description |
| --- | --- | --- |
| `plan-retention-days` | `7` | Plan artifact retention; a later approval fails |
| `pr-comment` | `true` | Comment the plan and apply result on the PR |
| `policy` | `false` | conftest policy check; failing blocks the apply |
| `policy-path` | `policy` | Policy directories |
| `policy-source` | none | go-getter URL for (more) policies |
| `policy-namespaces` | all | Rego namespaces to evaluate |
| `policy-fail-on-warn` | `false` | Also block on `warn` rules |
| `cost-estimate` | `false` | Infracost estimate (needs `infracost-api-key`); when off, the plan summary and PR comment say so |

The plan environment is the deployment file's `plan-environment`.

### Apply

| Input | Default | Description |
| --- | --- | --- |
| `apply` | `true` | Include the apply job (`false` = plan only) |
| `apply-from-pr` | `true` | Apply from the PR before merge; `false` = on the default branch only |

The apply environment is the deployment file's `environment`.

### Runners and tools

| Input | Default | Description |
| --- | --- | --- |
| `runs-on` | `ubuntu-latest` | Runner label for every job |
| `timeout-minutes` | `30` | Timeout for each job |
| `max-parallel` | `4` | Most jobs of one matrix at once (root modules; each one's deployments) |
| `mise-version` | `2026.9.12` | mise version |

### Secrets

| Secret | Description |
| --- | --- |
| `modules-token` | Token that can read private GitHub repositories used as module or policy sources |
| `infracost-api-key` | Infracost API key |

Deployments' own secrets come from their environments, not from the caller
(see [Deployment files](#deployment-files)).

### Outputs

| Output | Description |
| --- | --- |
| `modules` | JSON array of the root modules that ran |

<!-- markdownlint-enable MD013 -->

## PR comments

- **One comment per deployment per PR**, edited in place by every run.
  Its title always says which deployment applies in which environment,
  e.g. OpenTofu: `iac/identity` · `prod-eastus` → `prod`. The deployment
  jobs are named the same way.
  - **Contents:** the plan summary (plus the cost and policy sections) and
    where the apply stands: awaiting approval, applying after merge,
    blocked by policy, applied (and by whose approval), or failed.
  - **History:** earlier versions stay in the comment's edit history, and a
    footer on the comment points readers to it (the **edited** menu).
  - **Out-of-order runs:** a run for an outdated PR head leaves the comment
    alone.
  - **Size:** plan output is truncated to fit GitHub's limit; the full plan
    is in the run log.
- **Author:** only comments by `github-actions[bot]` are edited.

## Security notes

- **Plans hold state.** A plan file embeds a copy of the state, and
  artifacts of a public repository are readable by anyone. Keep secrets out
  of state (`tofu show` hides values marked sensitive), or use OpenTofu's
  native state and plan encryption: list `TF_ENCRYPTION` in the
  deployment's `secrets`, in both its plan and apply environments.
- **Least privilege.** validate never gets cloud credentials. Each
  deployment gets only what its file lists. Plans and applies can use
  different identities, and an apply environment's values exist only after
  its approval.
- **The deployment file is code.** It's reviewed in the PR like the `.tf`
  files: it decides which environment, and so which identity and approval
  gate, a deployment uses. Environment protection rules and federated
  credentials bound to environment names are what keep a PR from deploying
  where it shouldn't.
- **Private repositories.** The default `GITHUB_TOKEN` can only read the
  calling repository. Pass a token that can read the others as
  `modules-token`. This library itself needs no token: its Actions access
  setting grants the calling repositories (see the top-level README).
- **Fork PRs** are validated, never planned.

## Drift detection

[`opentofu-drift.yaml`](../.github/workflows/opentofu-drift.yaml) plans
every deployment of every root module on a schedule, lock-free, and opens
an issue per drifted deployment (labelled `drift`), updated while the drift
lasts and closed once it's gone. See
[`examples/opentofu-drift.yaml`](../examples/opentofu-drift.yaml).

It hasn't been brought in line with deployment files yet: it plans in each
deployment's `plan-environment` (or its own `plan-environment` input), but
takes Azure inputs (`azure-client-id`, ...) and an `env-vars` secret
instead of each file's `env`, `vars` and `secrets`, and doesn't check the
environments exist.

## Coming from the Azure DevOps templates

<!-- markdownlint-disable MD013 -->

| Azure DevOps (`pipeline-templates`) | Here |
| --- | --- |
| `opentofu-pipeline.yml`, `opentofu-multi-root-pipeline.yml` | `opentofu.yaml`; the marker is `mise.toml`, not `backend.tf` |
| One pipeline call per environment with `varFile` | One call; a `<name>.yaml` (and `<name>.tfvars`) per deployment in `deployments/` |
| `requireFormatCheck`, `requireLintCheck`, ... | `fmt`, `tflint`, `trivy`, `docs`, `tests`, ... |
| Environment approval on the deployment job | The deployment file's `environment`, with required reviewers |
| `azureServiceConnection` / `applyAzureServiceConnection` | `vars` in the deployment file, resolved in the plan and apply environments |
| `tfplan_<env>` artifact | One plan artifact per deployment, SHA-256 checked before apply |
| PR thread with a reply per run | One comment per deployment, edited in place |
| `enableConftest`, `enableInfracost` | `policy`, `cost-estimate` |
| ResultGate stage | `result` job |

<!-- markdownlint-enable MD013 -->

## Internals

`opentofu.yaml` is built from two inner reusable workflows and composite
actions, all in this directory and `.github/workflows/`. They're not meant
to be called on their own, and their interfaces may change in any release.

- [`opentofu-config.yaml`](../.github/workflows/opentofu-config.yaml): one
  root module, validated once, then each selected deployment.
- [`opentofu-deploy.yaml`](../.github/workflows/opentofu-deploy.yaml):
  integration tests → plan → apply for one deployment.
- Composite actions, one per directory: `discover`, `checks`, `plan`,
  `apply`, `drift-report`; plus the shared library's `shared/setup` (which
  exports what a deployment file declares), `shared/pr-comment` and
  `shared/result`.

The logic is in [`scripts/`](scripts/), on top of the shared library
([`../shared/scripts/`](../shared/scripts/)). Each script documents its
environment variables at the top and runs locally too, e.g.:

```bash
SEARCH_ROOT=iac CHANGED_ONLY=false opentofu/scripts/discover.sh
```

[`tests/opentofu/discover-test.sh`](../tests/opentofu/discover-test.sh)
tests change detection, deployment files and the layouts refused;
[`tests/shared/export-declared-test.sh`](../tests/shared/export-declared-test.sh)
what a deployment's jobs export. CI runs the workflow end to end against
[`tests/fixtures/opentofu/`](../tests/fixtures/opentofu/).
