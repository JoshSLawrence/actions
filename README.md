# actions

[![CI](https://github.com/JoshSLawrence/actions/actions/workflows/ci.yaml/badge.svg?branch=main&event=push)](https://github.com/JoshSLawrence/actions/actions/workflows/ci.yaml?query=branch%3Amain+event%3Apush)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A library of reusable GitHub Actions workflows and composite actions.

## Catalog

<!-- markdownlint-disable MD013 -->

| Name | Kind | Does |
| --- | --- | --- |
| [OpenTofu](opentofu/README.md) | Reusable workflow | Checks, tests, plans and applies one root module per call, with its var files, in its environment, when a PR touches it; Azure OIDC or secrets; PR comments; approval-gated apply; providers cached across jobs |
| [OpenTofu drift](opentofu/README.md#drift-detection) | Reusable workflow | Plans one deployment on a schedule, never applying, and reports drift as a GitHub issue per deployment (updated in place, marked resolved when it's gone) |
| [Data Factory](datafactory/README.md) | Reusable workflows + composite actions | Validate and export a factory's Git folder to an ARM template on every PR (no Publish, no `adf_publish`), what-if plans per environment, approval-gated deploys with trigger handling; PR comments |
| [Synapse](synapse/README.md) | Reusable workflows + composite actions | The same for a Synapse workspace's artifacts (no `workspace_publish`), deployed with GitHub OIDC; PR comments |

<!-- markdownlint-enable MD013 -->

## Usage

Reference a reusable workflow from a job:

```yaml
jobs:
  opentofu:
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v0.3.0
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
    with:
      working-directory: iac/network
      var-files: prod.tfvars
      apply-environment: prod
```

Each entry's README has its inputs, the setup it needs, and examples. The
Data Factory and Synapse composite actions can also be used on their own;
OpenTofu's are internals of its workflow.
Complete caller workflows are in [`examples/`](examples/).

## Principles

1. **mise** installs every tool, at the versions each project pins.
2. **No inline scripts in YAML.** A `run:` step runs one script, where the
   logic can be read, shellchecked and run locally. A pre-commit hook
   enforces this.
3. **Easy to follow beats early abstraction.**
4. **Stay DRY** with the shared library (`shared/`), as long as that
   doesn't make the code harder to follow. Areas build on it but never on
   each other, so a change to one area can't break another.

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
│       ├── opentofu-drift.yaml
│       ├── opentofu.yaml
│       ├── synapse-deploy.yaml
│       └── synapse.yaml
├── arm/
│   └── scripts/              # what Data Factory and Synapse share (arm.sh)
├── datafactory/              # build, deployments, plan, apply, scripts/
├── docs/
│   └── design/               # design documents and their decisions
├── examples/                 # caller workflows to copy from
├── mise.toml                 # tool versions for local hooks and CI lint
├── opentofu/
│   ├── apply/                # composite actions, one per directory
│   ├── azure/
│   ├── checks/
│   ├── drift-report/
│   ├── plan/
│   ├── prepare/
│   ├── provider-cache/
│   ├── README.md
│   └── scripts/              # the logic; actions are thin wrappers
├── shared/                   # the library every area builds on
│   ├── pr-comment/           # composite actions every area uses
│   ├── result/
│   ├── scripts/              # common.sh and generic steps
│   └── setup/
├── synapse/                  # build, deployments, plan, apply, scripts/
└── tests/
    ├── fixtures/             # what CI runs the workflows against
    └── opentofu/             # OpenTofu script tests
```

## Development

```bash
mise install
pre-commit install
.github/scripts/lint.sh
```

CI runs the same hooks (`Lint`), plus end-to-end runs of the reusable
workflows against [`tests/fixtures/`](tests/fixtures/). See
[CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) for conventions.
