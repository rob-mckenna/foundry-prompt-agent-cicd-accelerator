# Deployment runbook

Operational procedures for this community reference implementation; replace values in angle brackets.
These procedures have not been qualified against authenticated Azure deployment, inference or recovery.
Rehearse them in a non-production project before adoption.

Conventions used below:

- `<agent>` logical agent name, for example `operations-copilot`
- `<pkg>` package file name, for example `operations-copilot-2.1.0+ab12cd3.zip`
- `<sub>` subscription GUID

Real deploy, promote, rollback and export-by-name operations require Python 3.10+ plus the pinned SDK
dependencies:

```powershell
python -m pip install -r ./scripts/python/requirements.txt
```

Plain `import-agent.ps1 -WhatIf` returns before the SDK bridge or any Azure call is used.
`-ValidateSecretReferences` is the deliberate exception: it reads Key Vault before the preview return.
Rollback `-WhatIf` still validates live serving state; it is not an offline check.
`export-agent.ps1 -RemoteAgentId` remains the legacy REST fallback when you only have an opaque agent id.
Live tests require the SDK too; an assistant id alone is not a supported invocation target.

---

## RB-01 First-time platform setup

**Who:** platform engineer. **Duration:** 60 to 90 minutes per environment. **Prerequisites:** Owner or
Contributor plus User Access Administrator on the target subscription, and permission to create app
registrations.

### 1. Clone and validate locally

```powershell
git clone https://github.com/<owner>/foundry-prompt-agent-cicd-accelerator.git
cd foundry-prompt-agent-cicd-accelerator
./scripts/Invoke-Validation.ps1
```

Expect all checks to pass or to be reported as skipped. Skipped means the optional tool is not installed; it
never means a check silently passed.

### 2. Create the CI/CD identity

```powershell
az login
az account set --subscription <sub>

az ad app create --display-name 'foundry-agents-cicd-dev'
$appId = az ad app list --display-name 'foundry-agents-cicd-dev' --query '[0].appId' --output tsv
az ad sp create --id $appId
$principalId = az ad sp show --id $appId --query id --output tsv
$principalId   # you need this for the IaC parameters
```

Add a federated credential. GitHub:

```powershell
$credential = @{
  name = 'github-dev'
  issuer = 'https://token.actions.githubusercontent.com'
  subject = 'repo:<owner>/<repo>:environment:dev'
  audiences = @('api://AzureADTokenExchange')
} | ConvertTo-Json -Compress

$credential | Out-File -FilePath ./federated-credential.json -Encoding utf8
az ad app federated-credential create --id $appId --parameters ./federated-credential.json
Remove-Item ./federated-credential.json
```

Repeat for `test`, `uat` and `prod`, ideally with a separate app registration per environment so that a
compromised DEV identity cannot reach production.

For Azure DevOps, create an Azure Resource Manager service connection with **Workload identity federation
(automatic)**; Azure DevOps creates the credential for you.

No client secret is created at any point. If you find yourself running
`az ad app credential reset`, stop: something has gone wrong.

### 3. Provision the environment

Bicep:

```powershell
az group create --name rg-foundry-agents-dev --location eastus2

# Set deploymentPrincipalId and agentOperatorPrincipalId in the parameter file first.
az deployment group what-if --resource-group rg-foundry-agents-dev `
  --template-file infra/bicep/main.bicep --parameters infra/bicep/parameters/dev.bicepparam

az deployment group create --resource-group rg-foundry-agents-dev `
  --template-file infra/bicep/main.bicep --parameters infra/bicep/parameters/dev.bicepparam
```

Terraform:

```powershell
cd infra/terraform
$env:ARM_SUBSCRIPTION_ID = '<sub>'
$env:TF_VAR_subscription_id = '<sub>'
terraform init -backend-config=environments/dev.backend.hcl
terraform plan -var-file=environments/dev.tfvars -out=dev.tfplan
terraform apply dev.tfplan
cd ../..
```

### 4. Record the outputs

Copy the outputs into `config/environments/dev.json`: `foundry.accountName`, `foundry.projectName`,
`foundry.projectEndpoint`, `keyVault.name`, `keyVault.uri`, `releaseStore.accountName`.

### 5. Create the Foundry project connections

The supplied templates do not create project connections. Provision them once per environment through your
platform's supported connection-management process. Connections can use Microsoft Entra authentication and
can be managed through IaC; credential-based connections require appropriate secret handling, not plaintext
credentials in source or parameter files. Name them consistently across environments (`kb-search`,
`orders-api`, `bing-grounding`), because the overlays build the connection id from the name.

