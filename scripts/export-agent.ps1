#Requires -Version 7.2
<#
.SYNOPSIS
    Exports an agent that already exists in an Azure AI Foundry project into source-control format.

.DESCRIPTION
    Use this once, to bring an agent that was authored in the Azure AI Foundry portal under source control.
    After the first export the repository is the source of truth and changes flow through CI/CD only.

    The export is read-only against Azure. It writes agent.manifest.json, the instruction file, tool
    definitions, an overlay for the source environment and export-notes.md describing anything that needs a
    human decision. Values that are environment specific (connection ids, index names, vector store ids) are
    replaced with ${env:...} placeholders so that the exported agent can be promoted across environments.

    Authentication: sign in first with a workload identity (azure/login@v2 or AzureCLI@2). No credential is
    accepted or written by this script.

.PARAMETER Environment
    Environment to read from.

.PARAMETER AgentName
    Logical agent name. Matches agents tagged with this accelerator's metadata.

.PARAMETER RemoteAgentId
    Agent Service assistant id. Use this for agents that were not created by this accelerator.

.PARAMETER OutputPath
    Folder to create. Must not already contain agent.manifest.json unless -Force is supplied.

.PARAMETER Strict
    Fails instead of writing export notes when a tool cannot be represented exactly.

.EXAMPLE
    ./scripts/export-agent.ps1 -Environment dev -RemoteAgentId asst_0123456789 -OutputPath ./agents/support-agent
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'uat', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidatePattern('^[a-z][a-z0-9-]{2,62}$')]
    [string]$AgentName,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [ValidateNotNullOrEmpty()]
    [string]$RemoteAgentId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [string]$ConfigRoot,

    [switch]$Strict,

    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/FoundryAgentOps/FoundryAgentOps.psd1') -Force

function ConvertTo-KebabCase {
    param([Parameter(Mandatory)][string]$Value)
    $kebab = ($Value -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
    if ($kebab.Length -lt 3) { $kebab = "agent-$kebab" }
    return $kebab.Substring(0, [Math]::Min(63, $kebab.Length))
}

function Get-PropertyOrDefault {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

$config = Get-EnvironmentConfig -Environment $Environment -ConfigRoot $ConfigRoot
$foundry = $config['foundry']
$tenantId = if ($config['azure'].Contains('tenantId')) { [string]$config['azure']['tenantId'] } else { $null }

$accessToken = $null
try {
    $accessToken = Get-FoundryAccessToken -Scope $foundry['tokenScope'] -TenantId $tenantId

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        Write-OpsLog -Level Step -Message "Reading agent $RemoteAgentId from '$Environment'"
        $agent = Get-FoundryAgent -EnvironmentConfig $config -LogicalName '' -KnownAgentId $RemoteAgentId -AccessToken $accessToken
    }
    else {
        Write-OpsLog -Level Step -Message "Searching for managed agent '$AgentName' in '$Environment'"
        $agent = Get-FoundryAgent -EnvironmentConfig $config -LogicalName $AgentName -AccessToken $accessToken
    }

    if (-not $agent) {
        throw "No agent found in project '$($foundry['projectName'])' for the supplied identifier. Agents created outside this accelerator must be exported with -RemoteAgentId."
    }
}
finally {
    if ($accessToken) { $accessToken.Dispose() }
}

$logicalName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $AgentName }
elseif ($agent.metadata -and ($agent.metadata.PSObject.Properties.Name -contains 'logical_name')) { $agent.metadata.logical_name }
else { ConvertTo-KebabCase -Value ([string](Get-PropertyOrDefault -Object $agent -Name 'name' -Default 'exported-agent')) }

$manifestPath = Join-Path $OutputPath 'agent.manifest.json'
if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
    throw "'$manifestPath' already exists. Re-run with -Force to overwrite, or export to a new folder and diff the result."
}

$notes = [System.Collections.Generic.List[string]]::new()
$toolReferences = @()
$toolFiles = @{}

$agentTools = Get-PropertyOrDefault -Object $agent -Name 'tools' -Default @()
$toolResources = Get-PropertyOrDefault -Object $agent -Name 'tool_resources'
$index = 0

