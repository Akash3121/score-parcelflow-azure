[CmdletBinding()]
param(
    [string]$Namespace,
    [int]$LocalPort = 8080,
    [string]$FixturePath,
    [int]$ReadyTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Command kubectl
Assert-Command go

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Namespace) {
    $Namespace = if ($env:PARCELFLOW_NAMESPACE) { $env:PARCELFLOW_NAMESPACE } else { 'parcelflow' }
}
if (-not $FixturePath) {
    $FixturePath = Join-Path $repoRoot 'testdata\proof.pdf'
}

$portForward = Start-Process `
    -FilePath (Get-Command kubectl).Source `
    -ArgumentList @('-n', $Namespace, 'port-forward', 'service/parcel-api', "${LocalPort}:8080") `
    -PassThru -NoNewWindow
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    do {
        if ($portForward.HasExited) {
            throw "kubectl port-forward exited with code $($portForward.ExitCode)."
        }
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/health/ready" -TimeoutSec 3
            if ($response.StatusCode -eq 200) { break }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if ([DateTime]::UtcNow -ge $deadline) {
        throw 'Timed out waiting for the port-forwarded API readiness endpoint.'
    }

    Push-Location $repoRoot
    try {
        & go run ./cmd/smoke `
            --base-url "http://127.0.0.1:$LocalPort" `
            --fixture $FixturePath `
            --timeout 2m
        if ($LASTEXITCODE -ne 0) {
            throw 'ParcelFlow cloud smoke test failed.'
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($portForward -and -not $portForward.HasExited) {
        Stop-Process -Id $portForward.Id -ErrorAction SilentlyContinue
        $portForward.WaitForExit(5000)
    }
}
