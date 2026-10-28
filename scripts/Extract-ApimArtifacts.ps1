#Requires -Version 7.0
<#
.SYNOPSIS
Extract APIM artifacts using the globally installed APIOps CLI.
.DESCRIPTION
Accepts an optional CLI filter, including workspace filters. Explicit target
parameters override environment variables. Relative paths use the caller's directory;
the default artifact path is src/APIM in this repository. No azd dependency.
.EXAMPLE
./scripts/Extract-ApimArtifacts.ps1 -SubscriptionId <id> -ResourceGroupName <rg> -ServiceName <apim>
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string] $ResourceGroupName = $env:AZURE_RESOURCE_GROUP_NAME,
    [string] $ServiceName = $env:API_MANAGEMENT_SERVICE_NAME,
    [string] $ArtifactPath = (Join-Path $PSScriptRoot '../src/APIM'),
    [string] $FilterPath,
    [switch] $NoTransitive
)

$ErrorActionPreference = 'Stop'
foreach ($parameterName in 'SubscriptionId', 'ResourceGroupName', 'ServiceName', 'ArtifactPath') {
    if ([string]::IsNullOrWhiteSpace((Get-Variable $parameterName -ValueOnly))) {
        throw "Specify -$parameterName or its documented environment variable."
    }
}
if (-not (Get-Command apiops -ErrorAction SilentlyContinue)) {
    throw 'Install APIOps CLI first: npm install --global @azure-tools/apiops-cli@1.0.5'
}

$ArtifactPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactPath)
if ((Test-Path -LiteralPath $ArtifactPath) -and -not (Test-Path -LiteralPath $ArtifactPath -PathType Container)) {
    throw "ArtifactPath must be a directory: $ArtifactPath"
}
$cliArguments = @(
    'extract', '--subscription-id', $SubscriptionId,
    '--resource-group', $ResourceGroupName, '--service-name', $ServiceName
)
if ($FilterPath) {
    if (-not (Test-Path -LiteralPath $FilterPath -PathType Leaf)) {
        throw "Filter file not found: $FilterPath"
    }
    $cliArguments += @('--filter', (Resolve-Path -LiteralPath $FilterPath).Path)
}
if ($NoTransitive) { $cliArguments += '--no-transitive' }

$stagingPath = Join-Path ([System.IO.Path]::GetTempPath()) "apim-extract-$([guid]::NewGuid())"
try {
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    Write-Host "Extracting $SubscriptionId / $ResourceGroupName / $ServiceName"
    & apiops @cliArguments --output $stagingPath
    if ($LASTEXITCODE -ne 0) {
        throw "APIOps extraction failed with exit code $LASTEXITCODE. Existing artifacts were not updated."
    }
    New-Item -ItemType Directory -Path $ArtifactPath -Force | Out-Null
    Get-ChildItem -LiteralPath $stagingPath -Force |
        Copy-Item -Destination $ArtifactPath -Recurse -Force
    Write-Host "Artifacts updated in $ArtifactPath"
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}