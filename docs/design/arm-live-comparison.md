# Design: compare plans with the live definitions

- **Status:** approved
- **Ships as:** `v0.8.0` (breaking; before `v1.0.0` that is a new minor)

## Summary

Synapse has no what-if, so a plan used to list every artifact as an update
and `has-changes` was always true: every pull request asked for an approval
per environment. Data Factory's what-if cannot resolve a secure parameter
(`[parameters('x')]`), so a linked service whose connection string comes
from one was always a modify.

Both plans now compare what would be deployed with what is live:

- **Synapse:** with `what-if`, each template artifact, evaluated as the
  deployer would publish it, is compared with the definition the plan
  already downloads (the list responses carry full definitions, so there
  are no extra calls). The comment shows which artifacts change (with
  property paths), which are new, which are deleted, and a count of the
  rest. A plan with nothing to create, change or delete has `has-changes`
  false and skips its apply and approval.
- **Data Factory:** a secure parameter reference in a what-if delta is
  resolved from the parameters, compared with the live value, and dropped
  when they are equal.

Measured on a published workspace, a raw comparison reported 46 of 67
artifacts as changed; after the normalization below, one, and it was a real
difference between the folder and the workspace. A workspace that was behind
its folder showed exactly the pull requests it had not applied.

## Decisions

<!-- markdownlint-disable MD013 -->

| Topic | Decision |
| --- | --- |
| Synapse "no changes" | A plan with nothing to create, change or delete sets `has-changes` false. This is breaking: callers that relied on every run applying see the apply skipped. |
| Opt-out | `always-apply` (boolean, default false), defined identically in all four Data Factory and Synapse workflows and both plan actions, makes `has-changes` true and the heading say "applied anyway". It deploys everything anyway, for example after a change in the portal that the plan ignores or cannot see. A secure value the service hides already counts as a change, so a rotated secret needs no opt-out. |
| Comparison rule | Exact equality after the normalization below. Comparing only what the template defines was rejected: a property removed in the folder (a description, a detached pool) would never be reported, and with the apply skipped it would never reach the workspace. |
| Never "unchanged" by accident | A value the plan cannot read or evaluate, a live item without a definition, a kind that is not compared and a secure value the service hides all count as changes. If the comparison itself fails, the plan warns, counts every existing artifact as changed and does not fail. |
| Secure values | Compared where the service returns them, and never shown: only property paths reach the output. A readable difference is a modify with the path marked 🔒. A value the service hides (`**********`, null or omitted), or a Key Vault reference, is "🔒 secure, not compared" and counts as a change. |
| Parameters note | Every plan comment and job summary that lists a 🔒 parameter says where the values are (`deploy/parameters.json` of the plan artifact; `parameter-secrets` are never shown), linking the run when known. No hash or other derivative of a secure value is ever shown. |
| Plan artifact | Unchanged. The apply still deploys the whole template, so it needs nothing from the comparison; `live.json`'s fingerprint pins the live state the comparison was made against. A plan with nothing to change is not uploaded. |
| Evaluator | Copies the deployer's grammar (`src/expression.ts`, the parameter rules of `src/template.ts`, `src/defaults.ts`); keep them equal. |

<!-- markdownlint-enable MD013 -->

## The Synapse comparison

`arm_synapse_compare` (in `arm/scripts/arm.sh`) runs
`arm/scripts/synapse-compare.jq` over the plan's stripped template, a
scratch parameters file (the rendered parameters plus `parameter-secrets`,
mode 600, deleted when the plan ends), the template's artifacts as the plan
keys them, and the live lines (`ARM_LIVE_PROPERTIES=true`). It prints one
line per template artifact: its key, a status and the differing paths.

Artifacts are keyed as before (`<type>/<name>`, lower case), so "new" and
"deleted" are unchanged. Only `properties` is compared.

### Statuses

<!-- markdownlint-disable MD013 -->

| Status | When | Counts as a change |
| --- | --- | --- |
| `skipped` | A service default, as before | no |
| `create` | No live item has its key | yes |
| `modify` | A path differs (modified, added, removed, or a readable secure value) | yes |
| `unknown` | A path could not be evaluated, the live item has no definition, or the kind is not compared | yes |
| `secure` | The only differences are secure values the service hides | yes |
| `unchanged` | Nothing differs after normalization | no |

<!-- markdownlint-enable MD013 -->

Kinds compared: notebooks, Spark job definitions, SQL and KQL scripts, Spark
configurations, datasets, data flows, pipelines, triggers, linked services
and credentials. Lake databases (another API), and managed private endpoints
and integration runtimes when they are deployed, are not compared, so a
folder with them always has changes.

### Evaluating the template as the deployer does

A string is an expression only if all of it is `[...]`, it parses, and the
outer call is `parameters`, `variables`, `concat` or `resourceId`. One that
opens like a supported call but does not parse, or nests an unsupported
function, fails the deployment: the plan marks it "can't compare". Anything
else is literal text, including `[log].[usp_x]`, `[toLower('x')]` and
`[[x]`: `[[` is not an escape for the deployer, unlike in an ARM deployment.

`workspaceName` is always the target workspace. Another parameter is the
supplied value as it is, else the template's default (itself evaluated, to a
depth of 10), else it cannot be compared. A supplied value is used as it
is, never evaluated as an expression. Then a reference to another
workspace's default linked service is pointed at the target's, as the
deployer does: every `referenceName` of a `LinkedServiceReference`, and the
last segment of every `dependsOn` string whose parent segment is
`linkedServices`.

### Normalization

Applied to both sides; everything else is compared exactly. Each rule is
something the service adds, drops or rewrites.

1. Null is absent.
2. `[]` and `{}` are absent.
3. Properties the service sets itself (`ARM_SERVICE_MANAGED_PROPERTIES`,
   today `lastPublishTime`; Data Factory reads the same constant).
4. A notebook's `metadata.kernelspec`, which the service does not store.
5. A notebook's `sessionProperties.runAsWorkspaceSystemIdentity` when
   `false` (the service's default; `true` is still a change).
6. A notebook's `metadata.a365ComputeOptions`, Studio's cache of the
   attached pool, which names the workspace. The pool itself and the session
   size are compared.
7. A trigger's `runtimeState` when the template does not set it. It is
   read-only in the REST API, but the apply starts the triggers the template
   marks `Started`, so when the template sets it a different live state is a
   change (in both directions). With `manage-triggers: false` the apply does
   not start or stop triggers, so such a trigger shows as a change in every
   plan until it is aligned by hand; the plan does not know that input.

Not normalized, on purpose: `folder`, `execution_count`, array order, value
types (`"2"` is not `2`) and cell outputs. Arrays of different length are
reported once, at the array.

## Data Factory

`arm_whatif_secure` runs between the what-if and the plan's summary. A delta
whose `after` is exactly `[parameters('x')]`, naming a secure parameter, is
compared with `before`: equal, it is removed (with a parent whose children
all go); hidden or a Key Vault reference, it is marked `not-compared`;
otherwise `differs`. A modification made only of `not-compared` paths is a
"Secure" row: it counts as a change.

## Risks

- The evaluator must track the deployer; a change to the grammar there
  changes what is published.
- Kinds without a measured workspace (triggers, data flows, Spark job
  definitions, KQL scripts, Spark configurations, user credentials) may show
  noise at first. Noise is "changed", the safe direction; report it and add
  a rule.
- Masked secure values are unverified on both services: the rule comes from
  the services' documented behavior.
- Real drift becomes visible: the first plans after release surface
  differences between the folder and each workspace.
