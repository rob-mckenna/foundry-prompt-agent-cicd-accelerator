# Deployment runbook

Operational procedures. Every command is copy-paste ready; replace the values in angle brackets.

Conventions used below:

- `<agent>` logical agent name, for example `operations-copilot`
- `<pkg>` package file name, for example `operations-copilot-2.1.0+ab12cd3.zip`
- `<sub>` subscription GUID

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

Connections carry credentials, so they are created once per environment outside IaC. Create them in the Azure
AI Foundry portal under **Management center > Connected resources**, or with `az cognitiveservices`. Name them
consistently across environments (`kb-search`, `orders-api`, `bing-grounding`), because the overlays build the
connection id from the name.

### 6. Verify the data plane contract

```powershell
$env:AZURE_SUBSCRIPTION_ID = '<sub>'
./scripts/New-AgentPackage.ps1 -AgentPath ./samples/simple-agent -OutputDirectory ./out
./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment dev -WhatIf   # no credentials used
./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment dev           # real deployment
```

If the preflight fails, see [troubleshooting.md](troubleshooting.md) TS-03 before changing anything else.

### 7. Configure the CI/CD platform

Follow the setup section of [diagrams/github-to-foundry.md](diagrams/github-to-foundry.md) or
[../azure-devops/README.md](../azure-devops/README.md). Repeat steps 2 to 7 for TEST, UAT and PROD.

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

---

## RB-03 Deploy to DEV

**Automatic.** Merging to `main` runs `deploy-dev.yml`: validate, package once, deploy, smoke test.

Record the **package id** and the **run id** from the job summary. Promotion needs the run id.

Manual equivalent:

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<sub>'
./scripts/New-AgentPackage.ps1 -AgentPath ./agents/<agent> -OutputDirectory ./out
./scripts/import-agent.ps1 -PackagePath ./out/<pkg> -Environment dev
./tests/smoke/Invoke-SmokeTest.ps1 -Environment dev -AgentName <agent> -ExpectedVersion <version>
```

---

## RB-04 Promote to TEST

**Who:** agent developer requests, platform team approves.

GitHub: run **deploy-test** with `sourceRunId` = the DEV run id, `agentName`, optionally
`evaluationSuitePath`, and `promoteToUat` false.

Azure DevOps: run the **deploy-test** pipeline; it consumes the DEV pipeline artifact through
`resources.pipelines`.

The run stops at the environment approval. The approver should check that the package id in the summary
matches the one recorded for DEV.

Manual equivalent:

```powershell
./scripts/promote-agent.ps1 -AgentName <agent> -FromEnvironment dev -ToEnvironment test `
  -ArtifactDirectory ./artifacts -ReleaseDirectory ./out/releases
```

`-ArtifactDirectory` must contain the DEV artifact. The script compares its content address with the DEV
release record and refuses a mismatch; it will not rebuild.

---

## RB-05 Promote to UAT and obtain business sign-off

**Who:** platform team plus business owner.

Run **deploy-test** with `promoteToUat` true, or in Azure DevOps set the `promoteToUat` parameter. UAT applies
its own approval.

UAT differences to expect and to explain to business testers:

- `gpt-4o` at temperature 0.2
- `code_interpreter` and `bing_grounding` disabled, so those requests get a "capability not available in this
  environment" answer
- evaluation threshold 0.90
- Key Vault references verified before the write

After testing, record the sign-off against the **release id** from the run summary, in your change system.
The release id is the durable link between the business decision and the exact bytes.

---

## RB-06 Deploy to PROD

**Who:** platform team plus service owner. **Prerequisites:** UAT succeeded and is signed off; an approved
change record.

GitHub: run **deploy-prod** with `sourceRunId` (the deploy-test run), `agentName`, `changeRecordId`,
`confirmProduction` (type the agent name again) and optionally `evaluationSuitePath`.

