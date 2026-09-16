# Sample: simple agent

The smallest useful agent. No tools, no retrieval, no external dependencies. Use it to prove the pipeline end
to end before you add capabilities, and as the reference for instruction-only agents such as triage,
classification and style assistants.

| Property | Value |
| --- | --- |
| Logical name | `simple-support-agent` |
| Tools | none |
| Data sensitivity | internal |
| Azure dependencies | one model deployment per environment |

## What it demonstrates

- The minimum valid manifest, instructions and four environment overlays.
- Progressive tightening: `gpt-4o-mini` at temperature 0.3 in DEV down to `gpt-4o` at 0.1 in PROD.
- A PROD overlay that supplies the `change_record` metadata key required by `config/environments/prod.json`.
- Evaluation cases that check refusal, handoff and resistance to prompt injection rather than only happy paths.

## Try it locally

```powershell
# 1. Offline validation of the whole repository
./scripts/Invoke-Validation.ps1

# 2. Build the immutable package
./scripts/New-AgentPackage.ps1 -AgentPath ./samples/simple-agent -OutputDirectory ./out

# 3. Inspect the exact payload that would be sent to PROD, without deploying
./scripts/import-agent.ps1 -PackagePath ./out/simple-support-agent-1.0.0+<sha>.zip -Environment prod -WhatIf
```

Step 3 needs no Azure credentials: `-WhatIf` prints the resolved payload and returns before any token is
requested.

## Deploy for real

Prerequisites, all user supplied:

1. A Foundry account and project per environment (see `infra/`).
2. A model deployment named as in each overlay (`gpt-4o-mini` for DEV and TEST, `gpt-4o` for UAT and PROD).
3. `config/environments/*.json` updated with your resource names and endpoints.
4. A signed-in Azure CLI session with the `Azure AI User` role on the target project.

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<your subscription guid>'
./scripts/import-agent.ps1 -PackagePath ./out/simple-support-agent-1.0.0+<sha>.zip -Environment dev
```

## Promotion

```powershell
./scripts/promote-agent.ps1 -AgentName simple-support-agent -FromEnvironment dev -ToEnvironment test -ArtifactDirectory ./out
```

The same bytes move forward. The TEST overlay inside the package is applied at deploy time.

## Change the PROD change record

`metadata.change_record` reads `${env:CHANGE_RECORD_ID}`. Set it in the pipeline rather than editing the
overlay for every release:

```powershell
$env:CHANGE_RECORD_ID = 'CHG-0043912'
```

If it is not set, the overlay's `variables.CHANGE_RECORD_ID` default of `CHG-0000000` applies. Change that
default to something your change process will reject if you want a missing change record to fail loudly.