### 6. Verify the data plane contract

```powershell
$env:AZURE_SUBSCRIPTION_ID = '<sub>'
./scripts/New-AgentPackage.ps1 -AgentPath ./samples/simple-agent -OutputDirectory ./out
./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment dev -WhatIf   # no credentials used
./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment dev           # real deployment
```

If the preflight fails, see [troubleshooting.md](troubleshooting.md) TS-03 before changing anything else.
The real deployment path publishes the exact zip to the **target** environment package store, stages any prior
target package **and attested release JSON**, and durably writes prepared release/evidence state. It records
mutation started **before** calling SDK `create_version`, persists returned service identity, pins the new
version at 100%, and records completion only after reading back that selector. The release remains
`pending-verification` until `scripts/Complete-Release.ps1` attests the required post-deployment evidence.
Promotion never reuses the source release's `packageUri`; every
deploy, promotion, and rollback records the URI returned by the target store.

**Ordering/atomicity invariant:** no version creation may begin until candidate publication, prior-artifact
staging where applicable, prepared audit evidence, and mutation-started persistence have completed.
Version creation can affect first-deployment traffic before explicit activation; this is not a zero-exposure
deployment guarantee. Foundry changes and blob writes are not one transaction, so an ambiguous create outcome
remains potentially mutated. Any exception after mutation starts attempts a durable `failed` record and leaves
`deployment-evidence.json` with `mutationStarted`, `mutationCompleted`, and `priorArtifactStaged`.
Recovery-enabled CI makes at most one attempt when mutation started and a prior artifact was staged.
A first deployment has no rollback
target; its failed record is retained and recovery is an explicit known-good deployment, never a success report.

Managed live operation requires an enabled Responses endpoint with a single fixed concrete service version
at 100%. Existing latest/dynamic, split, disabled or unknown selectors are rejected before mutation; explicitly
pin a known version rather than using `versions.latest`. Missing agent is the supported first-deployment case.
An existing agent without an attested record mapping its serving version to retained bytes is not automatically
known-good; reconcile it before deployment. `latest.json` is the latest audit attempt, not active-state proof.

Repository validation has not executed this path against Azure; mocks and offline SDK construction/request
capture are not service qualification. Qualify the first deployment in a disposable project.
The bridge passes version description and custom metadata through supported `create_version` arguments,
and the offline tests cover the `agent_version` and
`environment` metadata contract used by smoke.

### 7. Configure the CI/CD platform

Follow the setup section of [diagrams/github-to-foundry.md](diagrams/github-to-foundry.md) or
[../azure-devops/README.md](../azure-devops/README.md). On self-hosted runners or Azure DevOps agents, make
Python 3.10+ available and install `scripts/python/requirements.txt` before any real deploy, promote or
export-by-name step. Repeat steps 2 to 7 for TEST, UAT and PROD.

---

## RB-02 Onboard a new agent

**Who:** agent developer. **Duration:** 30 minutes plus authoring time.

```powershell
Copy-Item -Recurse ./templates/prompt-agent ./agents/<agent>
```

1. Edit `agent.manifest.json`: `name` (lowercase kebab, permanent), `version` `1.0.0`, `displayName`,
   `description`, `owner`, `classification` including `responsibleAiReviewId` if you will reach UAT.
2. Write `instructions.md`. Replace every `REPLACE-` marker.
3. Add tools from `templates/tools/`, reference them from the manifest, bind values with `${env:...}`.
4. Set each overlay's `model.deploymentName` to a deployment that exists in that environment.
5. Add `metadata.service`; PROD also needs `change_record`, which the shipped overlays read from
   `${env:CHANGE_RECORD_ID}`.
6. Replace the evaluation dataset with cases for your scenario, including refusals and negative lookups.
7. Add a regression case file under `tests/regression/cases/`.

```powershell
./scripts/Invoke-Validation.ps1
./scripts/New-AgentPackage.ps1 -AgentPath ./agents/<agent> -OutputDirectory ./out
foreach ($e in 'dev','test','uat','prod') {
  ./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment $e -WhatIf
}
```

Open a pull request. The merge deploys to DEV automatically.

For a portal-authored agent, export first and treat the generated files as a draft: review every mapping,
complete governance data and overlays, and merge them through the same pull-request path. Do not delete the
portal-authored version until the pipeline-created replacement is active, its release is attested, and its
smoke checks pass.

---

## RB-03 Deploy to DEV

