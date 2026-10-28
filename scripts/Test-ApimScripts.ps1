#Requires -Version 7.0
[CmdletBinding()]
param([switch] $AzdHooks, [switch] $Infrastructure, [switch] $GitHubWorkflows)

$ErrorActionPreference = 'Stop'
$extractScript = Join-Path $PSScriptRoot 'Extract-ApimArtifacts.ps1'
$publishScript = Join-Path $PSScriptRoot 'Publish-ApimArtifacts.ps1'
$azdPublishScript = Join-Path $PSScriptRoot 'Invoke-AzdPublish.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "apim-script-tests-$([guid]::NewGuid())"
$previousCommitId = $env:COMMIT_ID
$previousSubscriptionId = $env:AZURE_SUBSCRIPTION_ID
$previousAzdSettings = @{}
foreach ($name in 'AZURE_RESOURCE_GROUP_NAME', 'API_MANAGEMENT_SERVICE_NAME', 'APIM_ARTIFACT_PATH',
    'APIM_FILTER_PATH', 'APIM_OVERRIDES_PATH', 'APIM_NO_TRANSITIVE', 'APIM_PUBLISH_DRY_RUN',
    'FUNCTION_SERVICE_NAME', 'FUNCTION_BACKEND_URL', 'APIM_PUBLISHER_NAME', 'APIM_PUBLISHER_EMAIL') {
    $previousAzdSettings[$name] = [Environment]::GetEnvironmentVariable($name)
}
$global:ApimScriptTestState = @{
    ExitCode = 0
    Arguments = @()
    StagingPath = $null
    CommitId = $null
    AzureExitCode = 0
    AzureCalls = 0
    AzureArguments = @()
    PublishedSource = $null
    PublishedBackends = @()
    PublishedNamedValues = @()
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Fails([scriptblock] $Action, [string] $ExpectedMessage) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-True ($null -ne $failure) "Expected failure: $ExpectedMessage"
    Assert-True ($failure.Exception.Message -like "*$ExpectedMessage*") "Unexpected failure: $failure"
}

