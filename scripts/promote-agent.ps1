#Requires -Version 7.2
<#
.SYNOPSIS
    Promotes an already-deployed, unchanged agent package from one environment to the next.

.DESCRIPTION
    Promotion never rebuilds. It resolves the exact package that was deployed to the source environment,
    verifies that the artifact on disk matches the package id recorded in the source release record, enforces
    the promotion order, and then deploys that same artifact to the target environment with the target
    overlay applied.

    Approval controls are enforced by the platform, not by this script: GitHub environment protection rules
    or Azure DevOps environment checks must gate the job that invokes it. The script records the gate results
    that the pipeline passes in -GateResult so that the release record shows what was verified.

.PARAMETER AgentName
    Logical agent name as declared in agent.manifest.json.

.PARAMETER FromEnvironment
    Environment the package is promoted from. Its release record must exist and have outcome 'succeeded'.

.PARAMETER ToEnvironment
    Target environment.

.PARAMETER PackagePath
    Path to the .zip or extracted package. When omitted, the script searches -ArtifactDirectory for a package
    whose content id matches the source release record.

.PARAMETER ArtifactDirectory
    Folder containing candidate packages, normally the pipeline artifact download location.

.PARAMETER SourceReleaseRecordPath
    Transported, schema-validated release record from the source deployment run. Pipelines should supply this
    artifact so the target identity does not need read access to the source environment's release store.

.PARAMETER ChangeRecordId
    Approved production change reference, for example CHG-0043912.

.PARAMETER BusinessSignoffId
    Durable UAT business acceptance reference. PROD requires BSO- followed by 4-10 digits.

.PARAMETER AllowSkipEnvironment
    Permits a non-adjacent promotion, for example dev to prod. Requires an explicit -Justification.

.EXAMPLE
    ./scripts/promote-agent.ps1 -AgentName support-agent -FromEnvironment dev -ToEnvironment test -ArtifactDirectory ./artifacts

.EXAMPLE
    ./scripts/promote-agent.ps1 -AgentName support-agent -FromEnvironment uat -ToEnvironment prod -PackagePath ./artifacts/support-agent-1.2.0+ab12cd3.zip -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{2,62}$')]
    [string]$AgentName,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$FromEnvironment,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$ToEnvironment,

    [string]$PackagePath,

    [string]$ArtifactDirectory,

    [string]$SourceReleaseRecordPath,

    [string]$ConfigRoot,

    [string]$ReleaseDirectory,

    [hashtable]$GateResult,

    [string]$ChangeRecordId,

    [string]$BusinessSignoffId,

    [switch]$AllowSkipEnvironment,

    [string]$Justification,

    [string]$DeploymentEvidencePath,

    [ValidateSet('None', 'AfterPackagePublication', 'AfterActivation')]
    [string]$TestFailurePoint = 'None'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1')

$promotionOrder = @('dev', 'test', 'uat', 'prod')
$fromIndex = $promotionOrder.IndexOf($FromEnvironment)
$toIndex = $promotionOrder.IndexOf($ToEnvironment)

if ($toIndex -le $fromIndex) {
    throw "Invalid promotion '$FromEnvironment' -> '$ToEnvironment'. Promotion always moves forward through $($promotionOrder -join ' -> '). Use Invoke-Rollback.ps1 to revert an environment."
}
if (($toIndex - $fromIndex) -gt 1) {
    if (-not $AllowSkipEnvironment) {
        throw "Promotion '$FromEnvironment' -> '$ToEnvironment' skips $($promotionOrder[($fromIndex + 1)..($toIndex - 1)] -join ', '). Re-run with -AllowSkipEnvironment and -Justification if this is an approved exception."
    }
    if ([string]::IsNullOrWhiteSpace($Justification)) {
        throw "-AllowSkipEnvironment requires -Justification so that the exception is recorded in the pipeline log."
    }
    Write-OpsLog -Level Warning -Message "Skipping intermediate environment(s). Justification: $Justification"
}

if ($ToEnvironment -eq 'prod') {
    if ($ChangeRecordId -notmatch '^[A-Za-z]{2,5}-[0-9]{4,10}$') {
        throw "Production promotion requires an approved change record in the form CHG-0043912. Supply -ChangeRecordId."
    }
    if ($BusinessSignoffId -notmatch '^BSO-[0-9]{4,10}$') {
        throw "Production promotion requires durable UAT business acceptance in the form BSO-0043912. Supply -BusinessSignoffId."
    }
}

$repoRoot = Get-RepositoryRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repoRoot 'out/releases' }

Write-OpsLog -Level Step -Message "Reading release record for '$AgentName' in '$FromEnvironment'"
$sourceRecord = if ($SourceReleaseRecordPath) {
    Read-ReleaseRecordFile -Path $SourceReleaseRecordPath
}
else {
    $sourceConfig = Get-EnvironmentConfig -Environment $FromEnvironment -ConfigRoot $ConfigRoot
    Get-LatestReleaseRecord -EnvironmentConfig $sourceConfig -AgentName $AgentName -LocalFallbackDirectory $ReleaseDirectory
}

if (-not $sourceRecord) {
    throw "No release record found for '$AgentName' in '$FromEnvironment'. Deploy to '$FromEnvironment' before promoting, or point -ReleaseDirectory at the pipeline artifact that holds the record."
}
$expectedPackageId = $sourceRecord['packageId']
Write-OpsLog -Level Info -Message "Source release $($sourceRecord['releaseId']) references package $expectedPackageId"

