# Troubleshooting

Each entry lists the symptom, the cause, and the fix. Errors in this accelerator are intentionally specific,
so the message text is the fastest way to find the right entry.

---

## TS-01 `Unresolved configuration placeholders: X, Y`

**Symptom.** Deployment stops before contacting Azure.

**Cause.** A `${env:...}` placeholder has no value in the overlay `variables` map and no matching process
environment variable.

**Fix.** Find where the placeholder is used and decide where the value belongs.

```powershell
Select-String -Path ./agents/<agent> -Pattern '\$\{env:X\}' -Recurse
```

- Environment-specific and non-secret: add it to `variables` in each overlay.
- Supplied by the pipeline: set it as an environment variable in the job. The samples expect
  `AZURE_SUBSCRIPTION_ID`, and the PROD overlays expect `CHANGE_RECORD_ID`.
- Secret: it does not belong in `variables`. Use `secretRefs` with a Key Vault reference.

The deployment fails rather than substituting an empty string, which is what stops a production agent from
binding to a nonexistent index.

---

## TS-02 `Governance policy for environment 'prod' rejected agent '<agent>'`

**Symptom.** Deployment stops after resolution, listing one violation per line.

**Causes and fixes.**

| Violation text | Fix |
| --- | --- |
| `Tool '<id>' of type '<type>' is not in the allowed tool list` | Disable the tool for that environment with `toolOverrides`, or get `allowedToolTypes` widened through the governance change process. Do not widen it in the same pull request as the agent change. |
| `Tool '<id>' declares allowedEnvironments that exclude '<env>'` | The tool definition itself forbids this environment. Disable it in the overlay or change the declaration deliberately. |
| `Agent data sensitivity 'X' exceeds the maximum 'Y'` | The agent is classified above what the environment permits. Either the classification is wrong or the environment is not approved for this workload. |
| `Manifest is missing owner.team` | Add `owner.team` and `owner.contact`. |
| `requires classification.responsibleAiReviewId` | UAT and PROD require a recorded Responsible AI review reference. |
| `Required metadata key 'change_record' is missing` | Set `CHANGE_RECORD_ID` in the job; the PROD overlay maps it into metadata. |
| `Model temperature X exceeds the '<env>' maximum` | Lower `model.parameters.temperature` in that overlay. |

Reproduce offline, with no Azure access:

```powershell
Import-Module ./scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1 -Force
$definition = Resolve-AgentDefinition -Path ./agents/<agent> -Environment prod -SkipPlaceholderExpansion
$config = Get-EnvironmentConfig -Environment prod -SkipPlaceholderExpansion
(Test-AgentGovernance -Definition $definition -EnvironmentConfig $config).Violations
```

---

## TS-03 `Agent Service call failed: GET /assistants returned HTTP 404`

**Symptom.** The preflight fails before any write.

**Causes, in order of likelihood.**

1. **`projectEndpoint` is wrong.** It must be the data plane endpoint including the project path:

   ```
   https://<account>.services.ai.azure.com/api/projects/<project>
   ```

   Not the portal URL, not the management plane resource id, not the account endpoint without
   `/api/projects/<project>`.

2. **`apiVersion` does not match the project.** The Agent Service has shipped under several api-versions with
   different paths and response shapes. Confirm the value with your Foundry project, then update
   `config/environments/<env>.json`.

3. **The project does not exist**, or the account was created without `allowProjectManagement`.

Verify the control plane state:

```powershell
az cognitiveservices account show --name <account> --resource-group <rg> --query '{kind:kind, endpoints:properties.endpoints}'
```

The preflight exists precisely so that this becomes a clear failure rather than a partially configured agent.

---

## TS-04 `HTTP 401` or `HTTP 403` from the Agent Service

**401.** No token, or the wrong audience.

- The job did not sign in. GitHub needs `permissions: id-token: write` and `azure/login@v2`; Azure DevOps
  needs the call inside an `AzureCLI@2` task.
- `foundry.tokenScope` is wrong. It should be `https://ai.azure.com/.default`.

