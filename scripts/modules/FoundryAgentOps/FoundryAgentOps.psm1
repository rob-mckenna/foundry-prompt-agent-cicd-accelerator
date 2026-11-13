#Requires -Version 7.2
Set-StrictMode -Version 3.0

<#
    FoundryAgentOps
    Shared helpers for source-controlled Azure AI Foundry prompt agents.

    Design rules enforced by this module:
      * No secret value is ever written to output, logs or error messages.
      * Every mutating call supports -WhatIf through the calling script.
      * Data plane calls fail loudly with the HTTP status and Azure error code
        instead of falling back to a guessed behaviour.
#>

$script:ModuleVersion = '1.0.0'
$script:UserAgent = "foundry-prompt-agent-cicd-accelerator/$script:ModuleVersion"
$script:ManagedByTag = 'foundry-prompt-agent-cicd-accelerator'
$script:ValidEnvironments = @('dev', 'test', 'uat', 'prod')

#region Logging

function Write-OpsLog {
    <#
    .SYNOPSIS
        Writes a structured, log-safe message to the host and to the CI step summary when available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')][string]$Level = 'Info'
    )

    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $prefix = switch ($Level) {
        'Success' { '[ OK ]' }
        'Warning' { '[WARN]' }
        'Error' { '[FAIL]' }
        'Step' { '[STEP]' }
        default { '[INFO]' }
    }
    $line = "$stamp $prefix $Message"

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Host $line -ForegroundColor Red }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Step' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

function Write-CiSummary {
    <#
    .SYNOPSIS
        Appends Markdown to the GitHub Actions job summary when running in GitHub Actions. No-op elsewhere.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Markdown)

    $summaryPath = [Environment]::GetEnvironmentVariable('GITHUB_STEP_SUMMARY')
    if ([string]::IsNullOrWhiteSpace($summaryPath)) { return }
    Add-Content -LiteralPath $summaryPath -Value $Markdown -Encoding utf8
}

#endregion

#region Repository and path helpers

function Get-RepositoryRoot {
    <#
    .SYNOPSIS
        Returns the repository root by walking up from this module until a .git directory or LICENSE file is found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$StartPath = $PSScriptRoot)

    $current = (Resolve-Path -LiteralPath $StartPath).Path
    while ($true) {
        if ((Test-Path -LiteralPath (Join-Path $current '.git')) -or
            (Test-Path -LiteralPath (Join-Path $current 'schemas/agent-manifest.schema.json'))) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            throw "Unable to locate the repository root starting from '$StartPath'. Run the script from inside a clone of the accelerator."
        }
        $current = $parent
    }
}

function Resolve-RequiredPath {
    <#
    .SYNOPSIS
        Resolves a path and throws an actionable error when it does not exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Purpose not found at '$Path'."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

#endregion

#region Data shaping

function ConvertTo-OrderedHashtable {
    <#
    .SYNOPSIS
        Recursively converts PSCustomObject graphs (for example ConvertFrom-Json output) into ordered hashtables.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $result[[string]$key] = ConvertTo-OrderedHashtable -InputObject $InputObject[$key]
            }
            return $result
        }

        if ($InputObject -is [string]) { return $InputObject }

        if ($InputObject -is [System.Collections.IEnumerable]) {
            $items = @()
            foreach ($item in $InputObject) { $items += , (ConvertTo-OrderedHashtable -InputObject $item) }
            return , $items
        }

        if ($InputObject -is [psobject] -and $InputObject.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject') {
            $result = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $result[$prop.Name] = ConvertTo-OrderedHashtable -InputObject $prop.Value
            }
            return $result
        }

        return $InputObject
    }
}

function Read-JsonFile {
    <#
    .SYNOPSIS
        Reads a JSON file into an ordered hashtable with a clear error when the document is malformed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-RequiredPath -Path $Path -Purpose 'JSON file'
    $raw = Get-Content -LiteralPath $resolved -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "JSON file '$resolved' is empty."
    }
    try {
        $parsed = $raw | ConvertFrom-Json -Depth 64
    }
    catch [System.ArgumentException] {
        throw "JSON file '$resolved' is not valid JSON: $($_.Exception.Message)"
    }
    return ConvertTo-OrderedHashtable -InputObject $parsed
}

function ConvertTo-AbsolutePath {
    <#
    .SYNOPSIS
        Returns an absolute filesystem path resolved against the PowerShell location.
    .DESCRIPTION
        .NET file APIs resolve relative paths against [Environment]::CurrentDirectory, which PowerShell does
        not update on Set-Location. Every raw System.IO write in this repository goes through this helper so
        that a relative -Path behaves the way the caller expects.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Write-JsonFile {
    <#
    .SYNOPSIS
        Writes an object as UTF-8 (no BOM) JSON with a trailing newline so that checksums are stable across platforms.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 32
    )

    $json = ($InputObject | ConvertTo-Json -Depth $Depth).Replace("`r`n", "`n").TrimEnd() + "`n"
    if ($PSCmdlet.ShouldProcess($Path, 'Write JSON file')) {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        [System.IO.File]::WriteAllText((ConvertTo-AbsolutePath -Path $Path), $json, [System.Text.UTF8Encoding]::new($false))
    }
    return $Path
}

function Write-TextFile {
    <#
    .SYNOPSIS
        Writes text as UTF-8 (no BOM) with LF endings and a single trailing newline.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Write text file')) {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        $normalised = $Content.Replace("`r`n", "`n").TrimEnd() + "`n"
        [System.IO.File]::WriteAllText((ConvertTo-AbsolutePath -Path $Path), $normalised, [System.Text.UTF8Encoding]::new($false))
    }
    return $Path
}

function Merge-Hashtable {
    <#
    .SYNOPSIS
        Deep-merges Override into a copy of Base. Scalars and arrays in Override replace Base values.
    .DESCRIPTION
        Array replacement (rather than concatenation) is deliberate: overlays must be able to shrink a list,
        and targeted list edits are expressed through keyed override maps such as toolOverrides.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Base,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Override
    )

    if ($null -eq $Base) { return $Override }
    if ($null -eq $Override) { return $Base }

    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }

    foreach ($key in $Override.Keys) {
        $overrideValue = $Override[$key]
        if ($result.Contains($key) -and
            $result[$key] -is [System.Collections.IDictionary] -and
            $overrideValue -is [System.Collections.IDictionary]) {
            $result[$key] = Merge-Hashtable -Base $result[$key] -Override $overrideValue
        }
        else {
            $result[$key] = $overrideValue
        }
    }
    return $result
}

#endregion

#region Safe path resolution

function Test-PathSegmentSafe {
    <#
    .SYNOPSIS
        Returns $true when a package-relative reference contains no traversal, rooting or stream syntax.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) { return $false }
    if ($Reference -match '[\x00-\x1f]') { return $false }
    if ([System.IO.Path]::IsPathRooted($Reference)) { return $false }
    if ($Reference -match '^[A-Za-z]:') { return $false }
    if ($Reference -match '^[\\/]{2}') { return $false }
    # Alternate data streams and device paths.
    if ($Reference -match ':') { return $false }
    if ($Reference -match '^\\\\\?\\') { return $false }

    foreach ($segment in ($Reference -split '[\\/]+')) {
        if ($segment -eq '' -or $segment -eq '.') { continue }
        if ($segment -eq '..') { return $false }
        # Trailing dots and spaces are stripped by Win32 and can be used to alias a different file.
        if ($segment -ne $segment.TrimEnd('. ')) { return $false }
    }
    return $true
}

function Test-PathContainedIn {
    <#
    .SYNOPSIS
        Separator-aware containment test between two absolute paths.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($separator, '/') + $separator
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    return $candidateFull.StartsWith($rootFull, $comparison)
}

function Test-PathHasReparsePoint {
    <#
    .SYNOPSIS
        Returns $true when the path or any ancestor under Root is a symlink, junction or other reparse point.
    .DESCRIPTION
        A package is untrusted input. A symlink inside it could point at a file outside the verified content,
        so the whole ancestor chain between Root and the target is checked.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($separator, '/')
    $current = [System.IO.Path]::GetFullPath($Path)

    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $true }
        }
        if ($current.TrimEnd($separator, '/') -eq $rootFull) { break }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Get-PackageInventory {
    <#
    .SYNOPSIS
        Reads checksums.sha256 into a map of package-relative path to SHA-256 hash.
    .DESCRIPTION
        The inventory is the authoritative list of files that were verified. Any reference from the manifest,
        a tool definition or an evaluation suite must resolve to a member of this inventory, so a package
        cannot pull in a file that was never covered by the integrity check.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [string]$ChecksumFileName = 'checksums.sha256'
    )

    $manifestPath = Join-Path $PackageRoot $ChecksumFileName
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @{} }

    $inventory = @{}
    foreach ($line in (Get-Content -LiteralPath $manifestPath -Encoding utf8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<hash>[a-f0-9]{64})\s\s(?<path>.+)$') {
            throw "Malformed checksum line in '$manifestPath': $line"
        }
        $inventory[$Matches['path']] = $Matches['hash']
    }
    return $inventory
}

function Resolve-ContainedPath {
    <#
    .SYNOPSIS
        Safely resolves a reference declared inside a package or agent source folder.
    .DESCRIPTION
        Applies, in order: syntax rejection (rooted, traversal, stream, device, trailing dot or space),
        canonical separator-aware containment under ContainmentRoot, reparse point rejection across the
        ancestor chain, existence, and - when an inventory is supplied - membership of the verified checksum
        inventory. Any failure throws with the offending reference named.
    .PARAMETER Reference
        The relative reference exactly as written in the manifest, tool definition or suite.
    .PARAMETER BasePath
        Directory the reference is relative to.
    .PARAMETER ContainmentRoot
        Outer boundary the resolved path must stay inside, normally the package root.
    .PARAMETER Inventory
        Optional inventory from Get-PackageInventory. When supplied, the resolved file must be a member.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$ContainmentRoot,
        [hashtable]$Inventory,
        [string]$Purpose = 'Packaged file'
    )

    if (-not (Test-PathSegmentSafe -Reference $Reference)) {
        throw "$Purpose reference '$Reference' is not a safe package-relative path. Absolute paths, drive or UNC roots, '..' traversal, alternate data streams and trailing dot or space segments are rejected."
    }

    $rootFull = [System.IO.Path]::GetFullPath($ContainmentRoot)
    $combined = [System.IO.Path]::GetFullPath((Join-Path $BasePath $Reference))

    if (-not (Test-PathContainedIn -Root $rootFull -Candidate $combined)) {
        throw "$Purpose reference '$Reference' resolves outside the package boundary. Refusing to read '$combined'."
    }

    if (Test-PathHasReparsePoint -Root $rootFull -Path $combined) {
        throw "$Purpose reference '$Reference' traverses a symbolic link or junction inside the package. Refusing to follow it."
    }

    if (-not (Test-Path -LiteralPath $combined -PathType Leaf)) {
        throw "$Purpose reference '$Reference' does not exist at '$combined'."
    }

    if ($PSBoundParameters.ContainsKey('Inventory') -and $null -ne $Inventory -and $Inventory.Count -gt 0) {
        $relative = Get-NormalizedRelativePath -Root $rootFull -Path $combined
        if (-not $Inventory.ContainsKey($relative)) {
            throw "$Purpose reference '$Reference' resolves to '$relative', which is not listed in the verified checksum inventory. Only files covered by checksums.sha256 may be read from a package."
        }
    }

    return $combined
}

#endregion

#region Placeholder expansion

function Get-PlaceholderName {
    <#
    .SYNOPSIS
        Returns every distinct ${env:NAME} placeholder found in an object graph.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowNull()]$InputObject)

    $found = [System.Collections.Generic.HashSet[string]]::new()

    function Get-Inner {
        param($Node)
        if ($null -eq $Node) { return }
        if ($Node -is [string]) {
            foreach ($m in [regex]::Matches($Node, '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}')) {
                [void]$found.Add($m.Groups[1].Value)
            }
            return
        }
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) { Get-Inner -Node $Node[$key] }
            return
        }
        if ($Node -is [System.Collections.IEnumerable]) {
            foreach ($item in $Node) { Get-Inner -Node $item }
        }
    }

    Get-Inner -Node $InputObject
    return , @($found)
}

function Expand-Placeholder {
    <#
    .SYNOPSIS
        Replaces ${env:NAME} placeholders using an explicit, closed variable map.
    .DESCRIPTION
        There is deliberately no fallback to the process environment. A CI agent's environment contains
        tokens, connection strings and other secrets; allowing an arbitrary ${env:NAME} in a packaged file to
        read it would let a package exfiltrate CI credentials into an agent definition. Callers must build
        the variable map from the overlay plus the names the environment configuration explicitly allows.

        Expansion is iterative (bounded to five passes) so that a variable whose value itself contains a
        placeholder resolves fully.
    .PARAMETER Variables
        The complete, closed set of names that may be substituted.
    .PARAMETER AllowUnresolved
        When set, unresolved placeholders are left intact instead of raising an error. Used by offline validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [hashtable]$Variables = @{},
        [switch]$AllowUnresolved,
        [int]$MaxPasses = 5
    )

    $unresolved = [System.Collections.Generic.HashSet[string]]::new()
    $counter = [pscustomobject]@{ Replacements = 0 }

    function Resolve-One {
        param([string]$Name)
        if ($Variables.ContainsKey($Name)) { return [string]$Variables[$Name] }
        [void]$unresolved.Add($Name)
        return $null
    }

    function Expand-Inner {
        param($Node)
        if ($null -eq $Node) { return $null }
        if ($Node -is [string]) {
            return [regex]::Replace($Node, '\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}', {
                    param($m)
                    $value = Resolve-One -Name $m.Groups[1].Value
                    if ($null -eq $value) { return $m.Value }
                    $counter.Replacements++
                    return $value
                })
        }
        if ($Node -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($key in $Node.Keys) { $out[$key] = Expand-Inner -Node $Node[$key] }
            return $out
        }
        if ($Node -is [System.Collections.IEnumerable]) {
            $items = @()
            foreach ($item in $Node) { $items += , (Expand-Inner -Node $item) }
            return , $items
        }
        return $Node
    }

    $expanded = $InputObject
    for ($pass = 0; $pass -lt $MaxPasses; $pass++) {
        $unresolved.Clear()
        $counter.Replacements = 0
        $expanded = Expand-Inner -Node $expanded
        if ($counter.Replacements -eq 0) { break }
    }

    if ($unresolved.Count -gt 0 -and -not $AllowUnresolved) {
        $names = ($unresolved | Sort-Object) -join ', '
        throw "Unresolved configuration placeholders: $names. Declare each name in the overlay 'variables' map, or in the target environment's runtime.allowedVariables allowlist and supply it with -RuntimeVariable. Values are never read from the process environment implicitly. See docs/environment-management.md."
    }

    return [pscustomobject]@{
        Value      = $expanded
        Unresolved = @($unresolved | Sort-Object)
    }
}

