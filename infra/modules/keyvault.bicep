param location string
param namePrefix string
param suffix string
param tags object
param tenantId string
param aksSubnetId string
param bootstrapPrincipalId string
param runtimeIdentityPrincipalId string
@secure()
param postgresAdministratorLogin string
@secure()
param postgresAdministratorPassword string
@secure()
param postgresApplicationLogin string
@secure()
param postgresApplicationPassword string

var secretsUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: take('${namePrefix}-kv-${suffix}', 24)
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: [
        {
          id: aksSubnetId
          ignoreMissingVnetServiceEndpoint: false
        }
      ]
    }
  }
}

resource administratorLoginSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-administrator-login'
  properties: {
    attributes: {
      enabled: true
    }
    value: postgresAdministratorLogin
  }
}

resource administratorPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-administrator-password'
  properties: {
    attributes: {
      enabled: true
    }
    value: postgresAdministratorPassword
  }
}

resource applicationLoginSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-application-login'
  properties: {
    attributes: {
      enabled: true
    }
    value: postgresApplicationLogin
  }
}

resource applicationPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'postgres-application-password'
  properties: {
    attributes: {
      enabled: true
    }
    value: postgresApplicationPassword
  }
}

resource bootstrapSecretsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, bootstrapPrincipalId, secretsUserRoleDefinitionId)
  scope: vault
  properties: {
    roleDefinitionId: secretsUserRoleDefinitionId
    principalId: bootstrapPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource runtimeSecretsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, runtimeIdentityPrincipalId, secretsUserRoleDefinitionId)
  scope: vault
  properties: {
    roleDefinitionId: secretsUserRoleDefinitionId
    principalId: runtimeIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output vaultId string = vault.id
output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
