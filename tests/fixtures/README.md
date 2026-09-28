# Test fixtures

Root modules the CI workflow runs the reusable workflows against, so every
PR tests the workflows and actions end to end, the way consumers use them.
None needs a cloud account: they only touch local state.

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