function Get-AllowedRuntimeVariable {
    <#
    .SYNOPSIS
        Builds the closed runtime variable map for an environment from its allowlist.
    .DESCRIPTION
        Only names listed in the environment configuration's runtime.allowedVariables are considered, and
        each is taken from -RuntimeVariable first, then from the process environment. Names that look like
        credentials are rejected outright so that an allowlist cannot be used to smuggle a secret into an
        agent definition or a log.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [hashtable]$RuntimeVariable = @{}
    )

    $allowed = @()
    if ($EnvironmentConfig.Contains('runtime') -and $EnvironmentConfig['runtime'] -and $EnvironmentConfig['runtime'].Contains('allowedVariables')) {
        $allowed = @($EnvironmentConfig['runtime']['allowedVariables'])
    }

    $secretLike = '(?i)(secret|password|passwd|pwd|credential|apikey|api_key|accesskey|access_key|token|connectionstring|connection_string|sas)'
    $result = @{}

    foreach ($name in $allowed) {
        if ($name -match $secretLike) {
            throw "Environment '$($EnvironmentConfig['environment'])' lists '$name' in runtime.allowedVariables, but the name looks like a credential. Secrets must be declared in the overlay 'secretRefs' block as a Key Vault reference, never expanded into an agent definition."
        }
        if ($RuntimeVariable.ContainsKey($name)) {
            $result[$name] = [string]$RuntimeVariable[$name]
            continue
        }
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $result[$name] = $value }
    }

    foreach ($name in $RuntimeVariable.Keys) {
        if ($allowed -notcontains $name) {
            throw "Runtime variable '$name' was supplied but is not listed in runtime.allowedVariables for environment '$($EnvironmentConfig['environment'])'. Add it to the environment configuration through the governance change process."
        }
    }

    return $result
}

#endregion

#region Schema validation

function Test-JsonFileSchema {
    <#
    .SYNOPSIS
        Validates a JSON file against a draft-07 schema using the built-in Test-Json cmdlet.
    .OUTPUTS
        PSCustomObject with Path, Schema, IsValid and Errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath
    )

    $resolved = Resolve-RequiredPath -Path $Path -Purpose 'JSON document'
    $schemaResolved = Resolve-RequiredPath -Path $SchemaPath -Purpose 'JSON schema'
    $json = Get-Content -LiteralPath $resolved -Raw -Encoding utf8
    $schema = Get-Content -LiteralPath $schemaResolved -Raw -Encoding utf8

    $errors = @()
    $isValid = $false
    try {
        $isValid = Test-Json -Json $json -Schema $schema -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        throw
    }
    catch {
        $isValid = $false
        $errors += $_.Exception.Message
    }

    return [pscustomobject]@{
        Path     = $resolved
        Schema   = $schemaResolved
        IsValid  = [bool]$isValid
        Errors   = $errors
    }
}

function Test-YamlFile {
    <#
    .SYNOPSIS
        Validates a YAML file offline.
    .DESCRIPTION
        Uses the richest parser available on the agent, in order:
          1. powershell-yaml module (full parse)
          2. python with PyYAML (full parse)
          3. built-in structural lint (tabs, indentation steps, duplicate sibling keys, unterminated quotes)
        The chosen method is reported so that CI logs show the strength of the check.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-RequiredPath -Path $Path -Purpose 'YAML document'
    $errors = @()

    if (Get-Module -ListAvailable -Name 'powershell-yaml') {
        Import-Module powershell-yaml -ErrorAction Stop
        try {
            $null = ConvertFrom-Yaml (Get-Content -LiteralPath $resolved -Raw -Encoding utf8) -AllDocuments
            return [pscustomobject]@{ Path = $resolved; IsValid = $true; Method = 'powershell-yaml'; Errors = @() }
        }
        catch {
            return [pscustomobject]@{ Path = $resolved; IsValid = $false; Method = 'powershell-yaml'; Errors = @($_.Exception.Message) }
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($python) {
        $script = 'import sys,yaml' + "`n" +
        'p=sys.argv[1]' + "`n" +
        'try:' + "`n" +
        '    list(yaml.safe_load_all(open(p, encoding="utf-8")))' + "`n" +
        'except ModuleNotFoundError:' + "`n" +
        '    sys.exit(3)' + "`n" +
        'except Exception as ex:' + "`n" +
        '    print(str(ex)); sys.exit(1)'
        $output = & $python.Source '-c' $script $resolved 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            return [pscustomobject]@{ Path = $resolved; IsValid = $true; Method = 'pyyaml'; Errors = @() }
        }
        if ($code -eq 1) {
            return [pscustomobject]@{ Path = $resolved; IsValid = $false; Method = 'pyyaml'; Errors = @(($output | Out-String).Trim()) }
        }
        # exit code 3 means PyYAML is unavailable; fall through to the structural lint.
    }

    $lines = Get-Content -LiteralPath $resolved -Encoding utf8
    $indentStack = [System.Collections.Generic.Stack[int]]::new()
    $keysByIndent = @{}
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -match "^\t") { $errors += "Line ${lineNumber}: tab character used for indentation."; continue }
        $indent = ($line.Length - $line.TrimStart(' ').Length)
        $trimmed = $line.TrimStart(' ')

        while ($indentStack.Count -gt 0 -and $indentStack.Peek() -gt $indent) {
            $dropped = $indentStack.Pop()
            $keysByIndent.Remove($dropped) | Out-Null
        }
        if ($indentStack.Count -eq 0 -or $indentStack.Peek() -lt $indent) { $indentStack.Push($indent) }

        $quoteCount = ([regex]::Matches($trimmed, '(?<!\\)"')).Count
        if ($quoteCount % 2 -ne 0 -and $trimmed -notmatch '#') {
            $errors += "Line ${lineNumber}: unbalanced double quote."
        }

        if ($trimmed -match '^(?<key>[A-Za-z0-9_.$-]+)\s*:(\s|$)') {
            $key = $Matches['key']
            if (-not $keysByIndent.ContainsKey($indent)) { $keysByIndent[$indent] = [System.Collections.Generic.HashSet[string]]::new() }
            if (-not $keysByIndent[$indent].Add($key)) {
                $errors += "Line ${lineNumber}: duplicate key '$key' at the same indentation level."
            }
        }
    }

    return [pscustomobject]@{
        Path    = $resolved
        IsValid = ($errors.Count -eq 0)
        Method  = 'structural-lint'
        Errors  = $errors
    }
}

function Test-PowerShellSyntax {
    <#
    .SYNOPSIS
        Parses a PowerShell file with the language parser and returns any syntax errors. No code is executed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-RequiredPath -Path $Path -Purpose 'PowerShell file'
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$parseErrors)

    $messages = @()
    foreach ($e in $parseErrors) {
        $messages += "Line $($e.Extent.StartLineNumber): $($e.Message)"
    }

    return [pscustomobject]@{
        Path    = $resolved
        IsValid = ($messages.Count -eq 0)
        Errors  = $messages
    }
}

#endregion

#region Environment configuration

function Get-EnvironmentConfig {
    <#
    .SYNOPSIS
        Loads and validates the configuration for a target environment.
    .PARAMETER Environment
        dev, test, uat or prod.
    .PARAMETER ConfigRoot
        Directory containing <environment>.json. Defaults to <repo>/config/environments.
    .PARAMETER SkipPlaceholderExpansion
        Leaves ${env:...} placeholders in place. Used by offline validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'uat', 'prod')][string]$Environment,
        [string]$ConfigRoot,
        [hashtable]$RuntimeVariable = @{},
        [switch]$SkipPlaceholderExpansion
    )

    $repoRoot = Get-RepositoryRoot
    if (-not $ConfigRoot) { $ConfigRoot = Join-Path $repoRoot 'config/environments' }

    $configPath = Join-Path $ConfigRoot "$Environment.json"
    $resolved = Resolve-RequiredPath -Path $configPath -Purpose "Environment configuration for '$Environment'"

    $schemaPath = Join-Path $repoRoot 'schemas/environment-config.schema.json'
    $schemaResult = Test-JsonFileSchema -Path $resolved -SchemaPath $schemaPath
    if (-not $schemaResult.IsValid) {
        throw "Environment configuration '$resolved' failed schema validation: $($schemaResult.Errors -join '; ')"
    }

    $config = Read-JsonFile -Path $resolved
    if ($config['environment'] -ne $Environment) {
        throw "Environment configuration '$resolved' declares environment '$($config['environment'])' but was loaded as '$Environment'."
    }

    if (-not $SkipPlaceholderExpansion) {
        $variables = Get-AllowedRuntimeVariable -EnvironmentConfig $config -RuntimeVariable $RuntimeVariable
        $config = (Expand-Placeholder -InputObject $config -Variables $variables).Value
    }

    $config['_sourcePath'] = $resolved
    return $config
}

#endregion

#region Agent definition resolution

function Get-AgentSourceLayout {
    <#
    .SYNOPSIS
        Describes the files that make up an agent source folder or an extracted package.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $root = Resolve-RequiredPath -Path $Path -Purpose 'Agent source folder'

    $manifestCandidates = @(
        (Join-Path $root 'agent.manifest.json'),
        (Join-Path $root 'manifest/agent.manifest.json')
    )
    $manifestPath = $manifestCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $manifestPath) {
        throw "No agent.manifest.json found under '$root' (looked in the root and in manifest/)."
    }

    return [pscustomobject]@{
        Root            = $root
        ManifestPath    = (Resolve-Path -LiteralPath $manifestPath).Path
        ManifestRoot    = (Split-Path -Parent (Resolve-Path -LiteralPath $manifestPath).Path)
        EnvironmentRoot = (Join-Path $root 'environments')
        IsPackage       = (Test-Path -LiteralPath (Join-Path $root 'package.json'))
    }
}

function Resolve-AgentDefinition {
    <#
    .SYNOPSIS
        Produces the effective agent definition for one environment by merging manifest, overlay and tool definitions.
    .DESCRIPTION
        The result is deployment-ready but contains no secret values. Key Vault references stay symbolic until
        Resolve-SecretReference is called by the deployment script with the pipeline workload identity.

        Every file reference is resolved through Resolve-ContainedPath, so a package cannot read a file
        outside its own verified content. When the source is a built package, references must also be members
        of the checksum inventory.

        Placeholder expansion uses a closed variable map: the overlay 'variables' block plus whatever the
        caller supplies in -RuntimeVariable. There is no fallback to the process environment.
    .PARAMETER Path
        Agent source folder or extracted package folder.
    .PARAMETER Environment
        Target environment whose overlay is applied.
    .PARAMETER RuntimeVariable
        Additional allowlisted values, normally produced by Get-AllowedRuntimeVariable.
    .PARAMETER SkipPlaceholderExpansion
        Leaves ${env:...} placeholders unresolved (offline validation).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'uat', 'prod')][string]$Environment,
        [hashtable]$RuntimeVariable = @{},
        [switch]$SkipPlaceholderExpansion
    )

    $repoRoot = Get-RepositoryRoot
    $layout = Get-AgentSourceLayout -Path $Path

    # Containment boundary: the package root for a built package, otherwise the agent source folder.
    $containmentRoot = [System.IO.Path]::GetFullPath($layout.Root)
    $inventory = if ($layout.IsPackage) { Get-PackageInventory -PackageRoot $containmentRoot } else { @{} }

    $manifest = Read-JsonFile -Path $layout.ManifestPath
    $schemaResult = Test-JsonFileSchema -Path $layout.ManifestPath -SchemaPath (Join-Path $repoRoot 'schemas/agent-manifest.schema.json')
    if (-not $schemaResult.IsValid) {
        throw "Agent manifest '$($layout.ManifestPath)' failed schema validation: $($schemaResult.Errors -join '; ')"
    }

    $overlayPath = Join-Path $layout.EnvironmentRoot "$Environment.overlay.json"
    if (-not (Test-Path -LiteralPath $overlayPath)) {
        throw "No overlay found for environment '$Environment' at '$overlayPath'. Every environment must have an explicit overlay, even if it only restates defaults."
    }
    $overlayResult = Test-JsonFileSchema -Path $overlayPath -SchemaPath (Join-Path $repoRoot 'schemas/environment-overlay.schema.json')
    if (-not $overlayResult.IsValid) {
        throw "Environment overlay '$overlayPath' failed schema validation: $($overlayResult.Errors -join '; ')"
    }
    $overlay = Read-JsonFile -Path $overlayPath
    if ($overlay['environment'] -ne $Environment) {
        throw "Overlay '$overlayPath' declares environment '$($overlay['environment'])'."
    }

    # Closed variable map: overlay values first, then caller-supplied allowlisted runtime values.
    $variables = @{}
    if ($overlay.Contains('variables') -and $overlay['variables']) {
        foreach ($key in $overlay['variables'].Keys) { $variables[$key] = [string]$overlay['variables'][$key] }
    }
    foreach ($key in $RuntimeVariable.Keys) { $variables[$key] = [string]$RuntimeVariable[$key] }

    # Merge model and metadata sections from the overlay onto the manifest.
    $effective = Merge-Hashtable -Base $manifest -Override ([ordered]@{})
    if ($overlay.Contains('model') -and $overlay['model']) {
        $effective['model'] = Merge-Hashtable -Base $manifest['model'] -Override $overlay['model']
    }
    if ($overlay.Contains('metadata') -and $overlay['metadata']) {
        $baseMetadata = if ($manifest.Contains('metadata') -and $manifest['metadata']) { $manifest['metadata'] } else { [ordered]@{} }
        $effective['metadata'] = Merge-Hashtable -Base $baseMetadata -Override $overlay['metadata']
    }

    # Instructions.
    $instructionsResolved = Resolve-ContainedPath -Reference $manifest['instructions']['file'] `
        -BasePath $layout.ManifestRoot -ContainmentRoot $containmentRoot -Inventory $inventory `
        -Purpose 'Agent instructions file'
    $instructions = (Get-Content -LiteralPath $instructionsResolved -Raw -Encoding utf8).Replace("`r`n", "`n").TrimEnd()
    $maxLength = 256000
    if ($manifest['instructions'].Contains('maxLength')) { $maxLength = [int]$manifest['instructions']['maxLength'] }
    if ($instructions.Length -gt $maxLength) {
        throw "Instructions file '$instructionsResolved' is $($instructions.Length) characters which exceeds the declared maxLength of $maxLength."
    }

    # Tools.
    $tools = @()
    $toolSchemaPath = Join-Path $repoRoot 'schemas/tool-definition.schema.json'
    $manifestTools = if ($manifest.Contains('tools') -and $manifest['tools']) { $manifest['tools'] } else { @() }
    foreach ($toolRef in $manifestTools) {
        $toolResolved = Resolve-ContainedPath -Reference $toolRef['ref'] -BasePath $layout.ManifestRoot `
            -ContainmentRoot $containmentRoot -Inventory $inventory `
            -Purpose 'Tool definition referenced by the manifest'
        $toolSchemaResult = Test-JsonFileSchema -Path $toolResolved -SchemaPath $toolSchemaPath
        if (-not $toolSchemaResult.IsValid) {
            throw "Tool definition '$toolResolved' failed schema validation: $($toolSchemaResult.Errors -join '; ')"
        }
        $tool = Read-JsonFile -Path $toolResolved
        $tool['_sourcePath'] = $toolResolved

        $enabled = $true
        if ($toolRef.Contains('enabled')) { $enabled = [bool]$toolRef['enabled'] }

        if ($overlay.Contains('toolOverrides') -and $overlay['toolOverrides'] -and $overlay['toolOverrides'].Contains($tool['id'])) {
            $override = $overlay['toolOverrides'][$tool['id']]
            if ($override.Contains('enabled')) { $enabled = [bool]$override['enabled'] }
            if ($override.Contains('config') -and $override['config']) {
                $baseConfig = if ($tool.Contains('config') -and $tool['config']) { $tool['config'] } else { [ordered]@{} }
                $tool['config'] = Merge-Hashtable -Base $baseConfig -Override $override['config']
            }
        }

        $tool['_enabled'] = $enabled
        $tools += , $tool
    }

    $unknownOverrides = @()
    if ($overlay.Contains('toolOverrides') -and $overlay['toolOverrides']) {
        $knownIds = @($tools | ForEach-Object { $_['id'] })
        foreach ($key in $overlay['toolOverrides'].Keys) {
            if ($knownIds -notcontains $key) { $unknownOverrides += $key }
        }
    }
    if ($unknownOverrides.Count -gt 0) {
        throw "Overlay '$overlayPath' contains toolOverrides for unknown tool ids: $($unknownOverrides -join ', ')."
    }

    # Evaluation suite reference must resolve safely when declared.
    $evaluationSuitePath = $null
    if ($manifest.Contains('evaluations') -and $manifest['evaluations'] -and $manifest['evaluations'].Contains('suiteFile')) {
        $evaluationSuitePath = Resolve-ContainedPath -Reference $manifest['evaluations']['suiteFile'] `
            -BasePath $layout.ManifestRoot -ContainmentRoot $containmentRoot -Inventory $inventory `
            -Purpose 'Evaluation suite declared by the manifest'
        $suiteCheck = Test-JsonFileSchema -Path $evaluationSuitePath -SchemaPath (Join-Path $repoRoot 'schemas/evaluation-suite.schema.json')
        if (-not $suiteCheck.IsValid) {
            throw "Evaluation suite '$evaluationSuitePath' failed schema validation: $($suiteCheck.Errors -join '; ')"
        }
    }

    $definition = [ordered]@{
        manifest            = $effective
        instructions        = $instructions
        tools               = @($tools | Where-Object { $_['_enabled'] })
        disabledTools       = @($tools | Where-Object { -not $_['_enabled'] } | ForEach-Object { $_['id'] })
        overlay             = $overlay
        environment         = $Environment
        sourceRoot          = $layout.Root
        manifestRoot        = $layout.ManifestRoot
        containmentRoot     = $containmentRoot
        isPackage           = $layout.IsPackage
        evaluationSuitePath = $evaluationSuitePath
    }

    $expansion = Expand-Placeholder -InputObject $definition -Variables $variables -AllowUnresolved:$SkipPlaceholderExpansion
    $resolvedDefinition = $expansion.Value
    $resolvedDefinition['unresolvedPlaceholders'] = $expansion.Unresolved
    $resolvedDefinition['inventory'] = $inventory
    return $resolvedDefinition
}

