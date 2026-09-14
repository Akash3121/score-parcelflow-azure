[CmdletBinding()]
param(
    [string]$ScoreComposeCommand = $env:SCORE_COMPOSE_COMMAND,
    [string]$BuildSha,
    [string]$ApiImage,
    [string]$WorkerImage,
    [int]$PublishedPort = 8080
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
if ([string]::IsNullOrWhiteSpace($BuildSha)) {
    $BuildSha = Get-BuildSha
}
$imageTag = Get-ImageTag -BuildSha $BuildSha
if ([string]::IsNullOrWhiteSpace($ApiImage)) {
    $ApiImage = "parcelflow/parcel-api:$imageTag"
}
if ([string]::IsNullOrWhiteSpace($WorkerImage)) {
    $WorkerImage = "parcelflow/delivery-worker:$imageTag"
}

$scoreCompose = Resolve-ScoreCommand -Name "score-compose" -ConfiguredCommand $ScoreComposeCommand
$stateDirectory = Join-Path $repoRoot ".score-compose"
$outputFile = Join-Path $repoRoot "compose.yaml"
$provisionerFile = Join-Path "." (Join-Path "deploy" (Join-Path "score-compose" "parcelflow.provisioners.yaml"))
$apiScoreFile = Join-Path "." (Join-Path "deploy" (Join-Path "score" "parcel-api.score.yaml"))
$workerScoreFile = Join-Path "." (Join-Path "deploy" (Join-Path "score" "delivery-worker.score.yaml"))
$backupDirectory = Join-Path $repoRoot ".tmp\score-compose-generate-$PID"
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
if (Test-Path -LiteralPath $stateDirectory) {
    Move-Item -LiteralPath $stateDirectory -Destination (Join-Path $backupDirectory ".score-compose")
}
if (Test-Path -LiteralPath $outputFile) {
    Move-Item -LiteralPath $outputFile -Destination (Join-Path $backupDirectory "compose.yaml")
}

try {
    Push-Location $repoRoot
    try {
        Invoke-NativeCommand $scoreCompose @(
            "init",
            "--no-sample",
            "--project", "parcelflow",
            "--provisioners", $provisionerFile
        )
        Invoke-NativeCommand $scoreCompose @(
            "generate",
            $apiScoreFile,
            "--image", $ApiImage,
            "--override-property", "containers.parcel-api.variables.BUILD_SHA=$BuildSha",
            "--override-property", "containers.parcel-api.variables.ENVIRONMENT=local",
            "--override-property", "containers.parcel-api.variables.DATABASE_SSLMODE=disable",
            "--output", $outputFile
        )
        Invoke-NativeCommand $scoreCompose @(
            "generate",
            $workerScoreFile,
            "--image", $WorkerImage,
            "--override-property", "containers.delivery-worker.variables.BUILD_SHA=$BuildSha",
            "--override-property", "containers.delivery-worker.variables.ENVIRONMENT=local",
            "--override-property", "containers.delivery-worker.variables.DATABASE_SSLMODE=disable",
            "--publish", "${PublishedPort}:parcel-api:8080",
            "--output", $outputFile
        )
    }
    finally {
        Pop-Location
    }
}
catch {
    Remove-Item -Recurse -Force $stateDirectory -ErrorAction SilentlyContinue
    Remove-Item -Force $outputFile -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath (Join-Path $backupDirectory ".score-compose")) {
        Move-Item -LiteralPath (Join-Path $backupDirectory ".score-compose") -Destination $stateDirectory
    }
    if (Test-Path -LiteralPath (Join-Path $backupDirectory "compose.yaml")) {
        Move-Item -LiteralPath (Join-Path $backupDirectory "compose.yaml") -Destination $outputFile
    }
    throw
}
Remove-Item -Recurse -Force $backupDirectory -ErrorAction SilentlyContinue

Write-Host "Generated $outputFile from clean Score state."
Write-Host "API image: $ApiImage"
Write-Host "Worker image: $WorkerImage"
