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
- [What's deployed: logic and infrastructure](#whats-deployed-logic-and-infrastructure)
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

## What's deployed: logic and infrastructure

The factory's Git folder holds its **logic**. Its **network and compute**
(the factory itself, the managed virtual network, managed private endpoints,
integration runtimes) belong to infrastructure as code, such as OpenTofu.
This workflow deploys the first and leaves the second alone, so a deployment
can't replace or delete what infrastructure as code created.

<!-- markdownlint-disable MD013 -->

| Kind | Deployed | Deleted when it isn't in the folder |
| --- | --- | --- |
| Pipelines, datasets, data flows, linked services, triggers | yes | yes |
| Credentials | yes | no (Microsoft's script has no section for them) |
| Integration runtimes | only with `deploy-integration-runtimes` | only with `deploy-integration-runtimes` |
| Managed private endpoints | only with `deploy-managed-private-endpoints` | never |
| Managed virtual network | never | never |
| The factory itself (identity, network access, Git settings) | never | never |
| Global parameters | only if the export includes them (see [Limitations](#limitations)) | never |

<!-- markdownlint-enable MD013 -->

- **Reference files are fine.** Studio's Git mode only shows the network
  and compute that are in the folder, so the folder may hold copies of the
  factory's integration runtimes, managed private endpoints and virtual
  network. The plan leaves them out of the deployed template and lists them
  under "Left to infrastructure as code". With `what-if` it also lists the
  factory's live integration runtimes and endpoints (for this check only),
  and:
  - a file whose type and name (without regard to case) exist live is a
    **reference copy**: listed as such, no warning;
  - a file with no live counterpart, when other files of its kind do have
    one, is new: someone added it in Studio and infrastructure as code
    doesn't have it. It warns: define it in your infrastructure as code, or
    remove the file;
  - when none of a kind's files match anything live (the folder holds
    another environment's copies: stg and prod see dev's endpoint names),
    the plan shows one note for the kind instead of a warning per file;
  - with `what-if` off it can't tell, and every such file warns.

  The service defaults (`AutoResolveIntegrationRuntime`, the `default`
  virtual network) are never warned about. Nothing in the folder is deleted
  from the factory.
- **Opting in.** `deploy-integration-runtimes: true` and
  `deploy-managed-private-endpoints: true` deploy the folder's, and then
  Data Factory's script also deletes runtimes that aren't in the folder.
  Before v0.6.0 this was the behavior; a factory whose runtimes come from
  infrastructure as code must not use it.

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

  Before either, it takes what infrastructure as code owns out of the
  template (see [above](#whats-deployed-logic-and-infrastructure)), so the
  plan, the what-if and the apply all use the same template. With `what-if`
  it also records the factory's current state (a fingerprint of its
  pipelines, datasets, ... and their etags) for the apply to check.

  It uploads the plan (template, parameters, target and that fingerprint,
  never secrets) and comments the summary on the PR. A what-if with nothing
  to change skips the apply.
- **apply** (per deployment) waits for the `apply-environment`'s reviewers,
  then:
  1. refuses a stale plan: the PR moved on, or the folder or its parameter
     files changed on the target branch since;
  2. checks the plan's SHA-256, and deploys to the factory and resource group
     the plan names;
  3. lists the factory again and refuses if it differs from the plan's
     fingerprint: something else changed it since (another PR's apply, or a
     change in the portal), and deploying this plan would undo or delete it.
     Re-run all jobs of the workflow to plan again (re-running only the
     failed job reuses the old plan, which is refused);
  4. runs the export's `PrePostDeploymentScript.ps1` to stop the triggers the
     deployment changes;
  5. deploys the template (incremental);
  6. runs the script again to delete what's no longer in the folder and start
     the triggers the template marks `Started`. The script deletes every
     integration runtime that isn't in the template, so when integration
     runtimes are left to infrastructure as code the apply lists the live
     ones and hands the script a copy of the template that names them, and
     it keeps them;
  7. updates the PR comment.
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
   `apply-environment: "{deployment}"`. It's required while `apply` is true,
   because it's the approval gate; the apply also warns when its environment
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

5. **Infrastructure as code** creates the factory, its managed virtual
   network, managed private endpoints and integration runtimes (including
   `AutoResolveIntegrationRuntime`) before the first deployment. Linked
   services reach storage and Key Vault through the endpoints it creates.
   Apply an infrastructure change that a pipeline needs first.
6. **Secure parameters:** prefer Key Vault linked services, so a deployment
   only needs the vault's URL. Parameter files may also use Key Vault
   `reference`s. Anything else goes in the `parameter-secrets` secret, one
   `name=value` per line.
7. **Branch protection:** require `<caller job> / Result`.

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
| `apply-environment` | none | Environment with required reviewers; `{deployment}`. Required with `apply` |
| `preflight-paths` | working directory | What plans depend on; other deployments' parameter files are left out |
| `pre-post-script` | `true` | Run the export's pre/post-deployment script |
| `deploy-managed-private-endpoints` | `false` | Deploy the folder's managed private endpoints; `false` leaves them to infrastructure as code. Data Factory never deletes them |
| `deploy-integration-runtimes` | `false` | Deploy the folder's integration runtimes; `false` leaves them to infrastructure as code. `true` also lets the post-deployment script delete runtimes not in the folder |
| `runs-on` | `ubuntu-latest` | Runner of every job without its own: a label, or JSON (below) |
| `build-runs-on` | `runs-on` | Runner of the build job |
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

The build, plan and apply jobs run on `runs-on` unless given their own
runner: e.g. plan and apply on a runner group that can reach Azure, build
on an image with the folder's tools installed. deployments and result
always run on `runs-on`. Each runner input takes a label, or JSON when it
starts with `{` or `[`: an array of labels (the runner needs all of them),
or a runner group, with or without labels:

```yaml
    with:
      build-runs-on: '["self-hosted", "linux"]'
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
| [`datafactory/plan`](plan/action.yaml) | Leave out what infrastructure as code owns, render parameters, optional what-if, deletions preview and live fingerprint, summary |
| [`datafactory/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, live check, pre/post script around the ARM deployment |
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
- **Global parameters are deployed only if the export puts them in the
  template.** With `"includeGlobalParamsTemplate": true` in the folder's
  `publish_config.json` (Manage → ARM template → Include global parameters
  in ARM template), the export adds a
  `Microsoft.DataFactory/factories/globalparameters` resource, with one
  parameter per global parameter (`default_properties_<name>_value`), and it
  is deployed like the rest: the factory's global parameters become exactly
  the folder's. Without the setting the export only writes
  `<factory>_GlobalParameters.json` and `GlobalParametersUpdateScript.ps1`
  next to the template, and nothing runs the script.
- **The factory itself** (identity, networking, Git configuration), its
  managed virtual network, endpoints and integration runtimes belong to
  infrastructure as code (see
  [What's deployed](#whats-deployed-logic-and-infrastructure)).
  With `deploy-managed-private-endpoints: true`, endpoints that aren't in the
  folder are never deleted: Microsoft's script has no section for them.
- **A plan made before another PR applied is refused.** The apply's live
  check compares etags, so a change made in the portal (or a trigger
  started there) also makes the next apply ask for a new plan.
- **A failed deployment leaves stopped triggers stopped**, as Microsoft's
  script does; a successful new apply starts them again. Re-run all jobs of
  the workflow, not just the failed one: the factory has changed since the
  plan, so the live check refuses that plan.
- **The apply's inputs must be the plan's.** An apply given a different
  `pre-post-script`, `deploy-integration-runtimes` or
  `deploy-managed-private-endpoints` is refused, with the reason in the PR
  comment, so it can't delete what the plan never previewed.
- **Endpoints have no etag.** Managed private endpoint listings carry none,
  so with `deploy-managed-private-endpoints: true` the fingerprint covers
  their names only: a change to an endpoint that keeps its name goes
  unnoticed.

## Coming from adf\_publish

<!-- markdownlint-disable MD013 -->

| Publish-branch workflow | Here |
| --- | --- |
| **Publish** in the UI, into `adf_publish` | The build job, on every PR and push |
| Checking out `adf_publish` to deploy | The template artifact from the build |
| `azure/arm-deploy` with parameters inline, per environment | `deployments/<env>.json`, plus `parameters` |
| Resource group per environment call | `resource-group: rg-{deployment}` |
| Stopping and starting triggers by hand | `pre-post-script` (Microsoft's script) |
| Integration runtimes and private endpoints in the publish branch | Infrastructure as code; `deploy-integration-runtimes` and `deploy-managed-private-endpoints` to deploy the folder's |
| One workflow per environment, chained with `needs` | One call; each deployment has its own environment and approval |

<!-- markdownlint-enable MD013 -->