#endregion

#region Agent Service payload

function ConvertTo-FoundryAgentPayload {
    <#
    .SYNOPSIS
        Converts a resolved agent definition into an Azure AI Foundry Agent Service create/update payload.
    .DESCRIPTION
        Field names follow the Agent Service data plane contract (snake_case). Tool payload shapes are
        documented in docs/deployment-patterns.md. Unsupported tool types raise an error rather than being
        silently dropped, so that a mis-typed tool never reaches production as a missing capability.

        Every secondary file the payload pulls in (OpenAPI specification, response format schema) is resolved
        through Resolve-ContainedPath against the package boundary and, for a built package, must be a member
        of the verified checksum inventory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $manifest = $Definition['manifest']
    $containmentRoot = if ($Definition.Contains('containmentRoot') -and $Definition['containmentRoot']) {
        $Definition['containmentRoot']
    }
    else { $Definition['manifestRoot'] }
    $inventory = if ($Definition.Contains('inventory') -and $Definition['inventory']) { $Definition['inventory'] } else { @{} }

    $payload = [ordered]@{
        model        = $manifest['model']['deploymentName']
        name         = $manifest['name']
        instructions = $Definition['instructions']
    }

    if ($manifest.Contains('description') -and $manifest['description']) {
        $payload['description'] = $manifest['description']
    }

    if ($manifest['model'].Contains('parameters') -and $manifest['model']['parameters']) {
        $modelParams = $manifest['model']['parameters']
        if ($modelParams.Contains('temperature')) { $payload['temperature'] = [double]$modelParams['temperature'] }
        if ($modelParams.Contains('topP')) { $payload['top_p'] = [double]$modelParams['topP'] }
    }

    if ($manifest['model'].Contains('responseFormat') -and $manifest['model']['responseFormat']) {
        $rf = $manifest['model']['responseFormat']
        switch ($rf['type']) {
            'text' { $payload['response_format'] = [ordered]@{ type = 'text' } }
            'json_object' { $payload['response_format'] = [ordered]@{ type = 'json_object' } }
            'json_schema' {
                if (-not $rf.Contains('jsonSchemaFile')) {
                    throw "responseFormat.type is json_schema but jsonSchemaFile is not set in the manifest."
                }
                $schemaFile = Resolve-ContainedPath -Reference $rf['jsonSchemaFile'] -BasePath $Definition['manifestRoot'] `
                    -ContainmentRoot $containmentRoot -Inventory $inventory -Purpose 'Response format JSON schema'
                $schemaObject = Read-JsonFile -Path $schemaFile
                $payload['response_format'] = [ordered]@{
                    type   = 'json_schema'
                    name   = $manifest['name']
                    strict = $true
                    schema = $schemaObject
                }
            }
            default { throw "Unsupported responseFormat.type '$($rf['type'])'." }
        }
    }

    $toolList = @()
    $toolResources = [ordered]@{}

    foreach ($tool in $Definition['tools']) {
        if (-not $tool['_enabled']) { continue }
        $config = if ($tool.Contains('config') -and $tool['config']) { $tool['config'] } else { [ordered]@{} }

        switch ($tool['type']) {
            'code_interpreter' {
                $toolList += , ([ordered]@{ type = 'code_interpreter' })
                if ($config.Contains('fileIds') -and $config['fileIds']) {
                    $toolResources['code_interpreter'] = [ordered]@{ file_ids = @($config['fileIds']) }
                }
            }
            'file_search' {
                $toolList += , ([ordered]@{ type = 'file_search' })
                $toolResources['file_search'] = [ordered]@{ vector_store_ids = @($config['vectorStoreIds']) }
            }
            'azure_ai_search' {
                $toolList += , ([ordered]@{ type = 'azure_ai_search' })
                $index = [ordered]@{
                    index_connection_id = $config['connectionId']
                    index_name          = $config['indexName']
                }
                if ($config.Contains('queryType')) { $index['query_type'] = $config['queryType'] }
                if ($config.Contains('topK')) { $index['top_k'] = [int]$config['topK'] }
                if ($config.Contains('filter')) { $index['filter'] = $config['filter'] }
                if (-not $toolResources.Contains('azure_ai_search')) {
                    $toolResources['azure_ai_search'] = [ordered]@{ indexes = @() }
                }
                $toolResources['azure_ai_search']['indexes'] += , $index
            }
            'openapi' {
                $specPath = Resolve-ContainedPath -Reference $config['specFile'] `
                    -BasePath (Split-Path -Parent $tool['_sourcePath']) -ContainmentRoot $containmentRoot `
                    -Inventory $inventory -Purpose "OpenAPI specification for tool '$($tool['id'])'"
                $spec = Read-JsonFile -Path $specPath
                $auth = switch ($config['auth']['type']) {
                    'anonymous' { [ordered]@{ type = 'anonymous' } }
                    'connection' { [ordered]@{ type = 'connection'; security_scheme = [ordered]@{ connection_id = $config['auth']['connectionId'] } } }
                    'managed_identity' { [ordered]@{ type = 'managed_identity'; security_scheme = [ordered]@{ audience = $config['auth']['audience'] } } }
                    default { throw "Unsupported OpenAPI auth type '$($config['auth']['type'])' on tool '$($tool['id'])'." }
                }
                $openApi = [ordered]@{
                    name = $config['name']
                    spec = $spec
                    auth = $auth
                }
                if ($tool.Contains('description') -and $tool['description']) { $openApi['description'] = $tool['description'] }
                $toolList += , ([ordered]@{ type = 'openapi'; openapi = $openApi })
            }
            'function' {
                $function = [ordered]@{
                    name       = $config['name']
                    parameters = $config['parameters']
                }
                if ($tool.Contains('description') -and $tool['description']) { $function['description'] = $tool['description'] }
                $toolList += , ([ordered]@{ type = 'function'; function = $function })
            }
            'azure_function' {
                $function = [ordered]@{
                    name       = $config['name']
                    parameters = $config['parameters']
                }
                if ($tool.Contains('description') -and $tool['description']) { $function['description'] = $tool['description'] }
                $toolList += , ([ordered]@{
                        type           = 'azure_function'
                        azure_function = [ordered]@{
                            function       = $function
                            input_binding  = [ordered]@{
                                type          = 'storage_queue'
                                storage_queue = [ordered]@{
                                    queue_service_endpoint = $config['inputQueue']['storageServiceEndpoint']
                                    queue_name             = $config['inputQueue']['queueName']
                                }
                            }
                            output_binding = [ordered]@{
                                type          = 'storage_queue'
                                storage_queue = [ordered]@{
                                    queue_service_endpoint = $config['outputQueue']['storageServiceEndpoint']
                                    queue_name             = $config['outputQueue']['queueName']
                                }
                            }
                        }
                    })
            }
            'bing_grounding' {
                $searchConfig = [ordered]@{ connection_id = $config['connectionId'] }
                if ($config.Contains('count')) { $searchConfig['count'] = [int]$config['count'] }
                if ($config.Contains('market')) { $searchConfig['market'] = $config['market'] }
                if ($config.Contains('setLang')) { $searchConfig['set_lang'] = $config['setLang'] }
                $toolList += , ([ordered]@{
                        type           = 'bing_grounding'
                        bing_grounding = [ordered]@{ search_configurations = @($searchConfig) }
                    })
            }
            'mcp' {
                $mcp = [ordered]@{
                    type         = 'mcp'
                    server_label = $config['serverLabel']
                    server_url   = $config['serverUrl']
                }
                if ($config.Contains('allowedTools') -and $config['allowedTools']) {
                    $mcp['allowed_tools'] = @($config['allowedTools'])
                }
                if ($config.Contains('requireApproval')) {
                    if ($config['requireApproval'] -notin @('always', 'never')) {
                        throw "Unsupported MCP requireApproval '$($config['requireApproval'])' on tool '$($tool['id'])'."
                    }
                    $mcp['require_approval'] = $config['requireApproval']
                }
                $toolList += , $mcp
            }
            default {
                throw "Tool '$($tool['id'])' has unsupported type '$($tool['type'])'. Extend ConvertTo-FoundryAgentPayload before using it."
            }
        }
    }

    if ($toolList.Count -gt 0) { $payload['tools'] = $toolList }
    if ($toolResources.Count -gt 0) { $payload['tool_resources'] = $toolResources }

    # Agent Service metadata values must be strings.
    $metadata = [ordered]@{
        managed_by     = $script:ManagedByTag
        logical_name   = $manifest['name']
        agent_version  = $manifest['version']
        environment    = $Definition['environment']
    }
    if ($manifest.Contains('metadata') -and $manifest['metadata']) {
        foreach ($key in $manifest['metadata'].Keys) { $metadata[$key] = [string]$manifest['metadata'][$key] }
    }
    if ($manifest.Contains('owner') -and $manifest['owner']) {
        $metadata['owner_team'] = [string]$manifest['owner']['team']
    }
    if ($metadata.Count -gt 16) {
        throw "Agent metadata has $($metadata.Count) entries. Agent Service allows at most 16 key/value pairs."
    }
    $payload['metadata'] = $metadata

    return $payload
}

function Get-PayloadSummary {
    <#
    .SYNOPSIS
        Produces a structural, non-disclosing summary of an Agent Service payload.
    .DESCRIPTION
        -WhatIf must let an operator confirm the shape of a change without printing resolved values. Resolved
        values can contain connection ids, index names and other tenant topology, and instruction text is
        long enough to hide a change in review. This emits field presence, counts, lengths and SHA-256
        digests instead of the values themselves.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Payload)

    function Get-Digest {
        param([string]$Value)
        if ($null -eq $Value) { return 'none' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Value)) }
        finally { $sha.Dispose() }
        return 'sha256:' + ((($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16))
    }

    $summary = [ordered]@{
        model             = $Payload['model']
        name              = $Payload['name']
        instructionLength = ([string]$Payload['instructions']).Length
        instructionDigest = Get-Digest -Value ([string]$Payload['instructions'])
    }
    foreach ($key in @('temperature', 'top_p')) {
        if ($Payload.Contains($key)) { $summary[$key] = $Payload[$key] }
    }
    if ($Payload.Contains('response_format')) {
        $summary['responseFormat'] = if ($Payload['response_format'] -is [string]) { $Payload['response_format'] } else { $Payload['response_format']['type'] }
    }

    $toolSummaries = @()
    if ($Payload.Contains('tools')) {
        foreach ($tool in $Payload['tools']) {
            $entry = [ordered]@{ type = $tool['type'] }
            switch ($tool['type']) {
                'openapi' { $entry['operationName'] = $tool['openapi']['name']; $entry['specDigest'] = Get-Digest -Value (ConvertTo-CanonicalJson -InputObject $tool['openapi']['spec']); $entry['authType'] = $tool['openapi']['auth']['type'] }
                'function' { $entry['functionName'] = $tool['function']['name'] }
                'azure_function' { $entry['functionName'] = $tool['azure_function']['function']['name'] }
                'mcp' { $entry['serverLabel'] = $tool['server_label']; $entry['serverUrl'] = '[redacted]' }
                default { }
            }
            $toolSummaries += , $entry
        }
    }
    $summary['tools'] = $toolSummaries
    $summary['toolCount'] = $toolSummaries.Count

    if ($Payload.Contains('tool_resources')) {
        $resources = [ordered]@{}
        foreach ($key in $Payload['tool_resources'].Keys) {
            switch ($key) {
                'azure_ai_search' {
                    $indexes = @()
                    foreach ($index in $Payload['tool_resources']['azure_ai_search']['indexes']) {
                        $indexes += , [ordered]@{
                            indexName       = $index['index_name']
                            connectionIdSet = -not [string]::IsNullOrWhiteSpace([string]$index['index_connection_id'])
                            queryType       = $(if ($index.Contains('query_type')) { $index['query_type'] } else { 'default' })
                            topK            = $(if ($index.Contains('top_k')) { $index['top_k'] } else { 'default' })
                        }
                    }
                    $resources['azure_ai_search'] = $indexes
                }
                'file_search' { $resources['file_search'] = [ordered]@{ vectorStoreCount = @($Payload['tool_resources']['file_search']['vector_store_ids']).Count } }
                default { $resources[$key] = 'present' }
            }
        }
        $summary['toolResources'] = $resources
    }

    if ($Payload.Contains('metadata')) {
        $summary['metadataKeys'] = @($Payload['metadata'].Keys | Sort-Object)
        $summary['metadata'] = [ordered]@{}
        foreach ($key in @('managed_by', 'logical_name', 'agent_version', 'environment', 'change_record')) {
            if ($Payload['metadata'].Contains($key)) { $summary['metadata'][$key] = $Payload['metadata'][$key] }
        }
    }

    $summary['payloadDigest'] = Get-Digest -Value (ConvertTo-CanonicalJson -InputObject $Payload)
    return $summary
}

#endregion

#region Deployment gates

function Get-DeploymentGate {
    <#
    .SYNOPSIS
        Returns the effective gate requirements for an environment from the packaged overlay.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $gates = @{
        requireEvaluationPass  = $false
        requireSmokeTestPass   = $true
        requireRegressionPass  = $false
        minimumEvaluationScore = $null
    }

    $overlay = $Definition['overlay']
    if ($overlay.Contains('deploymentGates') -and $overlay['deploymentGates']) {
        $declared = $overlay['deploymentGates']
        foreach ($key in @('requireEvaluationPass', 'requireSmokeTestPass', 'requireRegressionPass')) {
            if ($declared.Contains($key)) { $gates[$key] = [bool]$declared[$key] }
        }
        if ($declared.Contains('minimumEvaluationScore')) { $gates['minimumEvaluationScore'] = [double]$declared['minimumEvaluationScore'] }
    }
    return $gates
}

function Test-DeploymentGate {
    <#
    .SYNOPSIS
        Enforces the gate requirements declared in the packaged overlay against actual test evidence.
    .DESCRIPTION
        A required gate is only satisfied by evidence of a real, non-empty run. Specifically:
          * a missing or 'skipped' result for a required gate is a failure, never a pass;
          * a result that reports zero executed records or checks is a failure;
          * an evaluation pass rate below minimumEvaluationScore is a failure.
        This is what stops a deployment from being attested as successful because its tests did not run.
    .PARAMETER Evidence
        Map of gate name to a result object with at least Executed (int) and Outcome ('passed'/'failed').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition,
        [Parameter(Mandatory)][hashtable]$Evidence
    )

    $gates = Get-DeploymentGate -Definition $Definition
    $environment = $Definition['environment']
    $violations = @()
    $results = [ordered]@{}

    $requirementMap = @{
        smoke      = $gates['requireSmokeTestPass']
        evaluation = ($gates['requireEvaluationPass'] -or $null -ne $gates['minimumEvaluationScore'])
        regression = $gates['requireRegressionPass']
    }

    foreach ($gateName in @('smoke', 'evaluation', 'regression')) {
        $required = [bool]$requirementMap[$gateName]
        $entry = if ($Evidence.ContainsKey($gateName)) { $Evidence[$gateName] } else { $null }

        if (-not $required) {
            $results[$gateName] = if ($null -eq $entry) { 'skipped' } else { [string]$entry.Outcome }
            continue
        }

        if ($null -eq $entry) {
            $violations += "Gate '$gateName' is required in '$environment' but no result was supplied."
            $results[$gateName] = 'failed'
            continue
        }
        if ([string]$entry.Outcome -eq 'skipped') {
            $violations += "Gate '$gateName' is required in '$environment' but reported 'skipped'. A required gate cannot be skipped."
            $results[$gateName] = 'failed'
            continue
        }
        if ([int]$entry.Executed -le 0) {
            $violations += "Gate '$gateName' is required in '$environment' but executed 0 cases. An empty run is not a pass."
            $results[$gateName] = 'failed'
            continue
        }
        if ([string]$entry.Outcome -ne 'passed') {
            $violations += "Gate '$gateName' is required in '$environment' and reported '$($entry.Outcome)'."
            $results[$gateName] = 'failed'
            continue
        }
        $results[$gateName] = 'passed'
    }

    if ($null -ne $gates['minimumEvaluationScore']) {
        $entry = if ($Evidence.ContainsKey('evaluation')) { $Evidence['evaluation'] } else { $null }
        if ($null -eq $entry -or $null -eq $entry.Score) {
            $violations += "Environment '$environment' declares minimumEvaluationScore $($gates['minimumEvaluationScore']) but no evaluation score was supplied."
        }
        elseif ([double]$entry.Score -lt [double]$gates['minimumEvaluationScore']) {
            $violations += "Evaluation score $($entry.Score) is below the '$environment' minimum of $($gates['minimumEvaluationScore'])."
        }
    }

    return [pscustomobject]@{
        Environment  = $environment
        Required     = $gates
        GateResults  = $results
        IsSatisfied  = ($violations.Count -eq 0)
        Violations   = $violations
    }
}

function Read-GateEvidence {
    <#
    .SYNOPSIS
        Reads the result files produced by the smoke, evaluation and regression runners into gate evidence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$SmokeResultPath,
        [string]$EvaluationResultPath,
        [string]$RegressionResultPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ReleaseRecord,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig
    )

    $evidence = @{}
    $paths = @{ smoke = $SmokeResultPath; evaluation = $EvaluationResultPath; regression = $RegressionResultPath }
    foreach ($gate in @('smoke', 'evaluation', 'regression')) {
        $path = $paths[$gate]
        if (-not $path) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Supplied $gate evidence file is missing: $path" }
        $result = Read-JsonFile -Path $path
        Assert-GateEnvelope -Envelope $result -Record $ReleaseRecord -EnvironmentConfig $EnvironmentConfig -Gate $gate
        foreach ($counter in @('passed', 'failed', 'liveExecuted')) {
            if (($result[$counter] -isnot [int] -and $result[$counter] -isnot [long]) -or $result[$counter] -lt 0) {
                throw "$gate evidence counter '$counter' must be a nonnegative integer."
            }
        }
        $items = @($result[$(@{ smoke = 'checks'; evaluation = 'records'; regression = 'cases' }[$gate])])
        $passed = 0; $failed = 0; $skipped = 0; $live = 0; $livePassed = 0
        foreach ($item in $items) {
            if ($item -isnot [System.Collections.IDictionary] -or $item['Live'] -isnot [bool]) {
                throw "$gate item lacks an explicit boolean Live marker."
            }
            if ($gate -eq 'smoke') {
                switch ($item['Result']) {
                    'passed' { $passed++; $ok = $true }
                    'failed' { $failed++; $ok = $false }
                    'skipped' { $skipped++; $ok = $false }
                    default { throw 'Invalid smoke item result.' }
                }
            }
            else {
                if ($item['Passed'] -isnot [bool]) { throw "$gate item Passed must be boolean." }
                $ok = $item['Passed']
                if ($ok) { $passed++ } else { $failed++ }
            }
            if ($item['Live']) {
                $live++
                if ($ok) {
                    if ($item['Status'] -cne 'completed' -or
                        [string]::IsNullOrWhiteSpace([string]$item['ResponseId']) -or
                        [string]::IsNullOrWhiteSpace([string]$item['ConversationId'])) {
                        throw "$gate passing live item has no completed Responses call with IDs."
                    }
                    $livePassed++
                }
            }
        }
        if ($passed -ne $result['passed'] -or $failed -ne $result['failed'] -or $live -ne $result['liveExecuted']) {
            throw "$gate evidence totals do not match detailed items."
        }
        if ($gate -eq 'smoke') {
            if (($result['skipped'] -isnot [int] -and $result['skipped'] -isnot [long]) -or $result['skipped'] -ne $skipped) { throw 'Smoke skipped counter is inconsistent.' }
            if ($livePassed -le 0) { throw 'Smoke evidence has no successful live canary.' }
        }
        elseif (($result['total'] -isnot [int] -and $result['total'] -isnot [long]) -or
            $result['total'] -ne $items.Count -or $live -ne $items.Count -or $live -le 0) {
            throw "$gate requires liveExecuted=total>0."
        }
        $score = $null
        $thresholdsMet = $true
        if ($gate -eq 'evaluation') {
            $score = $result['passRate']
            if ($score -isnot [double] -and $score -isnot [int] -and $score -isnot [decimal]) { throw 'Evaluation passRate must be numeric.' }
            if (-not [double]::IsFinite([double]$score) -or $score -lt 0 -or $score -gt 1 -or
                [Math]::Abs($score - [Math]::Round($passed / $items.Count, 4)) -gt 0.00001) { throw 'Evaluation passRate is inconsistent.' }
            $thresholds = $result['thresholds']
            if ($thresholds -isnot [System.Collections.IDictionary] -or $result['thresholdsMet'] -isnot [bool]) { throw 'Evaluation thresholds and boolean thresholdsMet are required.' }
            $minimum = $thresholds['minimumPassRate']
            if (($minimum -isnot [double] -and $minimum -isnot [int] -and $minimum -isnot [decimal]) -or
                -not [double]::IsFinite([double]$minimum) -or $minimum -lt 0 -or $minimum -gt 1) { throw 'Invalid minimumPassRate.' }
            $latencies = @($items | ForEach-Object {
                if (($_['LatencyMs'] -isnot [int] -and $_['LatencyMs'] -isnot [long]) -or $_['LatencyMs'] -lt 0) { throw 'Invalid live latency.' }
                $_['LatencyMs']
            } | Sort-Object)
            $p95 = $latencies[[int][Math]::Ceiling($latencies.Count * 0.95) - 1]
            if ($result['p95LatencyMs'] -ne $p95) { throw 'Evaluation p95 does not match detailed items.' }
            $thresholdsMet = $score -ge $minimum
            foreach ($bound in @('maximumFailures', 'maximumP95LatencyMs')) {
                if ($thresholds.Contains($bound)) {
                    if (($thresholds[$bound] -isnot [int] -and $thresholds[$bound] -isnot [long]) -or $thresholds[$bound] -lt 0) { throw "Invalid $bound." }
                    $actual = if ($bound -eq 'maximumFailures') { $failed } else { $p95 }
                    $thresholdsMet = $thresholdsMet -and ($actual -le $thresholds[$bound])
                }
            }
            if ($result['thresholdsMet'] -ne $thresholdsMet) { throw 'Evaluation thresholdsMet is inconsistent.' }
        }
        $envelope = [ordered]@{}
        foreach ($key in @('schemaVersion', 'gate', 'mode', 'releaseId', 'packageId', 'agentName', 'environment', 'projectEndpoint', 'agentVersion', 'serviceVersion', 'startedUtc', 'executedUtc', 'liveExecuted')) {
            $envelope[$key] = $result[$key]
        }
        $evidence[$gate] = [pscustomobject]@{
            Executed = $passed + $failed
            Outcome = if ($failed -gt 0 -or -not $thresholdsMet) { 'failed' } else { 'passed' }
            Score = $score; Source = $path; Envelope = $envelope
            ResultSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $evidence
}

function Assert-GateEnvelope {
    param(
        [System.Collections.IDictionary]$Envelope,
        [System.Collections.IDictionary]$Record,
        [System.Collections.IDictionary]$EnvironmentConfig,
        [string]$Gate
    )
    $expected = @{
        schemaVersion = '1.1.0'; gate = $Gate; mode = 'live'
        releaseId = $Record['releaseId']; packageId = $Record['packageId']
        agentName = $Record['agent']['name']; environment = $Record['environment']
        agentVersion = $Record['agent']['version']; serviceVersion = $Record['agent']['serviceVersion']
    }
    foreach ($key in $expected.Keys) {
        if ($Envelope[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($expected[$key]) -or $Envelope[$key] -cne $expected[$key]) {
            throw "$Gate evidence identity '$key' does not match this live release."
        }
    }
    $endpoint = $EnvironmentConfig['foundry']['projectEndpoint'].TrimEnd('/').ToLowerInvariant()
    if ($Envelope['projectEndpoint'] -isnot [string] -or
        $Envelope['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -cne $endpoint -or
        $Record['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -cne $endpoint) { throw "$Gate evidence project endpoint mismatch." }
    foreach ($key in @('startedUtc', 'executedUtc')) {
        # ConvertFrom-Json on newer PowerShell versions materializes ISO strings as DateTime.
        if ($Envelope[$key] -is [DateTime] -and $Envelope[$key].Kind -eq [DateTimeKind]::Utc) {
            $Envelope[$key] = $Envelope[$key].ToString('o')
        }
        if ($Envelope[$key] -isnot [string] -or $Envelope[$key] -notmatch 'Z$') { throw "$Gate $key must be a UTC timestamp." }
    }
    $start = [DateTimeOffset]::Parse($Envelope['startedUtc'])
    $finish = [DateTimeOffset]::Parse($Envelope['executedUtc'])
    $activationValue = $Record['deployment']['runtimeMutation']['completedAtUtc']
    if ($activationValue -is [DateTime]) { $activationValue = $activationValue.ToString('o') }
    $activation = [DateTimeOffset]::Parse($activationValue)
    if ($start -lt $activation -or $finish -lt $start -or $finish -gt [DateTimeOffset]::UtcNow) {
        throw "$Gate evidence is stale, future-dated, or has invalid UTC ordering."
    }
    if (($Envelope['liveExecuted'] -isnot [int] -and $Envelope['liveExecuted'] -isnot [long]) -or $Envelope['liveExecuted'] -le 0) {
        throw "$Gate evidence requires at least one live invocation."
    }
}

function Test-ChangeRecordId {
    <#
    .SYNOPSIS
        Validates a change record id and rejects placeholder values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Value,
        [string]$Pattern = '^[A-Za-z]{2,5}-[0-9]{4,10}$'
    )

    $problems = @()
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $problems += 'no change record id was supplied'
    }
    elseif ($Value -notmatch $Pattern) {
        $problems += "change record id '$Value' does not match the required pattern $Pattern"
    }
    elseif ($Value -match '^[A-Za-z]{2,5}-0+$') {
        $problems += "change record id '$Value' is a placeholder. Supply the real approved change record at run time."
    }

    return [pscustomobject]@{
        IsValid  = ($problems.Count -eq 0)
        Problems = $problems
    }
}

#endregion

#region Governance

function Test-AgentGovernance {
    <#
    .SYNOPSIS
        Evaluates an agent definition against the governance policy of the target environment.
    .OUTPUTS
        PSCustomObject with IsCompliant and Violations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig
    )

    $violations = @()
    $manifest = $Definition['manifest']
    $policy = $EnvironmentConfig['governance']
    $environment = $EnvironmentConfig['environment']

    $sensitivityRank = @{ 'public' = 0; 'internal' = 1; 'confidential' = 2; 'highly-confidential' = 3 }

    if ($policy['requireOwnerMetadata'] -eq $true) {
        if (-not $manifest.Contains('owner') -or -not $manifest['owner'] -or -not $manifest['owner']['team']) {
            $violations += "Manifest is missing owner.team but the '$environment' policy requires owner metadata."
        }
    }

    if ($manifest.Contains('classification') -and $manifest['classification']) {
        $declared = $manifest['classification']['dataSensitivity']
        $max = $policy['maxDataSensitivity']
        if ($sensitivityRank[$declared] -gt $sensitivityRank[$max]) {
            $violations += "Agent data sensitivity '$declared' exceeds the maximum '$max' allowed in '$environment'."
        }
        if ($policy.Contains('requireResponsibleAiReview') -and $policy['requireResponsibleAiReview'] -eq $true) {
            if (-not $manifest['classification'].Contains('responsibleAiReviewId') -or
                [string]::IsNullOrWhiteSpace([string]$manifest['classification']['responsibleAiReviewId'])) {
                $violations += "Environment '$environment' requires classification.responsibleAiReviewId to be set."
            }
        }
    }
    elseif ($policy['maxDataSensitivity'] -ne 'highly-confidential') {
        $violations += "Manifest has no classification block; '$environment' policy cannot be evaluated."
    }

    if ($policy.Contains('requiredMetadataKeys') -and $policy['requiredMetadataKeys']) {
        $metadata = if ($manifest.Contains('metadata') -and $manifest['metadata']) { $manifest['metadata'] } else { [ordered]@{} }
        foreach ($key in $policy['requiredMetadataKeys']) {
            if (-not $metadata.Contains($key)) {
                $violations += "Required metadata key '$key' is missing for environment '$environment'."
                continue
            }
            if ($key -eq 'change_record') {
                $pattern = if ($policy.Contains('changeRecordPattern')) { [string]$policy['changeRecordPattern'] } else { '^[A-Za-z]{2,5}-[0-9]{4,10}$' }
                $check = Test-ChangeRecordId -Value ([string]$metadata[$key]) -Pattern $pattern
                if (-not $check.IsValid) {
                    $violations += "Environment '$environment' requires a real change record: $($check.Problems -join '; ')."
                }
            }
        }
    }

    if ($policy.Contains('maxTemperature') -and $manifest['model'].Contains('parameters') -and $manifest['model']['parameters']) {
        if ($manifest['model']['parameters'].Contains('temperature')) {
            $temperature = [double]$manifest['model']['parameters']['temperature']
            if ($temperature -gt [double]$policy['maxTemperature']) {
                $violations += "Model temperature $temperature exceeds the '$environment' maximum of $($policy['maxTemperature'])."
            }
        }
    }

    foreach ($tool in $Definition['tools']) {
        if (-not $tool['_enabled']) { continue }
        if ($policy['allowedToolTypes'] -notcontains $tool['type']) {
            $violations += "Tool '$($tool['id'])' of type '$($tool['type'])' is not in the allowed tool list for '$environment'."
        }
        if ($tool.Contains('governance') -and $tool['governance']) {
            if ($tool['governance'].Contains('allowedEnvironments') -and $tool['governance']['allowedEnvironments']) {
                if ($tool['governance']['allowedEnvironments'] -notcontains $environment) {
                    $violations += "Tool '$($tool['id'])' declares allowedEnvironments that exclude '$environment'."
                }
            }
        }
    }

    return [pscustomobject]@{
        Environment  = $environment
        IsCompliant  = ($violations.Count -eq 0)
        Violations   = $violations
    }
}

#endregion

#region Checksums and packaging

function Get-NormalizedRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' is outside the package root '$Root'."
    }
    return $full.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
}

function New-ChecksumManifest {
    <#
    .SYNOPSIS
        Creates a deterministic sha256 manifest for every file under Root except the manifest itself.
    .PARAMETER ExcludeRelativePath
        Additional package-relative paths to omit. Used to compute the content id without package.json,
        which itself carries the resulting content id and would otherwise be self-referential.
    .PARAMETER PackageFormat
        Strict /1 preserves the original culture-sensitive path order. Format /2 uses ordinal ordering.
    .OUTPUTS
        The manifest content as a single string with LF line endings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ChecksumFileName = 'checksums.sha256',
        [string[]]$ExcludeRelativePath = @(),
        [ValidateSet('foundry-agent-package/1', 'foundry-agent-package/2')]
        [string]$PackageFormat = 'foundry-agent-package/2'
    )

    $rootResolved = Resolve-RequiredPath -Path $Root -Purpose 'Package root'
    $lines = @()
    $files = @(Get-ChildItem -LiteralPath $rootResolved -Recurse -File |
    Where-Object { $_.Name -ne $ChecksumFileName } |
    Where-Object { $ExcludeRelativePath -notcontains (Get-NormalizedRelativePath -Root $rootResolved -Path $_.FullName) })
    if ($PackageFormat -eq 'foundry-agent-package/1') {
        $files = @($files | Sort-Object { Get-NormalizedRelativePath -Root $rootResolved -Path $_.FullName })
    }
    $paths = [string[]]@($files | ForEach-Object { Get-NormalizedRelativePath -Root $rootResolved -Path $_.FullName })
    if ($PackageFormat -eq 'foundry-agent-package/2') {
        [Array]::Sort($paths, [StringComparer]::Ordinal)
    }

    foreach ($relative in $paths) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $rootResolved $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$hash  $relative"
    }

    return (($lines -join "`n") + "`n")
}

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
        Produces a deterministic JSON rendering of an object graph: keys sorted, LF endings, no whitespace.
    .DESCRIPTION
        Used to fold the package descriptor into the content address. Sorting keys means the hash does not
        depend on property order, so the build stays reproducible while every descriptor field is covered.
    .PARAMETER PackageFormat
        Strict /1 preserves Sort-Object -CaseSensitive collation. Format /2 uses ordinal ordering.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [string[]]$ExcludeTopLevelKey = @(),
        [ValidateSet('foundry-agent-package/1', 'foundry-agent-package/2')]
        [string]$PackageFormat = 'foundry-agent-package/2'
    )

    function Write-Node {
        param($Node)
        if ($null -eq $Node) { return 'null' }
        if ($Node -is [bool]) { return $(if ($Node) { 'true' } else { 'false' }) }
        if ($Node -is [string]) { return (ConvertTo-Json -InputObject $Node -Compress) }
        if ($Node -is [int] -or $Node -is [long] -or $Node -is [double] -or $Node -is [decimal]) {
            return (ConvertTo-Json -InputObject $Node -Compress)
        }
        if ($Node -is [System.Collections.IDictionary]) {
            $parts = @()
            $keys = [string[]]@($Node.Keys)
            if ($PackageFormat -eq 'foundry-agent-package/1') {
                $keys = @($Node.Keys | Sort-Object -CaseSensitive)
            }
            else {
                [Array]::Sort($keys, [StringComparer]::Ordinal)
            }
            foreach ($key in $keys) {
                $parts += (ConvertTo-Json -InputObject ([string]$key) -Compress) + ':' + (Write-Node -Node $Node[$key])
            }
            return '{' + ($parts -join ',') + '}'
        }
        if ($Node -is [System.Collections.IEnumerable]) {
            $parts = @()
            foreach ($item in $Node) { $parts += (Write-Node -Node $item) }
            return '[' + ($parts -join ',') + ']'
        }
        return (ConvertTo-Json -InputObject ([string]$Node) -Compress)
    }

    $source = $InputObject
    if ($ExcludeTopLevelKey.Count -gt 0 -and $InputObject -is [System.Collections.IDictionary]) {
        $source = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            if ($ExcludeTopLevelKey -contains [string]$key) { continue }
            $source[$key] = $InputObject[$key]
        }
    }
    return (Write-Node -Node $source)
}

function Get-PackageId {
    <#
    .SYNOPSIS
        Computes the content address of a package from its checksum manifest and canonical descriptor.
    .DESCRIPTION
        Format /2 binds the stable descriptor projection and source checksums, excluding packageId and
        informational build time/run/builder/ref fields. Strict /1 excludes only packageId. Unknown formats
        fail; there is no checksum-only compatibility fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ChecksumManifest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Descriptor
    )

    $format = [string]$Descriptor['packageFormat']
    if ($format -notin @('foundry-agent-package/1', 'foundry-agent-package/2')) {
        throw "Unsupported package format '$format'."
    }
    $projection = ConvertTo-OrderedHashtable -InputObject ($Descriptor | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64)
    if ($format -eq 'foundry-agent-package/2') {
        foreach ($field in @('createdUtc', 'buildRunId', 'buildRunUrl', 'builder', 'sourceRef')) {
            if ($projection.Contains('build')) { $projection['build'].Remove($field) }
        }
        foreach ($field in @('environments', 'tools', 'evaluations', 'attachments')) {
            if ($projection['contents'].Contains($field)) {
                $items = [string[]]@($projection['contents'][$field])
                [Array]::Sort($items, [StringComparer]::Ordinal)
                $projection['contents'][$field] = $items
            }
        }
    }
    $descriptorJson = ConvertTo-CanonicalJson -InputObject $projection -ExcludeTopLevelKey @('packageId') -PackageFormat $format
    if ($format -eq 'foundry-agent-package/2') {
        $ChecksumManifest = $ChecksumManifest.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
    }
    $payload = "$format`n$descriptorJson`n$ChecksumManifest"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return 'sha256:' + (( $hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-ChecksumManifest {
    <#
    .SYNOPSIS
        Verifies every file in a package against checksums.sha256 and reports missing, extra and modified files.
    .OUTPUTS
        IsValid, Missing, Extra, Modified, ChecksumManifestHash and ContentId. ContentId is recomputed from
        the files on disk excluding package.json and must equal the packageId recorded in the descriptor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ChecksumFileName = 'checksums.sha256',
        [string[]]$ContentIdExclude = @('package.json')
    )

    $rootResolved = Resolve-RequiredPath -Path $Root -Purpose 'Package root'
    $manifestPath = Join-Path $rootResolved $ChecksumFileName
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Package at '$rootResolved' has no $ChecksumFileName. It was not produced by New-AgentPackage.ps1."
    }

    $expected = @{}
    foreach ($line in (Get-Content -LiteralPath $manifestPath -Encoding utf8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<hash>[a-f0-9]{64})\s\s(?<path>.+)$') {
            throw "Malformed checksum line in '$manifestPath': $line"
        }
        $expected[$Matches['path']] = $Matches['hash']
    }

    $actual = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $rootResolved -Recurse -File | Where-Object { $_.Name -ne $ChecksumFileName })) {
        $relative = Get-NormalizedRelativePath -Root $rootResolved -Path $file.FullName
        $actual[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) } | Sort-Object)
    $extra = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)
    $modified = @($expected.Keys | Where-Object { $actual.ContainsKey($_) -and $actual[$_] -ne $expected[$_] } | Sort-Object)

    $manifestText = (Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8).Replace("`r`n", "`n")

    $descriptor = $null
    $descriptorPath = Join-Path $rootResolved 'package.json'
    if (Test-Path -LiteralPath $descriptorPath) { $descriptor = Read-JsonFile -Path $descriptorPath }

    $contentManifest = New-ChecksumManifest -Root $rootResolved -ChecksumFileName $ChecksumFileName `
        -ExcludeRelativePath $ContentIdExclude -PackageFormat $descriptor['packageFormat']

    return [pscustomobject]@{
        Root                 = $rootResolved
        IsValid              = (($missing.Count + $extra.Count + $modified.Count) -eq 0)
        Missing              = $missing
        Extra                = $extra
        Modified             = $modified
        ChecksumManifestHash = 'sha256:' + (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        ContentId            = (Get-PackageId -ChecksumManifest $contentManifest -Descriptor $descriptor)
    }
}

function Test-PackageIdentity {
    <#
    .SYNOPSIS
        Cross-checks the descriptor's declared identity against the packaged manifest.
    .DESCRIPTION
        The descriptor is what promotion, rollback and release records key on. If it claimed a different
        agent or version from the manifest actually inside the package, every downstream control would be
        reasoning about the wrong artifact. This makes that divergence a hard failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Descriptor
    )

    $problems = @()
    $inventory = Get-PackageInventory -PackageRoot $PackageRoot

    $manifestReference = $Descriptor['contents']['manifest']
    $manifestPath = Resolve-ContainedPath -Reference $manifestReference -BasePath $PackageRoot `
        -ContainmentRoot $PackageRoot -Inventory $inventory -Purpose 'Packaged agent manifest'
    $manifest = Read-JsonFile -Path $manifestPath

    if ($Descriptor['agent']['name'] -ne $manifest['name']) {
        $problems += "Descriptor declares agent name '$($Descriptor['agent']['name'])' but the packaged manifest is '$($manifest['name'])'."
    }
    if ($Descriptor['agent']['version'] -ne $manifest['version']) {
        $problems += "Descriptor declares version '$($Descriptor['agent']['version'])' but the packaged manifest is '$($manifest['version'])'."
    }
    foreach ($field in @('owner', 'classification')) {
        if ((ConvertTo-CanonicalJson -InputObject $Descriptor['agent'][$field]) -cne
            (ConvertTo-CanonicalJson -InputObject $manifest[$field])) { $problems += "Descriptor $field does not match the packaged manifest." }
    }
    if ($Descriptor.Contains('fileCount') -and $Descriptor['fileCount'] -ne $inventory.Count) {
        $problems += 'Descriptor fileCount does not match the verified inventory.'
    }
    foreach ($field in @('tools', 'evaluations', 'attachments')) {
        if ($Descriptor['contents'].Contains($field)) {
            foreach ($reference in $Descriptor['contents'][$field]) {
                if (-not $inventory.ContainsKey($reference)) { $problems += "Descriptor inventory entry '$reference' is missing." }
            }
        }
    }

    $instructionsReference = $Descriptor['contents']['instructions']
    $null = Resolve-ContainedPath -Reference $instructionsReference -BasePath $PackageRoot `
        -ContainmentRoot $PackageRoot -Inventory $inventory -Purpose 'Packaged instructions file'

    foreach ($environmentName in $Descriptor['contents']['environments']) {
        $overlayRelative = "environments/$environmentName.overlay.json"
        if (-not $inventory.ContainsKey($overlayRelative)) {
            $problems += "Descriptor lists environment '$environmentName' but '$overlayRelative' is not in the verified inventory."
        }
    }

    return [pscustomobject]@{
        IsValid  = ($problems.Count -eq 0)
        Problems = $problems
    }
}

function Read-PackageDescriptor {
    <#
    .SYNOPSIS
        Reads and schema-validates package.json from an extracted package folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot)

    $repoRoot = Get-RepositoryRoot
    $descriptorPath = Join-Path $PackageRoot 'package.json'
    $resolved = Resolve-RequiredPath -Path $descriptorPath -Purpose 'Package descriptor (package.json)'

    $schemaResult = Test-JsonFileSchema -Path $resolved -SchemaPath (Join-Path $repoRoot 'schemas/package-descriptor.schema.json')
    if (-not $schemaResult.IsValid) {
        throw "Package descriptor '$resolved' failed schema validation: $($schemaResult.Errors -join '; ')"
    }
    return Read-JsonFile -Path $resolved
}

function Expand-AgentPackage {
    <#
    .SYNOPSIS
        Extracts a .zip package, verifies its checksums and returns the extraction folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$SkipVerification
    )

    $resolved = Resolve-RequiredPath -Path $PackagePath -Purpose 'Agent package'
    if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
        $packageRoot = $resolved
    }
    else {
        # Extraction targets a temporary folder and is a read operation from the caller's point of view,
        # so it must happen even when the caller is running with -WhatIf.
        #
        # Microsoft.PowerShell.Archive derives its internal confirm and whatif flags from
        # $PSBoundParameters.ContainsKey(...), so passing -WhatIf:$false or -Confirm:$false to
        # Expand-Archive turns the behaviour ON rather than off. Shadow the preference variables for this
        # scope instead, which child cmdlets inherit correctly.
        $WhatIfPreference = $false
        $ConfirmPreference = 'None'

        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Expand-Archive -LiteralPath $resolved -DestinationPath $Destination -Force
        $packageRoot = (Resolve-Path -LiteralPath $Destination).Path
    }

    if (-not $SkipVerification) {
        $verification = Test-ChecksumManifest -Root $packageRoot
        if (-not $verification.IsValid) {
            $detail = @()
            if ($verification.Missing.Count) { $detail += "missing: $($verification.Missing -join ', ')" }
            if ($verification.Extra.Count) { $detail += "unexpected: $($verification.Extra -join ', ')" }
            if ($verification.Modified.Count) { $detail += "modified: $($verification.Modified -join ', ')" }
            throw "Package integrity check failed for '$resolved' ($($detail -join ' | ')). Refusing to deploy a tampered package."
        }

        $descriptor = Read-PackageDescriptor -PackageRoot $packageRoot
        if ($descriptor['packageId'] -ne $verification.ContentId) {
            throw "Package content id mismatch for '$resolved'. package.json declares '$($descriptor['packageId'])' but the files and descriptor on disk hash to '$($verification.ContentId)'. Refusing to deploy a tampered package."
        }

        $identity = Test-PackageIdentity -PackageRoot $packageRoot -Descriptor $descriptor
        if (-not $identity.IsValid) {
            throw "Package identity check failed for '$resolved': $($identity.Problems -join ' | ')"
        }
    }

    return $packageRoot
}

#endregion

#region Package store

function Get-PackageBlobName {
    <#
    .SYNOPSIS
        Content-addressed blob name for a package: <agent>/<packageId without prefix>.zip.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[a-f0-9]{64}$')][string]$PackageId
    )
    return "$AgentName/$($PackageId -replace '^sha256:', '').zip"
}

function Publish-AgentPackage {
    <#
    .SYNOPSIS
        Uploads an immutable package to the environment's content-addressed package store.
    .DESCRIPTION
        The blob name is derived from the package id, so the store is content addressed and an upload is
        idempotent. The resulting URI is recorded in the release record, which is what makes rollback able to
        retrieve an exact prior artifact months later without relying on pipeline artifact retention.

        Uses 'az storage blob upload --auth-mode login', so no storage key or SAS token is involved.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig
    )

    if (-not $EnvironmentConfig.Contains('packageStore') -or -not $EnvironmentConfig['packageStore']) {
        Write-OpsLog -Level Warning -Message "Environment '$($EnvironmentConfig['environment'])' has no packageStore configured. Rollback will depend on pipeline artifact retention alone."
        return $null
    }

    $store = $EnvironmentConfig['packageStore']
    if ($store['type'] -ne 'azureBlob') { return $null }

    $blobName = Get-PackageBlobName -AgentName $AgentName -PackageId $PackageId
    $uri = "https://$($store['accountName']).blob.core.windows.net/$($store['container'])/$blobName"

    if (-not $PSCmdlet.ShouldProcess($uri, 'Upload immutable package')) { return $uri }

    $arguments = @(
        'storage', 'blob', 'upload',
        '--account-name', $store['accountName'],
        '--container-name', $store['container'],
        '--name', $blobName,
        '--file', (ConvertTo-AbsolutePath -Path $PackagePath),
        '--auth-mode', 'login',
        '--overwrite', 'false',
        '--only-show-errors'
    )
    $output = & az @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        # A blob that already exists is the expected outcome for a content-addressed store.
        if (($output | Out-String) -match 'BlobAlreadyExists|already exists') {
            $scratch = Join-Path (Get-RepositoryRoot) "out\publication-$([Guid]::NewGuid().ToString('n'))"
            New-Item -ItemType Directory -Force -Path $scratch | Out-Null
            try {
                $retained = Get-AgentPackageFromStore -AgentName $AgentName -PackageId $PackageId -EnvironmentConfig $EnvironmentConfig -Destination (Join-Path $scratch 'retained.zip')
                if (-not $retained -or
                    (Get-FileHash -LiteralPath $retained -Algorithm SHA256).Hash -ne
                    (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash) {
                    throw "Archive byte conflict for existing package $PackageId. Retain the original archive; never overwrite it."
                }
                Write-OpsLog -Level Info -Message "Existing package $PackageId has identical archive bytes."
                return $uri
            }
            finally { Remove-Item -LiteralPath $scratch -Recurse -Force -Confirm:$false }
        }
        throw "Failed to upload the package to '$uri'. Confirm the deployment identity holds 'Storage Blob Data Contributor' on the container. Azure CLI reported: $(($output | Out-String).Trim())"
    }
    Write-OpsLog -Level Success -Message "Package published to the content-addressed store as $blobName"
    return $uri
}

function Get-AgentPackageFromStore {
    <#
    .SYNOPSIS
        Downloads a package from the content-addressed package store by package id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not $EnvironmentConfig.Contains('packageStore') -or -not $EnvironmentConfig['packageStore']) { return $null }
    $store = $EnvironmentConfig['packageStore']
    if ($store['type'] -ne 'azureBlob') { return $null }

    $blobName = Get-PackageBlobName -AgentName $AgentName -PackageId $PackageId
    $directory = Split-Path -Parent $Destination
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }

    $arguments = @(
        'storage', 'blob', 'download',
        '--account-name', $store['accountName'],
        '--container-name', $store['container'],
        '--name', $blobName,
        '--file', (ConvertTo-AbsolutePath -Path $Destination),
        '--auth-mode', 'login',
        '--only-show-errors'
    )
    $null = & az @arguments 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Destination)) {
        Write-OpsLog -Level Warning -Message "Package $PackageId was not retrievable from the package store for '$AgentName'."
        return $null
    }
    return (Resolve-Path -LiteralPath $Destination).Path
}

function Find-AgentPackage {
    <#
    .SYNOPSIS
        Locates a package with a specific content id, searching local directories then the package store.
    .DESCRIPTION
        Verification is full: every candidate is expanded and checked against its checksum inventory,
        descriptor content id and declared identity before it is accepted. A candidate that fails is skipped
        with a warning rather than being used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$PackageId,
        [string[]]$SearchDirectory = @(),
        [System.Collections.IDictionary]$EnvironmentConfig,
        [string]$DownloadDirectory
    )

    foreach ($directory in $SearchDirectory) {
        if (-not $directory -or -not (Test-Path -LiteralPath $directory)) { continue }
        foreach ($candidate in (Get-ChildItem -LiteralPath $directory -Recurse -Filter '*.zip' -File)) {
            $extractRoot = Join-Path (Get-RepositoryRoot) ("out\platform-work\foundry-find-" + [Guid]::NewGuid().ToString('n'))
            try {
                $root = Expand-AgentPackage -PackagePath $candidate.FullName -Destination $extractRoot
                $descriptor = Read-PackageDescriptor -PackageRoot $root
                if ($descriptor['packageId'] -eq $PackageId -and $descriptor['agent']['name'] -eq $AgentName) {
                    return $candidate.FullName
                }
            }
            catch [System.Management.Automation.RuntimeException] {
                Write-OpsLog -Level Warning -Message "Skipping '$($candidate.Name)': $($_.Exception.Message)"
            }
            finally {
                if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
            }
        }
    }

    if ($EnvironmentConfig -and $DownloadDirectory) {
        $target = Join-Path $DownloadDirectory "$AgentName-$($PackageId -replace '^sha256:', '').zip"
        $downloaded = Get-AgentPackageFromStore -AgentName $AgentName -PackageId $PackageId -EnvironmentConfig $EnvironmentConfig -Destination $target
        if ($downloaded) {
            $extractRoot = Join-Path (Get-RepositoryRoot) ("out\platform-work\foundry-find-" + [Guid]::NewGuid().ToString('n'))
            try {
                $root = Expand-AgentPackage -PackagePath $downloaded -Destination $extractRoot
                $descriptor = Read-PackageDescriptor -PackageRoot $root
                if ($descriptor['packageId'] -eq $PackageId -and $descriptor['agent']['name'] -eq $AgentName) { return $downloaded }
                throw "Package downloaded from the store for id '$PackageId' does not verify to that id."
            }
            finally {
                if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
            }
        }
    }

    return $null
}

#endregion

#region Azure access

function Get-FoundryAccessToken {
    <#
    .SYNOPSIS
        Acquires an AAD access token for the Agent Service data plane using the current Azure CLI login.
    .DESCRIPTION
        In CI the login is established by azure/login@v2 (GitHub OIDC) or AzureCLI@2 with a workload identity
        federation service connection (Azure DevOps). No secret is accepted or emitted by this function; the
        token is returned as a SecureString and is never written to the console.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Converts the runtime Azure CLI access-token response to the existing SecureString return contract; no source-embedded credential.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [string]$TenantId
    )

    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw "Azure CLI ('az') was not found on PATH. Install it or run this step inside a task that provides an authenticated Azure CLI session."
    }

    $arguments = @('account', 'get-access-token', '--scope', $Scope, '--output', 'json')
    if ($TenantId) { $arguments += @('--tenant', $TenantId) }

    $output = & az @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire an access token for scope '$Scope' (az exit code $LASTEXITCODE). Ensure the pipeline has signed in with workload identity federation before this step. Azure CLI reported: $(($output | Out-String).Trim())"
    }

    try {
        $tokenObject = ($output | Out-String) | ConvertFrom-Json
    }
    catch [System.ArgumentException] {
        throw "Azure CLI returned a response that could not be parsed as JSON while acquiring a token for scope '$Scope'."
    }

    $secure = ConvertTo-SecureString -String $tokenObject.accessToken -AsPlainText -Force
    $tokenObject = $null
    $output = $null
    [System.GC]::Collect()
    return $secure
}

function Invoke-FoundryApi {
    <#
    .SYNOPSIS
        Calls the Agent Service data plane with retry on throttling and transient server errors.
    .PARAMETER Endpoint
        Project endpoint, for example https://<account>.services.ai.azure.com/api/projects/<project>.
    .PARAMETER Path
        Resource path appended to the endpoint, for example /assistants.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApiVersion,
        [Parameter(Mandatory)][securestring]$AccessToken,
        [ValidateSet('GET', 'POST', 'DELETE', 'PATCH')][string]$Method = 'GET',
        $Body,
        [int]$MaxAttempts = 4,
        [int]$TimeoutSeconds = 100
    )

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $uri = "$($Endpoint.TrimEnd('/'))$Path$separator" + "api-version=$ApiVersion"

    $parameters = @{
        Uri                     = $uri
        Method                  = $Method
        Authentication          = 'Bearer'
        Token                   = $AccessToken
        ContentType             = 'application/json'
        Headers                 = @{ 'User-Agent' = $script:UserAgent }
        TimeoutSec              = $TimeoutSeconds
        MaximumRedirection      = 0
        SkipHttpErrorCheck      = $true
        StatusCodeVariable      = 'statusCode'
        ErrorAction             = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters['Body'] = ($Body | ConvertTo-Json -Depth 32 -Compress)
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $statusCode = 0
        $response = Invoke-RestMethod @parameters

        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            return [pscustomobject]@{ StatusCode = $statusCode; Content = $response }
        }

        $isRetryable = ($statusCode -eq 429 -or $statusCode -ge 500)
        if ($isRetryable -and $attempt -lt $MaxAttempts) {
            $delay = [Math]::Min([Math]::Pow(2, $attempt), 30)
            Write-OpsLog -Level Warning -Message "Agent Service returned HTTP $statusCode for $Method $Path. Retrying in $delay second(s) (attempt $attempt of $MaxAttempts)."
            Start-Sleep -Seconds $delay
            continue
        }

        $detail = try { ($response | ConvertTo-Json -Depth 8 -Compress) } catch { '<no response body>' }
        throw "Agent Service call failed: $Method $Path returned HTTP $statusCode. Endpoint '$Endpoint', api-version '$ApiVersion'. Response: $detail"
    }
}

function Test-FoundryEndpoint {
    <#
    .SYNOPSIS
        Confirms that the configured project endpoint and SDK authentication support a read-only list call.
    .DESCRIPTION
        The Azure AI Projects SDK selects its own service API version. This preflight does not consume or
        validate the apiVersion retained in environment configuration for REST runtime tests and export-by-id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [securestring]$AccessToken
    )

    $result = Invoke-FoundryPythonCli -Subcommand 'preflight' -EnvironmentConfig $EnvironmentConfig

    Write-OpsLog -Level Success -Message 'Azure AI Projects SDK preflight succeeded for the project endpoint.'
    return $result
}

function Get-FoundryAgent {
    <#
    .SYNOPSIS
        Finds the managed agent for a logical name in the target project.
    .DESCRIPTION
        When -LogicalName is non-empty, reads the agent directly by logical name through the Azure AI Projects
        SDK and returns separate active/latest versions, with configuration from the active version.
        When only -KnownAgentId is supplied, falls back to the retained REST GET /assistants/{id} path
        for legacy/manual export scenarios because the SDK does not expose a get-by-id operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LogicalName,
        [string]$KnownAgentId,
        [securestring]$AccessToken
    )

    if (-not [string]::IsNullOrWhiteSpace($LogicalName)) {
        $result = Invoke-FoundryPythonCli -Subcommand 'get-agent' -EnvironmentConfig $EnvironmentConfig -LogicalName $LogicalName
        if (-not $result -or -not $result.found) { return $null }

        $agent = [ordered]@{
            id            = $result.id
            name          = $result.name
            latestVersion = $result.latestVersion
        }

        if ($result.PSObject.Properties.Name -contains 'agentEndpoint') {
            $agent['agent_endpoint'] = $result.agentEndpoint
        }
        if ($result.PSObject.Properties.Name -contains 'description') {
            $agent['description'] = $result.description
        }
        if ($result.PSObject.Properties.Name -contains 'metadata') {
            $agent['metadata'] = $result.metadata
        }
        if ($result.PSObject.Properties.Name -contains 'definition') {
            $agent['definition'] = $result.definition
        }
        foreach ($property in @('activeVersion', 'state', 'instructions', 'model', 'reasoning', 'structured_inputs', 'text', 'tools', 'top_p', 'temperature', 'version', 'versionId')) {
            if ($result.PSObject.Properties.Name -contains $property) {
                $agent[$property] = $result.$property
            }
        }

        return [pscustomobject]$agent
    }

    if ([string]::IsNullOrWhiteSpace($KnownAgentId)) {
        throw "Supply either -LogicalName for SDK discovery or -KnownAgentId for the retained REST get-by-id fallback."
    }
    if (-not $AccessToken) {
        throw "Get-FoundryAgent requires -AccessToken when using the retained REST get-by-id fallback for KnownAgentId '$KnownAgentId'."
    }

    $foundry = $EnvironmentConfig['foundry']
    $response = Invoke-FoundryApi -Endpoint $foundry['projectEndpoint'] -Path "/assistants/$KnownAgentId" `
        -ApiVersion $foundry['apiVersion'] -AccessToken $AccessToken -Method GET
    return $response.Content
}

function New-FoundryAgentVersion {
    <#
    .SYNOPSIS
        Creates a new agent version from a resolved payload through the Azure AI Projects SDK.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Payload
    )

    return Invoke-FoundryPythonCli -Subcommand 'create-version' -EnvironmentConfig $EnvironmentConfig -LogicalName $LogicalName -InputObject $Payload
}

function Set-FoundryAgentActiveVersion {
    <#
    .SYNOPSIS
        Promotes one agent version to 100% traffic through the Azure AI Projects SDK.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][string]$AgentVersion
    )

    return Invoke-FoundryPythonCli -Subcommand 'promote-version' -EnvironmentConfig $EnvironmentConfig -LogicalName $LogicalName -AgentVersion $AgentVersion
}

