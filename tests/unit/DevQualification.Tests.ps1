#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:Repo 'scripts/Invoke-DevQualification.ps1')
    $script:Scratch = Join-Path $script:Repo 'out/qualification/driver-tests'
    $null = New-Item -ItemType Directory -Path $script:Scratch -Force
}

Describe 'Transient qualification authentication lifecycle' {
    BeforeEach {
        $script:AuthRun = [DateTime]::UtcNow.Ticks.ToString()
        $script:AuthPaths = Get-QualificationAuthPaths -Repository $script:Repo -RunId $script:AuthRun
        $script:AuthEnvFile = Join-Path $script:Scratch "auth-env-$script:AuthRun"
        $script:PriorConfig = $env:AZURE_CONFIG_DIR
        $script:PriorAuth = $env:QUAL_AUTH_DIRECTORY
    }

    AfterEach {
        $env:AZURE_CONFIG_DIR = $script:PriorConfig
        $env:QUAL_AUTH_DIRECTORY = $script:PriorAuth
    }

    It 'removes only its isolated credential directory after success, failed login or failed driver consumers' {
        foreach ($outcome in @('success','login-failure','driver-failure')) {
            $run = [DateTime]::UtcNow.Ticks.ToString()
            $paths = Get-QualificationAuthPaths -Repository $script:Repo -RunId $run
            Initialize-QualificationAuthDirectory -Repository $script:Repo -RunId $run -EnvironmentFile $script:AuthEnvFile
            Assert-QualificationAuthDirectory -Repository $script:Repo -RunId $run
            [IO.File]::WriteAllText((Join-Path $paths.Directory 'inert-fixture.json'), '{"assertion":"inert-not-a-token"}')
            $events = [System.Collections.Generic.List[string]]::new()
            try {
                $events.Add('last-consumer')
                if ($outcome -ne 'success') { throw 'inert primary failure' }
            } catch { $events.Add('primary-failed') }
            finally {
                (Clear-QualificationAuthDirectory -Repository $script:Repo -RunId $run).verified | Should -BeTrue
                $events.Add('auth-removed')
            }
            $events[0] | Should -Be 'last-consumer'
            $events[-1] | Should -Be 'auth-removed'
            Test-Path -LiteralPath $paths.Directory | Should -BeFalse
            Test-Path -LiteralPath $paths.Owner | Should -BeTrue
        }
        $workflow = Get-Content -LiteralPath (Join-Path $script:Repo '.github/workflows/deploy-dev.yml') -Raw
        $finalizer = $workflow.Substring($workflow.IndexOf("      - name: Remove only this job's transient CLI credentials"))
        $finalizer | Should -Match "always\(\) && inputs\.qualificationPhase != 'PrivacyProof'"
        $finalizer | Should -Match "QUAL_AUTH_CLEANUP_FAILED'; exit 1"
        $finalizer | Should -Not -Match 'az logout|qualification-login|Invoke-QualificationBlob|upload-artifact'
        $workflow.IndexOf('$receipt = Clear-QualificationAuthDirectory') |
            Should -BeGreaterThan $workflow.IndexOf('name: Execute only the selected bounded phase')
        (ConvertTo-QualificationPublicResult -Phase Experiment -Status passed -Commit ('a' * 40)).authenticationTeardown |
            Should -Be 'pending'
    }

    It 'refuses inherited, pre-existing, unowned and changed ownership paths without broad deletion' {
        (Clear-QualificationAuthDirectory -Repository $script:Repo -RunId $script:AuthRun).disposition |
            Should -Be 'not-created'
        $null = New-Item -ItemType Directory -Path $script:AuthPaths.Directory
        [IO.File]::WriteAllText((Join-Path $script:AuthPaths.Directory 'inert-keep'), 'owned-by-someone-else-fixture')
        { Initialize-QualificationAuthDirectory -Repository $script:Repo -RunId $script:AuthRun -EnvironmentFile $script:AuthEnvFile } |
            Should -Throw '*QUAL_AUTH_PATH_BLOCKED*'
        { Clear-QualificationAuthDirectory -Repository $script:Repo -RunId $script:AuthRun } |
            Should -Throw '*QUAL_AUTH_CLEANUP_FAILED*'
        Test-Path -LiteralPath (Join-Path $script:AuthPaths.Directory 'inert-keep') | Should -BeTrue
        $run = [DateTime]::UtcNow.Ticks.ToString()
        Initialize-QualificationAuthDirectory -Repository $script:Repo -RunId $run -EnvironmentFile $script:AuthEnvFile
        $paths = Get-QualificationAuthPaths -Repository $script:Repo -RunId $run
        $owner = [IO.File]::ReadAllText($paths.Owner) | ConvertFrom-Json -AsHashtable
        $owner.directory = $script:Scratch
        Write-QualificationJson -Path $paths.Owner -Value $owner
        { Clear-QualificationAuthDirectory -Repository $script:Repo -RunId $run } | Should -Throw '*QUAL_AUTH_CLEANUP_FAILED*'
        Test-Path -LiteralPath $paths.Directory | Should -BeTrue
    }

    It 'blocks symlink aliases and excludes the complete authentication subtree from evidence without reading caches' {
        $target = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $target
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $script:AuthPaths.Directory -Target $target
        try {
            { Clear-QualificationAuthDirectory -Repository $script:Repo -RunId $script:AuthRun } |
                Should -Throw '*QUAL_AUTH_CLEANUP_FAILED*'
            Test-Path -LiteralPath $target | Should -BeTrue
        } finally { Remove-Item -LiteralPath $script:AuthPaths.Directory -Force }
        Mock Invoke-QualificationBlob { throw 'must not upload credentials' }
        $context = @{ Root = $script:AuthPaths.Directory; Repository = $script:Repo; RetentionVerified = $false }
        { Export-QualificationEvidence -Context $context } | Should -Throw '*QUAL_PATH_BLOCKED*'
        $context.Root = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $context.Root
        $alias = Join-Path $context.Root 'credential-alias'
        $null = New-Item -ItemType $linkType -Path $alias -Target $target
        try { { Export-QualificationEvidence -Context $context } | Should -Throw '*QUAL_PATH_BLOCKED*' }
        finally { Remove-Item -LiteralPath $alias -Force }
        Should -Invoke Invoke-QualificationBlob -Times 0
    }

    It 'fails with a constant finalizer category when removal cannot be verified' {
        Initialize-QualificationAuthDirectory -Repository $script:Repo -RunId $script:AuthRun -EnvironmentFile $script:AuthEnvFile
        Mock Remove-Item { throw 'private-filesystem-error-canary' }
        { Clear-QualificationAuthDirectory -Repository $script:Repo -RunId $script:AuthRun } |
            Should -Throw -ExpectedMessage 'QUAL_AUTH_CLEANUP_FAILED'
        Test-Path -LiteralPath $script:AuthPaths.Directory | Should -BeTrue
    }
}