foreach ($tool in $agentTools) {
    $index++
    $type = [string]$tool.type
    $id = "$($type -replace '_','-')-$index"
    $definition = [ordered]@{
        '$schema'     = '../../schemas/tool-definition.schema.json'
        schemaVersion = '1.0.0'
        id            = $id
        type          = $type
    }

    switch ($type) {
        'code_interpreter' {
            $definition['config'] = [ordered]@{}
        }
        'file_search' {
            $definition['config'] = [ordered]@{ vectorStoreIds = @('${env:VECTOR_STORE_ID}') }
            $notes.Add("file_search vector store ids were replaced with `${env:VECTOR_STORE_ID}. Bind a real value per environment in the overlay variables map.")
        }
        'azure_ai_search' {
            $indexConfig = $null
            if ($toolResources -and ($toolResources.PSObject.Properties.Name -contains 'azure_ai_search')) {
                $indexes = Get-PropertyOrDefault -Object $toolResources.azure_ai_search -Name 'indexes' -Default @()
                if ($indexes.Count -gt 0) { $indexConfig = $indexes[0] }
            }
            $definition['config'] = [ordered]@{
                connectionId = '${env:SEARCH_CONNECTION_ID}'
                indexName    = [string](Get-PropertyOrDefault -Object $indexConfig -Name 'index_name' -Default '${env:SEARCH_INDEX_NAME}')
                queryType    = [string](Get-PropertyOrDefault -Object $indexConfig -Name 'query_type' -Default 'vector_semantic_hybrid')
                topK         = [int](Get-PropertyOrDefault -Object $indexConfig -Name 'top_k' -Default 5)
            }
            $notes.Add("azure_ai_search connection id was replaced with `${env:SEARCH_CONNECTION_ID} because connection ids are environment specific.")
        }
        'openapi' {
            $spec = Get-PropertyOrDefault -Object $tool.openapi -Name 'spec'
            $specFileName = "$id.openapi.json"
            $toolFiles[$specFileName] = $spec
            $authType = [string](Get-PropertyOrDefault -Object $tool.openapi.auth -Name 'type' -Default 'anonymous')
            $auth = [ordered]@{ type = $authType }
            if ($authType -eq 'connection') { $auth['connectionId'] = '${env:OPENAPI_CONNECTION_ID}' }
            if ($authType -eq 'managed_identity') { $auth['audience'] = '${env:OPENAPI_AUDIENCE}' }
            $definition['config'] = [ordered]@{
                name     = [string](Get-PropertyOrDefault -Object $tool.openapi -Name 'name' -Default $id)
                specFile = $specFileName
                auth     = $auth
            }
        }
        'function' {
            $definition['config'] = [ordered]@{
                name       = [string](Get-PropertyOrDefault -Object $tool.function -Name 'name' -Default $id)
                parameters = (Get-PropertyOrDefault -Object $tool.function -Name 'parameters' -Default ([ordered]@{ type = 'object'; properties = [ordered]@{} }))
            }
            $notes.Add("function tool '$id' requires a client-side handler. Document the handler location in the agent README.")
        }
        'bing_grounding' {
            $definition['config'] = [ordered]@{ connectionId = '${env:BING_CONNECTION_ID}' }
        }
        'mcp' {
            $definition['config'] = [ordered]@{
                serverLabel     = [string](Get-PropertyOrDefault -Object $tool -Name 'server_label' -Default $id)
                serverUrl       = '${env:MCP_SERVER_URL}'
                requireApproval = 'always'
            }
            $notes.Add("mcp server url was replaced with `${env:MCP_SERVER_URL}.")
        }
        default {
            if ($Strict) {
                throw "Tool type '$type' has no export mapping. Re-run without -Strict to emit a stub and finish it by hand."
            }
            $definition['config'] = [ordered]@{}
            $notes.Add("Tool type '$type' has no export mapping. The generated definition is a stub and must be completed manually before it will pass validation.")
        }
    }

    if ($tool.PSObject.Properties.Name -contains 'description' -and $tool.description) {
        $definition['description'] = [string]$tool.description
    }
    $toolFiles["$id.json"] = $definition
    $toolReferences += , ([ordered]@{ ref = "tools/$id.json" })
}

$instructions = [string](Get-PropertyOrDefault -Object $agent -Name 'instructions' -Default '')
if ([string]::IsNullOrWhiteSpace($instructions)) {
    $notes.Add('The exported agent has no instructions. Author instructions.md before deploying.')
    $instructions = '# Instructions' + "`n`n" + 'TODO: author the system instructions for this agent.'
}