**403.** Authenticated but not authorised.

```powershell
az account show --query '{name:name, user:user.name}'    # confirm which identity is signed in
az role assignment list --assignee <principalId> --all --output table
```

The deployment identity needs **Azure AI User** on the Foundry account or project. Role assignments can take
several minutes to propagate.

If the agent deploys but cannot retrieve anything, you are looking at the wrong identity. The **project**
managed identity, not the deployment identity, reads your knowledge sources at run time. See
[diagrams/agent-knowledge-tools.md](diagrams/agent-knowledge-tools.md).

---

## TS-05 `Package integrity check failed` or `Package content id mismatch`

**Symptom.** Deployment refuses to start.

**Cause.** A file inside the package changed after it was built, or `package.json` no longer matches the files
on disk.

**Common non-malicious causes.**

- The package was extracted, edited and re-zipped.
- A tool rewrote line endings. `.gitattributes` forces LF for this reason; confirm `core.autocrlf` is not
  rewriting files in the agent that builds the package.
- Two different artifacts were mixed in the same folder.

**Fix.** Do not patch the package. Rebuild from source, or download the original artifact again.

```powershell
./scripts/Test-AgentPackage.ps1 -PackagePath ./artifacts/<pkg>   # lists missing, extra and modified files
```

---

## TS-06 `No package in '<dir>' matches package id 'sha256:...'`

**Symptom.** Promotion or rollback cannot find the artifact.

**Causes.**

1. The artifact aged out of retention. Increase retention above your promotion window and rollback horizon.
2. The wrong run id was supplied. Check the source environment's release record for the expected package id.
3. The artifact was downloaded to a different path than `-ArtifactDirectory`.

**Why it does not just rebuild.** A rebuild is not the artifact that was verified in the source environment.
Promoting or rolling back to a rebuild would silently break the guarantee that production runs what UAT
tested.

```powershell
# What does the source environment say it is running?
Get-Content ./out/releases/<agent>-uat-*.json | ConvertFrom-Json |
  Select-Object releaseId, packageId, @{n='previous';e={$_.previous.packageId}} | Format-List
```

---

## TS-07 `No release record found for '<agent>' in '<env>'`

**Symptom.** Promotion or rollback cannot establish history.

**Causes.**

- Nothing has been deployed to that environment yet. Deploy before promoting from it.
- The release store is unreachable, or the identity lacks **Storage Blob Data Contributor** on the container.
- `-ReleaseDirectory` points somewhere that does not hold the local copy.

```powershell
az storage blob list --account-name <storage> --container-name agent-releases `
  --prefix '<agent>/<env>/' --auth-mode login --output table
