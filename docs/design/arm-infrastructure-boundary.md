# Design: the infrastructure boundary of Data Factory and Synapse

- **Status:** approved, 2026-10-09
- **Ships as:** `v0.6.0` (breaking; before `v1.0.0` that is a new minor)

## Summary

The Data Factory and Synapse workflows deploy a factory's or workspace's
Git folder. Left alone, both would also destroy infrastructure that
infrastructure as code (OpenTofu) created:

- Data Factory's generated post-deployment script deletes every integration
  runtime that is not in the folder. That includes
  `AutoResolveIntegrationRuntime`, which `iac` creates in each factory's
  managed virtual network.
- The Synapse deployer this repository used before v0.7.0, with
  `DeleteArtifactsNotInTemplate`, deleted every non-default managed private
  endpoint that is not in the folder, even when `deployManagedPrivateEndpoint`
  is false. That is every endpoint
  infrastructure as code created.

Both are fixed by one ownership boundary, expressed with the same two inputs
for both services:

- **Infrastructure as code owns network and compute:** the factory or
  workspace itself, the managed virtual network, managed private endpoints,
  integration runtimes, Spark and SQL pools.
- **Git owns logic:** pipelines, datasets, data flows, linked services,
  triggers, credentials, notebooks, SQL and KQL scripts, Spark job
  definitions, Spark configurations, lake databases.

User documentation is in [`datafactory/README.md`](../../datafactory/README.md)
and [`synapse/README.md`](../../synapse/README.md); this document records the
decisions and why.

## Decisions

<!-- markdownlint-disable MD013 -->

| Topic | Decision |
| --- | --- |
| Boundary | Option A: infrastructure as code owns network and compute, Git owns logic. Input `deploy-managed-private-endpoints` and `deploy-integration-runtimes`, both default `false`, on both services. |
| Always left out | Managed virtual networks, Spark and SQL pools (and the stubs the Synapse export generates for them), and `Microsoft.DataFactory/factories` itself. No input. |
| How | `arm_strip_resources` removes the resources of the left-out types from the template, and from every remaining resource's `dependsOn` the entries naming them. The plan, what-if, digest and apply all use the stripped template. |
| Reference files in Git | Allowed and never deployed: Studio's Git mode shows only what is in the folder, so the owner keeps copies of the real network there. The plan lists them under "Left to infrastructure as code". It does not fail: failing would block unrelated PRs. With what-if it lists the live integration runtimes and endpoints (this check only) and marks a file whose type and name exist live (case-insensitive) as a reference copy, with no warning. A file without a live counterpart warns only when other files of its kind do match ("new": added in Studio); when none of a kind match, the folder holds another environment's copies (dev's endpoint names in stg and prod) and the plan shows one note per kind. With what-if off, or when that listing fails (it only decides what the plan says, so it never fails the plan), every such file warns. |
| Data Factory deletions | The post-deployment script is not edited. When integration runtimes are left to infrastructure as code, the apply gives the script a copy of the template that also lists every live integration runtime by name, so it keeps them. |
| Synapse deletions | The Synapse deployer (`JoshSLawrence/synapse-deploy`) never deletes managed private endpoints unless it deploys them. The plan's deletion list matches its rules: the service's defaults by type, endpoints named `synapse-ws-*`, and only Spark, SyMS lake databases. |
| Live re-check | A plan records a fingerprint (SHA-256 of the sorted `{type, name, etag}` lines) of the live logic, plus the integration runtimes and endpoints when deployed. The apply lists the same kinds again and refuses on a difference. Without what-if there is no fingerprint and the apply says the check is skipped. |
| Pool check | With what-if, a Synapse plan fails when a notebook, Spark job definition or generated pool stub names a pool the workspace lacks. |
| Synapse "no changes" | Deferred. `has-changes` stays true: every Synapse deployment a PR runs asks for approval, as before. The live re-check covers the safety side. |
| Template artifact | Named per call (stack, deployments, parameter files), as the SQL project's dacpac is, so several calls in one run do not overwrite each other's. |
| Stale-plan paths | A deployment's paths leave out the other deployments' parameters files in its folder, and always include its own and the shared ones, as the SQL project does for profiles. |
| Apply environment | `apply-environment` is required with `apply`: an apply without an environment has no approval gate. |
| Apply concurrency | Keyed on the plan's resource group and factory or workspace, not the inputs, so any workflow targeting one target queues. |

<!-- markdownlint-enable MD013 -->

## What each service does with each kind

<!-- markdownlint-disable MD013 -->

| Kind | Data Factory deploys | Data Factory deletes | Synapse deploys | Synapse deletes |
| --- | --- | --- | --- | --- |
| Managed virtual network | never | never | never | never |
| Managed private endpoints | `deploy-managed-private-endpoints` | never | `deploy-managed-private-endpoints` | those not in the folder, only when deployed |
| Integration runtimes | `deploy-integration-runtimes` | those not in the folder, only when deployed | `deploy-integration-runtimes` | never |
| Spark and SQL pools | n/a | n/a | never | never |
| The factory (identity, network, Git settings) | never | never | n/a | n/a |
| Logic | yes | yes (not change data capture) | yes | yes |
| Credentials | yes | never | yes | yes (not the default) |

<!-- markdownlint-enable MD013 -->

Before v0.6.0 Data Factory deployed the managed virtual network, endpoints
and runtimes it found in the folder, and deleted runtimes it did not; Synapse
deployed runtimes and deleted endpoints. Set `deploy-integration-runtimes` or
`deploy-managed-private-endpoints` to `true` to deploy them again.

## The Data Factory integration runtime shield

The export's `PrePostDeploymentScript.ps1` reads the template's resources
and, after the deployment, deletes every live integration runtime whose name
is not among the template's. It reads only `type` and `name` of each, and it
takes a name out with `Substring(37, Length - 40)`: it strips the 37
characters of `[concat(parameters('factoryName'), '/` and the 3 of `')]`.

So when integration runtimes are left to infrastructure as code (the plan's
template has none), the apply lists the factory's live runtimes and gives the
script a copy of the template in a scratch directory with one stub per
runtime:

```json
{
  "type": "Microsoft.DataFactory/factories/integrationRuntimes",
  "name": "[concat(parameters('factoryName'), '/<name>')]"
}
```

The ARM deployment keeps using the plan's template. The unit test pins the
name format by applying the script's own rule to the stubs.

## The live re-check

Without it, two open PRs applied in turn silently undo each other in every
environment: PR B's plan, made before PR A applied, would delete A's new
artifacts or overwrite A's edits. SQL and OpenTofu already prevent that (a
fresh report, a stale saved plan).

