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
        $script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fnd-test-" + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:WorkRoot 'manifest') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkRoot 'manifest/a.txt') -Value 'alpha' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:WorkRoot 'b.txt') -Value 'beta' -NoNewline
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
        $id = Get-PackageId -ChecksumManifest (New-ChecksumManifest -Root $script:WorkRoot)
        $id | Should -Match '^sha256:[a-f0-9]{64}$'
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
        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("fnd-noenv-" + [Guid]::NewGuid().ToString('n'))
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
}

Describe 'Test-AgentGovernance' {
    It 'passes every sample against every environment policy' {
        foreach ($sample in @('simple-agent', 'rag-agent', 'multi-tool-agent')) {
            foreach ($environment in @('dev', 'test', 'uat', 'prod')) {
                $definition = Resolve-AgentDefinition -Path (Join-Path $script:SampleRoot $sample) -Environment $environment -SkipPlaceholderExpansion
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
            agent     = [ordered]@{ name = 'test-agent'; version = '1.0.0' }
        }
        $record = New-ReleaseRecord -Environment prod -PackageDescriptor $descriptor -Operation promote `
            -Outcome succeeded -RemoteAgentId 'asst_test' -SourceEnvironment uat `
            -GateResults @{ validation = 'passed'; smoke = 'passed' }

        $record['releaseId'] | Should -Match '^test-agent-prod-\d{8}T\d{6}Z-a{12}$'
        $record['deployment']['operation'] | Should -Be 'promote'
        $record['deployment']['sourceEnvironment'] | Should -Be 'uat'

        $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("release-" + [Guid]::NewGuid().ToString('n') + '.json')
        try {
            Write-JsonFile -InputObject $record -Path $temporary -Depth 12 -Confirm:$false | Out-Null
            $check = Test-JsonFileSchema -Path $temporary -SchemaPath (Join-Path $script:RepoRoot 'schemas/release-record.schema.json')
            $check.IsValid | Should -BeTrue -Because ($check.Errors -join '; ')
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-EnvironmentConfig' {
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
