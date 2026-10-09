# SQL project

Build, plan and deploy an SDK-style SQL database project
([`Microsoft.Build.Sql`][sdk], as created by the VS Code SQL Database
Projects extension) from pull requests, with the plan and the result posted
on the PR. The project is built to a dacpac once; each database it deploys
to is planned with SqlPackage's `DeployReport` and `Script` against the live
database, approved by the environment's reviewers, and published exactly as
planned.

How to treat the project as the source of truth for a database, and what
that means for renames, data and deployment scripts, is in
[`source-of-truth.md`](source-of-truth.md).

[sdk]: https://learn.microsoft.com/sql/tools/sql-database-projects/concepts/sdk-style-projects

## Contents

- [Why](#why)
- [Quick start](#quick-start)
- [Concepts](#concepts)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reference](#reference)
- [Deploy modes](#deploy-modes)
- [Deployment scripts](#deployment-scripts)
- [Data loss](#data-loss)
- [Composite actions](#composite-actions)
- [Security notes](#security-notes)
- [Limitations](#limitations)

## Why

A database project is the schema in Git, but a deployment is usually a
person publishing from an IDE or a pipeline that publishes blind. These
workflows give a database the review that infrastructure code gets: the PR
shows what SqlPackage would change in each database (and the T-SQL it would
run), an approval gates the publish, and the publish does exactly what was
reviewed or nothing at all.

## Quick start

```yaml
name: Database

on:
  pull_request:
    branches: [main]
    paths: [database/core/**]
  workflow_dispatch:

permissions: {}

jobs:
  core:
    uses: JoshSLawrence/actions/.github/workflows/sqlproject.yaml@v0.5.0
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: database/core
      deployments: deployments/*.publish.xml
      apply-environment: "core-{deployment}"
```

The caller must grant the four permissions shown: a reusable workflow's jobs
can only narrow them. There is no `push` trigger: a PR's plans are applied
from the PR (before merge, under a required check), so the default branch
only holds what was applied. A complete caller, with the setup it needs, is
in [`examples/sqlproject.yaml`](../examples/sqlproject.yaml).

## Concepts

- **Project folder:** the folder with exactly one `*.sqlproj`. It pins its
  own tools in a `mise.toml` (below). Nothing from the repository root is
  used.
- **Deployment:** the project's dacpac with one publish profile, e.g.
  `deployments/dev.publish.xml`. The profile names the server and the
  database; the deployment is named after the file (`dev.publish.xml` is
  `dev`). `apply-environment`, `plan-environment` and `variables` take
  `{deployment}`.
- **Publish profile:** the standard SqlPackage `*.publish.xml`, the same
  file VS Code and Visual Studio use to publish. The workflow needs
  `TargetDatabaseName` and a `TargetConnectionString` with only the server
  (`Data Source=myserver.database.windows.net;Encrypt=True`), and refuses
  anything it owns or that could leak (see [Data loss](#data-loss) and
  [Security notes](#security-notes)). Two things trip people up:
  - the root element must carry the MSBuild namespace,
    `<Project ToolsVersion="Current"
    xmlns="http://schemas.microsoft.com/developer/msbuild/2003">`, as
    profiles made by the IDEs do: SqlPackage ignores a profile's properties
    and SQLCMD variables without it, so the workflow refuses such a profile;
  - SQLCMD variables for an environment go in the profile
    (`ItemGroup/SqlCmdVariable/Value`) or the `variables` input.
- **Environments:** `plan-environment` scopes the plan jobs' credentials
  (no reviewers); `apply-environment` is the approval gate (required
  reviewers). Every environment must exist before a run.
- **Modes:** `additive` (the default) never drops what is not in the
  project; `truth` makes the project the source of truth. See
  [Deploy modes](#deploy-modes).

## How it works

```text
sqlproject.yaml         build ───────┬─> deploy (per deployment) ──> result
                        deployments ─┘      │
                                            │
sqlproject-deploy.yaml                   plan ──> apply (after approval)
```

- **build** builds the dacpac once and uploads it, with a record of whether
  the pre- and post-deployment scripts changed. It needs no credentials, so
  PRs from forks run it too.
- **deployments** checks every input (all problems at once), resolves the
  profiles into a matrix, and checks the GitHub environments exist.
- **plan** (per deployment) asks SqlPackage for the report and the script
  against the live database, with the exact options the apply will use. A
  database that does not exist fails the plan: this workflow never creates
  databases. The plan holds the dacpacs, the profile, the target, the
  report, the script and a summary, and is uploaded when there is something
  to apply; the summary is commented on the PR. Plans of fork and Dependabot
  PRs are skipped (no OIDC token).
- **apply** (per deployment) runs only when the plan has changes, so a plan
  with nothing to do asks for no approval. After the environment's approval
  it:
  1. refuses a stale plan: the PR moved on, or the project's files changed
     on the target branch since (a sibling deployment's profile does not
     count);
  2. checks the plan's SHA-256;
  3. plans again against the live database and refuses if the report is not
     the reviewed one: someone changed the database after the plan;
  4. publishes with the plan's own dacpac, profile and options.
- **result** rolls everything up into one check to require in branch
  protection: `<caller job> / Result`.

A pull request run applies from the PR, after approval. A
`workflow_dispatch` (or any other run) on the default branch plans and
applies after approval only if something changed; other branches only plan.
One publish runs at a time per database, from whichever workflow or PR.

## Setup

1. **Pin the project's tools** in its folder:

   ```bash
   mise use dotnet@10.0.401 dotnet:microsoft.sqlpackage@170.5.96 \
     yq@4.53.6 azure-cli@2.90.0 uv@0.12.19
   ```

   `dotnet` builds, SqlPackage (installed by mise as a dotnet tool) plans
   and publishes, `yq` reads profiles and reports, `azure-cli` (installed
   with `uv`) gets the Entra token. With `target-dacpac` no `azure-cli` is
   used.
2. **The database identity.** Azure SQL signs the workflow in with an Entra
   token, so the identity of `AZURE_CLIENT_ID` must be a user of each
   database, able to deploy: e.g. the server's Entra administrator. For an
   application, Azure SQL's administrator ID is its client (application) ID.
3. **Databases are created by your infrastructure code**, before the
   workflow plans them: a plan against a missing database fails, telling you
   so.
4. **Runners that reach the databases.** Private endpoints need runners in
   the network: use `plan-runs-on` and `apply-runs-on` for a runner group
   that can reach the servers.
5. **Environments** with required reviewers, one per deployment with
   `apply-environment: "core-{deployment}"` (or one shared). The apply warns
   when its environment has no required reviewers.
6. **Azure OIDC.** No secrets are needed: set the variables
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`
   (environment-scoped ones win in that environment's jobs), and add a
   federated credential for each subject the jobs present, as for
   [Data Factory](../datafactory/README.md#setup). `azure/login` needs a
   subscription ID; the token for the database does not.
7. **Branch protection:** require `<caller job> / Result`.
8. **Dependabot** runs get no OIDC token, so their plans are skipped and
   their `Result` reports that.

## Reference

Paths are relative to the repository root, except `deployments`,
`target-dacpac` and `preflight-paths` entries that name files in the project
folder (as noted), which are relative to the working directory. List inputs
accept spaces or newlines. `{deployment}` is replaced where noted.

<!-- markdownlint-disable MD013 -->

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | The project folder (exactly one `*.sqlproj`) |
| `stack-name` | working directory | Display name in PR comments and summaries |
| `deployments` | required | Publish profiles, one deployment each; globs match within the folder |
| `deploy-mode` | `additive` | `additive` or `truth` ([Deploy modes](#deploy-modes)) |
| `keep-object-types` | users, logins, roles, permissions, credentials, keys | `truth` only: object types never dropped, `;`- or newline-separated |
| `deployment-scripts` | `changed` | When pre/post-deployment scripts alone make a change: `changed` or `always` |
| `properties` | none | Deploy properties every deployment uses, one `Name=Value` per line, after the profile's |
| `variables` | none | SQLCMD variables, one `Name=Value` per line, after the profile's; `{deployment}` |
| `plan-environment` | none | Environment for plan jobs; `{deployment}` |
| `plan-retention-days` | `7` | Dacpac and plan artifact retention |
| `pr-comment` | `true` | Comment the plan and apply result on the PR |
| `target-dacpac` | none | Plan against this dacpac instead of the database: no Azure access; needs `apply: false` |
| `allow-data-loss` | `false` | Let a plan with possible data loss be applied |
| `apply` | `true` | Include the apply job (`false` = plan only) |
| `apply-environment` | none | Environment with required reviewers; `{deployment}`; required with `apply` |
| `preflight-paths` | working directory | What plans depend on; each profile is added, the others left out |
| `runs-on` | `ubuntu-latest` | Runner of every job without its own: a label, or JSON (below) |
| `build-runs-on` | `runs-on` | Runner of the build job |
| `plan-runs-on` | `runs-on` | Runner of each deployment's plan job; must reach the database |
| `apply-runs-on` | `runs-on` | Runner of each deployment's apply job; must reach the database |
| `timeout-minutes` | `30` | Timeout for each job |
| `max-parallel` | `4` | Most deployments at once |
| `mise-version` | `2026.9.12` | mise version |
| `azure-client-id` | `vars.AZURE_CLIENT_ID` | Azure identity for OIDC |
| `apply-azure-client-id` | `azure-client-id` | Separate (write) identity for apply |
| `azure-tenant-id` | `vars.AZURE_TENANT_ID` | Azure tenant |
| `azure-subscription-id` | `vars.AZURE_SUBSCRIPTION_ID` | Azure subscription |

| Workflow | Output | Description |
| --- | --- | --- |
| `sqlproject.yaml` | `deployments` | JSON array of the deployment names |
| `sqlproject-deploy.yaml` | `has-changes`, `data-loss`, `applied` | Whether the plan had changes / possible data loss / was applied |

<!-- markdownlint-enable MD013 -->

There are no secrets. The default `keep-object-types` is
`Users;Logins;DatabaseRoles;ApplicationRoles;RoleMembership;ServerRoles;
ServerRoleMembership;Permissions;Credentials;DatabaseScopedCredentials;
MasterKeys` (written without the line breaks).

The build, plan and apply jobs run on `runs-on` unless given their own
runner. Each runner input takes a label, or JSON when it starts with `{` or
`[`: an array of labels (the runner needs all of them), or a runner group,
with or without labels:

```yaml
    with:
      plan-runs-on: '{"group": "private-network"}'
      apply-runs-on: '{"group": "private-network", "labels": ["linux-x64"]}'
```

`sqlproject-deploy.yaml` is the building block: plan and apply of one
deployment, taking a `dacpac-artifact` (sqlproject/build's output) and the
deployment's resolved `profile`.

## Deploy modes

- **`additive`** (the default) publishes with `DropObjectsNotInSource=False`:
  objects in the database that are not in the project stay, untouched. The
  plan lists them ("Kept: in the database, not in the project"), so drift
  and the effect of `truth` are visible without risk. It is SqlPackage's own
  default, and safe on the day you point the workflow at an existing
  database whose objects are not all in the project yet.
- **`truth`** publishes with `DropObjectsNotInSource=True` and
  `DoNotDropObjectTypes=<keep-object-types>`: everything not in the project
  is dropped after a reviewed plan, except the kept types. Table and column
  drops are possible data loss, so they are blocked unless `allow-data-loss`;
  views, procedures, functions, indexes and constraints drop without an
  alert, but are in the plan.

The `keep-object-types` default is what DBA tooling usually manages outside
a project. "Do not drop" never stops the project's own users, roles or
grants from deploying; it only keeps what others created. Add types (e.g.
`Indexes` if DBAs tune indexes), or set it empty to drop everything not in
the project.

`DropObjectsNotInSource`, `DoNotDropObjectTypes` and
`BlockOnPossibleDataLoss` belong to the inputs: a profile or `properties`
that sets them is refused, so there is one switch, visible in the calling
workflow.

## Deployment scripts

Pre- and post-deployment scripts run on every publish, but a deployment
report never shows them. So a plan is a change when the schema changes, or
when the project has deployment scripts that count as changed:

<!-- markdownlint-disable MD013 -->

| Run | `deployment-scripts: changed` compares them with | Why |
| --- | --- | --- |
| Pull request | A build of the PR's base commit | PRs apply before merge under a required check, so the base is what is deployed |
| Dispatch (and anything else) | Nothing: they count | A manual run is a request to deploy |

<!-- markdownlint-enable MD013 -->

`deployment-scripts: always` makes every plan of a project with scripts a
change (and every PR ask for approval), for projects whose scripts must run
on every deployment. The plan comment shows the scripts, collapsed, and why
they count. Scripts must be idempotent either way: they also run with every
schema change.

## Data loss

A `DataIssue` alert in the report (a dropped table or column, a narrowed
type, a new `NOT NULL` column without a default) blocks the plan: the plan
step fails after writing its summary, the PR comment says "Apply: blocked"
with the reason, nothing is uploaded and the call's `Result` fails. With
`allow-data-loss: true` the plan passes, says "possible data loss, allowed
by allow-data-loss", and both the plan and the publish use
`BlockOnPossibleDataLoss=False` (otherwise SqlPackage's own row check would
abort the publish). The environment's approval still gates every apply. A
caller can wire the input to a PR label, e.g.
`allow-data-loss: ${{ contains(github.event.pull_request.labels.*.name,
'sql-allow-data-loss') }}`; changing the label re-runs the plans.

`CreateNewDatabase=True` in a profile is refused outright: it drops and
recreates the database.

## Composite actions

The workflows are made of these; use them directly for a different job
layout. Each action's inputs are documented in its `action.yaml`. Run
[`shared/setup`](../shared/setup/action.yaml) first in every job that runs a
tool (it installs the project's mise tools).

<!-- markdownlint-disable MD013 -->

| Action | Does |
| --- | --- |
| [`sqlproject/build`](build/action.yaml) | Build the dacpac, offline, and compare the deployment scripts with the base commit's |
| [`sqlproject/deployments`](deployments/action.yaml) | Check the inputs and resolve the profiles into a matrix; check the environments exist |
| [`sqlproject/plan`](plan/action.yaml) | DeployReport and Script against the database, the kept list, the summary |
| [`sqlproject/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, live re-check, then Publish |
| [`shared/pr-comment`](../shared/pr-comment/action.yaml) | Create or update the PR comment for one deployment |
| [`shared/result`](../shared/result/action.yaml) | Roll a workflow's jobs up into one check |

<!-- markdownlint-enable MD013 -->

The logic is in [`scripts/`](scripts/) and the shared library,
[`../shared/scripts/`](../shared/scripts/). Every script runs locally too,
e.g. an offline plan against a baseline dacpac, from the repository root:

```bash
WORKING_DIR=tests/fixtures/sqlproject/basic sqlproject/scripts/build.sh
WORKING_DIR=tests/fixtures/sqlproject/basic \
  DACPAC_DIR=$TMPDIR/sqlproject-dacpac \
  PROFILE=deployments/dev.publish.xml TARGET_DACPAC=ci/baseline.dacpac \
  sqlproject/scripts/plan.sh
```

For a database in a local container, set `SQL_AUTH=sql`, `SQL_USER` and
`SQL_PASSWORD` (the workflows never do); the repository's engine test does.

## Security notes

- **OIDC only,** no client secrets. The token comes from
  `az account get-access-token` per SqlPackage call, is masked, and is
  written only into a mode-600 response file in a private temp directory,
  deleted on exit. It is never on a command line, in the environment of
  other steps, in an output, an artifact or a summary, and it is scrubbed
  from SqlPackage's output (which echoes malformed arguments).
- **The plan artifact** holds the dacpacs (schema and deployment scripts),
  the committed profile, server and database names, the reports and the
  script. Profiles with credentials are refused. SQLCMD variables are in the
  script and the PR comment: not for secrets. Artifacts of a public
  repository can be downloaded by any signed-in user.
- **Least privilege:** the build has `contents: read` only; plan and apply
  are the only jobs with `id-token: write`.
- **No caches:** NuGet packages are not cached, so nothing restored into an
  apply job can have been poisoned by another run.
- **The base-commit build** runs the target branch's own code, never a
  fork's.
- **Destructive operations** are explicit: databases are never created,
  `CreateNewDatabase` is refused, additive mode drops nothing, and in truth
  mode drops are in the plan, table and column drops are blocked as data
  loss, and security objects are kept by default.

## Limitations

- One SQL project per folder.
- Databases must exist: create them with your infrastructure code first.
- No secret SQLCMD variables.
- An Entra token lasts about an hour and SqlPackage cannot refresh it, so a
  publish longer than that may fail when it reconnects.
- No drift workflow yet: every PR plan shows drift in additive mode's "Kept"
  list, and the apply refuses if the database changed after the plan.
- SQL authentication is for local runs only.
- The deployment-scripts comparison assumes PRs apply before they merge
  under a required check.
- SqlPackage ignores a profile's properties without the MSBuild namespace on
  its root element; such profiles are refused.
