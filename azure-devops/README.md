# Azure DevOps pipelines

Azure Pipelines equivalents of the GitHub flows. The shared deployment stage installs the pinned Python bridge
dependencies, captures the pending release record, attests post-deployment evidence, and uses the staged prior
artifact plus attested release JSON for verified rollback. Running both CI systems against the same
environments requires a shared external lock; their native locks do not coordinate with each other.
**No authenticated Azure qualification has been performed for this tranche.** These templates are not
production certification; qualify federation, approvals, SDK routing/runtime and recovery in non-production.

## Files

| File | Trigger | Purpose |
| --- | --- | --- |
| `pipelines/validate.yml` | PR and push to main | Offline validation. No service connection. Use as a build validation policy. |
| `pipelines/deploy-dev.yml` | Push to main, paths filtered | Validate, package once, deploy to DEV unattended. |
| `pipelines/deploy-test.yml` | Manual | Promote the DEV package to TEST, optionally on to UAT. |
| `pipelines/deploy-prod.yml` | Manual | Preflight, approval, promote the UAT package to PROD. |
| `pipelines/rollback.yml` | Manual | Redeploy the previously promoted package to any environment. |
| `pipelines/templates/stages/deploy-stage.yml` | - | The single deployment stage used by every environment. |
| `pipelines/templates/steps/validate.yml` | - | Offline validation steps. |
| `pipelines/templates/steps/package.yml` | - | Immutable package build and publish. |
| `pipelines/templates/variables/common.yml` | - | Non-secret shared variables. |

The common deployment logic is centralized in `deploy-stage.yml`; pipeline wrappers supply environment
parameters and artifact hand-offs.

## One-time setup

### 1. Service connections (workload identity federation)

Create one per environment: `foundry-agents-dev`, `foundry-agents-test`, `foundry-agents-uat`,
`foundry-agents-prod`.

Use **Azure Resource Manager** with **Workload identity federation (automatic)**. No client secret is created,
stored or rotated. Grant each service principal:

| Role | Scope |
| --- | --- |
| Azure AI User | the environment's Foundry account or project |
| Key Vault Secrets User | the environment's Key Vault |
| Storage Blob Data Contributor | package and release storage |

`infra/bicep` and `infra/terraform` create these assignments when you supply `deploymentPrincipalId` /
`deployment_principal_id`.

### 2. Variable groups

Create `foundry-agents-<env>` with two **non-secret** variables:

| Variable | Example | Notes |
| --- | --- | --- |
| `azureSubscriptionId` | `00000000-0000-0000-0000-000000000000` | Identifier, not a credential |
| `azureTenantId` | `11111111-1111-1111-1111-111111111111` | Identifier, not a credential |

Do not add secrets to these groups. Configure runtime authentication in Foundry project connections, using
Entra where supported. Connections can be IaC-created, but the supplied templates do not create them. Overlay
`secretRefs` are optional Key Vault readability checks only; the current SDK bridge does not inject their
values into an agent definition.

### 3. Environments and approvals

Create `foundry-agents-dev`, `-test`, `-uat` and `-prod` under Pipelines > Environments.

| Environment | Checks |
| --- | --- |
| `foundry-agents-dev` | Exclusive lock; no approval |
| `foundry-agents-test` | Approval (platform team), Exclusive lock |
| `foundry-agents-uat` | Approval (platform team and business owner), Business hours, Exclusive lock |
| `foundry-agents-prod` | Approval (platform team and service owner), Business hours, Exclusive lock, Branch control limited to `refs/heads/main` |

Approvals/checks are configured on the Environment, not created by this YAML. Restrict who can administer
environments and service connections, and configure the intended approval policy explicitly.
Deploy, test and rollback must use the same environment lock; `lockBehavior: sequential` only has an effect
when the external Exclusive lock check exists. Serialize out-of-band operations separately.

### 4. Pipeline resource names

`deploy-test.yml` and `deploy-prod.yml` consume the artifact of the upstream pipeline through a
`resources.pipelines` entry. Update the `source:` values to the names you gave the pipelines:

```yaml
resources:
  pipelines:
    - pipeline: devPipeline
      source: foundry-agents-deploy-dev   # <- your DEV pipeline name
```

This is what guarantees promotion moves the identical artifact rather than a rebuild.

### 5. Branch policy

