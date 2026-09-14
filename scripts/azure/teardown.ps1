[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [string]$StackName = 'score-parcelflow',
    [string]$OutputsPath,
    [switch]$PurgeKeyVault
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$null = Confirm-AzureTarget `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken

$outputs = $null
if ($OutputsPath -and (Test-Path -LiteralPath $OutputsPath)) {
    $outputs = Read-DeploymentOutputs -Path $OutputsPath
}
else {
    $stack = Invoke-AzJson -Arguments @(
        'stack', 'group', 'show',
        '--name', $StackName,
        '--resource-group', $ResourceGroupName
    )
    $flat = [ordered]@{}
    if ($stack.outputs) {
        foreach ($property in $stack.outputs.PSObject.Properties) {
            $flat[$property.Name] = $property.Value.value
        }
    }
    $outputs = [pscustomobject]$flat
}

$nodeResourceGroup = if ($outputs.PSObject.Properties.Name -contains 'aksNodeResourceGroup') {
    $outputs.aksNodeResourceGroup
}
else {
    $clusters = @(Invoke-AzJson -Arguments @('aks', 'list', '--resource-group', $ResourceGroupName))
    ($clusters | Where-Object { $_.tags.project -eq 'score-parcelflow' } | Select-Object -First 1).nodeResourceGroup
}
$vaultName = if ($outputs.PSObject.Properties.Name -contains 'keyVaultName') {
    $outputs.keyVaultName
}
else {
    $vaults = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.KeyVault/vaults',
        '--tag', 'project=score-parcelflow'
    ))
    ($vaults | Select-Object -First 1).name
}
Invoke-Az -Arguments @(
    'stack', 'group', 'delete',
    '--name', $StackName,
    '--resource-group', $ResourceGroupName,
    '--action-on-unmanage', 'deleteResources',
    '--yes'
)

$remainingStacks = @(Invoke-AzJson -Arguments @(
    'stack', 'group', 'list',
    '--resource-group', $ResourceGroupName
))
if ($remainingStacks.name -contains $StackName) {
    throw "Deployment stack '$StackName' still exists after deletion."
}

if ($nodeResourceGroup) {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $exists = & az group exists --name $nodeResourceGroup --output tsv
        if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect the AKS node resource group.' }
        if ($exists -eq 'false') { break }
        Start-Sleep -Seconds 10
    }

    $nodeGroupStillExists = (& az group exists --name $nodeResourceGroup --output tsv) -eq 'true'
    if ($nodeGroupStillExists) {
        Write-Warning "AKS node resource group '$nodeResourceGroup' remained after stack deletion; deleting the orphan."
        Invoke-Az -Arguments @('group', 'delete', '--name', $nodeResourceGroup, '--yes')
    }
    if ((& az group exists --name $nodeResourceGroup --output tsv) -ne 'false') {
        throw "AKS node resource group '$nodeResourceGroup' still exists after cleanup."
    }
}

$remaining = @(Invoke-AzJson -Arguments @(
    'resource', 'list',
    '--resource-group', $ResourceGroupName,
    '--tag', 'project=score-parcelflow'
))
if ($remaining.Count -gt 0) {
    throw "Teardown verification found repository-owned resources: $($remaining.id -join ', ')"
}
if ((& az group exists --name $ResourceGroupName --output tsv) -ne 'true') {
    throw "Existing resource group '$ResourceGroupName' was unexpectedly deleted."
}

if ($PurgeKeyVault -and $vaultName) {
    $deleted = @(Invoke-AzJson -Arguments @('keyvault', 'list-deleted', '--subscription', $SubscriptionId))
    if ($deleted | Where-Object { $_.name -eq $vaultName }) {
        Invoke-Az -Arguments @('keyvault', 'purge', '--name', $vaultName, '--location', $Location)
        Write-Host "Purged soft-deleted Key Vault '$vaultName'."
    }
}

Write-Host "Deployment stack '$StackName' was removed; resource group '$ResourceGroupName' was preserved."
