[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [Parameter(Mandatory)][string]$RegistryName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ImageTag,
    [Parameter(Mandatory)][string]$ApiContext,
    [Parameter(Mandatory)][string]$WorkerContext,
    [string]$ApiDockerfile = 'Dockerfile',
    [string]$WorkerDockerfile = 'Dockerfile'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Command az
$null = Confirm-AzureTarget `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken

if ($ImageTag -eq 'latest' -or $ImageTag.Contains(':')) {
    throw 'ImageTag must be an immutable tag value and cannot be latest or contain a colon.'
}
foreach ($path in @($ApiContext, $WorkerContext)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Build context '$path' does not exist."
    }
}

function Resolve-BuildFile {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$Dockerfile
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Dockerfile)) {
        $Dockerfile
    }
    else {
        Join-Path $Context $Dockerfile
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Dockerfile '$candidate' does not exist."
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

$resolvedApiDockerfile = Resolve-BuildFile -Context $ApiContext -Dockerfile $ApiDockerfile
$resolvedWorkerDockerfile = Resolve-BuildFile -Context $WorkerContext -Dockerfile $WorkerDockerfile

function Publish-ImmutableImage {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Dockerfile,
        [Parameter(Mandatory)][string]$Context
    )

    $repositories = @(Invoke-AzJson -Arguments @(
        'acr', 'repository', 'list',
        '--name', $RegistryName
    ))
    $tags = if ($Repository -in $repositories) {
        @(Invoke-AzJson -Arguments @(
            'acr', 'repository', 'show-tags',
            '--name', $RegistryName,
            '--repository', $Repository
        ))
    }
    else {
        @()
    }
    if ($ImageTag -in $tags) {
        Invoke-Az -Arguments @(
            'acr', 'repository', 'update',
            '--name', $RegistryName,
            '--image', "${Repository}:$ImageTag",
            '--write-enabled', 'false',
            '--delete-enabled', 'false'
        )
        Write-Host "Reusing existing immutable image '$Repository`:$ImageTag'."
        return
    }

    & az acr build --registry $RegistryName --image "${Repository}:$ImageTag" --file $Dockerfile $Context --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "$Repository image build failed."
    }
    Invoke-Az -Arguments @(
        'acr', 'repository', 'update',
        '--name', $RegistryName,
        '--image', "${Repository}:$ImageTag",
        '--write-enabled', 'false',
        '--delete-enabled', 'false'
    )
}

Publish-ImmutableImage -Repository 'parcel-api' -Dockerfile $resolvedApiDockerfile -Context $ApiContext
Publish-ImmutableImage -Repository 'delivery-worker' -Dockerfile $resolvedWorkerDockerfile -Context $WorkerContext

Write-Host "Pushed parcel-api:$ImageTag and delivery-worker:$ImageTag to '$RegistryName'."
