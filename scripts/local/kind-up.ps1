[CmdletBinding()]
param(
    [string]$ClusterName = "parcelflow",
    [string]$Namespace = "parcelflow",
    [string]$NodeImage = "kindest/node:v1.34.0",
    [string]$ScoreK8sCommand = $env:SCORE_K8S_COMMAND,
    [switch]$SkipBuild,
    [int]$WaitTimeoutSeconds = 300
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
& (Join-Path $PSScriptRoot "kind-create.ps1") -ClusterName $ClusterName -NodeImage $NodeImage

& (Join-Path $PSScriptRoot "kind-generate.ps1") `
    -ClusterName $ClusterName `
    -Namespace $Namespace `
    -ScoreK8sCommand $ScoreK8sCommand `
    -SkipBuild:$SkipBuild

$kubectl = Assert-Command "kubectl"
$context = "kind-$ClusterName"
$manifest = Join-Path $repoRoot "manifests.yaml"
Invoke-NativeCommand $kubectl @(
    "--context", $context,
    "delete", "namespace", $Namespace,
    "--ignore-not-found=true",
    "--wait=true",
    "--timeout", "${WaitTimeoutSeconds}s"
)
Invoke-NativeCommand $kubectl @("--context", $context, "apply", "--filename", $manifest)
$statefulSets = @(& $kubectl --context $context --namespace $Namespace get statefulset --output name)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list StatefulSets in namespace '$Namespace'."
}
foreach ($statefulSet in $statefulSets) {
    Invoke-NativeCommand $kubectl @(
        "--context", $context,
        "--namespace", $Namespace,
        "rollout", "status", $statefulSet,
        "--timeout", "${WaitTimeoutSeconds}s"
    )
}
Invoke-NativeCommand $kubectl @(
    "--context", $context,
    "--namespace", $Namespace,
    "rollout", "status", "deployment/parcel-api",
    "--timeout", "${WaitTimeoutSeconds}s"
)
Invoke-NativeCommand $kubectl @(
    "--context", $context,
    "--namespace", $Namespace,
    "rollout", "status", "deployment/delivery-worker",
    "--timeout", "${WaitTimeoutSeconds}s"
)

Write-Host "ParcelFlow is running in Kind cluster '$ClusterName'."