- **Fingerprint.** The kinds are the logic (Data Factory: triggers,
  pipelines, data flows, datasets, linked services; Synapse: credentials,
  data flows, datasets, linked services, notebooks, pipelines, Spark job
  definitions, SQL and KQL scripts, triggers, Spark configurations and lake
  databases) plus runtimes and endpoints only when deployed. Endpoint
  listings have a null etag, so they are fingerprinted by name only; lake
  databases (a different API: `{items, continuationToken}`, no etag) by a
  digest of each item. The
  service's own artifacts (Synapse's default linked services, credential and
  `synapse-ws-*` endpoints) are left out: deployments skip them, so they say
  nothing about a change.
- **Where.** `deploy/live.json` (`{fingerprint, kinds}`) is in the plan
  directory, so the digest covers it. Data Factory's apply checks before the
  pre-deployment script stops any trigger; Synapse's `apply-prepare.sh`
  checks before it stops any trigger.
- **False refusals.** An etag can change for reasons other than a
  deployment, such as a trigger started in the portal. The refusal says to
  plan again. Watch for churn, and narrow the kinds if needed.
- **The apply's own inputs.** The plan records which kinds it left out, and
  whether it previewed deletions (`pre-post-script` for Data Factory,
  `delete-artifacts` for Synapse), in `target.json`. An apply given a
  different `deploy-integration-runtimes`,
  `deploy-managed-private-endpoints`, `pre-post-script` or
  `delete-artifacts` is refused, so the shield above cannot be turned off by
  a mismatch and nothing is deleted that the plan never showed. The reason
  is added to the summary the PR comment posts.
- **Recovery.** A partial apply changes the target, so "re-run failed jobs"
  reuses a plan the live check then refuses. Every message says to re-run all
  jobs, which plans again.
- **Lists are never cut short.** A 404 ends a list only on its first page (a
  factory that does not exist yet); on a later page it is an error, because
  a truncated list of integration runtimes would let the script delete the
  rest. The shield also lists right before the post-deployment script, not
  before the deployment.

## Alternatives considered

- **Option B: Git owns endpoints and runtimes.** Every endpoint becomes a
  file whose name is the same in every environment, so the
  environment-suffixed names infrastructure as code uses today must change
  (a delete and create of each, each pending the owner's approval again).
  Targets become per-environment parameters, full resource IDs duplicated
  from the tfvars, and adding a storage account touches the tfvars, two or
  three folders and up to eight parameter files. Deletion stays asymmetric,
  and an endpoint's target cannot change in place. Pools stay in
  infrastructure as code either way, so the line would still be split.
  Option A keeps one source for endpoint targets, drift detection as it is,
  and the cleaner rule that pools force anyway.
- **A custom deletion step for Data Factory** instead of the stubs: a second
  implementation of what the script does, to keep in step with Microsoft's.
  The stubs keep the script as the one place that decides.
- **Filtering the generated script's text**: it is regenerated by the bundle
  on every run, so a text patch breaks silently when Microsoft changes it.
- **Failing when a left-out kind is in the folder**: Studio can write
  reference files on its own, and failing would block unrelated PRs.
  A warning keeps the plan honest without that.
- **Comparing each Synapse artifact with the live one** to skip approvals
  when nothing changes: a few hundred lines of per-type normalization that
  need upkeep as Studio's formats change. Deferred.

## Limitations

- Global parameters are deployed only when the export puts them in the
  template. Checked against the current export bundle (sha256 `74782a53`): a
  folder with `publish_config.json` holding `"includeGlobalParamsTemplate":
  true` gets a `Microsoft.DataFactory/factories/globalparameters` resource
  (named `default`, one `default_properties_<name>_value` parameter each);
  without it the export writes only `<factory>_GlobalParameters.json` and
  `GlobalParametersUpdateScript.ps1`, which nothing runs. The resource is
  not stripped as part of the factory (it is logic, parameterized per
  deployment), so it is deployed and the factory's global parameters become
  exactly the folder's.
- A dependency the plan cannot resolve statically (a computed name in a
  `resourceId()` of a removed kind) fails the plan with the resource and the
  dependency named. One built entirely from variables is not detected.
- With `deploy-managed-private-endpoints: true`, Data Factory never deletes
  endpoints: its script has no section for them.
- Synapse Studio's **Publish** publishes the collaboration branch to the
  workspace outside this workflow's approval. Do not use it.
- Not testable offline: sign-in, the deployer, the pre/post-deployment script,
  what-if, Synapse data-plane listings.
