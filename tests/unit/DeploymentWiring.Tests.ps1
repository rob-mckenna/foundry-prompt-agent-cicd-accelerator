#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Focused offline wiring tests for the Foundry SDK bridge and deployment workflows.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

    $script:ScratchRoot = Join-Path $script:RepoRoot 'out/reviewer-offline-tests'
    if (Test-Path -LiteralPath $script:ScratchRoot) {
        Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force
    }

    $null = New-Item -ItemType Directory -Path $script:ScratchRoot -Force
    $script:PackageOutput = Join-Path $script:ScratchRoot 'package'
    $script:ReleaseDirectory = Join-Path $script:ScratchRoot 'releases'
    $script:ConfigRoot = Join-Path $script:ScratchRoot 'config'
    $null = New-Item -ItemType Directory -Path $script:PackageOutput -Force
    $null = New-Item -ItemType Directory -Path $script:ReleaseDirectory -Force
    $null = New-Item -ItemType Directory -Path $script:ConfigRoot -Force

    $script:OriginalAzureTenantId = [Environment]::GetEnvironmentVariable('AZURE_TENANT_ID')
    $script:OriginalAzureSubscriptionId = [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID')
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', '00000000-0000-0000-0000-000000000000')
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', '11111111-1111-1111-1111-111111111111')

    foreach ($environmentName in @('dev', 'test', 'prod')) {
        $config = Read-JsonFile -Path (Join-Path $script:RepoRoot "config/environments/$environmentName.json")
        $config['azure']['tenantId'] = '00000000-0000-0000-0000-000000000000'
        $config['azure']['subscriptionId'] = '11111111-1111-1111-1111-111111111111'
        $config.Remove('releaseStore')
        Write-JsonFile -InputObject $config -Path (Join-Path $script:ConfigRoot "$environmentName.json") -Depth 16 -Confirm:$false | Out-Null
    }

    $sourceRoot = Join-Path $script:RepoRoot 'samples/simple-agent'
    $sourceLayout = Get-AgentSourceLayout -Path $sourceRoot
    $sourceManifest = Read-JsonFile -Path $sourceLayout.ManifestPath
    $script:FixtureAgentName = $sourceManifest['name']
    $packageRoot = Join-Path $script:PackageOutput 'simple-support-agent-fixture.package'
    if (Test-Path -LiteralPath $packageRoot) {
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }

    $null = New-Item -ItemType Directory -Path (Join-Path $packageRoot 'manifest') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $packageRoot 'environments') -Force

    $sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object {
        (Get-NormalizedRelativePath -Root $sourceRoot -Path $_.FullName) -notlike 'environments/*'
    }

    $toolEntries = @()
    $evaluationEntries = @()
    foreach ($file in $sourceFiles) {
        $relative = Get-NormalizedRelativePath -Root $sourceRoot -Path $file.FullName
        $destination = Join-Path (Join-Path $packageRoot 'manifest') $relative
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            $null = New-Item -ItemType Directory -Path $destinationDirectory -Force
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force

        if ($relative -like 'tools/*') { $toolEntries += "manifest/$relative" }
        if ($relative -like 'evaluations/*') { $evaluationEntries += "manifest/$relative" }
    }

    foreach ($environmentName in @('dev', 'test', 'prod')) {
        Copy-Item `
            -LiteralPath (Join-Path $sourceLayout.EnvironmentRoot "$environmentName.overlay.json") `
            -Destination (Join-Path $packageRoot "environments/$environmentName.overlay.json") `
            -Force
    }

    $script:FixturePackageDescriptor = [ordered]@{
        '$schema'     = 'https://github.com/foundry-prompt-agent-cicd-accelerator/schemas/package-descriptor.schema.json'
        schemaVersion = '1.0.0'
        packageFormat = 'foundry-agent-package/1'
        packageId     = ''
        agent         = [ordered]@{
            name          = $sourceManifest['name']
            version       = $sourceManifest['version']
            displayName   = $sourceManifest['displayName']
            owner         = (ConvertTo-OrderedHashtable -InputObject $sourceManifest['owner'])
            classification = (ConvertTo-OrderedHashtable -InputObject $sourceManifest['classification'])
        }
        build         = [ordered]@{
            createdUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            sourceCommit = ('a' * 40)
            sourceRef    = 'refs/heads/main'
            sourceRepository = 'local/test'
            buildRunId   = '0'
            builder      = 'local'
            toolVersion  = '1.0.0'
        }
        contents      = [ordered]@{
            manifest     = 'manifest/agent.manifest.json'
            instructions = "manifest/$($sourceManifest['instructions']['file'])"
            environments = @('dev', 'test', 'prod')
            tools        = @($toolEntries | Sort-Object)
            evaluations  = @($evaluationEntries | Sort-Object)
        }
        checksumFile  = 'checksums.sha256'
        fileCount     = (Get-ChildItem -LiteralPath $packageRoot -Recurse -File).Count + 1
    }

    Write-JsonFile -InputObject $script:FixturePackageDescriptor -Path (Join-Path $packageRoot 'package.json') -Depth 16 -Confirm:$false | Out-Null
    $contentManifest = New-ChecksumManifest -Root $packageRoot -ExcludeRelativePath @('package.json') `
        -PackageFormat $script:FixturePackageDescriptor['packageFormat']
    $descriptorForHash = Read-JsonFile -Path (Join-Path $packageRoot 'package.json')
    $script:FixturePackageDescriptor['packageId'] = Get-PackageId -ChecksumManifest $contentManifest -Descriptor $descriptorForHash
    $descriptorForHash['packageId'] = $script:FixturePackageDescriptor['packageId']
    $script:FixturePackageDescriptor = $descriptorForHash
    Write-JsonFile -InputObject $script:FixturePackageDescriptor -Path (Join-Path $packageRoot 'package.json') -Depth 16 -Confirm:$false | Out-Null

    $fullManifest = New-ChecksumManifest -Root $packageRoot -PackageFormat $script:FixturePackageDescriptor['packageFormat']
    [System.IO.File]::WriteAllText(
        (Join-Path $packageRoot 'checksums.sha256'),
        $fullManifest,
        [System.Text.UTF8Encoding]::new($false)
    )

    $script:FixturePackagePath = Join-Path $script:PackageOutput 'simple-support-agent-fixture.zip'
    if (Test-Path -LiteralPath $script:FixturePackagePath) {
        Remove-Item -LiteralPath $script:FixturePackagePath -Force
    }
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $script:FixturePackagePath -CompressionLevel Optimal

    $verification = Test-ChecksumManifest -Root $packageRoot
    if (-not $verification.IsValid -or $verification.ContentId -ne $script:FixturePackageDescriptor['packageId']) {
        throw "Failed to create the offline package fixture. Expected '$($script:FixturePackageDescriptor['packageId'])' but computed '$($verification.ContentId)'."
    }

    $descriptorCheck = Test-JsonFileSchema -Path (Join-Path $packageRoot 'package.json') -SchemaPath (Join-Path $script:RepoRoot 'schemas/package-descriptor.schema.json')
    if (-not $descriptorCheck.IsValid) {
        throw "Offline package fixture descriptor is invalid: $($descriptorCheck.Errors -join '; ')"
    }

    $sourceRecord = New-ReleaseRecord `
        -Environment dev `
        -PackageDescriptor $script:FixturePackageDescriptor `
        -Operation deploy `
        -Outcome succeeded `
        -RemoteAgentId 'asst_dev_source' `
        -GateResults @{ validation = 'passed'; smoke = 'passed' }
    $sourceRecord['deployment']['attestation'] = [ordered]@{
        gatesSatisfied = $true
        attestedAtUtc  = '2026-10-01T20:00:00Z'
        attestedBy     = 'local:tester'
        requiredGates  = [ordered]@{
            requireEvaluationPass  = $false
            requireSmokeTestPass   = $true
            requireRegressionPass  = $false
            minimumEvaluationScore = $null
        }
        evidence = [ordered]@{}
    }
    function Set-FixtureReleaseContract {
            param($Record)
            $Record['schemaVersion'] = '1.1.0'
            $cfg = Get-EnvironmentConfig -Environment $Record['environment'] -ConfigRoot $script:ConfigRoot
            $Record['projectEndpoint'] = $cfg['foundry']['projectEndpoint'].TrimEnd('/').ToLowerInvariant()
            $Record['packageUri'] = 'https://targetstore.blob.core.windows.net/agent-packages/prior.zip'
            $Record['agent']['remoteAgentId'] = 'agent-target'
            $Record['agent']['serviceVersion'] = 'v1'
            $Record['agent']['serviceVersionId'] = 'versions/v1'
            $Record['deployment']['runtimeMutation'] = [ordered]@{
                started = $true; completed = $true; stage = 'activated'; candidateVersion = 'v1'
                startedAtUtc = '2026-10-01T12:00:00Z'; completedAtUtc = '2026-10-01T12:00:01Z'
            }
            $gates = Get-DeploymentGate -Definition (Resolve-AgentDefinition -Path $packageRoot -Environment $Record['environment'] -SkipPlaceholderExpansion)
            $Record['deployment']['attestation']['requiredGates'] = $gates
            $Record['deployment']['attestation']['evidence'] = [ordered]@{}
            foreach ($gate in @('smoke', 'evaluation', 'regression')) {
                $Record['deployment']['gateResults'][$gate] = 'passed'
                $Record['deployment']['attestation']['evidence'][$gate] = [ordered]@{
                    executed = 1; outcome = 'passed'; score = if ($gate -eq 'evaluation') { 1.0 } else { $null }
                    source = "$gate.json"; resultSha256 = 'a' * 64
                    envelope = [ordered]@{
                        schemaVersion = '1.1.0'; gate = $gate; mode = 'live'; releaseId = $Record['releaseId']
                        packageId = $Record['packageId']; agentName = $Record['agent']['name']; environment = $Record['environment']
                        projectEndpoint = $Record['projectEndpoint']; agentVersion = $Record['agent']['version']; serviceVersion = 'v1'
                        startedUtc = '2026-10-01T12:00:02Z'; executedUtc = '2026-10-01T12:01:00Z'; liveExecuted = 1
                    }
                }
            }
        }
    Set-FixtureReleaseContract $sourceRecord
    $script:SourceRecordPath = Join-Path $script:ReleaseDirectory "$($sourceRecord['releaseId']).json"
    Write-JsonFile `
        -InputObject $sourceRecord `
        -Path $script:SourceRecordPath `
        -Depth 16 `
        -Confirm:$false | Out-Null

    $rollbackRecord = New-ReleaseRecord `
        -Environment test `
        -PackageDescriptor $script:FixturePackageDescriptor `
        -Operation deploy `
        -Outcome succeeded `
        -RemoteAgentId 'asst_test_current' `
        -GateResults @{ validation = 'passed'; smoke = 'passed' }
    $rollbackRecord['deployment']['attestation'] = ConvertTo-OrderedHashtable -InputObject $sourceRecord['deployment']['attestation']
    Set-FixtureReleaseContract $rollbackRecord
    $script:KnownGoodTestRecord = $rollbackRecord | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
    $knownGoodPath = Join-Path $script:PackageOutput "$($rollbackRecord['releaseId']).json"
    Write-JsonFile -InputObject $script:KnownGoodTestRecord -Path $knownGoodPath -Depth 32 -Confirm:$false | Out-Null
    $rollbackRecord['releaseId'] = 'simple-support-agent-test-failed-attempt'
    $rollbackRecord['agent']['serviceVersion'] = 'v2'
    $rollbackRecord['agent']['serviceVersionId'] = 'versions/v2'
    $rollbackRecord['packageId'] = 'sha256:' + ('b' * 64)
    $rollbackRecord['deployment']['outcome'] = 'failed'
    $rollbackRecord['deployment']['runtimeMutation']['stage'] = 'failed'
    $rollbackRecord['deployment']['runtimeMutation']['candidateVersion'] = 'v2'
    $rollbackRecord['deployment']['attestation']['gatesSatisfied'] = $false
    $rollbackRecord['deployment']['attestation']['evidence'] = [ordered]@{}
    $rollbackRecord['previous'] = [ordered]@{
        packageId         = $script:FixturePackageDescriptor['packageId']
        agentVersion      = $script:FixturePackageDescriptor['agent']['version']
        releaseId         = $script:KnownGoodTestRecord['releaseId']
        remoteAgentId     = 'agent-target'
        serviceVersion = 'v1'
        serviceVersionId = 'versions/v1'
        releaseRecordPath = $knownGoodPath
        artifactRetained  = $true
        rollbackArtifactPath = $script:FixturePackagePath
    }
    $script:RollbackContextPath = Join-Path $script:ReleaseDirectory "$($rollbackRecord['releaseId']).json"
    Write-JsonFile `
        -InputObject $rollbackRecord `
        -Path $script:RollbackContextPath `
        -Depth 16 `
        -Confirm:$false | Out-Null

    $script:DummyEnvironmentConfig = @{
        foundry = @{
            projectEndpoint = 'https://contoso.services.ai.azure.com/api/projects/proj-test'
            apiVersion      = 'v1'
        }
        azure = @{}
    }
}

