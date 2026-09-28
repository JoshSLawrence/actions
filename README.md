# actions

A library of reusable GitHub Actions workflows and composite actions.

## Catalog

<!-- markdownlint-disable MD013 -->

| Name | Kind | Does |
| --- | --- | --- |
| [OpenTofu](opentofu/README.md) | Reusable workflows + composite actions | Validate, test, lint, scan, plan and approval-gated apply for one root module, a monorepo, or a config deployed with many `.tfvars` files; PR comments; drift detection with issues |

<!-- markdownlint-enable MD013 -->

## Usage

Reference a reusable workflow from a job:

```yaml
jobs:
  opentofu:
    uses: JoshSLawrence/actions/.github/workflows/opentofu.yaml@v1
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
- uses: JoshSLawrence/actions/opentofu/plan@v1
  with:
    working-directory: infra
```

Each entry's README has its inputs, the setup it needs, and examples.
Complete caller workflows are in [`examples/`](examples/).

## Principles

1. **mise** installs every tool, at the versions each project pins.
2. **OpenTofu**, not Terraform.
3. **No inline scripts in YAML.** A `run:` step runs one script, where the
   logic can be read, shellchecked and run locally. A pre-commit hook
   enforces this.
4. **Easy to follow beats early abstraction.**
5. **Stay DRY** with shared helpers (`common.sh`) and shared actions, as
   long as that doesn't make the code harder to follow.

## Versioning

Releases are tagged `vX.Y.Z`, and a major-version tag (`v1`) moves to the
latest release of that major version:

- `@v1` gets fixes and new features, but no breaking changes.
- `@vX.Y.Z`, or better a full commit SHA (with a `# vX.Y.Z` comment for
  Dependabot), pins exactly.

Workflows refer to their sibling workflows and actions with GitHub's
self-repository syntax (`uses: $/...`). Whatever ref you pin, everything
therefore comes from the same commit. That syntax needs GitHub Actions
runner 2.336.0 or newer; GitHub-hosted runners always qualify.

This repository must be public, or, if private, its Actions access setting
must allow the repositories that use it (Settings -> Actions -> General ->
Access).

## Layout

```text
actions/
├── .github/
│   ├── actionlint.yaml       # temporary: actionlint doesn't know `$/` yet
│   ├── dependabot.yml
│   ├── scripts/              # this repository's own checks (lint, sync)
│   └── workflows/
│       ├── ci.yaml           # lint + end-to-end runs of the workflows
│       ├── opentofu-config.yaml
│       ├── opentofu-deploy.yaml
│       ├── opentofu-drift.yaml
│       └── opentofu.yaml
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
└── tests/
    └── fixtures/             # root modules CI runs the workflows against
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
