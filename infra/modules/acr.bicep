param location string
param namePrefix string
param suffix string
param tags object
param kubeletPrincipalId string
param deploymentPrincipalId string

var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)
var acrPushRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '8311e382-0749-4cb8-b61a-304f252e45ec'
)
var contributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace('${namePrefix}acr${suffix}', '-', '')
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      retentionPolicy: {
        days: 7
        status: 'disabled'
      }
      trustPolicy: {
        type: 'Notary'
        status: 'disabled'
      }
      exportPolicy: {
        status: 'enabled'
      }
    }
    zoneRedundancy: 'Disabled'
  }
}

resource kubeletPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, kubeletPrincipalId, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: kubeletPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, deploymentPrincipalId, acrPushRoleDefinitionId)
  scope: registry
  properties: {
    roleDefinitionId: acrPushRoleDefinitionId
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentRegistryManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, deploymentPrincipalId, contributorRoleDefinitionId)
  scope: registry
  properties: {
    roleDefinitionId: contributorRoleDefinitionId
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output registryId string = registry.id
output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
