#Requires -Version 7.2
<#
.SYNOPSIS
    Post-deployment smoke test for a Foundry prompt agent.

.DESCRIPTION
    Runs immediately after every deployment, in every environment including production. Three layers:

      1. Existence and identity: the managed agent is present and its metadata reports the version that was
         just deployed. This catches a deployment that silently targeted the wrong project.
      2. Configuration: model deployment name and tool count match the package that was deployed.
      3. Liveness: one canary prompt per check completes and satisfies simple content assertions.

    Layer 3 creates a thread and deletes it afterwards. Use -SkipLiveRun in environments where even a canary
    conversation is not acceptable.

    A smoke failure in TEST, UAT or PROD should trigger scripts/Invoke-Rollback.ps1.

.PARAMETER Environment
    Environment to test.

.PARAMETER AgentName
    Logical agent name.

.PARAMETER ExpectedVersion
    Agent version expected in the deployed metadata. Supplied by the pipeline from the package descriptor.

.PARAMETER ChecksPath
    Canary check definitions. Defaults to tests/smoke/smoke-checks.json.

.EXAMPLE
    ./tests/smoke/Invoke-SmokeTest.ps1 -Environment dev -AgentName simple-support-agent -ExpectedVersion 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{2,62}$')]
    [string]$AgentName,

    [string]$ExpectedVersion,

    [string]$ExpectedModelDeployment,

    [int]$ExpectedToolCount = -1,

    [string]$ChecksPath,

    [string]$ConfigRoot,

    [string]$ResultPath,

    [switch]$SkipLiveRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1'
Import-Module $moduleRoot -Force

$repoRoot = Get-RepositoryRoot
if (-not $ChecksPath) { $ChecksPath = Join-Path $PSScriptRoot 'smoke-checks.json' }

$checks = @()
if (Test-Path -LiteralPath $ChecksPath) {
    $checkDocument = Read-JsonFile -Path $ChecksPath
    foreach ($check in $checkDocument['checks']) {
        if ($check.Contains('agents') -and $check['agents'] -and $check['agents'] -notcontains $AgentName) { continue }
        if ($check.Contains('environments') -and $check['environments'] -and $check['environments'] -notcontains $Environment) { continue }
        $checks += , $check
    }
}

$results = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Check {
    param([string]$Name, [ValidateSet('passed', 'failed', 'skipped')][string]$Result, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Name = $Name; Result = $Result; Detail = $Detail })
    switch ($Result) {
        'passed' { Write-OpsLog -Level Success -Message $Name }
        'failed' { Write-OpsLog -Level Error -Message "$Name :: $Detail" }
        'skipped' { Write-OpsLog -Level Info -Message "$Name skipped :: $Detail" }
    }
}

$config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot
$tenantId = if ($config['azure'].Contains('tenantId')) { [string]$config['azure']['tenantId'] } else { $null }
$accessToken = $null