AfterAll {
    [Environment]::SetEnvironmentVariable('AZURE_TENANT_ID', $script:OriginalAzureTenantId)
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:OriginalAzureSubscriptionId)

    if (Test-Path -LiteralPath $script:ScratchRoot) {
        Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force
    }
}

Describe 'Foundry SDK wrapper contract' {
    It 'routes Responses invocation through stdin settings and logical service identity' {
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps { [pscustomobject]@{ Status = 'completed'; Output = 'hello' } }
        $result = Invoke-FoundryAgentRun -EnvironmentConfig $script:DummyEnvironmentConfig -LogicalName simple-agent `
            -AgentVersion opaque-version -Prompt 'private prompt' -TimeoutSeconds 10 -PollIntervalSeconds 1
        $result.Status | Should -Be 'completed'
        Should -Invoke Invoke-FoundryPythonCli -ModuleName FoundryAgentOps -Times 1 -Exactly -ParameterFilter {
            $Subcommand -eq 'invoke-agent' -and $LogicalName -eq 'simple-agent' -and $AgentVersion -eq 'opaque-version' -and
            $InputObject['prompt'] -eq 'private prompt' -and $InputObject['timeoutSeconds'] -eq 10
        }
    }

    It 'routes Test-FoundryEndpoint through the Python CLI helper without running Python' {
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
            [pscustomobject]@{ ok = $true }
        }

        $result = Test-FoundryEndpoint -EnvironmentConfig $script:DummyEnvironmentConfig

        $result.ok | Should -BeTrue
        Should -Invoke Invoke-FoundryPythonCli -ModuleName FoundryAgentOps -Times 1 -Exactly -ParameterFilter {
            $Subcommand -eq 'preflight' -and $EnvironmentConfig['foundry']['apiVersion'] -eq 'v1'
        }
    }

    It 'maps SDK get-agent responses through Get-FoundryAgent without running Python' {
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
            [pscustomobject]@{
                found          = $true
                id             = 'agent-123'
                name           = 'simple-agent'
                latestVersion  = 'v3'
                description    = 'Test agent'
                metadata       = @{ logical_name = 'simple-agent' }
                definition     = @{ instructions = 'Be helpful.' }
                instructions   = 'Be helpful.'
                model          = 'gpt-4o-mini'
                tools          = @(@{ type = 'function' })
                top_p          = 0.8
                temperature    = 0.2
                version        = 'v3'
                versionId      = 'version-123'
                agentEndpoint  = @{ uri = 'https://contoso.example/agents/simple-agent' }
            }
        }

        $result = Get-FoundryAgent -EnvironmentConfig $script:DummyEnvironmentConfig -LogicalName 'simple-agent'

        $result.id | Should -Be 'agent-123'
        $result.latestVersion | Should -Be 'v3'
        $result.agent_endpoint.uri | Should -Be 'https://contoso.example/agents/simple-agent'
        $result.instructions | Should -Be 'Be helpful.'
        $result.model | Should -Be 'gpt-4o-mini'
        Should -Invoke Invoke-FoundryPythonCli -ModuleName FoundryAgentOps -Times 1 -Exactly -ParameterFilter {
            $Subcommand -eq 'get-agent' -and $LogicalName -eq 'simple-agent'
        }
    }

    It 'returns null when the SDK says the logical agent is missing' {
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
            [pscustomobject]@{ found = $false }
        }

        $result = Get-FoundryAgent -EnvironmentConfig $script:DummyEnvironmentConfig -LogicalName 'missing-agent'

        $result | Should -BeNullOrEmpty
    }

    It 'requires an access token for the retained REST KnownAgentId fallback' {
        {
            Get-FoundryAgent -EnvironmentConfig $script:DummyEnvironmentConfig -LogicalName '' -KnownAgentId 'asst_legacy_123'
        } | Should -Throw -ExpectedMessage "*Get-FoundryAgent requires -AccessToken when using the retained REST get-by-id fallback for KnownAgentId 'asst_legacy_123'.*"
    }

    It 'routes new version creation through the Python CLI helper' {
        $payload = @{ model = 'gpt-4o-mini'; instructions = 'Test' }

        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
            [pscustomobject]@{ version = 'v4' }
        }

        $result = New-FoundryAgentVersion -EnvironmentConfig $script:DummyEnvironmentConfig -LogicalName 'simple-agent' -Payload $payload

        $result.version | Should -Be 'v4'
        Should -Invoke Invoke-FoundryPythonCli -ModuleName FoundryAgentOps -Times 1 -Exactly -ParameterFilter {
            $Subcommand -eq 'create-version' -and $LogicalName -eq 'simple-agent' -and $InputObject['model'] -eq 'gpt-4o-mini'
        }
    }

    It 'routes active-version promotion through the Python CLI helper' {
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
            [pscustomobject]@{ ok = $true; activeVersion = 'v4' }
        }

        $result = Set-FoundryAgentActiveVersion -EnvironmentConfig $script:DummyEnvironmentConfig -LogicalName 'simple-agent' -AgentVersion 'v4'

        $result.activeVersion | Should -Be 'v4'
        Should -Invoke Invoke-FoundryPythonCli -ModuleName FoundryAgentOps -Times 1 -Exactly -ParameterFilter {
            $Subcommand -eq 'promote-version' -and $LogicalName -eq 'simple-agent' -and $AgentVersion -eq 'v4'
        }
    }
}

Describe 'Deployment script GateResult contract' {
    It 'declares GateResult on import-agent.ps1' {
        $command = Get-Command (Join-Path $script:RepoRoot 'scripts/import-agent.ps1')
        $command.Parameters.ContainsKey('GateResult') | Should -BeTrue
        $command.Parameters['GateResult'].ParameterType | Should -Be ([hashtable])
        $command.Parameters.ContainsKey('ChangeRecordId') | Should -BeTrue
        $command.Parameters.ContainsKey('BusinessSignoffId') | Should -BeTrue
    }

    It 'accepts GateResult during import-agent WhatIf execution' {
        $output = @(& (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
            -PackagePath $script:FixturePackagePath `
            -Environment dev `
            -ConfigRoot $script:ConfigRoot `
            -GateResult @{ validation = 'passed'; smoke = 'passed' } `
            -WhatIf `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'Outcome' }) | Select-Object -Last 1

        $result.Outcome | Should -Be 'simulated'
        $result.Environment | Should -Be 'dev'
    }

    It 'requires and records constrained production governance inputs' {
        {
            & (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
                -PackagePath $script:FixturePackagePath `
                -Environment prod `
                -ConfigRoot $script:ConfigRoot `
                -ChangeRecordId 'CHG-123456' `
                -WhatIf `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage "*requires durable UAT business acceptance*"

        $output = @(& (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
            -PackagePath $script:FixturePackagePath `
            -Environment prod `
            -ConfigRoot $script:ConfigRoot `
            -ChangeRecordId 'CHG-123456' `
            -BusinessSignoffId 'BSO-123456' `
            -WhatIf `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'Outcome' }) | Select-Object -Last 1

        $result.Outcome | Should -Be 'simulated'
        $result.Environment | Should -Be 'prod'
    }

    It 'lets promote-agent.ps1 forward GateResult into import-agent.ps1 without crashing' {
        $output = @(& (Join-Path $script:RepoRoot 'scripts/promote-agent.ps1') `
            -AgentName $script:FixtureAgentName `
            -FromEnvironment dev `
            -ToEnvironment test `
            -PackagePath $script:FixturePackagePath `
            -ConfigRoot $script:ConfigRoot `
            -ReleaseDirectory $script:ReleaseDirectory `
            -GateResult @{ validation = 'passed'; smoke = 'passed' } `
            -WhatIf `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'Outcome' }) | Select-Object -Last 1

        $result.Outcome | Should -Be 'simulated'
        $result.Environment | Should -Be 'test'
    }

    It 'promotes from a transported release record without source-store access' {
        $isolatedReleaseDirectory = Join-Path $script:ScratchRoot 'isolated-target-releases'
        $null = New-Item -ItemType Directory -Path $isolatedReleaseDirectory -Force

        $output = @(& (Join-Path $script:RepoRoot 'scripts/promote-agent.ps1') `
            -AgentName $script:FixtureAgentName `
            -FromEnvironment dev `
            -ToEnvironment test `
            -PackagePath $script:FixturePackagePath `
            -SourceReleaseRecordPath $script:SourceRecordPath `
            -ConfigRoot $script:ConfigRoot `
            -ReleaseDirectory $isolatedReleaseDirectory `
            -WhatIf `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'Outcome' }) | Select-Object -Last 1

        $result.Outcome | Should -Be 'simulated'
        $result.Environment | Should -Be 'test'
        @(Get-ChildItem -LiteralPath $isolatedReleaseDirectory -File).Count | Should -Be 0
    }

    It 'fails production promotion before lookup without explicit valid governance references' {
        {
            & (Join-Path $script:RepoRoot 'scripts/promote-agent.ps1') `
                -AgentName $script:FixtureAgentName `
                -FromEnvironment uat `
                -ToEnvironment prod `
                -PackagePath $script:FixturePackagePath `
                -ChangeRecordId 'CHG-123456' `
                -WhatIf `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*requires durable UAT business acceptance*'

        {
            & (Join-Path $script:RepoRoot 'scripts/promote-agent.ps1') `
                -AgentName $script:FixtureAgentName `
                -FromEnvironment uat `
                -ToEnvironment prod `
                -PackagePath $script:FixturePackagePath `
                -ChangeRecordId 'invalid' `
                -BusinessSignoffId 'BSO-123456' `
                -WhatIf `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*requires an approved change record*'
    }

    It 'uses exact rollback context and target overlay prerequisites during WhatIf' {
        Mock Get-FoundryAgent { [pscustomobject]@{ id = 'agent-target'; activeVersion = 'v2'; versionId = 'versions/v2' } }
        $output = @(& (Join-Path $script:RepoRoot 'scripts/Invoke-Rollback.ps1') `
            -AgentName $script:FixtureAgentName `
            -Environment test `
            -ReleaseRecordPath $script:RollbackContextPath `
            -EvaluationSuitePath (Join-Path $script:RepoRoot 'samples\simple-agent\evaluations\baseline.evaluation.json') `
            -ArtifactDirectory $script:PackageOutput `
            -ConfigRoot $script:ConfigRoot `
            -ReleaseDirectory $script:ReleaseDirectory `
            -Reason 'Offline rollback wiring test' `
            -WhatIf `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'Outcome' }) | Select-Object -Last 1

        $result.Outcome | Should -Be 'simulated'
        $result.Environment | Should -Be 'test'
        $result.PackagePath | Should -Be $script:FixturePackagePath
    }

    It 'records failed attestation when required test evidence is missing' {
        $pendingRecord = New-ReleaseRecord `
            -Environment dev `
            -PackageDescriptor $script:FixturePackageDescriptor `
            -Operation deploy `
            -Outcome pending-verification `
            -RemoteAgentId 'asst_dev_pending' `
            -GateResults @{ validation = 'passed' }
        $pendingRecord['projectEndpoint'] = (Get-EnvironmentConfig -Environment dev -ConfigRoot $script:ConfigRoot)['foundry']['projectEndpoint']
        $pendingRecord['packageUri'] = 'https://example.invalid/package.zip'
        $pendingPath = Join-Path $script:ScratchRoot 'pending-release.json'
        Write-JsonFile -InputObject $pendingRecord -Path $pendingPath -Depth 16 -Confirm:$false | Out-Null

        {
            & (Join-Path $script:RepoRoot 'scripts/Complete-Release.ps1') `
                -ReleaseRecordPath $pendingPath `
                -PackagePath $script:FixturePackagePath `
                -ConfigRoot $script:ConfigRoot `
                -ReleaseDirectory $script:ReleaseDirectory `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*failed its required gates*'

        $attestedRecord = Read-JsonFile -Path $pendingPath
        $attestedRecord['deployment']['outcome'] | Should -Be 'failed'
        $attestedRecord['deployment']['attestation']['gatesSatisfied'] | Should -BeFalse
        $attestedRecord['deployment']['gateResults']['smoke'] | Should -Be 'failed'
        $schemaCheck = Test-JsonFileSchema -Path $pendingPath -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
        $schemaCheck.IsValid | Should -BeTrue -Because ($schemaCheck.Errors -join '; ')
    }
}

Describe 'Fail-safe deployment ordering' {
    BeforeEach {
        $script:BehaviorReleaseDirectory = Join-Path $script:ScratchRoot ([Guid]::NewGuid().ToString('n'))
        $script:BehaviorRollbackDirectory = Join-Path $script:BehaviorReleaseDirectory 'rollback'
        $script:BehaviorEvidencePath = Join-Path $script:BehaviorReleaseDirectory 'deployment-evidence.json'
        $null = New-Item -ItemType Directory -Path $script:BehaviorReleaseDirectory -Force

        $global:BehaviorConfig = Get-EnvironmentConfig -Environment test -ConfigRoot $script:ConfigRoot
        $global:BehaviorConfig['packageStore'] = [ordered]@{
            type        = 'azureBlob'
            accountName = 'targetstore'
            container   = 'agent-packages'
        }
        $global:BehaviorPriorRecord = $null
        $global:BehaviorFixturePackagePath = $script:FixturePackagePath

        Mock Get-EnvironmentConfig { $global:BehaviorConfig }
        Mock Get-LatestReleaseRecord { $global:BehaviorPriorRecord }
        Mock Test-FoundryEndpoint { [pscustomobject]@{ ok = $true } }
        $global:BehaviorActiveVersion = 'v1'
        Mock Get-FoundryAgent {
            if (-not $global:BehaviorPriorRecord -and $global:BehaviorActiveVersion -eq 'v1') { return $null }
            [pscustomobject]@{ id = 'agent-target'; latestVersion = 'v9'; activeVersion = $global:BehaviorActiveVersion; versionId = "versions/$global:BehaviorActiveVersion" }
        }
        Mock New-FoundryAgentVersion {
            [pscustomobject]@{ id = 'versions/v2'; version = 'v2'; agentId = 'agent-target' }
        }
        Mock Set-FoundryAgentActiveVersion {
            $global:BehaviorActiveVersion = 'v2'
            [pscustomobject]@{ ok = $true; activeVersion = 'v2' }
        }
        Mock Publish-AgentPackage {
            "https://$($EnvironmentConfig['packageStore']['accountName']).blob.core.windows.net/$($EnvironmentConfig['packageStore']['container'])/$AgentName/$($PackageId -replace '^sha256:', '').zip"
        }
        Mock Find-AgentPackage { $global:BehaviorFixturePackagePath }
    }

    It 'records a target-store URI for promotion instead of forwarding the source URI' {
        $transportedSource = Read-JsonFile -Path $script:SourceRecordPath
        $transportedSource['packageUri'] = 'https://sourcestore.blob.core.windows.net/agent-packages/source.zip'
        $transportedSourcePath = Join-Path $script:BehaviorReleaseDirectory 'source-release.json'
        Write-JsonFile -InputObject $transportedSource -Path $transportedSourcePath -Depth 16 -Confirm:$false | Out-Null

        $output = @(& (Join-Path $script:RepoRoot 'scripts/promote-agent.ps1') `
            -AgentName $script:FixtureAgentName `
            -FromEnvironment dev `
            -ToEnvironment test `
            -PackagePath $script:FixturePackagePath `
            -SourceReleaseRecordPath $transportedSourcePath `
            -ConfigRoot $script:ConfigRoot `
            -ReleaseDirectory $script:BehaviorReleaseDirectory `
            -DeploymentEvidencePath $script:BehaviorEvidencePath `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'ReleaseRecord' }) | Select-Object -Last 1
        $record = Read-ReleaseRecordFile -Path $result.ReleaseRecord

        $record['packageId'] | Should -Be $transportedSource['packageId']
        $record['packageUri'] | Should -Match '^https://targetstore\.blob\.core\.windows\.net/'
        $record['packageUri'] | Should -Not -Be $transportedSource['packageUri']
        Should -Invoke Publish-AgentPackage -Times 1 -Exactly -ParameterFilter {
            $EnvironmentConfig['packageStore']['accountName'] -eq 'targetstore' -and
            $PackageId -eq $transportedSource['packageId']
        }
    }

    It 'discovers and stages the prior target package before the next deployment' {
        $global:BehaviorPriorRecord = $script:KnownGoodTestRecord | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
        $global:BehaviorPriorRecord['packageUri'] = 'https://targetstore.blob.core.windows.net/agent-packages/prior.zip'

        $output = @(& (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
            -PackagePath $script:FixturePackagePath `
            -Environment test `
            -ConfigRoot $script:ConfigRoot `
            -ReleaseDirectory $script:BehaviorReleaseDirectory `
            -RollbackStageDirectory $script:BehaviorRollbackDirectory `
            -DeploymentEvidencePath $script:BehaviorEvidencePath `
            -Confirm:$false)
        $result = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'ReleaseRecord' }) | Select-Object -Last 1
        $record = Read-ReleaseRecordFile -Path $result.ReleaseRecord

        $record['previous']['artifactRetained'] | Should -BeTrue
        Test-Path -LiteralPath $record['previous']['rollbackArtifactPath'] | Should -BeTrue
        Should -Invoke Find-AgentPackage -Times 1 -Exactly -ParameterFilter {
            $PackageId -eq $script:FixturePackageDescriptor['packageId'] -and
            $EnvironmentConfig['packageStore']['accountName'] -eq 'targetstore'
        }
    }

    It 'makes post-activation failure evidence durable and stages exactly one rollback opportunity' {
        $global:BehaviorPriorRecord = $script:KnownGoodTestRecord | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64

        {
            & (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
                -PackagePath $script:FixturePackagePath `
                -Environment test `
                -ConfigRoot $script:ConfigRoot `
                -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -RollbackStageDirectory $script:BehaviorRollbackDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath `
                -TestFailurePoint AfterActivation `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*Simulated failure after runtime activation*'

        $evidence = Read-JsonFile -Path $script:BehaviorEvidencePath
        $failedRecord = Read-ReleaseRecordFile -Path $evidence['releaseRecordPath']
        $evidence['mutationStarted'] | Should -BeTrue
        $evidence['mutationCompleted'] | Should -BeTrue
        $evidence['priorArtifactStaged'] | Should -BeTrue
        $evidence['failedReleaseAttempted'] | Should -BeTrue
        $evidence['failedReleaseRecorded'] | Should -BeTrue
        $failedRecord['deployment']['outcome'] | Should -Be 'failed'
        $failedRecord['deployment']['runtimeMutation']['stage'] | Should -Be 'failed'
        $failedRecord['deployment']['attestation']['gatesSatisfied'] | Should -BeFalse
        Should -Invoke Set-FoundryAgentActiveVersion -Times 1 -Exactly
    }

    It 'does not expose rollback evidence for a pre-mutation failure' {
        {
            & (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
                -PackagePath $script:FixturePackagePath `
                -Environment test `
                -ConfigRoot $script:ConfigRoot `
                -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -RollbackStageDirectory $script:BehaviorRollbackDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath `
                -TestFailurePoint AfterPackagePublication `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*before runtime activation*'

        $evidence = Read-JsonFile -Path $script:BehaviorEvidencePath
        $evidence['mutationStarted'] | Should -BeFalse
        $evidence['mutationCompleted'] | Should -BeFalse
        Should -Invoke New-FoundryAgentVersion -Times 0 -Exactly
        Should -Invoke Set-FoundryAgentActiveVersion -Times 0 -Exactly
    }

    It 'durably fails and surfaces explicit recovery for a first-deployment activation failure' {
        {
            & (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
                -PackagePath $script:FixturePackagePath `
                -Environment test `
                -ConfigRoot $script:ConfigRoot `
                -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -RollbackStageDirectory $script:BehaviorRollbackDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath `
                -TestFailurePoint AfterActivation `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*Simulated failure after runtime activation*'

        $evidence = Read-JsonFile -Path $script:BehaviorEvidencePath
        $failedRecord = Read-ReleaseRecordFile -Path $evidence['releaseRecordPath']
        $evidence['mutationStarted'] | Should -BeTrue
        $evidence['priorArtifactStaged'] | Should -BeFalse
        $evidence['recoveryAction'] | Should -Match 'Deploy a known-good package explicitly'
        $failedRecord['deployment']['outcome'] | Should -Be 'failed'
        $failedRecord['previous']['artifactRetained'] | Should -BeFalse
    }

    It 'persists creating intent and workflow evidence before a thrown or ambiguous create_version' {
        Mock New-FoundryAgentVersion {
            $before = Read-JsonFile -Path $global:IntentEvidencePath
            $before['mutationStarted'] | Should -BeTrue
            $intentRecord = Read-JsonFile -Path $before['releaseRecordPath']
            $intentRecord['deployment']['runtimeMutation']['stage'] | Should -Be 'creating'
            throw 'ambiguous create failure'
        }
        $global:IntentEvidencePath = $script:BehaviorEvidencePath
        {
            & (Join-Path $script:RepoRoot 'scripts\import-agent.ps1') -PackagePath $script:FixturePackagePath `
                -Environment test -ConfigRoot $script:ConfigRoot -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath -Confirm:$false
        } | Should -Throw '*ambiguous create failure*'
        $evidence = Read-JsonFile -Path $script:BehaviorEvidencePath
        $evidence['mutationStarted'] | Should -BeTrue
        $evidence['mutationCompleted'] | Should -BeFalse
        (Read-ReleaseRecordFile -Path $evidence['releaseRecordPath'])['deployment']['outcome'] | Should -Be 'failed'
        Should -Invoke Set-FoundryAgentActiveVersion -Times 0
    }

    It 'does not create if durable creating intent cannot be saved' {
        Mock Save-ReleaseRecord {
            if ($Record['deployment']['runtimeMutation']['stage'] -eq 'creating') { throw 'intent storage failed' }
            $path = Join-Path $LocalDirectory "$($Record['releaseId']).json"
            Write-JsonFile -InputObject $Record -Path $path -Depth 32 -Confirm:$false | Out-Null
            return $path
        }
        {
            & (Join-Path $script:RepoRoot 'scripts\import-agent.ps1') -PackagePath $script:FixturePackagePath `
                -Environment test -ConfigRoot $script:ConfigRoot -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath -Confirm:$false
        } | Should -Throw '*intent storage failed*'
        Should -Invoke New-FoundryAgentVersion -Times 0
    }

    It 'never resets mutation intent after a post-create persistence failure' {
        Mock Save-ReleaseRecord {
            if ($Record['deployment']['runtimeMutation']['stage'] -eq 'created') { throw 'created record storage failed' }
            $path = Join-Path $LocalDirectory "$($Record['releaseId']).json"
            Write-JsonFile -InputObject $Record -Path $path -Depth 32 -Confirm:$false | Out-Null
            return $path
        }
        {
            & (Join-Path $script:RepoRoot 'scripts\import-agent.ps1') -PackagePath $script:FixturePackagePath `
                -Environment test -ConfigRoot $script:ConfigRoot -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath -Confirm:$false
        } | Should -Throw '*created record storage failed*'
        $evidence = Read-JsonFile -Path $script:BehaviorEvidencePath
        $evidence['mutationStarted'] | Should -BeTrue
        (Read-ReleaseRecordFile -Path $evidence['releaseRecordPath'])['agent']['serviceVersion'] | Should -Be 'v2'
        Should -Invoke Set-FoundryAgentActiveVersion -Times 0
    }

    It 'rejects unverified activation without recording completed mutation' {
        Mock Set-FoundryAgentActiveVersion { [pscustomobject]@{ ok = $true; activeVersion = 'wrong-version' } }
        {
            & (Join-Path $script:RepoRoot 'scripts\import-agent.ps1') -PackagePath $script:FixturePackagePath `
                -Environment test -ConfigRoot $script:ConfigRoot -ReleaseDirectory $script:BehaviorReleaseDirectory `
                -DeploymentEvidencePath $script:BehaviorEvidencePath -Confirm:$false
        } | Should -Throw '*Activation did not verify*'
        $evidence = Read-JsonFile -Path $script:BehaviorEvidencePath
        $evidence['mutationStarted'] | Should -BeTrue
        $evidence['mutationCompleted'] | Should -BeFalse
    }

    It 'refuses a failed latest audit record that cannot map serving state to an attested prior release' {
        $global:BehaviorPriorRecord = $script:KnownGoodTestRecord | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
        $global:BehaviorPriorRecord['deployment']['outcome'] = 'failed'
        {
            & (Join-Path $script:RepoRoot 'scripts\import-agent.ps1') -PackagePath $script:FixturePackagePath `
                -Environment test -ConfigRoot $script:ConfigRoot -ReleaseDirectory $script:BehaviorReleaseDirectory -Confirm:$false
        } | Should -Throw '*Cannot reconcile*'
        Should -Invoke Publish-AgentPackage -Times 0
        Should -Invoke New-FoundryAgentVersion -Times 0
    }
}

Describe 'Real package format compatibility and repeat-build identity' {
    BeforeAll {
        $script:FrozenLegacyFixture = Read-JsonFile -Path (Join-Path $PSScriptRoot 'fixtures\strict-v1.fixture.json')
        $script:FrozenLegacyRoot = Join-Path $script:ScratchRoot 'frozen-original-v1'
        foreach ($file in $script:FrozenLegacyFixture['files'].GetEnumerator()) {
            $path = Join-Path $script:FrozenLegacyRoot ($file.Key.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            [IO.File]::WriteAllText($path, $file.Value, [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText((Join-Path $script:FrozenLegacyRoot 'checksums.sha256'),
            $script:FrozenLegacyFixture['checksumManifest'], [Text.UTF8Encoding]::new($false))
    }

    It 'builds and expands real samples with reproducible /2 identity across volatile build changes' {
        $priorRun = $env:GITHUB_RUN_ID; $priorRef = $env:GITHUB_REF
        try {
            $env:GITHUB_RUN_ID = 'first'; $env:GITHUB_REF = 'refs/heads/first'
            $first = & (Join-Path $script:RepoRoot 'scripts\New-AgentPackage.ps1') -AgentPath (Join-Path $script:RepoRoot 'samples\simple-agent') `
                -OutputDirectory (Join-Path $script:ScratchRoot 'build-one') -SourceCommit ('a' * 40) -SkipResolveCheck
            $env:GITHUB_RUN_ID = 'second'; $env:GITHUB_REF = 'refs/heads/second'
            $second = & (Join-Path $script:RepoRoot 'scripts\New-AgentPackage.ps1') -AgentPath (Join-Path $script:RepoRoot 'samples\simple-agent') `
                -OutputDirectory (Join-Path $script:ScratchRoot 'build-two') -SourceCommit ('a' * 40) -SkipResolveCheck
            $first.PackageId | Should -Be $second.PackageId
            $root = Expand-AgentPackage -PackagePath $second.PackagePath -Destination (Join-Path $script:ScratchRoot 'real-expanded')
            $descriptor = Read-PackageDescriptor -PackageRoot $root
            $descriptor['packageFormat'] | Should -Be 'foundry-agent-package/2'
            $manifest = New-ChecksumManifest -Root $root -ExcludeRelativePath @('package.json')
            $reordered = [ordered]@{}
            foreach ($key in @($descriptor.Keys)[($descriptor.Count - 1)..0]) { $reordered[$key] = $descriptor[$key] }
            (Get-PackageId -ChecksumManifest $manifest -Descriptor $reordered) | Should -Be $first.PackageId
            $reordered['build']['sourceCommit'] = 'b' * 40
            (Get-PackageId -ChecksumManifest $manifest -Descriptor $reordered) | Should -Not -Be $first.PackageId
            $descriptor['agent']['owner']['team'] = 'tampered'
            Write-JsonFile -InputObject $descriptor -Path (Join-Path $root 'package.json') -Depth 32 -Confirm:$false | Out-Null
            Write-TextFile -Path (Join-Path $root 'checksums.sha256') -Content (New-ChecksumManifest -Root $root) -Confirm:$false | Out-Null
            { Expand-AgentPackage -PackagePath $root -Destination (Join-Path $script:ScratchRoot 'unused') } | Should -Throw '*content*'
        }
        finally { $env:GITHUB_RUN_ID = $priorRun; $env:GITHUB_REF = $priorRef }
    }

    It 'verifies the frozen original /1 fixture without regenerating its expected identity' {
        $verification = Test-ChecksumManifest -Root $script:FrozenLegacyRoot
        $verification.IsValid | Should -BeTrue
        $verification.ContentId | Should -Be $script:FrozenLegacyFixture['packageId']
        $legacyManifest = New-ChecksumManifest -Root $script:FrozenLegacyRoot -ExcludeRelativePath @('package.json') `
            -PackageFormat 'foundry-agent-package/1'
        $legacyManifest | Should -Be $script:FrozenLegacyFixture['contentManifest']
        $ordinalManifest = New-ChecksumManifest -Root $script:FrozenLegacyRoot -ExcludeRelativePath @('package.json') `
            -PackageFormat 'foundry-agent-package/2'
        ($ordinalManifest -split "`n")[1] | Should -Match '  manifest/README\.md$'
        $zip = Join-Path $script:ScratchRoot 'frozen-original-v1.zip'
        Compress-Archive -Path (Join-Path $script:FrozenLegacyRoot '*') -DestinationPath $zip
        $root = Expand-AgentPackage -PackagePath $zip -Destination (Join-Path $script:ScratchRoot 'frozen-legacy-expanded')
        (Read-PackageDescriptor -PackageRoot $root)['packageId'] | Should -Be $script:FrozenLegacyFixture['packageId']
    }

    It 'refuses original builder and checksum-only /1 identities' {
        $checksumOnly = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($script:FrozenLegacyFixture['contentManifest']))).ToLowerInvariant()
        foreach ($invalidId in @($script:FrozenLegacyFixture['builderWithoutDescriptorId'],
                $script:FrozenLegacyFixture['builderBeforeReadbackId'], $checksumOnly)) {
            $root = Join-Path $script:ScratchRoot ([Guid]::NewGuid().ToString('n'))
            Copy-Item -LiteralPath $script:FrozenLegacyRoot -Destination $root -Recurse
            $d = Read-PackageDescriptor -PackageRoot $root
            $d['packageId'] = $invalidId
            Write-JsonFile -InputObject $d -Path (Join-Path $root 'package.json') -Depth 32 -Confirm:$false | Out-Null
            Write-TextFile -Path (Join-Path $root 'checksums.sha256') -Content (
                New-ChecksumManifest -Root $root -PackageFormat 'foundry-agent-package/1') -Confirm:$false | Out-Null
            (Test-ChecksumManifest -Root $root).IsValid | Should -BeTrue
            { Expand-AgentPackage -PackagePath $root -Destination (Join-Path $script:ScratchRoot 'unused-legacy') } |
                Should -Throw '*content*'
        }
    }

    It 'keeps original /1 build provenance bound and refuses unknown formats' {
        $root = Join-Path $script:ScratchRoot 'legacy-descriptor-tamper'
        Copy-Item -LiteralPath $script:FrozenLegacyRoot -Destination $root -Recurse
        $d = Read-PackageDescriptor -PackageRoot $root
        $d['packageFormat'] = 'foundry-agent-package/999'
        { Get-PackageId -ChecksumManifest $script:FrozenLegacyFixture['contentManifest'] -Descriptor $d } |
            Should -Throw '*Unsupported package format*'
        $d['packageFormat'] = 'foundry-agent-package/1'
        $d['build']['buildRunId'] = 'changed-after-build'
        Write-JsonFile -InputObject $d -Path (Join-Path $root 'package.json') -Depth 32 -Confirm:$false | Out-Null
        Write-TextFile -Path (Join-Path $root 'checksums.sha256') -Content (
            New-ChecksumManifest -Root $root -PackageFormat 'foundry-agent-package/1') -Confirm:$false | Out-Null
        (Test-ChecksumManifest -Root $root).IsValid | Should -BeTrue
        { Expand-AgentPackage -PackagePath $root -Destination (Join-Path $script:ScratchRoot 'unused-legacy') } | Should -Throw '*content*'
    }

    It 'rejects modified original /1 file content against frozen checksums' {
        $root = Join-Path $script:ScratchRoot 'legacy-content-tamper'
        Copy-Item -LiteralPath $script:FrozenLegacyRoot -Destination $root -Recurse
        [IO.File]::WriteAllText((Join-Path $root 'manifest\instructions.md'), 'tampered', [Text.UTF8Encoding]::new($false))
        { Expand-AgentPackage -PackagePath $root -Destination (Join-Path $script:ScratchRoot 'unused-legacy') } |
            Should -Throw '*integrity*'
    }

    It 'treats an existing blob as idempotent only for identical archive bytes' {
        Mock az -ModuleName FoundryAgentOps { $global:LASTEXITCODE = 1; 'BlobAlreadyExists' }
        $global:ExistingArchive = $script:FixturePackagePath
        Mock Get-AgentPackageFromStore -ModuleName FoundryAgentOps { $global:ExistingArchive }
        $cfg = @{ environment = 'test'; packageStore = @{ type = 'azureBlob'; accountName = 'offline'; container = 'packages' } }
        Publish-AgentPackage -PackagePath $script:FixturePackagePath -AgentName $script:FixtureAgentName `
            -PackageId $script:FixturePackageDescriptor['packageId'] -EnvironmentConfig $cfg -Confirm:$false | Should -Match '^https://'
        $global:ExistingArchive = Join-Path $script:ScratchRoot 'different.zip'
        Set-Content -LiteralPath $global:ExistingArchive -Value 'not the original archive'
        { Publish-AgentPackage -PackagePath $script:FixturePackagePath -AgentName $script:FixtureAgentName `
            -PackageId $script:FixturePackageDescriptor['packageId'] -EnvironmentConfig $cfg -Confirm:$false } | Should -Throw '*Archive byte conflict*'
    }
}

