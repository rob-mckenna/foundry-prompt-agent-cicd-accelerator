#Requires -Version 7.2
<#
.SYNOPSIS
    Runs one manually approved, frozen-source DEV qualification phase.
.DESCRIPTION
    Default-off hosted path only. Reads the fixed environment configuration after bootstrap masking.
    Never accepts target values or credentials as arguments. See docs/deployment-runbook.md.
    Dot-sourcing defines the reviewed bootstrap and offline-test helpers without executing a phase.
.PARAMETER Phase
    PrivacyProof, Preflight or Experiment. Each requires a separate first-attempt manual dispatch.
.PARAMETER ExpectedCommit
    Full reviewed source SHA, also required to match the workflow source and checked-out HEAD.
.PARAMETER PrivateRoot
    Fresh private directory beneath this checkout's ignored out/qualification directory.
#>
[CmdletBinding()]
param(
    [string]$Phase,
    [string]$ExpectedCommit,
    [string]$PrivacyProofRunId,
    [string]$PreflightRunId,
    [string]$PrivateRoot
)

function Assert-QualificationDispatch {
    param(
        [string]$Event, [string]$Ref, [string]$Attempt, [string]$Sha, [string]$WorkflowSha,
        [string]$Head, [string]$RunId, [string]$ExpectedCommit, [string]$Phase,
        [string]$PrivacyProofRunId, [string]$PreflightRunId
    )
    if ($Event -cne 'workflow_dispatch' -or $Ref -cne 'refs/heads/squad/sdk-first-qualification' -or
        $Attempt -cne '1' -or $ExpectedCommit -cnotmatch '^[a-f0-9]{40}$' -or
        $Sha -cne $ExpectedCommit -or $WorkflowSha -cne $ExpectedCommit -or $Head -cne $ExpectedCommit -or
        $RunId -notmatch '^[1-9][0-9]{0,19}$' -or $Phase -cnotin @('PrivacyProof', 'Preflight', 'Experiment')) {
        throw 'QUAL_SOURCE_BLOCKED'
    }
    if ($Phase -ne 'PrivacyProof' -and ($PrivacyProofRunId -notmatch '^[1-9][0-9]{0,19}$' -or
        [decimal]$PrivacyProofRunId -ge [decimal]$RunId)) { throw 'QUAL_SOURCE_BLOCKED' }
    if ($Phase -eq 'Experiment' -and ($PreflightRunId -notmatch '^[1-9][0-9]{0,19}$' -or
        [decimal]$PreflightRunId -ge [decimal]$RunId -or
        [decimal]$PreflightRunId -le [decimal]$PrivacyProofRunId)) { throw 'QUAL_SOURCE_BLOCKED' }
}

function Get-QualificationKeyPatterns {
    $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    return [ordered]@{
        AZURE_CLIENT_ID = $guid; AZURE_TENANT_ID = $guid; AZURE_SUBSCRIPTION_ID = $guid
        QUAL_FOUNDRY_RESOURCE_GROUP = '^[a-zA-Z0-9][a-zA-Z0-9_.()-]{0,89}$'
        QUAL_FOUNDRY_ACCOUNT = '^[a-zA-Z0-9][a-zA-Z0-9-]{1,63}$'
        QUAL_FOUNDRY_PROJECT = '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$'
        QUAL_PROJECT_ENDPOINT = '^https://[a-zA-Z0-9-]+\.services\.ai\.azure\.com/api/projects/[a-zA-Z0-9._-]+$'
        QUAL_MODEL_DEPLOYMENT = '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$'
        QUAL_STORAGE_ACCOUNT = '^[a-z0-9]{3,24}$'
        QUAL_PACKAGE_CONTAINER = '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$'
        QUAL_RELEASE_CONTAINER = '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$'
        QUAL_EXPERIMENT_ID = '^[a-z][a-z0-9-]{2,62}$'
        QUAL_AGENT_NAME = '^[a-z][a-z0-9-]{2,62}$'
    }
}

function Assert-QualificationValues {
    param([System.Collections.IDictionary]$Values)
    $patterns = Get-QualificationKeyPatterns
    if (-not $Values -or $Values.Count -ne $patterns.Count) { throw 'QUAL_CONFIG_BLOCKED' }
    foreach ($key in $patterns.Keys) {
        if (-not $Values.Contains($key) -or $Values[$key] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Values[$key]) -or $Values[$key].Length -gt 256 -or
            $Values[$key] -match '[\x00-\x20\x7f-\x9f]' -or $Values[$key] -cnotmatch $patterns[$key]) {
            throw 'QUAL_CONFIG_BLOCKED'
        }
    }
    $expectedEndpoint = "https://$($Values.QUAL_FOUNDRY_ACCOUNT).services.ai.azure.com/api/projects/$($Values.QUAL_FOUNDRY_PROJECT)"
    if ($Values.QUAL_PROJECT_ENDPOINT -cne $expectedEndpoint -or
        $Values.QUAL_PACKAGE_CONTAINER -ceq $Values.QUAL_RELEASE_CONTAINER) { throw 'QUAL_CONFIG_BLOCKED' }
    foreach ($key in @('ACTIONS_STEP_DEBUG', 'ACTIONS_RUNNER_DEBUG', 'RUNNER_DEBUG', 'AZURE_CORE_LOG_LEVEL', 'AZURE_LOG_LEVEL')) {
        $value = [Environment]::GetEnvironmentVariable($key)
        if ($value -and $value -cnotin @('false', 'False', '0', 'ERROR', 'error')) { throw 'QUAL_DEBUG_BLOCKED' }
    }
}

function Write-QualificationMask {
    param([string]$Value)
    $escaped = $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::add-mask::$escaped"
}

function Initialize-QualificationEnvironment {
    param([System.Collections.IDictionary]$Values, [string]$EnvironmentFile)
    Assert-QualificationValues -Values $Values
    if (-not $EnvironmentFile) { throw 'QUAL_CONFIG_BLOCKED' }
    $masks = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scopes = @(
        "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($Values.QUAL_FOUNDRY_RESOURCE_GROUP)/providers/Microsoft.CognitiveServices/accounts/$($Values.QUAL_FOUNDRY_ACCOUNT)/projects/$($Values.QUAL_FOUNDRY_PROJECT)"
        "https://$($Values.QUAL_STORAGE_ACCOUNT).blob.core.windows.net"
        "$($Values.QUAL_EXPERIMENT_ID)/qualification/claim.json"
    )
    foreach ($container in @($Values.QUAL_PACKAGE_CONTAINER, $Values.QUAL_RELEASE_CONTAINER)) {
        $scopes += "https://$($Values.QUAL_STORAGE_ACCOUNT).blob.core.windows.net/$container"
    }
    foreach ($value in @($Values.Values) + $scopes) {
        foreach ($form in @($value, $value.ToLowerInvariant(), $value.ToUpperInvariant(),
            [Uri]::EscapeDataString($value), ($value | ConvertTo-Json -Compress).Trim('"'), $value.Replace('/', '\/'))) {
            if ($masks.Add($form)) { Write-QualificationMask -Value $form }
        }
    }
    foreach ($key in $Values.Keys) {
        Add-Content -LiteralPath $EnvironmentFile -Value "$key=$($Values[$key])" -Encoding utf8
        [Environment]::SetEnvironmentVariable("BOOT_$key", $null)
    }
    foreach ($setting in @('AZURE_TOKEN_CREDENTIALS=AzureCliCredential', 'AZURE_CORE_LOG_LEVEL=ERROR',
        'AZURE_LOG_LEVEL=ERROR', 'AZURE_CORE_TRACING_IMPLEMENTATION=none', 'AZURE_HTTP_USER_AGENT=dev-qualification')) {
        Add-Content -LiteralPath $EnvironmentFile -Value $setting -Encoding utf8
    }
}

