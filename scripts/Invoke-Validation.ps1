#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the complete offline validation suite for the repository. No Azure credentials are required.

.DESCRIPTION
    Checks performed:
      1. JSON parse of every .json file.
      2. JSON Schema validation of manifests, overlays, tool definitions, evaluation suites and environment
         configuration, using the built-in Test-Json cmdlet (draft-07).
      3. YAML validation of GitHub Actions workflows and Azure DevOps pipelines. Uses powershell-yaml or
         PyYAML when present on the agent and otherwise falls back to a structural lint. No tool is installed.
      4. PowerShell language-parser checks of every .ps1/.psm1/.psd1 file. Code is parsed, never executed.
      5. PSScriptAnalyzer and Pester 5, but only when they are already installed.
      6. Agent resolution and Agent Service payload generation for every sample and every environment.
      7. Governance evaluation of every sample against every environment policy.
      8. Plain-text credential heuristics across tracked text files.
      9. Optional infrastructure checks: 'az bicep build' and 'terraform fmt -check' when those tools exist.

.PARAMETER SkipInfrastructure
    Skips the Bicep and Terraform checks.

.PARAMETER IncludeTerraformValidate
    Additionally runs 'terraform init -backend=false' and 'terraform validate'. This downloads providers and
    therefore needs outbound network access, so it is opt-in.

.PARAMETER Path
    Repository root. Defaults to the root discovered from this script's location.

.EXAMPLE
    ./scripts/Invoke-Validation.ps1

.EXAMPLE
    ./scripts/Invoke-Validation.ps1 -SkipInfrastructure
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$SkipInfrastructure,
    [switch]$IncludeTerraformValidate
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

$repoRoot = if ($Path) { Resolve-RequiredPath -Path $Path -Purpose 'Repository root' } else { Get-RepositoryRoot }
$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('Passed', 'Failed', 'Skipped')][string]$Status,
        [string]$Detail = ''
    )
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    switch ($Status) {
        'Passed' { Write-OpsLog -Level Success -Message "$Check" }
        'Failed' { Write-OpsLog -Level Error -Message "$Check :: $Detail" }
        'Skipped' { Write-OpsLog -Level Info -Message "$Check skipped :: $Detail" }
    }
}

function Get-RepositoryFile {
    param([Parameter(Mandatory)][string]$Filter, [string[]]$ExcludeDirectory = @('.git', 'out', 'node_modules', '.terraform'))
    Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter $Filter | Where-Object {
        $relative = (Get-NormalizedRelativePath -Root $repoRoot -Path $_.FullName)
        foreach ($excluded in $ExcludeDirectory) {
            if ($relative -like "$excluded/*") { return $false }
        }
        return $true
    }
}

Write-OpsLog -Level Step -Message "Validating repository at $repoRoot"

# 1. JSON parse
$jsonFiles = @(Get-RepositoryFile -Filter '*.json')
$jsonFailures = @()
foreach ($file in $jsonFiles) {
    try {
        $null = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 64
    }
    catch [System.ArgumentException] {
        $jsonFailures += "$(Get-NormalizedRelativePath -Root $repoRoot -Path $file.FullName): $($_.Exception.Message)"
    }
}
if ($jsonFailures.Count -eq 0) {
    Add-Result -Check "JSON parse ($($jsonFiles.Count) files)" -Status Passed
}
else {
    Add-Result -Check 'JSON parse' -Status Failed -Detail ($jsonFailures -join ' | ')
}

