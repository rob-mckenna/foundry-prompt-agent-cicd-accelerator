# Sample: RAG agent

A retrieval augmented configuration intended to ground answers in an Azure AI Search index plus documents
uploaded to the project vector store. Grounding is a behaviour to evaluate, not an assurance from packaging.

| Property | Value |
| --- | --- |
| Logical name | `kb-research-agent` |
| Tools | `azure_ai_search` (`knowledge-search`), `file_search` (`uploaded-documents`) |
| Data sensitivity | internal |
| Azure dependencies | model deployment, Azure AI Search index, project connection, vector store |

## What it demonstrates

- Two knowledge sources with distinct routing rules in the instructions.
- Per-environment index binding through `toolOverrides`, so DEV queries `kb-dev-v1` and PROD queries
  `kb-prod-v3` from a single package.
- Connection ids built from `${env:AZURE_SUBSCRIPTION_ID}`, which is supplied by the pipeline. Nested
  placeholders are expanded iteratively, so a variable may itself contain a placeholder.
- Grounding evaluations that assert refusal on a no-hit, citation presence, conflict disclosure and
  resistance to instructions embedded in retrieved documents.

## Azure prerequisites (user supplied)

Per environment:

1. Azure AI Search service with an index whose name matches the overlay (`kb-dev-v1`, `kb-test-v1`,
   `kb-uat-v1`, `kb-prod-v3`). `infra/` provisions the service, not the index or its content.
2. A Foundry project connection to that search service. The overlay builds the connection id as:

   ```
   /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>/connections/kb-search
   ```

   Change the connection name `kb-search` in the overlays if yours differs. Connections can use Entra
   authentication and can be managed through IaC, but these templates do not create them.
3. A project vector store if you use `uploaded-documents`. Set `VECTOR_STORE_ID` as a pipeline variable or in
   the overlay `variables` map. It is intentionally left unbound in the sample so that a missing value fails
   loudly rather than deploying an empty store.
4. The deployment identity needs `Foundry User` (formerly Azure AI User; role ID
   `53ca6127-db72-4b80-b1b0-d745d6d5456d`) on the project and the search service needs a role
   assignment for the project managed identity (`Search Index Data Reader`).
5. Model deployments named by the overlays, with model versions, regional support and retirement dates
   qualified for your use. Sample names are not current lifecycle guarantees.

## Index lifecycle

Indexes are data, not application code, so they are out of scope for the agent package. Recommended split:

| Concern | Owner | Pipeline |
| --- | --- | --- |
| Search service, SKU, network, RBAC | platform team | `infra/` |
| Index schema and vector profile | knowledge team | separate index pipeline |
| Index content refresh | knowledge team | scheduled indexer |
| Agent definition and tool binding | agent team | this repository |

Version index names (`kb-prod-v3`) and change the overlay to point at a new version. That makes an index
binding change reviewable and promotable. Reverting the binding does not restore mutable index content or
freeze model behaviour; retain and govern knowledge snapshots separately.

## Try it locally

```powershell
$ErrorActionPreference = 'Stop'
$package = .\scripts\New-AgentPackage.ps1 -AgentPath .\samples\rag-agent -OutputDirectory .\out\rag-quickstart
.\scripts\Test-AgentPackage.ps1 -PackagePath $package.PackagePath -Environment dev
# Placeholder IDs for structural resolution only; no Azure call is made.
$env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
$env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev `
  -RuntimeVariable @{ VECTOR_STORE_ID = 'vs-placeholder' } -WhatIf
```

Run from the repository root. Plain `-WhatIf` is not a service/tool check; it needs no Python or credentials.
Replace the dummy identifiers with your own before real operations.
Real deployment and live tests use the [pinned SDK bridge](../../scripts/README.md), with explicit preview
opt-in for agent-bound runtime. **No authenticated Azure qualification has been performed for this tranche.**

## Grounding gate

`evaluations/grounding.evaluation.json` is referenced by the manifest; required evidence comes from the
packaged overlay. The overlays raise the bar as the package advances:

| Environment | Evaluation gate | Minimum score |
| --- | --- | --- |
| DEV | not required | - |
| TEST | required | 0.85 |
| UAT | required | 0.90 |
| PROD | required | 0.90 |

Import/promotion returns `pending-verification`. Run required live gates with the exact returned
`-ReleaseRecordPath`, then call `Complete-Release.ps1`; failing evidence prevents successful attestation
and onward promotion, not initial candidate exposure. Offline fixtures cannot satisfy those gates. See
[the release sequence](../../scripts/README.md). Approval timing is configured externally in your CI system.
