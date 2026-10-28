// based on https://github.com/Azure/azure-quickstart-templates

param resourceSuffix string

@description('Location for all resources.')
param location string = resourceGroup().location

@description('The email address of the owner of the service')
@minLength(1)
param publisherEmail string

@description('The name of the owner of the service')
@minLength(1)
param publisherName string

@description('The pricing tier of this API Management service')
@allowed([
  'BasicV2'
  'PremiumV2'
])
param sku string

@description('The instance size of this API Management service.')
@allowed([
  1
  2
])
param skuCount int = 1

@description('The name of the API Management service instance')
var apiManagementServiceName = 'apiservice-${resourceSuffix}'

resource apiManagementService 'Microsoft.ApiManagement/service@2025-09-01-preview' = {
  name: apiManagementServiceName
  location: location
  sku: {
    name: sku
    capacity: skuCount
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    developerPortalStatus: 'Enabled'
  }
}

output AZURE_RESOURCE_GROUP_NAME string = apiManagementServiceName
