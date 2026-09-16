#Requires -Version 7.2
<#
.SYNOPSIS
    Detects behavioural regression by comparing a deployed agent against a recorded baseline.

.DESCRIPTION
    Evaluation suites answer "is it good enough". Regression answers a different question: "did behaviour
    change in a way nobody intended". Each case records assertions plus an optional baseline response
    fingerprint. A case fails when a required assertion breaks, and warns when the response shape drifts
    beyond the configured similarity floor.

    Baselines are captured deliberately with -UpdateBaseline, which supports -WhatIf. Baselines are not
    refreshed automatically: an unexplained drift must be reviewed by a human, not absorbed silently.

.PARAMETER Environment
    Environment to test. Regression normally runs in TEST and UAT.

.PARAMETER AgentName
    Logical agent name.

.PARAMETER CasePath
    Folder or file containing regression cases. Defaults to tests/regression/cases.

.PARAMETER UpdateBaseline
    Rewrites the baseline block of each case with the current response. Mutating, so it honours -WhatIf.

.EXAMPLE
    ./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName kb-research-agent

.EXAMPLE
    ./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName kb-research-agent -UpdateBaseline -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{2,62}$')]
    [string]$AgentName,

    [string]$AgentId,

    [string]$CasePath,

    [string]$ConfigRoot,

    [string]$ResultPath,

    [ValidateRange(0.0, 1.0)]
    [double]$SimilarityFloor = 0.6,

    [switch]$UpdateBaseline,

    [switch]$TreatDriftAsFailure
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1'
Import-Module $moduleRoot -Force

$repoRoot = Get-RepositoryRoot
if (-not $CasePath) { $CasePath = Join-Path $PSScriptRoot 'cases' }
$caseRoot = Resolve-RequiredPath -Path $CasePath -Purpose 'Regression case path'

$caseFiles = if ((Get-Item -LiteralPath $caseRoot).PSIsContainer) {
    @(Get-ChildItem -LiteralPath $caseRoot -Filter '*.json' -File | Sort-Object Name)
}
else {
    @(Get-Item -LiteralPath $caseRoot)
}
if ($caseFiles.Count -eq 0) { throw "No regression cases found under '$caseRoot'." }

function Get-TokenSet {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [System.Collections.Generic.HashSet[string]]::new() }
    $tokens = [regex]::Matches($Text.ToLowerInvariant(), '[a-z0-9]{3,}') | ForEach-Object { $_.Value }
    return [System.Collections.Generic.HashSet[string]]::new([string[]]$tokens)
}

function Get-JaccardSimilarity {
    param([string]$Left, [string]$Right)
    $a = Get-TokenSet -Text $Left
    $b = Get-TokenSet -Text $Right
    if ($a.Count -eq 0 -and $b.Count -eq 0) { return 1.0 }
    $intersection = [System.Collections.Generic.HashSet[string]]::new($a)
    $intersection.IntersectWith($b)
    $union = [System.Collections.Generic.HashSet[string]]::new($a)
    $union.UnionWith($b)
    if ($union.Count -eq 0) { return 1.0 }
    return [Math]::Round($intersection.Count / $union.Count, 4)
}

$config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot
$tenantId = if ($config['azure'].Contains('tenantId')) { [string]$config['azure']['tenantId'] } else { $null }
$results = [System.Collections.Generic.List[pscustomobject]]::new()
$accessToken = $null