$manifest = [ordered]@{
    '$schema'      = '../../schemas/agent-manifest.schema.json'
    schemaVersion  = '1.0.0'
    name           = $logicalName
    version        = '0.1.0'
    displayName    = [string](Get-PropertyOrDefault -Object $agent -Name 'name' -Default $logicalName)
    description    = [string](Get-PropertyOrDefault -Object $agent -Name 'description' -Default "Exported from $Environment on $([DateTime]::UtcNow.ToString('yyyy-MM-dd')).")
    owner          = [ordered]@{
        team    = 'TODO-owning-team'
        contact = 'TODO-distribution-list@example.com'
    }
    classification = [ordered]@{
        dataSensitivity      = 'internal'
        businessCriticality  = 'medium'
        processesPersonalData = $false
    }
    model          = [ordered]@{
        deploymentName = [string](Get-PropertyOrDefault -Object $agent -Name 'model' -Default '${env:MODEL_DEPLOYMENT_NAME}')
    }
    instructions   = [ordered]@{ file = 'instructions.md' }
}

$temperature = Get-PropertyOrDefault -Object $agent -Name 'temperature'
$topP = Get-PropertyOrDefault -Object $agent -Name 'top_p'
if ($null -ne $temperature -or $null -ne $topP) {
    $parameters = [ordered]@{}
    if ($null -ne $temperature) { $parameters['temperature'] = [double]$temperature }
    if ($null -ne $topP) { $parameters['topP'] = [double]$topP }
    $manifest['model']['parameters'] = $parameters
}
if ($toolReferences.Count -gt 0) { $manifest['tools'] = $toolReferences }

$overlay = [ordered]@{
    '$schema'      = '../../../schemas/environment-overlay.schema.json'
    schemaVersion  = '1.0.0'
    environment    = $Environment
    model          = [ordered]@{ deploymentName = [string](Get-PropertyOrDefault -Object $agent -Name 'model' -Default 'gpt-4o-mini') }
    variables      = [ordered]@{}
    deploymentGates = [ordered]@{ requireSmokeTestPass = $true }
}
foreach ($placeholder in (Get-PlaceholderName -InputObject $toolFiles)) {
    $overlay['variables'][$placeholder] = "TODO-set-$($placeholder.ToLowerInvariant())"
}

if (-not $PSCmdlet.ShouldProcess($OutputPath, "Write exported agent source for '$logicalName'")) {
    Write-OpsLog -Level Info -Message "WhatIf: $($toolFiles.Count) tool file(s), manifest, instructions and one overlay would be written."
    return
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutputPath 'environments') | Out-Null
if ($toolFiles.Count -gt 0) { New-Item -ItemType Directory -Force -Path (Join-Path $OutputPath 'tools') | Out-Null }

Write-JsonFile -InputObject $manifest -Path $manifestPath -Depth 24 -Confirm:$false | Out-Null
Write-TextFile -Content $instructions -Path (Join-Path $OutputPath 'instructions.md') -Confirm:$false | Out-Null
Write-JsonFile -InputObject $overlay -Path (Join-Path $OutputPath "environments/$Environment.overlay.json") -Depth 16 -Confirm:$false | Out-Null

foreach ($fileName in $toolFiles.Keys) {
    Write-JsonFile -InputObject $toolFiles[$fileName] -Path (Join-Path $OutputPath "tools/$fileName") -Depth 32 -Confirm:$false | Out-Null
}

$remainingEnvironments = @('dev', 'test', 'uat', 'prod') | Where-Object { $_ -ne $Environment }
$notes.Add("Only the '$Environment' overlay was generated. Create overlays for $($remainingEnvironments -join ', ') before packaging.")
$notes.Add('Set owner.team, owner.contact and classification values, then bump version to 1.0.0.')
$notes.Add('Run ./scripts/Invoke-Validation.ps1 to confirm the exported source passes schema and governance checks.')

$notesContent = "# Export notes`n`nExported from environment ``$Environment`` on $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC.`n`nComplete each item before the first pipeline run.`n`n"
foreach ($note in $notes) { $notesContent += "- $note`n" }
Write-TextFile -Content $notesContent -Path (Join-Path $OutputPath 'export-notes.md') -Confirm:$false | Out-Null

Write-OpsLog -Level Success -Message "Exported '$logicalName' to $OutputPath"
Write-OpsLog -Level Warning -Message "Review export-notes.md: $($notes.Count) item(s) need attention before this agent can be packaged."

return [pscustomobject]@{
    AgentName    = $logicalName
    OutputPath   = (Resolve-Path -LiteralPath $OutputPath).Path
    ToolCount    = $toolReferences.Count
    NoteCount    = $notes.Count
}
