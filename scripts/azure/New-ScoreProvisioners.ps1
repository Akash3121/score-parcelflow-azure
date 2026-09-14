[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputsPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$outputs = Read-DeploymentOutputs -Path $OutputsPath
$content = @"
- uri: template://parcelflow-azure/postgres
  type: postgres
  class: default
  description: Attaches the private Azure Database for PostgreSQL Flexible Server.
  state: |
    host: "$($outputs.postgresHost)"
    port: "5432"
    name: "$($outputs.postgresDatabaseName)"
  outputs: |
    host: {{ .State.host | quote }}
    port: {{ .State.port | quote }}
    name: {{ .State.name | quote }}
    username: {{ encodeSecretRef "parcelflow-postgres" "username" }}
    password: {{ encodeSecretRef "parcelflow-postgres" "password" }}
  manifests: |
    []
  expected_outputs:
    - host
    - port
    - name
    - username
    - password

- uri: template://parcelflow-azure/message-queue
  type: message-queue
  class: default
  description: Attaches the Azure Service Bus delivery command queue.
  state: |
    endpoint: "$($outputs.serviceBusEndpoint)"
    queue: "$($outputs.serviceBusQueueName)"
  outputs: |
    provider: azure-servicebus
    endpoint: {{ .State.endpoint | quote }}
    queue: {{ .State.queue | quote }}
    credentialMode: workload-identity
    username: ""
    password: ""
  manifests: |
    []
  expected_outputs:
    - provider
    - endpoint
    - queue
    - credentialMode
    - username
    - password

- uri: template://parcelflow-azure/object-store
  type: object-store
  class: default
  description: Attaches the private proof Blob container.
  state: |
    endpoint: "https://$($outputs.storageAccountName).blob.core.windows.net"
    container: "$($outputs.proofContainerName)"
    accountName: "$($outputs.storageAccountName)"
  outputs: |
    provider: azure-blob
    endpoint: {{ .State.endpoint | quote }}
    container: {{ .State.container | quote }}
    credentialMode: workload-identity
    accountName: {{ .State.accountName | quote }}
    accountKey: ""
  manifests: |
    []
  expected_outputs:
    - provider
    - endpoint
    - container
    - credentialMode
    - accountName
    - accountKey
"@

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null
$content | Set-Content -LiteralPath $resolvedOutput -Encoding utf8NoBOM
Write-Host "Generated secret-free Azure Score provisioners at '$resolvedOutput'."
