# Sample: multi-tool agent

An operations assistant that combines knowledge retrieval, a line-of-business OpenAPI service, an
asynchronous Azure Function and two capabilities that are deliberately available only in lower environments.

| Property | Value |
| --- | --- |
| Logical name | `operations-copilot` |
| Tools | `azure_ai_search`, `openapi`, `azure_function`, `code_interpreter`, `bing_grounding` |
| Data sensitivity | confidential, processes personal data |
| Azure dependencies | model deployment, AI Search, API connection, Function app with storage queues, Bing connection (DEV and TEST only) |

## What it demonstrates

This is the sample to read if you only read one.

1. **Environment-scoped capability.** `code-interpreter` and `web-grounding` are enabled in DEV and TEST and
   switched off in UAT and PROD through `toolOverrides`:

   ```json
   "toolOverrides": {
     "code-interpreter": { "enabled": false },
     "web-grounding":    { "enabled": false }
   }
   ```

   Disabled tools are removed from the resolved definition, so their `${env:...}` placeholders are not
   required in that environment and they never reach the Agent Service payload. The resolved tool count drops
   from five to three between TEST and UAT.

2. **Defence in depth on tool policy.** The same restriction is expressed three times on purpose:
   - the tool definition declares `governance.allowedEnvironments: ["dev","test"]`;
   - the overlay disables it in UAT and PROD;
   - `config/environments/prod.json` omits `code_interpreter` and `bing_grounding` from
     `governance.allowedToolTypes`.

   Removing any one of the three still leaves the deployment blocked. This is the pattern to copy for any
   capability with an external data egress path.

3. **Key Vault references.** UAT and PROD overlays declare:

   ```json
   "secretRefs": { "ORDERS_API_KEY": "@Microsoft.KeyVault(VaultName=kv-fnd-agents-prod;SecretName=orders-api-key)" }
   ```

   No value is stored in the repository or in the package. Run
   `import-agent.ps1 -ValidateSecretReferences` to confirm the deployment identity can read each reference
   before the write; values stay in a `SecureString` and are never printed.

4. **An inlined OpenAPI specification.** `tools/orders-api.openapi.json` is packaged with the agent and
   embedded in the payload at deploy time. Authentication comes from a Foundry project connection, so the
   specification file itself holds no credential.

5. **Instructions that match the deployment reality.** The agent is told that two capabilities are absent in
   UAT and PROD and how to respond when a user asks for them. Behaviour degrades in a defined way rather than
   producing a confusing tool error.

## Azure prerequisites (user supplied)

Per environment:

1. Model deployment named as in the overlay.
2. Azure AI Search index (`ops-dev-v1`, `ops-test-v1`, `ops-uat-v1`, `ops-prod-v2`) and a project connection
   named `ops-search`.
3. A project connection named `orders-api` for the OpenAPI tool.
4. A Function app that reads `entitlement-input` and writes `entitlement-output` on the storage account in
   `FUNCTION_QUEUE_ENDPOINT`, with both queues created in advance. The Foundry project managed identity needs
   `Storage Queue Data Contributor` on that account.
5. DEV and TEST only: a Grounding with Bing connection named `bing-grounding`.
6. UAT and PROD only: the `orders-api-key` secret in the environment Key Vault, and
   `Key Vault Secrets User` for the deployment identity.

If a dependency is missing, deployment fails at the Agent Service call with the returned HTTP status. The
accelerator does not create these dependencies implicitly.

## Try it locally

```powershell
./scripts/Invoke-Validation.ps1
./scripts/New-AgentPackage.ps1 -AgentPath ./samples/multi-tool-agent -OutputDirectory ./out

# Compare what DEV and PROD receive from the identical package
$env:AZURE_SUBSCRIPTION_ID = '<your subscription guid>'
./scripts/import-agent.ps1 -PackagePath ./out/operations-copilot-2.1.0+<sha>.zip -Environment dev  -WhatIf
./scripts/import-agent.ps1 -PackagePath ./out/operations-copilot-2.1.0+<sha>.zip -Environment prod -WhatIf
```

## Adding a tool

1. Copy a template from `templates/tools/` into `tools/`.
2. Give it a unique lowercase `id`.
3. Add `{ "ref": "tools/<file>.json" }` to `agent.manifest.json`.
4. Bind environment-specific values with `${env:NAME}` and set them in every overlay.
5. Add the type to `governance.allowedToolTypes` for each environment that should permit it.
6. Bump `version` in the manifest.
7. Run `./scripts/Invoke-Validation.ps1`.

If the type has no mapping in `ConvertTo-FoundryAgentPayload`, validation fails with
`Tool '<id>' has unsupported type '<type>'`. Extend that single function rather than working around it, so
that no tool can silently vanish from a deployment.
