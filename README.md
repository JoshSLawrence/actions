# actions

A library of reusable GitHub Actions workflows and composite actions.

## Catalog

<!-- markdownlint-disable MD013 -->

| Name | Kind | Does |
| --- | --- | --- |
| [OpenTofu](opentofu/README.md) | Reusable workflow + composite actions | Validate, test, lint, scan, plan, and apply OpenTofu, with plan/apply PR comments and approval-gated applies |

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
      working-directory: infra
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

## Versioning

Releases are tagged `vX.Y.Z`, and a major-version tag (`v1`) moves to the
latest release of that major version:

- `@v1` gets fixes and new features, but no breaking changes.
- `@vX.Y.Z`, or better a full commit SHA (with a `# vX.Y.Z` comment for
  Dependabot), pins exactly.

Workflows refer to their sibling actions with GitHub's self-repository
syntax (`uses: $/...`), so whatever ref you pin, the workflow and the
actions it calls always come from the same commit. That syntax needs GitHub
Actions runner 2.336.0 or newer; GitHub-hosted runners always qualify.

This repository must be public, or, if private, its Actions access setting
must allow the repositories that use it (Settings -> Actions -> General ->
Access).

## Layout

```text
actions/
├── .github/
│   ├── actionlint.yaml       # temporary: actionlint doesn't know `$/` yet
│   ├── dependabot.yml
│   └── workflows/
│       ├── ci.yaml           # lint + end-to-end test of the workflows
│       └── opentofu.yaml     # reusable workflow
├── examples/                 # caller workflows to copy from
├── mise.toml                 # tool versions for local hooks and CI
├── opentofu/
│   ├── apply/                # composite actions, one per directory
│   ├── checks/
│   ├── plan/
│   ├── pr-comment/
│   ├── README.md
│   ├── scripts/              # the logic; actions are thin wrappers
│   └── setup/
└── tests/
    └── fixtures/             # modules CI runs the workflows against
```

## Development

```bash
mise install
pre-commit install
pre-commit run --all-files
```

Every hook also runs in CI (`Lint`), alongside end-to-end runs of the
reusable workflow against [`tests/fixtures/`](tests/fixtures/) (`E2E`).
See [AGENTS.md](AGENTS.md) for conventions.
