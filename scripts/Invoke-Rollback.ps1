#Requires -Version 7.2
<#
.SYNOPSIS
    Rolls an environment back to the previously deployed immutable package.

.DESCRIPTION
    Reads the exact failed/current release context and its retained known-good release JSON, rejects serving
    drift, redeploys the verified prior package as a new service version, and centrally verifies and attests
    every gate required by the rollback target overlay. No recursive automatic recovery is attempted.

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

.PARAMETER ChangeRecordId
    Approved change reference for this rollback. For an automatic PROD rollback, the current release change
    reference is reused when this value is omitted.

.PARAMETER BusinessSignoffId
    Durable business acceptance reference. For an automatic PROD rollback, the current release reference is
    reused when this value is omitted.

.PARAMETER ReleaseRecordPath
    Exact failed/current release attempt being recovered. Never inferred from latest.json.

.PARAMETER EvaluationSuitePath
    Live suite required before mutation when the target overlay requires evaluation or a minimum score.

.EXAMPLE
    ./scripts/Invoke-Rollback.ps1 -AgentName support-agent -Environment prod -ArtifactDirectory ./artifacts -Reason 'INC-1234'

.EXAMPLE
    ./scripts/Invoke-Rollback.ps1 -AgentName support-agent -Environment test -ArtifactDirectory ./artifacts -Reason 'Verify recovery plan' -WhatIf
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

    [Parameter(Mandatory)]
    [string]$ReleaseRecordPath,

    [string]$EvaluationSuitePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reason,

    [string]$ChangeRecordId,

    [string]$BusinessSignoffId
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1')

$repoRoot = Get-RepositoryRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repoRoot 'out/releases' }

$config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot
if ($config['deployment'].Contains('rollbackMode') -and $config['deployment']['rollbackMode'] -eq 'manual') {
    throw "Environment '$Environment' is configured with rollbackMode 'manual'. Follow the manual procedure in docs/deployment-runbook.md instead of using this script."
}

