#!/usr/bin/env bash
#
# Rebuilds tests/fixtures/sqlproject/basic/ci/baseline.dacpac: the fixture
# project as it was before its latest changes, which CI plans against
# offline (target-dacpac). It has Widget with Id and Title (the refactorlog
# renames Title to Name), no WidgetNames view and no Status table, and an
# extra table, Extra, that the project doesn't have: additive plans list it
# as kept, truth plans drop it.
#
# Run it when the fixture's tools change (its mise.toml) or the dacpac needs
# to match a newer Microsoft.Build.Sql, and commit the result (a few KB):
#
#   tests/sqlproject/make-baseline.sh
#
# Needs mise, with the fixture's tools installable (dotnet).
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=shared/scripts/common.sh
source "$REPO_ROOT/shared/scripts/common.sh"

FIXTURE="$REPO_ROOT/tests/fixtures/sqlproject/basic"
ensure_mise

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log_step "Write the older project"
cp "$FIXTURE/mise.toml" "$WORK/mise.toml"
# The SDK version is the fixture's own, so the baseline moves with it
sdk_version="$(sed -n 's/.*<Sdk Name="Microsoft.Build.Sql" Version="\([^"]*\)".*/\1/p' "$FIXTURE/basic.sqlproj")"
[ -n "$sdk_version" ] || {
  log_error "Couldn't read the Microsoft.Build.Sql version from ${FIXTURE}/basic.sqlproj."
  exit 1
}
cat > "$WORK/basic.sqlproj" << XML
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build">
  <Sdk Name="Microsoft.Build.Sql" Version="${sdk_version}" />
  <PropertyGroup>
    <Name>basic</Name>
    <DSP>Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider</DSP>
    <ModelCollation>1033, CI</ModelCollation>
  </PropertyGroup>
</Project>
XML
echo 'CREATE TABLE [dbo].[Widget] ([Id] INT NOT NULL PRIMARY KEY, [Title] NVARCHAR (50) NOT NULL);' > "$WORK/Widget.sql"
echo 'CREATE TABLE [dbo].[Extra] ([Id] INT NOT NULL PRIMARY KEY);' > "$WORK/Extra.sql"

log_step "Build it"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DACFX_TELEMETRY_OPTOUT=1
(
  cd "$WORK"
  MISE_TRUSTED_CONFIG_PATHS="$WORK"
  export MISE_TRUSTED_CONFIG_PATHS
  log_cmd dotnet build basic.sqlproj -c Release -nologo -o out
  mise exec -- dotnet build basic.sqlproj -c Release -nologo -o out
)
cp "$WORK/out/basic.dacpac" "$FIXTURE/ci/baseline.dacpac"
log_success "Wrote ${FIXTURE}/ci/baseline.dacpac"