Azure DevOps: run **deploy-prod** with the same parameters.

Sequence:

1. Preflight validates the inputs and the artifact, then publishes the package id.
2. Approvers compare that package id with the UAT release record and approve.
3. The package is promoted with the PROD overlay.
4. Smoke and regression run. Failure triggers automatic rollback.

Post-deployment, within 15 minutes:

```powershell
./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName <agent> -ExpectedVersion <version>
```

Check the Application Insights dashboard for error rate and latency, confirm the release record was written,
tag the commit (see [branching-strategy.md](branching-strategy.md)), and close the change record with the
release id.

---

## RB-07 Roll back

**Who:** on-call engineer. **Duration:** 5 to 15 minutes. **Trigger:** failed smoke or regression, elevated
error rate, or an unacceptable behaviour change.

**Roll back first. Diagnose afterwards.**

GitHub: run the **rollback** workflow with the environment, `agentName`, the `packageRunId` whose artifact
contains the previous package, and a reason.

Azure DevOps: run the **rollback** pipeline with the same inputs.

Manual:

```powershell
az login
$env:AZURE_SUBSCRIPTION_ID = '<sub>'

# Confirm what is deployed and what it replaced
Get-Content ./out/releases/<agent>-prod-*.json | ConvertFrom-Json |
  Select-Object releaseId, packageId, @{n='previous';e={$_.previous.packageId}}

./scripts/Invoke-Rollback.ps1 -AgentName <agent> -Environment prod `
  -ArtifactDirectory ./artifacts -Reason 'INC-1234 elevated refusal rate' -WhatIf

./scripts/Invoke-Rollback.ps1 -AgentName <agent> -Environment prod `
  -ArtifactDirectory ./artifacts -Reason 'INC-1234 elevated refusal rate'

./tests/smoke/Invoke-SmokeTest.ps1 -Environment prod -AgentName <agent>
```

If the artifact cannot be found, the script fails rather than rebuilding. Retrieve it from the retained build
run or the package blob container and re-run with `-ArtifactDirectory` pointing at it. Never rebuild from
older source during an incident: that artifact was never verified.

After the rollback: confirm smoke tests pass, update the incident with the rollback release id, and fix
forward through the normal path.

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

Both flags are required and the justification is written to the log and the release record.

6. Within 48 hours, run the skipped UAT validation and record the result against the release id.

---

## RB-09 Rotate a secret

1. Add the new version in Key Vault.
2. If the overlay pins `SecretVersion`, update it, bump the agent version, and promote through the normal path.
3. If it does not pin a version, no deployment is needed; verify with:

```powershell
./scripts/import-agent.ps1 -PackagePath ./artifacts/<pkg> -Environment prod -ValidateSecretReferences -WhatIf
```

4. Run smoke tests in each environment, then disable the old version.

---

## RB-10 Detect and correct drift

Run weekly against UAT and PROD.

```powershell
az login
./scripts/export-agent.ps1 -Environment prod -AgentName <agent> -OutputPath ./out/drift-prod -Force
git diff --no-index ./agents/<agent>/instructions.md ./out/drift-prod/instructions.md
```

Any difference means someone changed the agent outside the pipeline. Treat it as an incident: capture the
current state for evidence, then redeploy the recorded package.

```powershell
./scripts/import-agent.ps1 -PackagePath ./artifacts/<pkg> -Environment prod
```

Prevent recurrence by removing human write access to the production project.

---

## RB-11 Decommission an agent

1. Confirm with the owner recorded in the manifest that no caller depends on it.
2. Remove the agent in each environment, highest first, using the Agent Service API or the portal. There is no
   delete script on purpose: destructive removal should be a deliberate, manual act.
3. Archive the final release record and the last package to long-term storage for your retention period.
4. Remove the agent folder and its regression cases in a pull request that states who approved the
   decommission.
5. Remove any connections, indexes and Key Vault secrets used only by that agent.