**Automatic.** Merging to `main` runs `deploy-dev.yml`: validate, package once, set up Python, install the
SDK bridge dependencies, deploy, smoke test, then run `scripts/Complete-Release.ps1` to attest the release.

Record the **package id**, **release id** and **run id** from the job summary. Promotion needs the run id.
Manifest semver (`-ExpectedVersion`) and opaque `agent.serviceVersion` are separate identities.

Manual equivalent:

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<sub>'
./scripts/New-AgentPackage.ps1 -AgentPath ./agents/<agent> -OutputDirectory ./out
$deploy = ./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment dev
./tests/smoke/Invoke-SmokeTest.ps1 -Environment dev -AgentName <agent> -ExpectedVersion <version> `
  -ReleaseRecordPath $deploy.ReleaseRecord -ResultPath ./out/smoke-dev.json
./scripts/Complete-Release.ps1 -ReleaseRecordPath $deploy.ReleaseRecord -PackagePath ./out/<pkg> `
  -SmokeResultPath ./out/smoke-dev.json
```

That final step moves the record from `pending-verification` to `succeeded` or `failed`.
All attestable runner results must use the exact returned `ReleaseRecord` path, never rediscover
`latest.json`. Required smoke needs at least one successful live canary; `-SkipLiveRun` and configuration-only
checks cannot attest it.

---

## RB-04 Promote to TEST

**Who:** agent developer requests, platform team approves.

GitHub: run **deploy-test** with `sourceRunId` = the DEV run id, `agentName`, optionally
`evaluationSuitePath`, and `promoteToUat` false.

Azure DevOps: run the **deploy-test** pipeline; it consumes the DEV pipeline artifact through
`resources.pipelines`.

The run stops at the environment approval. The approver should check that the package id in the summary
matches the one recorded for DEV.

GitHub Actions and the shipped Azure DevOps shared stage run smoke, evaluation, regression and
`scripts/Complete-Release.ps1` automatically after promotion. For manual operation outside those pipelines,
run the same gate scripts and attest the release explicitly before treating TEST as promotable.

Manual equivalent:

```powershell
$promotion = ./scripts/promote-agent.ps1 -AgentName <agent> -FromEnvironment dev -ToEnvironment test `
  -ArtifactDirectory ./artifacts -ReleaseDirectory ./out/releases
./tests/smoke/Invoke-SmokeTest.ps1 -Environment test -AgentName <agent> -ExpectedVersion <version> `
  -ReleaseRecordPath $promotion.ReleaseRecord -ResultPath ./out/smoke-test.json
./tests/evaluations/Invoke-EvaluationSuite.ps1 -SuitePath ./agents/<agent>/evaluations/<suite>.json `
  -Environment test -AgentName <agent> -ReleaseRecordPath $promotion.ReleaseRecord -ResultPath ./out/evaluation-test.json
./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName <agent> `
  -ReleaseRecordPath $promotion.ReleaseRecord -ResultPath ./out/regression-test.json
./scripts/Complete-Release.ps1 -ReleaseRecordPath $promotion.ReleaseRecord -PackagePath ./artifacts/<pkg> `
  -SmokeResultPath ./out/smoke-test.json -EvaluationResultPath ./out/evaluation-test.json `
  -RegressionResultPath ./out/regression-test.json
