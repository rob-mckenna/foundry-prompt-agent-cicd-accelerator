# Scripts

PowerShell 7 automation. Every script sets `#Requires -Version 7.2`, `Set-StrictMode -Version 3.0` and
`$ErrorActionPreference = 'Stop'`. Every script that changes state declares `SupportsShouldProcess`, so
`-WhatIf` and `-Confirm` work everywhere they should.

## Overview

| Script | Purpose | Azure needed | Mutates |
| --- | --- | --- | --- |
| `Invoke-Validation.ps1` | Full offline validation of the repository | no | no |
| `New-AgentPackage.ps1` | Build the immutable, content-addressed package | no | local files |
| `Test-AgentPackage.ps1` | Verify integrity, content address and per-environment resolution | no | no |
| `import-agent.ps1` | Deploy a package to one environment | yes | remote agent |
| `promote-agent.ps1` | Promote the identical artifact to the next environment | yes | remote agent |
| `Invoke-Rollback.ps1` | Redeploy the previously promoted package | yes | remote agent |
| `export-agent.ps1` | Capture a portal-built agent as source | yes, read only | local files |
| `modules/FoundryAgentOps` | Shared module used by all of the above and by the tests | - | - |

## Authentication

No script accepts a credential. They rely on an existing Azure CLI session:

| Context | How the session is established |
| --- | --- |
| Local | `az login` |
| GitHub Actions | `azure/login@v2` with OIDC and `permissions: id-token: write` |
| Azure DevOps | `AzureCLI@2` with a workload identity federation service connection |

`Get-FoundryAccessToken` calls `az account get-access-token --scope <tokenScope>` and immediately converts the
result to a `SecureString`. Tokens are passed to `Invoke-RestMethod` with `-Authentication Bearer -Token`, so
no bearer value is ever assembled into a header string, a log line or a command line argument.

## Common workflows

### Validate everything, offline

```powershell
./scripts/Invoke-Validation.ps1
./scripts/Invoke-Validation.ps1 -SkipInfrastructure        # faster inner loop
./scripts/Invoke-Validation.ps1 -IncludeTerraformValidate  # also runs terraform init and validate
```

### Build and verify

```powershell
$result = ./scripts/New-AgentPackage.ps1 -AgentPath ./agents/my-agent -OutputDirectory ./out
$result.PackageId
./scripts/Test-AgentPackage.ps1 -PackagePath $result.PackagePath
```

### Preview a deployment without Azure

```powershell
$env:AZURE_SUBSCRIPTION_ID = '<subscription guid>'
./scripts/import-agent.ps1 -PackagePath ./out/my-agent-1.0.0+abc1234.zip -Environment prod -WhatIf
```

`-WhatIf` resolves the overlay, evaluates governance and prints the exact Agent Service payload, then returns
before a token is requested.

### Deploy, promote, roll back

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<subscription guid>'