function New-QualificationSentinels {
    param([string]$Seed)
    if (-not $Seed -or $Seed.Length -lt 8 -or $Seed.Length -gt 256 -or $Seed -match '[\x00-\x20\x7f-\x9f]') {
        throw 'QUAL_CONFIG_BLOCKED'
    }
    $values = [ordered]@{}
    foreach ($key in (Get-QualificationKeyPatterns).Keys) {
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes("$Seed/$key"))).ToLowerInvariant()
        $values[$key] = if ($key -like 'AZURE_*') {
            "$($hash.Substring(0,8))-$($hash.Substring(8,4))-$($hash.Substring(12,4))-$($hash.Substring(16,4))-$($hash.Substring(20,12))"
        } elseif ($key -eq 'QUAL_STORAGE_ACCOUNT') { "q$($hash.Substring(0,20))" }
        else { "q-$($hash.Substring(0,20))" }
    }
    $values.QUAL_PROJECT_ENDPOINT = "https://$($values.QUAL_FOUNDRY_ACCOUNT).services.ai.azure.com/api/projects/$($values.QUAL_FOUNDRY_PROJECT)"
    foreach ($value in $values.Values) {
        if ($value.Contains($Seed) -or $Seed.Contains($value)) { throw 'QUAL_CONFIG_BLOCKED' }
    }
    Assert-QualificationValues -Values $values
    return $values
}

function Resolve-QualificationEvidenceBoundary {
    param([string]$Repository, [string]$Path)
    $Repository = [IO.Path]::GetFullPath($Repository).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $allowed = [IO.Path]::GetFullPath((Join-Path $Repository 'out/qualification'))
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($allowed + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
        [IO.Path]::GetFileName($full) -eq 'public-summary.json') { throw 'QUAL_PATH_BLOCKED' }
    $auth = Join-Path $allowed 'authentication'
    if ($full.Equals($auth, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($auth + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'QUAL_PATH_BLOCKED'
    }
    $part = $full
    while ($part -and $part.Length -ge $Repository.Length) {
        $item = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'QUAL_PATH_BLOCKED'
        }
        $part = Split-Path -Parent $part
    }
    return $full
}

function Resolve-QualificationPrivateRoot {
    param([string]$Repository, [string]$Path)
    $full = Resolve-QualificationEvidenceBoundary -Repository $Repository -Path $Path
    if ($env:GITHUB_STEP_SUMMARY -and [IO.Path]::GetFullPath($env:GITHUB_STEP_SUMMARY).StartsWith(
        $full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) { throw 'QUAL_PATH_BLOCKED' }
    return $full
}

function Get-QualificationAuthPaths {
    param([string]$Repository, [string]$RunId)
    if ($RunId -cnotmatch '^[1-9][0-9]{0,19}$') { throw 'QUAL_AUTH_PATH_BLOCKED' }
    $repositoryPath = [IO.Path]::GetFullPath($Repository).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parent = Join-Path $repositoryPath 'out/qualification/authentication'
    $directory = Join-Path $parent "run-$RunId"
    $owner = "$directory.owner.json"
    foreach ($path in @($directory, $owner)) {
        $part = $path
        while ($part -and $part.Length -ge $repositoryPath.Length) {
            $item = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'QUAL_AUTH_PATH_BLOCKED'
            }
            $part = Split-Path -Parent $part
        }
    }
    return @{ Repository = $repositoryPath; Parent = $parent; Directory = $directory; Owner = $owner; RunId = $RunId }
}

function Set-QualificationAuthPermissions {
    param([string]$Path)
    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($identity)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } else {
        & chmod 700 $Path 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'QUAL_AUTH_PATH_BLOCKED' }
    }
}

function Initialize-QualificationAuthDirectory {
    param([string]$Repository, [string]$RunId, [string]$EnvironmentFile)
    $stream = $null
    try {
        $paths = Get-QualificationAuthPaths -Repository $Repository -RunId $RunId
        if (-not $EnvironmentFile -or (Test-Path -LiteralPath $paths.Directory) -or
            (Test-Path -LiteralPath $paths.Owner)) { throw 'blocked' }
        $null = New-Item -ItemType Directory -Path $paths.Parent -Force -ErrorAction Stop
        $stream = [IO.File]::Open($paths.Owner, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $owner = @{ schemaVersion = '1'; repository = $paths.Repository; runId = $RunId
            directory = $paths.Directory; created = $false }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($owner | ConvertTo-Json -Compress))
        $stream.Write($bytes); $stream.Flush($true)
        $null = New-Item -ItemType Directory -Path $paths.Directory -ErrorAction Stop
        $owner.created = $true
        $stream.Position = 0; $stream.SetLength(0)
        $bytes = [Text.Encoding]::UTF8.GetBytes(($owner | ConvertTo-Json -Compress))
        $stream.Write($bytes); $stream.Flush($true)
        Set-QualificationAuthPermissions -Path $paths.Directory
        foreach ($key in @('AZURE_CONFIG_DIR','QUAL_AUTH_DIRECTORY')) {
            [Environment]::SetEnvironmentVariable($key, $paths.Directory)
            Add-Content -LiteralPath $EnvironmentFile -Value "$key=$($paths.Directory)" -Encoding utf8 -ErrorAction Stop
        }
    } catch { throw 'QUAL_AUTH_PATH_BLOCKED' }
    finally { if ($stream) { $stream.Dispose() } }
}

function Assert-QualificationAuthOwnership {
    param([hashtable]$Paths)
    if (-not (Test-Path -LiteralPath $Paths.Owner -PathType Leaf)) { throw 'QUAL_AUTH_PATH_BLOCKED' }
    $owner = [IO.File]::ReadAllText($Paths.Owner) | ConvertFrom-Json -AsHashtable
    if ($owner.schemaVersion -cne '1' -or $owner.repository -cne $Paths.Repository -or
        $owner.runId -cne $Paths.RunId -or $owner.directory -cne $Paths.Directory -or
        $owner.created -isnot [bool]) { throw 'QUAL_AUTH_PATH_BLOCKED' }
    return $owner
}

function Assert-QualificationAuthDirectory {
    param([string]$Repository, [string]$RunId)
    try {
        $paths = Get-QualificationAuthPaths -Repository $Repository -RunId $RunId
        $owner = Assert-QualificationAuthOwnership -Paths $paths
        if (-not $owner.created -or -not (Test-Path -LiteralPath $paths.Directory -PathType Container) -or
            $env:AZURE_CONFIG_DIR -cne $paths.Directory -or $env:QUAL_AUTH_DIRECTORY -cne $paths.Directory) { throw 'blocked' }
    } catch { throw 'QUAL_AUTH_PATH_BLOCKED' }
}

function Clear-QualificationAuthDirectory {
    param([string]$Repository, [string]$RunId)
    try {
        $paths = Get-QualificationAuthPaths -Repository $Repository -RunId $RunId
        if (-not (Test-Path -LiteralPath $paths.Owner)) {
            if (Test-Path -LiteralPath $paths.Directory) { throw 'blocked' }
            return @{ verified = $true; disposition = 'not-created' }
        }
        $owner = Assert-QualificationAuthOwnership -Paths $paths
        if (-not $owner.created) {
            if (Test-Path -LiteralPath $paths.Directory) { throw 'blocked' }
            return @{ verified = $true; disposition = 'not-created' }
        }
        if (Test-Path -LiteralPath $paths.Directory) {
            if (@(Get-ChildItem -LiteralPath $paths.Directory -Recurse -Force -ErrorAction Stop | Where-Object {
                $_.Attributes -band [IO.FileAttributes]::ReparsePoint
            }).Count -ne 0) { throw 'blocked' }
            Remove-Item -LiteralPath $paths.Directory -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $paths.Directory) { throw 'blocked' }
        return @{ verified = $true; disposition = 'removed' }
    } catch { throw 'QUAL_AUTH_CLEANUP_FAILED' }
}

