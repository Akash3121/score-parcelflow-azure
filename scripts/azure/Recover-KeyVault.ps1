[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [string]$VaultName,
    [string]$VaultNamePrefix = 'spf-kv-'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$null = Confirm-AzureTarget `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -ConfirmationToken $ConfirmationToken

$deletedVaults = @(Invoke-AzJson -Arguments @('keyvault', 'list-deleted', '--subscription', $SubscriptionId))
$resourceGroupSegment = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/"
$matches = @($deletedVaults | Where-Object {
    $deletedName = if ($_.name) { $_.name } else { $_.properties.vaultId.Split('/')[-1] }
    $vaultId = [string]$_.properties.vaultId
    $_.properties.location -eq $Location -and
    $vaultId.Contains($resourceGroupSegment, [StringComparison]::OrdinalIgnoreCase) -and
    (($VaultName -and $deletedName -eq $VaultName) -or (-not $VaultName -and $deletedName.StartsWith($VaultNamePrefix)))
})

if ($matches.Count -eq 0) {
    Write-Host 'No matching soft-deleted Key Vault requires recovery.'
    return
}
if ($matches.Count -gt 1) {
    throw "Multiple matching soft-deleted vaults were found. Re-run with -VaultName."
}

$name = if ($matches[0].name) { $matches[0].name } else { $matches[0].properties.vaultId.Split('/')[-1] }
Write-Host "Recovering soft-deleted Key Vault '$name'..."
Invoke-Az -Arguments @('keyvault', 'recover', '--name', $name, '--subscription', $SubscriptionId)
Invoke-WithRetry -Description "Key Vault recovery for $name" -Attempts 30 -DelaySeconds 10 -Operation {
    $null = Invoke-AzJson -Arguments @('keyvault', 'show', '--name', $name, '--resource-group', $ResourceGroupName)
}
