//based on https://github.com/Azure/azure-quickstart-templates

param resourceSuffix string

param environment string = ''

@description('Location for all resources.')
param location string = resourceGroup().location

var siteName = 'FuncApp-flex-${resourceSuffix}'
var storageAccountName = 'store${replace(resourceSuffix, '-', '')}'
var hostingPlanName = 'hpn-flex-${resourceSuffix}'
var storageBlobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: siteName
  kind: 'functionapp,linux'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: {
    'azd-service-name': 'function'
  }
  properties: {
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.14'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'DEMO_ENVIRONMENT'
          value: environment
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
      ]
    }
    serverFarmId: hostingPlan.id
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: hostingPlanName
  location: location
  kind: 'functionapp'
  properties: {
    reserved: true
  }
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
  }
}

resource storagePublicNetworkExemption 'Microsoft.Authorization/policyExemptions@2022-07-01-preview' = {
  name: 'apim-demo-storage-public-network'
  scope: storageAccount
  properties: {
    displayName: 'APIM demo storage public endpoint'
    description: 'User-approved public network access for the APIMScenarios demo. Managed identity, disabled shared keys, and disabled anonymous blob access remain required.'
    exemptionCategory: 'Waiver'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/499b952e-2194-4661-af36-2f39f4261f76/providers/Microsoft.Authorization/policyAssignments/mcapsgovdeploypolicies'
    policyDefinitionReferenceIds: [
      'StorageAccountPublicNetworkModify'
    ]
  }
}

module storagePublicNetwork './storage-public-network.bicep' = {
  name: 'function-storage-public-network'
  params: {
    storageAccountName: storageAccount.name
    location: location
  }
  dependsOn: [
    storagePublicNetworkExemption
  ]
}

resource functionStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, site.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'function-releases'
  properties: {
    publicAccess: 'None'
  }
  dependsOn: [
    storagePublicNetwork
  ]
}

output FUNCTION_SERVICE_NAME string = siteName
output FUNCTION_BACKEND_URL string = 'https://${site.properties.defaultHostName}/api'
