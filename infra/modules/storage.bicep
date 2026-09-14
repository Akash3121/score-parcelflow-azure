param location string
@minLength(5)
param suffix string
param tags object
param aksSubnetId string
param apiPrincipalId string
param deploymentPrincipalId string
param operatorPrincipalId string
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param operatorPrincipalType string
param proofContainerName string
param stateContainerName string

var blobDataContributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)
var storageAccountContributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '17d1049b-9a84-46fb-8f53-869881c3d3ab'
)

resource account 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'spf${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    isHnsEnabled: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: aksSubnetId
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: account
  name: 'default'
  properties: {
    cors: {
      corsRules: []
    }
    deleteRetentionPolicy: {
      enabled: false
    }
    isVersioningEnabled: false
  }
}

resource proofContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: proofContainerName
  properties: {
    publicAccess: 'None'
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: true
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: stateContainerName
  properties: {
    publicAccess: 'None'
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: true
  }
}

resource proofLifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: account
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'delete-proof-blobs-after-seven-days'
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 7
                }
              }
            }
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${proofContainerName}/'
              ]
            }
          }
        }
      ]
    }
  }
}

resource apiProofContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(proofContainer.id, apiPrincipalId, blobDataContributorRoleDefinitionId)
  scope: proofContainer
  properties: {
    roleDefinitionId: blobDataContributorRoleDefinitionId
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentStateContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stateContainer.id, deploymentPrincipalId, blobDataContributorRoleDefinitionId)
  scope: stateContainer
  properties: {
    roleDefinitionId: blobDataContributorRoleDefinitionId
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentStorageManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, deploymentPrincipalId, storageAccountContributorRoleDefinitionId)
  scope: account
  properties: {
    roleDefinitionId: storageAccountContributorRoleDefinitionId
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorStateContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stateContainer.id, operatorPrincipalId, blobDataContributorRoleDefinitionId)
  scope: stateContainer
  properties: {
    roleDefinitionId: blobDataContributorRoleDefinitionId
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

resource operatorStorageManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, operatorPrincipalId, storageAccountContributorRoleDefinitionId)
  scope: account
  properties: {
    roleDefinitionId: storageAccountContributorRoleDefinitionId
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

output accountId string = account.id
output accountName string = account.name
output blobEndpoint string = account.properties.primaryEndpoints.blob
output proofContainerName string = proofContainer.name
output stateContainerName string = stateContainer.name