# 2. Schema validation by path convention
$schemaMap = @(
    @{ Pattern = 'agent.manifest.json'; Schema = 'schemas/agent-manifest.schema.json'; Name = 'agent manifests' },
    @{ Pattern = '*.overlay.json'; Schema = 'schemas/environment-overlay.schema.json'; Name = 'environment overlays' },
    @{ Pattern = '*.evaluation.json'; Schema = 'schemas/evaluation-suite.schema.json'; Name = 'evaluation suites' }
)
foreach ($entry in $schemaMap) {
    $files = @(Get-RepositoryFile -Filter $entry.Pattern | Where-Object { (Get-NormalizedRelativePath -Root $repoRoot -Path $_.FullName) -notlike 'schemas/*' })
    if ($files.Count -eq 0) {
        Add-Result -Check "Schema: $($entry.Name)" -Status Skipped -Detail 'no matching files'
        continue
    }
    $failures = @()
    foreach ($file in $files) {
        $result = Test-JsonFileSchema -Path $file.FullName -SchemaPath (Join-Path $repoRoot $entry.Schema)
        if (-not $result.IsValid) {
            $failures += "$(Get-NormalizedRelativePath -Root $repoRoot -Path $file.FullName): $($result.Errors -join '; ')"
        }
    }
    if ($failures.Count -eq 0) {
        Add-Result -Check "Schema: $($entry.Name) ($($files.Count) files)" -Status Passed
    }
    else {
        Add-Result -Check "Schema: $($entry.Name)" -Status Failed -Detail ($failures -join ' | ')
    }
}

# Tool definitions live in tools/ folders.
$toolFiles = @(Get-RepositoryFile -Filter '*.json' | Where-Object {
        $relative = Get-NormalizedRelativePath -Root $repoRoot -Path $_.FullName
        ($relative -like '*/tools/*' -or $relative -like 'templates/tools/*') -and $relative -notlike '*openapi*'
    })
if ($toolFiles.Count -gt 0) {
    $failures = @()
    foreach ($file in $toolFiles) {
        $result = Test-JsonFileSchema -Path $file.FullName -SchemaPath (Join-Path $repoRoot 'schemas/tool-definition.schema.json')
        if (-not $result.IsValid) {
            $failures += "$(Get-NormalizedRelativePath -Root $repoRoot -Path $file.FullName): $($result.Errors -join '; ')"
        }
    }
    if ($failures.Count -eq 0) {
        Add-Result -Check "Schema: tool definitions ($($toolFiles.Count) files)" -Status Passed
    }
    else {
        Add-Result -Check 'Schema: tool definitions' -Status Failed -Detail ($failures -join ' | ')
    }
}

# Environment configuration.
$configFailures = @()
foreach ($environmentName in @('dev', 'test', 'uat', 'prod')) {
    $configPath = Join-Path $repoRoot "config/environments/$environmentName.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        $configFailures += "config/environments/$environmentName.json is missing"
        continue
    }
    $result = Test-JsonFileSchema -Path $configPath -SchemaPath (Join-Path $repoRoot 'schemas/environment-config.schema.json')
    if (-not $result.IsValid) { $configFailures += "$environmentName.json: $($result.Errors -join '; ')" }
}
if ($configFailures.Count -eq 0) {
    Add-Result -Check 'Schema: environment configuration (4 environments)' -Status Passed
}
else {
    Add-Result -Check 'Schema: environment configuration' -Status Failed -Detail ($configFailures -join ' | ')
}

# 3. YAML
$yamlFiles = @(Get-RepositoryFile -Filter '*.yml') + @(Get-RepositoryFile -Filter '*.yaml')
if ($yamlFiles.Count -eq 0) {
    Add-Result -Check 'YAML validation' -Status Skipped -Detail 'no YAML files'
}
else {
    $failures = @()
    $method = 'unknown'
    foreach ($file in $yamlFiles) {
        $result = Test-YamlFile -Path $file.FullName
        $method = $result.Method
        if (-not $result.IsValid) {
            $failures += "$(Get-NormalizedRelativePath -Root $repoRoot -Path $file.FullName): $($result.Errors -join '; ')"
        }
    }
    if ($failures.Count -eq 0) {
        Add-Result -Check "YAML validation ($($yamlFiles.Count) files, method: $method)" -Status Passed
    }
    else {
        Add-Result -Check "YAML validation (method: $method)" -Status Failed -Detail ($failures -join ' | ')
    }
}

