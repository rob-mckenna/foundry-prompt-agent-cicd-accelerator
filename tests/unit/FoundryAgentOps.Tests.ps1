#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for FoundryAgentOps. Everything here runs offline with no Azure credentials.
    Run with:  Invoke-Pester -Path ./tests/unit
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force
    $script:SampleRoot = Join-Path $script:RepoRoot 'samples'
    function Set-TestReleaseContract {
        param($Record)
        $Record['schemaVersion'] = '1.1.0'
        if (-not $Record.Contains('releaseId')) { $Record['releaseId'] = 'test-release' }
        $Record['projectEndpoint'] = "https://example.invalid/api/projects/$($Record['environment'])"
        $Record['packageUri'] = 'https://example.invalid/package.zip'
        $Record['agent']['version'] = '1.0.0'
        $Record['agent']['remoteAgentId'] = 'agent-test'
        $Record['agent']['serviceVersion'] = 'opaque-v1'
        $Record['agent']['serviceVersionId'] = 'versions/opaque-v1'
        $Record['deployment']['runtimeMutation'] = [ordered]@{
            started = $true; completed = $true; stage = 'activated'; candidateVersion = 'opaque-v1'
            startedAtUtc = '2026-10-01T12:00:00Z'; completedAtUtc = '2026-10-01T12:00:01Z'
        }
        if ($Record['deployment'].Contains('attestation')) {
            foreach ($gate in $Record['deployment']['attestation']['evidence'].Keys) {
                $Record['deployment']['attestation']['evidence'][$gate]['resultSha256'] = 'a' * 64
                $Record['deployment']['attestation']['evidence'][$gate]['envelope'] = [ordered]@{
                    schemaVersion = '1.1.0'; gate = $gate; mode = 'live'; releaseId = $Record['releaseId']
                    packageId = $Record['packageId']; agentName = $Record['agent']['name']; environment = $Record['environment']
                    projectEndpoint = $Record['projectEndpoint']; agentVersion = '1.0.0'; serviceVersion = 'opaque-v1'
                    startedUtc = '2026-10-01T12:00:02Z'; executedUtc = '2026-10-01T12:01:00Z'
                    liveExecuted = $Record['deployment']['attestation']['evidence'][$gate]['executed']
                }
            }
        }
    }
}

Describe 'Merge-Hashtable' {
    It 'deep merges nested objects' {
        $base = [ordered]@{ a = 1; nested = [ordered]@{ x = 1; y = 2 } }
        $override = [ordered]@{ nested = [ordered]@{ y = 9; z = 3 } }
        $result = Merge-Hashtable -Base $base -Override $override
        $result['a'] | Should -Be 1
        $result['nested']['x'] | Should -Be 1
        $result['nested']['y'] | Should -Be 9
        $result['nested']['z'] | Should -Be 3
    }

    It 'replaces arrays rather than concatenating them' {
        $base = [ordered]@{ list = @(1, 2, 3) }
        $override = [ordered]@{ list = @(9) }
        $result = Merge-Hashtable -Base $base -Override $override
        @($result['list']).Count | Should -Be 1
        $result['list'][0] | Should -Be 9
    }

    It 'does not mutate the base object' {
        $base = [ordered]@{ a = 1 }
        $null = Merge-Hashtable -Base $base -Override ([ordered]@{ a = 2 })
        $base['a'] | Should -Be 1
    }
}

Describe 'Expand-Placeholder' {
    It 'substitutes values from the variable map' {
        $result = Expand-Placeholder -InputObject ([ordered]@{ url = 'https://${env:HOST}/api' }) -Variables @{ HOST = 'contoso.example.com' }
        $result.Value['url'] | Should -Be 'https://contoso.example.com/api'
    }

    It 'resolves nested placeholders across passes' {
        $variables = @{
            CONNECTION = '/subscriptions/${env:SUBSCRIPTION}/connections/kb'
            SUBSCRIPTION = '11111111-2222-3333-4444-555555555555'
        }
        $result = Expand-Placeholder -InputObject ([ordered]@{ id = '${env:CONNECTION}' }) -Variables $variables
        $result.Value['id'] | Should -Be '/subscriptions/11111111-2222-3333-4444-555555555555/connections/kb'
    }

    It 'throws with the missing names when a placeholder cannot be resolved' {
        { Expand-Placeholder -InputObject ([ordered]@{ a = '${env:DEFINITELY_NOT_SET_XYZ}' }) } |
        Should -Throw -ExpectedMessage '*DEFINITELY_NOT_SET_XYZ*'
    }

    It 'reports unresolved names instead of throwing when AllowUnresolved is set' {
        $result = Expand-Placeholder -InputObject ([ordered]@{ a = '${env:DEFINITELY_NOT_SET_XYZ}' }) -AllowUnresolved
        $result.Unresolved | Should -Contain 'DEFINITELY_NOT_SET_XYZ'
        $result.Value['a'] | Should -Be '${env:DEFINITELY_NOT_SET_XYZ}'
    }
}