function Invoke-FoundryAgentRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LogicalName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AgentVersion,
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        [ValidateRange(1, 600)][int]$PollIntervalSeconds = 2
    )

    return Invoke-FoundryPythonCli -Subcommand 'invoke-agent' -EnvironmentConfig $EnvironmentConfig `
        -LogicalName $LogicalName -AgentVersion $AgentVersion -InputObject @{
            prompt = $Prompt; timeoutSeconds = $TimeoutSeconds; pollIntervalSeconds = $PollIntervalSeconds
        } -ProcessTimeoutSeconds ($TimeoutSeconds + 10)
}

function Get-FoundryReleaseTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRecordPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig
    )
    $record = Read-ReleaseRecordFile -Path $ReleaseRecordPath
    $mutation = $record['deployment']['runtimeMutation']
    if ($record['schemaVersion'] -ne '1.1.0' -or
        $record['environment'] -ne $EnvironmentConfig['environment'] -or
        -not $mutation -or $mutation['started'] -isnot [bool] -or $mutation['started'] -ne $true -or
        $mutation['completed'] -isnot [bool] -or $mutation['completed'] -ne $true -or
        $mutation['stage'] -ne 'activated' -or -not $mutation['completedAtUtc'] -or
        -not $record['agent']['serviceVersion'] -or -not $record['agent']['serviceVersionId'] -or
        $mutation['candidateVersion'] -cne $record['agent']['serviceVersion']) {
        throw 'Release target lacks completed mutation/service identity or does not match the configured environment.'
    }
    if ($record['projectEndpoint'].TrimEnd('/').ToLowerInvariant() -cne
        $EnvironmentConfig['foundry']['projectEndpoint'].TrimEnd('/').ToLowerInvariant()) {
        throw 'Release target project endpoint does not match configuration.'
    }
    $agent = Get-FoundryAgent -EnvironmentConfig $EnvironmentConfig -LogicalName $record['agent']['name']
    if (-not $agent -or $agent.activeVersion -cne $record['agent']['serviceVersion'] -or
        $agent.id -cne $record['agent']['remoteAgentId'] -or $agent.versionId -cne $record['agent']['serviceVersionId']) {
        throw 'Release target does not match the actual supported active selection and service identity.'
    }
    $identity = [ordered]@{
        schemaVersion = '1.1.0'; mode = 'live'
        releaseId = $record['releaseId']; packageId = $record['packageId']
        agentName = $record['agent']['name']; environment = $record['environment']
        projectEndpoint = $EnvironmentConfig['foundry']['projectEndpoint'].TrimEnd('/').ToLowerInvariant()
        agentVersion = $record['agent']['version']; serviceVersion = $record['agent']['serviceVersion']
    }
    return [pscustomobject]@{ Record = $record; Agent = $agent; Identity = $identity }
}

function Resolve-SecretReference {
    <#
    .SYNOPSIS
        Resolves an @Microsoft.KeyVault(VaultName=...;SecretName=...) reference to a SecureString.
    .DESCRIPTION
        Uses the signed-in workload identity. The value is returned as a SecureString and must never be
        converted to plain text for logging, pipeline variables or command line arguments.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Converts a runtime Azure CLI Key Vault lookup result to the existing SecureString return contract; source contains only the validated reference.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)][string]$Reference)

    if ($Reference -notmatch '^@Microsoft\.KeyVault\(VaultName=(?<vault>[A-Za-z0-9-]{3,24});SecretName=(?<secret>[A-Za-z0-9-]{1,127})(;SecretVersion=(?<version>[A-Za-z0-9]+))?\)$') {
        throw "Invalid Key Vault reference format. Expected '@Microsoft.KeyVault(VaultName=<vault>;SecretName=<secret>[;SecretVersion=<version>])'."
    }

    $vault = $Matches['vault']
    $secretName = $Matches['secret']
    $arguments = @('keyvault', 'secret', 'show', '--vault-name', $vault, '--name', $secretName, '--query', 'value', '--output', 'tsv')
    if ($Matches.ContainsKey('version') -and $Matches['version']) { $arguments += @('--version', $Matches['version']) }

    $value = & az @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($value)) {
        throw "Unable to read secret '$secretName' from Key Vault '$vault'. Verify the vault name, that the secret exists, and that the deployment identity holds the 'Key Vault Secrets User' role."
    }

    $secure = ConvertTo-SecureString -String ([string]$value).Trim() -AsPlainText -Force
    $value = $null
    return $secure
}

#endregion

#region Release records

function New-ReleaseRecord {
    <#
    .SYNOPSIS
        Builds a release record object describing one deployment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('dev', 'test', 'uat', 'prod')][string]$Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$PackageDescriptor,
        [Parameter(Mandatory)][ValidateSet('deploy', 'promote', 'rollback')][string]$Operation,
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed', 'rolled-back', 'simulated', 'pending-verification')][string]$Outcome,
        [string]$RemoteAgentId,
        [string]$PackageUri,
        [string]$SourceEnvironment,
        [hashtable]$GateResults,
        [System.Collections.IDictionary]$Previous,
        [string]$ChangeRecordId,
        [string]$BusinessSignoffId,
        [string]$OriginalChangeRecordId,
        [string]$RollbackReason
    )

    $timestamp = [DateTime]::UtcNow
    $shortId = ($PackageDescriptor['packageId'] -replace '^sha256:', '').Substring(0, 12)
    $deployedBy = if ($env:GITHUB_ACTOR) { "github:$env:GITHUB_ACTOR" }
    elseif ($env:BUILD_REQUESTEDFOR) { "azuredevops:$env:BUILD_REQUESTEDFOR" }
    else { "local:$([Environment]::UserName)" }

    $pipelineUrl = if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
        "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    }
    elseif ($env:SYSTEM_COLLECTIONURI -and $env:SYSTEM_TEAMPROJECT -and $env:BUILD_BUILDID) {
        "$($env:SYSTEM_COLLECTIONURI.TrimEnd('/'))/$env:SYSTEM_TEAMPROJECT/_build/results?buildId=$env:BUILD_BUILDID"
    }
    else { $null }

    $deployment = [ordered]@{
        deployedAtUtc = $timestamp.ToString('yyyy-MM-ddTHH:mm:ssZ')
        deployedBy    = $deployedBy
        outcome       = $Outcome
        operation     = $Operation
        runtimeMutation = [ordered]@{ started = $false; completed = $false; stage = 'prepared' }
    }
    if ($SourceEnvironment) { $deployment['sourceEnvironment'] = $SourceEnvironment }
    if ($pipelineUrl) { $deployment['pipelineRunUrl'] = $pipelineUrl }
    if ($GateResults) {
        $gates = [ordered]@{}
        foreach ($key in @('validation', 'evaluation', 'regression', 'smoke')) {
            if ($GateResults.ContainsKey($key)) { $gates[$key] = $GateResults[$key] }
        }
        if ($gates.Count -gt 0) { $deployment['gateResults'] = $gates }
    }

    $agent = [ordered]@{
        name    = $PackageDescriptor['agent']['name']
        version = $PackageDescriptor['agent']['version']
    }
    if ($RemoteAgentId) { $agent['remoteAgentId'] = $RemoteAgentId }

    $governance = [ordered]@{}
    if ($PackageDescriptor['agent'].Contains('classification') -and
        $PackageDescriptor['agent']['classification'] -and
        $PackageDescriptor['agent']['classification'].Contains('responsibleAiReviewId') -and
        $PackageDescriptor['agent']['classification']['responsibleAiReviewId']) {
        $governance['responsibleAiReviewId'] = [string]$PackageDescriptor['agent']['classification']['responsibleAiReviewId']
    }
    if ($ChangeRecordId) { $governance['changeRecordId'] = $ChangeRecordId }
    if ($BusinessSignoffId) { $governance['businessSignoffId'] = $BusinessSignoffId }
    if ($OriginalChangeRecordId) { $governance['originalChangeRecordId'] = $OriginalChangeRecordId }
    if ($RollbackReason) { $governance['rollbackReason'] = $RollbackReason }

    $record = [ordered]@{
        '$schema'     = '../schemas/release-record.schema.json'
        schemaVersion = '1.1.0'
        releaseId     = "$($PackageDescriptor['agent']['name'])-$Environment-$($timestamp.ToString('yyyyMMddTHHmmssZ'))-$shortId-$([Guid]::NewGuid().ToString('n').Substring(0,8))"
        environment   = $Environment
        packageId     = $PackageDescriptor['packageId']
        agent         = $agent
        governance    = $governance
        deployment    = $deployment
    }
    if ($PackageUri) { $record['packageUri'] = $PackageUri }
    if ($Previous -and $Previous.Count -gt 0) { $record['previous'] = $Previous }

    return $record
}

function Read-ReleaseRecordFile {
    <#
    .SYNOPSIS
        Reads and schema-validates a release record transported as a pipeline artifact.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-RequiredPath -Path $Path -Purpose 'Release record'
    $check = Test-JsonFileSchema -Path $resolved -SchemaPath (Join-Path (Get-RepositoryRoot) 'schemas/release-record.schema.json')
    if (-not $check.IsValid) {
        throw "Release record '$resolved' failed schema validation: $($check.Errors -join '; ')"
    }
    return Read-JsonFile -Path $resolved
}

function Test-ReleaseRecordForPromotion {
    <#
    .SYNOPSIS
        Validates that a transported source release record authorises promotion of a specific package.
    .DESCRIPTION
        Promotion previously read the source environment's release store, which requires the target
        environment identity to hold data access in the source environment. That breaks per-environment
        least privilege. Instead the source record travels with the package as a pipeline artifact and is
        validated here: it must describe the same agent, the same content-addressed package id, the declared
        source environment, and an outcome that was attested after post-deployment gates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$SourceEnvironment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedGates
    )

    $problems = @()
    if ($Record['schemaVersion'] -ne '1.1.0' -or
        -not $Record['agent']['serviceVersion'] -or -not $Record['agent']['serviceVersionId'] -or
        -not $Record['agent']['remoteAgentId'] -or -not $Record['projectEndpoint']) {
        $problems += 'record lacks the new release/service identity contract; legacy records are audit-only'
    }
    if ($Record['agent']['name'] -ne $AgentName) {
        $problems += "record is for agent '$($Record['agent']['name'])', not '$AgentName'"
    }
    if ($Record['environment'] -ne $SourceEnvironment) {
        $problems += "record is for environment '$($Record['environment'])', not '$SourceEnvironment'"
    }
    if ($Record['packageId'] -ne $PackageId) {
        $problems += "record references package '$($Record['packageId'])' but the supplied artifact is '$PackageId'"
    }
    $outcome = [string]$Record['deployment']['outcome']
    if ($outcome -ne 'succeeded') {
        $problems += "record outcome is '$outcome'. Only a deployment attested as 'succeeded' after its post-deployment gates may be promoted"
    }
    if (-not $Record['deployment'].Contains('runtimeMutation') -or
        $Record['deployment']['runtimeMutation']['started'] -isnot [bool] -or
        $Record['deployment']['runtimeMutation']['completed'] -isnot [bool] -or
        $Record['deployment']['runtimeMutation']['started'] -ne $true -or
        $Record['deployment']['runtimeMutation']['completed'] -ne $true -or
        $Record['deployment']['runtimeMutation']['stage'] -ne 'activated' -or
        $Record['deployment']['runtimeMutation']['candidateVersion'] -cne $Record['agent']['serviceVersion'] -or
        -not $Record['deployment']['runtimeMutation']['completedAtUtc']) {
        $problems += 'record does not contain completed runtime mutation evidence'
    }
    if (-not $Record['deployment'].Contains('attestation') -or -not $Record['deployment']['attestation']) {
        $problems += 'record carries no gate attestation. Run Complete-Release.ps1 in the source environment before promoting'
    }
    else {
        $attestation = $Record['deployment']['attestation']
        if (-not $attestation.Contains('gatesSatisfied') -or $attestation['gatesSatisfied'] -isnot [bool] -or $attestation['gatesSatisfied'] -ne $true) {
            $problems += 'record attestation does not report gatesSatisfied'
        }
        foreach ($field in @('attestedAtUtc', 'attestedBy', 'requiredGates', 'evidence')) {
            if (-not $attestation.Contains($field) -or $null -eq $attestation[$field] -or
                ($attestation[$field] -is [string] -and [string]::IsNullOrWhiteSpace($attestation[$field]))) {
                $problems += "record attestation is missing '$field'"
            }
        }
        if ($attestation.Contains('evidence') -and $attestation['evidence'].Count -eq 0) {
            $problems += 'record attestation evidence is empty'
        }
        if ($attestation.Contains('requiredGates') -and $attestation['requiredGates'] -and
            $attestation.Contains('evidence') -and $attestation['evidence']) {
            $requiredGates = $ExpectedGates
            foreach ($key in $ExpectedGates.Keys) {
                if ($attestation['requiredGates'][$key] -ne $ExpectedGates[$key]) { $problems += "attested requirement '$key' does not match the verified source overlay" }
            }
            $evidence = $attestation['evidence']
            foreach ($name in $evidence.Keys) {
                try {
                    if ($evidence[$name]['resultSha256'] -isnot [string] -or $evidence[$name]['resultSha256'] -notmatch '^[a-f0-9]{64}$') { throw 'missing result-file hash' }
                    if (($evidence[$name]['executed'] -isnot [int] -and $evidence[$name]['executed'] -isnot [long]) -or $evidence[$name]['executed'] -le 0) { throw 'invalid executed count' }
                    if ($null -ne $evidence[$name]['score']) {
                        $value = $evidence[$name]['score']
                        if (($value -isnot [int] -and $value -isnot [double] -and $value -isnot [decimal]) -or
                            -not [double]::IsFinite([double]$value) -or $value -lt 0 -or $value -gt 1) { throw 'invalid score' }
                    }
                    Assert-GateEnvelope -Envelope $evidence[$name]['envelope'] -Record $Record -Gate $name `
                        -EnvironmentConfig @{ foundry = @{ projectEndpoint = $Record['projectEndpoint'] } }
                    if ($evidence[$name]['executed'] -lt $evidence[$name]['envelope']['liveExecuted']) { throw 'live count exceeds executed count' }
                    if ($name -ne 'smoke' -and $evidence[$name]['executed'] -ne $evidence[$name]['envelope']['liveExecuted']) { throw 'live count differs from total' }
                }
                catch { $problems += "invalid $name evidence: $($_.Exception.Message)" }
            }
            foreach ($gate in @(
                    @{ Name = 'smoke'; Required = 'requireSmokeTestPass' },
                    @{ Name = 'evaluation'; Required = 'requireEvaluationPass' },
                    @{ Name = 'regression'; Required = 'requireRegressionPass' }
                )) {
                if (($requiredGates.Contains($gate.Required) -and $requiredGates[$gate.Required] -eq $true) -or
                    ($gate.Name -eq 'evaluation' -and $null -ne $requiredGates['minimumEvaluationScore'])) {
                    if (-not $Record['deployment'].Contains('gateResults') -or
                        -not $Record['deployment']['gateResults'].Contains($gate.Name) -or
                        $Record['deployment']['gateResults'][$gate.Name] -ne 'passed') {
                        $actualResult = if ($Record['deployment'].Contains('gateResults') -and
                            $Record['deployment']['gateResults'].Contains($gate.Name)) {
                            [string]$Record['deployment']['gateResults'][$gate.Name]
                        }
                        else { 'missing' }
                        $problems += "required $($gate.Name) gate result is '$actualResult', not 'passed'"
                    }
                    if (-not $evidence.Contains($gate.Name) -or -not $evidence[$gate.Name]) {
                        $problems += "required $($gate.Name) gate has no attested evidence"
                        continue
                    }
                    $gateEvidence = $evidence[$gate.Name]
                    if ($gateEvidence['outcome'] -ne 'passed') {
                        $problems += "required $($gate.Name) evidence outcome is '$($gateEvidence['outcome'])', not 'passed'"
                    }
                    if ([int]$gateEvidence['executed'] -le 0) {
                        $problems += "required $($gate.Name) evidence executed no cases"
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$gateEvidence['source'])) {
                        $problems += "required $($gate.Name) evidence has no source"
                    }
                }
            }
            if ($requiredGates.Contains('minimumEvaluationScore') -and
                $null -ne $requiredGates['minimumEvaluationScore'] -and
                $evidence.Contains('evaluation') -and $evidence['evaluation']) {
                if ($null -eq $evidence['evaluation']['score'] -or
                    [double]$evidence['evaluation']['score'] -lt [double]$requiredGates['minimumEvaluationScore']) {
                    $problems += "evaluation evidence does not meet minimum score $($requiredGates['minimumEvaluationScore'])"
                }
            }
        }
    }

    return [pscustomobject]@{
        IsValid  = ($problems.Count -eq 0)
        Problems = $problems
    }
}

