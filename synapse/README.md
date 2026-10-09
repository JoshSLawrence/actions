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
- [What's deployed: logic and infrastructure](#whats-deployed-logic-and-infrastructure)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reference](#reference)
- [Composite actions](#composite-actions)
- [Limitations](#limitations)
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
      plan-runs-on: synapse-vnet
      apply-runs-on: synapse-vnet
```

A complete caller is in [`examples/synapse.yaml`](../examples/synapse.yaml).

## How it's different from Data Factory

- **Artifacts aren't ARM resources.** They're published through the
  workspace's development endpoint (`https://<workspace>.dev.azuresynapse.net`)
  by the Synapse workspace deployer, not by an ARM deployment. So:
  - a workspace without public network access needs `apply-runs-on` (and,
    for `what-if` plans, `plan-runs-on`) to be a runner in its network, or
    `runs-on` for every job;
  - there's no what-if: every deployment publishes every artifact again.
    `what-if` instead lists which artifacts are new, which the deployment
    deletes, and checks that the Spark and SQL pools the artifacts use exist;
  - Key Vault `reference`s in parameter files don't work (they're an ARM
    feature): use `parameter-secrets`, or a Key Vault linked service.
- **The deployer is a fork.** Upstream
  [`Azure/Synapse-workspace-deployment`][upstream] only signs in with a
  client secret or an Azure VM's managed identity. `synapse/apply` uses
  [a fork][fork] that adds GitHub OIDC to upstream's V1.9.2, and never
  deletes a managed private endpoint unless it deploys them (upstream deletes
  those that aren't in the template whatever `deployManagedPrivateEndpoint`
  says).
- **Triggers** are stopped before the deployment (the deployer can't update
  or delete a started trigger) and started after: those the template marks
  `Started`, and those that were running and the template doesn't mark
  `Stopped`. After a failed deployment, only the ones that were running are
  started again.
- **Deletions:** with `delete-artifacts` (the default), logic in the
  workspace that isn't in the folder is deleted, so the workspace mirrors
  the folder. Integration runtimes and the workspace's own defaults
  (`<workspace>-WorkspaceDefaultStorage`, ...) are never deleted, and
  managed private endpoints are never deleted unless they're deployed
  (`deploy-managed-private-endpoints`).
- **Each deployment sets `workspaceName`** instead of `factoryName`.

[upstream]: https://github.com/Azure/Synapse-workspace-deployment
[fork]: https://github.com/JoshSLawrence/Synapse-workspace-deployment/releases/tag/v1.9.2-oidc.2

## What's deployed: logic and infrastructure

The workspace's Git folder holds its **logic**. Its **network and compute**
(the workspace itself, the managed virtual network, managed private
endpoints, integration runtimes, Spark and SQL pools) belong to
infrastructure as code, such as OpenTofu. This workflow deploys the first
and leaves the second alone, so a deployment can't replace or delete what
infrastructure as code created.

<!-- markdownlint-disable MD013 -->

| Kind | Deployed | Deleted when it isn't in the folder |
| --- | --- | --- |
| Pipelines, datasets, data flows, linked services, triggers, notebooks, SQL and KQL scripts, Spark job definitions, Spark configurations, credentials, lake databases | yes | with `delete-artifacts` (the workspace's defaults are skipped) |
| Integration runtimes | only with `deploy-integration-runtimes` | never |
| Managed private endpoints | only with `deploy-managed-private-endpoints` | only with `deploy-managed-private-endpoints` (not `synapse-ws-*`) |
| Managed virtual network | never | never |
| Spark and SQL pools | never | never |

<!-- markdownlint-enable MD013 -->

- **Reference files are fine.** Studio may write an integration runtime,
  endpoint or virtual network file into the folder, and that does no harm:
  the plan leaves it out of the deployed template, and lists it under "Left
  to infrastructure as code". A file that isn't a service default (not
  `AutoResolveIntegrationRuntime`, the `default` virtual network or a
  `synapse-ws-*` endpoint) also gets a warning, telling you to define it in
  infrastructure as code or remove the file.
- **Pools are infrastructure.** Create each pool with infrastructure as
  code, with the same name in every workspace: a notebook attached to a pool
  its target workspace doesn't have fails half-way through the deployment.
  With `what-if`, the plan checks every pool a notebook, a Spark job
  definition or the export names (the export generates an empty stub for
  each pool a pipeline or dataset uses), and fails naming the missing one.
  A notebook's `a365ComputeOptions` metadata holds the development pool's ID
  and is only Studio's display: runs use the pool's name.
- **Opting in.** `deploy-managed-private-endpoints: true` deploys the
  folder's endpoints and lets the deployer delete those that aren't in it
  (the apply identity then needs Synapse Administrator).
  `deploy-integration-runtimes: true` deploys the folder's runtimes.

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
- **plan** (per deployment) takes what infrastructure as code owns out of the
  template, renders the parameters (layered as for
  [Data Factory](../datafactory/README.md#concepts)), optionally compares the
  template with the live workspace and checks its pools exist, records a
  fingerprint of the workspace's current artifacts and their etags, uploads
  the plan (never secrets) and comments the summary on the PR.
- **apply** (per deployment) waits for approval, refuses a stale plan,
  checks the plan's SHA-256, lists the workspace again and refuses if it
  differs from the plan's fingerprint (something else changed it since:
  re-run the workflow to plan again), then stops triggers, runs the deployer
  and starts triggers.
- **result** is the single check to require: `<caller job> / Result`.

## Setup

1. **Pin the folder's tools**, e.g. in the workspace folder:
   `mise use node@22 azure-cli uv`.
2. **Keep Git integration on the development workspace only.** The others
   are deployed by this workflow; the development workspace can be a
   deployment too. Don't use **Publish** in Studio: it would publish the
   collaboration branch outside the approval.
3. **A runner that can reach the workspace**, unless it allows public
   network access: a self-hosted runner in its network, or a GitHub-hosted
   runner in an Azure private network (a runner group, e.g.
   `apply-runs-on: '{"group": "synapse-vnet"}'`).
4. **Apply environments** with required reviewers, e.g.
   `apply-environment: "{deployment}"`. It's required while `apply` is true,
   because it's the approval gate.
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
   - with `what-if`, the plan identity needs **Synapse Artifact User**, and
     Azure **Reader** on the workspace to list its pools.
   - **Dependabot** runs get no OIDC token (and no Actions secrets), so a
     Dependabot PR fails its what-if and its apply. Turn both off for it on
     the calling job, so it builds and plans offline and its Result check
     still reports (skipping the job would leave that required check
     pending):

     ```yaml
     what-if: ${{ github.actor != 'dependabot[bot]' }}
     apply: ${{ github.actor != 'dependabot[bot]' }}
     ```

6. **Infrastructure as code** creates the workspace, its managed virtual
   network, managed private endpoints, integration runtimes and Spark and
   SQL pools before the first deployment. Apply an infrastructure change
   that an artifact needs (a new pool, say) first.
7. **Branch protection:** require `<caller job> / Result`.

## Reference

The inputs are those of [Data Factory](../datafactory/README.md#reference),
with these differences:

<!-- markdownlint-disable MD013 -->

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | The Synapse workspace's Git root folder |
| `workspace-name` | from `*-WorkspaceDefaultStorage` | Development workspace's name, for the template's defaults (instead of `factory-name`) |
| `what-if` | `true` | List new artifacts and deletions, check the pools exist (needs network access, Synapse Artifact User and Reader) |
| `delete-artifacts` | `true` | Delete artifacts that aren't in the template |
| `deploy-managed-private-endpoints` | `false` | Deploy the folder's managed private endpoints; `false` leaves them to infrastructure as code. `true` also deletes endpoints not in the folder |
| `deploy-integration-runtimes` | `false` | Deploy the folder's integration runtimes; `false` leaves them to infrastructure as code. Synapse never deletes them |
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
| [`synapse/plan`](plan/action.yaml) | Leave out what infrastructure as code owns, render parameters, optional comparison with the live workspace, pool check and live fingerprint, summary |
| [`synapse/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, live check, triggers around the deployer |

<!-- markdownlint-enable MD013 -->

Run [`shared/setup`](../shared/setup/action.yaml) first in every job that
runs a tool; [`shared/pr-comment`](../shared/pr-comment/action.yaml) and
[`shared/result`](../shared/result/action.yaml) work here too. The scripts
run locally, e.g.:

```bash
WORKING_DIR=synapse synapse/scripts/build.sh
WORKING_DIR=synapse TEMPLATE_DIR=/tmp/synapse-template PARAMETER_FILES=deployments/dev.json RESOURCE_GROUP=rg-dev synapse/scripts/plan.sh
```

## Limitations

- **Global parameters** don't exist in Synapse, and Data Factory's aren't
  deployed.
- **Synapse Studio's Publish** publishes the collaboration branch
  (`main`) to the workspace and may create a `workspace_publish` branch.
  Under the required checks `main` only holds what was reviewed and
  applied, but Publish bypasses the per-environment approval: don't use it.
- **No "no changes" plan.** Synapse has no what-if, so every deployment a PR
  runs asks for approval. The live check still refuses an apply when the
  workspace changed since the plan.
- **A change in the portal** (or a trigger started there) changes etags, so
  the next apply asks for a new plan.

## Coming from workspace\_publish

<!-- markdownlint-disable MD013 -->

| Publish-branch workflow | Here |
| --- | --- |
| **Publish** in Synapse Studio, into `workspace_publish` | The build job, on every PR and push |
| `params-<env>.json` kept in the publish branch | `deployments/<env>.json` next to the artifacts |
| `TargetWorkspaceName` per environment call | `workspaceName` in each deployment's file |
| `DeleteArtifactsNotInTemplate`, `deployManagedPrivateEndpoint` | `delete-artifacts`, `deploy-managed-private-endpoints` (which also governs deleting endpoints) |
| Stopping and starting triggers by hand | `manage-triggers` |
| A publish branch per workspace (e.g. a QA one) | Another folder, another call |

<!-- markdownlint-enable MD013 -->
