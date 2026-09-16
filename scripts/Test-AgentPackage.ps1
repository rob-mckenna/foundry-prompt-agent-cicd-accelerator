#Requires -Version 7.2
<#
.SYNOPSIS
    Verifies an immutable agent package offline: integrity, descriptor, overlays, payload shape and governance.

.DESCRIPTION
    Runs with no Azure credentials. Intended as the gate immediately before a deployment job and as a
    standalone check when an artifact is handed between teams.

.PARAMETER PackagePath
    Path to a .zip package or an extracted package folder.

.PARAMETER Environment
    Environments to resolve. Defaults to every environment declared in the package descriptor.

.PARAMETER SkipGovernance
    Skips the governance evaluation, for example when the repository does not own the target config.

.EXAMPLE
    ./scripts/Test-AgentPackage.ps1 -PackagePath ./out/support-agent-1.2.0+ab12cd3.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,

    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string[]]$Environment,

    [string]$ConfigRoot,

    [switch]$SkipGovernance
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

$extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("foundry-verify-" + [Guid]::NewGuid().ToString('n'))
$failures = [System.Collections.Generic.List[string]]::new()
$cleanupRequired = $false

try {
    $packageRoot = Expand-AgentPackage -PackagePath $PackagePath -Destination $extractRoot -SkipVerification
    $cleanupRequired = (Test-Path -LiteralPath $extractRoot)

    Write-OpsLog -Level Step -Message "Verifying checksums"
    $verification = Test-ChecksumManifest -Root $packageRoot
    if ($verification.IsValid) {
        Write-OpsLog -Level Success -Message "All files match checksums.sha256."
    }
    else {
        foreach ($item in $verification.Missing) { $failures.Add("Missing file: $item") }
        foreach ($item in $verification.Extra) { $failures.Add("Unexpected file: $item") }
        foreach ($item in $verification.Modified) { $failures.Add("Modified file: $item") }
    }

    Write-OpsLog -Level Step -Message "Validating package descriptor"
    $descriptor = Read-PackageDescriptor -PackageRoot $packageRoot
    if ($descriptor['packageId'] -ne $verification.ContentId) {
        $failures.Add("Descriptor packageId '$($descriptor['packageId'])' does not match computed content id '$($verification.ContentId)'.")
    }
    else {
        Write-OpsLog -Level Success -Message "Content id matches descriptor: $($descriptor['packageId'])"
    }

    if (-not $Environment) { $Environment = @($descriptor['contents']['environments']) }

    foreach ($targetEnv in $Environment) {
        Write-OpsLog -Level Step -Message "Resolving environment '$targetEnv'"
        try {
            $definition = Resolve-AgentDefinition -Path $packageRoot -Environment $targetEnv -SkipPlaceholderExpansion
            $null = ConvertTo-FoundryAgentPayload -Definition $definition
            $unresolved = $definition['unresolvedPlaceholders']
            if ($unresolved.Count -gt 0) {
                Write-OpsLog -Level Info -Message "Deferred to deploy time: $($unresolved -join ', ')"
            }

            if (-not $SkipGovernance) {
                $configPath = if ($ConfigRoot) { Join-Path $ConfigRoot "$targetEnv.json" } else { Join-Path (Get-RepositoryRoot) "config/environments/$targetEnv.json" }
                if (Test-Path -LiteralPath $configPath) {
                    $config = Get-EnvironmentConfig -Environment $targetEnv -ConfigRoot (Split-Path -Parent $configPath) -SkipPlaceholderExpansion
                    $governance = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
                    if ($governance.IsCompliant) {
                        Write-OpsLog -Level Success -Message "Governance policy satisfied for '$targetEnv'."
                    }
                    else {
                        foreach ($violation in $governance.Violations) { $failures.Add("[$targetEnv] $violation") }
                    }
                }
                else {
                    Write-OpsLog -Level Warning -Message "No environment config at '$configPath'; governance not evaluated for '$targetEnv'."
                }
            }
            Write-OpsLog -Level Success -Message "Environment '$targetEnv' resolves to a valid Agent Service payload."
        }
        catch [System.Management.Automation.RuntimeException] {
            $failures.Add("[$targetEnv] $($_.Exception.Message)")
        }
    }
}
finally {
    if ($cleanupRequired -and (Test-Path -LiteralPath $extractRoot)) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-OpsLog -Level Error -Message $failure }
    throw "Package verification failed with $($failures.Count) problem(s)."
}

Write-OpsLog -Level Success -Message "Package verification passed."
return [pscustomobject]@{
    PackagePath  = $PackagePath
    PackageId    = $descriptor['packageId']
    AgentName    = $descriptor['agent']['name']
    Version      = $descriptor['agent']['version']
    Environments = @($Environment)
    IsValid      = $true
}
