# Test fixtures

Modules the CI workflow runs the reusable workflows against, so every PR
tests the workflows and actions end to end, the way consumers use them.

- [`opentofu/basic`](opentofu/basic/): a root module that needs no cloud
  account, with a unit test, TFLint/Trivy/terraform-docs config, and example
  conftest policies. CI runs it twice: once with every check plus policy and
  apply, and once plan-only with most checks off.
