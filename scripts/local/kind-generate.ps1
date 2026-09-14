[CmdletBinding()]
param(
    [string]$ClusterName = "parcelflow",
    [string]$Namespace = "parcelflow",
    [string]$ScoreK8sCommand = $env:SCORE_K8S_COMMAND,
    [switch]$SkipBuild,
    [switch]$SkipLoad,
    [switch]$ResetState
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
$buildSha = Get-BuildSha
$imageTag = Get-ImageTag -BuildSha $buildSha
$apiImage = "parcelflow/parcel-api:$imageTag"
$workerImage = "parcelflow/delivery-worker:$imageTag"

if (-not $SkipBuild) {
    Build-ParcelFlowImages -ApiImage $apiImage -WorkerImage $workerImage
}

if (-not $SkipLoad) {
    $kind = Assert-Command "kind"
    Invoke-NativeCommand $kind @("load", "docker-image", "--name", $ClusterName, $apiImage, $workerImage)
}

$scoreK8s = Resolve-ScoreCommand -Name "score-k8s" -ConfiguredCommand $ScoreK8sCommand
$workDirectory = Join-Path $repoRoot ".kind"
$stateDirectory = Join-Path $workDirectory ".score-k8s"
$outputFile = Join-Path $repoRoot "manifests.yaml"
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
$provisionerFile = [System.IO.Path]::GetRelativePath($workDirectory, (Join-Path $repoRoot "deploy\kind\parcelflow.provisioners.yaml"))
$patchTemplate = [System.IO.Path]::GetRelativePath($workDirectory, (Join-Path $repoRoot "deploy\kind\workload-security.patch.tpl"))
$apiScoreFile = [System.IO.Path]::GetRelativePath($workDirectory, (Join-Path $repoRoot "deploy\score\parcel-api.score.yaml"))
$workerScoreFile = [System.IO.Path]::GetRelativePath($workDirectory, (Join-Path $repoRoot "deploy\score\delivery-worker.score.yaml"))
Remove-Item -Force $outputFile -ErrorAction SilentlyContinue
if ($ResetState) {
    Remove-Item -Recurse -Force $stateDirectory -ErrorAction SilentlyContinue
}

Push-Location $workDirectory
try {
    if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        Invoke-NativeCommand $scoreK8s @(
            "init",
            "--no-sample",
            "--provisioners", $provisionerFile,
            "--patch-templates", $patchTemplate
        )
    }
    Invoke-NativeCommand $scoreK8s @(
        "generate",
        $apiScoreFile,
        "--image", $apiImage,
        "--override-property", "containers.parcel-api.variables.BUILD_SHA=$buildSha",
        "--override-property", "containers.parcel-api.variables.ENVIRONMENT=kind",
        "--override-property", "containers.parcel-api.variables.DATABASE_SSLMODE=disable",
        "--namespace", $Namespace,
        "--generate-namespace",
        "--output", $outputFile
    )
    Invoke-NativeCommand $scoreK8s @(
        "generate",
        $workerScoreFile,
        "--image", $workerImage,
        "--override-property", "containers.delivery-worker.variables.BUILD_SHA=$buildSha",
        "--override-property", "containers.delivery-worker.variables.ENVIRONMENT=kind",
        "--override-property", "containers.delivery-worker.variables.DATABASE_SSLMODE=disable",
        "--namespace", $Namespace,
        "--generate-namespace",
        "--output", $outputFile
    )
}
finally {
    Pop-Location
}

Write-Host "Generated $outputFile from persistent score-k8s state."
Write-Host "API image: $apiImage"
Write-Host "Worker image: $workerImage"