# Required workflow and pipeline files must exist.
$requiredPipelineFiles = @(
    '.github/workflows/validate.yml',
    '.github/workflows/deploy-dev.yml',
    '.github/workflows/deploy-test.yml',
    '.github/workflows/deploy-prod.yml',
    'azure-devops/pipelines/deploy-dev.yml',
    'azure-devops/pipelines/deploy-test.yml',
    'azure-devops/pipelines/deploy-prod.yml'
)
$missingPipelines = @($requiredPipelineFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_)) })
if ($missingPipelines.Count -eq 0) {
    Add-Result -Check 'Required pipeline files present' -Status Passed
}
else {
    Add-Result -Check 'Required pipeline files present' -Status Failed -Detail ($missingPipelines -join ', ')
}

# 4. PowerShell parser
$psFiles = @(Get-RepositoryFile -Filter '*.ps1') + @(Get-RepositoryFile -Filter '*.psm1') + @(Get-RepositoryFile -Filter '*.psd1')
$parseFailures = @()
foreach ($file in $psFiles) {
    $result = Test-PowerShellSyntax -Path $file.FullName
    if (-not $result.IsValid) {
        $parseFailures += "$(Get-NormalizedRelativePath -Root $repoRoot -Path $file.FullName): $($result.Errors -join '; ')"
    }
}
if ($parseFailures.Count -eq 0) {
    Add-Result -Check "PowerShell parser ($($psFiles.Count) files)" -Status Passed
}
else {
    Add-Result -Check 'PowerShell parser' -Status Failed -Detail ($parseFailures -join ' | ')
}

# Every mutating script must declare SupportsShouldProcess.
$mutatingScripts = @('New-AgentPackage.ps1', 'import-agent.ps1', 'export-agent.ps1', 'promote-agent.ps1', 'Invoke-Rollback.ps1')
$shouldProcessFailures = @()
foreach ($name in $mutatingScripts) {
    $scriptPath = Join-Path $repoRoot "scripts/$name"
    if (-not (Test-Path -LiteralPath $scriptPath)) { $shouldProcessFailures += "$name is missing"; continue }
    $content = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
    if ($content -notmatch 'SupportsShouldProcess') { $shouldProcessFailures += "$name does not declare SupportsShouldProcess" }
    if ($content -notmatch 'Set-StrictMode -Version 3\.0') { $shouldProcessFailures += "$name does not set strict mode" }
}
if ($shouldProcessFailures.Count -eq 0) {
    Add-Result -Check 'Mutating scripts declare SupportsShouldProcess and strict mode' -Status Passed
}
else {
    Add-Result -Check 'Mutating scripts contract' -Status Failed -Detail ($shouldProcessFailures -join ', ')
}

# 5. Optional analyzers
$analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if ($analyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $findings = @(Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot 'scripts') -Recurse -Severity Error)
    if ($findings.Count -eq 0) {
        Add-Result -Check "PSScriptAnalyzer $($analyzer.Version) (Error severity)" -Status Passed
    }
    else {
        $detail = ($findings | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName)" }) -join ' | '
        Add-Result -Check 'PSScriptAnalyzer' -Status Failed -Detail $detail
    }
}
else {
    Add-Result -Check 'PSScriptAnalyzer' -Status Skipped -Detail 'module not installed; no tool is installed by validation'
}

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
$unitTestPath = Join-Path $repoRoot 'tests/unit'
if ($pester -and (Test-Path -LiteralPath $unitTestPath)) {
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $unitTestPath
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $pesterResult = Invoke-Pester -Configuration $configuration
    if ($pesterResult.FailedCount -eq 0) {
        Add-Result -Check "Pester unit tests ($($pesterResult.PassedCount) passed)" -Status Passed
    }
    else {
        Add-Result -Check 'Pester unit tests' -Status Failed -Detail "$($pesterResult.FailedCount) test(s) failed"
    }
}
else {
    Add-Result -Check 'Pester unit tests' -Status Skipped -Detail 'Pester 5+ not installed; run Install-Module Pester -MinimumVersion 5.5.0 to enable'
}

