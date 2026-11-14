# Sample: simple agent

The smallest useful agent. No tools or retrieval; a live run still needs a Foundry project and model deployment.
Use it to qualify the pipeline before adding capabilities, and as a reference for instruction-only triage,
classification and style assistants.

| Property | Value |
| --- | --- |
| Logical name | `simple-support-agent` |
| Tools | none |
| Data sensitivity | internal |
| Azure dependencies | one model deployment per environment |

## What it demonstrates

- The minimum valid manifest, instructions and four environment overlays.
- Example model bindings: `gpt-4o-mini` at temperature 0.3 in DEV and `gpt-4o` at 0.1 in PROD.
  Qualify model versions, regional availability and retirement dates; these names are not lifecycle guarantees.
- A PROD overlay that supplies the `change_record` metadata key required by `config/environments/prod.json`.
- Evaluation cases that check refusal, handoff and resistance to prompt injection rather than only happy paths.

## Try it locally

```powershell
# Run from the repository root.
$ErrorActionPreference = 'Stop'

# 1. Build and capture the actual archive path.
$package = .\scripts\New-AgentPackage.ps1 -AgentPath .\samples\simple-agent -OutputDirectory .\out\quickstart
.\scripts\Test-AgentPackage.ps1 -PackagePath $package.PackagePath -Environment dev

# 2. Inspect the DEV structural summary and payload digest, without deploying.
$env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
$env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev -WhatIf
```

This needs neither Azure credentials nor Python. Explicit DEV verification avoids PROD change-record policy.
Plain `-WhatIf` withholds resolved values and returns before authentication/SDK calls. It does not qualify
Azure behaviour. The GUIDs are dummy identifiers; replace both for real operations.
For broader offline checks use `.\scripts\Invoke-Validation.ps1 -SkipInfrastructure`.

## Deploy for real

Prerequisites, all user supplied:

1. A Foundry account and project per environment (see `infra/`).
2. A model deployment named as in each overlay (`gpt-4o-mini` for DEV and TEST, `gpt-4o` for UAT and PROD).
3. `config/environments/*.json` updated with your resource names and endpoints.
4. An authenticated identity with the deployment roles and package/release storage configured as described
   in the [runbook](../../docs/deployment-runbook.md).
5. Python 3.10+ and the pinned SDK bridge, required for deployment **and live tests**.

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<your subscription guid>'
$env:AZURE_TENANT_ID = '<your tenant guid>'
python -m pip install -r .\scripts\python\requirements.txt
$deploy = .\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev
.\tests\smoke\Invoke-SmokeTest.ps1 -Environment dev -AgentName simple-support-agent -ExpectedVersion 1.0.0 `
  -ReleaseRecordPath $deploy.ReleaseRecord -ResultPath .\out\quickstart\smoke-dev.json
.\scripts\Complete-Release.ps1 -ReleaseRecordPath $deploy.ReleaseRecord -PackagePath $package.PackagePath `
  -SmokeResultPath .\out\quickstart\smoke-dev.json
```

Import returns `pending-verification`; only passing release-bound live gates and `Complete-Release.ps1`
can mark it `succeeded`. `-ExpectedVersion` is manifest semver, not the opaque service version recorded
as `agent.serviceVersion`. Runtime explicitly opts into the pinned SDK's preview agent-bound
Conversations/Responses path; see [pins and caveats](../../scripts/README.md).
**No authenticated Azure qualification has been performed for this tranche.**

## Promotion

```powershell
$promotion = .\scripts\promote-agent.ps1 -AgentName simple-support-agent -FromEnvironment dev -ToEnvironment test `
  -PackagePath $package.PackagePath -SourceReleaseRecordPath $deploy.ReleaseRecord
```

Run this only after DEV attestation succeeds and required approval controls are configured. The same bytes
move forward; the TEST overlay is applied at deploy time, and the new TEST release is pending until its own
smoke/evaluation/regression evidence is attested. Follow the [complete sequence](../../scripts/README.md).
Identical artifact bytes do not freeze model behaviour, and rollback does not revoke older service versions.

## Change the PROD change record

`metadata.change_record` reads `${env:CHANGE_RECORD_ID}`. Pass an approved `-ChangeRecordId` to
import/promote rather than editing and rebuilding the overlay for every release. PROD also requires a
durable `-BusinessSignoffId`; example formats are:

```powershell
$changeRecordId = 'CHG-0043912'
$businessSignoffId = 'BSO-0043912'
```

Missing or invalid references fail before deployment, including a PROD `-WhatIf`. These example identifiers
are not approvals. See the [runbook](../../docs/deployment-runbook.md) for the production procedure.