Describe 'Qualification invocation cleanup module guard' {
    BeforeAll {
        Import-Module (Join-Path $script:Repo 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force
    }
    BeforeEach {
        $script:PriorPrivate = $env:FOUNDRY_QUALIFICATION_PRIVATE_ROOT
        $script:GuardRoot = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $script:GuardRoot
        $env:FOUNDRY_QUALIFICATION_PRIVATE_ROOT = $script:GuardRoot
        $global:QualificationInvocation = [pscustomobject]@{
            Status = 'failed'; PrimaryStatus = 'failed'; Error = 'private-primary-error-canary'
            ResponseId = 'resp_inert'; ConversationId = 'conv_inert'; Output = $null
            InvocationCleanup = [pscustomobject]@{ verified = $false; resourcesClosed = $true
                conversationDisposition = 'failed'; failureCategories = @('conversation-delete-failed') }
        }
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps { $global:QualificationInvocation }
    }
    AfterEach { $env:FOUNDRY_QUALIFICATION_PRIVATE_ROOT = $script:PriorPrivate }

    It 'terminates before runners can continue and retains bounded primary and cleanup causes' {
        { Invoke-FoundryAgentRun -EnvironmentConfig @{} -LogicalName inert-agent -AgentVersion v1 -Prompt inert } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_FAILED*'
        $receipts = @(Get-ChildItem -LiteralPath $script:GuardRoot -Filter 'invocation-cleanup-*.json')
        $receipts.Count | Should -Be 1
        $receipt = Read-JsonFile $receipts[0].FullName
        $receipt.primaryStatus | Should -Be 'failed'
        $receipt.cleanupCategories | Should -Contain 'conversation-delete-failed'
        $receipt.ConversationId | Should -Be 'conv_inert'
        [IO.File]::ReadAllText($receipts[0].FullName) | Should -Not -Match 'private-primary-error-canary'
    }

    It 'fails closed for missing, malformed or contradictory envelopes and receipt-write failures' {
        $global:QualificationInvocation.PSObject.Properties.Remove('InvocationCleanup')
        { Invoke-FoundryAgentRun -EnvironmentConfig @{} -LogicalName inert-agent -AgentVersion v1 -Prompt inert } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_UNVERIFIED*'
        $global:QualificationInvocation | Add-Member InvocationCleanup @{ verified = 'true' }
        { Invoke-FoundryAgentRun -EnvironmentConfig @{} -LogicalName inert-agent -AgentVersion v1 -Prompt inert } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_UNVERIFIED*'
        $global:QualificationInvocation.InvocationCleanup = @{ verified = $true; resourcesClosed = $false
            conversationDisposition = 'deleted'; failureCategories = @() }
        { Invoke-FoundryAgentRun -EnvironmentConfig @{} -LogicalName inert-agent -AgentVersion v1 -Prompt inert } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_UNVERIFIED*'
        Mock Write-JsonFile -ModuleName FoundryAgentOps { throw 'private write failure' }
        { Invoke-FoundryAgentRun -EnvironmentConfig @{} -LogicalName inert-agent -AgentVersion v1 -Prompt inert } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_UNVERIFIED*'
    }

    It 'preserves a primary cleanup failure if evidence finalization also fails' {
        Mock Invoke-QualificationExperiment { throw 'QUAL_INVOCATION_CLEANUP_FAILED' }
        Mock Complete-QualificationRetention { throw 'secondary-private-finalization-error' }
        $context = @{ Root = $script:GuardRoot; Reservations = @('A'); PrimaryFailureCategory = $null }
        { Invoke-QualificationExperimentWithRetention -Context $context } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_FAILED*'
        $context.InvocationCleanupVerified | Should -BeFalse
        $context.RecoveryVerified | Should -BeFalse
        $failure = Read-JsonFile (Join-Path $script:GuardRoot 'finalization-failure.json')
        $failure.primaryCategory | Should -Be 'QUAL_INVOCATION_CLEANUP_FAILED'
        $failure.category | Should -Be 'QUAL_FINALIZATION_FAILED'
    }
}

Describe 'Real-script bounded qualification replay with transport-only substitutes' {
    BeforeAll {
        $probe = @'
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "tests" / "unit" / "python"))
import test_foundry_agent_cli as tests
print(json.dumps(tests.real_runtime_cleanup_probe()))
'@
        $raw = & python -c $probe $script:Repo
        if ($LASTEXITCODE -ne 0) { throw 'Offline real-SDK cleanup probe failed' }
        $script:RuntimeCases = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    }

    BeforeEach {
        $script:ReplayRoot = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $script:ReplayRoot
        $script:ReplayEnvironment = @{}
        foreach ($key in @('TEMP','TMP','FOUNDRY_QUALIFICATION_PRIVATE_ROOT','GITHUB_STEP_SUMMARY')) {
            $script:ReplayEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
        }
        $env:TEMP = $script:ReplayRoot; $env:TMP = $script:ReplayRoot
        $env:FOUNDRY_QUALIFICATION_PRIVATE_ROOT = $script:ReplayRoot
        $env:GITHUB_STEP_SUMMARY = Join-Path $script:ReplayRoot 'private-summary.md'
        $script:ReplayContext = @{
            Root = $script:ReplayRoot; Repository = $script:Repo
            Values = (New-QualificationSentinels -Seed 'persistent-offline-replay')
            ExpectedCommit = ('a' * 40); RunId = '123'; Claimed = $true
            Reservations = @(); VersionsReserved = 0; ResponsesReserved = 0; Created = @()
            RetentionVerified = $false; CleanupVerified = $false; RecoveryVerified = $false
            InvocationCleanupVerified = $true; AgentRemovalVerified = $false; PrimaryFailureCategory = $null
        }
        $script:ReplayContext.Values.QUAL_AGENT_NAME = 'qualification-readback-agent'
        # Package verification reloads the module; install boundary substitutes afterwards.
        Initialize-QualificationPackages -Context $script:ReplayContext *> (Join-Path $script:ReplayRoot 'preparation.log')
        Mock Initialize-QualificationPackages {}
        $global:QualificationReplay = @{
            Agent = $null; Versions = @(); Blobs = @{}; Sends = 0; FailureSend = 0; BadContent = $false
            Success = $script:RuntimeCases.success.result; Failure = $script:RuntimeCases.delete.result
        }
        Mock Invoke-QualificationNative { throw 'Unexpected native operation forbidden offline' }
        Mock Invoke-QualificationBlob {
            $key = "$([bool]$Package):$Name"
            if ($Operation -eq 'upload') {
                if ($CreateOnly -and $global:QualificationReplay.Blobs.ContainsKey($key)) { throw 'offline 412' }
                $global:QualificationReplay.Blobs[$key] = [IO.File]::ReadAllBytes($File)
            } elseif ($Operation -eq 'download') {
                [IO.File]::WriteAllBytes($File, $global:QualificationReplay.Blobs[$key])
            } else { throw 'Unexpected blob operation forbidden offline' }
        }
        Mock az -ModuleName FoundryAgentOps {
            $arguments = @($args)
            function Arg($name) { $i = [Array]::IndexOf($arguments, $name); if ($i -ge 0) { $arguments[$i + 1] } }
            if ($arguments[0] -ne 'storage' -or $arguments[1] -ne 'blob') { throw 'Unexpected CLI call forbidden offline' }
            $key = "$(Arg '--container-name'):$(Arg '--name')"; $file = Arg '--file'
            if ($arguments[2] -eq 'upload') {
                if ((Arg '--overwrite') -eq 'false' -and $global:QualificationReplay.Blobs.ContainsKey($key)) {
                    $global:LASTEXITCODE = 1; return 'BlobAlreadyExists'
                }
                $global:QualificationReplay.Blobs[$key] = [IO.File]::ReadAllBytes($file)
            } elseif ($arguments[2] -eq 'download') {
                if (-not $global:QualificationReplay.Blobs.ContainsKey($key)) {
                    $global:LASTEXITCODE = 1; return 'BlobNotFound'
                }
                [IO.File]::WriteAllBytes($file, $global:QualificationReplay.Blobs[$key])
            } else { throw 'Unexpected blob operation forbidden offline' }
            $global:LASTEXITCODE = 0; return '{}'
        }
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
            switch ($Subcommand) {
                preflight { return [pscustomobject]@{ ok = $true } }
                get-agent {
                    if ($global:QualificationReplay.Agent) { return $global:QualificationReplay.Agent }
                    return [pscustomobject]@{ found = $false }
                }
                create-version {
                    if (-not $DisableCreateRetries) { throw 'Missing create retry suppression' }
                    $n = $global:QualificationReplay.Versions.Count + 1
                    if ($n -gt 3) { throw 'Fourth creation forbidden offline' }
                    $global:QualificationReplay.Versions += , @{
                        id = "owned/version/$n"; version = "opaque$n"; metadata = $InputObject.metadata; payload = $InputObject
                    }
                    return [pscustomobject]@{ id = "owned/version/$n"; version = "opaque$n"; agentId = 'owned-agent' }
                }
                promote-version {
                    $v = @($global:QualificationReplay.Versions | Where-Object version -CEQ $AgentVersion)[0]
                    $global:QualificationReplay.Agent = [pscustomobject]@{
                        found = $true; id = 'owned-agent'; name = $LogicalName; latestVersion = $AgentVersion
                        activeVersion = $AgentVersion; versionId = $v.id; version = $AgentVersion
                        metadata = [pscustomobject]$v.metadata; model = $v.payload.model; tools = @()
                    }
                    return [pscustomobject]@{ ok = $true; activeVersion = $AgentVersion }
                }
                invoke-agent {
                    $global:QualificationReplay.Sends++
                    if ($global:QualificationReplay.Sends -gt 9) { throw 'Tenth send forbidden offline' }
                    if ($global:QualificationReplay.Sends -eq $global:QualificationReplay.FailureSend) {
                        return [pscustomobject]$global:QualificationReplay.Failure
                    }
                    $value = $global:QualificationReplay.Success | ConvertTo-Json -Depth 16 | ConvertFrom-Json
                    if ($global:QualificationReplay.BadContent -and $global:QualificationReplay.Sends -eq 4) {
                        $value.Output = 'system prompt'
                    }
                    return $value
                }
                default { throw 'Unexpected bridge operation forbidden offline' }
            }
        }
        Mock Invoke-QualificationSdk {
            if ($Operation -eq 'qualification-delete') {
                if (-not $Context.RetentionVerified) { throw 'Delete preceded evidence readback' }
                $global:QualificationReplay.Agent = $null
                return @{ absent = $true }
            }
            return @{
                found = ($null -ne $global:QualificationReplay.Agent); id = 'owned-agent'
                name = $Context.Values.QUAL_AGENT_NAME; activeVersion = $global:QualificationReplay.Agent.activeVersion
                activeDefinition = @{ model = $Context.Values.QUAL_MODEL_DEPLOYMENT; tools = @() }
                versions = @($global:QualificationReplay.Versions | ForEach-Object {
                    @{ id = $_.id; version = $_.version; metadata = $_.metadata }
                })
            }
        }
    }
    AfterEach {
        foreach ($key in $script:ReplayEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $script:ReplayEnvironment[$key])
        }
    }

    It 'retains a successful exactly three-create nine-send A/B/C experiment and original-byte cleanup' {
        $nested = Join-Path $script:ReplayRoot 'evidence-readback'
        $null = New-Item -ItemType Directory -Path $nested
        foreach ($name in @('inventory.json','readback.bin')) {
            [IO.File]::WriteAllText((Join-Path $nested $name), 'original nested evidence')
        }
        Invoke-QualificationExperimentWithRetention -Context $script:ReplayContext
        $global:QualificationReplay.Versions.Count | Should -Be 3
        $global:QualificationReplay.Sends | Should -Be 9
        $script:ReplayContext.RecoveryVerified | Should -BeTrue
        $script:ReplayContext.ExpectedBFailure | Should -BeTrue
        $script:ReplayContext.CleanupVerified | Should -BeTrue
        $script:ReplayContext.AgentRemovalVerified | Should -BeTrue
        $inventory = Read-JsonFile (Join-Path $script:ReplayRoot 'inventory-readback.json')
        foreach ($alias in @('A','B')) {
            $path = $script:ReplayContext.Packages[$alias].PackagePath
            $relative = [IO.Path]::GetRelativePath($script:ReplayRoot, $path).Replace('\','/')
            $entry = @($inventory.files | Where-Object file -CEQ $relative)
            $entry.Count | Should -Be 1
            $entry[0].sha256 | Should -BeExactly $script:ReplayContext.PackageArchiveHashes[$alias]
            $entry[0].sha256 | Should -BeExactly (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $stored = $global:QualificationReplay.Blobs["True:$($entry[0].blob)"]
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stored)) |
                Should -BeExactly $entry[0].sha256
        }
        foreach ($name in @('inventory.json','readback.bin')) {
            @($inventory.files | Where-Object file -CEQ "evidence-readback/$name").Count | Should -Be 1
        }
    }

    It 'blocks deletion during failure finalization when mandatory original retention has <Defect>' -TestCases @(
        @{ Defect = 'missing-file' }, @{ Defect = 'changed-original' }, @{ Defect = 'omitted-file' },
        @{ Defect = 'omitted-entry' }, @{ Defect = 'wrong-entry-hash' }, @{ Defect = 'empty-inventory' }
    ) {
        param($Defect)
        $global:QualificationReplay.FailureSend = 1
        $bPath = $script:ReplayContext.Packages.B.PackagePath
        switch ($Defect) {
            missing-file { Remove-Item -LiteralPath $bPath -Force }
            changed-original { [IO.File]::AppendAllText($bPath, 'inert archive corruption') }
            omitted-file {
                Mock Get-ChildItem {
                    Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Recurse -File |
                        Where-Object { $_.FullName -cne $script:ReplayContext.Packages.B.PackagePath }
                } -ParameterFilter { $LiteralPath -ceq $script:ReplayRoot -and $Recurse -and $File }
            }
            default {
                $script:InventoryDefect = $Defect
                Mock Write-QualificationJson {
                    if ($Path -ceq (Join-Path $script:ReplayRoot 'inventory.json')) {
                        $relativeB = [IO.Path]::GetRelativePath($script:ReplayRoot,
                            $script:ReplayContext.Packages.B.PackagePath).Replace('\','/')
                        if ($script:InventoryDefect -eq 'empty-inventory') { $Value.files = @() }
                        elseif ($script:InventoryDefect -eq 'omitted-entry') {
                            $Value.files = @($Value.files | Where-Object file -CNE $relativeB)
                        } else {
                            ($Value.files | Where-Object file -CEQ $relativeB).sha256 = '0' * 64
                        }
                    }
                    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
                }
            }
        }
        { Invoke-QualificationExperimentWithRetention -Context $script:ReplayContext } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_FAILED*'
        $global:QualificationReplay.Versions.Count | Should -Be 1
        $global:QualificationReplay.Sends | Should -Be 1
        $script:ReplayContext.ResponsesReserved | Should -Be 3
        $script:ReplayContext.RetentionVerified | Should -BeFalse
        $script:ReplayContext.AgentRemovalVerified | Should -BeFalse
        $script:ReplayContext.CleanupVerified | Should -BeFalse
        $global:QualificationReplay.Agent | Should -Not -BeNullOrEmpty
        Should -Invoke Invoke-QualificationSdk -Times 0 -ParameterFilter { $Operation -eq 'qualification-delete' }
        (Read-JsonFile (Join-Path $script:ReplayRoot 'finalization-failure.json')).category |
            Should -Be 'QUAL_FINALIZATION_FAILED'
    }

    It 'stops <Phase> cleanup failure before another inference and never reports recovery or generic cleanup success' -TestCases @(
        @{ Phase = 'A'; Send = 1; Versions = 1; Reserved = 3; Removed = $true }
        @{ Phase = 'B'; Send = 4; Versions = 2; Reserved = 6; Removed = $true }
        @{ Phase = 'C'; Send = 7; Versions = 3; Reserved = 9; Removed = $false }
    ) {
        param($Phase, $Send, $Versions, $Reserved, $Removed)
        $global:QualificationReplay.FailureSend = $Send
        { Invoke-QualificationExperimentWithRetention -Context $script:ReplayContext } |
            Should -Throw '*QUAL_INVOCATION_CLEANUP_FAILED*'
        $global:QualificationReplay.Sends | Should -Be $Send
        $global:QualificationReplay.Versions.Count | Should -Be $Versions
        $script:ReplayContext.ResponsesReserved | Should -Be $Reserved
        $script:ReplayContext.InvocationCleanupVerified | Should -BeFalse
        $script:ReplayContext.RecoveryVerified | Should -BeFalse
        $script:ReplayContext.CleanupVerified | Should -BeFalse
        $script:ReplayContext.RetentionVerified | Should -BeTrue
        $script:ReplayContext.AgentRemovalVerified | Should -Be $Removed
        @(Get-ChildItem -LiteralPath $script:ReplayRoot -Filter 'invocation-cleanup-*.json').Count | Should -Be 1
        if ($Phase -eq 'C') {
            $c = @(Get-ChildItem -LiteralPath $script:ReplayContext.ReleaseDirectory -File -Filter '*.json' | Where-Object {
                $record = Read-JsonFile $_.FullName
                $record.Contains('deployment') -and $record.deployment.operation -eq 'rollback'
            })
            $c.Count | Should -Be 1
            (Read-JsonFile $c[0].FullName).deployment.outcome | Should -Be 'failed'
        }
    }

    It 'does not reinterpret unrelated B content failure as the expected configuration-only failure' {
        $global:QualificationReplay.BadContent = $true
        { Invoke-QualificationExperimentWithRetention -Context $script:ReplayContext } | Should -Throw '*QUAL_GATE_FAILED*'
        $global:QualificationReplay.Versions.Count | Should -Be 2
        $global:QualificationReplay.Sends | Should -Be 5
        $script:ReplayContext.RecoveryVerified | Should -BeFalse
    }
}

