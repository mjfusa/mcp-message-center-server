// Creates an Azure Container Registry (ACR) for this project.
// Usage is documented in infra/README.md.

targetScope = 'resourceGroup'

@description('Azure region for the registry. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Name of the Azure Container Registry (must be globally unique, 5-50 alphanumeric characters; use lowercase to match Azure DNS/login server conventions).')
param acrName string

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
@description('ACR SKU.')
param acrSku string = 'Standard'

@description('Enable the admin user on the registry. Recommended: false (use Entra auth / managed identity).')
param acrAdminUserEnabled bool = false

@description('If true, disables AVM telemetry.')
param disableTelemetry bool = false

module acr 'br/public:avm/res/container-registry/registry:0.9.3' = {
  // IMPORTANT: this `name` becomes a nested Microsoft.Resources/deployments resource.
  // If it matches the top-level deployment name (often derived from the filename), ARM can error with DeploymentActive.
  name: 'acr-${uniqueString(resourceGroup().id, acrName)}'
  params: {
    name: toLower(acrName)
    location: location
    acrSku: acrSku
    acrAdminUserEnabled: acrAdminUserEnabled
    enableTelemetry: !disableTelemetry
  }
}

@description('ACR resource ID')
output acrResourceId string = acr.outputs.resourceId

@description('ACR login server, e.g. myregistry.azurecr.io')
output acrLoginServer string = acr.outputs.loginServer
