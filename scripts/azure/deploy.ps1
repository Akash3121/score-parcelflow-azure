[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$OperatorPrincipalId,
    [ValidateSet('User', 'Group', 'ServicePrincipal')][string]$OperatorPrincipalType = 'User',
    [string]$ResourceGroupName = 'rg-score-parcelflow-demo',
    [string]$Location = 'centralus',
    [Parameter(Mandatory)][string]$KubernetesVersion,
    [string]$NodeVmSize = 'Standard_D2as_v7',
    [ValidateSet('Standard_B1ms', 'Standard_B2s')][string]$PostgresSkuName = 'Standard_B1ms',
    [string]$BudgetContact,
    [switch]$SkipBudget,
    [Parameter(Mandatory)][string]$ConfirmationToken,
    [string]$CredentialFile,
    [string]$StackName = 'score-parcelflow',
    [string]$OutputPath,
    [switch]$DeployApplication,
    [string]$ImageTag,
    [string]$ApiContext,
    [string]$WorkerContext,
    [string]$ApiScoreFile,
    [string]$WorkerScoreFile,
    [string]$ApiDockerfile = 'deploy\docker\parcel-api.Dockerfile',
    [string]$WorkerDockerfile = 'deploy\docker\delivery-worker.Dockerfile',
    [string]$ProvisionerSetupScript,
    [string]$PrepareManifestHook,
    [string]$PostDeployHook,
    [string]$SmokeHook,
    [switch]$SkipSmoke,
    [string]$Namespace = 'parcelflow'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$workDirectory = Join-Path $repoRoot '.azure'
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
if (-not $OutputPath) {
    $OutputPath = Join-Path $workDirectory 'infra-outputs.json'
}
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
if ($DeployApplication) {
    if ([string]::IsNullOrWhiteSpace($ImageTag)) {
        throw 'ImageTag is required with -DeployApplication; use an immutable commit or release identifier.'
    }
    if (-not $ApiContext) { $ApiContext = $repoRoot }
    if (-not $WorkerContext) { $WorkerContext = $repoRoot }
    if (-not $ApiScoreFile) { $ApiScoreFile = Join-Path $repoRoot 'deploy\score\parcel-api.score.yaml' }
    if (-not $WorkerScoreFile) { $WorkerScoreFile = Join-Path $repoRoot 'deploy\score\delivery-worker.score.yaml' }
}
if (-not $CredentialFile) {
    $CredentialFile = Join-Path $workDirectory 'parcelflow.credentials.secrets.json'
    if (-not (Test-Path -LiteralPath $CredentialFile -PathType Leaf)) {
        & (Join-Path $PSScriptRoot 'New-Credentials.ps1') -OutputPath $CredentialFile
        Write-Host "Created reusable deployment credentials at '$CredentialFile'. Keep this ignored file for safe redeployments."
    }
    else {
        Write-Host "Reusing deployment credentials from '$CredentialFile'."
    }
}
$parameterFile = Join-Path $workDirectory "deploy-$PID.parameters.secrets.json"

try {
    & (Join-Path $PSScriptRoot 'preflight.ps1') `
        -TenantId $TenantId -SubscriptionId $SubscriptionId `
        -OperatorPrincipalId $OperatorPrincipalId -OperatorPrincipalType $OperatorPrincipalType `
        -ResourceGroupName $ResourceGroupName -Location $Location `
        -KubernetesVersion $KubernetesVersion -NodeVmSize $NodeVmSize `
        -PostgresSkuName $PostgresSkuName -BudgetContact $BudgetContact `
        -SkipBudget:$SkipBudget -ConfirmationToken $ConfirmationToken

    & (Join-Path $PSScriptRoot 'Recover-KeyVault.ps1') `
        -TenantId $TenantId -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -Location $Location `
        -ConfirmationToken $ConfirmationToken

    $null = New-DeploymentParameterFile `
        -Path $parameterFile -CredentialPath $CredentialFile `
        -TenantId $TenantId -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -OperatorPrincipalId $OperatorPrincipalId -OperatorPrincipalType $OperatorPrincipalType `
        -Location $Location `
        -KubernetesVersion $KubernetesVersion `
        -ExpirationDate ([DateTime]::UtcNow.AddHours(24).ToString('yyyy-MM-dd')) `
        -PostgresSkuName $PostgresSkuName -DeployBudget (-not $SkipBudget) `
        -BudgetContact $BudgetContact -NodeVmSize $NodeVmSize

    $null = Invoke-AzJson -Arguments @(
        'stack', 'group', 'validate',
        '--name', $StackName,
        '--resource-group', $ResourceGroupName,
        '--template-file', (Join-Path $repoRoot 'infra\main.bicep'),
        '--parameters', "@$parameterFile",
        '--action-on-unmanage', 'deleteResources',
        '--deny-settings-mode', 'none'
    )

    Invoke-Az -Arguments @(
        'stack', 'group', 'create',
        '--name', $StackName,
        '--resource-group', $ResourceGroupName,
        '--template-file', (Join-Path $repoRoot 'infra\main.bicep'),
        '--parameters', "@$parameterFile",
        '--action-on-unmanage', 'deleteResources',
        '--deny-settings-mode', 'none',
        '--yes',
        '--description', 'Score ParcelFlow demo resources; preserves the existing resource group.'
    )

    $stack = Invoke-AzJson -Arguments @(
        'stack', 'group', 'show',
        '--name', $StackName,
        '--resource-group', $ResourceGroupName
    )

    $outputs = [ordered]@{}
    foreach ($property in $stack.outputs.PSObject.Properties) {
        $outputs[$property.Name] = $property.Value.value
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null
    $outputs | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8NoBOM
    Write-Host "Deployment stack '$StackName' completed. Non-secret outputs: '$resolvedOutput'."
}
finally {
    Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
}

if ($DeployApplication) {
    & (Join-Path $PSScriptRoot 'Deploy-Application.ps1') `
        -TenantId $TenantId -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -Location $Location `
        -ConfirmationToken $ConfirmationToken -OutputsPath $resolvedOutput `
        -ImageTag $ImageTag -ApiContext $ApiContext -WorkerContext $WorkerContext `
        -ApiScoreFile $ApiScoreFile -WorkerScoreFile $WorkerScoreFile `
        -ApiDockerfile $ApiDockerfile -WorkerDockerfile $WorkerDockerfile `
        -ProvisionerSetupScript $ProvisionerSetupScript `
        -PrepareManifestHook $PrepareManifestHook `
        -PostDeployHook $PostDeployHook -SmokeHook $SmokeHook `
        -SkipSmoke:$SkipSmoke -Namespace $Namespace
}
else {
    Write-Host 'Infrastructure deployment is complete. Run Deploy-Application.ps1, or use deploy.ps1 -DeployApplication with an immutable -ImageTag, to complete the AKS workload deployment.'
}
