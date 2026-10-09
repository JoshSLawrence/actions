# Design: SQL database projects

- **Status:** approved (revision 3), 2026-10-09
- **Ships as:** `v0.5.0`

## Summary

A reusable workflow family, `sqlproject.yaml` (build once, resolve
deployments) calling `sqlproject-deploy.yaml` (plan, apply one deployment),
builds, plans and publishes SDK-style SQL database projects
(`Microsoft.Build.Sql`) from pull requests, the way the OpenTofu and Data
Factory workflows deploy theirs. The shape is that of Data Factory and
Synapse: a folder, one deployment per file, a plan reviewed on the PR, an
approval-gated apply of exactly that plan.

```text
sqlproject.yaml         build ───────┬─> deploy (per deployment) ──> result
                        deployments ─┘      │
                                            │
sqlproject-deploy.yaml                   plan ──> apply (after approval)
```

User documentation is in [`sqlproject/README.md`](../../sqlproject/README.md)
and [`sqlproject/source-of-truth.md`](../../sqlproject/source-of-truth.md);
this document records the decisions and why.

## Decisions

<!-- markdownlint-disable MD013 -->

| Topic | Decision |
| --- | --- |
| Deployment unit | The project's dacpac x one publish profile (`deployments/<env>.publish.xml`). The profile names the server and database; the deployment name is the file name. |
| Plan | SqlPackage `DeployReport` and `Script` against the live database, with the exact deploy options of the apply. The plan artifact is the dacpacs, the profile, the target and the report. |
| Apply | After environment approval: stale-plan preflight (shared), digest check, a fresh live `DeployReport` that must equal the planned one, then `Publish` of the planned dacpac. |
| Deploy mode | Input `deploy-mode`: `additive` (default; nothing outside the project is dropped, and the plan lists what is kept) or `truth` (drops what is not in the project, except `keep-object-types`). |
| Deployment scripts | Pre/post-deployment scripts do not show in a report. Input `deployment-scripts`: `changed` (default; compared with what is deployed) or `always`. |
| Possible data loss | `DataIssue` alerts block the plan unless `allow-data-loss` is on; then Publish uses `BlockOnPossibleDataLoss=False`. |
| Auth | `azure/login` (OIDC), then `az account get-access-token --resource https://database.windows.net/`, passed as `/AccessToken` inside a mode-600 response file, never on a command line. |
| Tools | Pinned in the project folder's `mise.toml`: `dotnet`, `"dotnet:microsoft.sqlpackage"` (mise's dotnet backend), `yq`, plus `azure-cli` and `uv` for online plans. |
| Triggers | `pull_request` and `workflow_dispatch` only; no push trigger. |
| Drift detection | Deferred. Every PR plan already shows drift (the kept list), and the apply refuses if the database changed after the plan. |

<!-- markdownlint-enable MD013 -->

## Why additive is the generic default

It is SqlPackage's own default. It is safe on the day a consumer points the
workflow at an existing database whose objects are not all in the project
yet (the usual adoption path). Destruction is an explicit opt-in. And the
plan's "kept" list shows exactly what `truth` mode would drop, so switching
later is an informed, reviewed one-line change.

## Plan and apply semantics

- **Exactly the reviewed plan.** The digest covers the dacpacs (schema and
  deployment scripts), the profile, the planned report, the deployment
  scripts comparison and the target. The apply builds its SqlPackage
  arguments only from the plan directory, so plan and apply cannot differ.
- **Stale plans.** The shared preflight: the PR is still open at the planned
  head, and none of `preflight-paths` changed on the target branch since the
  plan. A deployment's paths leave out the other profiles of the project (a
  sibling deployment's profile changing does not make this plan stale, as
  OpenTofu leaves out sibling var files) and always include its own. The
  live re-check: the database still yields the same report. This is
  SqlPackage's equivalent of OpenTofu's stale saved plan.
- **No changes, no approval.** `has-changes` false skips the apply job.
- **A missing database fails the plan.** A report does not show it (it lists
  only the object creates), but the generated script contains
  `CREATE DATABASE [$(DatabaseName)]`. Publish would create it, on Azure SQL
  with a default SKU outside the infrastructure code, so the plan refuses.
- **When it applies.** A pull request run plans, then applies from the PR
  after approval (`apply: false`: plan only). Any other run on the default
  branch plans and applies after approval only if something changed; other
  branches only plan. There is no apply-after-merge mode: under a required
  check, the default branch only holds what was applied, so a push run
  would plan again for nothing.
