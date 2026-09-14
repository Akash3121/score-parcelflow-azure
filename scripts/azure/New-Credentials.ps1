[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$AdministratorLogin = 'pfadmin',

    [string]$ApplicationLogin = 'pfapp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

function New-StrongPassword {
    param([int]$Length = 32)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $special = '!#%+-.:=?@_'
    $all = $upper + $lower + $digits + $special
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in @($upper, $lower, $digits, $special)) {
        $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)])
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        ($chars[$i], $chars[$j]) = ($chars[$j], $chars[$i])
    }
    return -join $chars
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $parent -Force | Out-Null

$credentials = [ordered]@{
    postgresAdministratorLogin    = $AdministratorLogin
    postgresAdministratorPassword = New-StrongPassword
    postgresApplicationLogin      = $ApplicationLogin
    postgresApplicationPassword   = New-StrongPassword
}

$credentials | ConvertTo-Json | Set-Content -LiteralPath $resolvedOutput -Encoding utf8NoBOM
Protect-LocalSecretFile -Path $resolvedOutput
Write-Host "Generated credentials at '$resolvedOutput'. Values were not written to stdout."
