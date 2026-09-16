#Requires -Version 7.2
<#
.SYNOPSIS
    Validates post-deployment gates and attests a release, or rolls the environment back.

.DESCRIPTION
    scripts/import-agent.ps1 writes a release record with outcome 'pending-verification'. Nothing may be
    promoted from that state. This script is the only thing that can move a release to 'succeeded', and it
    does so only when the gates declared in the packaged overlay are satisfied by real test evidence:

      * a required gate with no result is a failure, not a pass;
      * a required gate reporting 'skipped' is a failure;
      * a result that executed zero cases is a failure;
      * an evaluation pass rate below minimumEvaluationScore is a failure.

    On failure the record is marked 'failed' and, when -RollbackOnFailure is set and the prior artifact was
    staged before the deployment, the environment is rolled back to that exact prior package.

.PARAMETER ReleaseRecordPath
    The pending release record written by import-agent.ps1.

.PARAMETER PackagePath
    The package that was deployed. Needed to read the packaged overlay's gate requirements.

.PARAMETER SmokeResultPath
    Result JSON from tests/smoke/Invoke-SmokeTest.ps1.

.PARAMETER EvaluationResultPath
    Result JSON from tests/evaluations/Invoke-EvaluationSuite.ps1.

.PARAMETER RegressionResultPath
    Result JSON from tests/regression/Invoke-RegressionTest.ps1.

.PARAMETER RollbackOnFailure
    Roll the environment back to the staged prior package when a required gate is not satisfied.

.EXAMPLE
    ./scripts/Complete-Release.ps1 -ReleaseRecordPath ./out/releases/agent-prod-...json `
      -PackagePath ./artifacts/agent-2.1.0+ab12cd3.zip -SmokeResultPath ./out/smoke-prod.json `
      -RegressionResultPath ./out/regression-prod.json -RollbackOnFailure
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseRecordPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,

    [string]$SmokeResultPath,

    [string]$EvaluationResultPath,

    [string]$RegressionResultPath,

    [string]$ConfigRoot,

    [string]$ReleaseDirectory,

    [switch]$RollbackOnFailure
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

$repoRoot = Get-RepositoryRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repoRoot 'out/releases' }

$record = Read-ReleaseRecordFile -Path $ReleaseRecordPath
$environment = $record['environment']
$agentName = $record['agent']['name']

if ($record['deployment']['outcome'] -ne 'pending-verification') {
    throw "Release $($record['releaseId']) has outcome '$($record['deployment']['outcome'])'. Complete-Release.ps1 only attests a release that is pending verification."
}

$extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("foundry-attest-" + [Guid]::NewGuid().ToString('n'))
try {
    $packageRoot = Expand-AgentPackage -PackagePath $PackagePath -Destination $extractRoot
    $descriptor = Read-PackageDescriptor -PackageRoot $packageRoot
    if ($descriptor['packageId'] -ne $record['packageId']) {
        throw "Package '$($descriptor['packageId'])' does not match the package id '$($record['packageId'])' recorded in release $($record['releaseId'])."
    }

    $definition = Resolve-AgentDefinition -Path $packageRoot -Environment $environment -SkipPlaceholderExpansion
    $gates = Get-DeploymentGate -Definition $definition

    Write-OpsLog -Level Step -Message "Reading gate evidence for release $($record['releaseId'])"
    $evidence = Read-GateEvidence -SmokeResultPath $SmokeResultPath -EvaluationResultPath $EvaluationResultPath -RegressionResultPath $RegressionResultPath
    foreach ($key in ($evidence.Keys | Sort-Object)) {
        Write-OpsLog -Level Info -Message "  $key : executed=$($evidence[$key].Executed) outcome=$($evidence[$key].Outcome) score=$($evidence[$key].Score)"
    }

    $verdict = Test-DeploymentGate -Definition $definition -Evidence $evidence
}
finally {
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}

