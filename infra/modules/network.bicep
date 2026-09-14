param location string
param namePrefix string
param suffix string
param tags object
param vnetAddressPrefix string
param aksSubnetPrefix string
param postgresSubnetPrefix string
param controlPlanePrincipalId string

var networkContributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4d97b98b-1d4f-4787-a291-c67834d212e7'
)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'aks'
  properties: {
    addressPrefix: aksSubnetPrefix
    serviceEndpoints: [
      {
        service: 'Microsoft.Storage'
      }
      {
        service: 'Microsoft.KeyVault'
      }
    ]
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource postgresSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'postgres'
  dependsOn: [
    aksSubnet
  ]
  properties: {
    addressPrefix: postgresSubnetPrefix
    delegations: [
      {
        name: 'postgres-flexible-server'
        properties: {
          serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
        }
      }
    ]
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource outboundIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${namePrefix}-aks-egress-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 30
  }
}

resource postgresDns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
  tags: tags
}

resource postgresDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: postgresDns
  name: '${namePrefix}-vnet-link-${suffix}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource controlPlaneSubnetContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksSubnet.id, controlPlanePrincipalId, networkContributorRoleDefinitionId)
  scope: aksSubnet
  properties: {
    roleDefinitionId: networkContributorRoleDefinitionId
    principalId: controlPlanePrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource controlPlaneOutboundIpContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(outboundIp.id, controlPlanePrincipalId, networkContributorRoleDefinitionId)
  scope: outboundIp
  properties: {
    roleDefinitionId: networkContributorRoleDefinitionId
    principalId: controlPlanePrincipalId
    principalType: 'ServicePrincipal'
  }
}

output vnetId string = vnet.id
output aksSubnetId string = aksSubnet.id
output postgresSubnetId string = postgresSubnet.id
output outboundIpId string = outboundIp.id
output outboundIpAddress string = outboundIp.properties.ipAddress
output postgresPrivateDnsZoneId string = postgresDns.id
