Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ParcelFlowRepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Assert-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command '$Name' was not found on PATH."
    }
    return $command.Source
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$FilePath $($ArgumentList -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Resolve-ScoreCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("score-compose", "score-k8s")]
        [string]$Name,

        [Parameter()]
        [string]$ConfiguredCommand
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredCommand)) {
        if (Test-Path $ConfiguredCommand -PathType Leaf) {
            return (Resolve-Path $ConfiguredCommand).Path
        }
        $configured = Get-Command $ConfiguredCommand -ErrorAction SilentlyContinue
        if ($null -ne $configured) {
            return $configured.Source
        }
        throw "Configured $Name command '$ConfiguredCommand' does not exist."
    }

    $installed = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $installed) {
        return $installed.Source
    }

    $repoRoot = Get-ParcelFlowRepositoryRoot
    $siblingsRoot = Split-Path $repoRoot -Parent
    $sourceRoot = Join-Path $siblingsRoot $Name
    $isWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
    $executableName = if ($isWindowsPlatform) { "$Name.exe" } else { $Name }
    $candidates = @(
        (Join-Path $repoRoot "bin\$executableName"),
        (Join-Path $sourceRoot $executableName),
        (Join-Path $sourceRoot "bin\$executableName")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate -PathType Leaf) {
            return (Resolve-Path $candidate).Path
        }
    }

    if (-not (Test-Path (Join-Path $sourceRoot "go.mod") -PathType Leaf)) {
        throw "$Name was not found and sibling source '$sourceRoot' is unavailable."
    }

    $go = Assert-Command "go"
    $toolsDirectory = Join-Path $PSScriptRoot "bin"
    New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null
    $builtCommand = Join-Path $toolsDirectory $executableName

    Push-Location $sourceRoot
    try {
        Invoke-NativeCommand $go @("build", "-o", $builtCommand, (Join-Path "." (Join-Path "cmd" $Name)))
    }
    finally {
        Pop-Location
    }

    return $builtCommand
}

function Get-BuildSha {
    $repoRoot = Get-ParcelFlowRepositoryRoot
    $git = Assert-Command "git"
    Push-Location $repoRoot
    try {
        $sha = (& $git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
            throw "Unable to determine the Git commit."
        }
        $status = & $git status --porcelain
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect the Git working tree."
        }
        if ($status) {
            return "${sha}-dirty"
        }
        return $sha
    }
    finally {
        Pop-Location
    }
}

function Get-ImageTag {
    param([Parameter(Mandatory = $true)][string]$BuildSha)

    if ($BuildSha.EndsWith("-dirty")) {
        return "$($BuildSha.Substring(0, 8))-dirty"
    }
    return $BuildSha.Substring(0, [Math]::Min(12, $BuildSha.Length))
}

function Wait-HttpEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter()]
        [int]$TimeoutSeconds = 120
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 5 -UseBasicParsing
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                return
            }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Timed out waiting for '$Uri'."
}

function Build-ParcelFlowImages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiImage,

        [Parameter(Mandatory = $true)]
        [string]$WorkerImage
    )

    $docker = Assert-Command "docker"
    $repoRoot = Get-ParcelFlowRepositoryRoot
    Invoke-NativeCommand $docker @(
        "build",
        "--file", (Join-Path $repoRoot "deploy\docker\parcel-api.Dockerfile"),
        "--tag", $ApiImage,
        $repoRoot
    )
    Invoke-NativeCommand $docker @(
        "build",
        "--file", (Join-Path $repoRoot "deploy\docker\delivery-worker.Dockerfile"),
        "--tag", $WorkerImage,
        $repoRoot
    )
}