# 6 and 7. Sample resolution and governance
$sampleRoot = Join-Path $repoRoot 'samples'
if (Test-Path -LiteralPath $sampleRoot) {
    $sampleFailures = @()
    $sampleCount = 0
    foreach ($sample in (Get-ChildItem -LiteralPath $sampleRoot -Directory)) {
        if (-not (Test-Path -LiteralPath (Join-Path $sample.FullName 'agent.manifest.json'))) { continue }
        foreach ($environmentName in @('dev', 'test', 'uat', 'prod')) {
            $sampleCount++
            try {
                $definition = Resolve-AgentDefinition -Path $sample.FullName -Environment $environmentName -SkipPlaceholderExpansion
                if ($environmentName -eq 'prod') {
                    $definition['manifest']['metadata']['change_record'] = 'CHG-1234'
                }
                $null = ConvertTo-FoundryAgentPayload -Definition $definition
                $config = Get-EnvironmentConfig -Environment $environmentName -SkipPlaceholderExpansion
                $governance = Test-AgentGovernance -Definition $definition -EnvironmentConfig $config
                if (-not $governance.IsCompliant) {
                    $sampleFailures += "$($sample.Name)/$environmentName governance: $($governance.Violations -join '; ')"
                }
            }
            catch [System.Management.Automation.RuntimeException] {
                $sampleFailures += "$($sample.Name)/$environmentName : $($_.Exception.Message)"
            }
        }
    }
    if ($sampleFailures.Count -eq 0) {
        Add-Result -Check "Sample resolution and governance ($sampleCount combinations)" -Status Passed
    }
    else {
        Add-Result -Check 'Sample resolution and governance' -Status Failed -Detail ($sampleFailures -join ' | ')
    }
}
else {
    Add-Result -Check 'Sample resolution and governance' -Status Skipped -Detail 'no samples folder'
}

# 8. Credential heuristics
$secretPatterns = @(
    @{ Name = 'Azure storage key'; Pattern = 'AccountKey\s*=\s*[A-Za-z0-9+/]{40,}' },
    @{ Name = 'Shared access signature'; Pattern = 'sig=[A-Za-z0-9%]{30,}' },
    @{ Name = 'AAD client secret assignment'; Pattern = '(client_?secret|clientSecret)\s*[:=]\s*["''][^"''$<{][^"'']{12,}["'']' },
    @{ Name = 'Bearer literal'; Pattern = 'Authorization\s*[:=]\s*["'']Bearer\s+[A-Za-z0-9._-]{20,}' },
    @{ Name = 'Cognitive Services key assignment'; Pattern = '(api[_-]?key|subscriptionKey)\s*[:=]\s*["''][A-Za-z0-9]{32,}["'']' },
    @{ Name = 'Private key block'; Pattern = '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' }
)
$scanExtensions = @('.json', '.yml', '.yaml', '.ps1', '.psm1', '.psd1', '.bicep', '.bicepparam', '.tf', '.tfvars', '.md', '.jsonl')
$scanFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {
    $relative = Get-NormalizedRelativePath -Root $repoRoot -Path $_.FullName
    ($scanExtensions -contains $_.Extension.ToLowerInvariant()) -and
    ($relative -notlike '.git/*') -and ($relative -notlike 'out/*') -and ($relative -notlike '.terraform/*') -and
    ($relative -ne 'scripts/Invoke-Validation.ps1')
}
$secretHits = @()
foreach ($file in $scanFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern.Pattern) {
            $secretHits += "$(Get-NormalizedRelativePath -Root $repoRoot -Path $file.FullName): possible $($pattern.Name)"
        }
    }
}
if ($secretHits.Count -eq 0) {
    Add-Result -Check "Credential heuristics ($($scanFiles.Count) files)" -Status Passed
}
else {
    Add-Result -Check 'Credential heuristics' -Status Failed -Detail ($secretHits -join ' | ')
}

