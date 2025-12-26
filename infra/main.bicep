targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Prefix used for resource names')
param namePrefix string

@description('Container image for the Message Center MCP server')
param messageCenterImage string

@description('External ingress target port for the app')
param messageCenterTargetPort int = 8080

@description('Minimum replicas (0 enables scale-to-zero)')
@minValue(0)
param minReplicas int = 0

@description('Maximum replicas')
@minValue(1)
param maxReplicas int = 5

@description('Log Analytics workspace SKU')
param logAnalyticsSku string = 'PerGB2018'

@description('Enable zone redundancy for the Container Apps managed environment (only supported in some regions)')
param zoneRedundant bool = false

@description('Graph tenant id (GUID)')
param graphTenantId string

@description('Graph client id (GUID)')
param graphClientId string

@description('Key Vault name (globally unique) that stores the Graph client certificate private key as a secret')
param keyVaultName string

@description('If true, do not create a Key Vault; reference an existing Key Vault instead (useful when the vault name is already taken).')
param useExistingKeyVault bool = false

@description('Resource group name containing the existing Key Vault when useExistingKeyVault=true. If empty, uses the current resource group.')
param existingKeyVaultResourceGroupName string = ''

@description('Key Vault secret name that contains the Graph client certificate private key (PEM)')
param graphClientCertSecretName string = 'graph-client-cert'

@description('Thumbprint (hex) of the certificate uploaded to the app registration for Graph OBO')
param graphClientCertThumbprint string

@description('Optional override for PUBLIC_BASE_URL. If empty, uses https://<appFqdn>')
param publicBaseUrl string = ''

@description('Optional override for the Azure Container Registry login server. If empty, derived from messageCenterImage.')
param acrLoginServer string = ''

@description('If true, use system-assigned managed identity to pull from ACR. If false, use ACR admin credentials (bootstrap mode).')
param acrUseManagedIdentity bool = false

@description('Optional name for the user-assigned managed identity used to pull from ACR when acrUseManagedIdentity=true. Defaults to <namePrefix>-acr-pull.')
param acrPullIdentityName string = ''

var logAnalyticsName = '${namePrefix}-law'
var appInsightsName = '${namePrefix}-appi'
var acaEnvName = '${namePrefix}-cae'
var appName = '${namePrefix}-mcp-mc'

var effectiveAcrLoginServer = empty(acrLoginServer) ? split(messageCenterImage, '/')[0] : acrLoginServer
var acrName = split(effectiveAcrLoginServer, '.')[0]

var effectiveAcrPullIdentityName = empty(acrPullIdentityName) ? '${namePrefix}-acr-pull' : acrPullIdentityName

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// IMPORTANT: pulling from ACR via system-assigned identity can race because the identity principalId
// exists only after the Container App resource is created, but the image pull happens during revision provisioning.
// Using a user-assigned identity avoids that circular dependency (we can grant AcrPull before creating/updating the app).
resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (acrUseManagedIdentity) {
  name: effectiveAcrPullIdentityName
  location: location
}

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

var acrCredentials = acr.listCredentials()
var acrUsername = acrCredentials.username
var acrPassword = acrCredentials.passwords[0].value

var acrRegistrySecrets = acrUseManagedIdentity ? [] : [
  {
    name: 'acr-password'
    value: acrPassword
  }
]

var acrRegistries = acrUseManagedIdentity
  ? [
      {
        server: effectiveAcrLoginServer
        // For user-assigned identity, Container Apps expects the identity resourceId.
        identity: acrPullIdentity!.id
      }
    ]
  : [
      {
        server: effectiveAcrLoginServer
        username: acrUsername
        passwordSecretRef: 'acr-password'
      }
    ]

var appFqdnComputed = '${appName}.${managedEnv.outputs.defaultDomain}'
var effectivePublicBaseUrl = empty(publicBaseUrl) ? 'https://${appFqdnComputed}' : publicBaseUrl

var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

