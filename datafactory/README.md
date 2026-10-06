# Data Factory

Build, plan and deploy Azure Data Factory from its Git folder, with the plan
and the deployment result posted on the PR. There's no **Publish** button
and no `adf_publish` branch: every PR validates the folder and exports its
ARM template, so a feature branch can be deployed to an environment from its
PR, and merged once it works.

For Synapse workspaces, see [`synapse/`](../synapse/README.md); it works the
same way.

## Contents

- [Why](#why)
- [Quick start](#quick-start)
- [Concepts](#concepts)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reference](#reference)
- [Composite actions](#composite-actions)
- [Limitations](#limitations)
- [Coming from adf\_publish](#coming-from-adf_publish)

## Why

With Git integration, Data Factory only produces ARM templates when someone
selects **Publish** in the UI, from the collaboration branch, into the
`adf_publish` branch. So a change can't be deployed until it's merged, a
release depends on a person remembering to publish, and the publish branch
drifts from `main`.

Microsoft's automated publish replaces the button: the same "Validate all"
and "Export ARM template" logic, as a JavaScript bundle that runs offline.
The npm package `@microsoft/azure-data-factory-utilities` downloads it and
runs it with node; these actions do exactly that, then deploy the result.
See [automated publishing][automated-publishing].

[automated-publishing]: https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-improvements

## Quick start

```yaml
name: Data Factory

on:
  pull_request:
    branches: [main]
    paths: [adf/**]
  push:
    branches: [main]
    paths: [adf/**]
  workflow_dispatch:

permissions: {}

jobs:
  datafactory:
    uses: JoshSLawrence/actions/.github/workflows/datafactory.yaml@v1
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: adf
      deployments: deployments/*.json
      resource-group: rg-{deployment}
      apply-environment: "{deployment}"
```

The caller must grant the four permissions shown: a reusable workflow's jobs
can only narrow them. A complete caller, with the setup it needs, is in
[`examples/datafactory.yaml`](../examples/datafactory.yaml).

## Concepts

- **Factory folder:** the factory's Git root folder (the *root folder* of
  its Git configuration: `pipeline/`, `dataset/`, `linkedService/`, ...). It
  pins its own tools in a `mise.toml`: `node` to build; `azure-cli` (and
  `uv`, which mise installs it with) and `powershell` to deploy. Nothing
  from the repository root is used.
- **Deployment:** the template deployed with one ARM parameters file, e.g.
  `deployments/dev.json` and `deployments/prod.json`, each to its own
  factory. It's named after its file (`prod.json` or `prod.parameters.json`
  → `prod`).
  - Each file must set `factoryName`: the exported value is the development
    factory's, and deploying with it would overwrite that factory.
  - `resource-group` and `apply-environment` take `{deployment}`, e.g.
    `rg-{deployment}`.
  - Without `deployments`, the template is deployed once, with
    `parameter-files` and `parameters` only.
- **Parameters** are layered, later ones winning:
  1. the exported `ARMTemplateParametersForFactory.json` (development
     values);
  2. `parameter-files`, then the deployment's own file;
  3. `parameters`, one `name=value` per line (`{deployment}` replaced);
  4. the `parameter-secrets` secret, at plan (what-if) and deploy time only.
     It's never written to an artifact.

  Every name must be a parameter of the template, so a typo fails the plan
  instead of being ignored. To make a property a parameter, add an
  `arm-template-parameters-definition.json` to the folder
  ([custom parameters][custom-parameters]).

[custom-parameters]: https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-resource-manager-custom-parameters

## How it works

```text
datafactory.yaml         build ───────┬─> deploy (per deployment) ──> result
                         deployments ─┘      │
                                             │
datafactory-deploy.yaml                   plan ──> apply (after approval)
```

- **build** validates the folder and exports its ARM template, once, and
  uploads it as an artifact. It needs no Azure credentials, so PRs from forks
  run it too. Only `.json` files are passed to the exporter: a stray file in
  a resource folder (a `.keep`, a README) otherwise makes it find nothing.
- **plan** (per deployment) renders the parameters and, with `what-if`,
  previews the deployment:
  - `az deployment group what-if`: what would be created or modified, and
    which properties change;
  - the resources the post-deployment script would delete, because they're
    no longer in the folder.

  It uploads the plan (template, parameters and target, never secrets) and
  comments the summary on the PR. A what-if with nothing to change skips the
  apply.
- **apply** (per deployment) waits for the `apply-environment`'s reviewers,
  then:
  1. refuses a stale plan: the PR moved on, or the folder or its parameter
     files changed on the target branch since;
  2. checks the plan's SHA-256, and deploys to the factory and resource group
     the plan names;
  3. runs the export's `PrePostDeploymentScript.ps1` to stop the triggers the
     deployment changes;
  4. deploys the template (incremental);
  5. runs the script again to delete what's no longer in the folder and start
     the triggers the template marks `Started`;
  6. updates the PR comment.
- **result** rolls everything up into one check to require in branch
  protection: `<caller job> / Result`.

By default (`apply-from-pr: true`) each environment is deployed from the PR,
after approval, before merge; `apply-from-pr: false` deploys after merge
instead. Deployments are independent: each waits for its own environment's
approval.

## Setup

1. **Pin the folder's tools**, e.g. in the factory folder:
   `mise use node@22 azure-cli uv powershell`. The exporter supports node 20
   and 22.
2. **Keep Git integration on the development factory only** (Microsoft's
   recommendation). Every other factory is deployed by this workflow, and
   the development factory can be a deployment too: deploying it replaces
   **Publish**.
3. **Apply environments** with required reviewers, one per deployment with
   `apply-environment: "{deployment}"`. The apply warns when its environment
   has no required reviewers.
4. **Azure OIDC.** No secrets are needed: set the variables
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`
   (environment-scoped ones win in that environment's jobs).
   - Add a federated credential for each subject the jobs present:
     `<prefix>:environment:<name>`; for jobs without an environment,
     `<prefix>:pull_request` (PR plans) and `<prefix>:ref:refs/heads/main`
     (push and dispatch runs).
   - `<prefix>` is `repo:<owner>/<repo>`, or on newer repositories
     `repo:<owner>@<owner-id>/<repo>@<repo-id>`. Get yours with
     `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`
     (`sub_claim_prefix`). A mismatch fails sign-in with AADSTS700213,
     which quotes the subject presented.
   - The apply identity needs **Data Factory Contributor** on the factory's
     resource group: it deploys, stops and starts triggers, and deletes
     resources.
   - With `what-if`, the plan identity needs to run what-if on the resource
     group (Data Factory Contributor includes it), or set `what-if: false`.
   - **Dependabot** runs get no OIDC token (and no Actions secrets), so a
     Dependabot PR fails its what-if and its apply. Turn both off for it on
     the calling job, so it builds and plans offline and its Result check
     still reports (skipping the job would leave that required check
     pending):

     ```yaml
     what-if: ${{ github.actor != 'dependabot[bot]' }}
     apply: ${{ github.actor != 'dependabot[bot]' }}
     ```

5. **Secure parameters:** prefer Key Vault linked services, so a deployment
   only needs the vault's URL. Parameter files may also use Key Vault
   `reference`s. Anything else goes in the `parameter-secrets` secret, one
   `name=value` per line.
6. **Branch protection:** require `<caller job> / Result`.

## Reference

Paths are relative to the repository root, except `deployments` and
`parameter-files`, which are relative to the factory folder. List inputs
accept spaces or newlines. `{deployment}` is replaced where noted.

<!-- markdownlint-disable MD013 -->

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | The factory's Git root folder |
| `stack-name` | working directory | Display name in PR comments and summaries |
| `factory-name` | `factory/*.json`'s | Development factory's name, for the template's defaults |
| `deployments` | none | Parameters files, one deployment each; globs match within the folder |
| `parameter-files` | none | Parameters files every deployment uses, before its own |
| `parameters` | none | `name=value` lines every deployment uses; `{deployment}` |
| `resource-group` | required | Resource group to deploy to; `{deployment}` |
| `plan-environment` | none | Environment for plan jobs; `{deployment}` |
| `plan-retention-days` | `7` | Plan (and template) artifact retention |
| `pr-comment` | `true` | Comment the plan and apply result on the PR |
| `what-if` | `true` | Preview with what-if and list deletions (needs Azure access) |
| `apply` | `true` | Include the apply job (`false` = plan only) |
| `apply-from-pr` | `true` | Deploy from the PR before merge; `false` = on the default branch only |
| `apply-environment` | none | Environment with required reviewers; `{deployment}` |
| `preflight-paths` | working directory | What plans depend on; parameter files are added |
| `pre-post-script` | `true` | Run the export's pre/post-deployment script |
| `runs-on` | `ubuntu-latest` | Runner of every job without its own: a label, or JSON (below) |
| `plan-runs-on` | `runs-on` | Runner of each deployment's plan job |
| `apply-runs-on` | `runs-on` | Runner of each deployment's apply job |
| `timeout-minutes` | `30` | Timeout for each job |
| `max-parallel` | `4` | Most deployments at once |
| `mise-version` | `2026.9.12` | mise version |
| `azure-client-id` | `vars.AZURE_CLIENT_ID` | Azure identity for OIDC |
| `apply-azure-client-id` | `azure-client-id` | Separate (write) identity for apply |
| `azure-tenant-id` | `vars.AZURE_TENANT_ID` | Azure tenant |
| `azure-subscription-id` | `vars.AZURE_SUBSCRIPTION_ID` | Azure subscription |

| Secret | Description |
| --- | --- |
| `parameter-secrets` | `name=value` lines for secure parameters, never saved in artifacts |

| Workflow | Output | Description |
| --- | --- | --- |
| `datafactory.yaml` | `deployments` | JSON array of the deployment names |
| `datafactory-deploy.yaml` | `has-changes`, `applied` | Whether the plan had changes / was applied |

<!-- markdownlint-enable MD013 -->

The plan and apply jobs, the ones that reach Azure, run on `runs-on`
unless given their own runner; build, deployments and result always run
on `runs-on`. Each runner input takes a label, or JSON when it starts with
`{` or `[`: an array of labels (the runner needs all of them), or a runner
group, with or without labels:

```yaml
    with:
      plan-runs-on: '{"group": "private-network"}'
      apply-runs-on: '{"group": "private-network", "labels": ["linux-x64"]}'
```

A runner group must be available to the calling repository.

`datafactory-deploy.yaml` is the building block: plan and apply of one
deployment, taking a `template-artifact` (datafactory/build's output) and
the deployment's resolved `parameter-files`, `parameters` and
`resource-group`.

## Composite actions

The workflows are made of these; use them directly for a different job
layout. Each action's inputs are documented in its `action.yaml`. Run
[`shared/setup`](../shared/setup/action.yaml) first in every job that
runs a tool (it installs the folder's mise tools).

<!-- markdownlint-disable MD013 -->

| Action | Does |
| --- | --- |
| [`datafactory/build`](build/action.yaml) | Validate the folder and export its ARM template, offline |
| [`datafactory/deployments`](deployments/action.yaml) | The folder's deployments as a matrix |
| [`datafactory/plan`](plan/action.yaml) | Render parameters, optional what-if and deletions preview, summary |
| [`datafactory/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, pre/post script around the ARM deployment |
| [`shared/pr-comment`](../shared/pr-comment/action.yaml) | Create or update the PR comment for one deployment |
| [`shared/result`](../shared/result/action.yaml) | Roll a workflow's jobs up into one check |

<!-- markdownlint-enable MD013 -->

The logic is in [`scripts/`](scripts/), [`../arm/scripts/`](../arm/scripts/)
(what Data Factory and Synapse share) and the shared library,
[`../shared/scripts/`](../shared/scripts/). Every script runs locally too,
e.g.:

```bash
WORKING_DIR=adf datafactory/scripts/build.sh
WORKING_DIR=adf TEMPLATE_DIR=/tmp/datafactory-template PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev datafactory/scripts/plan.sh
```

## Limitations

- **Template size:** ARM rejects templates over 4 MB. Larger factories need
  linked templates, hosted in a storage account, which these actions don't
  deploy; the build fails with that message.
- **The export bundle isn't versioned:** every run downloads Microsoft's
  latest, as the npm package does. Its SHA-256 is in the build summary.
- **Global parameters** are deployed only if the factory includes them in
  the ARM template (Manage → ARM template).
- **The factory itself** (identity, networking, Git configuration) isn't in
  the template: manage it with infrastructure as code, such as OpenTofu.
- **A failed deployment leaves stopped triggers stopped**, as Microsoft's
  script does; a successful re-run starts them again.

## Coming from adf\_publish

<!-- markdownlint-disable MD013 -->

| Publish-branch workflow | Here |
| --- | --- |
| **Publish** in the UI, into `adf_publish` | The build job, on every PR and push |
| Checking out `adf_publish` to deploy | The template artifact from the build |
| `azure/arm-deploy` with parameters inline, per environment | `deployments/<env>.json`, plus `parameters` |
| Resource group per environment call | `resource-group: rg-{deployment}` |
| Stopping and starting triggers by hand | `pre-post-script` (Microsoft's script) |
| One workflow per environment, chained with `needs` | One call; each deployment has its own environment and approval |

<!-- markdownlint-enable MD013 -->
