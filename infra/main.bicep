targetScope = 'resourceGroup'

@description('Azure subscription that must match the active deployment context.')
param targetSubscriptionId string

@description('Microsoft Entra tenant that must match the active deployment context.')
param targetTenantId string

@description('Resource group that must match the deployment scope.')
param targetResourceGroupName string = 'rg-score-parcelflow-demo'

@description('Object ID of the user, group, or service principal allowed to administer the demo cluster.')
param operatorPrincipalId string

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param operatorPrincipalType string = 'User'

@description('Azure region for all regional resources.')
param location string = 'centralus'

@description('A supported, explicitly pinned AKS Kubernetes version returned by preflight.')
param kubernetesVersion string

@description('Expiration marker applied to all resources, normally tomorrow in yyyy-MM-dd form.')
param expirationDate string

@description('Email address used only for Azure Cost Management budget notifications.')
param budgetContact string = ''

@description('Deploy the resource-group budget. Disable for subscriptions that do not support budgets.')
param deployBudget bool = true

@description('Short resource naming prefix.')
param namePrefix string = 'spf'

@description('AKS system node VM size.')
param nodeVmSize string = 'Standard_D2as_v7'

@minValue(1)
@maxValue(3)
param nodeCount int = 2

@minValue(1)
@maxValue(3)
param minNodeCount int = 1

@minValue(1)
@maxValue(3)
param maxNodeCount int = 3

@allowed([
  'Standard_B1ms'
  'Standard_B2s'
])
@description('PostgreSQL Flexible Server SKU. Use Standard_B2s when Standard_B1ms is unavailable.')
param postgresSkuName string = 'Standard_B1ms'

param postgresVersion string = '16'
param postgresDatabaseName string = 'parcelflow'

@secure()
param postgresAdministratorLogin string

@secure()
param postgresAdministratorPassword string

@secure()
param postgresApplicationLogin string

@secure()
param postgresApplicationPassword string

param vnetAddressPrefix string = '10.20.0.0/16'
param aksSubnetPrefix string = '10.20.0.0/22'
param postgresSubnetPrefix string = '10.20.8.0/24'
param serviceBusQueueName string = 'delivery-commands'
param proofContainerName string = 'proof'
param stateContainerName string = 'score-state'
param logRetentionDays int = 30
param logDailyQuotaGb int = 1
param budgetAmount int = 50
param budgetStartDate string

var suffix = uniqueString(targetSubscriptionId, targetResourceGroupName, location)
var commonTags = {
  project: 'score-parcelflow'
  environment: 'demo'
  expiration: expirationDate
  managedBy: 'deployment-stack'
}

module identities 'modules/identities.bicep' = {
  name: 'identities'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    vnetAddressPrefix: vnetAddressPrefix
    aksSubnetPrefix: aksSubnetPrefix
    postgresSubnetPrefix: postgresSubnetPrefix
    controlPlanePrincipalId: identities.outputs.controlPlanePrincipalId
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    retentionInDays: logRetentionDays
    dailyQuotaGb: logDailyQuotaGb
  }
}

module registry 'modules/acr.bicep' = {
  name: 'registry'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    kubeletPrincipalId: identities.outputs.kubeletPrincipalId
    deploymentPrincipalId: identities.outputs.deploymentPrincipalId
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    suffix: suffix
    tags: commonTags
    aksSubnetId: network.outputs.aksSubnetId
    apiPrincipalId: identities.outputs.apiPrincipalId
    deploymentPrincipalId: identities.outputs.deploymentPrincipalId
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
    proofContainerName: proofContainerName
    stateContainerName: stateContainerName
  }
}

