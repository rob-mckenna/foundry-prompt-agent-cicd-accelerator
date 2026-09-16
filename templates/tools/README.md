# Tool definition templates

Each file is a standalone, environment-neutral tool definition validated by
`schemas/tool-definition.schema.json`. Copy the ones you need into your agent's `tools/` folder and reference
them from `agent.manifest.json`:

```json
"tools": [
  { "ref": "tools/knowledge-search.json" },
  { "ref": "tools/orders-api.json", "enabled": true }
]
```

## Available templates

| File | `type` | Agent Service payload it produces | Notes |
| --- | --- | --- | --- |
| `azure-ai-search-knowledge.json` | `azure_ai_search` | `tools[].type` plus `tool_resources.azure_ai_search.indexes[]` | Connection id and index name are environment specific. |
| `file-search-knowledge.json` | `file_search` | `tools[].type` plus `tool_resources.file_search.vector_store_ids` | Vector stores are created per project. |
| `code-interpreter-tool.json` | `code_interpreter` | `tools[].type` | Restricted to DEV and TEST by default. |
| `openapi-tool.json` + `orders-api.openapi.json` | `openapi` | `tools[].openapi` with the inlined spec | The spec is packaged with the agent; auth comes from a project connection. |
| `azure-function-tool.json` | `azure_function` | `tools[].azure_function` with queue bindings | Requires the storage queues to exist before deployment. |
| `function-tool.json` | `function` | `tools[].function` | The calling application executes the function and submits the output. |
| `mcp-tool.json` | `mcp` | `tools[].server_label` / `server_url` | External data egress. Approval required by default. |
| `bing-grounding-tool.json` | `bing_grounding` | `tools[].bing_grounding.search_configurations[]` | External data egress. Restricted to DEV and TEST by default. |

The mapping from these definitions to the data plane payload lives in one place:
`ConvertTo-FoundryAgentPayload` in `scripts/modules/FoundryAgentOps/FoundryAgentOps.psm1`. An unrecognised
`type` raises an error, so a mistyped tool cannot silently disappear from a deployment.

## Environment binding

Never hard-code a connection id, index name, queue endpoint or server URL. Use a `${env:NAME}` placeholder and
bind it in the environment overlay:

```json
{
  "environment": "prod",
  "variables": {
    "SEARCH_CONNECTION_ID": "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>/connections/kb-search",
    "SEARCH_INDEX_NAME": "kb-prod-v3"
  }
}
```

Alternatively set the same names as pipeline variables. Overlay values win over process environment variables.
Deployment fails with the list of unresolved names if a placeholder has no value, so a missing binding can
never reach an environment as an empty string.

## Secrets

Tool definitions must contain no secret values. Function keys, API keys and connection strings belong in a
Foundry project connection or in Key Vault. When the agent itself needs a secret, declare it in the overlay:

```json
"secretRefs": {
  "PARTNER_API_KEY": "@Microsoft.KeyVault(VaultName=kv-fnd-agents-prod;SecretName=partner-api-key)"
}
```

`import-agent.ps1 -ValidateSecretReferences` confirms the deployment identity can read each reference. Values
are held as `SecureString` and are never printed or written to the package.

## Governance block

The optional `governance` block is evaluated against the target environment policy before deployment:

- `dataEgress` records whether the tool can send prompt content outside the tenant.
- `allowedEnvironments` blocks the tool from environments it is not approved for.
- `requiresSecurityReview` and `networkIsolationRequired` are informational for review and inventory.

`config/environments/<env>.json` `governance.allowedToolTypes` is the hard gate: a tool type that is absent
from the list fails the deployment.