try {
    $accessToken = Get-FoundryAccessToken -Scope $config['foundry']['tokenScope'] -TenantId $tenantId

    Write-OpsLog -Level Step -Message "Smoke testing '$AgentName' in '$Environment'"

    $agent = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $AgentName -AccessToken $accessToken
    if (-not $agent) {
        Add-Check -Name 'Agent exists' -Result failed -Detail "No agent with metadata logical_name '$AgentName' found in project '$($config['foundry']['projectName'])'."
        throw "Smoke test aborted: the agent was not found."
    }
    Add-Check -Name 'Agent exists' -Result passed -Detail $agent.id

    $metadata = $agent.metadata
    $metadataNames = if ($metadata) { $metadata.PSObject.Properties.Name } else { @() }

    if ($ExpectedVersion) {
        if ($metadataNames -contains 'agent_version' -and $metadata.agent_version -eq $ExpectedVersion) {
            Add-Check -Name 'Deployed version matches package' -Result passed -Detail $ExpectedVersion
        }
        else {
            $actual = if ($metadataNames -contains 'agent_version') { $metadata.agent_version } else { '<absent>' }
            Add-Check -Name 'Deployed version matches package' -Result failed -Detail "expected '$ExpectedVersion', found '$actual'"
        }
    }
    else {
        Add-Check -Name 'Deployed version matches package' -Result skipped -Detail '-ExpectedVersion not supplied'
    }

    if ($metadataNames -contains 'environment' -and $metadata.environment -eq $Environment) {
        Add-Check -Name 'Environment metadata matches target' -Result passed -Detail $Environment
    }
    else {
        $actual = if ($metadataNames -contains 'environment') { $metadata.environment } else { '<absent>' }
        Add-Check -Name 'Environment metadata matches target' -Result failed -Detail "expected '$Environment', found '$actual'. The agent may have been deployed from the wrong overlay."
    }

    if ($ExpectedModelDeployment) {
        if ($agent.model -eq $ExpectedModelDeployment) {
            Add-Check -Name 'Model deployment matches overlay' -Result passed -Detail $ExpectedModelDeployment
        }
        else {
            Add-Check -Name 'Model deployment matches overlay' -Result failed -Detail "expected '$ExpectedModelDeployment', found '$($agent.model)'"
        }
    }

    if ($ExpectedToolCount -ge 0) {
        $actualToolCount = if ($agent.PSObject.Properties.Name -contains 'tools' -and $agent.tools) { @($agent.tools).Count } else { 0 }
        if ($actualToolCount -eq $ExpectedToolCount) {
            Add-Check -Name 'Tool count matches resolved package' -Result passed -Detail "$actualToolCount tool(s)"
        }
        else {
            Add-Check -Name 'Tool count matches resolved package' -Result failed -Detail "expected $ExpectedToolCount, found $actualToolCount. A tool may have been disabled or dropped unintentionally."
        }
    }

    if ($SkipLiveRun) {
        Add-Check -Name 'Canary conversation' -Result skipped -Detail '-SkipLiveRun specified'
    }
    elseif ($checks.Count -eq 0) {
        Add-Check -Name 'Canary conversation' -Result skipped -Detail "no applicable checks in $ChecksPath"
    }
    else {
        foreach ($check in $checks) {
            $name = "Canary: $($check['id'])"
            $timeout = if ($check.Contains('timeoutSeconds')) { [int]$check['timeoutSeconds'] } else { 90 }
            $response = Invoke-FoundryAgentRun -EnvironmentConfig $config -AgentId $agent.id -Prompt $check['prompt'] `
                -AccessToken $accessToken -TimeoutSeconds $timeout

            if ($response.Status -ne 'completed') {
                Add-Check -Name $name -Result failed -Detail "run status '$($response.Status)' $($response.Error)"
                continue
            }

            $output = [string]$response.Output
            $problems = @()
            if ([string]::IsNullOrWhiteSpace($output)) { $problems += 'the agent returned an empty response' }
            if ($check.Contains('mustContain')) {
                foreach ($term in $check['mustContain']) {
                    if (-not $output.ToLowerInvariant().Contains(([string]$term).ToLowerInvariant())) { $problems += "missing '$term'" }
                }
            }
            if ($check.Contains('mustNotContain')) {
                foreach ($term in $check['mustNotContain']) {
                    if ($output.ToLowerInvariant().Contains(([string]$term).ToLowerInvariant())) { $problems += "forbidden '$term' present" }
                }
            }
            if ($check.Contains('maximumLatencyMs') -and $response.LatencyMs -gt [int]$check['maximumLatencyMs']) {
                $problems += "$($response.LatencyMs) ms exceeds $($check['maximumLatencyMs']) ms"
            }

            if ($problems.Count -eq 0) {
                Add-Check -Name $name -Result passed -Detail "$($response.LatencyMs) ms"
            }
            else {
                Add-Check -Name $name -Result failed -Detail ($problems -join '; ')
            }
        }
    }
}
finally {
    if ($accessToken) { $accessToken.Dispose() }
}

$passed = @($results | Where-Object Result -EQ 'passed').Count
$failed = @($results | Where-Object Result -EQ 'failed').Count
$skipped = @($results | Where-Object Result -EQ 'skipped').Count

$summary = [ordered]@{
    agentName   = $AgentName
    environment = $Environment
    executedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    passed      = $passed
    failed      = $failed
    skipped     = $skipped
    checks      = @($results)
}
if ($ResultPath) { Write-JsonFile -InputObject $summary -Path $ResultPath -Depth 8 -Confirm:$false | Out-Null }

$summaryRows = ($results | ForEach-Object { "| $($_.Name) | $($_.Result) | $($_.Detail) |" }) -join "`n"
Write-CiSummary -Markdown @"
### Smoke test ``$AgentName`` on ``$Environment``

| Check | Result | Detail |
| --- | --- | --- |
$summaryRows
"@

Write-OpsLog -Level Step -Message "Smoke test: $passed passed, $failed failed, $skipped skipped"
if ($failed -gt 0) {
    throw "Smoke test failed for '$AgentName' in '$Environment' ($failed check(s)). Consider rolling back with scripts/Invoke-Rollback.ps1."
}

return [pscustomobject]$summary