Describe 'Get-PlaceholderName' {
    It 'finds placeholders in nested structures' {
        $names = Get-PlaceholderName -InputObject ([ordered]@{ a = '${env:ONE}'; b = @('${env:TWO}', [ordered]@{ c = '${env:ONE}' }) })
        @($names).Count | Should -Be 2
        $names | Should -Contain 'ONE'
        $names | Should -Contain 'TWO'
    }
}

Describe 'Checksums and package identity' {
    BeforeAll {
        $script:WorkRoot = Join-Path $script:RepoRoot ("out\platform-work\fnd-test-" + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:WorkRoot 'manifest') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkRoot 'manifest/a.txt') -Value 'alpha' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:WorkRoot 'b.txt') -Value 'beta' -NoNewline
        $script:HashDescriptor = @{ packageFormat = 'foundry-agent-package/2'; agent = @{ name = 'test-agent' }; build = @{}; contents = @{} }
        Write-JsonFile -InputObject $script:HashDescriptor -Path (Join-Path $script:WorkRoot 'package.json') -Confirm:$false | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:WorkRoot) { Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force }
    }

    It 'produces a deterministic manifest independent of enumeration order' {
        $first = New-ChecksumManifest -Root $script:WorkRoot
        $second = New-ChecksumManifest -Root $script:WorkRoot
        $first | Should -Be $second
        $first | Should -Match 'manifest/a.txt'
    }

    It 'produces a sha256 package id' {
        $id = Get-PackageId -ChecksumManifest (New-ChecksumManifest -Root $script:WorkRoot) -Descriptor $script:HashDescriptor
        $id | Should -Match '^sha256:[a-f0-9]{64}$'
    }

    It 'matches the frozen original descriptor-bound /1 identity' {
        $fixture = Read-JsonFile -Path (Join-Path $PSScriptRoot 'fixtures\strict-v1.fixture.json')
        $descriptor = $fixture['files']['package.json'] | ConvertFrom-Json -AsHashtable -Depth 32
        (Get-PackageId -ChecksumManifest $fixture['contentManifest'] -Descriptor $descriptor) |
            Should -Be $fixture['packageId']
    }

    It 'preserves original /1 and ordinal /2 canonical key ordering' {
        $build = [ordered]@{ buildRunId = '17'; builder = 'local' }
        (ConvertTo-CanonicalJson -InputObject $build -PackageFormat 'foundry-agent-package/1') |
            Should -Be '{"builder":"local","buildRunId":"17"}'
        (ConvertTo-CanonicalJson -InputObject $build -PackageFormat 'foundry-agent-package/2') |
            Should -Be '{"buildRunId":"17","builder":"local"}'
    }

    It 'excludes requested paths from the content id' {
        $withAll = New-ChecksumManifest -Root $script:WorkRoot
        $without = New-ChecksumManifest -Root $script:WorkRoot -ExcludeRelativePath @('b.txt')
        $withAll | Should -Match 'b.txt'
        $without | Should -Not -Match 'b.txt'
    }

    It 'detects a modified file' {
        $manifest = New-ChecksumManifest -Root $script:WorkRoot
        [System.IO.File]::WriteAllText((Join-Path $script:WorkRoot 'checksums.sha256'), $manifest, [System.Text.UTF8Encoding]::new($false))
        (Test-ChecksumManifest -Root $script:WorkRoot).IsValid | Should -BeTrue

        Set-Content -LiteralPath (Join-Path $script:WorkRoot 'b.txt') -Value 'tampered' -NoNewline
        $result = Test-ChecksumManifest -Root $script:WorkRoot
        $result.IsValid | Should -BeFalse
        $result.Modified | Should -Contain 'b.txt'
    }
}

