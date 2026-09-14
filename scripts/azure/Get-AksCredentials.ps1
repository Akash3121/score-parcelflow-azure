[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [Parameter(Mandatory)][string]$ClusterName,
    [switch]$OverwriteExisting
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Command kubectl
Assert-Command kubelogin

$null = Confirm-AzureTarget `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken

$arguments = @(
    'aks', 'get-credentials',
    '--resource-group', $ResourceGroupName,
    '--name', $ClusterName
)
if ($OverwriteExisting) {
    $arguments += '--overwrite-existing'
}
Invoke-Az -Arguments $arguments

& kubelogin convert-kubeconfig -l azurecli
if ($LASTEXITCODE -ne 0) {
    throw 'kubelogin failed to convert the kubeconfig.'
}

Invoke-WithRetry -Description 'AKS Azure RBAC propagation' -Attempts 30 -DelaySeconds 10 -Operation {
    $namespace = & kubectl get namespace default --output name
    if ($LASTEXITCODE -ne 0 -or ([string]$namespace).Trim() -ne 'namespace/default') {
        throw 'The current principal does not yet have AKS cluster-admin authorization.'
    }
}

Write-Host "Loaded Azure RBAC credentials for AKS cluster '$ClusterName'."
