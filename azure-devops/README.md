# Azure DevOps pipelines

Functionally equivalent to the GitHub Actions workflows in `.github/workflows`. Use one or the other; running
both against the same environments will produce competing release records.

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

The deployment logic exists once, in `deploy-stage.yml`. The four pipelines differ only in parameters, so a
change to deployment behaviour cannot drift between environments.

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
| Storage Blob Data Contributor | the release record container |

`infra/bicep` and `infra/terraform` create these assignments when you supply `deploymentPrincipalId` /
`deployment_principal_id`.

### 2. Variable groups

Create `foundry-agents-<env>` with two **non-secret** variables:

| Variable | Example | Notes |
| --- | --- | --- |
| `azureSubscriptionId` | `00000000-0000-0000-0000-000000000000` | Identifier, not a credential |
| `azureTenantId` | `11111111-1111-1111-1111-111111111111` | Identifier, not a credential |

Do not add secrets to these groups. Agent secrets belong in Key Vault and are referenced from the overlay
`secretRefs` block, resolved at deploy time by the workload identity.

### 3. Environments and approvals

Create `foundry-agents-dev`, `-test`, `-uat` and `-prod` under Pipelines > Environments.

| Environment | Checks |
| --- | --- |
| `foundry-agents-dev` | none |
| `foundry-agents-test` | Approval (platform team) |
| `foundry-agents-uat` | Approval (platform team and business owner), Business hours |
| `foundry-agents-prod` | Approval (platform team and service owner), Business hours, Exclusive lock, Branch control limited to `refs/heads/main` |

Approvals are configured on the Environment, never in YAML. A pull request to this repository therefore
cannot weaken a production gate.

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

On `main`: require a pull request, require the `validate` pipeline as build validation, require review from
the code owners listed in `.github/CODEOWNERS`, and block force push.

## Promotion flow

```
main merge -> deploy-dev.yml           (validate, package, deploy DEV)
              deploy-test.yml          (manual: approval -> TEST -> optional approval -> UAT)
              deploy-prod.yml          (manual: preflight -> approval -> PROD)
```

Each stage downloads the artifact rather than rebuilding it. `Test-AgentPackage.ps1` re-verifies checksums and
the content address before every deployment, so a tampered or mismatched artifact fails before any write.

## Rollback

Automatic: the deploy stage runs `Invoke-Rollback.ps1` when a post-deployment step fails, except in DEV where
`rollbackOnFailure` is false so that failures stay visible.

Manual: run `rollback.yml` with the environment, agent name and reason. It targets the same environment, so
the production approval applies to a rollback as well.

## Differences from the GitHub Actions implementation

| Concern | GitHub Actions | Azure DevOps |
| --- | --- | --- |
| Identity | `azure/login@v2` with OIDC, `id-token: write` | `AzureCLI@2` with a workload identity federation service connection |
| Approvals | GitHub Environment protection rules | Environment checks |
| Artifact hand-off | `actions/download-artifact` with `run-id` | `resources.pipelines` plus `download:` |
| Non-secret config | Environment `vars` | Variable group |
| Reuse | Reusable workflows (`workflow_call`) | Stage and step templates |
