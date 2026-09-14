[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ClusterName,
    [string]$Namespace = 'parcelflow',
    [string]$PrepareManifestHook,
    [string]$PostDeployHook,
    [string]$SmokeHook,
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Command kubectl
Confirm-KubernetesContext -ClusterName $ClusterName

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest '$ManifestPath' does not exist."
}
if ($PrepareManifestHook) {
    & $PrepareManifestHook -ManifestPath $ManifestPath -Namespace $Namespace
}

Invoke-WithRetry -Description 'runtime PostgreSQL Secret synchronization' -Attempts 30 -DelaySeconds 5 -Operation {
    $secretName = & kubectl -n $Namespace get secret parcelflow-postgres --output name
    if ($LASTEXITCODE -ne 0 -or ([string]$secretName).Trim() -ne 'secret/parcelflow-postgres') {
        throw 'The CSI-synchronized runtime Secret is not available yet.'
    }
}

& kubectl apply -f $ManifestPath
if ($LASTEXITCODE -ne 0) {
    throw 'Applying generated Kubernetes manifests failed.'
}

$workloads = @(
    @{ Deployment = 'parcel-api'; ServiceAccount = 'parcel-api'; Container = 'parcel-api' },
    @{ Deployment = 'delivery-worker'; ServiceAccount = 'delivery-worker'; Container = 'delivery-worker' }
)
foreach ($workload in $workloads) {
    $patch = [ordered]@{
        spec = @{
            template = @{
                metadata = @{
                    labels = @{
                        'azure.workload.identity/use' = 'true'
                    }
                }
                spec = @{
                    serviceAccountName = $workload.ServiceAccount
                    automountServiceAccountToken = $true
                }
            }
        }
    } | ConvertTo-Json -Depth 20 -Compress
    & kubectl -n $Namespace patch deployment $workload.Deployment --type strategic --patch $patch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to attach workload identity and runtime CSI secrets to '$($workload.Deployment)'."
    }
}

foreach ($deployment in @('parcel-api', 'delivery-worker')) {
    & kubectl -n $Namespace rollout restart "deployment/$deployment"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart '$deployment' after configuration synchronization."
    }
    & kubectl -n $Namespace rollout status "deployment/$deployment" --timeout="${TimeoutSeconds}s"
    if ($LASTEXITCODE -ne 0) {
        throw "Rollout failed for '$deployment'."
    }
}

if ($PostDeployHook) {
    & $PostDeployHook -Namespace $Namespace
}
if ($SmokeHook) {
    $env:PARCELFLOW_NAMESPACE = $Namespace
    & $SmokeHook
}
Write-Host 'Kubernetes workloads deployed and rollout checks passed.'