```

`-ArtifactDirectory` must contain the DEV artifact. The script compares its content address with the DEV
release record and refuses a mismatch; it will not rebuild. Attestation compares live result identities
and timestamps with this release/configuration, validates completed Response evidence and required thresholds,
and retains result-byte hashes. Fixtures, baseline updates, skipped/empty runs, unbound results or a prior
attempt's results cannot authorize this release. A packaged minimum evaluation score requires live evidence
even if `requireEvaluationPass` is false.

---

## RB-05 Promote to UAT and obtain business sign-off

**Who:** platform team plus business owner.

Run **deploy-test** with `promoteToUat` true, or in Azure DevOps set the `promoteToUat` parameter. UAT applies
its own approval. Both shipped CI implementations run the gate scripts and `scripts/Complete-Release.ps1`
automatically after promotion; for manual operation outside those pipelines, repeat the TEST pattern and
attest the release explicitly.

UAT differences to expect and to explain to business testers:

- `gpt-4o` at temperature 0.2
- `code_interpreter` and `bing_grounding` disabled, so those requests get a "capability not available in this
  environment" answer
- evaluation threshold 0.90
- Key Vault references verified before the write

After testing, create a durable business sign-off reference in the form `BSO-` followed by 4-10 digits and
link it to the **attested release id** from the run summary. Supply that `businessSignoffId` to PROD; the
production release record stores it with the exact package, change record, and Responsible AI review reference.

---

## RB-06 Deploy to PROD

**Who:** platform team plus service owner. **Prerequisites:** UAT succeeded and is signed off; an approved
change record.

GitHub: run **deploy-prod** with `sourceRunId` (the deploy-test run), `agentName`, `changeRecordId`,
`businessSignoffId`, `confirmProduction` (type the agent name again) and optionally `evaluationSuitePath`.

Azure DevOps: run **deploy-prod** with the same parameters.

Sequence:

1. Preflight validates the inputs and the artifact, then publishes the package id.
2. Approvers compare that package id with the UAT release record and approve.
3. The package is promoted with the PROD overlay, creating a `pending-verification` release record.
4. Smoke, regression and any configured evaluation suite run against PROD.
5. `scripts/Complete-Release.ps1` attests that evidence and moves the record to `succeeded` or `failed`.
6. On failure, the attestation step records `failed` and throws. The workflow keys its single automatic rollback
   attempt on durable mutation-started plus prior-artifact-staged evidence, including when import/promote itself
   exits nonzero after creation may have occurred. The handler calls the centralized, gate-verified
   `Invoke-Rollback.ps1` path. `Complete-Release.ps1` is not also invoked with `-RollbackOnFailure` in that
   workflow. A first deployment instead surfaces explicit manual recovery. The original deployment job still
   fails even if recovery succeeds.

Post-deployment, within 15 minutes:

```powershell
./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName <agent> -ExpectedVersion <version>
```

Check the Application Insights dashboard for error rate and latency, confirm the final release record outcome
is `succeeded`, tag the commit (see [branching-strategy.md](branching-strategy.md)), and close the change
record with the release id.

---

## RB-07 Roll back

**Who:** on-call engineer. **Duration:** 5 to 15 minutes. **Trigger:** failed gate attestation
(`scripts/Complete-Release.ps1`), elevated error rate, or an unacceptable behaviour change.

**Verify the exact recovery context before mutation.** Deploy, test and rollback must use the same
agent/environment concurrency lock. GitHub shares a concurrency group; Azure DevOps requires an exclusive-lock
check on the same Environment with sequential lock behaviour. Out-of-band concurrent routing edits are outside
the supported contract; before/after routing checks cannot prove the absence of every transient edit.

In GitHub Actions, a failed `scripts/Complete-Release.ps1` step or potentially mutating import/promote failure triggers
the workflow's separate rollback step using the prior artifact staged by import. The handler keys off persisted
`mutationStarted=true` and `priorArtifactStaged=true`, not command success, so a pre-mutation failure cannot
select an older package. Azure DevOps uses the same evidence-driven, single-handler contract. Use this procedure
when that attempt cannot restore service or when you are operating by hand.
Import stages the prior ZIP and exact known-good release JSON under `<ReleaseDirectory>\rollback-staged`
by default, so both travel with the retained release-record artifact. `-RollbackStageDirectory` overrides
that location; retain both files when customizing it.

GitHub: run the **rollback** workflow with the environment, `agentName`, `packageRunId`, `packageArtifactName`,
and `releaseRecordPath` (the exact failed/current release JSON path inside the downloaded artifact), plus a
reason. Retain the prior package and its exact known-good release JSON alongside that context.
Supply `evaluationSuitePath` when the rollback target overlay requires evaluation or a minimum score.
PROD also requires a rollback `changeRecordId` and `businessSignoffId`; the record preserves both the rollback
change reference and the original release change.

Azure DevOps: select the retained source pipeline run and supply `environmentName`, `agentName`, a reason,
`releaseRecordPath` relative to `Pipeline.Workspace`, and the applicable evaluation/governance inputs.

Manual:

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<sub>'

# Select the exact failed/current attempt, not latest.json or an arbitrary wildcard match.
$releaseContext = '.\artifacts\<failed-or-current-releaseId>.json'
Get-Content $releaseContext -Raw | ConvertFrom-Json |
  Select-Object releaseId, packageId, agent, previous

./scripts/Invoke-Rollback.ps1 -AgentName <agent> -Environment prod `
  -ArtifactDirectory ./artifacts -Reason 'INC-1234 elevated refusal rate' `
  -ReleaseRecordPath $releaseContext -EvaluationSuitePath .\artifacts\<suite>.json `
  -ChangeRecordId CHG-0044002 -BusinessSignoffId BSO-0043912 -WhatIf

