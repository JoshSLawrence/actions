/*
Deployment script for sqldb-fixture-dev
*/

GO
:setvar DatabaseName "sqldb-fixture-dev"

GO
IF (DB_ID(N'$(DatabaseName)') IS NOT NULL)
    BEGIN
        PRINT N'exists';
    END
GO
CREATE DATABASE [$(DatabaseName)]
    COLLATE SQL_Latin1_General_CP1_CI_AS;

GO
