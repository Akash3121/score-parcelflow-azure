[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [Parameter(Mandatory)][string]$OutputsPath,
    [Parameter(Mandatory)][string]$ImageTag,
    [Parameter(Mandatory)][string]$ApiContext,
    [Parameter(Mandatory)][string]$WorkerContext,
    [Parameter(Mandatory)][string]$ApiScoreFile,
    [Parameter(Mandatory)][string]$WorkerScoreFile,
    [string]$ApiDockerfile = 'Dockerfile',
    [string]$WorkerDockerfile = 'Dockerfile',
    [string]$ProvisionerSetupScript,
    [string]$PrepareManifestHook,
    [string]$PostDeployHook,
    [string]$SmokeHook,
    [switch]$SkipSmoke,
    [string]$Namespace = 'parcelflow'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$outputs = Read-DeploymentOutputs -Path $OutputsPath
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$manifestPath = Join-Path $repoRoot '.azure\manifests.generated.yaml'
if (-not $SmokeHook -and -not $SkipSmoke) {
    $SmokeHook = Join-Path $PSScriptRoot 'Invoke-Smoke.ps1'
}

& (Join-Path $PSScriptRoot 'Get-AksCredentials.ps1') `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken -ClusterName $outputs.aksClusterName `
    -OverwriteExisting

& (Join-Path $PSScriptRoot 'Configure-WorkloadIdentity.ps1') `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken -OutputsPath $OutputsPath `
    -Namespace $Namespace

& (Join-Path $PSScriptRoot 'Configure-CsiAndBootstrap.ps1') `
    -TenantId $TenantId -ResourceGroupName $ResourceGroupName -OutputsPath $OutputsPath `
    -ClusterName $outputs.aksClusterName `
    -Namespace $Namespace -DatabaseName $outputs.postgresDatabaseName

& (Join-Path $PSScriptRoot 'Build-PushImages.ps1') `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken `
    -RegistryName $outputs.acrName -ImageTag $ImageTag `
    -ApiContext $ApiContext -WorkerContext $WorkerContext `
    -ApiDockerfile $ApiDockerfile -WorkerDockerfile $WorkerDockerfile

$apiImage = "$($outputs.acrLoginServer)/parcel-api:$ImageTag"
$workerImage = "$($outputs.acrLoginServer)/delivery-worker:$ImageTag"
& (Join-Path $PSScriptRoot 'Sync-ScoreState.ps1') `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken -OutputsPath $OutputsPath `
    -ApiScoreFile $ApiScoreFile -WorkerScoreFile $WorkerScoreFile `
    -ApiImage $apiImage -WorkerImage $workerImage `
    -ManifestPath $manifestPath -Namespace $Namespace `
    -BuildSha $ImageTag -ProvisionerSetupScript $ProvisionerSetupScript

& (Join-Path $PSScriptRoot 'Deploy-Kubernetes.ps1') `
    -ManifestPath $manifestPath -ClusterName $outputs.aksClusterName `
    -Namespace $Namespace `
    -PrepareManifestHook $PrepareManifestHook `
    -PostDeployHook $PostDeployHook -SmokeHook $SmokeHook