./scripts/Invoke-Rollback.ps1 -AgentName <agent> -Environment prod `
  -ArtifactDirectory ./artifacts -Reason 'INC-1234 elevated refusal rate' `
  -ReleaseRecordPath $releaseContext -EvaluationSuitePath .\artifacts\<suite>.json `
  -ChangeRecordId CHG-0044002 -BusinessSignoffId BSO-0043912
```

`Invoke-Rollback.ps1` checks that the current serving version is the recorded candidate or prior version,
rejecting a stale failure that would undo an unrelated deployment. `-ToPackageId`, if supplied, must match
that context's prior known-good release. The retained JSON is resolved from `previous.releaseRecordPath` or
the exact `<previous.releaseId>.json` under `-ArtifactDirectory`; package bytes alone are insufficient.

The script deploys the prior package as a **new service version**, runs every gate required by its target
overlay, and calls `Complete-Release.ps1` without recursive recovery. Only `operation=rollback` with
`outcome=succeeded` means verified recovery; pending or failed attestation is not success. No manual duplicate
test/attestation step is required. A failed rollback preserves evidence and exits nonzero.

If the artifact or known-good record cannot be found, the script fails rather than rebuilding. Retrieve them
from the retained run or package/release stores and re-run with `-ArtifactDirectory` pointing at them.
Never rebuild from older source during an incident: that artifact was never verified.

After verified rollback, update the incident with its new release/service version and evidence, and fix
forward through the normal path. Model deployments, knowledge, connections and secrets are not restored by
package replay. First deployment without a prior artifact requires an explicit known-good deployment and
manual recovery; never report it as an automatic rollback.

---

## RB-08 Emergency change

Only when rollback is not the answer, for example a required behaviour change for a live regulatory issue.

1. Branch `hotfix/<incident-id>`, minimal change, bump the patch version.
2. Expedited review, but the same required checks. Do not bypass `validate`.
3. Merge; DEV deploys automatically.
4. Promote to TEST with an abbreviated suite.
5. Promote to PROD with an emergency change record. If UAT must be skipped:

```powershell
./scripts/promote-agent.ps1 -AgentName <agent> -FromEnvironment test -ToEnvironment prod `
  -ArtifactDirectory ./artifacts -AllowSkipEnvironment `
  -Justification 'INC-1234 severity 1, CAB approval CHG-0044001'
```

Both flags are required. The justification is written to the pipeline log; the current release-record writer
does not persist it.

6. Within 48 hours, run the skipped UAT validation and record the result against the release id.

---

## RB-09 Rotate a secret

1. Add the new version in Key Vault.
2. If the overlay pins `SecretVersion`, update it, bump the agent version, and promote through the normal path.
3. If it does not pin a version, no deployment is needed; verify with an authenticated Key Vault read:

```powershell
./scripts/import-agent.ps1 -PackagePath ./artifacts/<pkg> -Environment prod -ValidateSecretReferences -WhatIf
```

4. Run smoke tests in each environment, then disable the old version.

---

## RB-10 Detect and correct drift

Run weekly against UAT and PROD.

```powershell
az login
python -m pip install -r ./scripts/python/requirements.txt
./scripts/export-agent.ps1 -Environment prod -AgentName <agent> -OutputPath ./out/drift-prod -Force
git diff --no-index ./agents/<agent>/instructions.md ./out/drift-prod/instructions.md
```

Export is a best-effort qualification, not a canonical round trip. By-name uses the SDK's active version,
separate from `latestVersion`, under the supported pinned-routing contract;
opaque `-RemoteAgentId` uses the retained legacy REST get-by-id path. Review `export-notes.md` and generated
tool mappings before deciding whether a difference is drift. Confirmed differences should be treated as an
incident: capture the current state for evidence, then redeploy the recorded package.

```powershell
./scripts/import-agent.ps1 -PackagePath ./artifacts/<pkg> -Environment prod
```

Prevent recurrence by removing human write access to the production project.

---

## RB-11 Decommission an agent

1. Confirm with the owner recorded in the manifest that no caller depends on it, and export the current portal
   state for evidence.
2. Remove the agent folder and regression cases in a reviewed pull request that states who approved the
   decommission. Merge the pull request before any portal deletion.
3. Verify the pipeline has processed the merged state and, when replacing a portal-authored agent, verify the
   pipeline-created version and its attested release record before deleting the portal-authored version.
4. Archive the final release record, export, and last package to long-term storage for your retention period.
5. Only then remove the agent in each environment, highest first, using the Agent Service API or portal. There
   is no delete script: destructive removal remains a deliberate, reviewed act.
6. Remove connections, indexes, and Key Vault secrets used only by that agent.