Describe 'Resolve-AgentDefinition' {
    It 'resolves every sample in every environment' {
        foreach ($sample in @('simple-agent', 'rag-agent', 'multi-tool-agent')) {
            foreach ($environment in @('dev', 'test', 'uat', 'prod')) {
                $definition = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot $sample) -Environment $environment -SkipPlaceholderExpansion
                $definition['manifest']['name'] | Should -Not -BeNullOrEmpty
                $definition['instructions'] | Should -Not -BeNullOrEmpty
                $definition['environment'] | Should -Be $environment
            }
        }
    }

    It 'applies the overlay model override' {
        $dev = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'simple-agent') -Environment dev -SkipPlaceholderExpansion
        $prod = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'simple-agent') -Environment prod -SkipPlaceholderExpansion
        $dev['manifest']['model']['deploymentName'] | Should -Be 'gpt-4o-mini'
        $prod['manifest']['model']['deploymentName'] | Should -Be 'gpt-4o'
        $prod['manifest']['model']['parameters']['temperature'] | Should -Be 0.1
    }

    It 'removes tools disabled by the overlay' {
        $test = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'multi-tool-agent') -Environment test -SkipPlaceholderExpansion
        $prod = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'multi-tool-agent') -Environment prod -SkipPlaceholderExpansion
        @($test['tools']).Count | Should -Be 5
        @($prod['tools']).Count | Should -Be 3
        $prod['disabledTools'] | Should -Contain 'code-interpreter'
        $prod['disabledTools'] | Should -Contain 'web-grounding'
    }

    It 'fails when the environment overlay is missing' {
        $temporary = Join-Path $script:RepoRoot ("out\platform-work\fnd-noenv-" + [Guid]::NewGuid().ToString('n'))
        Copy-Item -Recurse (Join-Path $script:SampleRoot 'simple-agent') $temporary
        Remove-Item -LiteralPath (Join-Path $temporary 'environments/uat.overlay.json') -Force
        try {
            { Resolve-AgentDefinition -Path $temporary -Environment uat -SkipPlaceholderExpansion } |
            Should -Throw -ExpectedMessage '*No overlay found for environment*'
        }
        finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

Describe 'ConvertTo-FoundryAgentPayload' {
    BeforeAll {
        $script:ProdPayload = ConvertTo-FoundryAgentPayload -Definition (
            Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'multi-tool-agent') -Environment prod -SkipPlaceholderExpansion
        )
    }

    It 'maps the manifest onto Agent Service field names' {
        $script:ProdPayload['model'] | Should -Be 'gpt-4o'
        $script:ProdPayload['name'] | Should -Be 'operations-copilot'
        $script:ProdPayload['temperature'] | Should -Be 0.1
        $script:ProdPayload.Contains('instructions') | Should -BeTrue
    }

    It 'emits azure_ai_search under tool_resources' {
        $script:ProdPayload['tool_resources']['azure_ai_search']['indexes'][0]['index_name'] | Should -Be 'ops-prod-v2'
    }

    It 'inlines the OpenAPI specification' {
        $openapi = @($script:ProdPayload['tools'] | Where-Object { $_['type'] -eq 'openapi' })[0]
        $openapi['openapi']['spec']['openapi'] | Should -Be '3.0.3'
        $openapi['openapi']['auth']['type'] | Should -Be 'connection'
    }

    It 'writes traceability metadata as strings' {
        $script:ProdPayload['metadata']['managed_by'] | Should -Be 'foundry-prompt-agent-cicd-accelerator'
        $script:ProdPayload['metadata']['logical_name'] | Should -Be 'operations-copilot'
        $script:ProdPayload['metadata']['environment'] | Should -Be 'prod'
        foreach ($value in $script:ProdPayload['metadata'].Values) { $value | Should -BeOfType [string] }
    }

    It 'keeps metadata within the Agent Service limit of 16 pairs' {
        $script:ProdPayload['metadata'].Count | Should -BeLessOrEqual 16
    }

    It 'emits the flat azure-ai-projects 2.7.0 json_schema response format' {
        $schemaPath = Join-Path $TestDrive 'response.schema.json'
        '{"type":"object","properties":{"answer":{"type":"string"}}}' | Set-Content -LiteralPath $schemaPath -Encoding utf8
        $definition = [ordered]@{
            manifestRoot    = $TestDrive
            containmentRoot = $TestDrive
            inventory       = @{}
            environment     = 'test'
            instructions    = 'Return JSON.'
            tools           = @()
            manifest        = [ordered]@{
                name    = 'schema-agent'
                version = '1.0.0'
                model   = [ordered]@{
                    deploymentName = 'gpt-4o-mini'
                    responseFormat = [ordered]@{
                        type           = 'json_schema'
                        jsonSchemaFile = 'response.schema.json'
                    }
                }
            }
        }

        $payload = ConvertTo-FoundryAgentPayload -Definition $definition

        $payload['response_format']['type'] | Should -Be 'json_schema'
        $payload['response_format']['name'] | Should -Be 'schema-agent'
        $payload['response_format']['schema']['type'] | Should -Be 'object'
        $payload['response_format'].Contains('json_schema') | Should -BeFalse
    }

    It 'normalizes text and rejects the unsupported auto response format' {
        $definition = [ordered]@{
            manifestRoot = $TestDrive
            environment  = 'test'
            instructions = 'Respond.'
            tools        = @()
            manifest     = [ordered]@{
                name    = 'text-agent'
                version = '1.0.0'
                model   = [ordered]@{
                    deploymentName = 'gpt-4o-mini'
                    responseFormat = [ordered]@{ type = 'text' }
                }
            }
        }

        $payload = ConvertTo-FoundryAgentPayload -Definition $definition
        $payload['response_format'].Count | Should -Be 1
        $payload['response_format']['type'] | Should -Be 'text'

        $definition['manifest']['model']['responseFormat']['type'] = 'auto'
        { ConvertTo-FoundryAgentPayload -Definition $definition } |
            Should -Throw -ExpectedMessage "*Unsupported responseFormat.type 'auto'*"
    }

    It 'maps MCP requireApproval and rejects unsupported values' {
        $definition = [ordered]@{
            manifestRoot = $TestDrive
            environment  = 'test'
            instructions = 'Use the tool.'
            manifest     = [ordered]@{
                name    = 'mcp-agent'
                version = '1.0.0'
                model   = [ordered]@{ deploymentName = 'gpt-4o-mini' }
            }
            tools        = @(
                [ordered]@{
                    id       = 'knowledge'
                    type     = 'mcp'
                    _enabled = $true
                    config   = [ordered]@{
                        serverLabel     = 'knowledge'
                        serverUrl       = 'https://mcp.contoso.example'
                        allowedTools    = @('lookup')
                        requireApproval = 'always'
                    }
                }
            )
        }

        $payload = ConvertTo-FoundryAgentPayload -Definition $definition
        $payload['tools'][0]['require_approval'] | Should -Be 'always'

        $definition['tools'][0]['config']['requireApproval'] = 'sometimes'
        { ConvertTo-FoundryAgentPayload -Definition $definition } |
            Should -Throw -ExpectedMessage "*Unsupported MCP requireApproval 'sometimes'*"
    }
}

