# OpenTofu

Validate, test, lint, scan, plan, and apply OpenTofu root modules, with the
plan (and later the apply result) posted on the PR. You can use it two ways:

- **The reusable workflow**
  ([`.github/workflows/opentofu.yaml`](../.github/workflows/opentofu.yaml)).
  It's the whole pipeline in one `uses:`, with a boolean input for each
  check. Start here.
- **The composite actions** (`opentofu/setup`, `checks`, `plan`, `apply`,
  `pr-comment`). These are the building blocks the workflow is made of. Use
  them when you need a different job layout or extra steps.

## Contents

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Setup](#setup)
- [Reusable workflow reference](#reusable-workflow-reference)
- [Composite actions](#composite-actions)
- [Tool versions](#tool-versions)
- [PR comments](#pr-comments)
- [Security notes](#security-notes)
- [Coming from the Azure DevOps templates](#coming-from-the-azure-devops-templates)

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
      working-directory: infra
      apply-environment: production
```

The caller must grant all four permissions shown. The workflow's jobs can
only narrow the permissions they're given, never widen them, and GitHub
rejects the whole run if a job asks for more than the caller granted.

More complete callers are in [`examples/`](../examples/):

<!-- markdownlint-disable MD013 -->

| Example | Shows |
| --- | --- |
| [`opentofu-basic.yaml`](../examples/opentofu-basic.yaml) | One module on Azure, applied from the PR |
| [`opentofu-multi-environment.yaml`](../examples/opentofu-multi-environment.yaml) | dev then prod, each with its own approval |
| [`opentofu-multi-root.yaml`](../examples/opentofu-multi-root.yaml) | A matrix over several root modules, a policy repo |
| [`opentofu-apply-on-merge.yaml`](../examples/opentofu-apply-on-merge.yaml) | Apply on merge, a non-Azure provider, Infracost |
| [`opentofu-composite-actions.yaml`](../examples/opentofu-composite-actions.yaml) | Your own workflow built from the composite actions |

<!-- markdownlint-enable MD013 -->

## How it works

```text
validate ──┬──> plan ──> apply (after approval) ──> result
           └──> integration-tests (opt-in) ──┘
```

- **validate** runs fmt, validate, TFLint, Trivy, the terraform-docs check,
  and `tofu test`. Each is an input you can turn off. Every enabled check
  runs even when an earlier one fails, so a single run reports every
  problem, and a results table goes to the job summary. This job gets no
  cloud credentials, so PRs from forks can safely run it.
- **integration-tests** (off by default) runs `tofu test` again, this time
  with cloud credentials. It starts only after validate passes, and can be
  put behind an environment approval.
- **plan** plans to a saved file and renders a summary: counts, destroys
  called out above the fold, a resource table, and the full plan as a
  colored diff. It can also run a conftest policy check and an Infracost
  estimate. It uploads the plan as an artifact and comments the summary on
  the PR. It's skipped for fork PRs, since they get no OIDC token.
- **apply** runs only when the plan has changes, and waits for the
  `apply-environment`'s required reviewers. It then:
  1. refuses a stale plan (the PR moved on, or the module changed on the
     target branch since the plan was made);
  2. checks that the plan file's SHA-256 matches the one the plan job
     produced;
  3. applies that exact plan, never a fresh one;
  4. updates the PR comment with the result.
- **result** is a single stable check to require in branch protection.

### Apply from the PR (default) or on merge

By default (`apply-from-pr: true`) the reviewed plan is applied **from the
PR, before merge**. This has three consequences:

- The default branch only ever holds configuration that has applied
  successfully.
- If you require the `Result` check, a PR with changes can't merge until
  its plan is applied.
- A PR that is applied but then not merged is rolled back by running the
  workflow on the default branch (`workflow_dispatch`), which plans and
  re-applies what's there.

To apply only after merge, set `apply-from-pr: false`. PRs then only plan,
and the comment says the apply happens after merge. The push to the default
branch plans again and applies after approval.

Runs that aren't PRs (`push`, `workflow_dispatch`, `schedule`) only apply on
the default branch. For finer control, use the environment's deployment
branch policies.

## Setup

1. **Apply environment.** Create a GitHub environment (for example
   `production`) with **required reviewers**, and pass its name as
   `apply-environment`. That's the approval gate.

   GitHub creates any environment a workflow names on first use, *without*
   protection rules. The apply job warns when its environment has no
   required reviewers, but it doesn't fail.
2. **Plan environment (optional).** An environment without reviewers, passed
   as `plan-environment`. It lets you scope a read-only identity and
   credentials to plans.
3. **Azure OIDC.** No secrets are needed. Set the variables
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, or pass
   `azure-client-id` and friends as inputs.
   - Variables scoped to an environment win inside that environment's job.
     So a `production` environment can hold the write identity and the
     repository-level variables the read-only one, with no inputs at all.
     `apply-azure-client-id` does the same through an input.
   - Add a federated credential to each identity for the subjects its jobs
     present: `repo:<owner>/<repo>:environment:<name>` for jobs in an
     environment, or `repo:<owner>/<repo>:pull_request` for a plan job
     without one.
   - The azurerm backend and providers fetch GitHub OIDC tokens themselves
     (`ARM_USE_OIDC`). Set `azure-login: true` only if your configuration
     shells out to the az CLI.
4. **Other providers.** Put credentials in a secret holding one `KEY=VALUE`
   per line and pass it as the `env-vars` secret. `apply-env-vars` adds
   credentials for the apply job only (the write credentials).
5. **Branch protection.** Require the `<caller job> / Result` check (for
   example `opentofu / Result`). With `apply-from-pr`, also consider
   **Require branches to be up to date before merging**, so every applied
   plan already includes the latest default branch.

## Reusable workflow reference

Paths are relative to the repository root, except `var-files`,
`backend-config` files and `test-filter`, which (as in OpenTofu) are
relative to `working-directory`. List inputs accept spaces or newlines.

<!-- markdownlint-disable MD013 -->

### General

| Input | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Root module directory |
| `stack-name` | working directory | Display name. Set distinct names when calling the workflow more than once for the same directory and environment |
| `runs-on` | `ubuntu-latest` | Runner label for every job |
| `timeout-minutes` | `30` | Timeout for each job |

### Checks

| Input | Default | Description |
| --- | --- | --- |
| `fmt` | `true` | `tofu fmt -check -recursive` |
| `validate` | `true` | `tofu init -backend=false` + `tofu validate` |
| `tflint` | `true` | TFLint, recursive; uses `.tflint.hcl` if present |
| `trivy` | `true` | Trivy misconfiguration scan; uses `trivy.yaml` if present |
| `trivy-severity` | `trivy.yaml`'s, else `CRITICAL,HIGH` | Severities that fail the scan |
| `docs` | `false` | Fail if the terraform-docs README is stale; uses `.terraform-docs.yml` if present, else injects between `<!-- BEGIN_TF_DOCS -->` markers |
| `tests` | `true` | `tofu test` without cloud credentials (skipped if there are no test files) |
| `test-filter` | all | Test files (globs allowed), e.g. `tests/0*.tftest.hcl` |
| `test-verbose` | `false` | `tofu test -verbose` |
| `integration-tests` | `false` | `tofu test` again with cloud credentials, after validate passes |
| `integration-test-filter` | all | Test files for the integration run |
| `integration-test-environment` | none | Environment for the integration job |
| `integration-test-timeout-minutes` | `90` | Its timeout (generous: a timeout leaks what the test created) |

### Plan

| Input | Default | Description |
| --- | --- | --- |
| `var-files` | none | `-var-file` paths |
| `backend-config` | none | `-backend-config` values, one per line (`key=value` or a file) |
| `plan-environment` | none | Environment for the plan job (no reviewers) |
| `plan-retention-days` | `7` | Plan artifact retention; an approval later than this fails |
| `pr-comment` | `true` | Comment the plan and apply result on the PR |
| `policy` | `false` | conftest policy check; a failure blocks the apply |
| `policy-path` | `policy` | Policy directories |
| `policy-source` | none | go-getter URL for (more) policies, e.g. `git::https://github.com/org/policies.git//opentofu?ref=v1` |
| `policy-namespaces` | all | Rego namespaces to evaluate |
| `policy-fail-on-warn` | `false` | Also block on `warn` rules |
| `cost-estimate` | `false` | Infracost estimate in the summary (needs `infracost-api-key`) |

### Apply

| Input | Default | Description |
| --- | --- | --- |
| `apply` | `true` | Include the apply job at all (`false` = plan only) |
| `apply-from-pr` | `true` | Apply from the PR before merge; `false` = apply on the default branch only |
| `apply-environment` | none | Environment with required reviewers: the approval gate |
| `preflight-paths` | working directory | Paths whose change on the target branch makes a plan stale. Add local modules outside the root |

### Cloud auth and tools

| Input | Default | Description |
| --- | --- | --- |
| `azure-client-id` | `vars.AZURE_CLIENT_ID` | Azure identity for OIDC |
| `apply-azure-client-id` | `azure-client-id` | Separate (write) identity for apply |
| `azure-tenant-id` | `vars.AZURE_TENANT_ID` | Azure tenant |
| `azure-subscription-id` | `vars.AZURE_SUBSCRIPTION_ID` | Azure subscription |
| `azure-login` | `false` | Also `azure/login`, for the az CLI |
| `tofu-version`, `tflint-version`, `trivy-version`, `terraform-docs-version`, `conftest-version`, `infracost-version` | see [Tool versions](#tool-versions) | Version of a tool your mise config doesn't pin |
| `mise-version` | `2026.9.12` | mise version |

### Secrets

| Secret | Description |
| --- | --- |
| `env-vars` | `KEY=VALUE` lines exported (masked) in the integration, plan and apply jobs: other providers' credentials, `TF_VAR_*`, `TF_ENCRYPTION` |
| `apply-env-vars` | `KEY=VALUE` lines for the apply job only, overriding `env-vars` |
| `modules-token` | Token that can read private GitHub repositories used as module or policy sources |
| `infracost-api-key` | Infracost API key |

### Outputs

| Output | Description |
| --- | --- |
| `has-changes` | `true` if the plan has changes |
| `applied` | `true` if the apply job applied the plan |

<!-- markdownlint-enable MD013 -->

## Composite actions

Each action's inputs are documented in its `action.yaml`. Paths are
relative to the workspace. Run `setup` first in every job.

<!-- markdownlint-disable MD013 -->

| Action | Does |
| --- | --- |
| [`opentofu/setup`](setup/action.yaml) | Installs mise and the tools; optionally exports `env-vars` |
| [`opentofu/checks`](checks/action.yaml) | fmt, validate, TFLint, Trivy, docs, tests, each toggled; results table in the job summary |
| [`opentofu/plan`](plan/action.yaml) | Plan to a file, summary, optional policy check and cost estimate. Outputs `has-changes`, `plan-sha256`, `plan-dir`, `summary-file`, `key`, `artifact-name`, `title` |
| [`opentofu/apply`](apply/action.yaml) | Environment check, stale-plan preflight, digest check, apply |
| [`opentofu/pr-comment`](pr-comment/action.yaml) | Create or update the PR comment for one module and environment |

<!-- markdownlint-enable MD013 -->

The actions are thin wrappers around the scripts in [`scripts/`](scripts/).
Each script documents its environment variables at the top and runs locally
too. For example, to render a summary of a saved plan:

```bash
tofu show -json tfplan > plan.json
tofu show -no-color tfplan > plan.txt
PLAN_JSON=plan.json PLAN_TEXT=plan.txt opentofu/scripts/plan-summary.sh
```

## Tool versions

Everything runs through [mise](https://mise.jdx.dev).

- **Your mise config wins.** If `mise.toml` (or `.tool-versions`) in the
  working directory or any parent pins a tool, that version is used, and a
  version input for it is ignored with a warning.
- **Fallbacks.** A tool your config doesn't pin is installed at the version
  from its input, or at this library's default:

| Tool | Default |
| --- | --- |
| opentofu | 1.12.6 |
| tflint | 0.64.0 |
| trivy | 0.74.0 |
| terraform-docs | 0.24.0 |
| conftest | 0.69.0 |
| infracost | 0.10.45 |

Pin your versions in `mise.toml` for reproducible runs, and so local hooks
match CI.

## PR comments

Each root module and environment gets **one comment per PR**, edited in
place by every run.

- **Contents:** the plan summary (plus the policy and cost sections when
  enabled) and where the apply stands:
  - awaiting approval
  - applying after merge
  - blocked by policy
  - applied, and who approved it
  - failed
- **History:** earlier versions stay in the comment's edit history, and each
  run's summary stays on its run page.
- **Out-of-order runs:** a run for an outdated PR head leaves the comment
  alone, so a slow older run can't overwrite a newer plan.
- **Size:** plan output is truncated to fit GitHub's comment size limit; the
  full plan is always in the run log.
- **Author:** only comments by `github-actions[bot]` are edited. If you post
  with a GitHub App token instead, set the action's `comment-author`.

## Security notes

- **Plans hold state.** A plan file embeds the configuration and a copy of
  the state. Anyone signed in can download artifacts of a public repository.
  Keep secrets out of state, or encrypt plans and state with OpenTofu's
  native encryption: pass `TF_ENCRYPTION` through `env-vars`.
- **Least privilege.** validate never gets cloud credentials. Plan and apply
  can use different identities (environment-scoped variables, or
  `apply-azure-client-id`). Apply credentials only exist after approval.
- **Private repositories.** The default `GITHUB_TOKEN` can only read the
  calling repository. Pass a token that can read the others as
  `modules-token`.
- **Fork PRs** are validated but never planned: they get no OIDC token or
  secrets. A maintainer can push the branch to the repository to plan it.

## Coming from the Azure DevOps templates

<!-- markdownlint-disable MD013 -->

| Azure DevOps (`pipeline-templates`) | Here |
| --- | --- |
| `opentofu-pipeline.yml` stages Test / Plan / Apply | validate / plan / apply jobs of one reusable workflow |
| `requireFormatCheck`, `requireLintCheck`, ... | `fmt`, `tflint`, `trivy`, `docs`, `tests`, ... |
| `includeTest: false` | Turn the checks off (see the multi-environment example) |
| `apply` parameter | `apply` input |
| Environment approval on the deployment job | `apply-environment` with required reviewers |
| `azureServiceConnection` / `applyAzureServiceConnection` | `azure-client-id` / `apply-azure-client-id`, or environment-scoped `AZURE_CLIENT_ID` |
| `PLAN_HAS_CHANGES` gating the Apply stage | `has-changes` gating the apply job |
| `tfplan_<env>` pipeline artifact | `tofu-plan-<stack>-<env>` artifact, SHA-256 checked before apply |
| PR thread with a reply per run | One comment per module/environment, edited in place |
| `enableConftest`, `conftestPolicyPath` | `policy`, `policy-path` / `policy-source` |
| `enableInfracost`, `infracostApiKey` | `cost-estimate`, `infracost-api-key` secret |
| `planDependsOn: Apply_dev` | `needs: dev` between two calls |
| Multi-root discover + matrix | A matrix over the reusable workflow call |
| ResultGate stage | `result` job |

<!-- markdownlint-enable MD013 -->

Not ported yet: drift detection (a scheduled plan that opens an issue) and
automatic root-module discovery.
