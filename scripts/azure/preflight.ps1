[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OperatorPrincipalId,
    [ValidateSet('User', 'Group', 'ServicePrincipal')][string]$OperatorPrincipalType = 'User',
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$KubernetesVersion,
    [string]$NodeVmSize = 'Standard_D2as_v7',
    [ValidateSet('Standard_B1ms', 'Standard_B2s')][string]$PostgresSkuName = 'Standard_B1ms',
    [int]$MaximumNodeCount = 3,
    [string]$BudgetContact,
    [switch]$SkipBudget,
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$target = Confirm-AzureTarget `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -ConfirmationToken $ConfirmationToken
Write-Host "Confirmed tenant $($target.TenantId), subscription $($target.SubscriptionId), resource group $($target.ResourceGroupName) (metadata region $($target.ResourceGroupLocation)), deployment region $($target.Location)."

$providers = @(
    'Microsoft.Authorization',
    'Microsoft.Compute',
    'Microsoft.Consumption',
    'Microsoft.ContainerRegistry',
    'Microsoft.ContainerService',
    'Microsoft.DBforPostgreSQL',
    'Microsoft.Insights',
    'Microsoft.KeyVault',
    'Microsoft.ManagedIdentity',
    'Microsoft.Network',
    'Microsoft.OperationalInsights',
    'Microsoft.ServiceBus',
    'Microsoft.Storage'
)

foreach ($provider in $providers) {
    $state = (Invoke-AzJson -Arguments @('provider', 'show', '--namespace', $provider)).registrationState
    if ($state -ne 'Registered') {
        Write-Host "Registering $provider..."
        Invoke-Az -Arguments @('provider', 'register', '--namespace', $provider)
    }
}

foreach ($provider in $providers) {
    Invoke-WithRetry -Description "provider registration for $provider" -Attempts 30 -DelaySeconds 10 -Operation {
        $state = (Invoke-AzJson -Arguments @('provider', 'show', '--namespace', $provider)).registrationState
        if ($state -ne 'Registered') {
            throw "$provider is $state"
        }
    }
}

$aksVersions = Invoke-AzJson -Arguments @('aks', 'get-versions', '--location', $Location)
$supportedVersions = @($aksVersions.values | ForEach-Object {
    if ($_.version) { $_.version }
    if ($_.patchVersions) { $_.patchVersions.PSObject.Properties.Name }
}) | Sort-Object -Unique
if ($KubernetesVersion -notin $supportedVersions) {
    throw "AKS version '$KubernetesVersion' is not supported in '$Location'. Supported versions: $($supportedVersions -join ', ')."
}

$vmSku = @(Invoke-AzJson -Arguments @(
    'vm', 'list-skus', '--location', $Location, '--resource-type', 'virtualMachines',
    '--size', $NodeVmSize, '--all'
)) | Where-Object { $_.name -eq $NodeVmSize }
if ($vmSku.Count -eq 0) {
    throw "VM SKU '$NodeVmSize' is not advertised in '$Location'."
}
$locationRestrictions = @($vmSku[0].restrictions | Where-Object { $_.type -eq 'Location' })
if ($locationRestrictions.Count -gt 0) {
    throw "VM SKU '$NodeVmSize' is restricted for this subscription in '$Location': $($locationRestrictions | ConvertTo-Json -Compress -Depth 10)"
}

$vCpuCapability = $vmSku[0].capabilities | Where-Object { $_.name -eq 'vCPUs' } | Select-Object -First 1
$vCpusPerNode = if ($vCpuCapability) { [int]$vCpuCapability.value } else { 2 }
$requiredVcpus = $vCpusPerNode * $MaximumNodeCount
$usage = @(Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', $Location))
$regional = $usage | Where-Object { $_.name.value -eq 'cores' -or $_.name.value -eq 'Total Regional vCPUs' } | Select-Object -First 1
if ($regional -and (($regional.limit - $regional.currentValue) -lt $requiredVcpus)) {
    throw "Insufficient regional vCPU quota: $($regional.limit - $regional.currentValue) available, $requiredVcpus required."
}
$familyName = $vmSku[0].family
$familyUsage = $usage | Where-Object { $_.name.value -eq $familyName } | Select-Object -First 1
if ($familyUsage -and (($familyUsage.limit - $familyUsage.currentValue) -lt $requiredVcpus)) {
    throw "Insufficient '$familyName' quota: $($familyUsage.limit - $familyUsage.currentValue) available, $requiredVcpus required."
}

$postgresSkus = @(Invoke-AzJson -Arguments @('postgres', 'flexible-server', 'list-skus', '--location', $Location))
$postgresSkuJson = $postgresSkus | ConvertTo-Json -Depth 100 -Compress
if ($postgresSkuJson -notmatch ('"' + [regex]::Escape($PostgresSkuName) + '"')) {
    if ($PostgresSkuName -eq 'Standard_B1ms' -and $postgresSkuJson -match '"Standard_B2s"') {
        Write-Warning "Standard_B1ms is unavailable in '$Location'; use -PostgresSkuName Standard_B2s."
    }
    throw "PostgreSQL SKU '$PostgresSkuName' is not available in '$Location'."
}

if (-not $SkipBudget) {
    if ([string]::IsNullOrWhiteSpace($BudgetContact)) {
        throw 'BudgetContact is required unless -SkipBudget is supplied.'
    }
    try {
        $null = Invoke-AzJson -Arguments @('consumption', 'budget', 'list', '--resource-group', $ResourceGroupName)
    }
    catch {
        throw "Resource-group budgets are unavailable for this subscription. Re-run with -SkipBudget and deploy with -SkipBudget. $($_.Exception.Message)"
    }
}

$result = [ordered]@{
    tenantId = $TenantId
    subscriptionId = $SubscriptionId
    resourceGroupName = $ResourceGroupName
    location = $Location
    kubernetesVersion = $KubernetesVersion
    nodeVmSize = $NodeVmSize
    postgresSkuName = $PostgresSkuName
    operatorPrincipalId = $OperatorPrincipalId
    operatorPrincipalType = $OperatorPrincipalType
    budgetSupported = -not $SkipBudget
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
}

if ($OutputPath) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null
    $result | ConvertTo-Json | Set-Content -LiteralPath $resolvedOutput -Encoding utf8NoBOM
}
$result | Format-List
