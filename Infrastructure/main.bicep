targetScope = 'subscription'

@description('The environment for which the deployment is being executed')
@allowed([
  'dev'
  'test'
  'uat'
  'prod'
])
param environment string

param location string = deployment().location

@description('The APIM publisher organization name')
@minLength(1)
param publisherName string

@description('The APIM publisher email address')
@minLength(1)
param publisherEmail string

@description('Select the APIM v2 pricing tier: BasicV2 for demos or PremiumV2 for enterprise features. Both support workspaces.')
@allowed([
  'BasicV2'
  'PremiumV2'
])
param apimSku string

// Variables
var uniqueSuffix = substring(uniqueString(concat(subscription().id),environment),0,5)
var workloadName = 'demos'
var resourceSuffix = '${uniqueSuffix}-${workloadName}-${environment}'
var ResourceGroupName = 'apim-${resourceSuffix}'

resource RG 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: ResourceGroupName
  location: location
  tags: {
    'azd-env-name': environment
  }
}

module APIMDeploy 'apim.bicep' = {
  name: 'apim'
  scope: RG
  params: {
    resourceSuffix: resourceSuffix
    location: location
    publisherName: publisherName
    publisherEmail: publisherEmail
    sku: apimSku
    skuCount: 1
  }
}

module FunctionDeploy 'functions.bicep' = {
  name: 'function'
  scope: RG
  params: {
    resourceSuffix: resourceSuffix
    location: location
    environment: environment
  }
}

output AZURE_SUBSCRIPTION_ID string = subscription().subscriptionId
output AZURE_RESOURCE_GROUP_NAME string = ResourceGroupName
output API_MANAGEMENT_SERVICE_NAME string = APIMDeploy.outputs.AZURE_RESOURCE_GROUP_NAME
output FUNCTION_SERVICE_NAME string = FunctionDeploy.outputs.FUNCTION_SERVICE_NAME
output FUNCTION_BACKEND_URL string = FunctionDeploy.outputs.FUNCTION_BACKEND_URL
