//based on https://github.com/Azure/azure-quickstart-templates

param resourceSuffix string

@description('Location for all resources.')
param location string = resourceGroup().location

var siteName = 'FuncApp-${resourceSuffix}'
var storageAccountName = 'store${replace(resourceSuffix, '-', '')}'
var hostingPlanName = 'hpn-${resourceSuffix}'

resource site 'Microsoft.Web/sites@2022-03-01' = {
  name: siteName
  kind: 'functionapp,linux'
  location: location
  properties: {
    siteConfig: {
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
      ]
    }
    serverFarmId: hostingPlan.id
    clientAffinityEnabled: false
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: hostingPlanName
  location: location
  kind: 'linux'
  properties: {
    reserved: true
  }
  sku: {
    tier: 'Standard'
    name: 'S1'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

output FUNCTION_SERVICE_NAME string = siteName