function Write-QualificationJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
}

function Invoke-QualificationNative {
    param([hashtable]$Context, [string]$Command, [string[]]$Arguments)
    $output = @(& $Command @Arguments 2>> (Join-Path $Context.Root 'native-stderr.log'))
    if ($LASTEXITCODE -ne 0) { throw 'QUAL_OPERATION_FAILED' }
    return ($output -join "`n")
}

function Invoke-QualificationBlob {
    param(
        [hashtable]$Context, [ValidateSet('upload', 'download', 'exists')][string]$Operation,
        [string]$Name, [string]$File, [switch]$Package, [switch]$CreateOnly
    )
    $v = $Context.Values
    $container = if ($Package) { $v.QUAL_PACKAGE_CONTAINER } else { $v.QUAL_RELEASE_CONTAINER }
    $arguments = @('storage', 'blob', $Operation, '--auth-mode', 'login', '--account-name', $v.QUAL_STORAGE_ACCOUNT,
        '--container-name', $container, '--name', $Name, '--only-show-errors', '--output', 'json')
    if ($File) { $arguments += @('--file', $File) }
    if ($Operation -in @('upload', 'download')) { $arguments += '--no-progress' }
    if ($Operation -eq 'upload') {
        $arguments += @('--overwrite', 'false')
        if ($CreateOnly) { $arguments += @('--if-none-match', '*') }
    }
    $result = Invoke-QualificationNative -Context $Context -Command az -Arguments $arguments
    if ($Operation -eq 'exists' -and -not ($result | ConvertFrom-Json).exists) { throw 'QUAL_TARGET_BLOCKED' }
}

function Initialize-QualificationClaim {
    param([hashtable]$Context)
    $claim = [ordered]@{
        schemaVersion = '1'; experiment = $Context.Values.QUAL_EXPERIMENT_ID; agent = $Context.Values.QUAL_AGENT_NAME
        project = $Context.Values.QUAL_PROJECT_ENDPOINT; client = $Context.Values.AZURE_CLIENT_ID
        tenant = $Context.Values.AZURE_TENANT_ID; subscription = $Context.Values.AZURE_SUBSCRIPTION_ID
        sourceSha = $Context.ExpectedCommit; workflowSha = $Context.ExpectedCommit; runId = $Context.RunId; attempt = 1
        privacyProofRunId = $Context.PrivacyProofRunId; preflightRunId = $Context.PreflightRunId
        versionsAllowed = 3; responsesAllowed = 9; versionsUsedBefore = 0; responsesUsedBefore = 0
    }
    $file = Join-Path $Context.Root 'claim.json'
    Write-QualificationJson -Path $file -Value $claim
    $null = Invoke-QualificationBlob -Context $Context -Operation upload `
        -Name "$($Context.Values.QUAL_EXPERIMENT_ID)/qualification/claim.json" -File $file -CreateOnly
    $Context.Claimed = $true
}

function Reserve-QualificationPhase {
    param([hashtable]$Context, [ValidateSet('A', 'B', 'C')][string]$Alias)
    $expected = @('A', 'B', 'C')[$Context.Reservations.Count]
    if (-not $Context.Claimed -or $Context.Reservations.Count -ge 3 -or $Alias -cne $expected -or
        $Context.VersionsReserved -ge 3 -or $Context.ResponsesReserved -gt 6) { throw 'QUAL_BUDGET_BLOCKED' }
    $file = Join-Path $Context.Root "reservation-$Alias.json"
    Write-QualificationJson -Path $file -Value @{
        alias = $Alias; sourceSha = $Context.ExpectedCommit; runId = $Context.RunId
        versionCreations = 1; responsesCreates = 3; ambiguousConsumesAllowance = $true; refundable = $false
    }
    $null = Invoke-QualificationBlob -Context $Context -Operation upload `
        -Name "$($Context.Values.QUAL_EXPERIMENT_ID)/qualification/reservations/$Alias.json" -File $file -CreateOnly
    $Context.Reservations += $Alias
    $Context.VersionsReserved++
    $Context.ResponsesReserved += 3
}

function Invoke-QualificationSdk {
    param([hashtable]$Context, [ValidateSet('qualification-snapshot', 'qualification-delete')][string]$Operation, $InputObject)
    $bridge = Join-Path $Context.Repository 'scripts/python/foundry_agent_cli.py'
    $inputJson = if ($InputObject) { $InputObject | ConvertTo-Json -Depth 64 -Compress } else { '{}' }
    $raw = $inputJson | & python $bridge $Operation 2>> (Join-Path $Context.Root 'sdk-stderr.log')
    if ($LASTEXITCODE -ne 0) { throw 'QUAL_TARGET_BLOCKED' }
    return ($raw | ConvertFrom-Json -AsHashtable -Depth 64)
}

function Assert-QualificationPreflight {
    param([hashtable]$Context)
    if ($env:AZURE_TOKEN_CREDENTIALS -cne 'AzureCliCredential') { throw 'QUAL_IDENTITY_BLOCKED' }
    $account = Invoke-QualificationNative -Context $Context -Command az -Arguments @(
        'account', 'show', '--only-show-errors', '--output', 'json') | ConvertFrom-Json -AsHashtable
    if ($account.tenantId -ine $Context.Values.AZURE_TENANT_ID -or
        $account.id -ine $Context.Values.AZURE_SUBSCRIPTION_ID -or
        $account.user.type -cne 'servicePrincipal' -or $account.user.name -ine $Context.Values.AZURE_CLIENT_ID) {
        throw 'QUAL_IDENTITY_BLOCKED'
    }
    $snapshot = Invoke-QualificationSdk -Context $Context -Operation qualification-snapshot
    if ($snapshot.found -or -not $snapshot.modelMatched) { throw 'QUAL_TARGET_BLOCKED' }
    foreach ($container in @($Context.Values.QUAL_PACKAGE_CONTAINER, $Context.Values.QUAL_RELEASE_CONTAINER)) {
        $null = Invoke-QualificationNative -Context $Context -Command az -Arguments @(
            'storage', 'container', 'show', '--auth-mode', 'login', '--account-name', $Context.Values.QUAL_STORAGE_ACCOUNT,
            '--name', $container, '--only-show-errors', '--output', 'none')
    }
    Write-QualificationJson -Path (Join-Path $Context.Root 'preflight.json') -Value @{
        sourceSha = $Context.ExpectedCommit; runId = $Context.RunId; account = $account
        snapshot = $snapshot; privacyProofRunId = $Context.PrivacyProofRunId
        createAuthorityProven = $false; inferenceAuthorityProven = $false
    }
}

function Assert-QualificationSmoke {
    param([System.Collections.IDictionary]$Result, [switch]$ExpectedFailure)
    $failed = @($Result.checks | Where-Object Result -EQ failed)
    $live = @($Result.checks | Where-Object Live)
    if ($Result.mode -cne 'live' -or $Result.skipped -ne 0 -or $Result.liveExecuted -ne 2 -or $live.Count -ne 2 -or
        @($live | Where-Object { $_.Result -cne 'passed' -or $_.Status -cne 'completed' -or
            -not $_.ResponseId -or -not $_.ConversationId }).Count -ne 0) { throw 'QUAL_GATE_FAILED' }
    if ($ExpectedFailure) {
        if ($Result.failed -ne 1 -or $failed.Count -ne 1 -or
            $failed[0].Name -cne 'Model deployment matches overlay' -or $failed[0].Live) { throw 'QUAL_GATE_FAILED' }
    } elseif ($Result.failed -ne 0 -or $failed.Count -ne 0) { throw 'QUAL_GATE_FAILED' }
}

