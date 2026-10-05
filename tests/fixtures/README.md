# Test fixtures

What the CI workflow runs the reusable workflows against, so every PR tests
the workflows and actions end to end, the way consumers use them. None needs
a cloud account: the OpenTofu ones only touch local state, and the Data
Factory and Synapse ones are built (offline) and planned without what-if.

- [`opentofu/basic`](opentofu/basic/): a root module with three
  deployments, each a `deployments/<name>.yaml` choosing its own state file
  through a variable in the backend block:
  - `dev`, without a `.tfvars`: its variables are `TF_VAR_*` literals in its
    file;
  - `prod`, with `prod.tfvars`;
  - `staging-eu`, with `staging-eu.tfvars`, applying in `staging`. It
    declares a variable and a secret from that environment and a variable
    from the repository, so CI proves they resolve.

  `dev` and `prod` apply in `opentofu-fixture`. It has a unit test,
  TFLint/Trivy/terraform-docs config, and a child module, `modules/label`:
  changing it selects every deployment of `basic`.
- [`opentofu/minimal`](opentofu/minimal/): a root module without
  `deployments/`, providers or a lock file, deployed as is through its
  `deployment.yaml`. It pins fewer tools than `basic`.
- [`opentofu/minimal/nested`](opentofu/minimal/nested/): a root module
  nested inside `minimal`, with one deployment. Its changes select it, not
  `minimal`.
- [`opentofu/policy`](opentofu/policy/): example conftest policies shared by
  every root module.
- [`datafactory/basic`](datafactory/basic/): a factory's Git folder (a
  linked service, a pipeline, a stopped trigger) with two deployments,
  `deployments/dev.json` and `prod.json`. `pipeline/.keep` is deliberate:
  the build must leave out files that aren't `.json`. `ci/adf-githubtest.json`
  is a third deployment, kept apart from those, that CI deploys to a real
  factory.
- [`synapse/basic`](synapse/basic/): the same for a Synapse workspace, with
  a SQL script too.
