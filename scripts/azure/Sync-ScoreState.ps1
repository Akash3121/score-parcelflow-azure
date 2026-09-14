[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [Parameter(Mandatory)][string]$OutputsPath,
    [Parameter(Mandatory)][string]$ApiScoreFile,
    [Parameter(Mandatory)][string]$WorkerScoreFile,
    [Parameter(Mandatory)][string]$ApiImage,
    [Parameter(Mandatory)][string]$WorkerImage,
    [string]$ManifestPath,
    [string]$StateBlobName = 'score-k8s-state.zip',
    [string]$LockBlobName = 'locks/score-k8s-state.lock',
    [string]$Namespace = 'parcelflow',
    [string]$BuildSha,
    [string]$ProvisionerSetupScript
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-Command az
Assert-Command score-k8s

$null = Confirm-AzureTarget `
    -TenantId $TenantId -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName -Location $Location `
    -ConfirmationToken $ConfirmationToken
$outputs = Read-DeploymentOutputs -Path $OutputsPath
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$workDirectory = Join-Path $repoRoot '.azure'
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
$scoreWorkDirectory = Join-Path $workDirectory 'score-work'
New-Item -ItemType Directory -Path $scoreWorkDirectory -Force | Out-Null
$StateDirectory = Join-Path $scoreWorkDirectory '.score-k8s'
if (-not $ManifestPath) { $ManifestPath = Join-Path $workDirectory 'manifests.generated.yaml' }
$provisionerFile = Join-Path $workDirectory 'parcelflow.azure.provisioners.yaml'
if (-not $BuildSha) { $BuildSha = ($ApiImage -split ':')[-1] }
$archivePath = Join-Path $workDirectory "score-state-$PID.zip"
$emptyPath = Join-Path $workDirectory "lease-$PID.empty"
$leaseId = $null
$runnerIp = $null
$restoreDefaultAction = $null
$removeRunnerRule = $false

try {
    $runnerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
    $parsedIp = $null
    if (
        -not [System.Net.IPAddress]::TryParse($runnerIp, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw 'Could not determine a valid runner public IPv4 address.'
    }

    $account = Invoke-AzJson -Arguments @(
        'storage', 'account', 'show',
        '--resource-group', $ResourceGroupName,
        '--name', $outputs.storageAccountName
    )
    $runnerRuleExists = @($account.networkRuleSet.ipRules) |
        Where-Object { $_.ipAddressOrRange -eq $runnerIp } |
        Select-Object -First 1
    if (-not $runnerRuleExists) {
        Invoke-Az -Arguments @(
            'storage', 'account', 'network-rule', 'add',
            '--resource-group', $ResourceGroupName,
            '--account-name', $outputs.storageAccountName,
            '--ip-address', $runnerIp
        )
        $removeRunnerRule = $true
    }

    try {
        Invoke-WithRetry -Description 'Storage firewall propagation' -Attempts 6 -DelaySeconds 10 -Operation {
            $null = Invoke-AzJson -Arguments @(
                'storage', 'container', 'show',
                '--account-name', $outputs.storageAccountName,
                '--name', $outputs.stateContainerName,
                '--auth-mode', 'login'
            )
        }
    }
    catch {
        if ($account.networkRuleSet.defaultAction -ne 'Deny') {
            throw
        }

        Write-Warning 'The IPv4 runner rule did not authorize the data-plane connection. Temporarily allowing authenticated public access; shared-key and anonymous access remain disabled.'
        Invoke-Az -Arguments @(
            'storage', 'account', 'update',
            '--resource-group', $ResourceGroupName,
            '--name', $outputs.storageAccountName,
            '--default-action', 'Allow'
        )
        $restoreDefaultAction = 'Deny'
        Invoke-WithRetry -Description 'Storage authenticated-public-access propagation' -Attempts 6 -DelaySeconds 10 -Operation {
            $null = Invoke-AzJson -Arguments @(
                'storage', 'container', 'show',
                '--account-name', $outputs.storageAccountName,
                '--name', $outputs.stateContainerName,
                '--auth-mode', 'login'
            )
        }
    }

    '' | Set-Content -LiteralPath $emptyPath -NoNewline
    $lockExists = & az storage blob exists `
        --account-name $outputs.storageAccountName `
        --container-name $outputs.stateContainerName `
        --name $LockBlobName --auth-mode login `
        --query exists --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect the Score state lock blob.' }
    $lockExists = ([string]$lockExists).Trim().ToLowerInvariant()
    if ($lockExists -ne 'true') {
        & az storage blob upload `
            --account-name $outputs.storageAccountName `
            --container-name $outputs.stateContainerName `
            --name $LockBlobName --file $emptyPath `
            --auth-mode login --overwrite false --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the Score state lock blob.' }
    }

    $leaseId = & az storage blob lease acquire `
        --account-name $outputs.storageAccountName `
        --container-name $outputs.stateContainerName `
        --blob-name $LockBlobName --lease-duration -1 `
        --auth-mode login --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($leaseId)) {
        throw 'Could not acquire the Score state lease; another deployment may be active.'
    }
    $leaseId = ([string]$leaseId).Trim()

    $stateExists = & az storage blob exists `
        --account-name $outputs.storageAccountName `
        --container-name $outputs.stateContainerName `
        --name $StateBlobName --auth-mode login `
        --query exists --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect the Score state blob.' }
    $stateExists = ([string]$stateExists).Trim().ToLowerInvariant()

    Remove-Item -LiteralPath $StateDirectory -Recurse -Force -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot 'New-ScoreProvisioners.ps1') `
        -OutputsPath $OutputsPath -OutputPath $provisionerFile
    if ($stateExists -eq 'true') {
        & az storage blob download `
            --account-name $outputs.storageAccountName `
            --container-name $outputs.stateContainerName `
            --name $StateBlobName --file $archivePath `
            --auth-mode login --overwrite true --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw 'Failed to download Score state.' }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $StateDirectory -Force
    }
    else {
        Push-Location $scoreWorkDirectory
        try {
            & score-k8s init --no-sample --provisioners $provisionerFile
            if ($LASTEXITCODE -ne 0) { throw 'score-k8s init failed.' }
        }
        finally {
            Pop-Location
        }
    }

    if ($ProvisionerSetupScript) {
        & $ProvisionerSetupScript -StateDirectory $StateDirectory -OutputsPath $OutputsPath
    }

    Push-Location $scoreWorkDirectory
    try {
        Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
        & score-k8s generate $ApiScoreFile `
            --image $ApiImage `
            --override-property "containers.parcel-api.variables.BUILD_SHA=$BuildSha" `
            --override-property 'containers.parcel-api.variables.ENVIRONMENT=azure' `
            --namespace $Namespace --generate-namespace --output $ManifestPath
        if ($LASTEXITCODE -ne 0) { throw 'score-k8s generation failed for parcel-api.' }
        & score-k8s generate $WorkerScoreFile `
            --image $WorkerImage `
            --override-property "containers.delivery-worker.variables.BUILD_SHA=$BuildSha" `
            --override-property 'containers.delivery-worker.variables.ENVIRONMENT=azure' `
            --namespace $Namespace --generate-namespace --output $ManifestPath
        if ($LASTEXITCODE -ne 0) { throw 'score-k8s generation failed for delivery-worker.' }
    }
    finally {
        Pop-Location
    }

    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $StateDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal
    & az storage blob upload `
        --account-name $outputs.storageAccountName `
        --container-name $outputs.stateContainerName `
        --name $StateBlobName --file $archivePath `
        --auth-mode login --overwrite true --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to upload Score state.' }
    Write-Host "Generated '$ManifestPath' and uploaded the protected Score state."
}
finally {
    $cleanupFailures = [System.Collections.Generic.List[string]]::new()
    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    if ($leaseId) {
        & az storage blob lease release `
            --account-name $outputs.storageAccountName `
            --container-name $outputs.stateContainerName `
            --blob-name $LockBlobName --lease-id $leaseId `
            --auth-mode login --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add('release the Score state lease')
        }
    }
    if ($restoreDefaultAction) {
        & az storage account update `
            --resource-group $ResourceGroupName `
            --name $outputs.storageAccountName `
            --default-action $restoreDefaultAction --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add("restore the Storage firewall default action to '$restoreDefaultAction'")
        }
    }
    if ($removeRunnerRule) {
        & az storage account network-rule remove `
            --resource-group $ResourceGroupName `
            --account-name $outputs.storageAccountName `
            --ip-address $runnerIp --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures.Add("remove temporary Storage firewall rule '$runnerIp'")
        }
    }
    $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    Remove-Item -LiteralPath $archivePath, $emptyPath -Force -ErrorAction SilentlyContinue
    if ($cleanupFailures.Count -gt 0) {
        throw "Score state cleanup failed: $($cleanupFailures -join '; '). Manual remediation is required."
    }
}