- **Token lifetime.** Entra tokens last about an hour and SqlClient cannot
  refresh an `/AccessToken`; a publish that runs longer may fail on
  reconnect. A later version can switch to SqlClient's
  `Active Directory Default`, which refreshes, if it happens.

## Deployment scripts

A report never shows pre- and post-deployment scripts: two dacpacs with the
same schema and a different post-deployment `MERGE` give a report with no
operations while the script still contains the `MERGE`. A plan that decided
"changes" from the report alone would never publish a change made only to
the scripts, so:

- `has-changes` is true when the schema changes, or when the dacpac has
  deployment scripts and they count as changed;
- `deployment-scripts: changed` compares them with **what is deployed**,
  which the model makes knowable: on a pull request, a build of the PR's
  base commit (PRs apply before merge under a required check); on a
  dispatch, nothing, so they count (a manual run is a request to deploy);
- `always` makes every plan of a project with scripts a change.

The comparison builds the base commit with the target branch's own code in
a throwaway `git worktree`, never a fork's. Scripts must be idempotent
either way: they also run with every schema change.

## Data loss and owned properties

- The source of truth is `DataIssue` alerts in the report. The alert
  appears whatever `BlockOnPossibleDataLoss` is and whether or not the
  table has rows; with the default (`True`), Publish additionally fails when
  rows are detected.
- Off by default: the plan step fails after writing its summary and
  outputs, the PR comment says "Apply: blocked" with the reason (the
  `blocked-reason` input of `shared/pr-comment`), nothing is uploaded, and
  the call's `Result` fails.
- `allow-data-loss: true`: the plan passes, says so, and both the plan and
  Publish use `BlockOnPossibleDataLoss=False`.
- The inputs own `BlockOnPossibleDataLoss`, `DropObjectsNotInSource` and
  `DoNotDropObjectTypes`: profiles and `properties` cannot set them, so
  there is one switch per call, visible in the calling workflow.
  `CreateNewDatabase=True` is refused outright.

## SqlPackage and secrets

- SqlPackage reads arguments from a response file (`sqlpackage @file`), one
  per line. A value with spaces must be quoted, and unquoted, SqlPackage
  **echoes a malformed argument, a password included**. So every line is
  written double-quoted, values with a double quote or a line break are
  refused, and the output is scrubbed of the secret anyway.
- A command line beats the profile, so the server and database are read
  from the profile and passed explicitly with `/AccessToken`.
- `/UniversalAuthentication` is interactive and unusable in CI.
- No caches: a NuGet cache restored into apply jobs would be a poisoning
  risk.

## Findings that shaped the implementation

Found while testing against a real SQL Server and recorded here because
they are easy to get wrong:

- **A publish profile needs the MSBuild namespace.** SqlPackage ignores the
  properties and SQLCMD variables of a profile whose `<Project>` has no
  `xmlns="http://schemas.microsoft.com/developer/msbuild/2003"` (IDE-made
  profiles have it). The workflow refuses such a profile, since it would
  silently deploy with the wrong options.
- **SqlPackage connects to a profile's `TargetConnectionString` even with
  `/TargetFile`,** and hangs on a server that does not exist. An offline
  plan (never applied) therefore uses a copy of the profile without it.
- **A refactorlog needs the `dac/Serialization/2012/02` namespace,** or the
  build succeeds and the dacpac silently carries no operations, so a rename
  plans as a drop and a create.
- **The dacpac name is the project's `SqlTargetName`** (`dotnet msbuild
  -getProperty:SqlTargetName`), which the build checks before keeping
  anything.

## Tests

- `tests/sqlproject/scripts-test.sh` (pre-commit and CI Lint): offline, with
  stubs for mise, dotnet, sqlpackage, az and gh, canned reports and scripts
  in `tests/sqlproject/fixtures/`, and throwaway Git repositories for the
  deployment-scripts comparison.
- `tests/sqlproject/engine-test.sh` (CI job "SQL project engine"): the real
  scripts against a SQL Server container, with SQL authentication.
- CI end-to-end calls: "E2E sqlproject" (additive) and "E2E sqlproject
  truth", planning the fixture offline against `ci/baseline.dacpac`
  (`tests/sqlproject/make-baseline.sh` rebuilds it).
- Not feasible without Azure: OIDC sign-in, the token, private endpoints.

## Alternatives not taken

- **Publishing from the IDE or a blind pipeline step:** no review of what
  changes, no stale-plan protection.
- **Comparing the dacpac only (a model diff):** says nothing about the live
  database, so drift and out-of-band changes would be invisible.
- **A push trigger with apply-after-merge:** with a required check that
  applies from the PR, it would plan again for nothing.
