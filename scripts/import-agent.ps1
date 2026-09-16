#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys an immutable agent package to one Azure AI Foundry environment.

.DESCRIPTION
    Order of operations, all of which must succeed before the agent is written:

      1. Package integrity, content address and declared identity are verified.
      2. The environment configuration is loaded and its runtime variable allowlist is applied. No value is
         read from the process environment unless the environment configuration names it.
      3. The overlay is resolved. Every referenced file must live inside the package and be a member of the
         verified checksum inventory.
      4. The governance policy for the target environment is evaluated, including change record validation.
      5. The prior deployed package is resolved and staged so that automatic rollback is actually possible.
         In an environment configured for redeploy-previous-package rollback, an unresolvable prior artifact
         aborts the deployment before anything is mutated.
      6. A read-only Agent Service preflight confirms endpoint and api-version.
      7. The agent is created or updated, the package is published to the content-addressed store, and a
         release record is written with outcome 'pending-verification'.

    The record only becomes 'succeeded' when scripts/Complete-Release.ps1 has validated the required
    post-deployment gates against real, non-empty test evidence. Promotion refuses anything else.

    Authentication: the caller must already be signed in with a workload identity. This script never accepts,
    prints or persists a credential, and -WhatIf emits a structural summary rather than the resolved payload.

.PARAMETER PackagePath
    Path to a .zip package produced by New-AgentPackage.ps1, or to an already extracted package folder.

.PARAMETER Environment
    Target environment: dev, test, uat or prod.

.PARAMETER RuntimeVariable
    Values for placeholders named in the target environment's runtime.allowedVariables allowlist.

.PARAMETER ChangeRecordId
    Approved change record id. Required when the environment's governance requires change_record metadata.

.PARAMETER RollbackStageDirectory
    Directory that receives the prior package so a failing gate can roll back. Defaults to ./out/rollback.

.EXAMPLE
    ./scripts/import-agent.ps1 -PackagePath ./out/support-agent-1.2.0+ab12cd3.zip -Environment dev

.EXAMPLE
    ./scripts/import-agent.ps1 -PackagePath ./out/support-agent-1.2.0+ab12cd3.zip -Environment prod -ChangeRecordId CHG-0043912 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$Environment,

    [ValidateSet('deploy', 'promote', 'rollback')]
    [string]$Operation = 'deploy',

    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$SourceEnvironment,

    [hashtable]$RuntimeVariable = @{},

    [string]$ChangeRecordId,

    [string]$ConfigRoot,

    [string]$ReleaseDirectory,

    [string]$RollbackStageDirectory,

    [string[]]$PriorArtifactSearchDirectory = @(),

    [string]$PackageUri,

    [switch]$ValidateSecretReferences,

    [switch]$SkipPreflight,

    [switch]$AllowMissingRollbackArtifact
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

$repoRoot = Get-RepositoryRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repoRoot 'out/releases' }
if (-not $RollbackStageDirectory) { $RollbackStageDirectory = Join-Path $repoRoot 'out/rollback' }

$extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("foundry-pkg-" + [Guid]::NewGuid().ToString('n'))
$cleanupRequired = $false
$accessToken = $null

