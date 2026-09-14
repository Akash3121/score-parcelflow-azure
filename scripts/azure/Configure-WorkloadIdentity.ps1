[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [Parameter(Mandatory)][string]$OutputsPath,
    [string]$Namespace = 'parcelflow'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$null = Confirm-AzureTarget `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken
$outputs = Read-DeploymentOutputs -Path $OutputsPath

function Set-FederatedCredential {
    param(
        [Parameter(Mandatory)][string]$IdentityName,
        [Parameter(Mandatory)][string]$CredentialName,
        [Parameter(Mandatory)][string]$Subject
    )

    $existing = @(Invoke-AzJson -Arguments @(
        'identity', 'federated-credential', 'list',
        '--resource-group', $ResourceGroupName,
        '--identity-name', $IdentityName
    )) | Where-Object { $_.name -eq $CredentialName } | Select-Object -First 1

    $audience = 'api://AzureADTokenExchange'
    $matches = $existing -and
        $existing.issuer.TrimEnd('/') -eq $outputs.aksOidcIssuerUrl.TrimEnd('/') -and
        $existing.subject -eq $Subject -and
        $audience -in @($existing.audiences)

    if ($matches) {
        Write-Host "Federated credential '$CredentialName' is current."
        return
    }
    if ($existing) {
        Invoke-Az -Arguments @(
            'identity', 'federated-credential', 'delete',
            '--resource-group', $ResourceGroupName,
            '--identity-name', $IdentityName,
            '--name', $CredentialName,
            '--yes'
        )
    }

    Invoke-Az -Arguments @(
        'identity', 'federated-credential', 'create',
        '--resource-group', $ResourceGroupName,
        '--identity-name', $IdentityName,
        '--name', $CredentialName,
        '--issuer', $outputs.aksOidcIssuerUrl,
        '--subject', $Subject,
        '--audiences', $audience
    )
}

function Remove-FederatedCredentialIfPresent {
    param(
        [Parameter(Mandatory)][string]$IdentityName,
        [Parameter(Mandatory)][string]$CredentialName
    )

    $existing = @(Invoke-AzJson -Arguments @(
        'identity', 'federated-credential', 'list',
        '--resource-group', $ResourceGroupName,
        '--identity-name', $IdentityName
    )) | Where-Object { $_.name -eq $CredentialName } | Select-Object -First 1
    if (-not $existing) {
        return
    }

    Invoke-Az -Arguments @(
        'identity', 'federated-credential', 'delete',
        '--resource-group', $ResourceGroupName,
        '--identity-name', $IdentityName,
        '--name', $CredentialName,
        '--yes'
    )
}

$federations = @(
    @{
        Identity = $outputs.apiIdentityName
        Name = 'parcel-api'
        Subject = "system:serviceaccount:${Namespace}:parcel-api"
    },
    @{
        Identity = $outputs.workerIdentityName
        Name = 'delivery-worker'
        Subject = "system:serviceaccount:${Namespace}:delivery-worker"
    },
    @{
        Identity = $outputs.bootstrapIdentityName
        Name = 'postgres-bootstrap'
        Subject = "system:serviceaccount:${Namespace}:postgres-bootstrap"
    },
    @{
        Identity = $outputs.runtimeSecretsIdentityName
        Name = 'runtime-secret-sync'
        Subject = "system:serviceaccount:${Namespace}:runtime-secret-sync"
    }
)

Remove-FederatedCredentialIfPresent `
    -IdentityName $outputs.runtimeSecretsIdentityName `
    -CredentialName 'runtime-parcel-api'
Remove-FederatedCredentialIfPresent `
    -IdentityName $outputs.runtimeSecretsIdentityName `
    -CredentialName 'runtime-delivery-worker'

foreach ($federation in $federations) {
    Set-FederatedCredential `
        -IdentityName $federation.Identity `
        -CredentialName $federation.Name `
        -Subject $federation.Subject
}

function Wait-IdentityRoles {
    param(
        [Parameter(Mandatory)][string]$IdentityName,
        [Parameter(Mandatory)][string[]]$RoleNames
    )

    $identity = Invoke-AzJson -Arguments @(
        'identity', 'show',
        '--resource-group', $ResourceGroupName,
        '--name', $IdentityName
    )
    Invoke-WithRetry -Description "RBAC propagation for $IdentityName" -Attempts 30 -DelaySeconds 10 -Operation {
        $assignments = @(Invoke-AzJson -Arguments @(
            'role', 'assignment', 'list',
            '--assignee-object-id', $identity.principalId,
            '--all'
        ))
        $assignedNames = @($assignments.roleDefinitionName)
        $missing = @($RoleNames | Where-Object { $_ -notin $assignedNames })
        if ($missing.Count -gt 0) {
            throw "Missing roles: $($missing -join ', ')"
        }
    }
}

Wait-IdentityRoles -IdentityName $outputs.apiIdentityName -RoleNames @(
    'Azure Service Bus Data Sender',
    'Storage Blob Data Contributor'
)
Wait-IdentityRoles -IdentityName $outputs.workerIdentityName -RoleNames @(
    'Azure Service Bus Data Receiver'
)
Wait-IdentityRoles -IdentityName $outputs.bootstrapIdentityName -RoleNames @(
    'Key Vault Secrets User'
)
Wait-IdentityRoles -IdentityName $outputs.runtimeSecretsIdentityName -RoleNames @(
    'Key Vault Secrets User'
)

Write-Host 'Workload identity federated credentials are configured.'
