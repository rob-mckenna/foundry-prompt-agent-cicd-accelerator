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
      6. A read-only Azure AI Projects SDK preflight confirms endpoint, authentication and SDK availability.
         The SDK client does not consume the retained REST apiVersion setting.
      7. The candidate package is published to the target environment's content-addressed store and a prepared
         release record is made durable.
      8. Mutation intent is durable before create_version; returned service identity is persisted before
         activation. Activation completion is recorded only after selector read-back verification.

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

.PARAMETER BusinessSignoffId
    Durable UAT business acceptance reference. PROD requires the format BSO- followed by 4-10 digits.

.PARAMETER RollbackStageDirectory
    Directory that receives the prior package and attested release JSON. Defaults to ReleaseDirectory/rollback-staged.

.PARAMETER GateResult
    Deployment gate outcomes to record in the pending release record. Validation defaults to 'passed' and any
    supplied keys override that default without discarding it.

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

    [string]$BusinessSignoffId,

    [string]$OriginalChangeRecordId,

    [string]$RollbackReason,

    [string]$ConfigRoot,

    [string]$ReleaseDirectory,

    [string]$RollbackStageDirectory,

    [string[]]$PriorArtifactSearchDirectory = @(),

    [hashtable]$GateResult,

    [switch]$ValidateSecretReferences,

    [switch]$SkipPreflight,

    [switch]$AllowMissingRollbackArtifact,

    [string]$DeploymentEvidencePath,

    [string]$RollbackContextPath,

    [string]$RollbackTargetRecordPath,

    [ValidateSet('None', 'AfterPackagePublication', 'AfterActivation')]
    [string]$TestFailurePoint = 'None'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1')

$repoRoot = Get-RepositoryRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repoRoot 'out/releases' }
if (-not $RollbackStageDirectory) { $RollbackStageDirectory = Join-Path $ReleaseDirectory 'rollback-staged' }
if (-not $DeploymentEvidencePath) { $DeploymentEvidencePath = Join-Path $ReleaseDirectory 'deployment-evidence.json' }

$extractRoot = Join-Path $repoRoot ("out\platform-work\foundry-pkg-" + [Guid]::NewGuid().ToString('n'))
$cleanupRequired = $false
$descriptor = $null
$config = $null
$gates = $null
$record = $null
$recordPath = $null
$packageUri = $null
$agentName = $null
$packageId = $null
$rollbackArtifact = $null
$mutationStarted = $false
$mutationCompleted = $false
$failedReleaseAttempted = $false
$failedReleaseRecorded = $false
$failureMessage = $null