Describe 'Test-AgentGovernance' {
    It 'passes every sample against every environment policy' {
        foreach ($sample in @('simple-agent', 'rag-agent', 'multi-tool-agent')) {
            foreach ($environment in @('dev', 'test', 'uat', 'prod')) {
                $definition = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot $sample) -Environment $environment -SkipPlaceholderExpansion
                $definition = (Expand-Placeholder -InputObject $definition -Variables @{
                        CHANGE_RECORD_ID = 'CHG-123456'
                    } -AllowUnresolved).Value
                $config = Get-EnvironmentConfig -Environment $environment -SkipPlaceholderExpansion
                $result = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
                $result.IsCompliant | Should -BeTrue -Because "$sample in $environment reported: $($result.Violations -join '; ')"
            }
        }
    }

    It 'blocks a tool type that is not on the environment allow list' {
        $definition = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'multi-tool-agent') -Environment test -SkipPlaceholderExpansion
        $config = Get-EnvironmentConfig -Environment prod -SkipPlaceholderExpansion
        $result = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
        $result.IsCompliant | Should -BeFalse
        ($result.Violations -join ' ') | Should -Match 'code_interpreter|bing_grounding'
    }

    It 'blocks a temperature above the environment maximum' {
        $definition = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'simple-agent') -Environment dev -SkipPlaceholderExpansion
        $definition['manifest']['model']['parameters']['temperature'] = 1.9
        $config = Get-EnvironmentConfig -Environment prod -SkipPlaceholderExpansion
        $result = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
        $result.IsCompliant | Should -BeFalse
        ($result.Violations -join ' ') | Should -Match 'temperature'
    }

    It 'blocks a missing required metadata key' {
        $definition = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot 'simple-agent') -Environment uat -SkipPlaceholderExpansion
        $definition['manifest']['metadata'].Remove('service')
        $config = Get-EnvironmentConfig -Environment uat -SkipPlaceholderExpansion
        $result = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
        $result.IsCompliant | Should -BeFalse
        ($result.Violations -join ' ') | Should -Match "service"
    }
}

Describe 'Resolve-SecretReference input validation' {
    It 'rejects a malformed Key Vault reference without contacting Azure' {
        { Resolve-SecretReference -Reference 'not-a-reference' } |
        Should -Throw -ExpectedMessage '*Invalid Key Vault reference format*'
    }
}

