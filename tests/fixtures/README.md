# Test fixtures

What the CI workflow runs the reusable workflows against, so every PR tests
the workflows and actions end to end, the way consumers use them. None needs
a cloud account: the OpenTofu ones only touch local state, and the Data
Factory and Synapse ones are built (offline) and planned without what-if.

- [`opentofu/basic`](opentofu/basic/): a root module with two deployments
  (`deployments/dev.tfvars` and `prod.tfvars`, each with a `.tfbackend`
  choosing its own state file). It has a unit test,
  TFLint/Trivy/terraform-docs config, and uses the local module below.
- [`opentofu/minimal`](opentofu/minimal/): a root module without
  deployments, providers or a lock file. It pins fewer tools than `basic`.
- [`opentofu/modules/label`](opentofu/modules/label/): a local module (no
  `mise.toml`, so not a root module). Changing it selects `basic`.
- [`opentofu/policy`](opentofu/policy/): example conftest policies shared by
  both root modules.
- [`datafactory/basic`](datafactory/basic/): a factory's Git folder (a
  linked service, a pipeline, a stopped trigger) with two deployments,
  `deployments/dev.json` and `prod.json`. `pipeline/.keep` is deliberate:
  the build must leave out files that aren't `.json`. `ci/adf-githubtest.json`
  is a third deployment, kept apart from those, that CI deploys to a real
  factory.
- [`synapse/basic`](synapse/basic/): the same for a Synapse workspace, with
  a SQL script too.
