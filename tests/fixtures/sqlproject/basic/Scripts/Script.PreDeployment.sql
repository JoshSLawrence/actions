-- Runs before the schema changes, on every publish: keep it idempotent.
PRINT N'Deploying to $(Environment)';