function Save-ReleaseRecord {
    <#
    .SYNOPSIS
        Writes a release record locally and, when the environment uses an Azure Blob release store, uploads it.
    .DESCRIPTION
        Upload uses 'az storage blob upload --auth-mode login', so no storage key or SAS token is required.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$LocalDirectory
    )

    if (-not (Test-Path -LiteralPath $LocalDirectory)) {
        New-Item -ItemType Directory -Force -Path $LocalDirectory | Out-Null
    }
    $localPath = Join-Path $LocalDirectory "$($Record['releaseId']).json"
    Write-JsonFile -InputObject $Record -Path $localPath -Depth 16 | Out-Null
    Write-OpsLog -Level Success -Message "Release record written to $localPath"

    if (-not $EnvironmentConfig.Contains('releaseStore') -or -not $EnvironmentConfig['releaseStore']) { return $localPath }
    $store = $EnvironmentConfig['releaseStore']
    if ($store['type'] -ne 'azureBlob') { return $localPath }

    $agentName = $Record['agent']['name']
    $blobName = "$agentName/$($Record['environment'])/$($Record['releaseId']).json"
    $latestBlobName = "$agentName/$($Record['environment'])/latest.json"

    if ($PSCmdlet.ShouldProcess("$($store['accountName'])/$($store['container'])/$blobName", 'Upload release record')) {
        foreach ($target in @($blobName, $latestBlobName)) {
            $arguments = @(
                'storage', 'blob', 'upload',
                '--account-name', $store['accountName'],
                '--container-name', $store['container'],
                '--name', $target,
                '--file', $localPath,
                '--auth-mode', 'login',
                '--overwrite', 'true',
                '--only-show-errors'
            )
            $null = & az @arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to upload the release record to blob '$target' in account '$($store['accountName'])'. Confirm the deployment identity has the 'Storage Blob Data Contributor' role on the container."
            }
        }
        Write-OpsLog -Level Success -Message "Release record published to blob store as $blobName (and latest.json)."
    }

    return $localPath
}

