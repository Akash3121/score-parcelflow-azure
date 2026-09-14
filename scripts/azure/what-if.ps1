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
    [string]$CredentialFile
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$workDirectory = Join-Path $repoRoot '.azure'
New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
$temporaryCredential = -not $CredentialFile
if (-not $CredentialFile) {
    $CredentialFile = Join-Path $workDirectory "what-if-$PID.secrets.json"
    & (Join-Path $PSScriptRoot 'New-Credentials.ps1') -OutputPath $CredentialFile
}
$parameterFile = Join-Path $workDirectory "what-if-$PID.parameters.secrets.json"

try {
    & (Join-Path $PSScriptRoot 'preflight.ps1') `
        -TenantId $TenantId -SubscriptionId $SubscriptionId `
        -OperatorPrincipalId $OperatorPrincipalId -OperatorPrincipalType $OperatorPrincipalType `
        -ResourceGroupName $ResourceGroupName -Location $Location `
        -KubernetesVersion $KubernetesVersion -NodeVmSize $NodeVmSize `
        -PostgresSkuName $PostgresSkuName -BudgetContact $BudgetContact `
        -SkipBudget:$SkipBudget -ConfirmationToken $ConfirmationToken

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
        '--name', 'score-parcelflow',
        '--resource-group', $ResourceGroupName,
        '--template-file', (Join-Path $repoRoot 'infra\main.bicep'),
        '--parameters', "@$parameterFile",
        '--action-on-unmanage', 'deleteResources',
        '--deny-settings-mode', 'none'
    )

    & az deployment group what-if `
        --resource-group $ResourceGroupName `
        --template-file (Join-Path $repoRoot 'infra\main.bicep') `
        --parameters "@$parameterFile" `
        --result-format FullResourcePayloads `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure deployment what-if failed.'
    }
}
finally {
    Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    if ($temporaryCredential) {
        Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue
    }
}
