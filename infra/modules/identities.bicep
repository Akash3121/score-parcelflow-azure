param location string
param namePrefix string
param suffix string
param tags object

var managedIdentityOperatorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'f1a07417-d97a-45cb-824c-7a7467783830'
)

resource controlPlane 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-aks-control-${suffix}'
  location: location
  tags: tags
}

resource kubelet 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-aks-kubelet-${suffix}'
  location: location
  tags: tags
}

resource api 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-api-${suffix}'
  location: location
  tags: tags
}

resource worker 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-worker-${suffix}'
  location: location
  tags: tags
}

resource bootstrap 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-bootstrap-${suffix}'
  location: location
  tags: tags
}

resource runtimeSecrets 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-runtime-secrets-${suffix}'
  location: location
  tags: tags
}

resource deployment 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-deployment-${suffix}'
  location: location
  tags: tags
}

resource controlPlaneKubeletIdentityOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kubelet.id, controlPlane.id, managedIdentityOperatorRoleDefinitionId)
  scope: kubelet
  properties: {
    roleDefinitionId: managedIdentityOperatorRoleDefinitionId
    principalId: controlPlane.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output controlPlaneResourceId string = controlPlane.id
output controlPlaneClientId string = controlPlane.properties.clientId
output controlPlanePrincipalId string = controlPlane.properties.principalId
output kubeletResourceId string = kubelet.id
output kubeletClientId string = kubelet.properties.clientId
output kubeletPrincipalId string = kubelet.properties.principalId
output apiResourceId string = api.id
output apiClientId string = api.properties.clientId
output apiPrincipalId string = api.properties.principalId
output workerResourceId string = worker.id
output workerClientId string = worker.properties.clientId
output workerPrincipalId string = worker.properties.principalId
output bootstrapResourceId string = bootstrap.id
output bootstrapClientId string = bootstrap.properties.clientId
output bootstrapPrincipalId string = bootstrap.properties.principalId
output runtimeSecretsResourceId string = runtimeSecrets.id
output runtimeSecretsClientId string = runtimeSecrets.properties.clientId
output runtimeSecretsPrincipalId string = runtimeSecrets.properties.principalId
output deploymentResourceId string = deployment.id
output deploymentClientId string = deployment.properties.clientId
output deploymentPrincipalId string = deployment.properties.principalId
