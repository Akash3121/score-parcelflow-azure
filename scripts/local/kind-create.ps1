[CmdletBinding()]
param(
    [string]$ClusterName = "parcelflow",
    [string]$NodeImage = "kindest/node:v1.34.0"
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-ParcelFlowRepositoryRoot
$docker = Assert-Command "docker"
$kind = Assert-Command "kind"
Invoke-NativeCommand $docker @("info", "--format", "{{.ServerVersion}}")

$clusters = @(& $kind get clusters)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list Kind clusters."
}
if ($clusters -contains $ClusterName) {
    Write-Host "Kind cluster '$ClusterName' already exists."
    return
}

Invoke-NativeCommand $kind @(
    "create", "cluster",
    "--name", $ClusterName,
    "--image", $NodeImage,
    "--config", (Join-Path $repoRoot "deploy\kind\kind-config.yaml")
)
Write-Host "Created Kind cluster '$ClusterName' with node image '$NodeImage'."