./scripts/import-agent.ps1  -PackagePath ./out/my-agent-1.0.0+abc1234.zip -Environment dev
./scripts/promote-agent.ps1 -AgentName my-agent -FromEnvironment dev -ToEnvironment test -ArtifactDirectory ./out
./scripts/Invoke-Rollback.ps1 -AgentName my-agent -Environment test -ArtifactDirectory ./out -Reason 'INC-1234'
```

### Capture an existing agent

```powershell
./scripts/export-agent.ps1 -Environment dev -RemoteAgentId asst_0123456789 -OutputPath ./agents/legacy-agent
```

Read `export-notes.md` afterwards. It lists everything the export could not decide for you.

## The FoundryAgentOps module

`modules/FoundryAgentOps/FoundryAgentOps.psd1`, 33 exported functions grouped as follows.

**Configuration and resolution**

| Function | Purpose |
| --- | --- |
| `Get-EnvironmentConfig` | Load and schema-validate `config/environments/<env>.json` |
| `Get-AgentSourceLayout` | Locate the manifest, overlays and package root |
| `Resolve-AgentDefinition` | Merge manifest, overlay and tool definitions into the effective definition |
| `Merge-Hashtable` | Deep merge; arrays and scalars replace |
| `Expand-Placeholder` | Iterative `${env:...}` expansion with explicit unresolved reporting |
| `Get-PlaceholderName` | Enumerate placeholders in an object graph |

**Validation**

| Function | Purpose |
| --- | --- |
| `Test-JsonFileSchema` | Draft-07 validation with the built-in `Test-Json` |
| `Test-YamlFile` | Layered YAML check: `powershell-yaml`, then PyYAML, then a structural lint; reports which was used |
| `Test-PowerShellSyntax` | Language-parser check; never executes the file |
| `Test-AgentGovernance` | Evaluate an agent against an environment policy |

**Packaging**

| Function | Purpose |
| --- | --- |
| `New-ChecksumManifest` | Deterministic sorted SHA-256 manifest |
| `Get-PackageId` | Content address from the checksum manifest |
| `Test-ChecksumManifest` | Detect missing, extra and modified files; recompute the content id |
| `Read-PackageDescriptor` | Read and validate `package.json` |
| `Expand-AgentPackage` | Extract and verify, refusing a tampered package |

**Agent Service**

| Function | Purpose |
| --- | --- |
| `Get-FoundryAccessToken` | Token as a `SecureString` from the current CLI session |
| `Invoke-FoundryApi` | REST wrapper with retry on 429 and 5xx and explicit failures |
| `Test-FoundryEndpoint` | Read-only preflight that pins down endpoint and api-version problems before any write |
| `Get-FoundryAgent` | Find the managed agent by recorded id or by `managed_by` plus `logical_name` metadata |
| `ConvertTo-FoundryAgentPayload` | Manifest to Agent Service payload; unknown tool types raise an error |
| `Invoke-FoundryAgentRun` | One prompt, one thread, cleaned up afterwards; used by the test runners |
| `Resolve-SecretReference` | Key Vault reference to `SecureString` |

**Release records**

| Function | Purpose |
| --- | --- |
| `New-ReleaseRecord` | Build the audit record including the previous state |
| `Save-ReleaseRecord` | Write locally and upload with `--auth-mode login` |
| `Get-LatestReleaseRecord` | Read `latest.json` from the release store, with a local fallback |

Import it directly when you want to inspect behaviour:

```powershell
Import-Module ./scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1 -Force
Get-Command -Module FoundryAgentOps | Sort-Object Name
Get-Help Resolve-AgentDefinition -Full
```

## Extending

- **New tool type:** add it to `schemas/tool-definition.schema.json` and add a branch to
  `ConvertTo-FoundryAgentPayload`. Do not add a default that skips unknown types.
- **Different deployment interface:** replace the bodies of `Invoke-FoundryApi` and
  `ConvertTo-FoundryAgentPayload`. Nothing else in the accelerator talks to Azure directly.
- **Different release store:** implement `Save-ReleaseRecord` and `Get-LatestReleaseRecord` for your backend
  and add the type to `schemas/environment-config.schema.json`.
- **New governance rule:** add it to `Test-AgentGovernance` and to the `governance` block in
  `schemas/environment-config.schema.json`, then add a negative unit test.

## Conventions

| Rule | Reason |
| --- | --- |
| Strict mode 3.0 everywhere | Typos in property names fail loudly |
| `SupportsShouldProcess` on mutating scripts | `-WhatIf` is a first-class rehearsal, not an afterthought |
| Typed, validated parameters | Bad input fails at the boundary with a useful message |
| Catch specific exception types | A broad catch hides the failure you needed to see |
| Errors state cause and next action | The message is the first line of the runbook |
| Secrets stay `SecureString` | Never logged, never on a command line, never packaged |
| No silent fallback | A guessed default in a deployment pipeline is a future incident |

`Invoke-Validation.ps1` enforces the first two mechanically for the mutating scripts.