function Test-PackageMatch {
    param([Parameter(Mandatory)][string]$Candidate, [Parameter(Mandatory)][string]$ExpectedId)
    $extractRoot = Join-Path (Get-RepositoryRoot) ("out\platform-work\foundry-promote-" + [Guid]::NewGuid().ToString('n'))
    try {
        $root = Expand-AgentPackage -PackagePath $Candidate -Destination $extractRoot
        $descriptor = Read-PackageDescriptor -PackageRoot $root
        return ($descriptor['packageId'] -eq $ExpectedId)
    }
    catch [System.Management.Automation.RuntimeException] {
        Write-OpsLog -Level Warning -Message "Candidate '$Candidate' could not be verified: $($_.Exception.Message)"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
    }
}

if (-not $PackagePath) {
    if (-not $ArtifactDirectory) {
        throw "Supply either -PackagePath or -ArtifactDirectory so that the promoted artifact can be located."
    }
    $artifactRoot = Resolve-RequiredPath -Path $ArtifactDirectory -Purpose 'Artifact directory'
    Write-OpsLog -Level Step -Message "Searching '$artifactRoot' for package $expectedPackageId"
    $candidates = @(Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter "$AgentName-*.zip" -File)
    if ($candidates.Count -eq 0) {
        $candidates = @(Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter '*.zip' -File)
    }
    foreach ($candidate in $candidates) {
        if (Test-PackageMatch -Candidate $candidate.FullName -ExpectedId $expectedPackageId) {
            $PackagePath = $candidate.FullName
            break
        }
    }
    if (-not $PackagePath) {
        throw "No package in '$artifactRoot' matches package id '$expectedPackageId'. Promotion requires the identical artifact that was deployed to '$FromEnvironment'; rebuilding is not permitted. Re-download the build artifact or retain artifacts for longer."
    }
}
else {
    $PackagePath = Resolve-RequiredPath -Path $PackagePath -Purpose 'Agent package'
    if (-not (Test-PackageMatch -Candidate $PackagePath -ExpectedId $expectedPackageId)) {
        throw "Package '$PackagePath' does not match package id '$expectedPackageId' recorded for '$FromEnvironment'. Promotion must move the identical artifact."
    }
}

Write-OpsLog -Level Success -Message "Package match confirmed: $PackagePath"

$sourceExtract = Join-Path $repoRoot ("out\platform-work\promote-" + [Guid]::NewGuid().ToString('n'))
try {
    $sourcePackageRoot = Expand-AgentPackage -PackagePath $PackagePath -Destination $sourceExtract
    $sourceDefinition = Resolve-AgentDefinition -Path $sourcePackageRoot -Environment $FromEnvironment -SkipPlaceholderExpansion
    if ($sourceRecord['agent']['version'] -cne (Read-PackageDescriptor -PackageRoot $sourcePackageRoot)['agent']['version']) { throw 'Source manifest semver does not match the release record.' }
    $promotionCheck = Test-ReleaseRecordForPromotion -Record $sourceRecord -AgentName $AgentName `
        -PackageId $expectedPackageId -SourceEnvironment $FromEnvironment -ExpectedGates (Get-DeploymentGate -Definition $sourceDefinition)
}
finally { if (Test-Path -LiteralPath $sourceExtract) { Remove-Item -LiteralPath $sourceExtract -Recurse -Force -Confirm:$false -WhatIf:$false } }
if (-not $promotionCheck.IsValid) {
    throw "Source release '$($sourceRecord['releaseId'])' is not eligible for promotion: $($promotionCheck.Problems -join '; ')."
}
Write-OpsLog -Level Success -Message "Source release attestation, required gate evidence, and package identity are valid."

$importParameters = @{
    PackagePath       = $PackagePath
    Environment       = $ToEnvironment
    Operation         = 'promote'
    SourceEnvironment = $FromEnvironment
    ReleaseDirectory  = $ReleaseDirectory
    ChangeRecordId    = $ChangeRecordId
    BusinessSignoffId = $BusinessSignoffId
}
if ($ConfigRoot) { $importParameters['ConfigRoot'] = $ConfigRoot }
if ($GateResult) { $importParameters['GateResult'] = $GateResult }
if ($DeploymentEvidencePath) { $importParameters['DeploymentEvidencePath'] = $DeploymentEvidencePath }
if ($TestFailurePoint -ne 'None') { $importParameters['TestFailurePoint'] = $TestFailurePoint }

if (-not $PSCmdlet.ShouldProcess("$AgentName -> $ToEnvironment", "Promote package $expectedPackageId")) {
    $importParameters['WhatIf'] = $true
}

Write-OpsLog -Level Step -Message "Promoting $AgentName from '$FromEnvironment' to '$ToEnvironment'"
$result = & (Join-Path $PSScriptRoot 'import-agent.ps1') @importParameters

Write-CiSummary -Markdown @"
### Promotion ``$FromEnvironment`` -> ``$ToEnvironment``

| Field | Value |
| --- | --- |
| Agent | ``$AgentName`` |
| Package id | ``$expectedPackageId`` |
| Artifact | ``$(Split-Path -Leaf $PackagePath)`` |
| Source release | ``$($sourceRecord['releaseId'])`` |
| Rebuilt | no (identical artifact promoted) |
"@

return $result
