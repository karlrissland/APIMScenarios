#Requires -Version 7.0
<#
.SYNOPSIS
Publish APIM artifacts using the selected azd environment's outputs and settings.
.DESCRIPTION
Invoked by the root postdeploy hook. Relative artifact, filter and override paths
are resolved from the repository root. The standalone publisher remains azd-free.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$publishParameters = @{
    SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
    ResourceGroupName = $env:AZURE_RESOURCE_GROUP_NAME
    ServiceName = $env:API_MANAGEMENT_SERVICE_NAME
}
foreach ($setting in @{
    ArtifactPath = 'APIM_ARTIFACT_PATH'
    FilterPath = 'APIM_FILTER_PATH'
    OverridesPath = 'APIM_OVERRIDES_PATH'
    FunctionAppName = 'FUNCTION_SERVICE_NAME'
    FunctionBackendUrl = 'FUNCTION_BACKEND_URL'
}.GetEnumerator()) {
    $value = [Environment]::GetEnvironmentVariable($setting.Value)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $publishParameters[$setting.Key] = $value
    }
}
foreach ($setting in @{
    DryRun = 'APIM_PUBLISH_DRY_RUN'
    NoTransitive = 'APIM_NO_TRANSITIVE'
}.GetEnumerator()) {
    $value = [Environment]::GetEnvironmentVariable($setting.Value)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $booleanValue = $false
        if (-not [bool]::TryParse($value, [ref] $booleanValue)) {
            throw "$($setting.Value) must be true or false."
        }
        $publishParameters[$setting.Key] = $booleanValue
    }
}

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & (Join-Path $PSScriptRoot 'Publish-ApimArtifacts.ps1') @publishParameters
}
finally {
    Pop-Location
}