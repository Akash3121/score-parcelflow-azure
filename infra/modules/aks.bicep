param location string
param namePrefix string
param suffix string
param tags object
param tenantId string
param kubernetesVersion string
param nodeVmSize string
param nodeCount int
param minNodeCount int
param maxNodeCount int
param aksSubnetId string
param outboundIpId string
param workspaceId string
param controlPlaneIdentityResourceId string
param kubeletIdentityResourceId string
param kubeletIdentityClientId string
param kubeletIdentityPrincipalId string
param deploymentPrincipalId string
param operatorPrincipalId string
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param operatorPrincipalType string

var clusterAdminRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
)

resource cluster 'Microsoft.ContainerService/managedClusters@2024-10-01' = {
  name: '${namePrefix}-aks-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controlPlaneIdentityResourceId}': {}
    }
  }
  properties: {
    aadProfile: {
      enableAzureRBAC: true
      managed: true
      tenantID: tenantId
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
          rotationPollInterval: '2m'
        }
      }
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: workspaceId
          useAADAuth: 'true'
        }
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: nodeVmSize
        osDiskSizeGB: 64
        osDiskType: 'Managed'
        osType: 'Linux'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: true
        minCount: minNodeCount
        maxCount: maxNodeCount
        maxPods: 30
        vnetSubnetID: aksSubnetId
        upgradeSettings: {
          maxSurge: '33%'
        }
      }
    ]
    autoScalerProfile: {
      'balance-similar-node-groups': 'false'
      expander: 'random'
      'scan-interval': '20s'
      'scale-down-delay-after-add': '10m'
      'scale-down-unneeded-time': '10m'
      'scale-down-utilization-threshold': '0.5'
      'skip-nodes-with-local-storage': 'true'
      'skip-nodes-with-system-pods': 'true'
    }
    disableLocalAccounts: true
    dnsPrefix: '${namePrefix}-${suffix}'
    enableRBAC: true
    identityProfile: {
      kubeletidentity: {
        clientId: kubeletIdentityClientId
        objectId: kubeletIdentityPrincipalId
        resourceId: kubeletIdentityResourceId
      }
    }
    kubernetesVersion: kubernetesVersion
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'azure'
      networkDataplane: 'azure'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      loadBalancerProfile: {
        outboundIPs: {
          publicIPs: [
            {
              id: outboundIpId
            }
          ]
        }
      }
      serviceCidr: '10.2.0.0/16'
      dnsServiceIP: '10.2.0.10'
      podCidr: '10.244.0.0/16'
      ipFamilies: [
        'IPv4'
      ]
    }
    nodeResourceGroup: '${namePrefix}-aks-nodes-${suffix}'
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      defender: {
        securityMonitoring: {
          enabled: false
        }
      }
      imageCleaner: {
        enabled: true
        intervalHours: 168
      }
      workloadIdentity: {
        enabled: true
      }
    }
    supportPlan: 'KubernetesOfficial'
  }
}

resource operatorClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cluster.id, operatorPrincipalId, clusterAdminRoleDefinitionId)
  scope: cluster
  properties: {
    roleDefinitionId: clusterAdminRoleDefinitionId
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

resource deploymentClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cluster.id, deploymentPrincipalId, clusterAdminRoleDefinitionId)
  scope: cluster
  properties: {
    roleDefinitionId: clusterAdminRoleDefinitionId
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output clusterId string = cluster.id
output clusterName string = cluster.name
output nodeResourceGroup string = cluster.properties.nodeResourceGroup
output oidcIssuerUrl string = cluster.properties.oidcIssuerProfile.issuerURL
output fqdn string = cluster.properties.fqdn