module serviceBus 'modules/servicebus.bicep' = {
  name: 'service-bus'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    queueName: serviceBusQueueName
    outboundIpAddress: network.outputs.outboundIpAddress
    apiPrincipalId: identities.outputs.apiPrincipalId
    workerPrincipalId: identities.outputs.workerPrincipalId
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    delegatedSubnetId: network.outputs.postgresSubnetId
    privateDnsZoneId: network.outputs.postgresPrivateDnsZoneId
    administratorLogin: postgresAdministratorLogin
    administratorPassword: postgresAdministratorPassword
    databaseName: postgresDatabaseName
    skuName: postgresSkuName
    postgresVersion: postgresVersion
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'key-vault'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    tenantId: targetTenantId
    aksSubnetId: network.outputs.aksSubnetId
    bootstrapPrincipalId: identities.outputs.bootstrapPrincipalId
    runtimeIdentityPrincipalId: identities.outputs.runtimeSecretsPrincipalId
    postgresAdministratorLogin: postgresAdministratorLogin
    postgresAdministratorPassword: postgresAdministratorPassword
    postgresApplicationLogin: postgresApplicationLogin
    postgresApplicationPassword: postgresApplicationPassword
  }
}

module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    location: location
    namePrefix: namePrefix
    suffix: suffix
    tags: commonTags
    tenantId: targetTenantId
    kubernetesVersion: kubernetesVersion
    nodeVmSize: nodeVmSize
    nodeCount: nodeCount
    minNodeCount: minNodeCount
    maxNodeCount: maxNodeCount
    aksSubnetId: network.outputs.aksSubnetId
    outboundIpId: network.outputs.outboundIpId
    workspaceId: monitoring.outputs.workspaceId
    controlPlaneIdentityResourceId: identities.outputs.controlPlaneResourceId
    kubeletIdentityResourceId: identities.outputs.kubeletResourceId
    kubeletIdentityClientId: identities.outputs.kubeletClientId
    kubeletIdentityPrincipalId: identities.outputs.kubeletPrincipalId
    deploymentPrincipalId: identities.outputs.deploymentPrincipalId
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
  }
}

module budget 'modules/budget.bicep' = if (deployBudget) {
  name: 'budget'
  params: {
    budgetName: '${namePrefix}-monthly-${suffix}'
    contactEmail: budgetContact
    amount: budgetAmount
    startDate: budgetStartDate
  }
}

output suffix string = suffix
output aksClusterName string = aks.outputs.clusterName
output aksNodeResourceGroup string = aks.outputs.nodeResourceGroup
output aksOidcIssuerUrl string = aks.outputs.oidcIssuerUrl
output acrName string = registry.outputs.registryName
output acrLoginServer string = registry.outputs.registryLoginServer
output storageAccountName string = storage.outputs.accountName
output proofContainerName string = storage.outputs.proofContainerName
output stateContainerName string = storage.outputs.stateContainerName
output serviceBusNamespaceName string = serviceBus.outputs.namespaceName
output serviceBusEndpoint string = serviceBus.outputs.endpoint
output serviceBusQueueName string = serviceBus.outputs.queueName
output postgresServerName string = postgres.outputs.serverName
output postgresHost string = postgres.outputs.fullyQualifiedDomainName
output postgresDatabaseName string = postgres.outputs.databaseName
output keyVaultName string = keyVault.outputs.vaultName
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output apiIdentityClientId string = identities.outputs.apiClientId
output apiIdentityName string = last(split(identities.outputs.apiResourceId, '/'))
output workerIdentityClientId string = identities.outputs.workerClientId
output workerIdentityName string = last(split(identities.outputs.workerResourceId, '/'))
output bootstrapIdentityClientId string = identities.outputs.bootstrapClientId
output bootstrapIdentityName string = last(split(identities.outputs.bootstrapResourceId, '/'))
output runtimeSecretsIdentityClientId string = identities.outputs.runtimeSecretsClientId
output runtimeSecretsIdentityName string = last(split(identities.outputs.runtimeSecretsResourceId, '/'))
output deploymentIdentityClientId string = identities.outputs.deploymentClientId
output deploymentIdentityName string = last(split(identities.outputs.deploymentResourceId, '/'))
