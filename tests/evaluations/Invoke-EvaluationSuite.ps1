#Requires -Version 7.2
<#
.SYNOPSIS
    Runs an evaluation suite against a deployed agent and applies the suite thresholds as a promotion gate.

.DESCRIPTION
    Deterministic evaluators (contains-all, not-contains, regex-match, exact-match, json-schema, latency) run
    without any evaluation service, so they are cheap, stable and usable as hard gates.

    The 'ai-quality' evaluator is a declared extension point. It raises an explicit error unless an external
    runner is wired up, because silently scoring an unmeasured suite as a pass would be worse than failing.

    Set execution.mode to 'offline-fixture' in the suite to replay recorded responses with no Azure access.

.PARAMETER SuitePath
    Path to a suite validated by schemas/evaluation-suite.schema.json.

.PARAMETER Environment
    Environment whose configuration identifies the target project.

.PARAMETER AgentName
    Logical agent name. The deployed agent id is resolved from the release record or by metadata discovery.

.PARAMETER ResultPath
    Optional JSON file that receives the full result set.

.EXAMPLE
    ./tests/evaluations/Invoke-EvaluationSuite.ps1 -SuitePath ./samples/rag-agent/evaluations/grounding.evaluation.json -Environment test -AgentName kb-research-agent
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SuitePath,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{2,62}$')]
    [string]$AgentName,

    [string]$AgentId,

    [string]$ConfigRoot,

    [string]$ResultPath,

    [switch]$ContinueOnThresholdFailure
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1'
Import-Module $moduleRoot -Force

$repoRoot = Get-RepositoryRoot
$suiteResolved = Resolve-RequiredPath -Path $SuitePath -Purpose 'Evaluation suite'
$schemaCheck = Test-JsonFileSchema -Path $suiteResolved -SchemaPath (Join-Path $repoRoot 'schemas/evaluation-suite.schema.json')
if (-not $schemaCheck.IsValid) {
    throw "Evaluation suite '$suiteResolved' failed schema validation: $($schemaCheck.Errors -join '; ')"
}

$suite = Read-JsonFile -Path $suiteResolved
$suiteRoot = Split-Path -Parent $suiteResolved

if ($suite.Contains('appliesTo') -and $suite['appliesTo'] -and $suite['appliesTo'] -notcontains $Environment) {
    Write-OpsLog -Level Warning -Message "Suite '$($suite['id'])' does not apply to '$Environment' (appliesTo: $($suite['appliesTo'] -join ', ')). Nothing to do."
    return [pscustomobject]@{ SuiteId = $suite['id']; Environment = $Environment; Skipped = $true; Passed = 0; Failed = 0 }
}

$datasetPath = Resolve-RequiredPath -Path (Join-Path $suiteRoot $suite['dataset']['file']) -Purpose 'Evaluation dataset'
$inputField = if ($suite['dataset'].Contains('inputField')) { $suite['dataset']['inputField'] } else { 'query' }
$expectedField = if ($suite['dataset'].Contains('expectedField')) { $suite['dataset']['expectedField'] } else { 'expected' }

$records = @()
$lineNumber = 0
foreach ($line in (Get-Content -LiteralPath $datasetPath -Encoding utf8)) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $records += , (ConvertTo-OrderedHashtable -InputObject ($line | ConvertFrom-Json -Depth 32))
    }
    catch [System.ArgumentException] {
        throw "Dataset '$datasetPath' line ${lineNumber} is not valid JSON: $($_.Exception.Message)"
    }
}
if ($suite['dataset'].Contains('maxRecords')) {
    $records = $records | Select-Object -First ([int]$suite['dataset']['maxRecords'])
}
if ($records.Count -eq 0) { throw "Dataset '$datasetPath' contains no records." }

$mode = if ($suite.Contains('execution') -and $suite['execution'].Contains('mode')) { $suite['execution']['mode'] } else { 'live' }
$timeoutSeconds = if ($suite.Contains('execution') -and $suite['execution'].Contains('timeoutSeconds')) { [int]$suite['execution']['timeoutSeconds'] } else { 120 }

