# Sample: RAG agent

A retrieval augmented agent that grounds every answer in an Azure AI Search index plus documents uploaded to
the project vector store.

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

   Change the connection name `kb-search` in the overlays if yours differs.
3. A project vector store if you use `uploaded-documents`. Set `VECTOR_STORE_ID` as a pipeline variable or in
   the overlay `variables` map. It is intentionally left unbound in the sample so that a missing value fails
   loudly rather than deploying an empty store.
4. The deployment identity needs `Azure AI User` on the project and the search service needs a role
   assignment for the project managed identity (`Search Index Data Reader`).

## Index lifecycle

Indexes are data, not application code, so they are out of scope for the agent package. Recommended split:

| Concern | Owner | Pipeline |
| --- | --- | --- |
| Search service, SKU, network, RBAC | platform team | `infra/` |
| Index schema and vector profile | knowledge team | separate index pipeline |
| Index content refresh | knowledge team | scheduled indexer |
| Agent definition and tool binding | agent team | this repository |

Version index names (`kb-prod-v3`) and change the overlay to point at a new version. That makes an index
change a reviewable, promotable, revertible change to the agent package.

## Try it locally

```powershell
./scripts/Invoke-Validation.ps1
./scripts/New-AgentPackage.ps1 -AgentPath ./samples/rag-agent -OutputDirectory ./out
./scripts/import-agent.ps1 -PackagePath ./out/kb-research-agent-1.4.0+<sha>.zip -Environment test -WhatIf
```

## Grounding gate

`evaluations/grounding.evaluation.json` is referenced by the manifest and required from TEST onward. The
overlays raise the bar as the package advances:

| Environment | Evaluation gate | Minimum score |
| --- | --- | --- |
| DEV | not required | - |
| TEST | required | 0.85 |
| UAT | required | 0.90 |
| PROD | required | 0.90 |

A retrieval change that lowers grounding quality is blocked at TEST, before a human ever reviews it.