function Write-DeploymentEvidence {
    $evidence = [ordered]@{
        schemaVersion          = '1.0.0'
        environment            = $Environment
        priorArtifactStaged    = [bool]$rollbackArtifact
        mutationStarted        = $mutationStarted
        mutationCompleted      = $mutationCompleted
        failedReleaseAttempted = $failedReleaseAttempted
        failedReleaseRecorded  = $failedReleaseRecorded
    }
    if ($agentName) { $evidence['agentName'] = $agentName }
    if ($packageId) { $evidence['packageId'] = $packageId }
    if ($packageUri) { $evidence['packageUri'] = $packageUri }
    if ($record) { $evidence['releaseId'] = $record['releaseId'] }
    if ($recordPath) { $evidence['releaseRecordPath'] = $recordPath }
    if ($rollbackArtifact) { $evidence['rollbackArtifactPath'] = $rollbackArtifact }
    if ($failureMessage) { $evidence['failure'] = $failureMessage }
    if ($mutationStarted -and -not $rollbackArtifact) {
        $evidence['recoveryAction'] = "No prior package exists. Deploy a known-good package explicitly to '$Environment' with import-agent.ps1, then run the required gates; do not attest this failed release."
    }
    Write-JsonFile -InputObject $evidence -Path $DeploymentEvidencePath -Depth 8 -Confirm:$false -WhatIf:$false | Out-Null
}

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
    $config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot -RuntimeVariable $RuntimeVariable

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

    if ($BusinessSignoffId -and $BusinessSignoffId -notmatch '^BSO-[0-9]{4,10}$') {
        throw "BusinessSignoffId '$BusinessSignoffId' is invalid. Expected BSO- followed by 4-10 digits, for example BSO-0043912."
    }
    if ($Environment -eq 'prod') {
        if ([string]::IsNullOrWhiteSpace($BusinessSignoffId)) {
            throw "Environment 'prod' requires durable UAT business acceptance. Supply -BusinessSignoffId in the format BSO-0043912."
        }
        $raiReviewId = if ($descriptor['agent'].Contains('classification') -and $descriptor['agent']['classification']) {
            [string]$descriptor['agent']['classification']['responsibleAiReviewId']
        }
        else { '' }
        if ([string]::IsNullOrWhiteSpace($raiReviewId)) {
            throw "Environment 'prod' requires classification.responsibleAiReviewId in the immutable package."
        }
        Write-OpsLog -Level Success -Message "Business sign-off $BusinessSignoffId and Responsible AI review $raiReviewId accepted for production."
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

    if (-not $SkipPreflight) {
        Write-OpsLog -Level Step -Message "Running Agent Service preflight"
        $null = Test-FoundryEndpoint -EnvironmentConfig $config
    }

    Write-OpsLog -Level Step -Message "Locating existing managed agent '$agentName'"
    $previousRecord = Get-LatestReleaseRecord -EnvironmentConfig $config -AgentName $agentName -LocalFallbackDirectory $ReleaseDirectory
    $existing = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $agentName
    if ($existing) {
        Write-OpsLog -Level Success -Message "Managed agent found: $($existing.id) (latest version $($existing.latestVersion))."
    }
    else {
        Write-OpsLog -Level Info -Message "Managed agent '$agentName' does not exist yet. A new agent will be created."
    }
    if ($Operation -eq 'rollback') {
        if (-not $RollbackContextPath -or -not $RollbackTargetRecordPath) { throw 'Rollback imports require exact context and known-good release evidence. Use Invoke-Rollback.ps1.' }
        $context = Read-ReleaseRecordFile -Path $RollbackContextPath
        $previousRecord = Read-ReleaseRecordFile -Path $RollbackTargetRecordPath
        if ($context['environment'] -ne $Environment -or $context['agent']['name'] -cne $agentName -or
            $context['previous']['releaseId'] -cne $previousRecord['releaseId'] -or
            $previousRecord['packageId'] -cne $packageId -or
            -not $existing -or $existing.activeVersion -cnotin @($context['agent']['serviceVersion'], $context['previous']['serviceVersion'])) {
            throw 'Rollback context, target or serving version has drifted.'
        }
    }
    elseif ($existing) {
        for ($hop = 0; $hop -lt 20 -and $previousRecord; $hop++) {
            if ($previousRecord['agent']['serviceVersion'] -ceq $existing.activeVersion -and
                $previousRecord['deployment']['outcome'] -eq 'succeeded') { break }
            if (-not $previousRecord.Contains('previous') -or -not $previousRecord['previous']['releaseId']) {
                $previousRecord = $null; break
            }
            $previousRecord = Get-ReleaseRecordById -ReleaseId $previousRecord['previous']['releaseId'] `
                -AgentName $agentName -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory
        }
        if (-not $previousRecord -or $previousRecord['agent']['serviceVersion'] -cne $existing.activeVersion) {
            throw 'Cannot reconcile the active service version to an attested prior release; latest.json is only an audit attempt.'
        }
    }
    elseif ($previousRecord) {
        throw 'Release history exists but the managed agent is absent. Explicit manual recovery is required.'
    }
    if ($previousRecord) {
        if ($previousRecord['environment'] -ne $Environment -or $previousRecord['agent']['name'] -cne $agentName -or
            $previousRecord['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -cne $foundry['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -or
            $previousRecord['agent']['remoteAgentId'] -cne $existing.id -or
            ($Operation -ne 'rollback' -and $previousRecord['agent']['serviceVersionId'] -cne $existing.versionId)) {
            throw 'Prior attested release does not match the serving agent/environment/project identity.'
        }
        # Full packaged gate requirements are checked again once the retained package is staged below.
        $priorCheck = Test-ReleaseRecordForPromotion -Record $previousRecord -AgentName $agentName `
            -PackageId $previousRecord['packageId'] -SourceEnvironment $Environment `
            -ExpectedGates $previousRecord['deployment']['attestation']['requiredGates']
        if (-not $priorCheck.IsValid) { throw "Prior release is not known-good: $($priorCheck.Problems -join '; ')" }
    }

    # ---------------------------------------------------------------------------------------------
    # Resolve and stage the prior artifact BEFORE mutating anything. Without this the failure handler
    # only has the candidate package and cannot restore the previous state.
    # ---------------------------------------------------------------------------------------------
    $previous = [ordered]@{}
    if ($previousRecord) {
        $previous['packageId'] = $previousRecord['packageId']
        $previous['agentVersion'] = $previousRecord['agent']['version']
        $previous['releaseId'] = $previousRecord['releaseId']
        $previous['serviceVersion'] = $previousRecord['agent']['serviceVersion']
        $previous['serviceVersionId'] = $previousRecord['agent']['serviceVersionId']
        if ($previousRecord.Contains('packageUri')) { $previous['packageUri'] = $previousRecord['packageUri'] }
    }
    if ($existing) { $previous['remoteAgentId'] = $existing.id }

    $rollbackMode = if ($config['deployment'].Contains('rollbackMode')) { [string]$config['deployment']['rollbackMode'] } else { 'redeploy-previous-package' }
    $rollbackExpected = ($rollbackMode -eq 'redeploy-previous-package') -and $previousRecord

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
            $priorRoot = Join-Path $extractRoot 'prior'
            try {
                $verifiedPriorRoot = Expand-AgentPackage -PackagePath $staged -Destination $priorRoot
                $priorDescriptor = Read-PackageDescriptor -PackageRoot $verifiedPriorRoot
                if ($priorDescriptor['packageId'] -cne $previousRecord['packageId'] -or
                    $priorDescriptor['agent']['name'] -cne $agentName -or
                    $priorDescriptor['agent']['version'] -cne $previousRecord['agent']['version']) {
                    throw 'Staged rollback package does not match the attested prior identity.'
                }
                $priorDefinition = Resolve-AgentDefinition -Path $verifiedPriorRoot -Environment $Environment -SkipPlaceholderExpansion
                $priorCheck = Test-ReleaseRecordForPromotion -Record $previousRecord -AgentName $agentName `
                    -PackageId $previousRecord['packageId'] -SourceEnvironment $Environment -ExpectedGates (Get-DeploymentGate -Definition $priorDefinition)
                if (-not $priorCheck.IsValid) { throw "Retained release gate evidence is invalid: $($priorCheck.Problems -join '; ')" }
            }
            finally { if (Test-Path -LiteralPath $priorRoot) { Remove-Item -LiteralPath $priorRoot -Recurse -Force -Confirm:$false } }
            $priorRecordPath = Join-Path $RollbackStageDirectory "$($previousRecord['releaseId']).json"
            Write-JsonFile -InputObject $previousRecord -Path $priorRecordPath -Depth 32 -Confirm:$false -WhatIf:$false | Out-Null
            $previous['artifactRetained'] = $true
            $previous['rollbackArtifactPath'] = $staged
            $previous['releaseRecordPath'] = $priorRecordPath
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

    # Publication and prepared audit evidence are fallible and therefore complete before activation begins.
    $packageFile = ConvertTo-AbsolutePath -Path $PackagePath
    if (Test-Path -LiteralPath $packageFile -PathType Leaf) {
        $packageUri = Publish-AgentPackage -PackagePath $packageFile -AgentName $agentName -PackageId $packageId -EnvironmentConfig $config -Confirm:$false
    }
    elseif ($config.Contains('packageStore') -and $config['packageStore']) {
        throw "Package store publication requires an immutable package file. '$PackagePath' is a directory; deploy the verified zip so the exact bytes can be retained."
    }
    if ([string]::IsNullOrWhiteSpace($packageUri)) {
        throw "Environment '$Environment' did not publish package '$packageId' to a target package store. Refusing to mutate runtime state without a durable target URI."
    }

    $effectiveGateResult = [ordered]@{ validation = 'passed' }
    if ($PSBoundParameters.ContainsKey('GateResult') -and $GateResult) {
        $effectiveGateResult = Merge-Hashtable -Base $effectiveGateResult -Override $GateResult
    }

    $record = New-ReleaseRecord -Environment $Environment -PackageDescriptor $descriptor -Operation $Operation `
        -Outcome 'pending-verification' -SourceEnvironment $SourceEnvironment `
        -GateResults $effectiveGateResult -PackageUri $packageUri -Previous $previous `
        -ChangeRecordId $ChangeRecordId -BusinessSignoffId $BusinessSignoffId `
        -OriginalChangeRecordId $OriginalChangeRecordId -RollbackReason $RollbackReason
    $record['deployment']['runtimeMutation'] = [ordered]@{
        started   = $false
        completed = $false
        stage     = 'prepared'
    }
    $record['projectEndpoint'] = $config['foundry']['projectEndpoint'].TrimEnd('/').ToLowerInvariant()
    $recordPath = Join-Path $ReleaseDirectory "$($record['releaseId']).json"
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
    Write-DeploymentEvidence

    if ($TestFailurePoint -eq 'AfterPackagePublication') {
        throw 'Simulated failure after target package publication and before runtime activation.'
    }

    Write-OpsLog -Level Step -Message "Creating agent version for '$agentName' through the Azure AI Projects SDK"
    $record['deployment']['runtimeMutation']['started'] = $true
    $record['deployment']['runtimeMutation']['stage'] = 'creating'
    $record['deployment']['runtimeMutation']['startedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
    $mutationStarted = $true
    Write-DeploymentEvidence
    $createdVersion = New-FoundryAgentVersion -EnvironmentConfig $config -LogicalName $agentName -Payload $payload
    Write-OpsLog -Level Success -Message "Created agent version $($createdVersion.version) for '$agentName'."

    if ($createdVersion.PSObject.Properties.Name -contains 'agentId' -and $createdVersion.agentId) {
        $record['agent']['remoteAgentId'] = [string]$createdVersion.agentId
    }
    if (-not $createdVersion.version -or -not $createdVersion.id) { throw 'create_version returned incomplete service identity; mutation may have occurred.' }
    $record['agent']['serviceVersion'] = [string]$createdVersion.version
    $record['agent']['serviceVersionId'] = [string]$createdVersion.id
    $record['deployment']['runtimeMutation']['stage'] = 'created'
    $record['deployment']['runtimeMutation']['candidateVersion'] = [string]$createdVersion.version
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
    Write-DeploymentEvidence
    $record['deployment']['runtimeMutation']['stage'] = 'activating'
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false

    Write-OpsLog -Level Step -Message "Promoting agent version $($createdVersion.version) to active"
    $activation = Set-FoundryAgentActiveVersion -EnvironmentConfig $config -LogicalName $agentName -AgentVersion $createdVersion.version
    if (-not $activation.ok -or $activation.activeVersion -cne $createdVersion.version) { throw 'Activation did not verify the candidate service version.' }
    $mutationCompleted = $true
    $record['deployment']['runtimeMutation']['completed'] = $true
    $record['deployment']['runtimeMutation']['stage'] = 'activated'
    $record['deployment']['runtimeMutation']['completedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
    Write-DeploymentEvidence

    if ($TestFailurePoint -eq 'AfterActivation') {
        throw 'Simulated failure after runtime activation.'
    }

    $refreshedAgent = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $agentName
    $remoteAgentId = if ($refreshedAgent -and $refreshedAgent.id) { [string]$refreshedAgent.id }
    elseif ($createdVersion.PSObject.Properties.Name -contains 'agentId' -and $createdVersion.agentId) {
        Write-OpsLog -Level Warning -Message "Could not re-read the promoted agent immediately; recording the agent id returned by the version creation call."
        [string]$createdVersion.agentId
    }
    else { $null }
    if ([string]::IsNullOrWhiteSpace($remoteAgentId)) {
        throw "The Azure AI Projects SDK created and promoted a version for '$agentName', but the accelerator could not resolve the agent id to record the deployment."
    }
    Write-OpsLog -Level Success -Message "Agent written to '$Environment' as $remoteAgentId"
    $record['agent']['remoteAgentId'] = $remoteAgentId
    $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
    Write-DeploymentEvidence

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
        PackageUri       = $packageUri
        Environment      = $Environment
        RemoteAgentId    = $remoteAgentId
        ReleaseId        = $record['releaseId']
        ReleaseRecord    = $recordPath
        RollbackArtifact = $rollbackArtifact
        RequiredGates    = $gates
        Outcome          = 'pending-verification'
    }
}
catch {
    $originalError = $_
    $failureMessage = $originalError.Exception.Message

    if ($record -and $config) {
        $failedReleaseAttempted = $true
        $record['deployment']['outcome'] = 'failed'
        $record['deployment']['runtimeMutation']['started'] = $mutationStarted
        $record['deployment']['runtimeMutation']['completed'] = $mutationCompleted
        $record['deployment']['runtimeMutation']['stage'] = 'failed'
        $record['deployment']['runtimeMutation']['failure'] = $failureMessage
        $record['deployment']['attestation'] = [ordered]@{
            gatesSatisfied = $false
            attestedAtUtc  = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            attestedBy     = if ($env:GITHUB_ACTOR) { "github:$env:GITHUB_ACTOR" } elseif ($env:BUILD_REQUESTEDFOR) { "azuredevops:$env:BUILD_REQUESTEDFOR" } else { "local:$([Environment]::UserName)" }
            requiredGates  = [ordered]@{
                requireEvaluationPass  = [bool]$gates['requireEvaluationPass']
                requireSmokeTestPass   = [bool]$gates['requireSmokeTestPass']
                requireRegressionPass  = [bool]$gates['requireRegressionPass']
                minimumEvaluationScore = $gates['minimumEvaluationScore']
            }
            evidence       = [ordered]@{}
        }
        try {
            $recordPath = Save-ReleaseRecord -Record $record -EnvironmentConfig $config -LocalDirectory $ReleaseDirectory -Confirm:$false
            $failedReleaseRecorded = $true
        }
        catch {
            $failedReleaseRecorded = [bool]($recordPath -and (Test-Path -LiteralPath $recordPath -PathType Leaf))
            Write-OpsLog -Level Error -Message "Failed release evidence could not be fully published: $($_.Exception.Message)"
        }
    }

    try { Write-DeploymentEvidence }
    catch { Write-OpsLog -Level Error -Message "Deployment evidence could not be written: $($_.Exception.Message)" }

    if ($mutationStarted -and -not $rollbackArtifact) {
        Write-OpsLog -Level Error -Message "Runtime activation may have changed '$Environment', but this is the first deployment and no prior package exists. Deploy a known-good package explicitly with import-agent.ps1 and run all required gates."
    }
    throw $originalError
}
finally {
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}