try {
    $accessToken = Get-FoundryAccessToken -Scope $config['foundry']['tokenScope'] -TenantId $tenantId

    if (-not $AgentId) {
        $record = Get-LatestReleaseRecord -EnvironmentConfig $config -AgentName $AgentName -LocalFallbackDirectory (Join-Path $repoRoot 'out/releases')
        if ($record -and $record['agent'].Contains('remoteAgentId')) { $AgentId = [string]$record['agent']['remoteAgentId'] }
    }
    if (-not $AgentId) {
        $agent = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $AgentName -AccessToken $accessToken
        if (-not $agent) { throw "Agent '$AgentName' was not found in '$Environment'." }
        $AgentId = $agent.id
    }

    Write-OpsLog -Level Step -Message "Regression testing $AgentId in '$Environment' across $($caseFiles.Count) case file(s)"

    foreach ($caseFile in $caseFiles) {
        $document = Read-JsonFile -Path $caseFile.FullName
        if ($document.Contains('agent') -and $document['agent'] -ne $AgentName) {
            Write-OpsLog -Level Info -Message "Skipping $($caseFile.Name): declared for agent '$($document['agent'])'."
            continue
        }

        $mutated = $false
        foreach ($case in $document['cases']) {
            $id = [string]$case['id']
            $timeout = if ($case.Contains('timeoutSeconds')) { [int]$case['timeoutSeconds'] } else { 120 }
            $response = Invoke-FoundryAgentRun -EnvironmentConfig $config -AgentId $AgentId -Prompt $case['prompt'] `
                -AccessToken $accessToken -TimeoutSeconds $timeout

            $problems = @()
            $warnings = @()
            $similarity = $null

            if ($response.Status -ne 'completed') {
                $problems += "run status '$($response.Status)' $($response.Error)"
            }
            else {
                $output = [string]$response.Output
                if ($case.Contains('mustContain')) {
                    foreach ($term in $case['mustContain']) {
                        if (-not $output.ToLowerInvariant().Contains(([string]$term).ToLowerInvariant())) { $problems += "missing '$term'" }
                    }
                }
                if ($case.Contains('mustNotContain')) {
                    foreach ($term in $case['mustNotContain']) {
                        if ($output.ToLowerInvariant().Contains(([string]$term).ToLowerInvariant())) { $problems += "forbidden '$term' present" }
                    }
                }
                if ($case.Contains('mustMatch')) {
                    if (-not [regex]::IsMatch($output, [string]$case['mustMatch'], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                        $problems += "does not match /$($case['mustMatch'])/"
                    }
                }

                if ($case.Contains('baseline') -and $case['baseline'] -and $case['baseline'].Contains('response')) {
                    $similarity = Get-JaccardSimilarity -Left ([string]$case['baseline']['response']) -Right $output
                    if ($similarity -lt $SimilarityFloor) {
                        $message = "response drifted from baseline (similarity $similarity, floor $SimilarityFloor)"
                        if ($TreatDriftAsFailure) { $problems += $message } else { $warnings += $message }
                    }
                }

                if ($UpdateBaseline) {
                    if ($PSCmdlet.ShouldProcess("$($caseFile.Name)::$id", 'Update regression baseline')) {
                        $case['baseline'] = [ordered]@{
                            response    = $output
                            capturedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                            environment = $Environment
                            latencyMs   = $response.LatencyMs
                        }
                        $mutated = $true
                    }
                }
            }

            $results.Add([pscustomobject]@{
                    File       = $caseFile.Name
                    Id         = $id
                    Passed     = ($problems.Count -eq 0)
                    Similarity = $similarity
                    LatencyMs  = $response.LatencyMs
                    Problems   = $problems
                    Warnings   = $warnings
                })

            $marker = if ($problems.Count -eq 0) { 'pass' } else { 'FAIL' }
            $detail = (@($problems + $warnings) -join '; ')
            Write-Host ("  {0,-6} {1,-28} sim={2,-6} {3,6} ms  {4}" -f $marker, $id, ($null -eq $similarity ? 'n/a' : $similarity), $response.LatencyMs, $detail)
        }

        if ($mutated) {
            Write-JsonFile -InputObject $document -Path $caseFile.FullName -Depth 16 -Confirm:$false | Out-Null
            Write-OpsLog -Level Success -Message "Baseline updated in $($caseFile.Name). Review the diff before committing."
        }
    }
}
finally {
    if ($accessToken) { $accessToken.Dispose() }
}

$passed = @($results | Where-Object Passed).Count
$failed = $results.Count - $passed
$drifted = @($results | Where-Object { $_.Warnings.Count -gt 0 }).Count

$summary = [ordered]@{
    agentName   = $AgentName
    environment = $Environment
    executedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    total       = $results.Count
    passed      = $passed
    failed      = $failed
    drifted     = $drifted
    cases       = @($results)
}
if ($ResultPath) { Write-JsonFile -InputObject $summary -Path $ResultPath -Depth 10 -Confirm:$false | Out-Null }

Write-OpsLog -Level Step -Message "Regression: $passed passed, $failed failed, $drifted drifted"
Write-CiSummary -Markdown @"
### Regression ``$AgentName`` on ``$Environment``

| Metric | Value |
| --- | --- |
| Cases | $($results.Count) |
| Passed | $passed |
| Failed | $failed |
| Drifted beyond floor $SimilarityFloor | $drifted |
"@

if ($failed -gt 0) {
    throw "Regression testing failed for '$AgentName' in '$Environment' ($failed case(s))."
}
if ($drifted -gt 0) {
    Write-OpsLog -Level Warning -Message "$drifted case(s) drifted from baseline without breaking an assertion. Review them and either accept with -UpdateBaseline or investigate."
}

return [pscustomobject]$summary
