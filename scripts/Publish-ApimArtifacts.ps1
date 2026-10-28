#Requires -Version 7.0
<#
.SYNOPSIS
Publish APIM artifacts using the globally installed APIOps CLI.
.DESCRIPTION
Publishes current files, including uncommitted edits, without destructive deletion.
Pass CLI-compatible filters and overrides explicitly; legacy token replacement is
not performed. Relative paths use the caller's directory; the default artifact path
is src/APIM in this repository. No azd dependency. When the reserved demo-function
backend is present, specify FunctionAppName and FunctionBackendUrl. Azure CLI reads
the target host key; only a temporary artifact copy contains that key. Explicit
CLI overrides are applied afterward and remain the caller's responsibility.
.EXAMPLE
./scripts/Publish-ApimArtifacts.ps1 -SubscriptionId <id> -ResourceGroupName <rg> -ServiceName <apim> -DryRun
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string] $ResourceGroupName = $env:AZURE_RESOURCE_GROUP_NAME,
    [string] $ServiceName = $env:API_MANAGEMENT_SERVICE_NAME,
    [string] $ArtifactPath = (Join-Path $PSScriptRoot '../src/APIM'),
    [string] $FilterPath,
    [string] $OverridesPath,
    [string] $FunctionAppName,
    [string] $FunctionBackendUrl,
    [string] $FunctionResourceGroupName = $ResourceGroupName,
    [switch] $NoTransitive,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
foreach ($parameterName in 'SubscriptionId', 'ResourceGroupName', 'ServiceName') {
    if ([string]::IsNullOrWhiteSpace((Get-Variable $parameterName -ValueOnly))) {
        throw "Specify -$parameterName or its documented environment variable."
    }
}
if (-not (Get-Command apiops -ErrorAction SilentlyContinue)) {
    throw 'Install APIOps CLI first: npm install --global @azure-tools/apiops-cli@1.0.5'
}
if (-not $ArtifactPath -or -not (Test-Path -LiteralPath $ArtifactPath -PathType Container)) {
    throw "Artifact directory not found: $ArtifactPath"
}
$cliArguments = @(
    'publish', '--subscription-id', $SubscriptionId,
    '--resource-group', $ResourceGroupName, '--service-name', $ServiceName,
    '--source', (Resolve-Path -LiteralPath $ArtifactPath).Path
)
foreach ($fileParameter in @{ '--filter' = $FilterPath; '--overrides' = $OverridesPath }.GetEnumerator()) {
    if ($fileParameter.Value) {
        if (-not (Test-Path -LiteralPath $fileParameter.Value -PathType Leaf)) {
            throw "Configuration file not found: $($fileParameter.Value)"
        }
        $cliArguments += @($fileParameter.Key, (Resolve-Path -LiteralPath $fileParameter.Value).Path)
    }
}
if ($NoTransitive) { $cliArguments += '--no-transitive' }
if ($DryRun) { $cliArguments += '--dry-run' }

$sourcePath = (Resolve-Path -LiteralPath $ArtifactPath).Path
$scopePaths = @($sourcePath)
$workspacesPath = Join-Path $sourcePath 'workspaces'
if (Test-Path -LiteralPath $workspacesPath -PathType Container) {
    $scopePaths += @(Get-ChildItem -LiteralPath $workspacesPath -Directory | Select-Object -ExpandProperty FullName)
}
$functionScopes = @()
if ($FunctionAppName -or $FunctionBackendUrl) {
    $functionScopes = @($scopePaths | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'backends/demo-function/backendInformation.json') -PathType Leaf
    })
}
if ($functionScopes.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($FunctionAppName) -or [string]::IsNullOrWhiteSpace($FunctionResourceGroupName)) {
        throw 'The demo-function backend requires -FunctionAppName and its -FunctionResourceGroupName (defaults to the APIM resource group).'
    }
    $backendUri = $null
    if (-not [uri]::TryCreate($FunctionBackendUrl, [UriKind]::Absolute, [ref] $backendUri) -or
        $backendUri.Scheme -ne 'https' -or $backendUri.AbsolutePath.TrimEnd('/') -ne '/api' -or
        $backendUri.Query -or $backendUri.Fragment -or $backendUri.UserInfo) {
        throw 'Specify -FunctionBackendUrl as the target Function HTTPS base URL ending in /api, without credentials or a query string.'
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Install Azure CLI and sign in using az login to resolve the target Function key.'
    }
    foreach ($scopePath in $functionScopes) {
        if (-not (Test-Path -LiteralPath (Join-Path $scopePath 'namedValues/demo-function-key/namedValueInformation.json') -PathType Leaf)) {
            throw "The demo-function backend is missing its demo-function-key named value in $scopePath."
        }
    }
}

$previousCommitId = $env:COMMIT_ID
$stagingPath = $null
try {
    $env:COMMIT_ID = $null
    if ($functionScopes.Count -gt 0) {
        $functionKey = & az functionapp keys list --subscription $SubscriptionId --resource-group $FunctionResourceGroupName --name $FunctionAppName --query functionKeys.default --output tsv --only-show-errors
        if ($LASTEXITCODE -ne 0 -or $functionKey -is [array] -or
            [string]::IsNullOrWhiteSpace($functionKey) -or $functionKey -eq 'null') {
            throw 'Could not read the target Function default host key. Check Azure CLI authentication, permissions and Function deployment.'
        }
        $stagingPath = Join-Path ([IO.Path]::GetTempPath()) "apim-publish-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $stagingPath | Out-Null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($stagingPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        Get-ChildItem -LiteralPath $sourcePath -Force | Copy-Item -Destination $stagingPath -Recurse -Force
        foreach ($scopePath in $functionScopes) {
            $relativeScope = [IO.Path]::GetRelativePath($sourcePath, $scopePath)
            $stagedScope = Join-Path $stagingPath $relativeScope
            $backendPath = Join-Path $stagedScope 'backends/demo-function/backendInformation.json'
            $backend = Get-Content -LiteralPath $backendPath -Raw | ConvertFrom-Json -AsHashtable
            $backend.properties.url = $FunctionBackendUrl.TrimEnd('/')
            $backend.properties.Remove('resourceId')
            $backend.properties.credentials = @{ header = @{ 'x-functions-key' = @('{{demo-function-key}}') } }
            $backend | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $backendPath
            $namedValuePath = Join-Path $stagedScope 'namedValues/demo-function-key/namedValueInformation.json'
            $namedValue = Get-Content -LiteralPath $namedValuePath -Raw | ConvertFrom-Json -AsHashtable
            $namedValue.properties.Remove('keyVault')
            $namedValue.properties.secret = $true
            $namedValue.properties.displayName = 'demo-function-key'
            $namedValue.properties.value = $functionKey.Trim()
            $namedValue | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $namedValuePath
        }
        $cliArguments[([array]::IndexOf($cliArguments, '--source') + 1)] = $stagingPath
    }
    Write-Host "Publishing to $SubscriptionId / $ResourceGroupName / $ServiceName"
    & apiops @cliArguments
    if ($LASTEXITCODE -ne 0) {
        throw "APIOps publishing failed with exit code $LASTEXITCODE. Azure may contain partial changes."
    }
}
finally {
    $env:COMMIT_ID = $previousCommitId
    $functionKey = $null
    if ($stagingPath -and (Test-Path -LiteralPath $stagingPath)) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}