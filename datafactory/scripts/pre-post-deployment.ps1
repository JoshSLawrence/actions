<#
.SYNOPSIS
    Runs the PrePostDeploymentScript.ps1 that the Data Factory export
    generates, before or after the ARM deployment of a factory.
    datafactory/scripts/apply.sh calls it.

.DESCRIPTION
    pre:  stops the started triggers the deployment changes.
    post: deletes the resources that are no longer in the template, then
          starts the triggers the template marks Started.

    Microsoft's script needs the Az PowerShell modules. They're saved at the
    versions pinned below into a scratch directory (not the user's profile),
    and signed in with an access token from the az CLI session, so this uses
    the same (OIDC) login as the deployment itself and never stores it.

    Environment variables:
      AZURE_ACCESS_TOKEN    - ARM access token (required)
      AZURE_ACCOUNT_ID      - who the token is for, e.g. the client ID
                              (required)
      AZURE_TENANT_ID       - tenant (required)
      AZURE_SUBSCRIPTION_ID - subscription of the factory (required)
      AZ_MODULES_DIR        - where to save the modules (default:
                              $RUNNER_TEMP/az-powershell-modules)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('pre', 'post')] [string] $Phase,
    [Parameter(Mandatory)] [string] $TemplateDir,
    [Parameter(Mandatory)] [string] $ParametersFile,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $DataFactoryName
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Pinned so a module release can't change behaviour under you. Dependabot
# doesn't see these; bump them by hand now and then.
$modules = [ordered]@{
    'Az.Accounts'    = '5.5.3'
    'Az.Resources'   = '10.2.1'
    'Az.DataFactory' = '1.20.1'
}

foreach ($name in 'AZURE_ACCESS_TOKEN', 'AZURE_ACCOUNT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "$name is not set. datafactory/scripts/apply.sh sets it from the az CLI session; run that instead."
    }
}

$script = Join-Path $TemplateDir 'PrePostDeploymentScript.ps1'
if (-not (Test-Path $script)) {
    throw "No PrePostDeploymentScript.ps1 in $TemplateDir. It comes from the export (datafactory/build); set pre-post-script to false to deploy without it."
}

$root = $env:AZ_MODULES_DIR
if (-not $root) {
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $root = Join-Path $temp 'az-powershell-modules'
}
New-Item -ItemType Directory -Force -Path $root | Out-Null
$env:PSModulePath = $root + [IO.Path]::PathSeparator + $env:PSModulePath

# Dependencies are skipped because every module that matters is pinned
# here: otherwise saving Az.Resources would also fetch the latest Az.Accounts.
foreach ($name in $modules.Keys) {
    $version = $modules[$name]
    if (-not (Test-Path (Join-Path $root "$name/$version"))) {
        Write-Host "Saving $name $version from the PowerShell Gallery..."
        Save-PSResource -Name $name -Version $version -Repository PSGallery -TrustRepository `
            -SkipDependencyCheck -Path $root -Quiet
    }
    Import-Module $name -RequiredVersion $version
}

# Keep the token in this process only, and the output free of prompts
Disable-AzContextAutosave -Scope Process | Out-Null
Update-AzConfig -Scope Process -DisplayBreakingChangeWarning $false -DisplaySurveyMessage $false `
    -EnableLoginByWam $false | Out-Null
# Az.Accounts 5.x takes the token as a plain string
Connect-AzAccount -AccessToken $env:AZURE_ACCESS_TOKEN -AccountId $env:AZURE_ACCOUNT_ID `
    -Tenant $env:AZURE_TENANT_ID -Subscription $env:AZURE_SUBSCRIPTION_ID | Out-Null

Write-Host "Running the $Phase-deployment script for factory $DataFactoryName in $ResourceGroupName"
& $script -ArmTemplate (Join-Path $TemplateDir 'ARMTemplateForFactory.json') `
    -ArmTemplateParameters $ParametersFile `
    -ResourceGroupName $ResourceGroupName `
    -DataFactoryName $DataFactoryName `
    -PreDeployment ($Phase -eq 'pre') `
    -DeleteDeployment $false