$evidenceRecord = [ordered]@{}
foreach ($key in ($evidence.Keys | Sort-Object)) {
    $evidenceRecord[$key] = [ordered]@{
        executed = [int]$evidence[$key].Executed
        outcome  = [string]$evidence[$key].Outcome
        score    = $evidence[$key].Score
        source   = [string]$evidence[$key].Source
    }
}

$attestedBy = if ($env:GITHUB_ACTOR) { "github:$env:GITHUB_ACTOR" }
elseif ($env:BUILD_REQUESTEDFOR) { "azuredevops:$env:BUILD_REQUESTEDFOR" }
else { "local:$([Environment]::UserName)" }

$record['deployment']['gateResults'] = $verdict.GateResults
$record['deployment']['attestation'] = [ordered]@{
    gatesSatisfied = $verdict.IsSatisfied
    attestedAtUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    attestedBy     = $attestedBy
    requiredGates  = [ordered]@{
        requireEvaluationPass  = [bool]$gates['requireEvaluationPass']
        requireSmokeTestPass   = [bool]$gates['requireSmokeTestPass']
        requireRegressionPass  = [bool]$gates['requireRegressionPass']
        minimumEvaluationScore = $gates['minimumEvaluationScore']
    }
    evidence       = $evidenceRecord
}
$record['deployment']['outcome'] = if ($verdict.IsSatisfied) { 'succeeded' } else { 'failed' }

$config = Get-EnvironmentConfig -Environment $environment -ConfigRoot $ConfigRoot
if ($PSCmdlet.ShouldProcess($record['releaseId'], "Attest release as '$($record['deployment']['outcome'])'")) {
    $null = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
    Write-JsonFile -InputObject $record -Path $ReleaseRecordPath -Depth 16 -Confirm:$false -WhatIf:$false | Out-Null
}

$summaryRows = ($verdict.GateResults.Keys | ForEach-Object { "| $_ | $($verdict.GateResults[$_]) |" }) -join "`n"
Write-CiSummary -Markdown @"
### Release attestation for ``$agentName`` in ``$environment``

| Gate | Result |
| --- | --- |
$summaryRows

Outcome: **$($record['deployment']['outcome'])**
"@

if ($verdict.IsSatisfied) {
    Write-OpsLog -Level Success -Message "Release $($record['releaseId']) attested as succeeded. It is now eligible for promotion."
    return [pscustomobject]@{
        ReleaseId      = $record['releaseId']
        Environment    = $environment
        Outcome        = 'succeeded'
        GatesSatisfied = $true
        GateResults    = $verdict.GateResults
    }
}

foreach ($violation in $verdict.Violations) { Write-OpsLog -Level Error -Message $violation }

if ($RollbackOnFailure) {
    $canRollback = $record.Contains('previous') -and $record['previous'] -and
        $record['previous'].Contains('artifactRetained') -and $record['previous']['artifactRetained'] -eq $true -and
        $record['previous'].Contains('rollbackArtifactPath')

    if ($canRollback) {
        $priorArtifact = $record['previous']['rollbackArtifactPath']
        Write-OpsLog -Level Warning -Message "Gate failure in '$environment'. Rolling back to the staged prior package $($record['previous']['packageId'])."
        & (Join-Path $PSScriptRoot 'Invoke-Rollback.ps1') `
            -AgentName $agentName `
            -Environment $environment `
            -ArtifactDirectory (Split-Path -Parent $priorArtifact) `
            -ToPackageId $record['previous']['packageId'] `
            -ConfigRoot $ConfigRoot `
            -ReleaseDirectory $ReleaseDirectory `
            -Reason "Automatic rollback: required gate(s) not satisfied - $($verdict.Violations -join '; ')" `
            -Confirm:$false
    }
    else {
        Write-OpsLog -Level Error -Message "Automatic rollback is not possible: the release record reports no retained prior artifact. Follow docs/deployment-runbook.md RB-07."
    }
}

throw "Release $($record['releaseId']) failed its required gates in '$environment': $($verdict.Violations -join ' | ')"
