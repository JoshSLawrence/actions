-- Runs after the schema changes, on every publish: keep it idempotent.
-- MERGE makes the reference data converge instead of piling up.
MERGE INTO [dbo].[Status] AS target
USING (VALUES (1, N'new'), (2, N'active'), (3, N'retired')) AS source ([Code], [Label])
ON target.[Code] = source.[Code]
WHEN MATCHED AND target.[Label] <> source.[Label] THEN
    UPDATE SET [Label] = source.[Label]
WHEN NOT MATCHED BY TARGET THEN
    INSERT ([Code], [Label]) VALUES (source.[Code], source.[Label]);
