# OpenTofu

One reusable workflow, [`opentofu.yaml`](../.github/workflows/opentofu.yaml),
that checks, tests, plans and applies **one root module, with one set of var
files, in one environment**. You call it from your own workflow files, once
per deployment, with that deployment's var files, environments and
credentials. Everything a run does is in your workflow YAML.

The design and the decisions behind it are in
[`docs/design/opentofu-per-root-module.md`](../docs/design/opentofu-per-root-module.md).

## Contents

- [Calling it](#calling-it)
- [How a call runs](#how-a-call-runs)
- [Inputs](#inputs)
- [Change detection](#change-detection)
- [When it applies](#when-it-applies)
- [Checks](#checks)
- [Policy](#policy)
- [Azure](#azure)
- [Private modules and policies](#private-modules-and-policies)
- [Runners](#runners)
- [Branch protection](#branch-protection)
- [Setup](#setup)
- [PR comments](#pr-comments)
- [Security notes](#security-notes)
- [Moving from v0.1.0](#moving-from-v010)
- [Internals](#internals)

## Calling it

One job per deployment. A module deployed once:

```yaml
jobs:
  network:
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v0.3.0
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: iac/network
      var-files: prod.tfvars
      apply-environment: prod
      azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
      azure-subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
```

- **The four permissions are required.** A reusable workflow's jobs can only
  narrow the caller's permissions, and GitHub rejects the run if one asks
  for more.
- **Several deployments of one module** are several jobs in one workflow
  file, each with its own var files, environments and identity, ordered
  with `needs:` if one should wait for another.
- **Unrelated root modules** get their own workflow files, so they run, pass
  and fail independently.

Complete callers:
[`examples/opentofu.yaml`](../examples/opentofu.yaml) (one module, deployed
once) and
[`examples/opentofu-deployments.yaml`](../examples/opentofu-deployments.yaml)
(one module deployed to dev and two production regions, with one check for
all of them).

## How a call runs

```text
prepare ──> checks ──> integration-tests ──> plan ──> apply ──> result
           (no creds)      (opt-in)        (per PR)  (after approval)
```

- **prepare** checks every input up front, listing every problem at once
  (see [Setup](#setup) for what it checks), checks every environment the
  call names exists, and decides whether this run plans (see
  [Change detection](#change-detection)). GitHub creates a missing
  environment, unprotected, the first time a job names one; this fails
  first instead.
- **checks** runs fmt, validate, TFLint, Trivy, the terraform-docs check and
  `tofu test`, each switchable, with the call's var files. Every enabled
  check runs even when an earlier one fails, and a results table goes to
  the job summary and the PR comment. No cloud credentials, so PRs from
  forks can run it.
- **integration-tests** (off by default) runs `tofu test` again with the
  call's var files and the apply identity, in
  `integration-test-environment`.
- **plan** plans to a saved file in `plan-environment` and renders a
  summary: counts, destroys called out, resources, the full plan as a diff,
  and optionally an Infracost estimate and a conftest policy check (a
  failing policy deletes the plan, so it can't be applied). It uploads the
  plan and comments the summary on the PR. Skipped for PRs from forks and
  Dependabot, which get no OIDC token or secrets.
- **apply** runs when the plan has changes (see
  [When it applies](#when-it-applies)), after the apply environment's
  reviewers approve. It refuses a stale plan (the PR moved on, or a watched
  path changed on the target branch since), checks the plan file's
  SHA-256, applies exactly that plan, and updates the PR comment.
- **result** is the call's one check (see
  [Branch protection](#branch-protection)).

## Inputs

All paths are relative to the repository root, except `var-files` and
`test-filter`, which are relative to the root module, as in OpenTofu.
Lists take one item per line, or items separated by spaces. Without
`var-files`, the module uses its defaults (and its `terraform.tfvars`).

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
| `azure-client-id`                  | none                 | Identity for the apply and integration test jobs, and plan by default  |
| `azure-tenant-id`                  | none                 | Tenant ID; required with any client ID                                 |
| `azure-subscription-id`            | none                 | Subscription ID                                                        |
| `plan-azure-client-id`             | `azure-client-id`    | Identity for the plan job, e.g. a read-only one                        |
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
| `integration-test-timeout-minutes` | `90`                 | Its timeout (a timeout leaks what the tests created)                   |
| **Plan**                           |                      |                                                                        |
| `pr-comment`                       | `true`               | Comment the plan and apply result on the PR                            |
| `plan-retention-days`              | `7`                  | Plan artifact retention; an approval after that fails                  |
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

| Secret                     | Description                                                        |
| -------------------------- | ------------------------------------------------------------------ |
| `azure-client-secret`      | Secret of `azure-client-id`; without it, OIDC                      |
| `plan-azure-client-secret` | Secret of `plan-azure-client-id`; without it, OIDC                 |
| `modules-token`            | Reads private GitHub repositories used as module or policy sources |
| `infracost-api-key`        | For `cost-estimate`                                                |

| Output        | Description                                                                   |
| ------------- | ----------------------------------------------------------------------------- |
| `changed`     | `true` if this run planned (a watched path changed, or `changed-only` is off) |
| `has-changes` | `true` if the plan has changes                                                |
| `applied`     | `true` if the apply job applied the plan                                      |

<!-- markdownlint-enable MD013 -->

## Change detection

The workflow always runs; the prepare job decides whether it plans. Don't
filter its triggers with `on.pull_request.paths`: a workflow skipped that
way leaves its required checks pending forever.

- **What's watched:** always the module directory (every file in it: `.tf`
  files, child modules, tests, the lock file, `mise.toml`, ...), the var
  files (even outside the module), and the calling workflow file, so
  editing the call runs it. `extra-paths` adds to these, e.g. a module
  directory several root modules share: a directory (`iac/modules`, with
  everything under it) or a glob (`iac/modules/**/*.tf`). It can't remove
  them.
- **The calling workflow** is the run's top-level workflow file. If you call
  `opentofu.yaml` from a reusable workflow of your own, add that file to
  `extra-paths`.
- **When:** on `pull_request` and `push` with `changed-only`, if no watched
  path changed since the base, plan and apply are skipped and the call's
  check passes. Checks still run. `workflow_dispatch`, `schedule`,
  `changed-only: false`, or a diff that can't be computed always plan.
- **Stale plans:** the same watched paths decide whether a plan is stale at
  apply time.

## When it applies

<!-- markdownlint-disable MD013 -->

| `apply` | `apply-from-pr` | Pull request run                                   | Push or dispatch, default branch               | Other branches |
| ------- | --------------- | -------------------------------------------------- | ---------------------------------------------- | -------------- |
| `true`  | `true`          | Plan, then apply after approval, before merge      | Plan; apply after approval if anything changed | Plan only      |
| `true`  | `false`         | Plan only; the comment says it applies after merge | Plan, then apply after approval                | Plan only      |
| `false` | (ignored)       | Plan only                                          | Plan only                                      | Plan only      |

<!-- markdownlint-enable MD013 -->

- With `apply-from-pr: true`, the default branch only ever holds
  configuration that applied: if the call's check is required, a PR with
  changes can't merge until it's applied. The push after merge plans again
  and normally finds nothing to do. PRs from forks and Dependabot are the
  exception: they aren't planned, so the push after merge plans and applies
  them.
- **Rolling back an unmerged PR:** if a PR is applied but not merged, run
  the workflow on the default branch (`workflow_dispatch`) to re-apply
  what's there.
- With `apply-from-pr: false`, merging is when it applies: the push to the
  default branch plans again and waits for approval. If that apply is
  rejected or fails, later pushes don't retry it unless they change a
  watched path too: run the workflow on the default branch
  (`workflow_dispatch`) to plan and apply what's there.
- Scheduled runs on the default branch count as pushes: with changes, they
  wait for approval to apply.
- Use environment deployment branch policies for more control.

## Checks

- **With the call's var files:** TFLint gets them as `--var-file`, Trivy as
  `--tf-vars`, `tofu test` as `-var-file`, so a deployment whose variables
  trip a check is caught in its own call. fmt, validate and terraform-docs
  don't depend on variables.
- **`checks: false`** skips the checks job entirely, without turning each
  check off.
- **`test-filter`** selects test files, as OpenTofu's `-filter` does
  (`tests/unit/*.tftest.hcl`), not test or run block names.
- **`docs`** is on by default: the module needs `terraform-docs` pinned and
  a README it generates (with a `.terraform-docs.yml`, or the markers in
  `README.md`), or turns the check off.
- **Tools** come from the module's own `mise.toml`; every enabled check's
  tool must be pinned there.

## Policy

`policy: true` runs conftest against the plan.

- **Where policies come from:** `policy-path` (local directories) and
  `policy-source` (a go-getter URL, e.g.
  `git::https://github.com/org/policies.git//terraform?ref=v1`) are
  combined: conftest evaluates the local and the pulled policies together.
- **Namespaces:** `policy-namespaces` lists the Rego namespaces to evaluate;
  empty means all of them.
- **deny and warn:** any `deny` (or `violation`) fails the plan and deletes
  it, so it can't be applied. A `warn` doesn't fail by default, but every
  one is listed in the PR comment. `policy-fail-on-warn: true` makes any
  warn fail too; failing only above a severity isn't supported.

## Azure

The workflow sets the azurerm provider's and backend's environment
variables from the Azure inputs and secrets, in the integration test, plan
and apply jobs:

<!-- markdownlint-disable MD013 -->

| Variable                  | Integration test and apply jobs | Plan job                                       |
| ------------------------- | ------------------------------- | ---------------------------------------------- |
| `ARM_CLIENT_ID`           | `azure-client-id`               | `plan-azure-client-id`, else `azure-client-id` |
| `ARM_CLIENT_SECRET`       | `azure-client-secret`           | the plan identity's secret (see below)         |
| `ARM_TENANT_ID`           | `azure-tenant-id`               | `azure-tenant-id`                              |
| `ARM_SUBSCRIPTION_ID`     | `azure-subscription-id`         | `azure-subscription-id`                        |
| `ARM_USE_OIDC`            | `true` without a secret         | `true` without a secret                        |
| `ARM_USE_AZUREAD`         | `azure-use-azuread`             | `azure-use-azuread`                            |
| `ARM_STORAGE_USE_AZUREAD` | `azure-use-azuread`             | `azure-use-azuread`                            |

<!-- markdownlint-enable MD013 -->

- **`azure-client-id` is the apply identity**, the one that can write; the
  integration tests use it too, so it needs whatever they need.
  `plan-azure-client-id` overrides it for the plan job only, e.g. with a
  read-only identity. The plan identity switches as a pair: with
  `plan-azure-client-id`, the plan job uses `plan-azure-client-secret` (or
  OIDC without it), never the apply identity's secret.
- **OIDC or a client secret, per job:** a job with a client secret uses it;
  one without uses OIDC.
- **Entra ID (RBAC) for storage, by default:** the backend reaches the state
  storage account with the identity instead of an access key, and so does
  the provider's storage data plane. Set `azure-use-azuread: false` to turn
  it off.
- **Nothing else Azure is set without `azure-client-id`.**
- **Values come from the repository or organization.** Your calling job has
  no environment, so `${{ vars.X }}` and `${{ secrets.X }}` there resolve
  at repository or organization level. Name per-environment values
  accordingly (`PROD_CLIENT_ID`, `PROD_READ_CLIENT_ID`).

### OIDC setup

Add a federated credential to each identity for each subject its jobs
present:

<!-- markdownlint-disable MD013 -->

| Job               | Subject                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| apply             | `<prefix>:environment:<apply-environment>`                                                                                                              |
| plan              | `<prefix>:environment:<plan-environment>`; without one, `<prefix>:pull_request` (PR plans) and `<prefix>:ref:refs/heads/main` (push and dispatch plans) |
| integration tests | `<prefix>:environment:<integration-test-environment>`; without one, as for plans                                                                        |

<!-- markdownlint-enable MD013 -->

- `<prefix>` is `repo:<owner>/<repo>`, or on newer repositories
  `repo:<owner>@<owner-id>/<repo>@<repo-id>`. Get yours with
  `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`
  (`sub_claim_prefix`). A mismatch fails `tofu init` with AADSTS700213,
  which quotes the subject presented.
- Since each subject is bound to an environment, only the job running there
  can use the identity: the apply identity only after approval.

Only Azure is supported for now. Other providers will get their own
optional inputs (`aws-*`, `google-*`, ...) as they're needed.

## Private modules and policies

`tofu init` downloads modules from their `source`, and conftest pulls
`policy-source`, both with git. Local modules (`./modules/x`) and public
repositories need nothing. For private GitHub repositories:

- **Why a token:** the run's `GITHUB_TOKEN` can only read the repository
  the run belongs to, on GitHub Enterprise too, for private and internal
  repositories alike.
- **What `modules-token` does:** before `tofu init` and `conftest pull`, the
  workflow writes a throwaway git config (in the job's temporary directory)
  that rewrites `https://github.com/`, `ssh://git@github.com/` and
  `git@github.com:` URLs to authenticate with the token (on your Enterprise
  host too). `git::https://github.com/org/modules.git//x?ref=v1` and
  `git@github.com:org/modules.git` sources then work without changing the
  module code.
- **Which token:** one that can read those repositories, e.g. a
  fine-grained personal access token with read-only Contents on them,
  stored as a secret. Without it, the run's `GITHUB_TOKEN` is used.

## Runners

Every job runs on `runs-on`, except those given their own runner:
`checks-runs-on`, `integration-test-runs-on`, `plan-runs-on` and
`apply-runs-on`. prepare and result, which only check inputs and collect
results, always run on `runs-on`. Use the overrides to send only some jobs
to a particular runner, e.g.:

- plan, apply and integration tests to a runner group of GitHub-hosted
  runners in your private network;
- checks to a self-hosted runner or custom image with your tools already
  installed.

Each takes a label, or JSON when it starts with `{` or `[`: an array of
labels (the runner needs all of them), or a runner group, with or without
labels:

```yaml
    with:
      plan-runs-on: '{"group": "private-network"}'
      apply-runs-on: '{"group": "private-network", "labels": ["linux-x64"]}'
      integration-test-runs-on: '["self-hosted", "linux"]'
```

The prepare job checks them up front. A runner group must be available to
the calling repository.

**Tools on a custom image.** Every job still installs mise (`mise-version`)
and runs `mise install` for the module's own `mise.toml`, which skips any
tool version already in mise's data directory: `MISE_DATA_DIR`, else
`$XDG_DATA_HOME/mise`, else `~/.local/share/mise`, for the runner's user.
Install the exact versions your modules pin there (`mise install` in each
module when building the image); a different version is downloaded as
usual, and tools set only in the image's global mise config are ignored.

## Branch protection

Each call ends with a `result` job, which passes only if every job of the
call succeeded or was skipped for a reason (nothing changed, checks off,
plan only, a fork PR). GitHub names its check after your calling job:
`<calling job name> / Result`, where the calling job's name is its `name:`,
else its ID.

**Per file (recommended):** add one job to your workflow file that needs
every call, and require only its check:

```yaml
  result:
    name: identity
    needs: [dev, prod-eastus, prod-westus]
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - name: Check results
        uses: JoshSLawrence/actions/shared/result@v0.3.0
        with:
          needs: ${{ toJSON(needs) }}
```

The required check is `identity`. Adding a deployment means adding it to
`needs:` in the same PR; the ruleset doesn't change.

**Per call:** require each call's check instead (`identity-dev / Result`,
`identity-prod-eastus / Result`, ...). Adding a deployment then means
changing the ruleset too. Calling job names must be unique across your
workflows: `prod` in two files would be two checks both named
`prod / Result`, so give each job a `name:`.

To require a check: Settings → Rules → Rulesets → your default-branch
ruleset → "Require status checks to pass" → add the check by name (it's
listed once it has run on a PR). Also consider "Require branches to be up
to date before merging" with `apply-from-pr`.

## Setup

1. **Pin the module's tools** in its own `mise.toml`, e.g.
   `mise use opentofu@1.12.6 tflint@0.64.0 trivy@0.74.0
   terraform-docs@0.24.0` in the module directory, plus `conftest` for
   `policy` and `infracost` for `cost-estimate`. Commit
   `.terraform.lock.hcl` too.
   - A plain `mise install` in a module also installs what every
     `mise.toml` above it pins, and your global config. CI installs only
     the module's own tools; to do the same locally, run this in the
     module:

     ```bash
     MISE_CEILING_PATHS="$(dirname "$PWD")" MISE_GLOBAL_CONFIG_FILE=/nonexistent/config.toml mise install
     ```

2. **One state per deployment:** each var file sets a variable the backend
   block reads (OpenTofu evaluates variables there), and the workflow passes
   the var files to `tofu init` too:

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

   Leave the variable without a default, so a deployment that forgets it
   fails at `init` instead of using another deployment's state.
3. **Create the environments** each call names, before its first run:
   apply environments with **required reviewers**, plan environments
   without. A run naming one that doesn't exist fails, naming it.
   Required reviewers on a **private** repository need GitHub Enterprise;
   without them, `apply-from-pr: false` makes merging the approval.
4. **Credentials:** the repository variables and secrets your calls pass,
   and federated credentials (see [Azure](#azure)).
5. **Branch protection** (see [Branch protection](#branch-protection)).

Before any job runs, the prepare job checks:

- `working-directory` exists, has `*.tf` files and its own `mise.toml`, and
  every var file exists;
- `apply-environment` is set, and every environment named exists;
- every tool the enabled options need is pinned;
- the Azure inputs are consistent (a client ID needs a tenant ID; a secret
  needs its client ID; `plan-azure-client-id` needs `azure-client-id`);
- `cost-estimate` has its `infracost-api-key`; `policy` has a
  `policy-source` or a `policy-path`, and every `policy-path` directory
  exists (set `policy-path: ""` to use only `policy-source`); test filters
  match files; `extra-paths` stay in the repository; `name` is usable;
- the jobs' own runners (`plan-runs-on`, ...) are a label or valid JSON.

## PR comments

- **One comment per call per PR**, edited in place by every run. Its title
  says which call applies in which environment, e.g.
  OpenTofu: `iac/identity` · `prod-eastus` → `prod`.
  - **Contents:** the plan summary, the cost and policy sections, the
    checks' results, and where the apply stands: awaiting approval,
    applying after merge, blocked by policy, applied (and by whose
    approval), or failed.
  - **History:** earlier versions stay in the comment's edit history (its
    **edited** menu).
  - **Out-of-order runs:** a run for an outdated PR head leaves the comment
    alone.
  - **Size:** plan output is truncated to fit GitHub's limit; the full plan
    is in the run log.
- **Author:** only comments by `github-actions[bot]` are edited.

## Security notes

- **Plans hold state.** A plan file embeds a copy of the state, and
  artifacts of a public repository are readable by anyone. Keep secrets out
  of state (`tofu show` hides values marked sensitive).
- **Least privilege.** The checks never get cloud credentials. Plans and
  applies can use different identities, and an identity bound to the apply
  environment works only after its approval.
- **The calling workflow is code.** It's reviewed in the PR like the `.tf`
  files: it decides which environment, and so which identity and approval
  gate, a call uses. Environment protection rules and federated credentials
  bound to environment names keep a PR from deploying where it shouldn't.
- **Fork and Dependabot PRs** are checked, never planned: they get no
  secrets or OIDC token.

## Moving from v0.1.0

<!-- markdownlint-disable MD013 -->

| v0.1.0                                                           | v0.2.0                                                             |
| ---------------------------------------------------------------- | ------------------------------------------------------------------ |
| `opentofu.yaml` discovered every root module under `search-root` | `opentofu.yaml` is one call per deployment; write one job for each |
| `opentofu-config.yaml` with a `deployments` glob                 | One call per var file (`var-files`)                                |
| `opentofu-deploy.yaml`, the composite actions                    | Internals of `opentofu.yaml`                                       |
| `backend-config`, `.tfbackend` files, `{deployment}`             | A backend variable set in each var file                            |
| `apply-environment` per deployment pattern                       | `apply-environment` per call                                       |
| `azure-client-id` (plan) and `apply-azure-client-id` (apply)     | `azure-client-id` (apply) and `plan-azure-client-id` (plan)        |
| `azure-login`, the `env-vars` and `apply-env-vars` secrets       | Not supported; Azure through its inputs, other providers to come   |
| `stack-name`                                                     | `name`                                                             |
| `opentofu-drift.yaml`                                            | Removed for now; it returns in the per-call shape                  |

<!-- markdownlint-enable MD013 -->

## Internals

`opentofu.yaml` uses the composite actions in this directory (`prepare`,
`checks`, `azure`, `plan`, `apply`) and the shared library's `shared/setup`,
`shared/pr-comment` and `shared/result`. They're not meant to be called on
their own, and their interfaces may change in any release.

The logic is in [`scripts/`](scripts/), on top of the shared library
([`../shared/scripts/`](../shared/scripts/)). Each script documents its
environment variables at the top and runs locally too, e.g.:

```bash
WORKING_DIR=iac/identity VAR_FILES=deployments/prod.tfvars APPLY_ENVIRONMENT=prod opentofu/scripts/validate-inputs.sh
```

[`tests/opentofu/scripts-test.sh`](../tests/opentofu/scripts-test.sh)
tests change detection, input validation, the Azure mapping and names; CI
runs the workflow end to end against
[`tests/fixtures/opentofu/`](../tests/fixtures/opentofu/).