Write-OpsLog -Level Step -Message "Reading current release record for '$AgentName' in '$Environment'"
$currentRecord = Read-ReleaseRecordFile -Path $ReleaseRecordPath
if (-not $currentRecord) {
    throw "No release record found for '$AgentName' in '$Environment'. Rollback needs a recorded deployment history; see docs/troubleshooting.md."
}
if ($currentRecord['schemaVersion'] -ne '1.1.0' -or
    $currentRecord['agent']['name'] -cne $AgentName -or $currentRecord['environment'] -ne $Environment -or
    $currentRecord['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -cne $config['foundry']['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -or
    -not $currentRecord['deployment']['runtimeMutation']['started']) {
    throw 'Rollback requires the exact mutated release context for this agent/environment/project.'
}
if (-not $currentRecord.Contains('previous') -or -not $currentRecord['previous']['releaseId']) {
    throw 'First deployment has no known-good prior release. Manual recovery requires an explicitly supplied known-good package deployment.'
}
$previous = $currentRecord['previous']
$knownGoodPath = if ($previous.Contains('releaseRecordPath') -and (Test-Path -LiteralPath $previous['releaseRecordPath'])) {
    $previous['releaseRecordPath']
}
else {
    $matches = @(Get-ChildItem -LiteralPath $ArtifactDirectory -Recurse -File -Filter "$($previous['releaseId']).json")
    if ($matches.Count -ne 1) { throw 'Rollback needs the exact retained known-good release JSON alongside the package.' }
    $matches[0].FullName
}
$knownGood = Read-ReleaseRecordFile -Path $knownGoodPath
foreach ($pair in @(
    @('releaseId', 'releaseId'), @('packageId', 'packageId')
)) {
    if ($knownGood[$pair[0]] -cne $previous[$pair[1]]) { throw 'Retained known-good release does not match the recorded previous identity.' }
}
if ($knownGood['agent']['serviceVersion'] -cne $previous['serviceVersion'] -or
    $knownGood['agent']['serviceVersionId'] -cne $previous['serviceVersionId'] -or
    $knownGood['agent']['remoteAgentId'] -cne $previous['remoteAgentId']) { throw 'Prior service identity mismatch.' }
$serving = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $AgentName
if (-not $serving -or $serving.activeVersion -cnotin @($currentRecord['agent']['serviceVersion'], $previous['serviceVersion'])) {
    throw 'Serving version drift: a stale failure cannot roll back an unrelated newer deployment.'
}
if ($serving.id -cne $previous['remoteAgentId'] -or
    ($serving.activeVersion -ceq $previous['serviceVersion'] -and $serving.versionId -cne $previous['serviceVersionId']) -or
    ($serving.activeVersion -ceq $currentRecord['agent']['serviceVersion'] -and $serving.versionId -cne $currentRecord['agent']['serviceVersionId'])) {
    throw 'Serving resource identity drift prevents rollback.'
}

$originalChangeRecordId = $null
if ($currentRecord.Contains('governance') -and $currentRecord['governance']) {
    $originalChangeRecordId = [string]$currentRecord['governance']['changeRecordId']
    if (-not $ChangeRecordId) { $ChangeRecordId = $originalChangeRecordId }
    if (-not $BusinessSignoffId) {
        $BusinessSignoffId = [string]$currentRecord['governance']['businessSignoffId']
    }
}

if (-not $ToPackageId) {
    if (-not $currentRecord.Contains('previous') -or -not $currentRecord['previous'] -or -not $currentRecord['previous'].Contains('packageId')) {
        throw "Release $($currentRecord['releaseId']) has no recorded previous package. This is the first deployment to '$Environment', so there is nothing to roll back to. Deploy a known-good package explicitly with import-agent.ps1."
    }
    $ToPackageId = $currentRecord['previous']['packageId']
}

if ($ToPackageId -cne $previous['packageId']) { throw 'Explicit rollback package must match the exact prior known-good release in this context.' }

Write-OpsLog -Level Info -Message "Current package: $($currentRecord['packageId'])"
Write-OpsLog -Level Info -Message "Rollback target: $ToPackageId"

$artifactRoot = Resolve-RequiredPath -Path $ArtifactDirectory -Purpose 'Artifact directory'
$packagePath = $null
foreach ($candidate in (Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter '*.zip' -File)) {
    $extractRoot = Join-Path $repoRoot ("out\platform-work\foundry-rollback-" + [Guid]::NewGuid().ToString('n'))
    try {
        $root = Expand-AgentPackage -PackagePath $candidate.FullName -Destination $extractRoot
        $descriptor = Read-PackageDescriptor -PackageRoot $root
        if ($descriptor['packageId'] -eq $ToPackageId -and $descriptor['agent']['name'] -eq $AgentName) {
            $packagePath = $candidate.FullName
            if ($descriptor['agent']['version'] -cne $knownGood['agent']['version']) { throw 'Rollback manifest semver does not match the retained release.' }
            $definition = Resolve-AgentDefinition -Path $root -Environment $Environment -SkipPlaceholderExpansion
            $gates = Get-DeploymentGate -Definition $definition
            $check = Test-ReleaseRecordForPromotion -Record $knownGood -AgentName $AgentName -PackageId $ToPackageId `
                -SourceEnvironment $Environment -ExpectedGates $gates
            if (-not $check.IsValid) { throw "Rollback target is not known-good: $($check.Problems -join '; ')" }
            break
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        $packagePath = $null
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

$needsEvaluation = $gates['requireEvaluationPass'] -or $null -ne $gates['minimumEvaluationScore']
if ($needsEvaluation) {
    if (-not $EvaluationSuitePath) { throw 'Rollback target requires -EvaluationSuitePath before mutation.' }
    $suite = Read-JsonFile -Path (Resolve-RequiredPath -Path $EvaluationSuitePath -Purpose 'Rollback evaluation suite')
    if (($suite.Contains('execution') -and $suite['execution']['mode'] -eq 'offline-fixture') -or
        ($suite.Contains('appliesTo') -and $suite['appliesTo'] -notcontains $Environment)) {
        throw 'Rollback evaluation suite must execute live in the target environment.'
    }
    $suiteCheck = Test-JsonFileSchema -Path $EvaluationSuitePath -SchemaPath (Join-Path $repoRoot 'schemas\evaluation-suite.schema.json')
    if (-not $suiteCheck.IsValid) { throw "Invalid rollback evaluation suite: $($suiteCheck.Errors -join '; ')" }
    $null = Resolve-RequiredPath -Path (Join-Path (Split-Path -Parent (ConvertTo-AbsolutePath -Path $EvaluationSuitePath)) $suite['dataset']['file']) -Purpose 'Rollback evaluation dataset'
}
if ($gates['requireSmokeTestPass']) {
    $canaries = Read-JsonFile -Path (Join-Path $repoRoot 'tests\smoke\smoke-checks.json')
    $applicable = @($canaries['checks'] | Where-Object {
        (-not $_.Contains('agents') -or -not $_['agents'] -or $_['agents'] -contains $AgentName) -and
        (-not $_.Contains('environments') -or -not $_['environments'] -or $_['environments'] -contains $Environment)
    })
    if ($applicable.Count -eq 0) { throw 'Rollback target has no applicable live smoke canary.' }
}
if ($gates['requireRegressionPass']) {
    $regressionCases = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests\regression\cases') -Filter '*.json' -File | Where-Object {
        $caseDocument = Read-JsonFile -Path $_.FullName
        (-not $caseDocument.Contains('agent') -or $caseDocument['agent'] -eq $AgentName) -and @($caseDocument['cases']).Count -gt 0
    })
    if ($regressionCases.Count -eq 0) { throw 'Rollback target has no applicable regression cases.' }
}

$importParameters = @{
    PackagePath      = $packagePath
    Environment      = $Environment
    Operation        = 'rollback'
    ReleaseDirectory = $ReleaseDirectory
    GateResult       = @{ validation = 'passed' }
    RollbackContextPath = $ReleaseRecordPath
    RollbackTargetRecordPath = $knownGoodPath
    PriorArtifactSearchDirectory = @($ArtifactDirectory)
    RollbackStageDirectory = (Join-Path $ReleaseDirectory 'rollback-staged')
    ChangeRecordId   = $ChangeRecordId
    BusinessSignoffId = $BusinessSignoffId
    RollbackReason   = $Reason
}
if ($ConfigRoot) { $importParameters['ConfigRoot'] = $ConfigRoot }
if ($originalChangeRecordId) { $importParameters['OriginalChangeRecordId'] = $originalChangeRecordId }

$description = "Roll back '$AgentName' in '$Environment' to $ToPackageId. Reason: $Reason"

if (-not $PSCmdlet.ShouldProcess($Environment, $description)) {
    $importParameters['WhatIf'] = $true
}

Write-OpsLog -Level Step -Message $description
$importOutput = @(& (Join-Path $PSScriptRoot 'import-agent.ps1') @importParameters)
$result = @($importOutput | Where-Object { $_.PSObject.Properties.Name -contains 'Outcome' }) | Select-Object -Last 1
if (-not $result) {
    throw 'Rollback deployment completed without returning the deployment result contract.'
}
$result | Add-Member -NotePropertyName PackagePath -NotePropertyValue $packagePath -Force
if ($result.Outcome -eq 'simulated') { return $result }

$gateError = $null
$completeParameters = @{
    ReleaseRecordPath = $result.ReleaseRecord; PackagePath = $packagePath
    ConfigRoot = $ConfigRoot; ReleaseDirectory = $ReleaseDirectory
}
try {
    $runnerParameters = @{ Environment = $Environment; AgentName = $AgentName; ConfigRoot = $ConfigRoot; ReleaseRecordPath = $result.ReleaseRecord }
    if ($gates['requireSmokeTestPass']) {
        $completeParameters['SmokeResultPath'] = Join-Path $ReleaseDirectory "$($result.ReleaseId)-smoke.json"
        $null = & (Join-Path $repoRoot 'tests\smoke\Invoke-SmokeTest.ps1') @runnerParameters `
            -ExpectedVersion $knownGood['agent']['version'] -ResultPath $completeParameters['SmokeResultPath']
    }
    if ($needsEvaluation) {
        $completeParameters['EvaluationResultPath'] = Join-Path $ReleaseDirectory "$($result.ReleaseId)-evaluation.json"
        $null = & (Join-Path $repoRoot 'tests\evaluations\Invoke-EvaluationSuite.ps1') @runnerParameters `
            -SuitePath $EvaluationSuitePath -ResultPath $completeParameters['EvaluationResultPath']
    }
    if ($gates['requireRegressionPass']) {
        $completeParameters['RegressionResultPath'] = Join-Path $ReleaseDirectory "$($result.ReleaseId)-regression.json"
        $null = & (Join-Path $repoRoot 'tests\regression\Invoke-RegressionTest.ps1') @runnerParameters -ResultPath $completeParameters['RegressionResultPath']
    }
}
catch { $gateError = $_ }
try { $attestation = & (Join-Path $PSScriptRoot 'Complete-Release.ps1') @completeParameters -Confirm:$false }
catch {
    if ($gateError) { throw $gateError }
    throw
}
if ($gateError) { throw $gateError }
if ($attestation.Outcome -ne 'succeeded') { throw 'Rollback verification did not succeed.' }
$result.Outcome = 'succeeded'
$result | Add-Member -NotePropertyName Operation -NotePropertyValue 'rollback' -Force

Write-CiSummary -Markdown @"
### Rollback of ``$Environment``

| Field | Value |
| --- | --- |
| Agent | ``$AgentName`` |
| Rolled back from | ``$($currentRecord['packageId'])`` |
| Rolled back to | ``$ToPackageId`` |
| Artifact | ``$(Split-Path -Leaf $packagePath)`` |
| Reason | $Reason |

Required live gates passed and the new rollback service version was attested.
"@

Write-OpsLog -Level Success -Message "Rollback verified and attested in '$Environment'."
return $result
