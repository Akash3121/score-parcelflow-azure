Set-StrictMode -Version Latest

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
    if ([string]::IsNullOrWhiteSpace(($result -join [Environment]::NewLine))) {
        return $null
    }
    return (($result -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100)
}

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}

function Confirm-AzureTarget {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$ConfirmationToken
    )

    Assert-Command az
    Invoke-Az -Arguments @('account', 'set', '--subscription', $SubscriptionId)
    $account = Invoke-AzJson -Arguments @('account', 'show')
    if ($account.id -ne $SubscriptionId) {
        throw "Active subscription '$($account.id)' does not match '$SubscriptionId'."
    }
    if ($account.tenantId -ne $TenantId) {
        throw "Active tenant '$($account.tenantId)' does not match '$TenantId'."
    }

    $resourceGroup = Invoke-AzJson -Arguments @('group', 'show', '--name', $ResourceGroupName)

    $expected = "$TenantId/$SubscriptionId/$ResourceGroupName/$Location"
    if ($ConfirmationToken -cne $expected) {
        throw "Confirmation token mismatch. Re-run with -ConfirmationToken '$expected'."
    }

    [pscustomobject]@{
        TenantId          = $account.tenantId
        SubscriptionId    = $account.id
        SubscriptionName  = $account.name
        ResourceGroupName     = $resourceGroup.name
        ResourceGroupLocation = $resourceGroup.location
        Location              = $Location
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [string]$Description = 'operation',
        [int]$Attempts = 12,
        [int]$DelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return & $Operation
        }
        catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            Write-Warning "$Description failed (attempt $attempt/$Attempts); retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Protect-LocalSecretFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) {
        & chmod 600 $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restrict permissions on '$Path'."
        }
        return
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${identity}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restrict permissions on '$Path'."
    }
}

function Read-DeploymentOutputs {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Deployment output file '$Path' does not exist."
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100)
}

function Confirm-KubernetesContext {
    param([Parameter(Mandatory)][string]$ClusterName)

    Assert-Command kubectl
    $context = & kubectl config current-context
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the current Kubernetes context.'
    }
    if (([string]$context).Trim() -cne $ClusterName) {
        throw "Current Kubernetes context '$(([string]$context).Trim())' does not match '$ClusterName'."
    }
}

function New-DeploymentParameterFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CredentialPath,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$OperatorPrincipalId,
        [Parameter(Mandatory)][string]$OperatorPrincipalType,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$KubernetesVersion,
        [Parameter(Mandatory)][string]$ExpirationDate,
        [Parameter(Mandatory)][string]$PostgresSkuName,
        [Parameter(Mandatory)][bool]$DeployBudget,
        [string]$BudgetContact,
        [string]$NodeVmSize = 'Standard_D2as_v7'
    )

    $credentials = Get-Content -LiteralPath $CredentialPath -Raw | ConvertFrom-Json
    $requiredProperties = @(
        'postgresAdministratorLogin',
        'postgresAdministratorPassword',
        'postgresApplicationLogin',
        'postgresApplicationPassword'
    )
    foreach ($property in $requiredProperties) {
        if ([string]::IsNullOrWhiteSpace($credentials.$property)) {
            throw "Credential file '$CredentialPath' is missing '$property'."
        }
    }

    $firstOfMonth = [DateTime]::new(
        [DateTime]::UtcNow.Year,
        [DateTime]::UtcNow.Month,
        1,
        0,
        0,
        0,
        [DateTimeKind]::Utc
    ).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $parameters = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            targetSubscriptionId = @{ value = $SubscriptionId }
            targetTenantId = @{ value = $TenantId }
            targetResourceGroupName = @{ value = $ResourceGroupName }
            operatorPrincipalId = @{ value = $OperatorPrincipalId }
            operatorPrincipalType = @{ value = $OperatorPrincipalType }
            location = @{ value = $Location }
            kubernetesVersion = @{ value = $KubernetesVersion }
            expirationDate = @{ value = $ExpirationDate }
            budgetContact = @{ value = $BudgetContact }
            deployBudget = @{ value = $DeployBudget }
            nodeVmSize = @{ value = $NodeVmSize }
            postgresSkuName = @{ value = $PostgresSkuName }
            budgetStartDate = @{ value = $firstOfMonth }
            postgresAdministratorLogin = @{ value = $credentials.postgresAdministratorLogin }
            postgresAdministratorPassword = @{ value = $credentials.postgresAdministratorPassword }
            postgresApplicationLogin = @{ value = $credentials.postgresApplicationLogin }
            postgresApplicationPassword = @{ value = $credentials.postgresApplicationPassword }
        }
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedPath) -Force | Out-Null
    $parameters | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedPath -Encoding utf8NoBOM
    Protect-LocalSecretFile -Path $resolvedPath
    return $resolvedPath
}

Export-ModuleMember -Function Assert-Command, Invoke-AzJson, Invoke-Az, Confirm-AzureTarget, Confirm-KubernetesContext, Invoke-WithRetry, Protect-LocalSecretFile, Read-DeploymentOutputs, New-DeploymentParameterFile