On `main`: require a pull request, require the `validate` pipeline as build validation, configure required
reviewers corresponding to `.github/CODEOWNERS`, and block force push. Azure DevOps does not automatically
enforce GitHub's CODEOWNERS file.

### 6. Agent image and attestation

Real deploy, promote, rollback and live smoke/evaluation/regression operations require Python 3.10+ and the
exact pins in `scripts/python/requirements.txt`. The shipped deployment and rollback pipelines select Python
3.11 and install those pins before invoking the SDK-backed scripts. A self-hosted agent must allow `UsePythonVersion@0` and pip,
or provide the same versions on its image. The pins are `azure-ai-projects==2.7.0`,
`azure-identity==1.26.0`, `azure-core==1.41.0` and `openai==3.17.0`. Runtime explicitly opts into preview
with `allow_preview=True` and uses the agent-bound Conversations/Responses client, not classic thread/run REST.

The shared stage captures the deploy/promote result's exact `ReleaseRecord`, passes it as
`-ReleaseRecordPath` to live runners, and runs `Complete-Release.ps1` after completed activation even if a gate
fails. Missing or failed required evidence records a failed attestation before the separate rollback handler.
Import/promote returns `pending-verification`, not a successful release. Standalone/offline fixtures and
configuration-only smoke cannot attest it; each target needs passing release-bound live evidence.
`agentVersion`/smoke `-ExpectedVersion` is manifest semver, distinct from opaque `agent.serviceVersion`.

## Promotion flow

```
main merge -> deploy-dev.yml           (validate, package, deploy DEV)
              deploy-test.yml          (manual: approval -> TEST -> optional approval -> UAT)
              deploy-prod.yml          (manual: preflight -> approval -> PROD)
```

Each stage downloads the artifact rather than rebuilding it. `Test-AgentPackage.ps1` re-verifies checksums and
the content address before every deployment, so a tampered or mismatched artifact fails before any write.
The `/2` content ID binds stable descriptor/source identity; identical IDs need not mean identical ZIP bytes.
The store rejects differing archive bytes at an existing ID. Retain the original archive across environments;
target overlays can change model/tool bindings, and external data/model behaviour is not frozen by packaging.
Promotion also downloads the source stage's attested release-record artifact and passes it to
`promote-agent.ps1`; the target identity does not need cross-environment release-store access.
After TEST succeeds, that stage republishes the unchanged `agentPackage` from the DEV resource as an artifact
of the TEST run. The optional UAT stage consumes that current-run artifact, while PROD promotion and manual
rollback consume the tested bytes from `testPipeline`, all without rebuilding.

## Rollback

Automatic attempt: after recorded mutation has started and a prior known-good artifact was staged, the
deploy stage runs `Invoke-Rollback.ps1` on failure, except in DEV where `rollbackOnFailure` is false.
The handler uses the exact failed attempt and returned staging directory, not an unrelated `latest.json`.
Default staging is `ReleaseDirectory\rollback-staged`, retaining both prior ZIP and attested release JSON.
A failure before mutation does not trigger recovery; the attestation step does not separately request rollback.

Manual: run `rollback.yml` with environment, agent name, reason, the exact failed/current release-record
artifact path, and an evaluation suite when the target overlay requires evaluation or a minimum score.
It targets the same environment, so production approvals and the shared lock also apply.
`Invoke-Rollback.ps1` centrally creates a new service version of the retained package, runs required live
gates and calls `Complete-Release.ps1`; the pipeline publishes its result without duplicate verification.
Success means `operation=rollback`, `outcome=succeeded`, not merely redeployed/pending. Verification failure
remains failed; the original deployment job still fails after successful recovery. A first deployment without
a prior release needs manual recovery. Rollback does not revoke older versions or revert external knowledge,
models or tools. See [the runbook](../docs/deployment-runbook.md).

## Differences from the GitHub Actions implementation

| Concern | GitHub Actions | Azure DevOps |
| --- | --- | --- |
| Identity | `azure/login@v2` with OIDC, `id-token: write` | `AzureCLI@2` with a workload identity federation service connection |
| Approvals | Externally configured Environment rules; required reviewers are one-of, not all listed teams | Externally configured Environment checks |
| Artifact hand-off | `actions/download-artifact` with `run-id` | `resources.pipelines` plus `download:` |
| Non-secret config | Environment `vars` | Variable group |
| Reuse | Reusable workflows (`workflow_call`) | Stage and step templates |
