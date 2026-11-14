# Scripts

PowerShell 7 automation. Entry points require PowerShell 7.2, strict mode and stop-on-error behavior.
Regular deployment scripts expose `SupportsShouldProcess`. The separately gated qualification driver
instead requires a frozen-source hosted phase; it deliberately has no skip, force, resume or WhatIf mode.

Real deployment, promotion, rollback, live smoke/evaluation/regression and export-by-name operations require
Python 3.10+ plus the pinned SDK dependencies in `scripts/python/requirements.txt`:

```powershell
python -m pip install -r .\scripts\python\requirements.txt
```

The pins are `azure-ai-projects==2.7.0`, `azure-identity==1.26.0`, `azure-core==1.41.0` and
`openai==3.17.0`. Runtime explicitly uses `allow_preview=True` and the agent-bound OpenAI
Conversations/Responses client; this is a preview-dependent path, not a GA assurance. No authenticated Azure
qualification has been performed for this tranche; offline SDK request capture is not live service evidence.

Plain `-WhatIf` still returns before any Azure or Python SDK call. `-ValidateSecretReferences` deliberately
reads Key Vault before that return and therefore is not an offline rehearsal. `export-agent.ps1
-RemoteAgentId` still uses the legacy REST path without the Python dependency.

## Overview

| Script | Purpose | Azure needed | Mutates |
| --- | --- | --- | --- |
| `Invoke-Validation.ps1` | Full offline validation of the repository | no | no |
| `Invoke-DevQualification.ps1` | Default-off, separately approved frozen-source qualification phase | not PrivacyProof; yes otherwise | Experiment only (cloud) |
| `New-AgentPackage.ps1` | Build the immutable, content-addressed package | no | local files |
| `Test-AgentPackage.ps1` | Verify integrity, content address and per-environment resolution | no | no |
| `import-agent.ps1` | Deploy a package to one environment | yes | remote agent |
| `promote-agent.ps1` | Promote the identical artifact to the next environment | yes | remote agent |
| `Invoke-Rollback.ps1` | Redeploy the previously promoted package | yes | remote agent |
| `Complete-Release.ps1` | Attest release-bound live evidence | yes | release record |
| `export-agent.ps1` | Capture a portal-built agent as source | yes, read only | local files |
| `modules/FoundryAgentOps` | Shared module used by all of the above and by the tests | - | - |

## Authentication

No script accepts a credential. Legacy export-by-ID acquires a token from the existing Azure CLI session;
the Python bridge authenticates deployment and live runtime independently with `DefaultAzureCredential`
against the same local or federated identity context:

| Context | How the session is established |
| --- | --- |
| Local | `az login` |
| GitHub Actions | `azure/login@v2` with OIDC and `permissions: id-token: write` |
| Azure DevOps | `AzureCLI@2` with a workload identity federation service connection |

The optional qualification job is different: its installed Azure CLI interpreter invokes OIDC login
in-process, so the federated token is not an OS process argument. Azure CLI/MSAL **can persist the
assertion and session/access state on disk**. The entire fresh, owner-restricted
`out/qualification/authentication/run-<run-id>` directory is transient credential-bearing material,
separate from ordinary scratch and exported evidence; never inspect, upload or retain its contents.
The pinned SDK
credential chain is restricted to that CLI session with `AZURE_TOKEN_CREDENTIALS=AzureCliCredential`.
After the final Azure/storage consumer, an `always()` real-phase finalizer removes only the recorded
job-created directory and verifies absence. Login/driver failure also enters that finalizer; an unowned,
aliased or unverifiable path fails closed, without touching a default/shared CLI cache.
Earlier results are explicitly phase-only, authentication teardown pending; teardown failure fails the job.
This is bounded best effort on trusted ephemeral standard hosted runners. Forced termination, runner
loss or timeout enforcement can prevent finalization and leave files until runner disposal. It is not
credential revocation, cryptographic erasure or proof of disposal, and does not support persistent/shared
self-hosted runners.
This depends on the hosted Ubuntu CLI layout and fails closed if it changes; it is pending independent
review and hosted proof, not an already qualified authentication path.
Qualification source checkout is anonymous and frozen to the reviewed SHA on this public repository;
it has no checkout token, credential helper or persisted Git authentication. Private-repository use
is intentionally unsupported by this path rather than introducing a credential-argv fallback.