```

Deployment still works without a release record: `Get-FoundryAgent` falls back to metadata discovery using
`managed_by` and `logical_name`. Promotion and rollback do not, because they need to know which exact package
was deployed.

---

## TS-08 `Tool '<id>' has unsupported type '<type>'`

**Symptom.** Validation or packaging fails.

**Cause.** The tool `type` is in the schema enum but has no mapping in `ConvertTo-FoundryAgentPayload`, or it
is simply misspelled.

**Fix.** Check the spelling first. If the type is genuinely new, add a mapping branch following
[CONTRIBUTING.md](../CONTRIBUTING.md). Do not add a default branch that skips unknown types: a silently
dropped tool is a production incident waiting to happen.

---

## TS-09 Smoke test fails with `Environment metadata matches target :: expected 'prod', found 'uat'`

**Symptom.** The deployment succeeded but the agent reports the wrong environment.

**Cause.** The wrong overlay was applied, which almost always means `config/environments/<env>.json` for two
environments points at the same `projectEndpoint`.

**Fix.** Check that every environment configuration has a distinct account, project and endpoint. Then
redeploy with the correct target.

This check exists because a shared endpoint between TEST and PROD is easy to create by copy-paste and
catastrophic in effect.

---

## TS-10 Smoke test fails with `Tool count matches resolved package :: expected 5, found 3`

**Symptom.** Fewer or more tools than expected.

**Causes.**

- Expected: the overlay disables tools in that environment. Pass the environment-correct
  `-ExpectedToolCount`, or omit the parameter.
- Unexpected: a tool ref was removed from the manifest, or an override disabled it by mistake.

```powershell
Import-Module ./scripts/modules/FoundryAgentOps/FoundryAgentOps.psd1 -Force
foreach ($e in 'dev','test','uat','prod') {
  $d = Resolve-AgentDefinition -Path ./agents/<agent> -Environment $e -SkipPlaceholderExpansion
  "{0,-5} enabled={1} disabled=[{2}]" -f $e, @($d['tools']).Count, ($d['disabledTools'] -join ',')
}
```

---

## TS-11 Evaluation suite fails on latency but the answers look right

**Symptom.** `p95 latency X ms exceeds the maximum Y ms`.

**Causes.**

- Cold start on the first run after deployment. Warm the agent with one throwaway prompt before the suite.
- A slow tool, typically a search index or an OpenAPI backend, not the model.
- Throttling. `Invoke-FoundryApi` retries on HTTP 429 with exponential backoff, and the retry time counts
  towards the measured latency. Look for `Agent Service returned HTTP 429` warnings in the log.
- The threshold is simply unrealistic for the model and tool set in that environment.

Set `maximumP95LatencyMs` from measured behaviour, not aspiration. An evaluation gate that fails for
infrastructure reasons gets disabled, and then you have no gate.

---

## TS-12 `Evaluator '<name>' is of type 'ai-quality', which requires an external Azure AI evaluation runner`

**Symptom.** The evaluation suite throws instead of scoring.

**Cause.** `ai-quality` is a declared extension point with no built-in implementation.

**Fix.** Either remove the evaluator and rely on the deterministic ones, or implement the call to your
evaluation backend in `tests/evaluations/Invoke-EvaluationSuite.ps1`. It throws rather than returning a
neutral pass, because an unmeasured pass is worse than no measurement at all.

---

## TS-13 Regression test reports drift but no assertion failed

**Symptom.** `response drifted from baseline (similarity 0.42, floor 0.6)`, exit code 0.

**Cause.** The wording changed substantially while still satisfying every assertion. This is a warning, not a
failure, unless you pass `-TreatDriftAsFailure`.

**What to do.** Read the new response. If the change is intended, accept it explicitly:

```powershell
./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName <agent> -UpdateBaseline -WhatIf
./tests/regression/Invoke-RegressionTest.ps1 -Environment test -AgentName <agent> -UpdateBaseline
git diff ./tests/regression/cases/
```

Commit the baseline change with the change that caused it, so the diff explains itself. Never refresh
baselines as a routine step: an unexplained drift is the signal you are paying for.

---

## TS-14 Validation reports `Pester unit tests skipped` or `PSScriptAnalyzer skipped`

**Not an error.** Those modules are optional and validation never installs tooling. Install them in your user
scope to enable the checks:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Both CI implementations install Pester on the build agent, so the tests do run in the pipeline.

---

## TS-15 Validation reports `Terraform validate skipped`

**Not an error.** `terraform validate` requires `terraform init`, which downloads providers over the network.
It is opt-in locally:

```powershell
./scripts/Invoke-Validation.ps1 -IncludeTerraformValidate
```

`terraform fmt -check -recursive` is offline and always runs. CI runs the full validate.

---

## TS-16 Validation reports `YAML validation (method: structural-lint)`

**Meaning.** Neither `powershell-yaml` nor PyYAML was available, so a reduced structural check ran: tabs,
indentation, duplicate sibling keys and unbalanced quotes. It will not catch every YAML error.

**Fix.** Install one of them to get a full parse:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
# or
python -m pip install --user pyyaml
```

The method used is always printed, so a weaker check is never silently reported as a strong one.

---

## TS-17 `az bicep build` fails after editing a module

Common causes:

