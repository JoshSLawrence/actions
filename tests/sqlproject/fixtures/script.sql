/*
Deployment script for sqldb-fixture-dev
*/

GO
:setvar DatabaseName "sqldb-fixture-dev"

GO
PRINT N'Creating Table [dbo].[Status]...';

GO
CREATE TABLE [dbo].[Status] ([Code] INT NOT NULL PRIMARY KEY);

GO