if ($Infrastructure) {
    if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
        throw 'Install Bicep CLI to run the optional infrastructure checks.'
    }
    $compiledFunction = bicep build (Join-Path $PSScriptRoot '../Infrastructure/functions.bicep') --stdout
    Assert-True ($LASTEXITCODE -eq 0) 'Function Bicep compilation failed.'
    $functionTemplate = $compiledFunction | ConvertFrom-Json
    $functionSite = $functionTemplate.resources | Where-Object type -eq 'Microsoft.Web/sites'
    $functionPlan = $functionTemplate.resources | Where-Object type -eq 'Microsoft.Web/serverfarms'
    $functionStorage = $functionTemplate.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts'
    $storageRoles = @($functionTemplate.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
    $deploymentContainer = $functionTemplate.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts/blobServices/containers'
    $flexConfig = $functionSite.properties.functionAppConfig
    Assert-True ($functionPlan.sku.name -eq 'FC1' -and $functionPlan.sku.tier -eq 'FlexConsumption' -and
        $functionPlan.properties.reserved) 'Expected a Linux Flex Consumption plan.'
    Assert-True ($functionTemplate.variables.siteName -like '*FuncApp-flex-*' -and
        $functionTemplate.variables.hostingPlanName -like '*hpn-flex-*') 'Flex migration must not update existing S1 resource names.'
    Assert-True ($flexConfig.runtime.name -eq 'python' -and $flexConfig.runtime.version -eq '3.14') 'Incorrect Flex Python runtime.'
    Assert-True ($flexConfig.deployment.storage.type -eq 'blobContainer' -and
        $flexConfig.deployment.storage.authentication.type -eq 'SystemAssignedIdentity' -and
        $flexConfig.deployment.storage.authentication.PSObject.Properties.Name -notcontains 'storageAccountConnectionStringName') 'Flex deployment storage must use managed identity, not a connection string.'
    Assert-True ($functionSite.identity.type -eq 'SystemAssigned') 'Function must have a system-assigned identity.'
    Assert-True ($functionStorage.properties.allowSharedKeyAccess -eq $false -and
        ($compiledFunction -join "`n") -notmatch 'listKeys\(|AccountKey=|StorageAccountConnectionString') 'Function storage must not use shared keys.'
    Assert-True ($functionStorage.properties.publicNetworkAccess -eq 'Enabled' -and
        $functionStorage.properties.allowBlobPublicAccess -eq $false) 'Demo storage must allow its public network endpoint without anonymous blob access.'
    $storageExemptions = @($functionTemplate.resources | Where-Object type -eq 'Microsoft.Authorization/policyExemptions')
    $publicNetworkDeployment = $functionTemplate.resources | Where-Object name -eq 'function-storage-public-network'
    $publicNetworkStorage = $publicNetworkDeployment.properties.template.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts'
    $storageScope = "[resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))]"
    Assert-True ($storageExemptions.Count -eq 1 -and
        $storageExemptions[0].name -eq 'apim-demo-storage-public-network' -and
        $storageExemptions[0].scope -eq $storageScope -and
        $storageExemptions[0].properties.exemptionCategory -eq 'Waiver' -and
        $storageExemptions[0].properties.policyAssignmentId -eq '/providers/Microsoft.Management/managementGroups/499b952e-2194-4661-af36-2f39f4261f76/providers/Microsoft.Authorization/policyAssignments/mcapsgovdeploypolicies' -and
        ($storageExemptions[0].properties.policyDefinitionReferenceIds -join ',') -eq 'StorageAccountPublicNetworkModify' -and
        $storageExemptions[0].dependsOn -contains $storageScope) 'Exempt only the public-network policy member on the demo storage account, after creating the account.'
    Assert-True ($publicNetworkDeployment.properties.parameters.storageAccountName.value -eq "[variables('storageAccountName')]" -and
        @($publicNetworkDeployment.dependsOn | Where-Object { $_ -match 'Microsoft.Authorization/policyExemptions' }).Count -eq 1 -and
        $publicNetworkStorage.properties.publicNetworkAccess -eq 'Enabled' -and
        $publicNetworkStorage.properties.allowSharedKeyAccess -eq $false -and
        $publicNetworkStorage.properties.allowBlobPublicAccess -eq $false -and
        @($deploymentContainer.dependsOn | Where-Object { $_ -match 'function-storage-public-network' }).Count -eq 1) 'Reapply authenticated public access after the exemption and before the Function deployment container.'
    Assert-True ($storageRoles.Count -eq 1 -and
        $functionTemplate.variables.storageBlobDataOwnerRoleId -like '*b7e6dc6d-f1e8-4753-8033-0f276bb0955b*' -and
        $storageRoles[0].properties.roleDefinitionId -eq "[variables('storageBlobDataOwnerRoleId')]" -and
        $storageRoles[0].properties.principalId -like '*identity.principalId*' -and
        $storageRoles[0].properties.principalType -eq 'ServicePrincipal' -and
        $storageRoles[0].scope -eq "[resourceId('Microsoft.Storage/storageAccounts', variables('storageAccountName'))]" -and
        @($storageRoles[0].dependsOn | Where-Object { $_ -match 'Microsoft.Web/sites' }).Count -eq 1) 'Grant the Function identity Storage Blob Data Owner on its storage account.'
    Assert-True ($deploymentContainer.properties.publicAccess -eq 'None') 'Deployment container must be private.'
    Assert-True (@($functionSite.dependsOn | Where-Object { $_ -match '/containers' }).Count -gt 0) 'Create the deployment container before the Function app.'
    Assert-True ($flexConfig.scaleAndConcurrency.instanceMemoryMB -eq 2048 -and
        $flexConfig.scaleAndConcurrency.maximumInstanceCount -eq 40 -and
        $flexConfig.scaleAndConcurrency.PSObject.Properties.Name -notcontains 'alwaysReady') 'Unexpected Flex scaling or always-ready configuration.'
    Assert-True ($functionSite.properties.siteConfig.PSObject.Properties.Name -notcontains 'linuxFxVersion' -and
        $functionSite.properties.siteConfig.PSObject.Properties.Name -notcontains 'alwaysOn') 'Legacy site configuration is incompatible with Flex.'
    $unsupportedSettings = @('FUNCTIONS_WORKER_RUNTIME', 'FUNCTIONS_EXTENSION_VERSION',
        'SCM_DO_BUILD_DURING_DEPLOYMENT', 'ENABLE_ORYX_BUILD', 'WEBSITE_RUN_FROM_PACKAGE')
    Assert-True (@($functionSite.properties.siteConfig.appSettings | Where-Object name -in $unsupportedSettings).Count -eq 0) 'Unsupported Flex runtime or build setting.'
    $hostSettings = $functionSite.properties.siteConfig.appSettings
    Assert-True (@($hostSettings | Where-Object name -eq 'AzureWebJobsStorage').Count -eq 0 -and
        @($hostSettings | Where-Object name -eq 'AzureWebJobsStorage__accountName').Count -eq 1 -and
        ($hostSettings | Where-Object name -eq 'AzureWebJobsStorage__accountName').value -eq "[variables('storageAccountName')]" -and
        ($hostSettings | Where-Object name -eq 'AzureWebJobsStorage__credential').value -eq 'managedidentity' -and
        @($hostSettings | Where-Object name -in @('AzureWebJobsStorage__clientId', 'AzureWebJobsStorage__managedIdentityResourceId')).Count -eq 0) 'Host storage must select the Function system-assigned identity without a key.'
    Assert-True ($functionSite.tags.'azd-service-name' -eq 'function' -and
        $null -ne $functionTemplate.outputs.FUNCTION_SERVICE_NAME -and
        $null -ne $functionTemplate.outputs.FUNCTION_BACKEND_URL) 'Function discovery and publishing outputs must be preserved.'
    $compiledMain = bicep build (Join-Path $PSScriptRoot '../Infrastructure/main.bicep') --stdout
    Assert-True ($LASTEXITCODE -eq 0) 'Main Bicep compilation failed.'
    $mainTemplate = $compiledMain | ConvertFrom-Json
    $apimDeployment = $mainTemplate.resources | Where-Object name -eq 'apim'
    $apimTemplate = $apimDeployment.properties.template
    $apimService = $apimTemplate.resources | Where-Object type -eq 'Microsoft.ApiManagement/service'
    foreach ($skuParameter in $mainTemplate.parameters.apimSku, $apimTemplate.parameters.sku) {
        Assert-True ($skuParameter.PSObject.Properties.Name -notcontains 'defaultValue' -and
            ($skuParameter.allowedValues -join ',') -eq 'BasicV2,PremiumV2') 'APIM must require a choice between BasicV2 and PremiumV2 without a default.'
    }
    Assert-True ($apimService.apiVersion -eq '2025-09-01-preview' -and
        $apimService.sku.name -eq "[parameters('sku')]" -and
        $apimDeployment.properties.parameters.sku.value -eq "[parameters('apimSku')]") 'APIM v2 SKU wiring or management API is incorrect.'
    Assert-True ($apimService.properties.developerPortalStatus -eq 'Enabled') 'APIM developer portal must be enabled for portal scenarios.'
    Assert-True ($apimTemplate.variables.apiManagementServiceName -like '*apiservice-*' -and
        $null -ne $mainTemplate.outputs.API_MANAGEMENT_SERVICE_NAME) 'APIM names and publishing outputs must be preserved.'
    $azdParameters = Get-Content (Join-Path $PSScriptRoot '../Infrastructure/main.parameters.json') -Raw | ConvertFrom-Json
    Assert-True ($azdParameters.parameters.PSObject.Properties.Name -notcontains 'apimSku') 'Omit the SKU from azd parameter mappings so native Bicep prompting can select it.'
    Write-Host 'PASS: Flex and APIM v2 infrastructure compilation and configuration contracts (offline).'
}

