[CmdletBinding()]
param(
    [string]$ClusterName = "parcelflow",
    [switch]$KeepGenerated
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
$kind = Get-Command "kind" -ErrorAction SilentlyContinue
if ($null -ne $kind) {
    $clusters = @(& $kind.Source get clusters)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Kind clusters."
    }
    if ($clusters -contains $ClusterName) {
        Invoke-NativeCommand $kind.Source @("delete", "cluster", "--name", $ClusterName)
    }
}

if (-not $KeepGenerated) {
    Remove-Item -Recurse -Force (Join-Path $repoRoot ".kind") -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $repoRoot "manifests.yaml") -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $PSScriptRoot "tmp") -ErrorAction SilentlyContinue
}

Write-Host "ParcelFlow Kind environment is down."