Describe 'DEV qualification safety boundaries' {
    BeforeEach {
        $script:Dispatch = @{
            Event = 'workflow_dispatch'; Ref = 'refs/heads/squad/sdk-first-qualification'
            Attempt = '1'; Sha = ('a' * 40); WorkflowSha = ('a' * 40); Head = ('a' * 40)
            RunId = '123'; ExpectedCommit = ('a' * 40); Phase = 'Experiment'
            PrivacyProofRunId = '121'; PreflightRunId = '122'
        }
    }

    It 'blocks wrong source, retries and invalid proof references before target access' {
        foreach ($change in @(
            @{ Ref = 'refs/heads/main' }, @{ Sha = ('b' * 40) }, @{ WorkflowSha = ('b' * 40) },
            @{ Head = ('b' * 40) }, @{ Attempt = '2' }, @{ Event = 'push' },
            @{ ExpectedCommit = 'short' }, @{ Phase = 'other' },
            @{ PrivacyProofRunId = '' }, @{ PreflightRunId = '123' }, @{ PreflightRunId = '121' }
        )) {
            $candidate = $script:Dispatch.Clone()
            foreach ($key in $change.Keys) { $candidate[$key] = $change[$key] }
            { Assert-QualificationDispatch @candidate } | Should -Throw '*QUAL_SOURCE_BLOCKED*'
        }
        { Assert-QualificationDispatch @script:Dispatch } | Should -Not -Throw
    }

    It 'validates the complete key set before emitting masks or exports' {
        $values = New-QualificationSentinels -Seed 'inert-test-seed'
        $values.Count | Should -Be 13
        $values.Values | Where-Object { $_ -like '*inert-test-seed*' } | Should -BeNullOrEmpty
        $values['QUAL_AGENT_NAME'] = "private-canary`n::error::leak"
        { Initialize-QualificationEnvironment -Values $values -EnvironmentFile (Join-Path $script:Scratch 'env') } |
            Should -Throw '*QUAL_CONFIG_BLOCKED*'
        $values.Remove('QUAL_AGENT_NAME')
        { Initialize-QualificationEnvironment -Values $values -EnvironmentFile (Join-Path $script:Scratch 'env') } |
            Should -Throw '*QUAL_CONFIG_BLOCKED*'
    }

    It 'registers all identifier masks before the first environment-file write' {
        $script:Events = [System.Collections.Generic.List[string]]::new()
        Mock Write-QualificationMask { $script:Events.Add('mask') }
        Mock Add-Content { $script:Events.Add('export') }
        Initialize-QualificationEnvironment -Values (New-QualificationSentinels -Seed 'other-inert-seed') `
            -EnvironmentFile (Join-Path $script:Scratch 'env')
        $firstExport = $script:Events.IndexOf('export')
        $firstExport | Should -BeGreaterThan 13
        @($script:Events | Select-Object -Skip $firstExport | Where-Object { $_ -eq 'mask' }).Count | Should -Be 0
    }

    It 'refuses a second claim and blocks a phase if its durable reservation fails' {
        $script:Writes = [System.Collections.Generic.HashSet[string]]::new()
        Mock Invoke-QualificationBlob {
            if (-not $script:Writes.Add($Name)) { throw 'collision' }
        }
        $context = @{ Root = $script:Scratch; Values = (New-QualificationSentinels -Seed 'claim-seed')
            ExpectedCommit = ('a' * 40); RunId = '123'; PrivacyProofRunId = '121'; PreflightRunId = '122'
            Reservations = @(); VersionsReserved = 0; ResponsesReserved = 0 }
        Initialize-QualificationClaim -Context $context
        { Initialize-QualificationClaim -Context $context } | Should -Throw
        Reserve-QualificationPhase -Context $context -Alias A
        { Reserve-QualificationPhase -Context $context -Alias A } | Should -Throw
        $context.VersionsReserved | Should -Be 1
        $context.ResponsesReserved | Should -Be 3
        Mock Invoke-QualificationBlob { throw 'persistence failed' }
        { Reserve-QualificationPhase -Context $context -Alias B } | Should -Throw
        $context.VersionsReserved | Should -Be 1
    }

    It 'uses conditional OAuth writes without credentials and suppresses transfer progress' {
        $context = @{ Root = $script:Scratch; Values = (New-QualificationSentinels -Seed 'atomic-write-boundary') }
        Mock Invoke-QualificationNative { '{}' }
        Invoke-QualificationBlob -Context $context -Operation upload -Name 'private-claim' `
            -File (Join-Path $script:Scratch 'claim.json') -CreateOnly
        Should -Invoke Invoke-QualificationNative -Times 1 -ParameterFilter {
            $Command -eq 'az' -and $Arguments -contains '--if-none-match' -and $Arguments -contains '*' -and
            $Arguments -contains '--auth-mode' -and $Arguments -contains 'login' -and
            $Arguments -contains '--no-progress' -and
            $Arguments -notcontains '--account-key' -and $Arguments -notcontains '--sas-token'
        }
    }

    It 'accepts only the model-expectation failure with two completed live canaries' {
        $smoke = @{ mode = 'live'; failed = 1; skipped = 0; liveExecuted = 2; checks = @(
            @{ Name = 'Model deployment matches overlay'; Result = 'failed'; Live = $false },
            @{ Name = 'Agent exists'; Result = 'passed'; Live = $false },
            @{ Name = 'Canary: responds'; Result = 'passed'; Live = $true; Status = 'completed'; ResponseId = 'r1'; ConversationId = 'c1' },
            @{ Name = 'Canary: refuses-configuration-disclosure'; Result = 'passed'; Live = $true; Status = 'completed'; ResponseId = 'r2'; ConversationId = 'c2' }
        ) }
        { Assert-QualificationSmoke -Result $smoke -ExpectedFailure } | Should -Not -Throw
        $smoke.checks[2].Result = 'failed'
        { Assert-QualificationSmoke -Result $smoke -ExpectedFailure } | Should -Throw
        $smoke.checks[2].Result = 'passed'
        $smoke.checks[0].Name = 'Agent exists'
        { Assert-QualificationSmoke -Result $smoke -ExpectedFailure } | Should -Throw
        $errors = @{
            AgentName = 'offline-agent'; ReleaseId = 'offline-release'
            SmokeMessage = "Smoke test failed for 'offline-agent' in 'dev' (1 check(s)). Consider rolling back with scripts/Invoke-Rollback.ps1."
            AttestationMessage = "Release offline-release failed its required gates in 'dev': Gate 'smoke' is required in 'dev' and reported 'failed'."
        }
        { Assert-QualificationExpectedErrors @errors } | Should -Not -Throw
        $errors.AttestationMessage = 'Blob persistence failed after local failed JSON was written'
        { Assert-QualificationExpectedErrors @errors } | Should -Throw '*QUAL_GATE_FAILED*'
    }

    It 'does not delete on failed readback or unknown inventory' {
        Write-QualificationJson -Path (Join-Path $script:Scratch 'original.json') -Value @{ original = 'private-canary' }
        Mock Invoke-QualificationBlob {
            if ($Operation -eq 'download') { throw 'readback failure' }
        }
        Mock Invoke-QualificationSdk { throw 'must not delete' }
        $context = @{ Root = $script:Scratch; Values = (New-QualificationSentinels -Seed 'export-seed')
            RetentionVerified = $false; Created = @() }
        { Complete-QualificationRetention -Context $context } | Should -Throw
        { Remove-QualificationAgent -Context $context } | Should -Throw
        Should -Invoke Invoke-QualificationSdk -Times 0
        Should -Invoke Invoke-QualificationBlob -Times 1 -ParameterFilter { $Operation -eq 'download' }
        $context.RetentionVerified = $true
        $context.Created = @(@{ agent = @{ remoteAgentId = 'owned'; serviceVersionId = 'v1-id'; serviceVersion = 'v1' } })
        Mock Invoke-QualificationSdk {
            return @{ found = $true; id = 'owned'; name = $context.Values.QUAL_AGENT_NAME
                activeVersion = 'v1'; versions = @(@{ id = 'unknown'; version = 'v2'; metadata = @{} }) }
        }
        { Remove-QualificationAgent -Context $context } | Should -Throw
        Should -Invoke Invoke-QualificationSdk -Times 0 -ParameterFilter { $Operation -eq 'qualification-delete' }
    }

    It 'rejects private paths and public-summary canaries instead of redacting arbitrary objects' {
        { Resolve-QualificationPrivateRoot -Repository $script:Repo -Path (Join-Path $script:Repo 'docs') } | Should -Throw
        { ConvertTo-QualificationPublicResult -Phase Experiment -Status 'private-canary' -Commit ('a' * 40) } | Should -Throw
        $result = ConvertTo-QualificationPublicResult -Phase PrivacyProof -Status passed -Commit ('a' * 40)
        $result | ConvertTo-Json -Compress | Should -Not -Match 'QUAL_|https://|private-canary'
    }

    It 'verifies original readback bytes before deleting the exact owned resource and retaining its receipt' {
        $root = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $root
        $context = @{ Root = $root; Values = (New-QualificationSentinels -Seed 'owned-retention-cleanup')
            RetentionVerified = $false; CleanupVerified = $false
            Created = @(@{ agent = @{ remoteAgentId = 'owned'; serviceVersion = 'owned-v1'; serviceVersionId = 'owned-v1-id' } }) }
        Write-QualificationJson -Path (Join-Path $root 'original.json') -Value @{ original = 'unaltered-canary-bytes' }
        $archive = Join-Path $root 'original-readback-A.zip'
        [IO.File]::WriteAllText($archive, 'unaltered inert archive bytes')
        $context.Packages = @{ A = [pscustomobject]@{ PackagePath = $archive } }
        $context.PackageArchiveHashes = @{ A = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash }
        $script:BlobBytes = @{}
        Mock Invoke-QualificationBlob {
            if ($Operation -eq 'upload') { $script:BlobBytes[$Name] = [IO.File]::ReadAllBytes($File) }
            if ($Operation -eq 'download') { [IO.File]::WriteAllBytes($File, $script:BlobBytes[$Name]) }
        }
        Mock Invoke-QualificationSdk {
            if ($Operation -eq 'qualification-delete') {
                if (-not $Context.RetentionVerified) { throw 'deletion preceded retention' }
                return @{ absent = $true }
            }
            return @{ found = $true; id = 'owned'; name = $Context.Values.QUAL_AGENT_NAME; activeVersion = 'owned-v1'
                versions = @(@{ id = 'owned-v1-id'; version = 'owned-v1'
                    metadata = @{ qualification_experiment = $Context.Values.QUAL_EXPERIMENT_ID } }) }
        }
        Complete-QualificationRetention -Context $context
        $context.RetentionVerified | Should -BeTrue
        $context.CleanupVerified | Should -BeTrue
        Should -Invoke Invoke-QualificationSdk -Times 1 -ParameterFilter { $Operation -eq 'qualification-delete' }
        $receiptName = "$($context.Values.QUAL_EXPERIMENT_ID)/evidence/cleanup-receipt.json"
        $script:BlobBytes.ContainsKey($receiptName) | Should -BeTrue
    }

    It 'blocks wrong real identity, model uncertainty and collisions without creating a claim' {
        $values = New-QualificationSentinels -Seed 'read-only-preflight'
        $context = @{ Root = $script:Scratch; Values = $values }
        $old = $env:AZURE_TOKEN_CREDENTIALS
        try {
            $env:AZURE_TOKEN_CREDENTIALS = 'AzureCliCredential'
            Mock Invoke-QualificationNative { '{"tenantId":"wrong","id":"wrong","user":{"type":"servicePrincipal","name":"wrong"}}' }
            Mock Invoke-QualificationSdk { throw 'must not reach target with wrong identity' }
            { Assert-QualificationPreflight -Context $context } | Should -Throw '*QUAL_IDENTITY_BLOCKED*'
            Should -Invoke Invoke-QualificationSdk -Times 0
            Mock Invoke-QualificationNative {
                @{ tenantId = $values.AZURE_TENANT_ID; id = $values.AZURE_SUBSCRIPTION_ID
                    user = @{ type = 'servicePrincipal'; name = $values.AZURE_CLIENT_ID } } | ConvertTo-Json -Compress
            }
            Mock Invoke-QualificationSdk { @{ found = $false; modelMatched = $false } }
            { Assert-QualificationPreflight -Context $context } | Should -Throw '*QUAL_TARGET_BLOCKED*'
            Mock Invoke-QualificationSdk { @{ found = $true; modelMatched = $true } }
            { Assert-QualificationPreflight -Context $context } | Should -Throw '*QUAL_TARGET_BLOCKED*'
            Should -Invoke Invoke-QualificationNative -Times 0 -ParameterFilter { $Arguments -contains 'storage' }
        } finally { $env:AZURE_TOKEN_CREDENTIALS = $old }
    }

    It 'prepares both real DEV packages privately without changing tracked samples or using Azure' {
        $root = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $root
        $context = @{ Root = $root; Repository = $script:Repo
            Values = (New-QualificationSentinels -Seed 'package-preparation'); ExpectedCommit = ('a' * 40) }
        Mock Invoke-QualificationNative { throw 'no Azure in package preparation' }
        Mock Invoke-QualificationSdk { throw 'no Azure in package preparation' }
        $source = Join-Path $script:Repo 'samples/simple-agent/agent.manifest.json'
        $before = (Get-FileHash -LiteralPath $source).Hash
        $oldTemp = $env:TEMP; $oldTmp = $env:TMP; $oldSummary = $env:GITHUB_STEP_SUMMARY
        try {
            $env:TEMP = $root; $env:TMP = $root
            $env:GITHUB_STEP_SUMMARY = Join-Path $root 'private-summary.md'
            Initialize-QualificationPackages -Context $context *> (Join-Path $root 'preparation.log')
        } finally { $env:TEMP = $oldTemp; $env:TMP = $oldTmp; $env:GITHUB_STEP_SUMMARY = $oldSummary }
        $context.Packages.A.Version | Should -Be '1.0.0'
        $context.Packages.B.Version | Should -Be '1.0.1'
        $context.Packages.A.PackageId | Should -Not -Be $context.Packages.B.PackageId
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $before
        Should -Invoke Invoke-QualificationSdk -Times 0
        Should -Invoke Invoke-QualificationNative -Times 0
    }

    It 'persists C before one exact-context central rollback and never recovers an unrelated B failure' {
        $root = Join-Path $script:Scratch ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $root
        $values = New-QualificationSentinels -Seed 'exact-rollback-routing'
        $aPath = Join-Path $root 'A.json'; $bPath = Join-Path $root 'B.json'; $cPath = Join-Path $root 'C.json'
        $zip = Join-Path $root 'original-A.zip'
        [IO.File]::WriteAllText($zip, 'offline original archive bytes')
        $records = @()
        foreach ($alias in @('A','B','C')) {
            $record = @{ agent = @{ version = '1.0.0'; serviceVersion = "v$alias"
                    serviceVersionId = "id$alias"; remoteAgentId = 'owned-agent' }
                releaseId = $alias; packageId = 'same-A-package'
                deployment = @{ operation = 'rollback'; outcome = 'succeeded'; attestation = @{ gatesSatisfied = $true } }
                previous = @{ rollbackArtifactPath = $zip } }
            if ($alias -eq 'B') { $record.deployment.outcome = 'failed'; $record.agent.version = '1.0.1' }
            Write-QualificationJson -Path (Join-Path $root "$alias.json") -Value $record
            $records += ,$record
        }
        $smoke = @{ mode = 'live'; failed = 0; skipped = 0; liveExecuted = 2; checks = @(
            @{ Result = 'passed'; Live = $true; Status = 'completed'; ResponseId = 'r1'; ConversationId = 'c1' },
            @{ Result = 'passed'; Live = $true; Status = 'completed'; ResponseId = 'r2'; ConversationId = 'c2' }
        ) }
        $evaluation = @{ mode = 'live'; liveExecuted = 1; total = 1; failed = 0; thresholdsMet = $true
            records = @(@{ Passed = $true; Status = 'completed'; ResponseId = 'r3'; ConversationId = 'c3'
                Checks = @(@{ Result = 'passed' }) }) }
        Write-QualificationJson -Path (Join-Path $root 'C-smoke.json') -Value $smoke
        Write-QualificationJson -Path (Join-Path $root 'C-evaluation.json') -Value $evaluation
        $bSmoke = Join-Path $root 'B-smoke.json'; $bEvaluation = Join-Path $root 'B-evaluation.json'
        Write-QualificationJson -Path $bSmoke -Value @{ original = 'B smoke bytes' }
        Write-QualificationJson -Path $bEvaluation -Value @{ original = 'B evaluation bytes' }
        $context = @{ Root = $root; Values = $values; ExpectedCommit = ('a' * 40); RunId = '123'; Claimed = $true
            ConfigRoot = (Join-Path $root 'config'); SuitePath = (Join-Path $root 'suite.json'); ReleaseDirectory = $root
            ARecordPath = $aPath; BRecordPath = $bPath; BRecordHash = (Get-FileHash $bPath).Hash
            AZipHash = (Get-FileHash $zip).Hash; Created = @($records[0], $records[1])
            BEvidenceHashes = @{ $bSmoke = (Get-FileHash $bSmoke).Hash; $bEvaluation = (Get-FileHash $bEvaluation).Hash }
            VersionsReserved = 2; ResponsesReserved = 6; Reservations = @('A','B') }
        $script:RecoveryEvents = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-QualificationPackages {}
        Mock Invoke-QualificationRelease {}
        Mock Stage-QualificationKnownGood {}
        Mock Invoke-QualificationBlob { $script:RecoveryEvents.Add('reservation') }
        Mock Invoke-QualificationScript {
            $script:RecoveryEvents.Add('rollback')
            return [pscustomobject]@{ ReleaseRecord = $cPath; ReleaseId = 'C'; Outcome = 'succeeded'
                Operation = 'rollback'; PackagePath = $zip }
        }
        Mock Invoke-QualificationSdk {
            @{ found = $true; activeVersion = 'vC'; id = 'owned-agent'
                activeDefinition = @{ model = $values.QUAL_MODEL_DEPLOYMENT; tools = @() }
                versions = @(@{id='idA'}, @{id='idB'}, @{id='idC'}) }
        }
        Invoke-QualificationExperiment -Context $context
        $context.RecoveryVerified | Should -BeTrue
        $context.ResponsesReserved | Should -Be 9
        ($script:RecoveryEvents -join ',') | Should -Be 'reservation,rollback'
        Should -Invoke Invoke-QualificationScript -Times 1 -ParameterFilter {
            $Path -eq 'scripts/Invoke-Rollback.ps1' -and
            $Parameters.ReleaseRecordPath -eq $bPath -and $Parameters.ArtifactDirectory -eq $root -and
            $Parameters.ConfigRoot -eq $context.ConfigRoot -and $Parameters.EvaluationSuitePath -eq $context.SuitePath -and
            $Parameters.DisableCreateRetries -eq $true -and -not $Parameters.ContainsKey('RollbackOnFailure')
        }
        (Get-FileHash $bPath).Hash | Should -Be $context.BRecordHash
        $script:RecoveryEvents.Clear()
        Mock Invoke-QualificationRelease { if ($Alias -eq 'B') { throw 'unrelated runtime failure' } }
        { Invoke-QualificationExperiment -Context $context } | Should -Throw '*unrelated runtime failure*'
        $script:RecoveryEvents.Count | Should -Be 0
    }
}
