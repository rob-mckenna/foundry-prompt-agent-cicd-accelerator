# Environment configuration

One file per deployment target. These files describe **where** an agent is deployed and **what policy applies
there**. They never contain secrets.

| File | Purpose |
| --- | --- |
| `dev.json` | Auto-deploy target for every merge to `main`. Most permissive tool policy. |
| `test.json` | Promotion target from DEV. Approval required. |
| `uat.json` | Business acceptance target. Responsible AI review required. |
| `prod.json` | Production. Tightest tool allow-list, lowest maximum temperature, change record required. |

Validated by `schemas/environment-config.schema.json`.

## Values you must replace

Everything below is an example and must be changed for your tenant:

- `azure.resourceGroup`, `azure.location`
- `foundry.accountName`, `foundry.projectName`, `foundry.projectEndpoint`
- `keyVault.name`, `keyVault.uri`
- `releaseStore.accountName`, `releaseStore.container`
- `governance.approverGroups`

`azure.tenantId` and `azure.subscriptionId` use `${env:AZURE_TENANT_ID}` and `${env:AZURE_SUBSCRIPTION_ID}`
placeholders. The pipelines set those from GitHub or Azure DevOps variables, so no subscription identifier is
committed. You can use `${env:NAME}` in any string value in these files.

## Pinning the Agent Service API version

`foundry.apiVersion` is deliberately explicit. The Agent Service data plane has shipped under several
api-versions and the response shapes differ. Confirm the value for your project before the first deployment:

```powershell
az account get-access-token --scope https://ai.azure.com/.default --query expiresOn --output tsv
# then, with the token acquired by the module:
./scripts/Invoke-Validation.ps1          # offline checks only
./scripts/import-agent.ps1 -PackagePath <pkg> -Environment dev -WhatIf
```

`import-agent.ps1` performs a read-only `GET /assistants?limit=1` preflight before any write. If the configured
`apiVersion` or endpoint is wrong, the deployment fails there with the HTTP status rather than producing a
partially configured agent.

## Governance fields

| Field | Effect |
| --- | --- |
| `allowedToolTypes` | A tool whose `type` is absent fails the deployment gate. |
| `maxDataSensitivity` | An agent classified above this level cannot deploy here. |
| `requireOwnerMetadata` | `owner.team` must be present in the manifest. |
| `requireResponsibleAiReview` | `classification.responsibleAiReviewId` must be set. |
| `requiredMetadataKeys` | Each key must exist in `metadata` in the manifest or overlay. |
| `maxTemperature` | Effective `model.parameters.temperature` must not exceed this value. |

Changes to `prod.json` should be treated as a governance change: require review from the platform team through
`CODEOWNERS`.
