# actions

[![CI](https://github.com/JoshSLawrence/actions/actions/workflows/ci.yaml/badge.svg)](https://github.com/JoshSLawrence/actions/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A library of reusable GitHub Actions workflows and composite actions.

## Catalog

<!-- markdownlint-disable MD013 -->

| Name | Kind | Does |
| --- | --- | --- |
| [OpenTofu](opentofu/README.md) | Reusable workflows + composite actions | Validate, test, lint, scan, plan and approval-gated apply for one root module, a monorepo, or a config deployed with many `.tfvars` files; PR comments; drift detection with issues |
| [Data Factory](datafactory/README.md) | Reusable workflows + composite actions | Validate and export a factory's Git folder to an ARM template on every PR (no Publish, no `adf_publish`), what-if plans per environment, approval-gated deploys with trigger handling; PR comments |
| [Synapse](synapse/README.md) | Reusable workflows + composite actions | The same for a Synapse workspace's artifacts (no `workspace_publish`), deployed with GitHub OIDC; PR comments |

<!-- markdownlint-enable MD013 -->

## Usage

Reference a reusable workflow from a job:

```yaml
jobs:
  opentofu:
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v0.0.1
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      search-root: infra
      apply-environment: production
```

Or reference a composite action from a step:

```yaml
- uses: JoshSLawrence/actions/opentofu/plan@v0.0.1
  with:
    working-directory: infra
```

Each entry's README has its inputs, the setup it needs, and examples.
Complete caller workflows are in [`examples/`](examples/).

## Principles

1. **mise** installs every tool, at the versions each project pins.
2. **No inline scripts in YAML.** A `run:` step runs one script, where the
   logic can be read, shellchecked and run locally. A pre-commit hook
   enforces this.
3. **Easy to follow beats early abstraction.**
4. **Stay DRY** with shared helpers and shared actions, as long as that
   doesn't make the code harder to follow.

## Versioning

This project is in pre-release (`v0.x.x`). Breaking changes may occur
between minor versions. Once stable, it will move to `v1.0.0`.

Releases are tagged `vX.Y.Z`. Pin to a specific version or use a full commit
SHA (with a `# vX.Y.Z` comment for Dependabot) for stability.

Workflows refer to their sibling workflows and actions with GitHub's
self-repository syntax (`uses: $/...`). Whatever ref you pin, everything
therefore comes from the same commit. That syntax needs GitHub Actions
runner 2.336.0 or newer; GitHub-hosted runners always qualify.

This repository is public and available for use in any workflow.

## Layout

```text
actions/
├── .github/
│   ├── actionlint.yaml       # temporary: actionlint doesn't know `$/` yet
│   ├── dependabot.yml
│   ├── scripts/              # this repository's own checks (lint, sync)
│   └── workflows/
│       ├── ci.yaml           # lint + end-to-end runs of the workflows
│       ├── datafactory-deploy.yaml
│       ├── datafactory.yaml
│       ├── opentofu-config.yaml
│       ├── opentofu-deploy.yaml
│       ├── opentofu-drift.yaml
│       ├── opentofu.yaml
│       ├── synapse-deploy.yaml
│       └── synapse.yaml
├── datafactory/              # build, deployments, plan, apply, scripts/
├── examples/                 # caller workflows to copy from
├── mise.toml                 # tool versions for local hooks and CI lint
├── opentofu/
│   ├── apply/                # composite actions, one per directory
│   ├── checks/
│   ├── deployments/
│   ├── discover/
│   ├── drift-report/
│   ├── plan/
│   ├── pr-comment/
│   ├── README.md
│   ├── result/
│   ├── scripts/              # the logic; actions are thin wrappers
│   └── setup/
├── shared/
│   └── scripts/              # helpers every area uses (common.sh, arm.sh)
├── synapse/                  # build, deployments, plan, apply, scripts/
└── tests/
    └── fixtures/             # what CI runs the workflows against
```

## Development

```bash
mise install
pre-commit install
.github/scripts/lint.sh
```

CI runs the same hooks (`Lint`), plus end-to-end runs of the reusable
workflows against [`tests/fixtures/`](tests/fixtures/). See
[AGENTS.md](AGENTS.md) for conventions.