`Get-FoundryAccessToken` calls `az account get-access-token --scope <tokenScope>` and immediately converts the
result to a `SecureString`. Tokens are passed to `Invoke-RestMethod` with PowerShell's bearer authentication,
so no bearer value is assembled into a header string, a log line or a command-line argument. This token is
used only by retained legacy get-by-ID export, not by deployment or live runtime.

## Common workflows

### Optional bounded DEV qualification — pending hosted proof

See [RB-12](../docs/deployment-runbook.md#rb-12-optional-bounded-dev-qualification-pending)
for the ordered review/privacy/preflight/experiment gates. Only `-Phase`, `-ExpectedCommit`,
`-PrivacyProofRunId`, `-PreflightRunId` and a repository-local ignored `-PrivateRoot` are accepted;
configuration and credentials are not CLI arguments. The driver is not a local live-test command.

The qualification path alone passes `-DisableCreateRetries` through import, the module/bridge and
central rollback. This sets supported Azure Core retry options to zero on the version-creation client.
Ordinary callers retain their existing defaults. Runtime Responses already use zero SDK retries.
`FOUNDRY_QUALIFICATION_PRIVATE_ROOT` is an internal scratch-directory binding, validated beneath
`out/qualification`; absent that binding, existing deployment work paths are unchanged.
That binding also requires a typed, verified invocation-cleanup result before either existing live runner
can continue. Conversation DELETE and each acquired-resource close are attempted once; failed/ambiguous
cleanup withholds usable output and stops subsequent inference, including B's expected-failure path and C.
Private receipts distinguish primary invocation status, invocation cleanup and evidence-first agent removal.
Successful agent removal alone cannot mark failed invocation cleanup verified. Ordinary callers retain
their previous completed-with-warning cleanup behavior.

### Validate everything, offline

```powershell
.\scripts\Invoke-Validation.ps1
.\scripts\Invoke-Validation.ps1 -SkipInfrastructure        # faster inner loop
.\scripts\Invoke-Validation.ps1 -IncludeTerraformValidate  # also runs terraform init and validate
```

### Build and verify

```powershell
$package = .\scripts\New-AgentPackage.ps1 -AgentPath .\samples\simple-agent -OutputDirectory .\out\quickstart
$package.PackageId
.\scripts\Test-AgentPackage.ps1 -PackagePath $package.PackagePath -Environment dev
```

`-Environment dev` selects DEV resolution/policy checks while still verifying the entire archive's integrity
and content ID. Without it, verification checks every packaged overlay, including PROD change-record policy.
`foundry-agent-package/2` binds stable descriptor fields and source checksums, excluding informational build
time/run/ref/builder fields from the ID. Equal content IDs need not mean equal ZIP bytes; a store must reject
different archive bytes at an existing ID. Promotion moves the original ZIP unchanged, with the target overlay.
Strict descriptor-bound `/1` verification remains supported; there is no weaker fallback for malformed packages.
See [the package specification](../docs/package-format.md) for the canonical identity algorithm.

### Preview a deployment without Azure

```powershell
# Dummy identifiers for offline configuration resolution, not credentials.
$env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
$env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev -WhatIf
```

Plain `-WhatIf` resolves the overlay, evaluates governance and prints a structural summary plus a payload
digest. Resolved values are withheld because they can expose tenant topology; it returns before a token or the
Python bridge is requested. This is a structural preview, not Azure qualification. PROD previews still need
valid `-ChangeRecordId` and `-BusinessSignoffId`; use DEV for a tenant-neutral offline quickstart.

### Deploy, attest, then promote

Run from the repository root, after the build above and tenant setup in the
[deployment runbook](../docs/deployment-runbook.md). This example uses the simple sample's DEV and TEST gates;
other overlays can require different evidence. Do not continue after a failed command.

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<subscription guid>'
$env:AZURE_TENANT_ID = '<tenant guid>'
$ErrorActionPreference = 'Stop'

$deploy = .\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev
.\tests\smoke\Invoke-SmokeTest.ps1 -Environment dev -AgentName simple-support-agent -ExpectedVersion 1.0.0 `
  -ReleaseRecordPath $deploy.ReleaseRecord -ResultPath .\out\quickstart\smoke-dev.json
.\scripts\Complete-Release.ps1 -ReleaseRecordPath $deploy.ReleaseRecord `
  -PackagePath $package.PackagePath -SmokeResultPath .\out\quickstart\smoke-dev.json

# DEV must now be succeeded and attested. Hosted approval gates must also be configured.
$promotion = .\scripts\promote-agent.ps1 -AgentName simple-support-agent -FromEnvironment dev -ToEnvironment test `
  -PackagePath $package.PackagePath -SourceReleaseRecordPath $deploy.ReleaseRecord
.\tests\smoke\Invoke-SmokeTest.ps1 -Environment test -AgentName simple-support-agent -ExpectedVersion 1.0.0 `
  -ReleaseRecordPath $promotion.ReleaseRecord -ResultPath .\out\quickstart\smoke-test.json
.\tests\evaluations\Invoke-EvaluationSuite.ps1 -SuitePath .\samples\simple-agent\evaluations\baseline.evaluation.json `
  -Environment test -AgentName simple-support-agent -ReleaseRecordPath $promotion.ReleaseRecord `
  -ResultPath .\out\quickstart\evaluation-test.json
.\tests\regression\Invoke-RegressionTest.ps1 -Environment test -AgentName simple-support-agent `
  -ReleaseRecordPath $promotion.ReleaseRecord -ResultPath .\out\quickstart\regression-test.json
.\scripts\Complete-Release.ps1 -ReleaseRecordPath $promotion.ReleaseRecord `
  -PackagePath $package.PackagePath -SmokeResultPath .\out\quickstart\smoke-test.json `
  -EvaluationResultPath .\out\quickstart\evaluation-test.json -RegressionResultPath .\out\quickstart\regression-test.json
```

GitHub Actions invokes `Complete-Release.ps1` automatically inside `_reusable-deploy.yml`, and the shipped
Azure DevOps deploy stage does the same. Outside those pipelines, call it explicitly: import/promote activates
a candidate but leaves it `pending-verification`, which cannot be promoted. `latest.json` is the latest audit
attempt, not proof of the active or known-good version.

Every attestable runner must receive the exact operation's `-ReleaseRecordPath`, not a rediscovered latest
record. `-ExpectedVersion` is manifest semver; release `agent.serviceVersion` is the distinct opaque SDK
identity. Evidence binds release/package/agent/environment/project/semver/service version and post-activation
execution times. Required smoke needs a completed live canary; offline fixtures, `-SkipLiveRun`, zero-case,
baseline-update and unbound standalone results cannot satisfy live release gates. See
[tests/README.md](../tests/README.md) for runner contracts.

Before version creation, import publishes candidate bytes, stages the prior package and its attested release
JSON where available, and durably records mutation intent. It records service identity and verifies the
100% fixed-version Responses endpoint selection before recording activation completion. Unsupported routing
fails closed; deployment, testing and rollback must share an agent/environment lock. These controls are not a
zero-exposure deployment guarantee or service-signed attestation. See the [runbook](../docs/deployment-runbook.md).

### Roll back with verified recovery

Use the exact failed/current operation's release record and the retained prior ZIP **and** attested release
JSON. For example, after a later TEST promotion fails with a retained known-good prior release (not the first
deployment to TEST):

```powershell
.\scripts\Invoke-Rollback.ps1 -AgentName simple-support-agent -Environment test `
  -ArtifactDirectory .\out\releases\rollback-staged -ReleaseRecordPath $promotion.ReleaseRecord `
  -EvaluationSuitePath .\samples\simple-agent\evaluations\baseline.evaluation.json -Reason 'INC-1234'
```

Default staging is under `ReleaseDirectory\rollback-staged`; use the actual returned staging location when
you customize release storage. `Invoke-Rollback.ps1` creates a new service version of the known-good package,
runs the target overlay's required live gates, and calls `Complete-Release.ps1` itself. No separate successful
redeploy or pending record proves recovery. The first deployment has no prior known-good release to restore.
Rollback does not revoke older versions or revert model deployments, external indexes or tool services.

### Capture an existing agent

```powershell
.\scripts\export-agent.ps1 -Environment dev -AgentName managed-agent -OutputPath .\agents\managed-agent
# Legacy portal agent that can only be identified by opaque assistant id:
.\scripts\export-agent.ps1 -Environment dev -RemoteAgentId asst_0123456789 -OutputPath .\agents\legacy-agent
```

By-name export reads the active service version through SDK discovery, not simply latest.
`-RemoteAgentId` uses the retained REST get-by-ID fallback. Neither path is a lossless qualification:
read `export-notes.md`, review every generated tool
mapping and placeholder, complete owner/classification data, and create the other environment overlays.

## The FoundryAgentOps module

`modules/FoundryAgentOps/FoundryAgentOps.psd1` exports the shared helpers. The principal groups are summarised below;
use `Get-Command` for the complete list.

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
| `Get-PackageId` | Descriptor-aware content address from stable identity and source checksums |
| `Test-ChecksumManifest` | Detect missing, extra and modified files; recompute the content id |
| `Read-PackageDescriptor` | Read and validate `package.json` |
| `Expand-AgentPackage` | Extract and verify, refusing a tampered package |

**Agent Service**

| Function | Purpose |
| --- | --- |
| `Get-FoundryAccessToken` | Token as a `SecureString` from the current CLI session |
| `Invoke-FoundryApi` | Retained REST wrapper for legacy get-by-ID export |
| `Test-FoundryEndpoint` | Read-only Azure AI Projects SDK preflight that confirms endpoint, auth and SDK availability before any write; it does not validate the REST `apiVersion` |
| `Get-FoundryAgent` | SDK discovery with separate latest/active versions, or legacy export-by-ID fallback |
| `New-FoundryAgentVersion` | Create a new agent service version through the SDK |
| `Set-FoundryAgentActiveVersion` | Set and read back a concrete single-version selector at 100% traffic |
| `ConvertTo-FoundryAgentPayload` | Manifest to Agent Service payload; unknown tool types raise an error |
| `Invoke-FoundryAgentRun` | Agent-bound SDK Conversations/Responses call; verifies service-version routing before/after and attempts conversation cleanup |
| `Get-FoundryReleaseTarget` | Validate the exact release/config identity and supported active selection for live gates |
| `Resolve-SecretReference` | Key Vault reference to `SecureString` |

**Release records**

| Function | Purpose |
| --- | --- |
| `New-ReleaseRecord` | Build the audit record including the previous state |
| `Save-ReleaseRecord` | Write locally and upload with `--auth-mode login` |
| `Get-LatestReleaseRecord` | Read the latest audit attempt, not necessarily a succeeded or active release |

Import it directly when you want to inspect behaviour:

```powershell
Import-Module .\scripts\modules\FoundryAgentOps\FoundryAgentOps.psd1 -Force
Get-Command -Module FoundryAgentOps | Sort-Object Name
Get-Help Resolve-AgentDefinition -Full
```

## Extending

- **New tool type:** add it to `schemas/tool-definition.schema.json` and add a branch to
  `ConvertTo-FoundryAgentPayload`. Do not add a default that skips unknown types.
- **Different deployment interface:** update the Python SDK bridge under `scripts/python/` and
  `ConvertTo-FoundryAgentPayload` together with the shared `Invoke-FoundryAgentRun` runtime contract.
  Deployment/discovery and live smoke/evaluation/regression all use the SDK bridge; do not silently fall back
  to classic thread/run APIs.
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
