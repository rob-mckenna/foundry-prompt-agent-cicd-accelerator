@{
    RootModule           = 'FoundryAgentOps.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '8f2a4d16-3b5c-4f0e-9a71-6c2f0d5a81b4'
    Author               = 'foundry-prompt-agent-cicd-accelerator contributors'
    CompanyName          = 'Community'
    Copyright            = 'Copyright (c) Microsoft Corporation. Licensed under the MIT License.'
    Description          = 'Shared helpers for source-controlled Azure AI Foundry prompt agents: manifest resolution, immutable packaging, governance gates, Agent Service data plane calls and release records.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Test-PathSegmentSafe',
    'Test-PathContainedIn',
    'Test-PathHasReparsePoint',
    'Get-PackageInventory',
    'Resolve-ContainedPath',
    'Get-AllowedRuntimeVariable',
    'ConvertTo-CanonicalJson',
    'Test-PackageIdentity',
    'Get-PayloadSummary',
    'Get-DeploymentGate',
    'Test-DeploymentGate',
    'Read-GateEvidence',
    'Test-ChangeRecordId',
    'Get-PackageBlobName',
    'Publish-AgentPackage',
    'Get-AgentPackageFromStore',
    'Find-AgentPackage',
    'Read-ReleaseRecordFile',
    'Test-ReleaseRecordForPromotion',
    'Write-OpsLog',
        'Write-CiSummary',
        'Get-RepositoryRoot',
        'Resolve-RequiredPath',
        'ConvertTo-OrderedHashtable',
        'Read-JsonFile',
        'Write-JsonFile',
    'Write-TextFile',
    'ConvertTo-AbsolutePath',
        'Merge-Hashtable',
        'Get-PlaceholderName',
        'Expand-Placeholder',
        'Test-JsonFileSchema',
        'Test-YamlFile',
        'Test-PowerShellSyntax',
        'Get-EnvironmentConfig',
        'Get-AgentSourceLayout',
        'Resolve-AgentDefinition',
        'ConvertTo-FoundryAgentPayload',
        'Test-AgentGovernance',
        'Get-NormalizedRelativePath',
        'New-ChecksumManifest',
        'Get-PackageId',
        'Test-ChecksumManifest',
        'Read-PackageDescriptor',
        'Expand-AgentPackage',
        'Get-FoundryAccessToken',
        'Invoke-FoundryApi',
        'Test-FoundryEndpoint',
        'Get-FoundryAgent',
    'Invoke-FoundryAgentRun',
        'Resolve-SecretReference',
        'New-ReleaseRecord',
        'Save-ReleaseRecord',
        'Get-LatestReleaseRecord'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Azure', 'AI', 'Foundry', 'Agents', 'CICD', 'DevOps')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/OWNER/foundry-prompt-agent-cicd-accelerator'
        }
    }
}
