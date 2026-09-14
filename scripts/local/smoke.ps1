[CmdletBinding()]
param(
    [string]$BaseUrl = "http://127.0.0.1:8080",
    [string]$SmokeCommand = $env:PARCELFLOW_SMOKE_COMMAND,
    [int]$ReadyTimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
Wait-HttpEndpoint -Uri "$BaseUrl/health/live" -TimeoutSeconds $ReadyTimeoutSeconds
Wait-HttpEndpoint -Uri "$BaseUrl/health/ready" -TimeoutSeconds $ReadyTimeoutSeconds

$previousBaseUrl = $env:PARCELFLOW_BASE_URL
$previousFixture = $env:PARCELFLOW_PROOF_FIXTURE
$env:PARCELFLOW_BASE_URL = $BaseUrl
if ([string]::IsNullOrWhiteSpace($env:PARCELFLOW_PROOF_FIXTURE)) {
    $env:PARCELFLOW_PROOF_FIXTURE = Join-Path $repoRoot "testdata\proof.pdf"
}
try {
    if (-not [string]::IsNullOrWhiteSpace($SmokeCommand)) {
        $resolvedSmoke = if (Test-Path $SmokeCommand -PathType Leaf) {
            (Resolve-Path $SmokeCommand).Path
        }
        else {
            (Get-Command $SmokeCommand -ErrorAction Stop).Source
        }
        Invoke-NativeCommand $resolvedSmoke
    }
    elseif (Test-Path (Join-Path $repoRoot "cmd\smoke") -PathType Container) {
        $go = Assert-Command "go"
        Push-Location $repoRoot
        try {
            Invoke-NativeCommand $go @("run", (Join-Path "." (Join-Path "cmd" "smoke")))
        }
        finally {
            Pop-Location
        }
    }
    else {
        throw "No smoke executable was configured and cmd/smoke is missing."
    }
}
finally {
    $env:PARCELFLOW_BASE_URL = $previousBaseUrl
    $env:PARCELFLOW_PROOF_FIXTURE = $previousFixture
}

Write-Host "ParcelFlow smoke test passed against $BaseUrl."
