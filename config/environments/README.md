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
- `packageStore.accountName`, `packageStore.container`
- `releaseStore.accountName`, `releaseStore.container`
- `deployment.approverGroups`

`azure.tenantId` and `azure.subscriptionId` use `${env:AZURE_TENANT_ID}` and `${env:AZURE_SUBSCRIPTION_ID}`
placeholders. The pipelines set those from GitHub or Azure DevOps variables, so no subscription identifier is
committed. Declare runtime placeholder names in `runtime.allowedVariables`; explicit `-RuntimeVariable` values
take precedence over allowlisted process values. Unresolved placeholders fail deployment. See
[environment management](../../docs/environment-management.md).

## SDK and retained REST contracts

`foundry.apiVersion` is explicit for retained legacy `export-agent.ps1 -RemoteAgentId` REST calls.
SDK deployment and live smoke/evaluation/regression do not send this setting to the SDK; changing it does not
qualify those paths. They need Python 3.10+ and the [pinned SDK dependencies](../../scripts/README.md);
agent-bound Conversations/Responses runtime explicitly uses `allow_preview=True`.

For a no-credential configuration preview, run from the repository root:

```powershell
$package = .\scripts\New-AgentPackage.ps1 -AgentPath .\samples\simple-agent -OutputDirectory .\out\quickstart
.\scripts\Test-AgentPackage.ps1 -PackagePath $package.PackagePath -Environment dev
$env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
$env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev -WhatIf
```

The GUIDs above are dummy identifiers for offline resolution only; replace both for real operations.
Real import performs a read-only Azure AI Projects SDK preflight before mutation. Plain `-WhatIf` returns
before that preflight or authentication; it cannot confirm the endpoint, identity, model or external tools.
Do not add `-ValidateSecretReferences` to an offline preview; that option reads Key Vault.

Managed live routing requires an enabled Responses endpoint with one explicit fixed-version selector at
100% traffic. Latest/dynamic/split selectors are unsupported. Manifest `agent.version` is semver, while
`agent.serviceVersion` is an opaque service identity. Release-bound tests verify the actual selection and
`Complete-Release.ps1` attests passing live evidence before promotion; see the
[runbook](../../docs/deployment-runbook.md).

**No authenticated Azure qualification has been performed for this tranche.** Qualify the SDK and any legacy
export path you use in a non-production project; offline results are not production certification.

## External setup

The IaC provisions base resources, not every dependency: model deployments, project connections, indexes and
content, vector stores and Function/API implementations need separate setup. Connections can use Entra
authentication and be IaC-created, but these templates do not create them. The Azure Functions queue sample
also requires Standard Setup and deployed Function code/dependencies, not just storage queues.

`deployment.approvalRequired` and `approverGroups` describe policy; configure and restrict GitHub Environment
rules or Azure DevOps checks externally. GitHub required reviewers are one-of, not approval by every listed
group. Use separate enforced gates for multiple independent sign-offs. PROD import/promote requires valid
`-ChangeRecordId` and `-BusinessSignoffId` even with `-WhatIf`; identifiers are not substitutes for approvals.

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