function Get-LatestReleaseRecord {
    <#
    .SYNOPSIS
        Retrieves the most recent release record for an agent and environment from the configured release store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$AgentName,
        [string]$LocalFallbackDirectory
    )

    $environment = $EnvironmentConfig['environment']

    if ($EnvironmentConfig.Contains('releaseStore') -and $EnvironmentConfig['releaseStore'] -and $EnvironmentConfig['releaseStore']['type'] -eq 'azureBlob') {
        $store = $EnvironmentConfig['releaseStore']
        $scratch = Join-Path (Get-RepositoryRoot) 'out\platform-work'
        New-Item -ItemType Directory -Force -Path $scratch | Out-Null
        $tempFile = Join-Path $scratch ("release-$([Guid]::NewGuid().ToString('n')).json")
        $arguments = @(
            'storage', 'blob', 'download',
            '--account-name', $store['accountName'],
            '--container-name', $store['container'],
            '--name', "$AgentName/$environment/latest.json",
            '--file', $tempFile,
            '--auth-mode', 'login',
            '--only-show-errors'
        )
        $null = & az @arguments 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tempFile)) {
            try {
                return Read-JsonFile -Path $tempFile
            }
            finally {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
        Write-OpsLog -Level Warning -Message "No release record found in blob store for '$AgentName' in '$environment'."
    }

    if ($LocalFallbackDirectory -and (Test-Path -LiteralPath $LocalFallbackDirectory)) {
        $candidate = Get-ChildItem -LiteralPath $LocalFallbackDirectory -Filter "$AgentName-$environment-*.json" -File |
        Sort-Object Name -Descending | Select-Object -First 1
        if ($candidate) { return Read-JsonFile -Path $candidate.FullName }
    }

    return $null
}

