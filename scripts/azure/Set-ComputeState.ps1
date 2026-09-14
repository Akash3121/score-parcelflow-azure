[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Stop')][string]$Action,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [Parameter(Mandatory)][string]$OutputsPath
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

$aks = Invoke-AzJson -Arguments @('aks', 'show', '--resource-group', $ResourceGroupName, '--name', $outputs.aksClusterName)
$postgres = Invoke-AzJson -Arguments @('postgres', 'flexible-server', 'show', '--resource-group', $ResourceGroupName, '--name', $outputs.postgresServerName)
$failures = [System.Collections.Generic.List[string]]::new()

if ($Action -eq 'Stop') {
    if ($aks.powerState.code -ne 'Stopped') {
        try {
            Invoke-Az -Arguments @('aks', 'stop', '--resource-group', $ResourceGroupName, '--name', $outputs.aksClusterName)
        }
        catch {
            $failures.Add("AKS stop failed: $($_.Exception.Message)")
        }
    }
    if ($postgres.state -ne 'Stopped') {
        try {
            Invoke-Az -Arguments @('postgres', 'flexible-server', 'stop', '--resource-group', $ResourceGroupName, '--name', $outputs.postgresServerName)
        }
        catch {
            $failures.Add("PostgreSQL stop failed: $($_.Exception.Message)")
        }
    }
}
else {
    if ($postgres.state -ne 'Ready') {
        try {
            Invoke-Az -Arguments @('postgres', 'flexible-server', 'start', '--resource-group', $ResourceGroupName, '--name', $outputs.postgresServerName)
        }
        catch {
            $failures.Add("PostgreSQL start failed: $($_.Exception.Message)")
        }
    }
    if ($aks.powerState.code -ne 'Running') {
        try {
            Invoke-Az -Arguments @('aks', 'start', '--resource-group', $ResourceGroupName, '--name', $outputs.aksClusterName)
        }
        catch {
            $failures.Add("AKS start failed: $($_.Exception.Message)")
        }
    }
}
if ($failures.Count -gt 0) {
    throw "$Action completed with errors: $($failures -join '; ')"
}
Write-Host "$Action completed for AKS and PostgreSQL. Other Azure services remain billable."
