[CmdletBinding()]
param(
    [string]$ClusterName = "parcelflow",
    [string]$Namespace = "parcelflow",
    [int]$LocalPort = 18080,
    [string]$SmokeCommand = $env:PARCELFLOW_SMOKE_COMMAND
)

. (Join-Path $PSScriptRoot "common.ps1")

$kubectl = Assert-Command "kubectl"
$runtimeDirectory = Join-Path $PSScriptRoot "tmp"
New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
$stdoutPath = Join-Path $runtimeDirectory "kind-port-forward.stdout.log"
$stderrPath = Join-Path $runtimeDirectory "kind-port-forward.stderr.log"
Remove-Item -Force $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $kubectl `
    -ArgumentList @(
        "--context", "kind-$ClusterName",
        "--namespace", $Namespace,
        "port-forward", "service/parcel-api",
        "${LocalPort}:8080"
    ) `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

try {
    $baseUrl = "http://127.0.0.1:$LocalPort"
    Wait-HttpEndpoint -Uri "$baseUrl/health/ready" -TimeoutSeconds 120
    & (Join-Path $PSScriptRoot "smoke.ps1") -BaseUrl $baseUrl -SmokeCommand $SmokeCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Kind smoke test failed."
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id
        $process.WaitForExit()
    }
}
