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

#### GitHub OIDC subject formats

Match the exact subject configured for your repository and job environment. Repositories created after
July 15, 2026, or renamed/transferred after that date, use the immutable owner/repository-ID default.
Earlier repositories retain the legacy default unless opted in. This rollout excludes GitHub Enterprise
Server. See [GitHub's immutable subject guidance](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims).

These are inert default-format examples; replace placeholders privately, never with published target IDs:

| Job context | Immutable-ID subject | Legacy name-only subject |
| --- | --- | --- |
| `environment: dev` | `repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:dev` | `repo:<OWNER>/<REPO>:environment:dev` |
| `environment: prod` | `repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:prod` | `repo:<OWNER>/<REPO>:environment:prod` |

An environment-bound default subject takes precedence over branch/tag context; it does not restrict which
branches may deploy. Configure environment deployment protection separately. Branch/tag default subjects
apply only without an environment and outside pull-request context. Encode colons inside environment names
as `%3A`.

[Custom subject templates](https://docs.github.com/en/actions/reference/security/oidc#customizing-the-subject-claims-for-an-organization-or-repository)
can replace the default structure; organization templates require repository opt-in. Match the complete
customized subject and configure cloud trust before changing templates. Immutable IDs cannot be removed
from the `repo` segment through `include_claim_keys`.

The [issuer, subject and audience must match case-sensitively](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation#how-it-works).
The infrastructure templates consume an existing principal; they do not create or migrate federated
credentials. Authentication configuration alone grants no resource permissions.

Add the GitHub federated credential using your exact environment-bound subject:

```powershell
$credential = @{
  name = 'github-dev'
  issuer = 'https://token.actions.githubusercontent.com'
  subject = '<exact-environment-bound-subject>'
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
   is no general-purpose delete script: destructive removal remains a deliberate, reviewed act.
6. Remove connections, indexes, and Key Vault secrets used only by that agent.

---

## RB-12 Optional bounded DEV qualification (pending)

**Status:** source implementation awaiting independent Tester, Security and Reviewer gates, then actual
hosted privacy proof and read-only preflight. Existing offline/PR checks are not live/OIDC qualification.
Do not dispatch Experiment merely because CI is green. This path does not qualify ordinary deployment,
Azure DevOps, TEST/UAT/PROD, production readiness, model immutability or independent approval.

The existing `deploy-dev` workflow defaults `qualificationMode` to **false**. Ordinary push/manual behavior
is unchanged. Explicit qualification mode excludes every ordinary validate/package/deploy/summary job and
never invokes generic reusable deployment, artifact uploads or automatic recovery.

### External setup and human gates

The maintainer must separately approve/configure the exact private DEV target, dedicated OIDC UAMI,
project-scoped runtime grant, two container-scoped data grants, and thirty-day private evidence retention.
Use the approved feature-branch restriction, administrative bypass disabled and manual DEV self-approval.
Self-approval is operator authorization, **not** independent review or separation of duties.

Inject these thirteen operational values as individual DEV **environment secrets**, not variables or
credentials: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
`QUAL_FOUNDRY_RESOURCE_GROUP`, `QUAL_FOUNDRY_ACCOUNT`, `QUAL_FOUNDRY_PROJECT`,
`QUAL_PROJECT_ENDPOINT`, `QUAL_MODEL_DEPLOYMENT`, `QUAL_STORAGE_ACCOUNT`,
`QUAL_PACKAGE_CONTAINER`, `QUAL_RELEASE_CONTAINER`, `QUAL_EXPERIMENT_ID`, `QUAL_AGENT_NAME`.
Never put their actual values in source, dispatch inputs, driver arguments, outputs or public artifacts.
The unique agent must remain exclusively reserved; the fixed qualification concurrency group does not
provide a shared lock with normal deployment, ADO or out-of-band operators.

One additional benign `QUAL_PRIVACY_SENTINEL` seed is a reviewed setup detail; do not overwrite any real
value or create another environment for proof. The first configuration-consuming shell step validates and
masks all identifiers before exports, action inputs or login. PrivacyProof receives only the inert seed.
It derives thirteen independently hashed typed canaries and uses the same validation/mask/export helper.
It requests no OIDC token, constructs no Azure client, accesses no Azure target and performs no inference.

For **each** phase, independently reviewed source is frozen as a full `expectedCommit` SHA on
`squad/sdk-first-qualification`, matching dispatch/workflow/checkout SHA and run attempt 1:

1. Manually approve `PrivacyProof`. Inspect **complete** setup, normal, negative-case, finalizer and post-job
   logs, annotations, summaries and files. Confirm fixed log probes are masked and public non-log channels
   contain only the allowlisted result. A failed, cancelled or incompletely inspected run is not proof.
2. Separately approve `Preflight`, referencing that accepted `privacyProofRunId`. It uses the real thirteen
   values and OIDC once; verifies CLI tenant/subscription/client identity, exact SDK model, absent agent and
   both containers with OAuth; it creates no agent/version/claim/conversation and performs no inference.
   Inspect its **complete** real-binding logs/output before proceeding. Use the private provisioning readback
   for account/network/RBAC controls; no parent read/role fallback is implied.
3. Only after both reviews, approve one `Experiment` with both proof run IDs at that same SHA and unchanged
   private target/budget. Source or dependency drift invalidates prior acceptance. Action revisions are
   pinned for this path; inspect the recorded SDK pins and installed CLI version too.

Run IDs are operator-reviewed references, not API-authenticated proof of human inspection. One seed proves
one automatically registered original-secret header plus thirteen derived explicit-mask cases, **not**
thirteen independently observed original-secret headers, all transformations or guaranteed cancellation
coverage. Real Preflight supplies the remaining observed binding coverage. Masking is defense in depth;
summaries/files use suppression and a separate allowlist, not a masking assumption.

### One irreversible budget claim, evidence first

The driver accepts only `-Phase`, `-ExpectedCommit`, optional proof run IDs and optional `-PrivateRoot`
beneath ignored `out/qualification`. There are no target/credential, retry, resume, force, cleanup-only or
skip-gate switches. Runtime scratch and raw streams stay private; script summaries/outputs are redirected.
OIDC login uses the installed Azure CLI interpreter in-process; credentials never become OS arguments.
This does **not** prevent disk persistence: CLI/MSAL may cache the federated assertion and access/session
state. The whole fresh, owner-restricted `out/qualification/authentication/run-<run-id>` directory is
credential-bearing and separate from ordinary scratch and recursively exported evidence. Do not inspect,
archive, upload or include it in any evidence inventory. Pre-existing paths, ownership drift and symlink/
reparse aliases block use/removal; there is no inherited/default/global cache deletion fallback.
Existing internal helpers may carry noncredential metadata in argv within the trusted runner boundary.
Privileged runner administrators or compromised same-job code can inspect memory/environment/metadata;
this is not argv-free execution or OS-level metadata isolation.

Before any service mutation, an OAuth create-if-absent audit claim binds identities, SHA/run/proof references
and the **shared** maximum of three version creates/nine Responses creates across all attempts. An existing
claim refuses every rerun/re-dispatch. Each A/B/C reservation durably consumes one create and three possible
sends before calls; persistence failure blocks calls. Ambiguous operations consume allowance, with no refund.
Management CREATE and Responses have zero automatic retries. This cooperative guard is not a hard request
quota or dollar cap.

- **A:** original private DEV-only 1.0.0 package; two existing smoke canaries and the first delivery evaluation
  record execute live, bound to its exact release; attest succeeded and durably retain original ZIP/JSON.
- **B:** 1.0.1 plus a benign instruction change, same real model. Only smoke's deliberately unequal
  model-expectation assertion may fail. Both live canaries and its one evaluation must pass. Attestation
  must persist B as failed using unedited originals; exception text alone is insufficient.
- **C:** central rollback receives B's exact failed record, actual staged A artifact/JSON, copied ConfigRoot
  and live suite. It creates a new service version and owns its two smoke/one evaluation/attestation.
  No outer rerun, fourth create, tenth send or recursive automatic rollback is allowed.

An unexpected failure stops normal progression. Retain all available original evidence; do not reinterpret
it as the expected B failure. In qualification context, the bridge returns `PrimaryStatus` and a typed
`InvocationCleanup` envelope. Each known conversation DELETE and acquired-resource close is attempted once
within the invocation deadline, without retry. A failed/ambiguous cleanup withholds usable success output;
the module persists a bounded private receipt and throws before either runner can start another invocation.
This also applies to central C rollback. Ordinary nonqualification warning behavior is unchanged.
Original ZIPs go to the package container; original release/mutation/gate/
selector evidence, private logs and a hash inventory go to the audit container. Verify exact OAuth
readback bytes before cleanup. Export failure, unknown inventory, ambiguous ownership, identity or route
drift prevents deletion. Only the exact claimed agent/owned versions may be deleted; verify absence and
retain its receipt. Infrastructure, federation, grants and their continuing costs remain until a separate
teardown decision. Later human evidence access needs existing authorization or separate narrow approval.
Retaining failed-experiment evidence and safely removing its agent cannot make that experiment successful.
Private `agentRemovalVerified` is distinct from invocation cleanup; public generic `cleanupVerified` stays
false after failed/unverified invocation cleanup. A secondary retention/removal error does not erase the
primary failure or reopen the irreversible budget.

Only after the last Azure/storage consumer, including failure-evidence export and guarded agent removal,
does the real-phase workflow `always()` finalizer remove the exact job-owned CLI directory and verify
local absence. It also runs after handled login/driver failure. Catchable removal/verification failure emits
only `QUAL_AUTH_CLEANUP_FAILED` and fails the job; no re-login or Azure logout is performed. Not-created
and verified-removed are distinct constant receipts. PrivacyProof neither authenticates nor proves real
authentication teardown.

This lifecycle assumes a trusted ephemeral standard hosted runner, not a shared/persistent/self-hosted host.
Cancellation runs cleanup only where the runner still executes steps. Forced termination, timeout enforcement,
runner loss or process kill may prevent finalization and leave credential-bearing files until hosted-runner
disposal; do not claim infallible cleanup, secure memory erasure, credential revocation or independent proof
of disposal.

Public output is a separately constructed fixed allowlist of phase/status, reviewed SHA, bounded reserved
counts and expected-failure/recovery/retention/cleanup booleans. It is explicitly **phase-only**, with
authentication teardown pending for real phases. Whole-job success additionally requires the finalizer's
verified result; an earlier phase pass is not an unqualified qualification pass. Exit 0 means actual phase postconditions
passed, 2 means blocked before entering the experiment, 1 means failure after claiming it. Never upload
arbitrary `out` directories or raw evidence. A successful bounded configuration-failure/recovery scenario
is not an outage/model-regression test or a passed B release.