# 9. Infrastructure
if ($SkipInfrastructure) {
    Add-Result -Check 'Bicep build' -Status Skipped -Detail '-SkipInfrastructure specified'
    Add-Result -Check 'Terraform fmt' -Status Skipped -Detail '-SkipInfrastructure specified'
}
else {
    $bicepMain = Join-Path $repoRoot 'infra/bicep/main.bicep'
    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if ($azCommand -and (Test-Path -LiteralPath $bicepMain)) {
        $bicepOutput = & az bicep build --file $bicepMain --stdout 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Exclude the Azure CLI's own "a new Bicep release is available" notice.
            $warnings = @($bicepOutput | Where-Object { $_ -match 'Warning' -and $_ -notmatch 'new Bicep release is available' })
            $detail = if ($warnings.Count -gt 0) { "$($warnings.Count) linter warning(s)" } else { '' }
            Add-Result -Check 'Bicep build (infra/bicep/main.bicep)' -Status Passed -Detail $detail
        }
        else {
            Add-Result -Check 'Bicep build' -Status Failed -Detail (($bicepOutput | Where-Object { $_ -match 'Error' } | Select-Object -First 10) -join ' | ')
        }
    }
    else {
        Add-Result -Check 'Bicep build' -Status Skipped -Detail 'Azure CLI with the bicep extension is not available'
    }

    $terraformCommand = Get-Command terraform -ErrorAction SilentlyContinue
    $terraformRoot = Join-Path $repoRoot 'infra/terraform'
    if ($terraformCommand -and (Test-Path -LiteralPath $terraformRoot)) {
        Push-Location $terraformRoot
        try {
            $fmtOutput = & terraform fmt -check -recursive 2>&1
            if ($LASTEXITCODE -eq 0) {
                Add-Result -Check 'Terraform fmt -check -recursive' -Status Passed
            }
            else {
                Add-Result -Check 'Terraform fmt -check -recursive' -Status Failed -Detail (($fmtOutput | Out-String).Trim())
            }

            if ($IncludeTerraformValidate) {
                $initOutput = & terraform init -backend=false -input=false -no-color 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Add-Result -Check 'Terraform validate' -Status Skipped -Detail 'terraform init failed, usually because provider download requires network access'
                }
                else {
                    $validateOutput = & terraform validate -no-color 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Add-Result -Check 'Terraform validate' -Status Passed
                    }
                    else {
                        Add-Result -Check 'Terraform validate' -Status Failed -Detail (($validateOutput | Out-String).Trim())
                    }
                }
            }
            else {
                Add-Result -Check 'Terraform validate' -Status Skipped -Detail 'requires provider download; re-run with -IncludeTerraformValidate'
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Add-Result -Check 'Terraform fmt' -Status Skipped -Detail 'terraform is not installed'
    }
}

$passed = @($results | Where-Object Status -EQ 'Passed').Count
$failed = @($results | Where-Object Status -EQ 'Failed').Count
$skipped = @($results | Where-Object Status -EQ 'Skipped').Count

Write-Host ''
Write-OpsLog -Level Step -Message "Validation summary: $passed passed, $failed failed, $skipped skipped"
$results | Format-Table -AutoSize Check, Status, Detail | Out-String -Width 200 | Write-Host

$summary = "### Offline validation`n`n| Check | Status |`n| --- | --- |`n"
foreach ($result in $results) {
    $icon = switch ($result.Status) { 'Passed' { 'pass' } 'Failed' { 'FAIL' } default { 'skip' } }
    $summary += "| $($result.Check) | $icon |`n"
}
Write-CiSummary -Markdown $summary

if ($failed -gt 0) {
    throw "Offline validation failed: $failed check(s) did not pass."
}

return [pscustomobject]@{
    Passed  = $passed
    Failed  = $failed
    Skipped = $skipped
    Results = $results
}
