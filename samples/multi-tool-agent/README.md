# Sample: multi-tool agent

An operations assistant that combines knowledge retrieval, a line-of-business OpenAPI service, an
asynchronous Azure Function and two capabilities that are deliberately available only in lower environments.

| Property | Value |
| --- | --- |
| Logical name | `operations-copilot` |
| Tools | `azure_ai_search`, `openapi`, `azure_function`, `code_interpreter`, `bing_grounding` |
| Data sensitivity | confidential, processes personal data |
| Azure dependencies | model deployment, AI Search/index, API connection, Standard Setup and deployed queue Function, Bing connection (DEV and TEST only) |

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

   These controls cover different stages: the overlay removes a disabled tool; governance rejects a resolved
   enabled tool that violates the target policy. They do not prove downstream network/egress enforcement.

3. **Key Vault references.** UAT and PROD overlays declare:

   ```json
   "secretRefs": { "ORDERS_API_KEY": "@Microsoft.KeyVault(VaultName=kv-fnd-agents-prod;SecretName=orders-api-key)" }
   ```

   No value is stored in the repository or in the package. Run
   `import-agent.ps1 -ValidateSecretReferences` to confirm the deployment identity can read each reference
   before the write; values stay in a `SecureString` and are never printed. This is an authenticated Key Vault
   check, not an offline option, and it does not inject credentials into the runtime connection.

4. **An inlined OpenAPI specification.** `tools/orders-api.openapi.json` is packaged with the agent and
   embedded in the payload at deploy time. Authentication comes from a Foundry project connection, so the
   specification file itself holds no credential.

5. **Instructions that describe the configured capabilities.** The agent is told that two capabilities are
   absent in UAT and PROD and how it should respond. Test that behaviour live; instructions do not guarantee it.

## Azure prerequisites (user supplied)

Per environment:

1. Model deployment named as in the overlay. The model names are examples; qualify versions, regional
   availability and retirement dates before use.
2. Azure AI Search index (`ops-dev-v1`, `ops-test-v1`, `ops-uat-v1`, `ops-prod-v2`) and a project connection
   named `ops-search`.
3. A project connection named `orders-api` for the OpenAPI tool.
4. Foundry **Standard Setup**, plus a deployed Function implementation and its runtime dependencies that read
   `entitlement-input` and write `entitlement-output` on the account in `FUNCTION_QUEUE_ENDPOINT`.
   Create both queues and configure Function/project identities and permissions, including
   `Storage Queue Data Contributor` for the Foundry project managed identity. Queues alone are not sufficient;
   the supplied IaC does not deploy Standard Setup or the Function code/dependencies.
5. DEV and TEST only: a Grounding with Bing connection named `bing-grounding`.
6. UAT and PROD only: the `orders-api-key` secret in the environment Key Vault, and
   `Key Vault Secrets User` for the deployment identity.

Connections may use Entra authentication and can be IaC-created, but the supplied templates do not create
them. Missing dependencies may surface at deployment **or runtime**; a successful create call is not a tool
integration test. The accelerator does not create these dependencies implicitly.

## Try it locally

```powershell
$ErrorActionPreference = 'Stop'
$package = .\scripts\New-AgentPackage.ps1 -AgentPath .\samples\multi-tool-agent -OutputDirectory .\out\tools-quickstart
.\scripts\Test-AgentPackage.ps1 -PackagePath $package.PackagePath -Environment dev

# Compare DEV and TEST structural summaries from the identical package, with no Azure calls.
$env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
$env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev -WhatIf
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment test -WhatIf
```

Run from the repository root. PROD also needs valid change/sign-off references, even for `-WhatIf`.
Replace the dummy GUIDs above before real operations.
For offline comparison of DEV/PROD tool shapes without deployment, use [samples/README.md](../README.md).
Identical package bytes do not mean identical model/tool bindings or immutable external behaviour.

Real deployment and live tests need the [pinned Python SDK bridge](../../scripts/README.md); the agent-bound
runtime explicitly opts into preview. Import/promotion returns `pending-verification`: pass the exact returned
`-ReleaseRecordPath` to live runners and attest their evidence with `Complete-Release.ps1` before promotion.
**No authenticated Azure qualification has been performed for this tranche.**

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
