# Synapse

Build, plan and deploy an Azure Synapse workspace's artifacts (notebooks,
pipelines, SQL scripts, linked services, ...) from its Git folder, with the
plan and the deployment result posted on the PR. There's no **Publish**
button and no `workspace_publish` branch: every PR validates the folder and
exports its workspace template, so a feature branch can be deployed to an
environment from its PR, and merged once it works.

It works the same way as [`datafactory/`](../datafactory/README.md); this
page covers what's different.

## Contents

- [Quick start](#quick-start)
- [How it's different from Data Factory](#how-its-different-from-data-factory)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reference](#reference)
- [Composite actions](#composite-actions)
- [Coming from workspace\_publish](#coming-from-workspace_publish)

## Quick start

```yaml
name: Synapse

on:
  pull_request:
    branches: [main]
    paths: [synapse/**]
  push:
    branches: [main]
    paths: [synapse/**]
  workflow_dispatch:

permissions: {}

jobs:
  synapse:
    uses: JoshSLawrence/actions/.github/workflows/synapse.yaml@v1
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: synapse
      deployments: deployments/*.json
      resource-group: rg-{deployment}
      apply-environment: "{deployment}"
      # A runner that can reach the workspace (see Setup)
      runs-on: synapse-vnet
```

A complete caller is in [`examples/synapse.yaml`](../examples/synapse.yaml).

## How it's different from Data Factory

- **Artifacts aren't ARM resources.** They're published through the
  workspace's development endpoint (`https://<workspace>.dev.azuresynapse.net`)
  by the Synapse workspace deployer, not by an ARM deployment. So:
  - a workspace without public network access needs `runs-on` to be a
    runner in its network, for the apply (and for `what-if` plans);
  - there's no what-if: every deployment publishes every artifact again.
    `what-if` instead lists which artifacts are new, and which the
    deployment deletes;
  - Key Vault `reference`s in parameter files don't work (they're an ARM
    feature): use `parameter-secrets`, or a Key Vault linked service.
- **The deployer is a fork.** Upstream
  [`Azure/Synapse-workspace-deployment`][upstream] only signs in with a
  client secret or an Azure VM's managed identity. `synapse/apply` uses
  [a fork][fork] that adds GitHub OIDC to upstream's V1.9.2.
- **Triggers** are stopped before the deployment (the deployer can't update
  or delete a started trigger) and started after: those the template marks
  `Started`, and those that were running and the template doesn't mark
  `Stopped`. After a failed deployment, only the ones that were running are
  started again.
- **Deletions:** with `delete-artifacts` (the default), artifacts in the
  workspace that aren't in the folder are deleted, so the workspace mirrors
  the folder. Integration runtimes and the workspace's own defaults
  (`<workspace>-WorkspaceDefaultStorage`, ...) are never deleted.
- **Not deployed:** Spark and SQL pools and the managed virtual network are
  infrastructure; manage them with OpenTofu. Name pools the same in every
  environment, or parameterize the references. Managed private endpoints are
  deployed only with `deploy-managed-private-endpoints`.
- **Each deployment sets `workspaceName`** instead of `factoryName`.

[upstream]: https://github.com/Azure/Synapse-workspace-deployment
[fork]: https://github.com/JoshSLawrence/Synapse-workspace-deployment/releases/tag/v1.9.2-oidc.1

## How it works

```text
synapse.yaml         build ───────┬─> deploy (per deployment) ──> result
                     deployments ─┘      │
                                         │
synapse-deploy.yaml                   plan ──> apply (after approval)
```

- **build** validates the folder and exports `TemplateForWorkspace.json`,
  once, offline, with Microsoft's export bundle (the one the deployer's
  `validate` operation downloads). Only `.json` files are passed to it.
- **plan** (per deployment) renders the parameters (layered as for
  [Data Factory](../datafactory/README.md#concepts)), optionally compares the
  template with the live workspace, uploads the plan (never secrets) and
  comments the summary on the PR.
- **apply** (per deployment) waits for approval, refuses a stale plan,
  checks the plan's SHA-256, then stops triggers, runs the deployer and
  starts triggers.
- **result** is the single check to require: `<caller job> / Result`.

## Setup

1. **Pin the folder's tools**, e.g. in the workspace folder:
   `mise use node@22 azure-cli uv`.
2. **Keep Git integration on the development workspace only.** The others
   are deployed by this workflow; the development workspace can be a
   deployment too.
3. **A runner that can reach the workspace**, unless it allows public
   network access: a self-hosted runner in its network, or a GitHub-hosted
   runner in an Azure private network.
4. **Apply environments** with required reviewers, e.g.
   `apply-environment: "{deployment}"`.
5. **Azure OIDC.** No secrets are needed: set the variables
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
   - Synapse roles are separate from Azure's:
   - the apply identity needs **Synapse Artifact Publisher** in the
     workspace (**Synapse Administrator** with
     `deploy-managed-private-endpoints`), and Azure **Reader** on the
     workspace; deploying integration runtimes also needs
     `Microsoft.Synapse/workspaces/integrationruntimes/write`;
   - with `what-if`, the plan identity needs **Synapse Artifact User**.
6. **Branch protection:** require `<caller job> / Result`.

## Reference

The inputs are those of [Data Factory](../datafactory/README.md#reference),
with these differences:

<!-- markdownlint-disable MD013 -->

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | The Synapse workspace's Git root folder |
| `workspace-name` | from `*-WorkspaceDefaultStorage` | Development workspace's name, for the template's defaults (instead of `factory-name`) |
| `what-if` | `true` | List new artifacts and deletions (needs network access and Synapse Artifact User) |
| `delete-artifacts` | `true` | Delete artifacts that aren't in the template |
| `deploy-managed-private-endpoints` | `false` | Also deploy managed private endpoints |
| `manage-triggers` | `true` | Stop triggers before, start them after |

<!-- markdownlint-enable MD013 -->

`pre-post-script` doesn't apply. The workflows are `synapse.yaml` and the
building block `synapse-deploy.yaml`, with the same outputs as their Data
Factory counterparts.

## Composite actions

<!-- markdownlint-disable MD013 -->

| Action | Does |
| --- | --- |
| [`synapse/build`](build/action.yaml) | Validate the folder and export its workspace template, offline |
| [`synapse/deployments`](deployments/action.yaml) | The folder's deployments as a matrix |
| [`synapse/plan`](plan/action.yaml) | Render parameters, optional comparison with the live workspace, summary |
| [`synapse/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, triggers around the deployer |

<!-- markdownlint-enable MD013 -->

Run [`shared/setup`](../shared/setup/action.yaml) first in every job that
runs a tool; [`shared/pr-comment`](../shared/pr-comment/action.yaml) and
[`shared/result`](../shared/result/action.yaml) work here too. The scripts
run locally, e.g.:

```bash
WORKING_DIR=synapse synapse/scripts/build.sh
WORKING_DIR=synapse TEMPLATE_DIR=/tmp/synapse-template PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev synapse/scripts/plan.sh
```

## Coming from workspace\_publish

<!-- markdownlint-disable MD013 -->

| Publish-branch workflow | Here |
| --- | --- |
| **Publish** in Synapse Studio, into `workspace_publish` | The build job, on every PR and push |
| `params-<env>.json` kept in the publish branch | `deployments/<env>.json` next to the artifacts |
| `TargetWorkspaceName` per environment call | `workspaceName` in each deployment's file |
| `DeleteArtifactsNotInTemplate`, `deployManagedPrivateEndpoint` | `delete-artifacts`, `deploy-managed-private-endpoints` |
| Stopping and starting triggers by hand | `manage-triggers` |
| A publish branch per workspace (e.g. a QA one) | Another folder, another call |

<!-- markdownlint-enable MD013 -->
