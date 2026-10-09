# Test fixtures

What the CI workflow runs the reusable workflows against, so every PR tests
the workflows and actions end to end, the way consumers use them. None needs
a cloud account: the OpenTofu ones only touch local state, and the Data
Factory and Synapse ones are built (offline) and planned without what-if,
and the SQL project one is built and planned against a baseline dacpac.

- [`opentofu/basic`](opentofu/basic/): a root module deployed three times,
  once per var file in `deployments/` (`dev`, `prod` and `staging-eu`), each
  choosing its own state file through a variable in the backend block. CI
  calls the workflow once per deployment: `dev` with every check and the
  policy, `prod` plan only with the policy pulled from a URL, `staging-eu`
  in the `staging` environment with checks off and change detection on. It
  has a unit test, TFLint/Trivy/terraform-docs config, and a child module,
  `modules/label`.
- [`opentofu/minimal`](opentofu/minimal/): a root module without var files,
  providers or a lock file. It pins fewer tools than `basic` (no
  terraform-docs, so its call turns `docs` off).
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
- [`sqlproject/basic`](sqlproject/basic/): an SDK-style SQL project
  (`Microsoft.Build.Sql` 2.2.0) with two tables, a view, a refactorlog that
  renames a column, an SQLCMD variable and pre- and post-deployment
  scripts. `deployments/dev.publish.xml` and `prod.publish.xml` name fake
  servers that are never contacted: CI plans them offline against
  `ci/baseline.dacpac`, the project as it was before (rebuild it with
  `tests/sqlproject/make-baseline.sh`), in additive and truth mode.
  `ci/engine.publish.xml` is for the engine test, which publishes it to a
  SQL Server container.
