#Requires -Version 7.2
<#
.SYNOPSIS
    Builds an immutable, content-addressed deployment package for a Foundry prompt agent.

.DESCRIPTION
    The package is built once, on merge to main, and is then promoted unchanged through DEV, TEST, UAT and
    PROD. Environment differences live in overlays that ship inside the package, so promotion never rebuilds.

    Package layout (foundry-agent-package/1):

        package.json                 Descriptor: package id, agent identity, build provenance, inventory
        checksums.sha256             SHA-256 of every other file, including package.json
        manifest/agent.manifest.json Agent manifest
        manifest/instructions.md     Instruction text (path taken from the manifest)
        manifest/tools/*.json        Tool definitions referenced by the manifest
        environments/<env>.overlay.json
        evaluations/**               Evaluation suites and datasets

    packageId is the SHA-256 of the checksum manifest computed over every file except package.json, so it is
    stable, self-verifying and free of circular references.

.PARAMETER AgentPath
    Folder containing agent.manifest.json and an environments/ folder.

.PARAMETER OutputDirectory
    Folder that receives the .zip package and the staging folder. Created if missing.

.PARAMETER Environment
    Environments whose overlays must be present. Defaults to dev, test, uat and prod.

.PARAMETER SourceCommit
    Git commit SHA recorded in the descriptor. Discovered from git when omitted.

.PARAMETER SkipResolveCheck
    Skips the offline per-environment resolution check. Not recommended.

.EXAMPLE
    ./scripts/New-AgentPackage.ps1 -AgentPath ./samples/simple-agent -OutputDirectory ./out

.EXAMPLE
    ./scripts/New-AgentPackage.ps1 -AgentPath ./samples/rag-agent -OutputDirectory ./out -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AgentPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string[]]$Environment = @('dev', 'test', 'uat', 'prod'),

    [string]$SourceCommit,

    [string[]]$ExcludePattern = @('*.tmp', '*.bak', '.DS_Store', 'Thumbs.db'),

    [switch]$SkipResolveCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

function Get-GitValue {
    param([string[]]$Arguments, [string]$Fallback = 'unknown')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $Fallback }
    $value = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    return ([string]$value).Trim()
}

$agentRoot = Resolve-RequiredPath -Path $AgentPath -Purpose 'Agent source folder'
$layout = Get-AgentSourceLayout -Path $agentRoot
if ($layout.IsPackage) {
    throw "'$agentRoot' already contains package.json. Point -AgentPath at agent source, not at a built package."
}

$manifest = Read-JsonFile -Path $layout.ManifestPath
$agentName = $manifest['name']
$agentVersion = $manifest['version']

Write-OpsLog -Level Step -Message "Packaging agent '$agentName' version $agentVersion from $agentRoot"

foreach ($targetEnv in $Environment) {
    $overlayPath = Join-Path $layout.EnvironmentRoot "$targetEnv.overlay.json"
    if (-not (Test-Path -LiteralPath $overlayPath)) {
        throw "Overlay for environment '$targetEnv' is missing at '$overlayPath'. Every packaged environment needs an explicit overlay so that promotion cannot fall back to defaults."
    }
}

if (-not $SkipResolveCheck) {
    foreach ($targetEnv in $Environment) {
        $definition = Resolve-AgentDefinition -Path $agentRoot -Environment $targetEnv -SkipPlaceholderExpansion
        $null = ConvertTo-FoundryAgentPayload -Definition $definition
        $unresolved = $definition['unresolvedPlaceholders']
        if ($unresolved.Count -gt 0) {
            Write-OpsLog -Level Info -Message "Environment '$targetEnv' defers $($unresolved.Count) placeholder(s) to deploy time: $($unresolved -join ', ')"
        }
        Write-OpsLog -Level Success -Message "Resolution check passed for environment '$targetEnv'."
    }
}

if (-not $SourceCommit) { $SourceCommit = Get-GitValue -Arguments @('rev-parse', 'HEAD') }
$sourceRef = if ($env:GITHUB_REF) { $env:GITHUB_REF }
elseif ($env:BUILD_SOURCEBRANCH) { $env:BUILD_SOURCEBRANCH }
else { Get-GitValue -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') }
$sourceRepository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY }
elseif ($env:BUILD_REPOSITORY_NAME) { $env:BUILD_REPOSITORY_NAME }
else { Get-GitValue -Arguments @('config', '--get', 'remote.origin.url') }
$builder = if ($env:GITHUB_ACTIONS -eq 'true') { 'github-actions' }
elseif ($env:TF_BUILD -eq 'True') { 'azure-pipelines' }
else { 'local' }
$buildRunId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } elseif ($env:BUILD_BUILDID) { $env:BUILD_BUILDID } else { '0' }

$shortCommit = if ($SourceCommit -and $SourceCommit -ne 'unknown') { $SourceCommit.Substring(0, [Math]::Min(7, $SourceCommit.Length)) } else { 'local' }
$packageName = "$agentName-$agentVersion+$shortCommit"

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Create output directory')) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    }
}
$outputResolved = if (Test-Path -LiteralPath $OutputDirectory) { (Resolve-Path -LiteralPath $OutputDirectory).Path } else { $OutputDirectory }
$stagingRoot = Join-Path $outputResolved "$packageName.package"
$zipPath = Join-Path $outputResolved "$packageName.zip"

if (-not $PSCmdlet.ShouldProcess($zipPath, "Build immutable package for '$agentName' $agentVersion")) {
    Write-OpsLog -Level Info -Message "WhatIf: package '$packageName' would be written to $outputResolved"
    return [pscustomobject]@{
        AgentName   = $agentName
        Version     = $agentVersion
        PackageId   = $null
        PackagePath = $zipPath
        StagingPath = $stagingRoot
        WhatIf      = $true
    }
}

if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot 'manifest') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stagingRoot 'environments') | Out-Null

# Copy everything except the environments folder into manifest/ so that manifest-relative tool refs keep working.
$sourceFiles = Get-ChildItem -LiteralPath $agentRoot -Recurse -File | Where-Object {
    $relative = Get-NormalizedRelativePath -Root $agentRoot -Path $_.FullName
    if ($relative -like 'environments/*') { return $false }
    foreach ($pattern in $ExcludePattern) { if ($_.Name -like $pattern) { return $false } }
    return $true
}

$copiedTools = @()
$copiedEvaluations = @()
foreach ($file in $sourceFiles) {
    $relative = Get-NormalizedRelativePath -Root $agentRoot -Path $file.FullName
    $target = Join-Path (Join-Path $stagingRoot 'manifest') $relative
    $targetDirectory = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDirectory)) { New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null }
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    if ($relative -like 'tools/*') { $copiedTools += "manifest/$relative" }
    if ($relative -like 'evaluations/*') { $copiedEvaluations += "manifest/$relative" }
}

foreach ($targetEnv in $Environment) {
    Copy-Item -LiteralPath (Join-Path $layout.EnvironmentRoot "$targetEnv.overlay.json") `
        -Destination (Join-Path $stagingRoot "environments/$targetEnv.overlay.json") -Force
}

$contentManifest = New-ChecksumManifest -Root $stagingRoot -ExcludeRelativePath @('package.json')
$packageId = Get-PackageId -ChecksumManifest $contentManifest

$descriptor = [ordered]@{
    '$schema'     = 'https://github.com/foundry-prompt-agent-cicd-accelerator/schemas/package-descriptor.schema.json'
    schemaVersion = '1.0.0'
    packageFormat = 'foundry-agent-package/1'
    packageId     = $packageId
    agent         = [ordered]@{
        name    = $agentName
        version = $agentVersion
    }
    build         = [ordered]@{
        createdUtc       = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        sourceCommit     = $SourceCommit
        sourceRef        = $sourceRef
        sourceRepository = $sourceRepository
        buildRunId       = [string]$buildRunId
        builder          = $builder
        toolVersion      = '1.0.0'
    }
    contents      = [ordered]@{
        manifest     = 'manifest/agent.manifest.json'
        instructions = "manifest/$($manifest['instructions']['file'])"
        environments = @($Environment)
        tools        = @($copiedTools | Sort-Object)
        evaluations  = @($copiedEvaluations | Sort-Object)
    }
    checksumFile  = 'checksums.sha256'
}
if ($manifest.Contains('displayName')) { $descriptor['agent']['displayName'] = $manifest['displayName'] }
if ($manifest.Contains('owner')) { $descriptor['agent']['owner'] = $manifest['owner'] }
if ($manifest.Contains('classification')) { $descriptor['agent']['classification'] = $manifest['classification'] }

$buildRunUrl = if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
}
elseif ($env:SYSTEM_COLLECTIONURI -and $env:SYSTEM_TEAMPROJECT -and $env:BUILD_BUILDID) {
    "$($env:SYSTEM_COLLECTIONURI.TrimEnd('/'))/$env:SYSTEM_TEAMPROJECT/_build/results?buildId=$env:BUILD_BUILDID"
}
else { $null }
if ($buildRunUrl) { $descriptor['build']['buildRunUrl'] = $buildRunUrl }

Write-JsonFile -InputObject $descriptor -Path (Join-Path $stagingRoot 'package.json') -Depth 16 -Confirm:$false -WhatIf:$false | Out-Null

$descriptor['fileCount'] = (Get-ChildItem -LiteralPath $stagingRoot -Recurse -File).Count
Write-JsonFile -InputObject $descriptor -Path (Join-Path $stagingRoot 'package.json') -Depth 16 -Confirm:$false -WhatIf:$false | Out-Null

$fullManifest = New-ChecksumManifest -Root $stagingRoot
[System.IO.File]::WriteAllText((ConvertTo-AbsolutePath -Path (Join-Path $stagingRoot 'checksums.sha256')), $fullManifest, [System.Text.UTF8Encoding]::new($false))

$descriptorSchema = Join-Path (Get-RepositoryRoot) 'schemas/package-descriptor.schema.json'
$descriptorCheck = Test-JsonFileSchema -Path (Join-Path $stagingRoot 'package.json') -SchemaPath $descriptorSchema
if (-not $descriptorCheck.IsValid) {
    throw "Generated package descriptor failed schema validation: $($descriptorCheck.Errors -join '; ')"
}

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal

$verification = Test-ChecksumManifest -Root $stagingRoot
if (-not $verification.IsValid -or $verification.ContentId -ne $packageId) {
    throw "Self-verification of the freshly built package failed. Expected content id '$packageId', computed '$($verification.ContentId)'."
}

Write-OpsLog -Level Success -Message "Package built: $zipPath"
Write-OpsLog -Level Info -Message "packageId $packageId"
Write-CiSummary -Markdown @"
### Agent package built

| Field | Value |
| --- | --- |
| Agent | ``$agentName`` |
| Version | ``$agentVersion`` |
| Package id | ``$packageId`` |
| Source commit | ``$SourceCommit`` |
| Environments | $($Environment -join ', ') |
| Files | $($descriptor['fileCount']) |
"@

return [pscustomobject]@{
    AgentName   = $agentName
    Version     = $agentVersion
    PackageId   = $packageId
    PackagePath = $zipPath
    StagingPath = $stagingRoot
    FileCount   = $descriptor['fileCount']
    WhatIf      = $false
}
