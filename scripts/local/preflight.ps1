[CmdletBinding()]
param(
    [switch]$RequireKind,
    [string]$ScoreComposeCommand = $env:SCORE_COMPOSE_COMMAND,
    [string]$ScoreK8sCommand = $env:SCORE_K8S_COMMAND
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
Assert-Command "git" | Out-Null
$docker = Assert-Command "docker"
Invoke-NativeCommand $docker @("info", "--format", "{{.ServerVersion}}")
Invoke-NativeCommand $docker @("compose", "version")

$scoreCompose = Resolve-ScoreCommand -Name "score-compose" -ConfiguredCommand $ScoreComposeCommand
Invoke-NativeCommand $scoreCompose @("version")

if ($RequireKind) {
    $kind = Assert-Command "kind"
    $kubectl = Assert-Command "kubectl"
    Invoke-NativeCommand $kind @("version")
    Invoke-NativeCommand $kubectl @("version", "--client")
    $scoreK8s = Resolve-ScoreCommand -Name "score-k8s" -ConfiguredCommand $ScoreK8sCommand
    Invoke-NativeCommand $scoreK8s @("version")
}

$requiredFiles = @(
    "deploy\score\parcel-api.score.yaml",
    "deploy\score\delivery-worker.score.yaml",
    "deploy\score-compose\parcelflow.provisioners.yaml"
)
if ($RequireKind) {
    $requiredFiles += @(
        "deploy\kind\kind-config.yaml",
        "deploy\kind\parcelflow.provisioners.yaml",
        "deploy\kind\workload-security.patch.tpl"
    )
}
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path (Join-Path $repoRoot $relativePath) -PathType Leaf)) {
        throw "Required file '$relativePath' is missing."
    }
}

Write-Host "ParcelFlow local preflight passed."