function Assert-QualificationEvaluation {
    param([System.Collections.IDictionary]$Result)
    if ($Result.mode -cne 'live' -or $Result.liveExecuted -ne 1 -or $Result.total -ne 1 -or
        $Result.failed -ne 0 -or -not $Result.thresholdsMet -or $Result.records.Count -ne 1 -or
        -not $Result.records[0].Passed -or $Result.records[0].Status -cne 'completed' -or
        -not $Result.records[0].ResponseId -or -not $Result.records[0].ConversationId -or
        @($Result.records[0].Checks | Where-Object Result -NE passed).Count -ne 0) { throw 'QUAL_GATE_FAILED' }
}

function Assert-QualificationExpectedErrors {
    param([string]$SmokeMessage, [string]$AttestationMessage, [string]$AgentName, [string]$ReleaseId)
    if ($SmokeMessage -cne "Smoke test failed for '$AgentName' in 'dev' (1 check(s)). Consider rolling back with scripts/Invoke-Rollback.ps1." -or
        $AttestationMessage -cne "Release $ReleaseId failed its required gates in 'dev': Gate 'smoke' is required in 'dev' and reported 'failed'.") {
        throw 'QUAL_GATE_FAILED'
    }
}

function Get-QualificationOriginalArchives {
    param([hashtable]$Context)
    $archives = @()
    if ($Context.ContainsKey('Packages') -or $Context.ContainsKey('PackageArchiveHashes')) {
        if (-not $Context.ContainsKey('Packages') -or -not $Context.ContainsKey('PackageArchiveHashes') -or
            $Context.Packages -isnot [System.Collections.IDictionary] -or
            $Context.PackageArchiveHashes -isnot [System.Collections.IDictionary] -or
            $Context.Packages.Count -ne $Context.PackageArchiveHashes.Count) { throw 'QUAL_RETENTION_FAILED' }
        $root = [IO.Path]::GetFullPath($Context.Root).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        foreach ($alias in $Context.Packages.Keys) {
            $path = $Context.Packages[$alias].PackagePath
            $hash = $Context.PackageArchiveHashes[$alias]
            if ($alias -cnotin @('A','B') -or $path -isnot [string] -or -not $path -or
                $hash -isnot [string] -or $hash -cnotmatch '^[A-F0-9]{64}$') { throw 'QUAL_RETENTION_FAILED' }
            $path = [IO.Path]::GetFullPath($path)
            if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $comparison) -or
                [IO.Path]::GetExtension($path) -cne '.zip' -or
                -not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -cne $hash) {
                throw 'QUAL_RETENTION_FAILED'
            }
            $archives += @{ path = $path; file = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/'); sha256 = $hash }
        }
    }
    if ($Context.Created.Count -gt 0 -and $archives.Count -eq 0) { throw 'QUAL_RETENTION_FAILED' }
    return $archives
}

function Assert-QualificationArchiveInventory {
    param([array]$Archives, [array]$Inventory, [string]$Experiment)
    foreach ($archive in $Archives) {
        $entry = @($Inventory | Where-Object { $_.file -ceq $archive.file })
        if ($entry.Count -ne 1 -or $entry[0].sha256 -cne $archive.sha256 -or
            $entry[0].blob -cne "$Experiment/evidence/$($archive.file)") { throw 'QUAL_RETENTION_FAILED' }
    }
}

function Export-QualificationEvidence {
    param([hashtable]$Context)
    $Context.RetentionVerified = $false
    $repository = if ($Context.ContainsKey('Repository')) { $Context.Repository } else { Split-Path -Parent $PSScriptRoot }
    $null = Resolve-QualificationEvidenceBoundary -Repository $repository -Path $Context.Root
    if (@(Get-ChildItem -LiteralPath $Context.Root -Recurse -Force -ErrorAction Stop | Where-Object {
        $_.Attributes -band [IO.FileAttributes]::ReparsePoint
    }).Count -ne 0) { throw 'QUAL_PATH_BLOCKED' }
    $archives = @(Get-QualificationOriginalArchives -Context $Context)
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $excluded = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($relative in @('readback.bin','known-good-readback.bin','cleanup-readback.json',
        'inventory.json','inventory-readback.json')) {
        $null = $excluded.Add([IO.Path]::GetFullPath((Join-Path $Context.Root $relative)))
    }
    $files = @(Get-ChildItem -LiteralPath $Context.Root -Recurse -File -ErrorAction Stop |
        Where-Object { -not $excluded.Contains($_.FullName) })
    if ($files.Count -eq 0) { throw 'QUAL_RETENTION_FAILED' }
    foreach ($archive in $archives) {
        if (@($files | Where-Object { $_.FullName -ceq $archive.path }).Count -ne 1) { throw 'QUAL_RETENTION_FAILED' }
    }
    $inventory = @()
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Context.Root, $file.FullName).Replace('\', '/')
        $package = $file.Extension -eq '.zip'
        $name = "$($Context.Values.QUAL_EXPERIMENT_ID)/evidence/$relative"
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $null = Invoke-QualificationBlob -Context $Context -Operation upload -Name $name -File $file.FullName -Package:$package -CreateOnly
        $readback = Join-Path $Context.Root 'readback.bin'
        if (Test-Path -LiteralPath $readback) { Remove-Item -LiteralPath $readback -Force -ErrorAction Stop }
        $null = Invoke-QualificationBlob -Context $Context -Operation download -Name $name -File $readback -Package:$package
        if ((Get-FileHash -LiteralPath $readback -Algorithm SHA256).Hash -cne $hash -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -cne $hash) { throw 'QUAL_RETENTION_FAILED' }
        $inventory += @{ file = $relative; blob = $name; sha256 = $hash; length = $file.Length }
    }
    Assert-QualificationArchiveInventory -Archives $archives -Inventory $inventory -Experiment $Context.Values.QUAL_EXPERIMENT_ID
    $file = Join-Path $Context.Root 'inventory.json'
    Write-QualificationJson -Path $file -Value @{
        files = $inventory; capturedUtc = [DateTime]::UtcNow.ToString('o')
        retainUntilUtc = [DateTime]::UtcNow.AddDays(30).ToString('o')
    }
    $name = "$($Context.Values.QUAL_EXPERIMENT_ID)/evidence/inventory.json"
    $inventoryHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash
    $null = Invoke-QualificationBlob -Context $Context -Operation upload -Name $name -File $file -CreateOnly
    $readback = Join-Path $Context.Root 'inventory-readback.json'
    if (Test-Path -LiteralPath $readback) { Remove-Item -LiteralPath $readback -Force -ErrorAction Stop }
    $null = Invoke-QualificationBlob -Context $Context -Operation download -Name $name -File $readback
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $inventoryHash -or
        (Get-FileHash -LiteralPath $readback -Algorithm SHA256).Hash -cne $inventoryHash) { throw 'QUAL_RETENTION_FAILED' }
    $verified = [IO.File]::ReadAllText($readback) | ConvertFrom-Json -AsHashtable
    if (-not $verified.files -or $verified.files.Count -ne $inventory.Count) { throw 'QUAL_RETENTION_FAILED' }
    $null = @(Get-QualificationOriginalArchives -Context $Context)
    Assert-QualificationArchiveInventory -Archives $archives -Inventory $verified.files -Experiment $Context.Values.QUAL_EXPERIMENT_ID
    $Context.RetentionVerified = $true
}

