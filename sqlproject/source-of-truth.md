# Projects as the source of truth

Practical guidance for treating an SDK-style SQL project
(`Microsoft.Build.Sql` 2.x, as created by the VS Code SQL Database Projects
extension or `dotnet new sqlproj`) as the definition of a database, deployed
by the [SQL project workflows](README.md). Every point below was checked
against `Microsoft.Build.Sql` 2.2.0, SqlPackage 170.5.96 and SQL Server.

## Contents

- [1. Additive or truth](#1-additive-or-truth)
- [2. What truth mode drops, and what it keeps](#2-what-truth-mode-drops-and-what-it-keeps)
- [3. Renames: the refactorlog](#3-renames-the-refactorlog)
- [4. Pre- and post-deployment scripts](#4-pre--and-post-deployment-scripts)
- [5. Reference data](#5-reference-data)
- [6. Changes that would lose data](#6-changes-that-would-lose-data)
- [7. SQLCMD variables per environment](#7-sqlcmd-variables-per-environment)
- [8. Publish profiles](#8-publish-profiles)
- [9. Security objects](#9-security-objects)
- [10. Build-time checks](#10-build-time-checks)
- [11. Testing a dacpac locally](#11-testing-a-dacpac-locally)

## 1. Additive or truth

The workflow has two deploy modes (`deploy-mode`):

- `additive` (the default) never drops anything that is not in the project.
  The plan lists what it keeps.
- `truth` drops what is not in the project, except `keep-object-types`.

Start **additive** on an existing database:

1. Bring the database into a project. To start from an existing database,
   extract it into a folder, one file per object, then add the `.sqlproj`
   (the SDK's README describes this):

   ```bash
   sqlpackage /Action:Extract /SourceConnectionString:"<connection string>" \
     /TargetFile:./database /p:ExtractTarget=SchemaObjectType
   ```

2. Deploy additively. Read the **Kept: in the database, not in the project**
   list in each plan: it is exactly what `truth` mode would drop.
3. Bring those objects into the project, or drop them deliberately (in a
   reviewed change).
4. When the list is empty, or only holds what you want to keep, switch to
   `truth` with a one-line change to the calling workflow. The switch is
   reviewed like any other: its first plan shows every drop.

Staying additive is also a choice. It is the safe one when other teams or
tools create objects in the same database.

## 2. What truth mode drops, and what it keeps

`truth` publishes with `DropObjectsNotInSource=True`: everything in the
database that is not in the project is dropped, except the object types in
`keep-object-types` (SqlPackage's `DoNotDropObjectTypes`). The default list
is `Users`, `Logins`, `DatabaseRoles`, `ApplicationRoles`, `RoleMembership`,
`ServerRoles`, `ServerRoleMembership`, `Permissions`, `Credentials`,
`DatabaseScopedCredentials` and `MasterKeys`: what DBA tooling usually
manages outside a project. An unknown name fails the plan ("The property
DoNotDropObjectTypes ... invalid value").

- A dropped **table or column** is possible data loss, so the plan is
  blocked unless `allow-data-loss` is on (whether or not the table has
  rows).
- Views, procedures, functions, indexes and constraints drop **without an
  alert**: read the plan's Changes table before approving.
- Change the list when your DBAs manage more: add `Indexes` if they tune
  indexes. An empty list drops everything not in the project.

## 3. Renames: the refactorlog

Without help, SqlPackage sees a rename as a drop and a create, and loses the
data. A `*.refactorlog` file (a `RefactorLog` item in the project) records
the rename, and the plan shows `Rename`, scripted as `sp_rename` and
recorded in `dbo.__RefactorLog`, with no data loss.

Visual Studio writes the entry when you rename in the IDE. If your editor
does not, add it by hand. The entry is a `Rename Refactor` operation, and
the file's namespace matters: with another namespace the build succeeds but
the operations are silently left out of the dacpac.

```xml
<?xml version="1.0" encoding="utf-8"?>
<Operations Version="1.0" xmlns="http://schemas.microsoft.com/sqlserver/dac/Serialization/2012/02">
  <Operation Name="Rename Refactor" Key="3b6a8a1e-5a0e-4a64-9a43-6a3f2f0c1d11" ChangeDateTime="10/09/2026 12:00:00">
    <Property Name="ElementName" Value="[dbo].[Widget].[Title]" />
    <Property Name="ElementType" Value="SqlSimpleColumn" />
    <Property Name="ParentElementName" Value="[dbo].[Widget]" />
    <Property Name="ParentElementType" Value="SqlTable" />
    <Property Name="NewName" Value="Name" />
  </Operation>
</Operations>
```

Reference it in the `.sqlproj`:

```xml
<ItemGroup>
  <RefactorLog Include="basic.refactorlog" />
</ItemGroup>
```

The test fixture has a working example:
[`basic.refactorlog`](../tests/fixtures/sqlproject/basic/basic.refactorlog).
Give every operation a new GUID `Key`. **Never edit or remove applied
entries:** each database remembers the keys it has applied.

## 4. Pre- and post-deployment scripts

A project has at most one of each: `PreDeploy` and `PostDeploy` items,
written in SQLCMD syntax, with `:r .\other.sql` to split them. The pre script
runs before the schema changes, the post script after, **on every publish**,
so make them idempotent.

A deployment report never shows them, so the workflow decides whether they
make a plan a change: see `deployment-scripts` in the [README](README.md#deployment-scripts).
By default they count when they differ from the base commit's build (what is
deployed); `always` makes every plan of a project with scripts a change.

## 5. Reference data

Fill lookup tables from the post-deployment script with a `MERGE`, so the
data converges whatever state the table is in (the fixture's
[post-deployment script](../tests/fixtures/sqlproject/basic/Scripts/Script.PostDeployment.sql)):

```sql
MERGE INTO [dbo].[Status] AS target
USING (VALUES (1, N'new'), (2, N'active'), (3, N'retired')) AS source ([Code], [Label])
ON target.[Code] = source.[Code]
WHEN MATCHED AND target.[Label] <> source.[Label] THEN
    UPDATE SET [Label] = source.[Label]
WHEN NOT MATCHED BY TARGET THEN
    INSERT ([Code], [Label]) VALUES (source.[Code], source.[Label]);
```

Or guard each insert with `IF NOT EXISTS`. Never use an unconditional
`INSERT`: it runs again with the next publish.

## 6. Changes that would lose data

Use **expand and contract** instead of a destructive change:

1. Add the new column (or table), nullable or with a default.
2. Backfill it in a post-deployment script.
3. Switch the readers and writers.
4. Drop the old column in a later PR, with the data-loss override because it
   holds data.

Use the refactorlog for renames. What `allow-data-loss` does: the plan
passes, and the publish runs with `BlockOnPossibleDataLoss=False`, so
SqlPackage does not abort on rows. What it does not do: skip the review or
the approval. A caller can tie it to a PR label (e.g. `sql-allow-data-loss`)
so the person who asks is visible, and the environment's reviewers still
approve each apply.

## 7. SQLCMD variables per environment

Declare the variable in the project (a `SqlCmdVariable` item with a
`DefaultValue`), and set its value per environment in each profile:

```xml
<ItemGroup>
  <SqlCmdVariable Include="Environment">
    <Value>prod</Value>
  </SqlCmdVariable>
</ItemGroup>
```

or with the workflow's `variables` input (`Environment={deployment}`).
Scripts use `$(Environment)`. Variables are in the generated script and the
plan comment: **not for secrets**. A profile only sets variables if its root
element has the MSBuild namespace (the next section).

## 8. Publish profiles

One `deployments/<name>.publish.xml` per environment. What goes in:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <TargetDatabaseName>sqldb-prod-core</TargetDatabaseName>
    <TargetConnectionString>Data Source=sql-prod-core.database.windows.net;Encrypt=True</TargetConnectionString>
    <IncludeTransactionalScripts>True</IncludeTransactionalScripts>
    <ScriptDatabaseOptions>False</ScriptDatabaseOptions>
  </PropertyGroup>
</Project>
```

- `TargetDatabaseName` and a credential-free `TargetConnectionString` (the
  server; CI signs in with Entra ID).
- `IncludeTransactionalScripts=True` makes a publish all-or-nothing where
  SQL Server allows.
- `ScriptDatabaseOptions=False` when infrastructure code owns the database's
  settings, or every plan reports them as differences.
- `CommandTimeout` for long statements.
- The `xmlns` is required: SqlPackage ignores the properties and variables
  of a profile without it, and the workflow refuses the file.

The workflow refuses credentials, `CreateNewDatabase=True`, and the
properties its inputs own (`BlockOnPossibleDataLoss`,
`DropObjectsNotInSource`, `DoNotDropObjectTypes`). The same file works for a
local publish from VS Code.

## 9. Security objects

Users, logins, role membership and permissions managed by other tooling are
kept by default (section 2). Roles and grants that the application's schema
needs can live in the project: the keep list never stops the project's own
objects from deploying; it only keeps the ones others created.

## 10. Build-time checks

- `RunSqlCodeAnalysis=True` runs the built-in rules, e.g. `SR0001`
  (`SELECT *`) as warnings.
- `SqlCodeAnalysisRules` sets a rule's severity: `+!Microsoft.Rules.Data.SR0001`
  makes it an error that fails the build, `-Microsoft.Rules...` turns one
  off.
- `TreatTSqlWarningsAsErrors=True` applies to T-SQL (`SQL7xxxx`) warnings
  only: it does not promote code analysis warnings.
- `SuppressTSqlWarnings` takes the numbers to ignore.
- References to other databases or system objects: a `PackageReference` to
  the matching `Microsoft.SqlServer.Dacpacs.*` package, or an
  `ArtifactReference` to a dacpac.

The workflow does not build with `-warnaserror`: the SDK warns whenever a
newer `Microsoft.Build.Sql` exists.

## 11. Testing a dacpac locally

- `dotnet build` the project; the dacpac is in `bin/`.
- Compare two builds offline, without a server: `DeployReport` and `Script`
  accept a dacpac as the target:

  ```bash
  sqlpackage /Action:DeployReport /SourceFile:new.dacpac \
    /TargetFile:old.dacpac /TargetDatabaseName:x /OutputPath:report.xml
  sqlpackage /Action:Script /SourceFile:new.dacpac \
    /TargetFile:old.dacpac /TargetDatabaseName:x /OutputPath:script.sql
  ```

- Publish to a local container (`mcr.microsoft.com/mssql/server:2022-latest`,
  or `azure-sql-edge` on Apple silicon), with
  `/p:AllowIncompatiblePlatform=True` for an Azure SQL project.
- Or run the workflow's own scripts with `SQL_AUTH=sql`, `SQL_USER` and
  `SQL_PASSWORD` against the container (see the
  [README](README.md#composite-actions)).