| Error | Cause |
| --- | --- |
| `BCP095 The file is involved in a cycle` | A module imports a type from `main.bicep`. Shared types belong in `types.bicep`. |
| `BCP062 The referenced declaration ... is not valid` | A downstream error from the cycle above, or a renamed resource symbol. |
| `deployment is not valid` | A loop variable named `deployment` collides with the `deployment()` function. Rename it. |
| `BCP037 ... is not allowed` | The property does not exist in that API version. Check the resource type reference rather than guessing. |

```powershell
az bicep build --file infra/bicep/main.bicep --stdout
az bicep build-params --file infra/bicep/parameters/prod.bicepparam --stdout
```

---

## TS-18 GitHub Actions: `AADSTS70021: No matching federated identity record found`

**Cause.** The federated credential subject does not match the token the workflow requested.

**Fix.** The subject must match exactly:

| Workflow context | Required subject |
| --- | --- |
| Job with `environment: prod` | `repo:<owner>/<repo>:environment:prod` |
| Job on a branch, no environment | `repo:<owner>/<repo>:ref:refs/heads/main` |
| Job on a tag | `repo:<owner>/<repo>:ref:refs/tags/v1.2.3` |

```powershell
az ad app federated-credential list --id <appId> --query '[].{name:name, subject:subject}' --output table
```

The reusable deploy workflow always sets `environment`, so use the environment form. Also confirm the job has
`permissions: id-token: write`.

---

## TS-19 Azure DevOps: the deployment stage is skipped

**Causes.**

- The environment approval was rejected or timed out.
- A branch control check on the environment excludes the branch the run started from.
- `dependsOn` refers to a stage that failed or was skipped.
- A template `${{ if }}` condition evaluated false, for example `promoteToUat` left at its default.

Check the environment's check history, not just the pipeline log: a rejected approval appears there.

---

## TS-20 Agent deploys but returns no grounded results

**Symptom.** Deployment and smoke tests pass, but the agent says it could not find anything.

**Check, in order.**

1. **Identity.** The **project** managed identity needs `Search Index Data Reader` on the search service. This
   is the most common cause.
2. **Index name.** Confirm the resolved value:

   ```powershell
   $env:AZURE_SUBSCRIPTION_ID = '<sub>'
   $d = Resolve-AgentDefinition -Path ./agents/<agent> -Environment prod
   ($d['tools'] | Where-Object { $_['type'] -eq 'azure_ai_search' })['config']
   ```

3. **Connection.** The Foundry project connection named in the overlay must exist in that project and point at
   the right service.
4. **Content.** The index exists but is empty, or the vector profile does not match the `queryType` in the
   tool configuration.
5. **The agent is behaving correctly.** A no-hit refusal is the designed behaviour when the index genuinely
   has no relevant content. Check the index directly before assuming a defect.

---

## Diagnostic commands

```powershell
# Full offline validation with detail
./scripts/Invoke-Validation.ps1 -Verbose

# What exactly would be sent to an environment, no credentials used
./scripts/import-agent.ps1 -PackagePath ./artifacts/<pkg> -Environment prod -WhatIf

# Package contents and integrity
./scripts/Test-AgentPackage.ps1 -PackagePath ./artifacts/<pkg>

# Deployment history
Get-ChildItem ./out/releases/*.json | ForEach-Object {
  $r = Get-Content $_ -Raw | ConvertFrom-Json
  [pscustomobject]@{
    Release = $r.releaseId; Env = $r.environment; Version = $r.agent.version
    Outcome = $r.deployment.outcome; When = $r.deployment.deployedAtUtc
  }
} | Sort-Object When -Descending | Format-Table

# Confirm which Azure identity is in use (no secret is printed)
az account show --query '{subscription:name, tenant:tenantId, identity:user.name}'
```

## Getting help

1. Read the error message. They are written to say what failed, what was expected and what to do next.
2. Reproduce offline with `-WhatIf` and `-SkipPlaceholderExpansion`.
3. Check the release record for the environment: it states exactly what is deployed.
4. Open an issue with the command, the full error text, the environment, and the package id. Never paste
   tokens, connection strings or real endpoints.
