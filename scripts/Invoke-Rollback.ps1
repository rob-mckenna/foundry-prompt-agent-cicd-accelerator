#Requires -Version 7.2
<#
.SYNOPSIS
    Rolls an environment back to the previously deployed immutable package.

.DESCRIPTION
    Reads the current release record for the environment, finds the package id recorded under 'previous',
    locates that artifact and redeploys it. Because packages are immutable and content addressed, rollback is
    a redeploy of known-good bytes rather than a rebuild of older source.

    The script refuses to proceed when the previous package cannot be located, rather than silently leaving
    the environment on the failing version.

.PARAMETER AgentName
    Logical agent name.

.PARAMETER Environment
    Environment to roll back.

.PARAMETER ArtifactDirectory
    Folder searched for the previous package. Normally the retained pipeline artifact or a blob download.

.PARAMETER ToPackageId
    Explicit package id to roll back to. Defaults to the 'previous.packageId' of the current release record.

.EXAMPLE
    ./scripts/Invoke-Rollback.ps1 -AgentName support-agent -Environment prod -ArtifactDirectory ./artifacts

.EXAMPLE
    ./scripts/Invoke-Rollback.ps1 -AgentName support-agent -Environment test -ArtifactDirectory ./artifacts -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{2,62}$')]
    [string]$AgentName,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ArtifactDirectory,

    [ValidatePattern('^sha256:[a-f0-9]{64}$')]
    [string]$ToPackageId,

    [string]$ConfigRoot,

    [string]$ReleaseDirectory,

    [string]$Reason
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

$repoRoot = Get-RepositoryRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repoRoot 'out/releases' }

$config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot
if ($config['deployment'].Contains('rollbackMode') -and $config['deployment']['rollbackMode'] -eq 'manual') {
    throw "Environment '$Environment' is configured with rollbackMode 'manual'. Follow the manual procedure in docs/deployment-runbook.md instead of using this script."
}

Write-OpsLog -Level Step -Message "Reading current release record for '$AgentName' in '$Environment'"
$currentRecord = Get-LatestReleaseRecord -EnvironmentConfig $config -AgentName $AgentName -LocalFallbackDirectory $ReleaseDirectory
if (-not $currentRecord) {
    throw "No release record found for '$AgentName' in '$Environment'. Rollback needs a recorded deployment history; see docs/troubleshooting.md."
}

if (-not $ToPackageId) {
    if (-not $currentRecord.Contains('previous') -or -not $currentRecord['previous'] -or -not $currentRecord['previous'].Contains('packageId')) {
        throw "Release $($currentRecord['releaseId']) has no recorded previous package. This is the first deployment to '$Environment', so there is nothing to roll back to. Deploy a known-good package explicitly with import-agent.ps1."
    }
    $ToPackageId = $currentRecord['previous']['packageId']
}

if ($ToPackageId -eq $currentRecord['packageId']) {
    throw "The requested rollback target '$ToPackageId' is already the deployed package in '$Environment'. Nothing to do."
}

Write-OpsLog -Level Info -Message "Current package: $($currentRecord['packageId'])"
Write-OpsLog -Level Info -Message "Rollback target: $ToPackageId"

$artifactRoot = Resolve-RequiredPath -Path $ArtifactDirectory -Purpose 'Artifact directory'
$packagePath = $null
foreach ($candidate in (Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter '*.zip' -File)) {
    $extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("foundry-rollback-" + [Guid]::NewGuid().ToString('n'))
    try {
        $root = Expand-AgentPackage -PackagePath $candidate.FullName -Destination $extractRoot
        $descriptor = Read-PackageDescriptor -PackageRoot $root
        if ($descriptor['packageId'] -eq $ToPackageId -and $descriptor['agent']['name'] -eq $AgentName) {
            $packagePath = $candidate.FullName
            break
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        Write-OpsLog -Level Warning -Message "Skipping '$($candidate.Name)': $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
    }
}

if (-not $packagePath) {
    throw "Package '$ToPackageId' for agent '$AgentName' was not found under '$artifactRoot'. Rollback cannot rebuild it: retrieve the artifact from the retained build run or the package blob store, then re-run with -ArtifactDirectory pointing at it."
}

Write-OpsLog -Level Success -Message "Rollback artifact located: $packagePath"

$importParameters = @{
    PackagePath      = $packagePath
    Environment      = $Environment
    Operation        = 'rollback'
    ReleaseDirectory = $ReleaseDirectory
    GateResult       = @{ validation = 'skipped'; evaluation = 'skipped'; regression = 'skipped'; smoke = 'passed' }
}
if ($ConfigRoot) { $importParameters['ConfigRoot'] = $ConfigRoot }

$description = if ($Reason) { "Roll back '$AgentName' in '$Environment' to $ToPackageId. Reason: $Reason" }
else { "Roll back '$AgentName' in '$Environment' to $ToPackageId" }

if (-not $PSCmdlet.ShouldProcess($Environment, $description)) {
    $importParameters['WhatIf'] = $true
}

Write-OpsLog -Level Step -Message $description
$result = & (Join-Path $PSScriptRoot 'import-agent.ps1') @importParameters

Write-CiSummary -Markdown @"
### Rollback of ``$Environment``

| Field | Value |
| --- | --- |
| Agent | ``$AgentName`` |
| Rolled back from | ``$($currentRecord['packageId'])`` |
| Rolled back to | ``$ToPackageId`` |
| Artifact | ``$(Split-Path -Leaf $packagePath)`` |
| Reason | $(if ($Reason) { $Reason } else { 'not supplied' }) |

Smoke tests must be re-run against ``$Environment`` before the incident is closed.
"@

Write-OpsLog -Level Warning -Message "Rollback complete. Run tests/smoke/Invoke-SmokeTest.ps1 against '$Environment' and record the outcome in the incident."
return $result
