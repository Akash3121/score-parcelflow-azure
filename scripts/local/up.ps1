[CmdletBinding()]
param(
    [string]$ScoreComposeCommand = $env:SCORE_COMPOSE_COMMAND,
    [switch]$SkipBuild,
    [int]$PublishedPort = 8080
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
$docker = Assert-Command "docker"
Invoke-NativeCommand $docker @("info", "--format", "{{.ServerVersion}}")

$buildSha = Get-BuildSha
$imageTag = Get-ImageTag -BuildSha $buildSha
$apiImage = "parcelflow/parcel-api:$imageTag"
$workerImage = "parcelflow/delivery-worker:$imageTag"

if (-not $SkipBuild) {
    Build-ParcelFlowImages -ApiImage $apiImage -WorkerImage $workerImage
}

& (Join-Path $PSScriptRoot "generate.ps1") `
    -ScoreComposeCommand $ScoreComposeCommand `
    -BuildSha $buildSha `
    -ApiImage $apiImage `
    -WorkerImage $workerImage `
    -PublishedPort $PublishedPort
Push-Location $repoRoot
try {
    Invoke-NativeCommand $docker @(
        "compose",
        "--file", (Join-Path $repoRoot "compose.yaml"),
        "up",
        "--detach",
        "--remove-orphans"
    )
}
finally {
    Pop-Location
}

Wait-HttpEndpoint -Uri "http://127.0.0.1:$PublishedPort/health/live" -TimeoutSeconds 180
Wait-HttpEndpoint -Uri "http://127.0.0.1:$PublishedPort/health/ready" -TimeoutSeconds 180
Write-Host "ParcelFlow is ready at http://127.0.0.1:$PublishedPort."
