param location string
param namePrefix string
param suffix string
param tags object
param queueName string
param outboundIpAddress string
param apiPrincipalId string
param workerPrincipalId string

var senderRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
)
var receiverRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
)

resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: '${namePrefix}-sb-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
  }
}

resource networkRules 'Microsoft.ServiceBus/namespaces/networkRuleSets@2024-01-01' = {
  parent: serviceBus
  name: 'default'
  properties: {
    defaultAction: 'Deny'
    publicNetworkAccess: 'Enabled'
    trustedServiceAccessEnabled: false
    ipRules: [
      {
        action: 'Allow'
        ipMask: outboundIpAddress
      }
    ]
    virtualNetworkRules: []
  }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: queueName
  properties: {
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P14D'
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    enableBatchedOperations: true
    enablePartitioning: false
    lockDuration: 'PT1M'
    maxDeliveryCount: 10
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: true
    requiresSession: false
    status: 'Active'
  }
}

resource apiSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, apiPrincipalId, senderRoleDefinitionId)
  scope: queue
  properties: {
    roleDefinitionId: senderRoleDefinitionId
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource workerReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, workerPrincipalId, receiverRoleDefinitionId)
  scope: queue
  properties: {
    roleDefinitionId: receiverRoleDefinitionId
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output namespaceId string = serviceBus.id
output namespaceName string = serviceBus.name
output endpoint string = 'sb://${serviceBus.name}.servicebus.windows.net/'
output queueName string = queue.name