function Get-ReleaseRecordById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$ReleaseId,
        [Parameter(Mandatory)][string]$AgentName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$LocalDirectory
    )
    $path = Join-Path $LocalDirectory "$ReleaseId.json"
    if (Test-Path -LiteralPath $path) { return Read-ReleaseRecordFile -Path $path }
    if (-not $EnvironmentConfig['releaseStore'] -or $EnvironmentConfig['releaseStore']['type'] -ne 'azureBlob') { return $null }
    $store = $EnvironmentConfig['releaseStore']
    $scratch = Join-Path (Get-RepositoryRoot) 'out\platform-work'
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $download = Join-Path $scratch "$([Guid]::NewGuid().ToString('n')).json"
    try {
        $null = & az storage blob download --account-name $store['accountName'] --container-name $store['container'] `
            --name "$AgentName/$($EnvironmentConfig['environment'])/$ReleaseId.json" --file $download --auth-mode login --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        return Read-ReleaseRecordFile -Path $download
    }
    finally { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force } }
}

#endregion

function Invoke-FoundryPythonCli {
    <#
    .SYNOPSIS
        Invokes the Python SDK bridge for Azure AI Foundry agent operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('preflight', 'get-agent', 'create-version', 'promote-version', 'invoke-agent')][string]$Subcommand,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentConfig,
        [string]$LogicalName,
        [string]$AgentVersion,
        [AllowNull()][System.Collections.IDictionary]$InputObject,
        [ValidateRange(1, 660)][int]$ProcessTimeoutSeconds = 180
    )

    $repoRoot = Get-RepositoryRoot
    $cliPath = Join-Path $repoRoot (Join-Path 'scripts' (Join-Path 'python' 'foundry_agent_cli.py'))
    if (-not (Test-Path -LiteralPath $cliPath)) {
        throw [System.Management.Automation.RuntimeException]::new("Foundry SDK CLI not found at '$cliPath'.")
    }

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
    }
    if (-not $pythonCommand) {
        throw [System.Management.Automation.RuntimeException]::new("Python 3.10+ is required for Foundry agent deployment operations. Install Python and then run 'python -m pip install -r scripts/python/requirements.txt'.")
    }

    $pythonVersion = & $pythonCommand.Source -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"
    if ($LASTEXITCODE -ne 0) {
        throw [System.Management.Automation.RuntimeException]::new("Unable to determine the Python version from '$($pythonCommand.Source)'.")
    }
    if ([version]$pythonVersion -lt [version]'3.10') {
        throw [System.Management.Automation.RuntimeException]::new("Python 3.10+ is required for Foundry agent deployment operations. Found '$pythonVersion' at '$($pythonCommand.Source)'.")
    }

    $foundry = $EnvironmentConfig['foundry']
    $tenantId = if ($EnvironmentConfig['azure'].Contains('tenantId')) { [string]$EnvironmentConfig['azure']['tenantId'] } else { $null }
    $arguments = @(
        $cliPath,
        $Subcommand,
        '--endpoint', [string]$foundry['projectEndpoint'],
        '--api-version', [string]$foundry['apiVersion']
    )
    if ($LogicalName) {
        $arguments += @('--agent-name', $LogicalName)
    }
    if ($AgentVersion) {
        $arguments += @('--agent-version', $AgentVersion)
    }
    if ($tenantId) {
        $arguments += @('--tenant-id', $tenantId)
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonCommand.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputObject') -and $null -ne $InputObject
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw [System.Management.Automation.RuntimeException]::new("Failed to start the Foundry SDK CLI with '$($pythonCommand.Source)'.")
    }

    if ($startInfo.RedirectStandardInput) {
        $jsonInput = $InputObject | ConvertTo-Json -Depth 64 -Compress
        $process.StandardInput.Write($jsonInput)
        $process.StandardInput.Close()
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        $process.Dispose()
        throw "Foundry SDK CLI '$Subcommand' exceeded its bounded process timeout."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if (-not [string]::IsNullOrWhiteSpace($stderr) -and $process.ExitCode -eq 0) {
        foreach ($line in ($stderr -split "(`r`n|`n|`r)")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            Write-Warning $line.Trim()
        }
    }

    if ($process.ExitCode -ne 0) {
        $detail = $stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $stdout.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $detailLines = @($detail -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $detailToParse = if ($detailLines.Count -gt 0) { $detailLines[-1] } else { $detail }
            try {
                $errorPayload = $detailToParse | ConvertFrom-Json -Depth 16
                if ($errorPayload.PSObject.Properties.Name -contains 'error' -and $errorPayload.error) {
                    $detail = [string]$errorPayload.error
                }
            }
            catch {
            }
        }
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "The Python helper exited with code $($process.ExitCode)."
        }
        throw [System.Management.Automation.RuntimeException]::new("Foundry SDK CLI '$Subcommand' failed: $detail Install or refresh the pinned SDK dependencies with 'python -m pip install -r scripts/python/requirements.txt'.")
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
    try {
        return $stdout | ConvertFrom-Json -Depth 64
    }
    catch [System.ArgumentException] {
        throw [System.Management.Automation.RuntimeException]::new("Foundry SDK CLI '$Subcommand' returned invalid JSON. Raw output: $stdout")
    }
}

Export-ModuleMember -Function @(
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
    'Get-FoundryReleaseTarget',
    'Get-ReleaseRecordById',
    'New-FoundryAgentVersion',
    'Set-FoundryAgentActiveVersion',
    'Invoke-FoundryAgentRun',
    'Resolve-SecretReference',
    'New-ReleaseRecord',
    'Save-ReleaseRecord',
    'Get-LatestReleaseRecord'
)