$fixtures = @{}
if ($mode -eq 'offline-fixture') {
    if (-not $suite['execution'].Contains('fixtureFile')) {
        throw "execution.mode is 'offline-fixture' but execution.fixtureFile is not set in '$suiteResolved'."
    }
    $fixturePath = Resolve-RequiredPath -Path (Join-Path $suiteRoot $suite['execution']['fixtureFile']) -Purpose 'Evaluation fixture'
    foreach ($line in (Get-Content -LiteralPath $fixturePath -Encoding utf8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fixture = ConvertTo-OrderedHashtable -InputObject ($line | ConvertFrom-Json -Depth 32)
        $fixtures[[string]$fixture['id']] = $fixture
    }
    Write-OpsLog -Level Info -Message "Offline fixture mode: $($fixtures.Count) recorded response(s) loaded. No Azure call is made."
}

function Get-ExpectedValue {
    param([System.Collections.IDictionary]$Record, [string]$Name)
    if (-not $Record.Contains($expectedField) -or -not $Record[$expectedField]) { return $null }
    $expected = $Record[$expectedField]
    if ($expected -isnot [System.Collections.IDictionary]) { return $expected }
    if (-not $expected.Contains($Name)) { return $null }
    return $expected[$Name]
}

function Test-Evaluator {
    param(
        [System.Collections.IDictionary]$Evaluator,
        [System.Collections.IDictionary]$Record,
        $Response
    )

    $arguments = if ($Evaluator.Contains('arguments') -and $Evaluator['arguments']) { $Evaluator['arguments'] } else { [ordered]@{} }
    $caseSensitive = ($arguments.Contains('caseSensitive') -and $arguments['caseSensitive'] -eq $true)
    $output = [string]$Response.Output

    if ($arguments.Contains('appliesWhenExpectedField')) {
        $flag = Get-ExpectedValue -Record $Record -Name $arguments['appliesWhenExpectedField']
        if ($flag -ne $true) { return [pscustomobject]@{ Result = 'skipped'; Message = 'not applicable to this record' } }
    }

    switch ($Evaluator['type']) {
        'exact-match' {
            $expected = [string](Get-ExpectedValue -Record $Record -Name 'value')
            $comparison = if ($caseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
            $ok = [string]::Equals($output.Trim(), $expected.Trim(), $comparison)
            return [pscustomobject]@{ Result = ($ok ? 'passed' : 'failed'); Message = ($ok ? '' : "expected '$expected'") }
        }
        'contains-all' {
            $terms = if ($arguments.Contains('fromExpectedField')) { Get-ExpectedValue -Record $Record -Name $arguments['fromExpectedField'] } else { $arguments['values'] }
            if (-not $terms) { return [pscustomobject]@{ Result = 'skipped'; Message = 'no terms declared' } }
            $missing = @()
            foreach ($term in $terms) {
                $found = if ($caseSensitive) { $output.Contains([string]$term) } else { $output.ToLowerInvariant().Contains(([string]$term).ToLowerInvariant()) }
                if (-not $found) { $missing += $term }
            }
            return [pscustomobject]@{ Result = ($missing.Count -eq 0 ? 'passed' : 'failed'); Message = ($missing.Count -eq 0 ? '' : "missing: $($missing -join ', ')") }
        }
        'not-contains' {
            $terms = if ($arguments.Contains('fromExpectedField')) { Get-ExpectedValue -Record $Record -Name $arguments['fromExpectedField'] } else { $arguments['values'] }
            if (-not $terms) { return [pscustomobject]@{ Result = 'skipped'; Message = 'no terms declared' } }
            $hits = @()
            foreach ($term in $terms) {
                $found = if ($caseSensitive) { $output.Contains([string]$term) } else { $output.ToLowerInvariant().Contains(([string]$term).ToLowerInvariant()) }
                if ($found) { $hits += $term }
            }
            return [pscustomobject]@{ Result = ($hits.Count -eq 0 ? 'passed' : 'failed'); Message = ($hits.Count -eq 0 ? '' : "forbidden content present: $($hits -join ', ')") }
        }
        'regex-match' {
            $pattern = [string]$arguments['pattern']
            $options = [System.Text.RegularExpressions.RegexOptions]::None
            if (-not $caseSensitive) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
            if ($arguments.Contains('multiline') -and $arguments['multiline'] -eq $true) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::Multiline }
            $ok = [regex]::IsMatch($output, $pattern, $options)
            return [pscustomobject]@{ Result = ($ok ? 'passed' : 'failed'); Message = ($ok ? '' : "output does not match /$pattern/") }
        }
        'json-schema' {
            if (-not $arguments.Contains('schemaFile')) { return [pscustomobject]@{ Result = 'failed'; Message = 'schemaFile argument is required' } }
            $schemaFile = Join-Path $suiteRoot $arguments['schemaFile']
            $schema = Get-Content -LiteralPath (Resolve-RequiredPath -Path $schemaFile -Purpose 'Evaluator JSON schema') -Raw -Encoding utf8
            $isValid = $false
            try { $isValid = Test-Json -Json $output -Schema $schema -ErrorAction Stop }
            catch { $isValid = $false }
            return [pscustomobject]@{ Result = ($isValid ? 'passed' : 'failed'); Message = ($isValid ? '' : 'output is not valid against the declared schema') }
        }
        'latency' {
            $maximum = [int]$arguments['maximumMs']
            $ok = ($Response.LatencyMs -le $maximum)
            return [pscustomobject]@{ Result = ($ok ? 'passed' : 'failed'); Message = ($ok ? '' : "$($Response.LatencyMs) ms exceeds $maximum ms") }
        }
        'ai-quality' {
            throw "Evaluator '$($Evaluator['name'])' is of type 'ai-quality', which requires an external Azure AI evaluation runner. Wire one up in this script or remove the evaluator. It is not scored automatically because an unmeasured pass would be misleading."
        }
        default {
            throw "Unknown evaluator type '$($Evaluator['type'])' in suite '$($suite['id'])'."
        }
    }
}

$accessToken = $null
$results = [System.Collections.Generic.List[pscustomobject]]::new()

try {
    if ($mode -eq 'live') {
        $config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot
        $tenantId = if ($config['azure'].Contains('tenantId')) { [string]$config['azure']['tenantId'] } else { $null }
        $accessToken = Get-FoundryAccessToken -Scope $config['foundry']['tokenScope'] -TenantId $tenantId

        if (-not $AgentId) {
            $record = Get-LatestReleaseRecord -EnvironmentConfig $config -AgentName $AgentName -LocalFallbackDirectory (Join-Path $repoRoot 'out/releases')
            if ($record -and $record['agent'].Contains('remoteAgentId')) { $AgentId = [string]$record['agent']['remoteAgentId'] }
        }
        if (-not $AgentId) {
            $agent = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $AgentName -AccessToken $accessToken
            if (-not $agent) { throw "Agent '$AgentName' was not found in '$Environment'. Deploy it before running evaluations." }
            $AgentId = $agent.id
        }
        Write-OpsLog -Level Info -Message "Evaluating agent $AgentId in '$Environment' with suite '$($suite['id'])' ($($records.Count) records)."
    }

    foreach ($record in $records) {
        $id = [string]$record['id']
        $prompt = [string]$record[$inputField]

        if ($mode -eq 'offline-fixture') {
            if (-not $fixtures.ContainsKey($id)) {
                throw "Fixture file has no recorded response for dataset record '$id'. Re-record the fixture or remove the record."
            }
            $response = [pscustomobject]@{
                Output    = [string]$fixtures[$id]['output']
                Status    = 'completed'
                LatencyMs = [int]($fixtures[$id].Contains('latencyMs') ? $fixtures[$id]['latencyMs'] : 0)
                Error     = $null
            }
        }
        else {
            $response = Invoke-FoundryAgentRun -EnvironmentConfig $config -AgentId $AgentId -Prompt $prompt `
                -AccessToken $accessToken -TimeoutSeconds $timeoutSeconds
        }

        $checks = @()
        $recordFailed = $false

        if ($response.Status -ne 'completed') {
            $recordFailed = $true
            $checks += [pscustomobject]@{ Evaluator = 'run-status'; Result = 'failed'; Message = "run status '$($response.Status)' $($response.Error)" }
        }
        else {
            foreach ($evaluator in $suite['evaluators']) {
                $check = Test-Evaluator -Evaluator $evaluator -Record $record -Response $response
                $checks += [pscustomobject]@{ Evaluator = $evaluator['name']; Result = $check.Result; Message = $check.Message }
                $weight = if ($evaluator.Contains('weight')) { [double]$evaluator['weight'] } else { 1 }
                if ($check.Result -eq 'failed' -and $weight -gt 0) { $recordFailed = $true }
            }
        }

        $results.Add([pscustomobject]@{
                Id        = $id
                Prompt    = $prompt
                Status    = $response.Status
                LatencyMs = $response.LatencyMs
                Passed    = (-not $recordFailed)
                Checks    = $checks
            })

        $marker = if ($recordFailed) { 'FAIL' } else { 'pass' }
        Write-Host ("  {0,-8} {1,-10} {2,6} ms  {3}" -f $marker, $id, $response.LatencyMs, (($checks | Where-Object Result -EQ 'failed' | ForEach-Object { "$($_.Evaluator): $($_.Message)" }) -join '; '))
    }
}
finally {
    if ($accessToken) { $accessToken.Dispose() }
}

$passedCount = @($results | Where-Object Passed).Count
$failedCount = $results.Count - $passedCount
$passRate = if ($results.Count -gt 0) { [Math]::Round($passedCount / $results.Count, 4) } else { 0 }
$latencies = @($results | ForEach-Object { $_.LatencyMs } | Sort-Object)
$p95 = if ($latencies.Count -gt 0) { $latencies[[Math]::Min($latencies.Count - 1, [int][Math]::Ceiling($latencies.Count * 0.95) - 1)] } else { 0 }

$thresholds = $suite['thresholds']
$violations = @()
if ($passRate -lt [double]$thresholds['minimumPassRate']) {
    $violations += "pass rate $passRate is below the minimum $($thresholds['minimumPassRate'])"
}
if ($thresholds.Contains('maximumFailures') -and $failedCount -gt [int]$thresholds['maximumFailures']) {
    $violations += "$failedCount failures exceed the maximum $($thresholds['maximumFailures'])"
}
if ($thresholds.Contains('maximumP95LatencyMs') -and $p95 -gt [int]$thresholds['maximumP95LatencyMs']) {
    $violations += "p95 latency ${p95} ms exceeds the maximum $($thresholds['maximumP95LatencyMs']) ms"
}

$summary = [ordered]@{
    suiteId      = $suite['id']
    environment  = $Environment
    agentName    = $AgentName
    agentId      = $AgentId
    mode         = $mode
    executedUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    total        = $results.Count
    passed       = $passedCount
    failed       = $failedCount
    passRate     = $passRate
    p95LatencyMs = $p95
    thresholdsMet = ($violations.Count -eq 0)
    violations   = $violations
    records      = @($results)
}

if ($ResultPath) {
    Write-JsonFile -InputObject $summary -Path $ResultPath -Depth 12 -Confirm:$false | Out-Null
    Write-OpsLog -Level Info -Message "Results written to $ResultPath"
}

Write-OpsLog -Level Step -Message "Suite '$($suite['id'])': $passedCount/$($results.Count) passed, pass rate $passRate, p95 ${p95} ms"
Write-CiSummary -Markdown @"
### Evaluation ``$($suite['id'])`` on ``$Environment``

| Metric | Value |
| --- | --- |
| Records | $($results.Count) |
| Passed | $passedCount |
| Failed | $failedCount |
| Pass rate | $passRate (minimum $($thresholds['minimumPassRate'])) |
| p95 latency | ${p95} ms |
| Thresholds met | $($violations.Count -eq 0) |
"@

if ($violations.Count -gt 0) {
    foreach ($violation in $violations) { Write-OpsLog -Level Error -Message $violation }
    if (-not $ContinueOnThresholdFailure) {
        throw "Evaluation suite '$($suite['id'])' did not meet its thresholds."
    }
}

return [pscustomobject]$summary