Describe 'New-ReleaseRecord' {
    It 'builds a record that satisfies the release record schema' {
        $descriptor = [ordered]@{
            packageId = 'sha256:' + ('a' * 64)
            agent     = [ordered]@{
                name           = 'test-agent'
                version        = '1.0.0'
                classification = [ordered]@{ responsibleAiReviewId = 'RAI-2026-1234' }
            }
        }
        $record = New-ReleaseRecord -Environment prod -PackageDescriptor $descriptor -Operation promote `
            -Outcome pending-verification -RemoteAgentId 'asst_test' -SourceEnvironment uat `
            -GateResults @{ validation = 'passed'; smoke = 'passed' } `
            -ChangeRecordId 'CHG-123456' -BusinessSignoffId 'BSO-123456'

        $record['releaseId'] | Should -Match '^test-agent-prod-\d{8}T\d{6}Z-a{12}-[a-f0-9]{8}$'
        $record['deployment']['operation'] | Should -Be 'promote'
        $record['deployment']['sourceEnvironment'] | Should -Be 'uat'
        $record['governance']['changeRecordId'] | Should -Be 'CHG-123456'
        $record['governance']['businessSignoffId'] | Should -Be 'BSO-123456'
        $record['governance']['responsibleAiReviewId'] | Should -Be 'RAI-2026-1234'

        Set-TestReleaseContract $record
        $temporary = Join-Path $script:RepoRoot ("out\platform-work\release-" + [Guid]::NewGuid().ToString('n') + '.json')
        try {
            Write-JsonFile -InputObject $record -Path $temporary -Depth 12 -Confirm:$false | Out-Null
            $check = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
            $check.IsValid | Should -BeTrue -Because ($check.Errors -join '; ')
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts constrained attestation evidence and staged rollback state' {
        $descriptor = [ordered]@{
            packageId = 'sha256:' + ('b' * 64)
            agent     = [ordered]@{ name = 'test-agent'; version = '2.0.0' }
        }
        $previous = [ordered]@{
            packageId           = 'sha256:' + ('a' * 64)
            packageUri          = 'https://artifacts.example/packages/test-agent.zip'
            agentVersion        = '1.0.0'
            remoteAgentId       = 'agent-previous'
            releaseId           = 'test-agent-test-20261001T120000Z-aaaaaaaaaaaa'
            artifactRetained    = $true
            rollbackArtifactPath = 'C:\staged\rollback-test-agent.zip'
        }
        $record = New-ReleaseRecord -Environment test -PackageDescriptor $descriptor -Operation deploy `
            -Outcome failed -RemoteAgentId 'agent-current' -Previous $previous
        $record['deployment']['attestation'] = [ordered]@{
            gatesSatisfied = $false
            attestedAtUtc  = '2026-10-01T20:00:00Z'
            attestedBy     = 'local:tester'
            requiredGates  = [ordered]@{
                requireEvaluationPass  = $true
                requireSmokeTestPass   = $true
                requireRegressionPass  = $true
                minimumEvaluationScore = 0.85
            }
            evidence       = [ordered]@{
                smoke = [ordered]@{
                    executed = 3
                    outcome  = 'failed'
                    score    = $null
                    source   = 'out/smoke-test.json'
                }
                evaluation = [ordered]@{
                    executed = 10
                    outcome  = 'passed'
                    score    = 0.9
                    source   = 'out/evaluation-test.json'
                }
            }
        }

        Set-TestReleaseContract $record
        $temporary = Join-Path $script:RepoRoot ("out\platform-work\release-full-" + [Guid]::NewGuid().ToString('n') + '.json')
        try {
            Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null
            $check = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
            $check.IsValid | Should -BeTrue -Because ($check.Errors -join '; ')

            $record['previous'].Remove('rollbackArtifactPath')
            Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null
            $invalidCheck = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
            $invalidCheck.IsValid | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts empty evidence only for failed attestations and rejects it for success' {
        $descriptor = [ordered]@{
            packageId = 'sha256:' + ('f' * 64)
            agent     = [ordered]@{ name = 'test-agent'; version = '2.1.0' }
        }
        $record = New-ReleaseRecord -Environment dev -PackageDescriptor $descriptor -Operation deploy `
            -Outcome failed -GateResults @{ validation = 'passed'; smoke = 'failed' }
        $record['deployment']['attestation'] = [ordered]@{
            gatesSatisfied = $false
            attestedAtUtc  = '2026-10-01T20:00:00Z'
            attestedBy     = 'local:tester'
            requiredGates  = [ordered]@{
                requireEvaluationPass  = $false
                requireSmokeTestPass   = $true
                requireRegressionPass  = $false
                minimumEvaluationScore = $null
            }
            evidence       = [ordered]@{}
        }
        Set-TestReleaseContract $record
        $temporary = Join-Path $TestDrive 'empty-attestation-evidence.json'
        Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null

        $failedCheck = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
        $failedCheck.IsValid | Should -BeTrue -Because ($failedCheck.Errors -join '; ')

        $record['deployment']['outcome'] = 'succeeded'
        $record['deployment']['attestation']['gatesSatisfied'] = $true
        $record['deployment']['gateResults']['smoke'] = 'passed'
        Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null
        $successCheck = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
        $successCheck.IsValid | Should -BeFalse
    }

    It 'requires rollback reason and validates retained-artifact consistency' {
        $descriptor = [ordered]@{
            packageId = 'sha256:' + ('9' * 64)
            agent     = [ordered]@{ name = 'test-agent'; version = '2.0.1' }
        }
        $previous = [ordered]@{
            packageId            = 'sha256:' + ('8' * 64)
            artifactRetained     = $false
            rollbackArtifactPath = 'C:\staged\must-not-exist.zip'
        }
        $record = New-ReleaseRecord -Environment test -PackageDescriptor $descriptor -Operation rollback `
            -Outcome pending-verification -Previous $previous
        Set-TestReleaseContract $record
        $temporary = Join-Path $TestDrive 'rollback-release.json'
        Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null

        (Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')).IsValid |
            Should -BeFalse

        $record['governance']['rollbackReason'] = 'INC-1234 restore last verified package'
        $record['previous'].Remove('rollbackArtifactPath')
        Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null
        $check = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
        $check.IsValid | Should -BeTrue -Because ($check.Errors -join '; ')
    }

    It 'rejects malformed governance evidence identifiers' {
        $descriptor = [ordered]@{
            packageId = 'sha256:' + ('c' * 64)
            agent     = [ordered]@{ name = 'test-agent'; version = '3.0.0' }
        }
        $record = New-ReleaseRecord -Environment prod -PackageDescriptor $descriptor -Operation promote `
            -Outcome pending-verification -ChangeRecordId 'not-a-change' -BusinessSignoffId 'approval-1'
        $temporary = Join-Path $TestDrive 'invalid-prod-release.json'
        Write-JsonFile -InputObject $record -Path $temporary -Depth 16 -Confirm:$false | Out-Null

        $check = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')

        $check.IsValid | Should -BeFalse
    }
}

Describe 'Test-ReleaseRecordForPromotion' {
    BeforeAll {
        $script:PromotionRecord = [ordered]@{
            environment = 'uat'
            packageId   = 'sha256:' + ('d' * 64)
            agent       = [ordered]@{ name = 'test-agent' }
            deployment  = [ordered]@{
                outcome     = 'succeeded'
                gateResults = [ordered]@{
                    smoke     = 'passed'
                    evaluation = 'passed'
                    regression = 'passed'
                }
                attestation = [ordered]@{
                    gatesSatisfied = $true
                    attestedAtUtc  = '2026-10-01T20:00:00Z'
                    attestedBy     = 'github:tester'
                    requiredGates  = [ordered]@{
                        requireSmokeTestPass   = $true
                        requireEvaluationPass  = $true
                        requireRegressionPass  = $true
                        minimumEvaluationScore = 0.85
                    }
                    evidence       = [ordered]@{
                        smoke = [ordered]@{ executed = 2; outcome = 'passed'; score = $null; source = 'smoke.json' }
                        evaluation = [ordered]@{ executed = 10; outcome = 'passed'; score = 0.9; source = 'evaluation.json' }
                        regression = [ordered]@{ executed = 4; outcome = 'passed'; score = $null; source = 'regression.json' }
                    }
                }
            }
        }
        Set-TestReleaseContract $script:PromotionRecord
    }

    It 'requires successful attestation, required evidence, and a source package match' {
        $check = Test-ReleaseRecordForPromotion -Record $script:PromotionRecord -AgentName test-agent `
            -PackageId ('sha256:' + ('d' * 64)) -SourceEnvironment uat -ExpectedGates $script:PromotionRecord['deployment']['attestation']['requiredGates']

        $check.IsValid | Should -BeTrue -Because ($check.Problems -join '; ')
    }

    It 'fails closed for empty evidence and a package mismatch' {
        $record = ConvertTo-OrderedHashtable -InputObject $script:PromotionRecord
        $record['packageId'] = 'sha256:' + ('e' * 64)
        $record['deployment']['attestation']['evidence'] = [ordered]@{}

        $check = Test-ReleaseRecordForPromotion -Record $record -AgentName test-agent `
            -PackageId ('sha256:' + ('d' * 64)) -SourceEnvironment uat -ExpectedGates $script:PromotionRecord['deployment']['attestation']['requiredGates']

        $check.IsValid | Should -BeFalse
        ($check.Problems -join ' ') | Should -Match 'supplied artifact'
        ($check.Problems -join ' ') | Should -Match 'evidence is empty'
    }

    It 'fails closed when a required gate result is missing or not passing' {
        $record = ConvertTo-OrderedHashtable -InputObject $script:PromotionRecord
        $record['deployment']['gateResults']['smoke'] = 'failed'
        $record['deployment']['gateResults'].Remove('regression')

        $check = Test-ReleaseRecordForPromotion -Record $record -AgentName test-agent `
            -PackageId ('sha256:' + ('d' * 64)) -SourceEnvironment uat -ExpectedGates $script:PromotionRecord['deployment']['attestation']['requiredGates']

        $check.IsValid | Should -BeFalse
        ($check.Problems -join ' ') | Should -Match "required smoke gate result is 'failed'"
        ($check.Problems -join ' ') | Should -Match "required regression gate result is 'missing'"
    }
}

Describe 'Get-EnvironmentConfig' {
    It 'resolves only explicitly allowlisted configuration identifiers' {
        $cfg = Get-EnvironmentConfig -Environment dev -RuntimeVariable @{
            AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
            AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        }
        $cfg['azure']['tenantId'] | Should -Be '11111111-1111-1111-1111-111111111111'
        { Get-EnvironmentConfig -Environment dev -RuntimeVariable @{ NOT_ALLOWLISTED = 'no' } } | Should -Throw '*not listed*'
    }

    It 'loads and validates all four environments' {
        foreach ($environment in @('dev', 'test', 'uat', 'prod')) {
            $config = Get-EnvironmentConfig -Environment $environment -SkipPlaceholderExpansion
            $config['environment'] | Should -Be $environment
            $config['foundry']['projectEndpoint'] | Should -Match '^https://.+/api/projects/.+$'
            $config['foundry']['apiVersion'] | Should -Not -BeNullOrEmpty
        }

    }

    It 'enables auto deploy only in DEV' {
        (Get-EnvironmentConfig -Environment dev -SkipPlaceholderExpansion)['deployment']['autoDeploy'] | Should -BeTrue
        foreach ($environment in @('test', 'uat', 'prod')) {
            $config = Get-EnvironmentConfig -Environment $environment -SkipPlaceholderExpansion
            $config['deployment']['autoDeploy'] | Should -BeFalse
            $config['deployment']['approvalRequired'] | Should -BeTrue
        }
    }
}

Describe 'Bound live gate evidence' {
            BeforeAll {
                $script:EvidenceRecord = New-ReleaseRecord -Environment test -PackageDescriptor @{
                    packageId = 'sha256:' + ('a' * 64); agent = @{ name = 'test-agent'; version = '1.0.0' }
                } -Operation deploy -Outcome pending-verification
                Set-TestReleaseContract $script:EvidenceRecord
                $script:EvidenceConfig = @{ environment = 'test'; foundry = @{ projectEndpoint = $script:EvidenceRecord['projectEndpoint'] } }
                function New-TestGateResult {
                    param([string]$Gate)
                    $r = [ordered]@{
                        schemaVersion = '1.1.0'; gate = $Gate; mode = 'live'; releaseId = $script:EvidenceRecord['releaseId']
                        packageId = $script:EvidenceRecord['packageId']; agentName = 'test-agent'; environment = 'test'
                        projectEndpoint = $script:EvidenceRecord['projectEndpoint']; agentVersion = '1.0.0'; serviceVersion = 'opaque-v1'
                        startedUtc = '2026-10-01T12:00:02Z'; executedUtc = '2026-10-01T12:01:00Z'; liveExecuted = 1
                        passed = 1; failed = 0
                    }
                    $item = @{ Live = $true; Status = 'completed'; ResponseId = 'resp_1'; ConversationId = 'conv_1'; LatencyMs = 10 }
                    if ($Gate -eq 'smoke') {
                        $item['Result'] = 'passed'; $r['checks'] = @($item); $r['skipped'] = 0
                    }
                    else {
                        $item['Passed'] = $true; $r['total'] = 1
                        $r[$(if ($Gate -eq 'evaluation') { 'records' } else { 'cases' })] = @($item)
                    }
                    if ($Gate -eq 'evaluation') {
                        $r['passRate'] = 1.0; $r['thresholdsMet'] = $true; $r['p95LatencyMs'] = 10
                        $r['thresholds'] = @{ minimumPassRate = 0.9; maximumFailures = 0; maximumP95LatencyMs = 100 }
                    }
                    return $r
                }
            }

            It 'accepts real bound <Gate> results and retains their hash/envelope' -TestCases @(
                @{ Gate = 'smoke' }, @{ Gate = 'evaluation' }, @{ Gate = 'regression' }
            ) {
                param($Gate)
                $path = Join-Path $TestDrive "$Gate.json"
                Write-JsonFile -InputObject (New-TestGateResult $Gate) -Path $path -Depth 16 -Confirm:$false | Out-Null
                $parameters = @{ "$($Gate)ResultPath" = $path; ReleaseRecord = $script:EvidenceRecord; EnvironmentConfig = $script:EvidenceConfig }
                $result = Read-GateEvidence @parameters
                $result[$Gate].Outcome | Should -Be 'passed'
                $result[$Gate].Envelope['serviceVersion'] | Should -Be 'opaque-v1'
                $result[$Gate].ResultSha256 | Should -Be (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
            }

            It 'rejects invalid supplied smoke evidence even when the caller might consider it optional: <Fault>' -TestCases @(
                @{ Fault = 'fixture' }, @{ Fault = 'releaseId' }, @{ Fault = 'packageId' }, @{ Fault = 'agentName' },
                @{ Fault = 'environment' }, @{ Fault = 'projectEndpoint' }, @{ Fault = 'agentVersion' }, @{ Fault = 'serviceVersion' },
                @{ Fault = 'stale' }, @{ Fault = 'future' }, @{ Fault = 'empty' }, @{ Fault = 'no-canary' }, @{ Fault = 'no-response-id' },
                @{ Fault = 'wrong-status' }, @{ Fault = 'string-counter' }, @{ Fault = 'inconsistent-counter' }
            ) {
                param($Fault)
                $r = New-TestGateResult smoke
                switch ($Fault) {
                    fixture { $r['mode'] = 'offline-fixture' }
                    stale { $r['startedUtc'] = '2026-10-01T11:00:00Z' }
                    future { $r['executedUtc'] = '2099-01-01T00:00:00Z' }
                    empty { $r['checks'] = @(); $r['passed'] = 0; $r['liveExecuted'] = 0 }
                    no-canary { $r['checks'][0]['Live'] = $false; $r['liveExecuted'] = 0 }
                    no-response-id { $r['checks'][0]['ResponseId'] = '' }
                    wrong-status { $r['checks'][0]['Status'] = 'requires_action' }
                    string-counter { $r['passed'] = '1' }
                    inconsistent-counter { $r['passed'] = 2 }
                    default { $r[$Fault] = 'wrong' }
                }
                $path = Join-Path $TestDrive 'bad-smoke.json'
                Write-JsonFile -InputObject $r -Path $path -Depth 16 -Confirm:$false | Out-Null
                { Read-GateEvidence -SmokeResultPath $path -ReleaseRecord $script:EvidenceRecord -EnvironmentConfig $script:EvidenceConfig } | Should -Throw
            }

            It 'rejects coerced booleans, bad scores, thresholds and detailed live counts: <Fault>' -TestCases @(
                @{ Fault = 'boolean' }, @{ Fault = 'score' }, @{ Fault = 'thresholds' }, @{ Fault = 'live-count' }
            ) {
                param($Fault)
                $r = New-TestGateResult evaluation
                switch ($Fault) {
                    boolean { $r['thresholdsMet'] = 'false' }
                    score { $r['passRate'] = 0.5 }
                    thresholds { $r['thresholds']['maximumP95LatencyMs'] = 1 }
                    live-count { $r['records'][0]['Live'] = $false }
                }
                $path = Join-Path $TestDrive 'bad-evaluation.json'
                Write-JsonFile -InputObject $r -Path $path -Depth 16 -Confirm:$false | Out-Null
                { Read-GateEvidence -EvaluationResultPath $path -ReleaseRecord $script:EvidenceRecord -EnvironmentConfig $script:EvidenceConfig } | Should -Throw
            }

            It 'requires passing evaluation when minimum score is declared even without the separate boolean requirement' {
                $definition = @{ environment = 'test'; overlay = @{ deploymentGates = @{
                    requireSmokeTestPass = $false; requireEvaluationPass = $false; minimumEvaluationScore = 0.8
                } } }
                $result = Test-DeploymentGate -Definition $definition -Evidence @{
                    evaluation = [pscustomobject]@{ Executed = 1; Outcome = 'failed'; Score = 1.0 }
                }
                $result.IsSatisfied | Should -BeFalse
            }

            It 'rejects legacy audit-only records and weakened self-declared promotion requirements' {
                $r = $script:PromotionRecord | ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
                $expected = $r['deployment']['attestation']['requiredGates'].Clone()
                $r['deployment']['attestation']['requiredGates']['requireRegressionPass'] = $false
                (Test-ReleaseRecordForPromotion -Record $r -AgentName test-agent -PackageId $r['packageId'] `
                    -SourceEnvironment uat -ExpectedGates $expected).IsValid | Should -BeFalse
                $r['schemaVersion'] = '1.0.0'
                (Test-ReleaseRecordForPromotion -Record $r -AgentName test-agent -PackageId $r['packageId'] `
                    -SourceEnvironment uat -ExpectedGates $expected).IsValid | Should -BeFalse
            }
}