function Remove-QualificationAgent {
    param([hashtable]$Context)
    if (-not $Context.RetentionVerified -or $Context.Created.Count -eq 0) { throw 'QUAL_CLEANUP_BLOCKED' }
    $snapshot = Invoke-QualificationSdk -Context $Context -Operation qualification-snapshot
    $expected = @($Context.Created | ForEach-Object {
        @{ id = $_.agent.serviceVersionId; version = $_.agent.serviceVersion }
    })
    if (-not $snapshot.found -or $snapshot.id -cne $Context.Created[0].agent.remoteAgentId -or
        $snapshot.name -cne $Context.Values.QUAL_AGENT_NAME -or
        $snapshot.activeVersion -cne $Context.Created[-1].agent.serviceVersion -or
        $snapshot.versions.Count -ne $expected.Count -or
        @($snapshot.versions | Where-Object {
            $_.metadata.qualification_experiment -cne $Context.Values.QUAL_EXPERIMENT_ID -or
            $_.id -cnotin $expected.id -or
            $_.version -cne ($expected | Where-Object id -CEQ $_.id | Select-Object -ExpandProperty version)
        }).Count -ne 0) { throw 'QUAL_CLEANUP_BLOCKED' }
    $receipt = Invoke-QualificationSdk -Context $Context -Operation qualification-delete -InputObject $snapshot
    if (-not $receipt.absent) { throw 'QUAL_CLEANUP_BLOCKED' }
    $Context.AgentRemovalVerified = $true
    $Context.CleanupVerified = -not ($Context.ContainsKey('InvocationCleanupVerified') -and
        -not $Context.InvocationCleanupVerified)
    $receipt['agentRemovalVerified'] = $true
    $receipt['invocationCleanupVerified'] = $Context.CleanupVerified
    $file = Join-Path $Context.Root 'cleanup-receipt.json'
    Write-QualificationJson -Path $file -Value $receipt
    $name = "$($Context.Values.QUAL_EXPERIMENT_ID)/evidence/cleanup-receipt.json"
    $null = Invoke-QualificationBlob -Context $Context -Operation upload -Name $name -File $file -CreateOnly
    $readback = Join-Path $Context.Root 'cleanup-readback.json'
    $null = Invoke-QualificationBlob -Context $Context -Operation download -Name $name -File $readback
    if ((Get-FileHash -LiteralPath $file).Hash -cne (Get-FileHash -LiteralPath $readback).Hash) { throw 'QUAL_RETENTION_FAILED' }
}

function Complete-QualificationRetention {
    param([hashtable]$Context)
    Export-QualificationEvidence -Context $Context
    Remove-QualificationAgent -Context $Context
}

function ConvertTo-QualificationPublicResult {
    param(
        [string]$Phase, [string]$Status, [string]$Commit,
        [ValidateRange(0,3)][int]$VersionsReserved = 0, [ValidateRange(0,9)][int]$ResponsesReserved = 0,
        [bool]$ExpectedBFailure = $false, [bool]$RecoveryVerified = $false,
        [bool]$RetentionVerified = $false, [bool]$CleanupVerified = $false
    )
    if ($Phase -cnotin @('PrivacyProof', 'Preflight', 'Experiment') -or
        $Status -cnotin @('passed', 'blocked', 'failed') -or $Commit -cnotmatch '^[a-f0-9]{40}$') {
        throw 'QUAL_SUMMARY_BLOCKED'
    }
    return [ordered]@{
        phase = $Phase; status = $Status; reviewedSha = $Commit
        scope = 'phase-only'
        authenticationTeardown = if ($Phase -eq 'PrivacyProof') { 'not-applicable' } else { 'pending' }
        versionsReserved = $VersionsReserved; responsesReserved = $ResponsesReserved
        expectedBFailure = $ExpectedBFailure; recoveryVerified = $RecoveryVerified
        retentionVerified = $RetentionVerified; cleanupVerified = $CleanupVerified
    }
}

function Invoke-QualificationScript {
    param([hashtable]$Context, [string]$Path, [hashtable]$Parameters, [string]$ContractProperty)
    $objects = @(& (Join-Path $Context.Repository $Path) @Parameters)
    if ($ContractProperty) {
        $contract = @($objects | Where-Object { $_.PSObject.Properties.Name -contains $ContractProperty })
        if ($contract.Count -ne 1) { throw 'QUAL_CONTRACT_FAILED' }
        return $contract[0]
    }
}

function Invoke-QualificationPrivacyProof {
    param([hashtable]$Context)
    $values = [ordered]@{}
    foreach ($key in (Get-QualificationKeyPatterns).Keys) { $values[$key] = [Environment]::GetEnvironmentVariable($key) }
    Assert-QualificationValues -Values $values
    foreach ($case in @('missing', 'malformed', 'control')) {
        $candidate = [ordered]@{}
        foreach ($key in $values.Keys) { $candidate[$key] = $values[$key] }
        switch ($case) {
            missing { $candidate.Remove('QUAL_AGENT_NAME') }
            malformed { $candidate.QUAL_AGENT_NAME = '!' }
            control { $candidate.QUAL_AGENT_NAME = "inert`ncanary" }
        }
        $blocked = $false
        try {
            Initialize-QualificationEnvironment -Values $candidate -EnvironmentFile (Join-Path $Context.Root 'negative-env')
        } catch { $blocked = $_.Exception.Message -ceq 'QUAL_CONFIG_BLOCKED' }
        if (-not $blocked) { throw 'QUAL_PRIVACY_BLOCKED' }
    }
    $probe = Join-Path $Context.Root 'private-summary-probe.txt'
    [IO.File]::WriteAllText($probe, ($values.Values -join "`n"))
    $public = ConvertTo-QualificationPublicResult -Phase PrivacyProof -Status passed -Commit $Context.ExpectedCommit |
        ConvertTo-Json -Compress
    foreach ($value in $values.Values) {
        if ($public.Contains($value)) { throw 'QUAL_PRIVACY_BLOCKED' }
    }
    Write-QualificationJson -Path (Join-Path $Context.Root 'privacy-proof.json') -Value @{
        sourceSha = $Context.ExpectedCommit; originalSecretHeadersPlanned = 1; derivedValues = 13
        negativeCases = 3; azureAccess = $false; oidcRequested = $false; responses = 0; versions = 0
        hostedLogInspectionRequired = $true; cancellationCoverageGuaranteed = $false
    }
}