Describe 'Centrally verified rollback and exact live attestation' {
    BeforeEach {
        $script:RecoveryDirectory = Join-Path $script:ScratchRoot ("recovery-" + [Guid]::NewGuid().ToString('n'))
        $global:RecoveryConfig = Get-EnvironmentConfig -Environment test -ConfigRoot $script:ConfigRoot
        $global:RecoveryVersion = 'v2'
        $global:RecoveryOutput = 'delivery cannot specialist not share processing'
        $global:RecoveryPackage = $script:FixturePackagePath
        Mock Get-EnvironmentConfig { $global:RecoveryConfig }
        Mock Get-LatestReleaseRecord { $null }
        Mock Test-FoundryEndpoint { [pscustomobject]@{ ok = $true } }
        Mock Get-FoundryAgent {
            [pscustomobject]@{
                id = 'agent-target'; activeVersion = $global:RecoveryVersion; latestVersion = 'v99'
                versionId = "versions/$global:RecoveryVersion"; metadata = [pscustomobject]@{ agent_version = '1.0.0'; environment = 'test' }
            }
        }
        Mock New-FoundryAgentVersion {
            [pscustomobject]@{ id = 'versions/v3'; version = 'v3'; agentId = 'agent-target' }
        }
        Mock Set-FoundryAgentActiveVersion {
            $global:RecoveryVersion = 'v3'
            [pscustomobject]@{ ok = $true; activeVersion = 'v3' }
        }
        Mock Publish-AgentPackage { 'https://targetstore.blob.core.windows.net/packages/rollback.zip' }
        Mock Find-AgentPackage { $global:RecoveryPackage }
        Mock Invoke-FoundryAgentRun {
            [pscustomobject]@{
                Output = $global:RecoveryOutput; Status = 'completed'; LatencyMs = 10; Error = $null
                ResponseId = 'resp_offline'; ConversationId = 'conv_offline'; AgentName = $LogicalName; ServiceVersion = $AgentVersion
            }
        }
        Mock Invoke-FoundryPythonCli -ModuleName FoundryAgentOps {
                if ($Subcommand -eq 'get-agent') {
                    return [pscustomobject]@{
                        found = $true; id = 'agent-target'; name = 'simple-support-agent'
                        activeVersion = $global:RecoveryVersion; latestVersion = 'v99'; versionId = "versions/$global:RecoveryVersion"
                        metadata = [pscustomobject]@{ agent_version = '1.0.0'; environment = 'test' }
                    }
                }
                throw "Unexpected bridge command in offline rollback test: $Subcommand"
        }
        $script:RecoveryParameters = @{
            AgentName = $script:FixtureAgentName; Environment = 'test'; ArtifactDirectory = $script:PackageOutput
            ConfigRoot = $script:ConfigRoot; ReleaseDirectory = $script:RecoveryDirectory
            ReleaseRecordPath = $script:RollbackContextPath
            EvaluationSuitePath = Join-Path $script:RepoRoot 'samples\simple-agent\evaluations\baseline.evaluation.json'
            Reason = 'offline verified recovery'; Confirm = $false
        }
    }

    It 'redeploys prior verified bytes as a new version and attests all target-required live gates once' {
        $outputs = @(& (Join-Path $script:RepoRoot 'scripts\Invoke-Rollback.ps1') @script:RecoveryParameters)
        $result = @($outputs | Where-Object { $_.PSObject.Properties.Name -contains 'ReleaseRecord' })[-1]
        $result.Outcome | Should -Be 'succeeded'
        $result.Operation | Should -Be 'rollback'
        $record = Read-ReleaseRecordFile -Path $result.ReleaseRecord
        $record['agent']['version'] | Should -Be '1.0.0'
        $record['agent']['serviceVersion'] | Should -Be 'v3'
        $record['deployment']['attestation']['gatesSatisfied'] | Should -BeTrue
        foreach ($gate in @('smoke', 'evaluation', 'regression')) {
            $evidence = $record['deployment']['attestation']['evidence'][$gate]
            $evidence['outcome'] | Should -Be 'passed'
            $evidence['envelope']['releaseId'] | Should -Be $record['releaseId']
            $evidence['envelope']['serviceVersion'] | Should -Be 'v3'
            $evidence['envelope']['liveExecuted'] | Should -BeGreaterThan 0
        }
        Should -Invoke New-FoundryAgentVersion -Times 1 -Exactly
        Should -Invoke Set-FoundryAgentActiveVersion -Times 1 -Exactly
        Should -Invoke Invoke-FoundryAgentRun -Times 14 -Exactly
    }

    It 'persists a failed rollback attestation without reporting recovery or recursively rolling back' {
        $global:RecoveryOutput = 'system prompt'
        { & (Join-Path $script:RepoRoot 'scripts\Invoke-Rollback.ps1') @script:RecoveryParameters } | Should -Throw '*Smoke test failed*'
        $records = @(Get-ChildItem -LiteralPath $script:RecoveryDirectory -Filter "$($script:FixtureAgentName)-test-*.json" -File |
            Where-Object { (Read-JsonFile -Path $_.FullName).Contains('deployment') })
        $records.Count | Should -Be 1
        $failed = Read-ReleaseRecordFile -Path $records[0].FullName
        $failed['deployment']['operation'] | Should -Be 'rollback'
        $failed['deployment']['outcome'] | Should -Be 'failed'
        $failed['deployment']['attestation']['gatesSatisfied'] | Should -BeFalse
        Should -Invoke New-FoundryAgentVersion -Times 1 -Exactly
    }

    It 'rejects stale contexts and predictable missing evaluation prerequisites before mutation' {
        $global:RecoveryVersion = 'unrelated-new-version'
        { & (Join-Path $script:RepoRoot 'scripts\Invoke-Rollback.ps1') @script:RecoveryParameters } | Should -Throw '*drift*'
        $global:RecoveryVersion = 'v2'
        $script:RecoveryParameters.Remove('EvaluationSuitePath')
        { & (Join-Path $script:RepoRoot 'scripts\Invoke-Rollback.ps1') @script:RecoveryParameters } | Should -Throw '*requires -EvaluationSuitePath before mutation*'
        Should -Invoke New-FoundryAgentVersion -Times 0
    }

    It 'fails and durably records an invalid supplied result for the exact pending release' {
        $record = $script:KnownGoodTestRecord | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
        $record['releaseId'] = 'simple-support-agent-test-pending-for-invalid-evidence'
        $record['deployment']['outcome'] = 'pending-verification'
        $record['deployment'].Remove('attestation')
        $global:RecoveryVersion = 'v1'
        $pending = Join-Path $script:RecoveryDirectory 'pending.json'
        $invalid = Join-Path $script:RecoveryDirectory 'invalid.json'
        Write-JsonFile -InputObject $record -Path $pending -Depth 32 -Confirm:$false | Out-Null
        Write-TextFile -Path $invalid -Content '{not-json' -Confirm:$false | Out-Null
        {
            & (Join-Path $script:RepoRoot 'scripts\Complete-Release.ps1') -ReleaseRecordPath $pending `
                -PackagePath $script:FixturePackagePath -SmokeResultPath $invalid -ConfigRoot $script:ConfigRoot `
                -ReleaseDirectory $script:RecoveryDirectory -Confirm:$false
        } | Should -Throw '*failed its required gates*'
        $failed = Read-ReleaseRecordFile -Path $pending
        $failed['deployment']['outcome'] | Should -Be 'failed'
        $failed['deployment']['attestation']['failure'] | Should -Match 'JSON|json|Unexpected'
    }
}