var existingKeyVaultScope = empty(existingKeyVaultResourceGroupName)
  ? resourceGroup()
  : resourceGroup(subscription().subscriptionId, existingKeyVaultResourceGroupName)

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = if (!useExistingKeyVault) {
  name: keyVaultName
  location: location
  properties: {
    tenantId: graphTenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
  }
}

resource existingKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (useExistingKeyVault) {
  name: keyVaultName
  scope: existingKeyVaultScope
}

var effectiveKeyVaultUri = useExistingKeyVault ? existingKeyVault.properties.vaultUri : keyVault.properties.vaultUri

// AVM modules
// Note: versions are pinned. Update as needed.

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.14.2' = {
  name: 'logAnalytics'
  params: {
    name: logAnalyticsName
    location: location
    skuName: logAnalyticsSku
  }
}

module appInsights 'br/public:avm/res/insights/component:0.7.1' = {
  name: 'appInsights'
  params: {
    name: appInsightsName
    location: location
    kind: 'web'
    applicationType: 'web'
    workspaceResourceId: logAnalytics.outputs.resourceId
  }
}

module managedEnv 'br/public:avm/res/app/managed-environment:0.11.3' = {
  name: 'managedEnv'
  params: {
    name: acaEnvName
    location: location
    zoneRedundant: zoneRedundant
    publicNetworkAccess: 'Enabled'
    // Wire logs to Log Analytics
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.outputs.logAnalyticsWorkspaceId
        sharedKey: logAnalytics.outputs.primarySharedKey
      }
    }
    // App Insights connection string for Dapr/OpenTelemetry destinations
    appInsightsConnectionString: appInsights.outputs.connectionString
  }
}

module app 'br/public:avm/res/app/container-app:0.19.0' = {
  name: 'messageCenterApp'
  params: {
    name: appName
    location: location
    environmentResourceId: managedEnv.outputs.resourceId

    managedIdentities: acrUseManagedIdentity
      ? {
          systemAssigned: true
          userAssignedResourceIds: [
            acrPullIdentity!.id
          ]
        }
      : {
          systemAssigned: true
        }

    ingressExternal: true
    ingressAllowInsecure: false
    ingressTargetPort: messageCenterTargetPort
    ingressTransport: 'auto'

    secrets: acrRegistrySecrets
    registries: acrRegistries

    containers: [
      {
        name: 'app'
        image: messageCenterImage
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        env: [
          {
            name: 'NODE_ENV'
            value: 'production'
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
          {
            name: 'PORT'
            value: string(messageCenterTargetPort)
          }
          {
            name: 'GRAPH_TENANT_ID'
            value: graphTenantId
          }
          {
            name: 'GRAPH_CLIENT_ID'
            value: graphClientId
          }
          {
            name: 'GRAPH_CLIENT_CERT_KEYVAULT_URL'
            value: effectiveKeyVaultUri
          }
          {
            name: 'GRAPH_CLIENT_CERT_SECRET_NAME'
            value: graphClientCertSecretName
          }
          {
            name: 'GRAPH_CLIENT_CERT_THUMBPRINT'
            value: graphClientCertThumbprint
          }
          {
            name: 'PUBLIC_BASE_URL'
            value: effectivePublicBaseUrl
          }
        ]
      }
    ]

    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http'
          http: {
            metadata: {
              concurrentRequests: '50'
            }
          }
        }
      ]
    }
  }
}

resource keyVaultSecretsUserRoleAssignmentNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!useExistingKeyVault) {
  name: guid(keyVault.id, appName, keyVaultSecretsUserRoleDefinitionId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: app.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultSecretsUserRoleAssignmentExisting 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useExistingKeyVault) {
  name: guid(existingKeyVault.id, appName, keyVaultSecretsUserRoleDefinitionId)
  scope: existingKeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: app.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
  }
}

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (acrUseManagedIdentity) {
  name: guid(acr.id, acrPullIdentity.id, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: acrPullIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output messageCenterFqdn string = appFqdnComputed
output logAnalyticsWorkspaceResourceId string = logAnalytics.outputs.resourceId
output appInsightsConnectionString string = appInsights.outputs.connectionString