try {
    Write-OpsLog -Level Step -Message "Verifying package integrity and identity"
    $packageRoot = Expand-AgentPackage -PackagePath $PackagePath -Destination $extractRoot
    $cleanupRequired = ($packageRoot -eq (Resolve-Path -LiteralPath $extractRoot -ErrorAction SilentlyContinue).Path)

    $descriptor = Read-PackageDescriptor -PackageRoot $packageRoot
    $agentName = $descriptor['agent']['name']
    $agentVersion = $descriptor['agent']['version']
    $packageId = $descriptor['packageId']
    Write-OpsLog -Level Success -Message "Package verified: $agentName $agentVersion ($packageId)"

    if ($descriptor['contents']['environments'] -notcontains $Environment) {
        throw "Package '$packageId' was built for environments [$($descriptor['contents']['environments'] -join ', ')] and does not carry an overlay for '$Environment'. Rebuild the package with -Environment $Environment."
    }

    Write-OpsLog -Level Step -Message "Loading environment configuration for '$Environment'"
    $config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot

    # Change record is a runtime value, never a packaged default.
    $governancePolicy = $config['governance']
    $requiresChangeRecord = $governancePolicy.Contains('requiredMetadataKeys') -and
        $governancePolicy['requiredMetadataKeys'] -and
        ($governancePolicy['requiredMetadataKeys'] -contains 'change_record')

    if ($requiresChangeRecord) {
        $pattern = if ($governancePolicy.Contains('changeRecordPattern')) { [string]$governancePolicy['changeRecordPattern'] } else { '^[A-Za-z]{2,5}-[0-9]{4,10}$' }
        $check = Test-ChangeRecordId -Value $ChangeRecordId -Pattern $pattern
        if (-not $check.IsValid) {
            throw "Environment '$Environment' requires an approved change record: $($check.Problems -join '; '). Supply it with -ChangeRecordId."
        }
        $RuntimeVariable['CHANGE_RECORD_ID'] = $ChangeRecordId
        Write-OpsLog -Level Success -Message "Change record $ChangeRecordId accepted for '$Environment'."
    }
    elseif ($ChangeRecordId) {
        $RuntimeVariable['CHANGE_RECORD_ID'] = $ChangeRecordId
    }

    Write-OpsLog -Level Step -Message "Building the allowlisted runtime variable map"
    $runtimeValues = Get-AllowedRuntimeVariable -EnvironmentConfig $config -RuntimeVariable $RuntimeVariable
    Write-OpsLog -Level Info -Message "Allowlisted variables bound: $(@($runtimeValues.Keys | Sort-Object) -join ', ')"

    Write-OpsLog -Level Step -Message "Resolving effective agent definition"
    $definition = Resolve-AgentDefinition -Path $packageRoot -Environment $Environment -RuntimeVariable $runtimeValues
    $payload = ConvertTo-FoundryAgentPayload -Definition $definition

    Write-OpsLog -Level Step -Message "Evaluating governance policy"
    $governance = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
    if (-not $governance.IsCompliant) {
        foreach ($violation in $governance.Violations) { Write-OpsLog -Level Error -Message $violation }
        throw "Governance policy for environment '$Environment' rejected agent '$agentName'. Resolve the $($governance.Violations.Count) violation(s) above or amend config/environments/$Environment.json through the governance change process."
    }
    Write-OpsLog -Level Success -Message "Governance policy satisfied for '$Environment'."

    $gates = Get-DeploymentGate -Definition $definition
    Write-OpsLog -Level Info -Message "Required post-deployment gates: smoke=$($gates['requireSmokeTestPass']) evaluation=$($gates['requireEvaluationPass']) regression=$($gates['requireRegressionPass']) minimumScore=$($gates['minimumEvaluationScore'])"

    if ($ValidateSecretReferences) {
        $overlay = $definition['overlay']
        if ($overlay.Contains('secretRefs') -and $overlay['secretRefs']) {
            foreach ($key in $overlay['secretRefs'].Keys) {
                $null = Resolve-SecretReference -Reference $overlay['secretRefs'][$key]
                Write-OpsLog -Level Success -Message "Key Vault reference '$key' resolved (value not displayed)."
            }
        }
        else {
            Write-OpsLog -Level Info -Message "Overlay declares no Key Vault references."
        }
    }

    $foundry = $config['foundry']
    $tenantId = if ($config['azure'].Contains('tenantId')) { [string]$config['azure']['tenantId'] } else { $null }

    if ($WhatIfPreference) {
        Write-OpsLog -Level Info -Message "WhatIf: would deploy to $($foundry['projectEndpoint']) (api-version $($foundry['apiVersion']))."
        Write-OpsLog -Level Info -Message "WhatIf: structural summary only. Resolved values are withheld because they can contain tenant topology."
        Write-Output (Get-PayloadSummary -Payload $payload | ConvertTo-Json -Depth 10)
        return [pscustomobject]@{
            AgentName     = $agentName
            Version       = $agentVersion
            PackageId     = $packageId
            Environment   = $Environment
            RemoteAgentId = $null
            Outcome       = 'simulated'
        }
    }

    $accessToken = Get-FoundryAccessToken -Scope $foundry['tokenScope'] -TenantId $tenantId

    if (-not $SkipPreflight) {
        Write-OpsLog -Level Step -Message "Running Agent Service preflight"
        $null = Test-FoundryEndpoint -EnvironmentConfig $config -AccessToken $accessToken
    }

    Write-OpsLog -Level Step -Message "Locating existing managed agent '$agentName'"
    $previousRecord = Get-LatestReleaseRecord -EnvironmentConfig $config -AgentName $agentName -LocalFallbackDirectory $ReleaseDirectory
    $knownAgentId = $null
    if ($previousRecord -and $previousRecord['agent'].Contains('remoteAgentId')) {
        $knownAgentId = [string]$previousRecord['agent']['remoteAgentId']
    }

    $existing = $null
    if ($knownAgentId) {
        try {
            $existing = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $agentName -KnownAgentId $knownAgentId -AccessToken $accessToken
        }
        catch [System.Management.Automation.RuntimeException] {
            Write-OpsLog -Level Warning -Message "Recorded agent id '$knownAgentId' could not be read back; falling back to metadata discovery."
            $existing = $null
        }
    }
    if (-not $existing) {
        $existing = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $agentName -AccessToken $accessToken
    }

    # ---------------------------------------------------------------------------------------------
    # Resolve and stage the prior artifact BEFORE mutating anything. Without this the failure handler
    # only has the candidate package and cannot restore the previous state.
    # ---------------------------------------------------------------------------------------------
    $previous = [ordered]@{}
    $rollbackArtifact = $null

    if ($previousRecord) {
        $previous['packageId'] = $previousRecord['packageId']
        $previous['agentVersion'] = $previousRecord['agent']['version']
        $previous['releaseId'] = $previousRecord['releaseId']
        if ($previousRecord.Contains('packageUri')) { $previous['packageUri'] = $previousRecord['packageUri'] }
    }
    if ($existing) { $previous['remoteAgentId'] = $existing.id }

    $rollbackMode = if ($config['deployment'].Contains('rollbackMode')) { [string]$config['deployment']['rollbackMode'] } else { 'redeploy-previous-package' }
    $rollbackExpected = ($rollbackMode -eq 'redeploy-previous-package') -and $previousRecord -and ($previousRecord['packageId'] -ne $packageId)

    if ($rollbackExpected) {
        Write-OpsLog -Level Step -Message "Staging the prior package so rollback is possible"
        if (-not (Test-Path -LiteralPath $RollbackStageDirectory)) {
            New-Item -ItemType Directory -Force -Path $RollbackStageDirectory | Out-Null
        }
        $searchDirectories = @($PriorArtifactSearchDirectory) + @((Split-Path -Parent (ConvertTo-AbsolutePath -Path $PackagePath)))
        $found = Find-AgentPackage -AgentName $agentName -PackageId $previousRecord['packageId'] `
            -SearchDirectory (@($searchDirectories | Where-Object { $_ })) -EnvironmentConfig $config `
            -DownloadDirectory $RollbackStageDirectory

        if ($found) {
            $staged = Join-Path $RollbackStageDirectory ("rollback-" + (Split-Path -Leaf $found))
            if ((ConvertTo-AbsolutePath -Path $found) -ne (ConvertTo-AbsolutePath -Path $staged)) {
                Copy-Item -LiteralPath $found -Destination $staged -Force
            }
            $rollbackArtifact = $staged
            $previous['artifactRetained'] = $true
            $previous['rollbackArtifactPath'] = $staged
            Write-OpsLog -Level Success -Message "Prior package $($previousRecord['packageId']) staged at $staged"
        }
        elseif ($AllowMissingRollbackArtifact) {
            $previous['artifactRetained'] = $false
            Write-OpsLog -Level Warning -Message "Prior package $($previousRecord['packageId']) could not be located. -AllowMissingRollbackArtifact was supplied, so the deployment continues WITHOUT automatic rollback capability."
        }
        else {
            throw "Environment '$Environment' is configured for redeploy-previous-package rollback, but the prior package '$($previousRecord['packageId'])' could not be located in [$($searchDirectories -join ', ')] or in the package store. Refusing to deploy a change that cannot be reverted. Retrieve the prior artifact and pass -PriorArtifactSearchDirectory, or re-run with -AllowMissingRollbackArtifact if an unrevertable deployment is genuinely acceptable."
        }
    }
    else {
        $previous['artifactRetained'] = $false
        if (-not $previousRecord) {
            Write-OpsLog -Level Info -Message "No prior release record: this is the first deployment to '$Environment', so there is nothing to roll back to."
        }
    }

    $target = if ($existing) { "agent '$($existing.id)' in project $($foundry['projectName'])" } else { "new agent '$agentName' in project $($foundry['projectName'])" }
    if (-not $PSCmdlet.ShouldProcess($target, "Deploy package $packageId")) {
        return [pscustomobject]@{ AgentName = $agentName; Environment = $Environment; Outcome = 'simulated' }
    }

    if ($existing) {
        Write-OpsLog -Level Step -Message "Updating existing agent $($existing.id)"
        $response = Invoke-FoundryApi -Endpoint $foundry['projectEndpoint'] -Path "/assistants/$($existing.id)" `
            -ApiVersion $foundry['apiVersion'] -AccessToken $accessToken -Method POST -Body $payload
    }
    else {
        Write-OpsLog -Level Step -Message "Creating new agent '$agentName'"
        $response = Invoke-FoundryApi -Endpoint $foundry['projectEndpoint'] -Path '/assistants' `
            -ApiVersion $foundry['apiVersion'] -AccessToken $accessToken -Method POST -Body $payload
    }

    $remoteAgentId = $response.Content.id
    if ([string]::IsNullOrWhiteSpace($remoteAgentId)) {
        throw "Agent Service returned HTTP $($response.StatusCode) without an 'id' field. Cannot record the deployment. Verify api-version '$($foundry['apiVersion'])'."
    }
    Write-OpsLog -Level Success -Message "Agent written to '$Environment' as $remoteAgentId"

    # Publish to the content-addressed store so a future rollback does not depend on artifact retention.
    if (-not $PackageUri) {
        $packageFile = ConvertTo-AbsolutePath -Path $PackagePath
        if (Test-Path -LiteralPath $packageFile -PathType Leaf) {
            $PackageUri = Publish-AgentPackage -PackagePath $packageFile -AgentName $agentName -PackageId $packageId -EnvironmentConfig $config -Confirm:$false
        }
    }

    $record = New-ReleaseRecord -Environment $Environment -PackageDescriptor $descriptor -Operation $Operation `
        -Outcome 'pending-verification' -RemoteAgentId $remoteAgentId -SourceEnvironment $SourceEnvironment `
        -GateResults @{ validation = 'passed' } -PackageUri $PackageUri -Previous $previous
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false

    Write-OpsLog -Level Warning -Message "Release $($record['releaseId']) is recorded as pending-verification. Run scripts/Complete-Release.ps1 after the post-deployment gates to attest it; promotion refuses an unattested release."

    Write-CiSummary -Markdown @"
### Deployment to ``$Environment`` (pending verification)

| Field | Value |
| --- | --- |
| Agent | ``$agentName`` |
| Version | ``$agentVersion`` |
| Package id | ``$packageId`` |
| Agent Service id | ``$remoteAgentId`` |
| Operation | $Operation |
| Release id | ``$($record['releaseId'])`` |
| Rollback artifact staged | $(if ($rollbackArtifact) { 'yes' } else { 'not applicable' }) |
| Required gates | smoke=$($gates['requireSmokeTestPass']), evaluation=$($gates['requireEvaluationPass']), regression=$($gates['requireRegressionPass']) |
"@

    return [pscustomobject]@{
        AgentName        = $agentName
        Version          = $agentVersion
        PackageId        = $packageId
        PackageUri       = $PackageUri
        Environment      = $Environment
        RemoteAgentId    = $remoteAgentId
        ReleaseId        = $record['releaseId']
        ReleaseRecord    = $recordPath
        RollbackArtifact = $rollbackArtifact
        RequiredGates    = $gates
        Outcome          = 'pending-verification'
    }
}
finally {
    if ($accessToken) { $accessToken.Dispose() }
    if ($cleanupRequired -and (Test-Path -LiteralPath $extractRoot)) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}