function Initialize-QualificationPackages {
    param([hashtable]$Context)
    Import-Module (Join-Path $Context.Repository 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1')
    $source = Join-Path $Context.Root 'source'
    Copy-Item -LiteralPath (Join-Path $Context.Repository 'samples/simple-agent') -Destination $source -Recurse
    $manifestPath = Join-Path $source 'agent.manifest.json'
    $manifest = Read-JsonFile -Path $manifestPath
    if ($manifest.version -cne '1.0.0' -or @($manifest.tools).Count -ne 0) { throw 'QUAL_CASES_BLOCKED' }
    $manifest.name = $Context.Values.QUAL_AGENT_NAME
    $manifest.model.deploymentName = $Context.Values.QUAL_MODEL_DEPLOYMENT
    $manifest.metadata.qualification_experiment = $Context.Values.QUAL_EXPERIMENT_ID
    $overlayPath = Join-Path $source 'environments/dev.overlay.json'
    $overlay = Read-JsonFile -Path $overlayPath
    $overlay.model.deploymentName = $Context.Values.QUAL_MODEL_DEPLOYMENT
    $overlay.deploymentGates.requireSmokeTestPass = $true
    $overlay.deploymentGates.requireEvaluationPass = $true
    $overlay.deploymentGates.requireRegressionPass = $false
    Write-QualificationJson -Path $overlayPath -Value $overlay
    $suitePath = Join-Path $source 'evaluations/baseline.evaluation.json'
    $suite = Read-JsonFile -Path $suitePath
    if ($suite.execution.mode -cne 'live' -or @($suite.evaluators | Where-Object {
        $_.type -cnotin @('contains-all', 'not-contains', 'latency')
    }).Count -ne 0) { throw 'QUAL_CASES_BLOCKED' }
    $suite.dataset.maxRecords = 1
    $suite.execution.maxParallel = 1
    $suite.appliesTo = @('dev')
    $dataset = Get-Content -LiteralPath (Join-Path $source 'evaluations/dataset.jsonl') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1 | ConvertFrom-Json
    if ($dataset.id -cne 's-001' -or $dataset.query -cne 'How long does standard delivery take?') {
        throw 'QUAL_CASES_BLOCKED'
    }
    Write-QualificationJson -Path $suitePath -Value $suite
    $checks = Read-JsonFile -Path (Join-Path $Context.Repository 'tests/smoke/smoke-checks.json')
    $applicable = @($checks.checks | Where-Object {
        (-not $_.Contains('agents') -or -not $_.agents -or $_.agents -contains $manifest.name) -and
        (-not $_.Contains('environments') -or -not $_.environments -or $_.environments -contains 'dev')
    })
    if ($applicable.Count -ne 2 -or $applicable[0].id -cne 'responds' -or
        $applicable[1].id -cne 'refuses-configuration-disclosure') { throw 'QUAL_CASES_BLOCKED' }
    $config = Read-JsonFile -Path (Join-Path $Context.Repository 'config/environments/dev.json')
    $v = $Context.Values
    $config.azure.tenantId = $v.AZURE_TENANT_ID
    $config.azure.subscriptionId = $v.AZURE_SUBSCRIPTION_ID
    $config.azure.resourceGroup = $v.QUAL_FOUNDRY_RESOURCE_GROUP
    $config.foundry.accountName = $v.QUAL_FOUNDRY_ACCOUNT
    $config.foundry.projectName = $v.QUAL_FOUNDRY_PROJECT
    $config.foundry.projectEndpoint = $v.QUAL_PROJECT_ENDPOINT
    $config.foundry.defaultModelDeployment = $v.QUAL_MODEL_DEPLOYMENT
    $config.packageStore.accountName = $v.QUAL_STORAGE_ACCOUNT
    $config.packageStore.container = $v.QUAL_PACKAGE_CONTAINER
    $config.releaseStore.accountName = $v.QUAL_STORAGE_ACCOUNT
    $config.releaseStore.container = $v.QUAL_RELEASE_CONTAINER
    $configRoot = Join-Path $Context.Root 'config'
    $null = New-Item -ItemType Directory -Path $configRoot
    Write-QualificationJson -Path (Join-Path $configRoot 'dev.json') -Value $config
    $Context.ConfigRoot = $configRoot
    $Context.SuitePath = $suitePath
    $Context.ReleaseDirectory = Join-Path $Context.Root 'releases'
    $null = New-Item -ItemType Directory -Path $Context.ReleaseDirectory
    $Context.Packages = @{}
    $Context.PackageArchiveHashes = @{}
    foreach ($alias in @('A', 'B')) {
        $manifest.version = if ($alias -eq 'A') { '1.0.0' } else { '1.0.1' }
        if ($alias -eq 'B') { Add-Content -LiteralPath (Join-Path $source 'instructions.md') -Value "`nPlease keep responses concise." }
        Write-QualificationJson -Path $manifestPath -Value $manifest
        $package = Invoke-QualificationScript -Context $Context -Path 'scripts/New-AgentPackage.ps1' -Parameters @{
            AgentPath = $source; OutputDirectory = (Join-Path $Context.Root "package-$alias")
            Environment = @('dev'); SourceCommit = $Context.ExpectedCommit
        } -ContractProperty PackagePath
        $Context.Packages[$alias] = $package
        $Context.PackageArchiveHashes[$alias] = (Get-FileHash -LiteralPath $package.PackagePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $null = Invoke-QualificationScript -Context $Context -Path 'scripts/Test-AgentPackage.ps1' -Parameters @{
            PackagePath = $package.PackagePath; Environment = @('dev'); ConfigRoot = $configRoot
        }
    }
}

function Invoke-QualificationRelease {
    param([hashtable]$Context, [ValidateSet('A', 'B')][string]$Alias)
    Reserve-QualificationPhase -Context $Context -Alias $Alias
    $import = @{
        PackagePath = $Context.Packages[$Alias].PackagePath; Environment = 'dev'; ConfigRoot = $Context.ConfigRoot
        ReleaseDirectory = $Context.ReleaseDirectory; DisableCreateRetries = $true; Confirm = $false
    }
    if ($Alias -eq 'B') { $import.PriorArtifactSearchDirectory = @($Context.KnownGoodDirectory) }
    $result = Invoke-QualificationScript -Context $Context -Path 'scripts/import-agent.ps1' -Parameters $import -ContractProperty ReleaseRecord
    $record = Read-JsonFile -Path $result.ReleaseRecord
    $Context.Created += , $record
    if ($record.deployment.outcome -cne 'pending-verification' -or -not $record.deployment.runtimeMutation.completed) {
        throw 'QUAL_RELEASE_FAILED'
    }
    if ($Alias -eq 'B') {
        if (-not $record.previous.artifactRetained -or
            (Get-FileHash -LiteralPath $record.previous.rollbackArtifactPath).Hash -cne $Context.AZipHash -or
            (Get-FileHash -LiteralPath $record.previous.releaseRecordPath).Hash -cne $Context.ARecordHash) {
            throw 'QUAL_STAGING_FAILED'
        }
        $Context.BRecordPath = $result.ReleaseRecord
    }
    $smokePath = Join-Path $Context.Root "$Alias-smoke.json"
    $evaluationPath = Join-Path $Context.Root "$Alias-evaluation.json"
    $runner = @{
        Environment = 'dev'; AgentName = $Context.Values.QUAL_AGENT_NAME; ConfigRoot = $Context.ConfigRoot
        ReleaseRecordPath = $result.ReleaseRecord; ExpectedVersion = $record.agent.version
        ExpectedModelDeployment = $Context.Values.QUAL_MODEL_DEPLOYMENT; ExpectedToolCount = 0; ResultPath = $smokePath
    }
    if ($Alias -eq 'B') {
        $runner.ExpectedModelDeployment = 'qualification deliberately unequal model expectation'
        if ($runner.ExpectedModelDeployment -ceq $Context.Values.QUAL_MODEL_DEPLOYMENT) { throw 'QUAL_CASES_BLOCKED' }
    }
    $smokeThrew = $false
    $smokeFailure = $null
    try { $null = Invoke-QualificationScript -Context $Context -Path 'tests/smoke/Invoke-SmokeTest.ps1' -Parameters $runner }
    catch {
        if ($_.Exception.Message -cin @('QUAL_INVOCATION_CLEANUP_FAILED','QUAL_INVOCATION_CLEANUP_UNVERIFIED')) {
            $Context.InvocationCleanupVerified = $false
            $Context.RecoveryVerified = $false
            $Context.CleanupVerified = $false
            throw
        }
        $smokeThrew = $true; $smokeFailure = $_.Exception.Message
    }
    $smoke = Read-JsonFile -Path $smokePath
    if ($smokeThrew -ne ($Alias -eq 'B')) { throw 'QUAL_GATE_FAILED' }
    Assert-QualificationSmoke -Result $smoke -ExpectedFailure:($Alias -eq 'B')
    $null = Invoke-QualificationScript -Context $Context -Path 'tests/evaluations/Invoke-EvaluationSuite.ps1' -Parameters @{
        Environment = 'dev'; AgentName = $Context.Values.QUAL_AGENT_NAME; ConfigRoot = $Context.ConfigRoot
        ReleaseRecordPath = $result.ReleaseRecord; SuitePath = $Context.SuitePath; ResultPath = $evaluationPath
    }
    Assert-QualificationEvaluation -Result (Read-JsonFile -Path $evaluationPath)
    $completeThrew = $false
    $completeFailure = $null
    try {
        $null = Invoke-QualificationScript -Context $Context -Path 'scripts/Complete-Release.ps1' -Parameters @{
            ReleaseRecordPath = $result.ReleaseRecord; PackagePath = $Context.Packages[$Alias].PackagePath
            ConfigRoot = $Context.ConfigRoot; ReleaseDirectory = $Context.ReleaseDirectory
            SmokeResultPath = $smokePath; EvaluationResultPath = $evaluationPath; Confirm = $false
        }
    } catch { $completeThrew = $true; $completeFailure = $_.Exception.Message }
    $attested = Read-JsonFile -Path $result.ReleaseRecord
    $Context.Created[-1] = $attested
    if ($Alias -eq 'A') {
        if ($completeThrew -or $attested.deployment.outcome -cne 'succeeded' -or
            -not $attested.deployment.attestation.gatesSatisfied) { throw 'QUAL_ATTESTATION_FAILED' }
        $Context.ARecordPath = $result.ReleaseRecord
    } else {
        Assert-QualificationExpectedErrors -SmokeMessage $smokeFailure -AttestationMessage $completeFailure `
            -AgentName $Context.Values.QUAL_AGENT_NAME -ReleaseId $result.ReleaseId
        if (-not $completeThrew -or $attested.deployment.outcome -cne 'failed' -or
            $attested.deployment.attestation.gatesSatisfied -or
            $attested.deployment.gateResults.smoke -cne 'failed' -or
            $attested.deployment.gateResults.evaluation -cne 'passed') { throw 'QUAL_ATTESTATION_FAILED' }
        $Context.BRecordHash = (Get-FileHash -LiteralPath $result.ReleaseRecord).Hash
        $Context.BEvidenceHashes = @{
            $smokePath = (Get-FileHash -LiteralPath $smokePath).Hash
            $evaluationPath = (Get-FileHash -LiteralPath $evaluationPath).Hash
        }
        $Context.ExpectedBFailure = $true
    }
}

function Stage-QualificationKnownGood {
    param([hashtable]$Context)
    $Context.KnownGoodDirectory = Join-Path $Context.Root 'known-good'
    $null = New-Item -ItemType Directory -Path $Context.KnownGoodDirectory
    $Context.AZipHash = (Get-FileHash -LiteralPath $Context.Packages.A.PackagePath).Hash
    $Context.ARecordHash = (Get-FileHash -LiteralPath $Context.ARecordPath).Hash
    foreach ($original in @($Context.Packages.A.PackagePath, $Context.ARecordPath)) {
        $copy = Join-Path $Context.KnownGoodDirectory (Split-Path -Leaf $original)
        Copy-Item -LiteralPath $original -Destination $copy
        if ((Get-FileHash -LiteralPath $original).Hash -cne (Get-FileHash -LiteralPath $copy).Hash) { throw 'QUAL_STAGING_FAILED' }
        $package = [IO.Path]::GetExtension($original) -eq '.zip'
        $name = "$($Context.Values.QUAL_EXPERIMENT_ID)/known-good/$(Split-Path -Leaf $original)"
        $null = Invoke-QualificationBlob -Context $Context -Operation upload -Name $name -File $copy -Package:$package -CreateOnly
        $readback = Join-Path $Context.Root 'known-good-readback.bin'
        Remove-Item -LiteralPath $readback -Force -ErrorAction SilentlyContinue
        $null = Invoke-QualificationBlob -Context $Context -Operation download -Name $name -File $readback -Package:$package
        if ((Get-FileHash -LiteralPath $original).Hash -cne (Get-FileHash -LiteralPath $readback).Hash) { throw 'QUAL_STAGING_FAILED' }
    }
}

function Invoke-QualificationExperiment {
    param([hashtable]$Context)
    if (-not $Context.ContainsKey('InvocationCleanupVerified')) { $Context.InvocationCleanupVerified = $true }
    Initialize-QualificationPackages -Context $Context
    Invoke-QualificationRelease -Context $Context -Alias A
    Stage-QualificationKnownGood -Context $Context
    Invoke-QualificationRelease -Context $Context -Alias B
    Reserve-QualificationPhase -Context $Context -Alias C
    $b = Read-JsonFile -Path $Context.BRecordPath
    $stagedA = $b.previous.rollbackArtifactPath
    $rollback = Invoke-QualificationScript -Context $Context -Path 'scripts/Invoke-Rollback.ps1' -Parameters @{
        AgentName = $Context.Values.QUAL_AGENT_NAME; Environment = 'dev'; ReleaseRecordPath = $Context.BRecordPath
        ArtifactDirectory = (Split-Path -Parent $stagedA); ConfigRoot = $Context.ConfigRoot
        ReleaseDirectory = $Context.ReleaseDirectory; EvaluationSuitePath = $Context.SuitePath
        Reason = 'Bounded qualification expected configuration-assertion recovery'
        DisableCreateRetries = $true; Confirm = $false
    } -ContractProperty ReleaseRecord
    $c = Read-JsonFile -Path $rollback.ReleaseRecord
    $Context.Created += , $c
    $smoke = Read-JsonFile -Path (Join-Path $Context.ReleaseDirectory "$($rollback.ReleaseId)-smoke.json")
    $evaluation = Read-JsonFile -Path (Join-Path $Context.ReleaseDirectory "$($rollback.ReleaseId)-evaluation.json")
    Assert-QualificationSmoke -Result $smoke
    Assert-QualificationEvaluation -Result $evaluation
    $a = Read-JsonFile -Path $Context.ARecordPath
    if ($Context.BEvidenceHashes.Count -ne 2) { throw 'QUAL_RECOVERY_FAILED' }
    foreach ($path in $Context.BEvidenceHashes.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -cne $Context.BEvidenceHashes[$path]) { throw 'QUAL_RECOVERY_FAILED' }
    }
    if ($rollback.Outcome -cne 'succeeded' -or $rollback.Operation -cne 'rollback' -or
        $c.deployment.operation -cne 'rollback' -or $c.deployment.outcome -cne 'succeeded' -or
        -not $c.deployment.attestation.gatesSatisfied -or $c.agent.version -cne '1.0.0' -or
        $c.packageId -cne $a.packageId -or
        (Get-FileHash -LiteralPath $rollback.PackagePath).Hash -cne $Context.AZipHash -or
        (Get-FileHash -LiteralPath $Context.BRecordPath).Hash -cne $Context.BRecordHash -or
        @($Context.Created.agent.serviceVersion | Select-Object -Unique).Count -ne 3 -or
        @($Context.Created.agent.serviceVersionId | Select-Object -Unique).Count -ne 3 -or
        @($Context.Created.agent.remoteAgentId | Select-Object -Unique).Count -ne 1) { throw 'QUAL_RECOVERY_FAILED' }
    $snapshot = Invoke-QualificationSdk -Context $Context -Operation qualification-snapshot
    if (-not $snapshot.found -or $snapshot.activeVersion -cne $c.agent.serviceVersion -or
        $snapshot.id -cne $c.agent.remoteAgentId -or $snapshot.versions.Count -ne 3 -or
        $snapshot.activeDefinition.model -cne $Context.Values.QUAL_MODEL_DEPLOYMENT -or
        @($snapshot.activeDefinition.tools).Count -ne 0 -or
        @($snapshot.versions | Where-Object { $_.id -cnotin $Context.Created.agent.serviceVersionId }).Count -ne 0) {
        throw 'QUAL_RECOVERY_FAILED'
    }
    $Context.RecoveryVerified = $true
    Write-QualificationJson -Path (Join-Path $Context.Root 'final-private-result.json') -Value @{
        sourceSha = $Context.ExpectedCommit; runId = $Context.RunId; records = $Context.Created
        snapshot = $snapshot; expectedBFailure = $true; recoveryVerified = $true
        versionsReserved = $Context.VersionsReserved; responsesReserved = $Context.ResponsesReserved
        aOriginalZipSha256 = $Context.AZipHash; bFailedRecordSha256 = $Context.BRecordHash
    }
}

function Invoke-QualificationExperimentWithRetention {
    param([hashtable]$Context)
    if (-not $Context.ContainsKey('InvocationCleanupVerified')) { $Context.InvocationCleanupVerified = $true }
    if (-not $Context.ContainsKey('PrimaryFailureCategory')) { $Context.PrimaryFailureCategory = $null }
    $failure = $null
    try { Invoke-QualificationExperiment -Context $Context }
    catch {
        $failure = $_
        $category = if ($_.Exception.Message -cin @('QUAL_INVOCATION_CLEANUP_FAILED','QUAL_INVOCATION_CLEANUP_UNVERIFIED')) {
            $Context.InvocationCleanupVerified = $false
            $_.Exception.Message
        } else { 'QUAL_EXPERIMENT_FAILED' }
        $Context.PrimaryFailureCategory = $category
        $Context.RecoveryVerified = $false
        $Context.CleanupVerified = $false
        try {
            Write-QualificationJson -Path (Join-Path $Context.Root 'experiment-failure.json') -Value @{
                status = 'failed'; category = $category; reservations = $Context.Reservations; noBudgetRefund = $true
                invocationCleanupVerified = $Context.InvocationCleanupVerified
            }
        } catch { $Context.FailureReceiptWritten = $false }
    }
    try { Complete-QualificationRetention -Context $Context }
    catch {
        try {
            Write-QualificationJson -Path (Join-Path $Context.Root 'finalization-failure.json') -Value @{
                status = 'failed'; category = 'QUAL_FINALIZATION_FAILED'
                primaryCategory = $Context.PrimaryFailureCategory
            }
        } catch { $Context.FailureReceiptWritten = $false }
        if (-not $failure) { $failure = $_ }
    }
    if ($failure) { throw $failure }
}

if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
    $exitCode = 2
    $status = 'blocked'
    $context = $null
    $publicSummary = $env:GITHUB_STEP_SUMMARY
    $oldOutput = $env:GITHUB_OUTPUT
    try {
        if ($env:GITHUB_ACTIONS -cne 'true') { throw 'QUAL_SOURCE_BLOCKED' }
        $repo = Split-Path -Parent $PSScriptRoot
        $head = (& git -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
        Assert-QualificationDispatch -Event $env:GITHUB_EVENT_NAME -Ref $env:GITHUB_REF -Attempt $env:GITHUB_RUN_ATTEMPT `
            -Sha $env:GITHUB_SHA -WorkflowSha $env:QUAL_WORKFLOW_SHA -Head $head -RunId $env:GITHUB_RUN_ID `
            -ExpectedCommit $ExpectedCommit -Phase $Phase -PrivacyProofRunId $PrivacyProofRunId -PreflightRunId $PreflightRunId
        & git -C $repo diff --quiet HEAD -- 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'QUAL_SOURCE_BLOCKED' }
        if (-not $PrivateRoot) { $PrivateRoot = Join-Path $repo "out/qualification/run-$($env:GITHUB_RUN_ID)-$Phase" }
        $root = Resolve-QualificationPrivateRoot -Repository $repo -Path $PrivateRoot
        if ($Phase -ne 'PrivacyProof') {
            Assert-QualificationAuthDirectory -Repository $repo -RunId $env:GITHUB_RUN_ID
        }
        if (Test-Path -LiteralPath $root) { throw 'QUAL_PATH_BLOCKED' }
        $null = New-Item -ItemType Directory -Path $root
        & git -C $repo check-ignore --quiet -- $root 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'QUAL_PATH_BLOCKED' }
        if (-not $IsWindows) { & chmod 700 $root; if ($LASTEXITCODE -ne 0) { throw 'QUAL_PATH_BLOCKED' } }
        $env:TEMP = $root; $env:TMP = $root; $env:TMPDIR = $root
        $env:FOUNDRY_QUALIFICATION_PRIVATE_ROOT = $root
        $env:GITHUB_STEP_SUMMARY = Join-Path $root 'private-summary.md'
        $env:GITHUB_OUTPUT = Join-Path $root 'private-output.txt'
        $context = @{
            Root = $root; Repository = $repo; ExpectedCommit = $ExpectedCommit; RunId = $env:GITHUB_RUN_ID
            PrivacyProofRunId = $PrivacyProofRunId; PreflightRunId = $PreflightRunId
            Reservations = @(); VersionsReserved = 0; ResponsesReserved = 0; Created = @()
            RetentionVerified = $false; CleanupVerified = $false; ExpectedBFailure = $false; RecoveryVerified = $false
            InvocationCleanupVerified = $true; AgentRemovalVerified = $false; PrimaryFailureCategory = $null
            EnteredExperiment = $false
        }
        Write-QualificationJson -Path (Join-Path $root 'dependency-provenance.json') -Value @{
            workflowSha256 = (Get-FileHash -LiteralPath (Join-Path $repo '.github/workflows/deploy-dev.yml')).Hash
            requirements = (Get-Content -LiteralPath (Join-Path $repo 'scripts/python/requirements.txt'))
            qualificationActions = @(
                'actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065'
            )
            azureCliVersion = if ($env:AZURE_TOKEN_CREDENTIALS -eq 'AzureCliCredential' -and $Phase -ne 'PrivacyProof') {
                (Invoke-QualificationNative -Context $context -Command az -Arguments @('version', '--output', 'json') | ConvertFrom-Json)
            } else { $null }
        }
        & {
            if ($Phase -eq 'PrivacyProof') {
                Invoke-QualificationPrivacyProof -Context $context
            } else {
                $values = [ordered]@{}
                foreach ($key in (Get-QualificationKeyPatterns).Keys) { $values[$key] = [Environment]::GetEnvironmentVariable($key) }
                Assert-QualificationValues -Values $values
                $context.Values = $values
                Assert-QualificationPreflight -Context $context
                if ($Phase -eq 'Experiment') {
                    Initialize-QualificationClaim -Context $context
                    $context.EnteredExperiment = $true
                    Invoke-QualificationExperimentWithRetention -Context $context
                }
            }
        } *> (Join-Path $root 'private-operation.log')
        $exitCode = 0
        $status = 'passed'
    } catch {
        if ($context -and $context.Root) {
            # Constant category only: exception bodies may contain credentials from external tools.
            Write-QualificationJson -Path (Join-Path $context.Root 'phase-failure.json') -Value @{ status = 'blocked-or-failed' }
        }
        $exitCode = if ($context -and $context.EnteredExperiment) { 1 } else { 2 }
        $status = if ($exitCode -eq 1) { 'failed' } else { 'blocked' }
    } finally {
        $env:GITHUB_STEP_SUMMARY = $publicSummary
        $env:GITHUB_OUTPUT = $oldOutput
    }
    try {
        $parameters = @{ Phase = $Phase; Status = $status; Commit = $ExpectedCommit }
        if ($context) {
            foreach ($key in @('VersionsReserved', 'ResponsesReserved', 'ExpectedBFailure', 'RecoveryVerified', 'RetentionVerified', 'CleanupVerified')) {
                $parameters[$key] = $context[$key]
            }
        }
        $public = ConvertTo-QualificationPublicResult @parameters | ConvertTo-Json -Compress
        if ($publicSummary) { [IO.File]::AppendAllText($publicSummary, "### DEV qualification phase only (authentication teardown pending for real phases)`n``````json`n$public`n```````n") }
        Write-Output $public
    } catch { Write-Output '{"status":"blocked","category":"QUAL_SUMMARY_BLOCKED"}'; $exitCode = 2 }
    exit $exitCode
}