function apiops {
    $global:ApimScriptTestState.Arguments = @($args)
    $global:ApimScriptTestState.CommitId = $env:COMMIT_ID
    if ($args[0] -eq 'extract') {
        $global:ApimScriptTestState.StagingPath = $args[([array]::IndexOf($args, '--output') + 1)]
        $apiPath = Join-Path $global:ApimScriptTestState.StagingPath 'apis/echo-api'
        New-Item -ItemType Directory -Path $apiPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $apiPath 'apiInformation.json') -Value '{"properties":{}}'
    }
    if ($args[0] -eq 'publish') {
        $source = $args[([array]::IndexOf($args, '--source') + 1)]
        $global:ApimScriptTestState.PublishedSource = $source
        $global:ApimScriptTestState.PublishedBackends = @(Get-ChildItem $source -Recurse -Filter backendInformation.json |
            ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        $global:ApimScriptTestState.PublishedNamedValues = @(Get-ChildItem $source -Recurse -Filter namedValueInformation.json |
            ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
    }
    $global:LASTEXITCODE = $global:ApimScriptTestState.ExitCode
}

function az {
    $global:ApimScriptTestState.AzureCalls++
    $global:ApimScriptTestState.AzureArguments = @($args)
    $global:LASTEXITCODE = $global:ApimScriptTestState.AzureExitCode
    if ($global:LASTEXITCODE -eq 0) { 'offline-function-key' }
}

try {
    $env:FUNCTION_SERVICE_NAME = 'test-function'
    $env:FUNCTION_BACKEND_URL = 'https://test-function.azurewebsites.net/api'
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $artifactPath = Join-Path $testRoot 'artifacts with spaces'
    $filterPath = Join-Path $testRoot 'workspace filter.yaml'
    $overridesPath = Join-Path $testRoot 'overrides.yaml'
    Set-Content -LiteralPath $filterPath -Value 'workspaces: [team-a]'
    Set-Content -LiteralPath $overridesPath -Value 'apis: []'
    $target = @{ SubscriptionId = 'test-sub'; ResourceGroupName = 'test-rg'; ServiceName = 'test-apim' }
    Push-Location $testRoot
    try {
        & $extractScript @target -ArtifactPath $artifactPath -FilterPath $filterPath -NoTransitive
        Assert-True (Test-Path (Join-Path $artifactPath 'apis/echo-api/apiInformation.json')) 'Extract did not copy artifacts.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains '--no-transitive') 'Missing transitive option.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains $filterPath) 'Filter path was not preserved.'
        Assert-True (-not (Test-Path $global:ApimScriptTestState.StagingPath)) 'Extraction staging was not removed.'

        $existingPath = Join-Path $artifactPath 'apis/echo-api/apiInformation.json'
        Set-Content -LiteralPath $existingPath -Value 'keep-existing'
        foreach ($failureCode in 1, 2) {
            $global:ApimScriptTestState.ExitCode = $failureCode
            Assert-Fails { & $extractScript @target -ArtifactPath $artifactPath } "exit code $failureCode"
            Assert-True ((Get-Content $existingPath -Raw).Trim() -eq 'keep-existing') 'Failed extraction changed existing artifacts.'
            Assert-True (-not (Test-Path $global:ApimScriptTestState.StagingPath)) 'Failed extraction leaked staging.'
        }
        $global:ApimScriptTestState.ExitCode = 0
        & $extractScript @target -ArtifactPath $artifactPath
        Assert-True (-not (Test-Path (Join-Path $artifactPath 'apis/apis'))) 'Repeated extraction nested directories.'

        $env:COMMIT_ID = 'ambient-commit'
        & $publishScript @target -ArtifactPath $artifactPath -FilterPath $filterPath -OverridesPath $overridesPath -DryRun -NoTransitive
        Assert-True ($global:ApimScriptTestState.Arguments -contains '--dry-run') 'Missing dry-run option.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains $artifactPath) 'Source path was not preserved.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains $overridesPath) 'Overrides path was not preserved.'
        Assert-True (-not ($global:ApimScriptTestState.Arguments -contains '--delete-unmatched')) 'Destructive deletion was enabled.'
        Assert-True ([string]::IsNullOrEmpty($global:ApimScriptTestState.CommitId)) 'Ambient COMMIT_ID affected publishing.'
        Assert-True ($env:COMMIT_ID -eq 'ambient-commit') 'COMMIT_ID was not restored.'
        foreach ($failureCode in 1, 2) {
            $global:ApimScriptTestState.ExitCode = $failureCode
            Assert-Fails { & $publishScript @target -ArtifactPath $artifactPath } "exit code $failureCode"
            Assert-True ($env:COMMIT_ID -eq 'ambient-commit') 'Failed publishing did not restore COMMIT_ID.'
        }
        $global:ApimScriptTestState.ExitCode = 0
        Assert-Fails { & $publishScript @target -ArtifactPath $artifactPath -FilterPath './missing.yaml' } 'Configuration file not found'
        Assert-Fails { & $extractScript @target -ArtifactPath $artifactPath -FilterPath './missing.yaml' } 'Filter file not found'
        $env:AZURE_SUBSCRIPTION_ID = 'environment-sub'
        & $publishScript -ResourceGroupName 'test-rg' -ServiceName 'test-apim' -ArtifactPath $artifactPath
        Assert-True ($global:ApimScriptTestState.Arguments -contains 'environment-sub') 'Subscription environment fallback failed.'
        & $publishScript @target -ArtifactPath $artifactPath
        Assert-True ($global:ApimScriptTestState.Arguments -contains 'test-sub') 'Explicit subscription did not override environment.'
        Assert-Fails { & $publishScript @target -ServiceName '' -ArtifactPath $artifactPath } 'ServiceName'

        $functionArtifacts = Join-Path $testRoot 'function artifacts'
        New-Item -ItemType Directory -Path $functionArtifacts | Out-Null
        foreach ($directory in 'backends', 'namedValues') {
            Copy-Item (Join-Path $PSScriptRoot "../src/APIM/$directory") $functionArtifacts -Recurse
        }
        $workspacePath = Join-Path $functionArtifacts 'workspaces/team-a'
        New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
        foreach ($directory in 'backends', 'namedValues') {
            Copy-Item (Join-Path $functionArtifacts $directory) $workspacePath -Recurse
        }
        $functionTarget = @{
            FunctionAppName = 'target-function'
            FunctionBackendUrl = 'https://target-function.azurewebsites.net/api'
            FunctionResourceGroupName = 'function-rg'
        }
        $callsBeforeBinding = $global:ApimScriptTestState.AzureCalls
        & $publishScript @target -ArtifactPath $functionArtifacts -FilterPath $filterPath -NoTransitive
        Assert-True ($global:ApimScriptTestState.AzureCalls -eq $callsBeforeBinding) 'Generic filtered publishing performed an unsolicited Function key lookup.'
        Assert-Fails { & $publishScript @target -FunctionBackendUrl $functionTarget.FunctionBackendUrl -ArtifactPath $functionArtifacts } 'requires -FunctionAppName'
        Assert-Fails { & $publishScript @target @functionTarget -FunctionBackendUrl 'https://target-function.azurewebsites.net' -ArtifactPath $functionArtifacts } 'Specify -FunctionBackendUrl'
        $callsBeforeBinding = $global:ApimScriptTestState.AzureCalls
        & $publishScript @target @functionTarget -ArtifactPath $functionArtifacts -DryRun -OverridesPath $overridesPath
        Assert-True ($global:ApimScriptTestState.AzureCalls -eq $callsBeforeBinding + 1) 'Binding did not resolve exactly one target key.'
        Assert-True ($global:ApimScriptTestState.PublishedBackends.Count -eq 2) 'Service/workspace backends were not staged.'
        foreach ($backend in $global:ApimScriptTestState.PublishedBackends) {
            Assert-True ($backend.properties.url -eq $functionTarget.FunctionBackendUrl) 'Backend retained a source-environment URL.'
            Assert-True ($backend.properties.credentials.header.'x-functions-key'[0] -eq '{{demo-function-key}}') 'Backend did not use a named value.'
        }
        foreach ($namedValue in $global:ApimScriptTestState.PublishedNamedValues) {
            Assert-True ($namedValue.properties.secret -and $namedValue.properties.value -eq 'offline-function-key') 'Target secret was not bound.'
        }
        Assert-True ($global:ApimScriptTestState.AzureArguments -contains 'function-rg') 'Function resource group was not used.'
        Assert-True ($global:ApimScriptTestState.AzureArguments -contains 'test-sub') 'Key lookup did not target the explicit subscription.'
        Assert-True ($global:ApimScriptTestState.AzureArguments -contains 'target-function') 'Wrong Function key requested.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains $overridesPath) 'Binding lost explicit overrides.'
        Assert-True (-not (Test-Path $global:ApimScriptTestState.PublishedSource)) 'Publish staging leaked.'
        $originalSecret = Get-Content (Join-Path $functionArtifacts 'namedValues/demo-function-key/namedValueInformation.json') -Raw | ConvertFrom-Json
        Assert-True ($originalSecret.properties.value -eq '*** REDACTED ***') 'Publisher changed source artifacts.'
        $global:ApimScriptTestState.ExitCode = 2
        Assert-Fails { & $publishScript @target @functionTarget -ArtifactPath $functionArtifacts } 'exit code 2'
        Assert-True (-not (Test-Path $global:ApimScriptTestState.PublishedSource)) 'Failed publish leaked staged secrets.'
        Assert-True ($env:COMMIT_ID -eq 'ambient-commit') 'Bound publish failed to restore COMMIT_ID.'
        $global:ApimScriptTestState.ExitCode = 0
        $global:ApimScriptTestState.AzureExitCode = 1
        Assert-Fails { & $publishScript @target @functionTarget -ArtifactPath $functionArtifacts } 'Could not read the target Function'
        $global:ApimScriptTestState.AzureExitCode = 0

        $env:AZURE_RESOURCE_GROUP_NAME = 'azd-test-rg'
        $env:API_MANAGEMENT_SERVICE_NAME = 'azd-test-apim'
        $env:APIM_ARTIFACT_PATH = $artifactPath
        $env:APIM_FILTER_PATH = $filterPath
        $env:APIM_OVERRIDES_PATH = $overridesPath
        $env:APIM_NO_TRANSITIVE = 'true'
        $env:APIM_PUBLISH_DRY_RUN = 'true'
        & $azdPublishScript
        Assert-True ($global:ApimScriptTestState.Arguments -contains 'azd-test-rg') 'Hook did not use the selected resource group.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains 'azd-test-apim') 'Hook did not use the selected APIM service.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains $filterPath) 'Hook did not pass the workspace filter.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains $overridesPath) 'Hook did not pass overrides.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains '--dry-run') 'Hook did not pass dry-run.'
        Assert-True ($global:ApimScriptTestState.Arguments -contains '--no-transitive') 'Hook did not pass dependency selection.'
        Assert-True ((Get-Location).Path -eq $testRoot) 'Hook changed the caller directory.'
        $global:ApimScriptTestState.ExitCode = 2
        Assert-Fails { & $azdPublishScript } 'exit code 2'
        Assert-True ((Get-Location).Path -eq $testRoot) 'Failed hook changed the caller directory.'
        Assert-True ($env:COMMIT_ID -eq 'ambient-commit') 'Failed hook did not restore COMMIT_ID.'
        $global:ApimScriptTestState.ExitCode = 0
        $env:APIM_PUBLISH_DRY_RUN = 'false'
        $env:APIM_NO_TRANSITIVE = 'false'
        $env:APIM_ARTIFACT_PATH = 'src/APIM'
        $env:APIM_FILTER_PATH = $null
        $env:APIM_OVERRIDES_PATH = $null
        & $azdPublishScript
        Assert-True ($global:ApimScriptTestState.Arguments -notcontains '--dry-run') 'Hook interpreted false as true.'
        Assert-True ($global:ApimScriptTestState.Arguments -notcontains '--no-transitive') 'Hook interpreted false dependency selection as true.'
        Assert-True ($global:ApimScriptTestState.PublishedBackends[0].properties.url -eq $env:FUNCTION_BACKEND_URL) 'Hook paths or Function output binding failed.'
        $env:APIM_PUBLISH_DRY_RUN = 'invalid'
        Assert-Fails { & $azdPublishScript } 'APIM_PUBLISH_DRY_RUN must be true or false'
        if ($GitHubWorkflows) {
            $repositoryPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
            $globalNpmRoot = & npm root --global
            Assert-True ($LASTEXITCODE -eq 0) 'Could not locate the globally installed APIOps CLI.'
            $parseYaml = @'
const fs = require('node:fs');
const path = require('node:path');
const yaml = require(require.resolve('js-yaml', { paths: [path.join(process.argv[1], '@azure-tools/apiops-cli')] }));
console.log(JSON.stringify(process.argv.slice(2).map(file => yaml.load(fs.readFileSync(file, 'utf8')))));
'@
            $yamlPaths = @(
                (Join-Path $repositoryPath '.github/workflows/APIM-Extract-APIs-and-Artifacts.yml'),
                (Join-Path $repositoryPath '.github/workflows/APIM-Publish-APIs-and-Artifacts.yml'),
                (Join-Path $repositoryPath 'src/apim-extract-configuration.yaml'),
                (Join-Path $repositoryPath 'src/apim-publish-configuration.yaml')
            )
            $parsedYaml = & node -e $parseYaml $globalNpmRoot @yamlPaths
            Assert-True ($LASTEXITCODE -eq 0) 'Workflow or APIOps configuration YAML parsing failed.'
            $workflowData = $parsedYaml | ConvertFrom-Json -AsHashtable
            $extractJob = $workflowData[0].jobs.'APIM-extract-apis'
            $publishJob = $workflowData[1].jobs.'APIM-Import-APIs'
            foreach ($job in $extractJob, $publishJob) {
                Assert-True ($job.steps[0].uses -eq 'actions/checkout@v4' -and
                    @($job.steps | Where-Object { $_.uses -like 'actions/checkout@*' }).Count -eq 1) 'Workflow must check out the repository once before invoking its scripts.'
                Assert-True (($job.steps | Where-Object uses -eq 'actions/setup-node@v4').with.'node-version' -eq '22') 'Workflow must select a supported Node runtime.'
                Assert-True (@($job.steps | Where-Object run -eq 'npm install --global @azure-tools/apiops-cli@1.0.5').Count -eq 1) 'Workflow must install the pinned global CLI.'
                Assert-True (@($job.steps | Where-Object uses -eq 'azure/login@v2').Count -eq 1) 'Workflow must authenticate Azure CLI before publishing or extracting.'
                foreach ($step in @($job.steps | Where-Object shell -eq 'pwsh')) {
                    $parseErrors = $null
                    $tokens = $null
                    [System.Management.Automation.Language.Parser]::ParseInput($step.run, [ref] $tokens, [ref] $parseErrors) | Out-Null
                    Assert-True ($parseErrors.Count -eq 0) 'Workflow PowerShell has syntax errors.'
                }
            }
            $upload = $extractJob.steps | Where-Object uses -eq 'actions/upload-artifact@v4'
            Assert-True ($upload.with.path -eq '${{ env.API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH }}' -and
                $upload.with.'if-no-files-found' -eq 'error') 'Upload the extraction directory without doubling the workspace path.'
            Assert-True (($extractJob.steps | Where-Object uses -eq 'peter-evans/create-pull-request@v7').with.'add-paths' -eq 'src/APIM') 'Extraction PR must include only APIM artifacts.'
            Assert-True ($workflowData[2].ContainsKey('apis') -and -not $workflowData[2].ContainsKey('apiNames') -and
                -not $workflowData[3].ContainsKey('apimServiceName')) 'Configuration files must use CLI-native schemas.'
            foreach ($workflow in $workflowData[0], $workflowData[1]) {
                foreach ($trigger in 'workflow_call', 'workflow_dispatch') {
                    Assert-True ($workflow.on[$trigger].inputs.USE_CONFIG_FILE.type -eq 'boolean') 'Keep config selection available for both workflow triggers.'
                }
            }
            $extractRun = ($extractJob.steps | Where-Object name -eq 'Run extractor').run
            $publishRun = ($publishJob.steps | Where-Object name -eq 'Run publisher').run
            $workflowSettings = @{}
            foreach ($name in 'USE_CONFIG_FILE', 'API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH', 'APIM_FILTER_PATH',
                'APIM_NO_TRANSITIVE', 'APIM_PUBLISH_DRY_RUN', 'FUNCTION_SERVICE_NAME', 'FUNCTION_BACKEND_URL', 'FUNCTION_RESOURCE_GROUP_NAME') {
                $workflowSettings[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            Push-Location $repositoryPath
            try {
                $env:API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH = Join-Path $testRoot 'workflow extraction'
                $env:USE_CONFIG_FILE = 'true'
                $env:APIM_FILTER_PATH = $null
                $env:APIM_NO_TRANSITIVE = 'true'
                & ([scriptblock]::Create($extractRun))
                Assert-True ($global:ApimScriptTestState.Arguments -contains $yamlPaths[2] -and
                    $global:ApimScriptTestState.Arguments -contains '--no-transitive') 'Extraction workflow did not forward config selection or dependency scope.'
                $env:USE_CONFIG_FILE = 'false'
                $env:APIM_NO_TRANSITIVE = 'false'
                & ([scriptblock]::Create($extractRun))
                Assert-True ($global:ApimScriptTestState.Arguments -notcontains '--filter' -and
                    $global:ApimScriptTestState.Arguments -notcontains '--no-transitive') 'Extraction workflow interpreted false as true.'
                $env:API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH = $functionArtifacts
                $env:FUNCTION_RESOURCE_GROUP_NAME = 'workflow-function-rg'
                $env:USE_CONFIG_FILE = 'true'
                $env:APIM_FILTER_PATH = $filterPath
                $env:APIM_NO_TRANSITIVE = 'true'
                $env:APIM_PUBLISH_DRY_RUN = 'true'
                & ([scriptblock]::Create($publishRun))
                foreach ($expectedArgument in $yamlPaths[3], $filterPath, '--dry-run', '--no-transitive') {
                    Assert-True ($global:ApimScriptTestState.Arguments -contains $expectedArgument) "Publishing workflow did not forward $expectedArgument."
                }
                Assert-True ($global:ApimScriptTestState.AzureArguments -contains 'workflow-function-rg' -and
                    $global:ApimScriptTestState.PublishedNamedValues[0].properties.value -eq 'offline-function-key' -and
                    -not (Test-Path $global:ApimScriptTestState.PublishedSource)) 'Publishing workflow did not bind and clean up its target Function secret.'
                $env:USE_CONFIG_FILE = 'false'
                $env:APIM_FILTER_PATH = $null
                $env:APIM_NO_TRANSITIVE = 'false'
                $env:APIM_PUBLISH_DRY_RUN = 'false'
                $env:FUNCTION_SERVICE_NAME = $null
                $env:FUNCTION_BACKEND_URL = $null
                & ([scriptblock]::Create($publishRun))
                foreach ($disabledArgument in '--overrides', '--filter', '--dry-run', '--no-transitive') {
                    Assert-True ($global:ApimScriptTestState.Arguments -notcontains $disabledArgument) "Publishing workflow unexpectedly enabled $disabledArgument."
                }
                $global:ApimScriptTestState.ExitCode = 2
                Assert-Fails { & ([scriptblock]::Create($publishRun)) } 'exit code 2'
                Assert-Fails { & ([scriptblock]::Create($extractRun)) } 'exit code 2'
                Write-Host 'PASS: GitHub workflow YAML, configuration, actual PowerShell steps and failure propagation (offline).'
            }
            finally {
                $global:ApimScriptTestState.ExitCode = 0
                Pop-Location
                foreach ($setting in $workflowSettings.GetEnumerator()) {
                    [Environment]::SetEnvironmentVariable($setting.Key, $setting.Value)
                }
            }
        }
        if ($AzdHooks) {
            if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
                throw 'Install azd to run -AzdHooks checks.'
            }
            $sandboxPath = Join-Path $testRoot 'azd project'
            $fakeBinPath = Join-Path $testRoot 'fake cli'
            $environmentPath = Join-Path $sandboxPath '.azure/test'
            New-Item -ItemType Directory -Path $environmentPath, $fakeBinPath, (Join-Path $sandboxPath 'scripts') -Force | Out-Null
            Copy-Item (Join-Path $PSScriptRoot '../azure.yaml') $sandboxPath
            Copy-Item $publishScript, $azdPublishScript (Join-Path $sandboxPath 'scripts')
            Set-Content -LiteralPath (Join-Path $environmentPath '.env') -Value @(
                'AZURE_ENV_NAME="test"'
                'AZURE_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"'
                'AZURE_LOCATION="westus2"'
                'AZURE_RESOURCE_GROUP_NAME="hook-test-rg"'
                'API_MANAGEMENT_SERVICE_NAME="hook-test-apim"'
                'FUNCTION_SERVICE_NAME="hook-test-function"'
                'FUNCTION_BACKEND_URL="https://hook-test-function.azurewebsites.net/api"'
            )
            Set-Content -LiteralPath (Join-Path $fakeBinPath 'apiops.ps1') -Value @'
$ErrorActionPreference = 'Stop'
$source = $args[([array]::IndexOf($args, '--source') + 1)]
@{
    Arguments = @($args)
    CommitId = $env:COMMIT_ID
    Source = $source
    Backend = (Get-Content (Join-Path $source 'backends/demo-function/backendInformation.json') -Raw | ConvertFrom-Json)
    NamedValue = (Get-Content (Join-Path $source 'namedValues/demo-function-key/namedValueInformation.json') -Raw | ConvertFrom-Json)
} | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $env:APIM_TEST_CAPTURE
exit ([int] $env:APIM_TEST_EXIT_CODE)
'@
            Set-Content -LiteralPath (Join-Path $fakeBinPath 'az.ps1') -Value @'
if ($args -notcontains 'hook-test-function' -or $args -notcontains 'hook-test-rg' -or
    $args -notcontains '00000000-0000-0000-0000-000000000000') {
    throw 'Function key lookup did not use selected azd outputs.'
}
'offline-hook-function-key'
exit 0
'@
            $previousPath = $env:PATH
            $previousCapture = $env:APIM_TEST_CAPTURE
            $previousTestExitCode = $env:APIM_TEST_EXIT_CODE
            $previousNativePreference = $PSNativeCommandUseErrorActionPreference
            try {
                $PSNativeCommandUseErrorActionPreference = $false
                $env:PATH = "$fakeBinPath$([IO.Path]::PathSeparator)$previousPath"
                $env:APIM_TEST_CAPTURE = Join-Path $testRoot 'hook-arguments.json'
                $env:APIM_TEST_EXIT_CODE = '0'
                $env:APIM_PUBLISH_DRY_RUN = 'true'
                $env:APIM_NO_TRANSITIVE = 'true'
                $env:APIM_ARTIFACT_PATH = $functionArtifacts
                $env:APIM_FILTER_PATH = $filterPath
                $env:APIM_OVERRIDES_PATH = $overridesPath
                $env:APIM_PUBLISHER_NAME = $null
                $env:APIM_PUBLISHER_EMAIL = $null
                $hookOutput = azd hooks run preprovision --environment test --cwd $sandboxPath --no-prompt 2>&1 | Out-String
                Assert-True ($LASTEXITCODE -eq 0) "azd prerequisite hook blocked native publisher parameter prompting: $hookOutput"
                $hookOutput = azd hooks run postdeploy --environment test --cwd $sandboxPath --no-prompt 2>&1 | Out-String
                Assert-True ($LASTEXITCODE -eq 0) "azd hook failed: $hookOutput"
                $captured = Get-Content -LiteralPath $env:APIM_TEST_CAPTURE -Raw | ConvertFrom-Json
                Assert-True ($captured.Arguments -contains 'hook-test-apim') 'azd hook did not use selected environment outputs.'
                Assert-True ($captured.Arguments -contains '--dry-run') 'azd hook did not forward dry-run.'
                Assert-True ([string]::IsNullOrEmpty($captured.CommitId)) 'azd hook retained ambient COMMIT_ID.'
                Assert-True ($captured.Backend.properties.url -eq 'https://hook-test-function.azurewebsites.net/api') 'azd hook used the wrong Function backend.'
                Assert-True ($captured.NamedValue.properties.value -eq 'offline-hook-function-key') 'azd hook did not bind the target key.'
                Assert-True (-not (Test-Path $captured.Source)) 'azd hook leaked its staged secret.'
                $env:APIM_TEST_EXIT_CODE = '2'
                $hookOutput = azd hooks run postdeploy --environment test --cwd $sandboxPath --no-prompt 2>&1 | Out-String
                Assert-True ($LASTEXITCODE -ne 0) 'azd swallowed the publisher failure.'
                Assert-True ($hookOutput -like '*exit code 2*') "azd failed for an unexpected reason: $hookOutput"
                Write-Host 'PASS: Actual azd hook invocation and failure propagation (isolated stub CLI).'
            }
            finally {
                $env:PATH = $previousPath
                $env:APIM_TEST_CAPTURE = $previousCapture
                $env:APIM_TEST_EXIT_CODE = $previousTestExitCode
                $PSNativeCommandUseErrorActionPreference = $previousNativePreference
            }
        }
        Write-Host 'PASS: APIM scripts and azd publish adapter checks (offline).'
    }
    finally { Pop-Location }
}
finally {
    $env:COMMIT_ID = $previousCommitId
    $env:AZURE_SUBSCRIPTION_ID = $previousSubscriptionId
    foreach ($setting in $previousAzdSettings.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($setting.Key, $setting.Value)
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    Remove-Variable -Name ApimScriptTestState -Scope Global
}