Describe 'Hosted offline validation contract' -Tag 'HostedOffline' {
    It 'verifies sample packages against explicit DEV governance without bypassing it' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/validate.yml') -Raw
        $buildStep = [regex]::Match($workflow, '(?s)- name: Build and verify the package.*?(?=\n      - name:)').Value
        $buildStep | Should -Match 'Test-AgentPackage\.ps1[^\r\n]*-Environment dev'
        $buildStep | Should -Not -Match '-SkipGovernance'
    }

    It 'limits synthetic PROD references to the all-environment offline WhatIf step' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/validate.yml') -Raw
        $whatIfStep = [regex]::Match($workflow, '(?s)- name: Show the resolved payload for every environment.*').Value
        $whatIfStep | Should -Match "foreach \(\`$environment in @\('dev', 'test', 'uat', 'prod'\)\)"
        $whatIfStep | Should -Match "(?s)if \(\`$environment -eq 'prod'\) \{\s*# Synthetic.*?ChangeRecordId = '(CHG-[0-9]+)'.*?BusinessSignoffId = '(BSO-[0-9]+)'"
        $references = [regex]::Match($whatIfStep, "ChangeRecordId = '(CHG-[0-9]+)'; BusinessSignoffId = '(BSO-[0-9]+)'")
        {
            & (Join-Path $script:RepoRoot 'scripts/import-agent.ps1') `
                -PackagePath $script:FixturePackagePath -Environment prod -ConfigRoot $script:ConfigRoot `
                -ChangeRecordId $references.Groups[1].Value -BusinessSignoffId $references.Groups[2].Value `
                -WhatIf -Confirm:$false | Out-Null
        } | Should -Not -Throw
        $whatIfStep | Should -Match 'import-agent\.ps1[^\r\n]*@syntheticGovernance -WhatIf'
        $whatIfStep | Should -Not -Match '-SkipGovernance|-SkipPreflight'
        $workflow.Substring(0, $workflow.IndexOf('- name: Show the resolved payload for every environment')) |
            Should -Not -Match 'CHG-[0-9]+|BSO-[0-9]+'
    }

    It 'installs the pinned SDK on Python 3.11 before explicitly running Python unit tests' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/_reusable-validate.yml') -Raw
        $workflow | Should -Match "actions/setup-python@v5\s+with:\s+python-version: '3\.11'"
        $installStep = [regex]::Match($workflow, '(?s)- name: Install Foundry SDK dependencies.*?(?=\n      - name:)').Value
        $installStep | Should -Match 'shell: bash'
        $installStep | Should -Match 'python -m pip install --disable-pip-version-check -r scripts/python/requirements\.txt'
        $installStep | Should -Match '(?m)^\s+run:\s+python -m pip install[^\r\n]*\bPyYAML==\d+\.\d+\.\d+(?:\s|$)'
        $testStep = [regex]::Match($workflow, '(?s)- name: Run Python unit tests.*?(?=\n      - name:)').Value
        $testStep | Should -Match 'shell: bash'
        $testStep | Should -Match "python -m unittest discover -s tests/unit/python -p 'test_\*\.py' -v"
        $workflow.IndexOf('uses: actions/setup-python@v5') | Should -BeLessThan $workflow.IndexOf('name: Install Foundry SDK dependencies')
        $workflow.IndexOf('name: Install Foundry SDK dependencies') | Should -BeLessThan $workflow.IndexOf('name: Run Python unit tests')
        $workflow.IndexOf('name: Install Foundry SDK dependencies') | Should -BeLessThan $workflow.IndexOf('name: Run offline validation suite')
        $testStep | Should -Not -Match 'continue-on-error|if:'
    }
}

Describe 'Foundry module exports and workflow wiring' {
    It 'exports the new version-management functions from FoundryAgentOps.psd1' {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1')
        @($manifest.FunctionsToExport) | Should -Contain 'New-FoundryAgentVersion'
        @($manifest.FunctionsToExport) | Should -Contain 'Set-FoundryAgentActiveVersion'
    }

    It 'keeps the reusable deploy workflow aligned with the import GateResult contract and gate attestation flow' {
        $workflowPath = Join-Path $script:RepoRoot '.github/workflows/_reusable-deploy.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
        $importCommand = Get-Command (Join-Path $script:RepoRoot 'scripts/import-agent.ps1')

        $workflow | Should -Match 'name:\s+Deploy package'
        $workflow | Should -Match 'GateResult\s+=\s+@\{\s*validation\s+=\s+''passed'''
        $importCommand.Parameters.ContainsKey('GateResult') | Should -BeTrue

        $attestIndex = $workflow.IndexOf('name: Attest release gates')
        $regressionIndex = $workflow.IndexOf('name: Regression tests')
        $uploadIndex = $workflow.IndexOf('name: Upload release record and test results')
        $rollbackIndex = $workflow.IndexOf('name: Roll back on failure')

        $attestIndex | Should -BeGreaterThan $regressionIndex
        $attestIndex | Should -BeLessThan $rollbackIndex
        $rollbackIndex | Should -BeLessThan $uploadIndex
        $workflow | Should -Match 'Complete-Release\.ps1'
        $workflow | Should -Match 'businessSignoffId:'
        $workflow | Should -Match "-ChangeRecordId '\$\{\{ inputs\.changeRecordId \}\}'"
        $workflow | Should -Match "-BusinessSignoffId '\$\{\{ inputs\.businessSignoffId \}\}'"
        $workflow | Should -Match "if:\s+always\(\)\s+&&\s+\(steps\.deploy\.outcome == 'success' \|\| steps\.promote\.outcome == 'success'\)"
        $workflow | Should -Match 'rollbackArtifactPath=\$\(\$evidence\.rollbackArtifactPath\)'
        $workflow | Should -Match "steps\.deploy\.outputs\.mutationStarted == 'true'"
        $workflow | Should -Match "steps\.deploy\.outputs\.priorArtifactStaged == 'true'"
        $workflow | Should -Match 'name: Surface first-deployment recovery'
        ([regex]::Matches($workflow, 'Invoke-Rollback\.ps1')).Count | Should -Be 1
        $workflow | Should -Match '-ArtifactDirectory \(Split-Path -Parent \$rollbackArtifactPath\)'
        $workflow | Should -Match '-SourceReleaseRecordPath \$sourceReleaseRecordPath'
        $workflow | Should -Not -Match "-ArtifactDirectory\s+'\.\/artifacts'"
        $workflow | Should -Not -Match '-RollbackOnFailure'
    }

    It 'keeps manual GitHub rollback on SDK, governance, tests, and single attestation parity' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/rollback.yml') -Raw -Encoding utf8

        $workflow | Should -Match 'actions/setup-python@v5'
        $workflow | Should -Match 'pip install --disable-pip-version-check -r scripts/python/requirements\.txt'
        $workflow | Should -Match 'Validate rollback governance inputs'
        $workflow | Should -Match "inputs\.environment \}\}' -eq 'prod'"
        $workflow | Should -Match 'Reason\s+=\s+''\$\{\{ inputs\.reason \}\}'''
        $workflow | Should -Match 'ChangeRecordId\s+=\s+''\$\{\{ inputs\.changeRecordId \}\}'''
        $workflow | Should -Match 'BusinessSignoffId\s+=\s+''\$\{\{ inputs\.businessSignoffId \}\}'''
        $workflow | Should -Match 'releaseRecordPath=\$\(\$result\.ReleaseRecord\)'
        $workflow | Should -Match 'packagePath=\$\(\$result\.PackagePath\)'
        $workflow | Should -Match 'ReleaseRecordPath\s+='
        $workflow | Should -Match 'EvaluationSuitePath\s+='
        $centralRollback = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts\Invoke-Rollback.ps1') -Raw
        $centralRollback | Should -Match 'Invoke-RegressionTest\.ps1'
        $centralRollback | Should -Match 'Complete-Release\.ps1'
        $workflow | Should -Not -Match 'Complete-Release\.ps1'
        $workflow | Should -Match 'group:\s+foundry-\$\{\{ inputs.environment \}\}-\$\{\{ inputs.agentName \}\}'
        $workflow | Should -Match 'name:\s+rollback-\$\{\{ inputs\.environment \}\}-\$\{\{ github\.run_id \}\}'
        $workflow | Should -Not -Match '-RollbackOnFailure'
        ([regex]::Matches($workflow, 'Invoke-Rollback\.ps1')).Count | Should -Be 1
    }

    It 'grants id-token: write in each reusable-deploy caller and retains it in rollback.yml' {
        foreach ($workflowName in @('deploy-dev.yml', 'deploy-test.yml', 'deploy-prod.yml', 'rollback.yml')) {
            $workflowPath = Join-Path $script:RepoRoot ".github/workflows/$workflowName"
            $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
            $workflow | Should -Match '(?m)^permissions:\s*$'
            $workflow | Should -Match '(?m)^\s+id-token:\s+write\s*$'
        }
    }

    It 'keeps Azure DevOps deployment and rollback on the pinned SDK and attestation contract' {
        $stagePath = Join-Path $script:RepoRoot 'azure-devops/pipelines/templates/stages/deploy-stage.yml'
        $stage = Get-Content -LiteralPath $stagePath -Raw -Encoding utf8
        $rollbackPipeline = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'azure-devops/pipelines/rollback.yml') -Raw -Encoding utf8
        $testPipeline = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'azure-devops/pipelines/deploy-test.yml') -Raw -Encoding utf8

        $stage | Should -Match 'UsePythonVersion@0'
        $stage | Should -Match "versionSpec:\s+'3\.11'"
        $stage | Should -Match 'pip install --disable-pip-version-check -r scripts/python/requirements\.txt'
        $stage | Should -Match 'releaseRecordPath\]\$\(\$evidence\.releaseRecordPath\)'
        $stage | Should -Match 'rollbackArtifactPath\]\$\(\$evidence\.rollbackArtifactPath\)'
        $stage | Should -Match 'condition:\s+and\(always\(\), eq\(variables\[''deploymentCommandSucceeded''\], ''true''\), eq\(variables\[''mutationCompleted''\], ''true''\)\)'
        $stage | Should -Match 'Complete-Release\.ps1'
        $stage | Should -Match 'condition:\s+and\(failed\(\), eq\(variables\[''deploymentChanged''\], ''true''\), eq\(variables\[''priorArtifactStaged''\], ''true''\)\)'
        $stage | Should -Match 'displayName: Surface first-deployment recovery'
        ([regex]::Matches($stage, 'Invoke-Rollback\.ps1')).Count | Should -Be 1
        $stage | Should -Match '-ArtifactDirectory \(Split-Path -Parent \$rollbackArtifactPath\)'
        $stage | Should -Not -Match "-ArtifactDirectory\s+'\$\(Pipeline\.Workspace\)'"
        $stage | Should -Not -Match '-RollbackOnFailure'
        $stage | Should -Match "-ChangeRecordId '\$\{\{ parameters\.changeRecordId \}\}'"
        $stage | Should -Match "-BusinessSignoffId '\$\{\{ parameters\.businessSignoffId \}\}'"
        $stage | Should -Match 'PublishPipelineArtifact@1'
        $stage | Should -Match "-SourceReleaseRecordPath '\$\(sourceReleaseRecordPath\)'"
        $stage | Should -Match 'artifact:\s+releaseRecords-\$\{\{ parameters\.sourceEnvironment \}\}'
        $stage | Should -Match 'artifact:\s+releaseRecords-\$\{\{ parameters\.environmentName \}\}'

        $regressionIndex = $stage.IndexOf('displayName: Regression tests')
        $attestIndex = $stage.IndexOf('displayName: Attest release gates')
        $rollbackIndex = $stage.IndexOf('displayName: Roll back on failure')
        $publishIndex = $stage.IndexOf('displayName: Publish release record and test results')
        $attestIndex | Should -BeGreaterThan $regressionIndex
        $attestIndex | Should -BeLessThan $rollbackIndex
        $rollbackIndex | Should -BeLessThan $publishIndex

        $rollbackPipeline | Should -Match 'UsePythonVersion@0'
        $rollbackPipeline | Should -Match 'pip install --disable-pip-version-check -r scripts/python/requirements\.txt'
        $rollbackPipeline | Should -Match 'Validate rollback governance inputs'
        $rollbackPipeline | Should -Match "parameters\.environmentName \}\}' -eq 'prod'"
        $rollbackPipeline | Should -Match 'rollbackReleaseRecordPath\]\$\(\$result\.ReleaseRecord\)'
        $rollbackPipeline | Should -Match 'rollbackPackagePath\]\$\(\$result\.PackagePath\)'
        $rollbackPipeline | Should -Match 'ReleaseRecordPath\s+='
        $rollbackPipeline | Should -Match 'EvaluationSuitePath\s+='
        $rollbackPipeline | Should -Not -Match 'Complete-Release\.ps1'
        $rollbackPipeline | Should -Match 'lockBehavior:\s+sequential'
        $stage | Should -Match 'lockBehavior:\s+sequential'
        $rollbackPipeline | Should -Not -Match '-RollbackOnFailure'
        $rollbackPipeline | Should -Match 'ChangeRecordId\s+=\s+''\$\{\{ parameters\.changeRecordId \}\}'''
        $rollbackPipeline | Should -Match 'BusinessSignoffId\s+=\s+''\$\{\{ parameters\.businessSignoffId \}\}'''
        $testPipeline | Should -Match 'republishPackage:\s+true'
        $uatBlock = $testPipeline.Substring($testPipeline.IndexOf('stageName: promoteUat'))
        $uatBlock | Should -Not -Match 'sourcePipelineResource:\s+devPipeline'

        $githubTest = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/deploy-test.yml') -Raw -Encoding utf8
        $githubProd = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/deploy-prod.yml') -Raw -Encoding utf8
        $githubTest | Should -Match 'release-dev-\$\{\{ inputs\.sourceRunId \}\}'
        $githubTest | Should -Match 'release-test-\$\{\{ github\.run_id \}\}'
        $githubTest | Should -Match 'artifactName:\s+uat-package'
        $githubProd | Should -Match 'release-uat-\$\{\{ inputs\.sourceRunId \}\}'
    }

    It 'documents reviewed portal handoff and durable governance evidence' {
        $runbook = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs/deployment-runbook.md') -Raw -Encoding utf8
        $patterns = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs/deployment-patterns.md') -Raw -Encoding utf8
        $governance = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs/governance.md') -Raw -Encoding utf8
        $azureReadme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'azure-devops/README.md') -Raw -Encoding utf8

        $runbook | Should -Match 'Merge the pull request before any portal deletion'
        $runbook | Should -Match 'pipeline-created version and its attested release record before deleting'
        $patterns | Should -Match 'reviewed pull request'
        $patterns | Should -Match 'pipeline-created version'
        $governance | Should -Match 'governance\.rollbackReason'
        $governance | Should -Match 'governance\.changeRecordId.*governance\.businessSignoffId.*governance\.responsibleAiReviewId'
        $azureReadme | Should -Match 'attests post-deployment evidence'
        $azureReadme | Should -Match 'republishes the unchanged `agentPackage`'
    }
}
