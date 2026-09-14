[CmdletBinding()]
param(
    [switch]$KeepGenerated
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
$docker = Get-Command "docker" -ErrorAction SilentlyContinue
$composeFile = Join-Path $repoRoot "compose.yaml"

if ($null -ne $docker -and (Test-Path $composeFile -PathType Leaf)) {
    Push-Location $repoRoot
    try {
        Invoke-NativeCommand $docker.Source @(
            "compose",
            "--file", $composeFile,
            "down",
            "--volumes",
            "--remove-orphans"
        )
    }
    finally {
        Pop-Location
    }
}

if (-not $KeepGenerated) {
    Remove-Item -Recurse -Force (Join-Path $repoRoot ".score-compose") -ErrorAction SilentlyContinue
    Remove-Item -Force $composeFile -ErrorAction SilentlyContinue
}

Write-Host "ParcelFlow local environment is down."
