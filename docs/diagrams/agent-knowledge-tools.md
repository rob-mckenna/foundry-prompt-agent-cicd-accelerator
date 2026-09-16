# Diagram: agent, knowledge and tools

How a prompt agent, its knowledge sources and its action tools fit together, and where each piece is defined
in this repository.

## Composition

```mermaid
flowchart TB
    subgraph DEF["Definition in Git"]
        MAN["agent.manifest.json<br/>name, version, owner, classification,<br/>model, tool refs"]
        INS["instructions.md<br/>role, scope, grounding rules, output format"]
        TDEF["tools/*.json<br/>one file per tool"]
        OVL["environments/*.overlay.json<br/>bindings and enablement"]
    end

    subgraph RUNTIME["Deployed agent in a Foundry project"]
        AGENT["Assistant resource<br/>model + instructions + tools + tool_resources + metadata"]
        THREAD["Thread"]
        RUN["Run"]
    end

    MAN --> AGENT
    INS --> AGENT
    TDEF --> AGENT
    OVL --> AGENT
    AGENT --> THREAD --> RUN
```

## Knowledge and tools at run time

```mermaid
flowchart TB
    USER["Calling application"] -->|user message| THREAD["Thread"]
    THREAD --> RUN["Run"]
    RUN --> MODEL["Model deployment<br/>gpt-4o / gpt-4o-mini"]
    MODEL -->|decides to call a tool| DISPATCH{"Tool"}

    subgraph KNOWLEDGE["Knowledge - read only, grounding"]
        AIS["azure_ai_search<br/>tool_resources.azure_ai_search.indexes[]<br/>index_connection_id + index_name"]
        FS["file_search<br/>tool_resources.file_search.vector_store_ids[]"]
    end

    subgraph ACTION["Action - internal systems"]
        OAPI["openapi<br/>spec inlined, auth via project connection"]
        AFUNC["azure_function<br/>storage queue in and out"]
        CFUNC["function<br/>executed by the calling application"]
        CI["code_interpreter<br/>sandboxed Python"]
    end

    subgraph EXTERNAL["External - restricted by policy"]
        BING["bing_grounding<br/>dataEgress: external"]
        MCP["mcp<br/>dataEgress: external"]
    end

    DISPATCH --> AIS
    DISPATCH --> FS
    DISPATCH --> OAPI
    DISPATCH --> AFUNC
    DISPATCH --> CFUNC
    DISPATCH --> CI
    DISPATCH -.->|DEV and TEST only| BING
    DISPATCH -.->|DEV and TEST only| MCP

    AIS --> RESULT["Tool output returned to the model"]
    FS --> RESULT
    OAPI --> RESULT
    AFUNC --> RESULT
    CFUNC --> RESULT
    CI --> RESULT
    BING -.-> RESULT
    MCP -.-> RESULT
    RESULT --> MODEL
    MODEL -->|final message| USER
```

## Identity and data access

The Foundry **project** has a system-assigned managed identity. That identity, not the deployment identity,
is what reads your knowledge sources at run time.

```mermaid
flowchart LR
    PROJ["Foundry project<br/>system assigned managed identity"]
    PROJ -->|Search Index Data Reader| SRCH["Azure AI Search"]
    PROJ -->|Storage Queue Data Contributor| QUEUE["Storage queues for azure_function"]
    PROJ -->|Key Vault Secrets User| KV["Key Vault"]

    CICD["CI/CD workload identity"]
    CICD -->|Azure AI User| PROJ
    CICD -->|Key Vault Secrets User| KV
    CICD -->|Storage Blob Data Contributor| BLOB["Release record container"]
```

Confusing these two identities is the most common cause of a deployment that succeeds and an agent that
cannot retrieve anything. The deployment identity creates the agent; the project identity serves it.

## Environment binding of a knowledge tool

```mermaid
flowchart LR
    T["tools/knowledge-search.json<br/>connectionId: ${env:SEARCH_CONNECTION_ID}<br/>indexName: ${env:SEARCH_INDEX_NAME}"]

    OD["dev.overlay.json<br/>SEARCH_INDEX_NAME = kb-dev-v1"]
    OT["test.overlay.json<br/>SEARCH_INDEX_NAME = kb-test-v1"]
    OU["uat.overlay.json<br/>SEARCH_INDEX_NAME = kb-uat-v1"]
    OP["prod.overlay.json<br/>SEARCH_INDEX_NAME = kb-prod-v3"]

    T --> OD --> AD["DEV agent<br/>index kb-dev-v1"]
    T --> OT --> AT["TEST agent<br/>index kb-test-v1"]
    T --> OU --> AU["UAT agent<br/>index kb-uat-v1"]
    T --> OP --> AP["PROD agent<br/>index kb-prod-v3"]
```

Placeholders resolve iteratively, so an overlay variable may itself contain a placeholder. This is how the
samples build a full connection id from `${env:AZURE_SUBSCRIPTION_ID}`, which the pipeline supplies:

```json
"SEARCH_CONNECTION_ID": "/subscriptions/${env:AZURE_SUBSCRIPTION_ID}/resourceGroups/rg-foundry-agents-prod/providers/Microsoft.CognitiveServices/accounts/aifagentsprod/projects/proj-agents-prod/connections/kb-search"
```

An unresolved placeholder aborts the deployment with the list of missing names. It never becomes an empty
string.

## Tool type reference

| `type` | Payload shape produced | Environment-specific values | Default policy |
| --- | --- | --- | --- |
| `azure_ai_search` | `tools[].type` plus `tool_resources.azure_ai_search.indexes[]` | connection id, index name | allowed everywhere |
| `file_search` | `tools[].type` plus `tool_resources.file_search.vector_store_ids[]` | vector store ids | allowed everywhere |
| `openapi` | `tools[].openapi` with the spec inlined | connection id or audience | allowed everywhere |
| `azure_function` | `tools[].azure_function` with queue bindings | queue service endpoint | allowed everywhere |
| `function` | `tools[].function` | none; the caller executes it | allowed everywhere |
| `code_interpreter` | `tools[].type` | none | DEV and TEST only |
| `bing_grounding` | `tools[].bing_grounding.search_configurations[]` | connection id | DEV and TEST only, external egress |
| `mcp` | `tools[].server_label` and `server_url` | server URL | DEV and TEST only, external egress |

The mapping is implemented once, in `ConvertTo-FoundryAgentPayload`
(`scripts/modules/FoundryAgentOps/FoundryAgentOps.psm1`). An unknown type raises an error rather than being
skipped, so a typo cannot quietly remove a capability from a production agent.

## Disabling a tool for an environment

```json
"toolOverrides": {
  "code-interpreter": { "enabled": false },
  "web-grounding":    { "enabled": false }
}
```

A disabled tool is removed from the resolved definition before placeholder expansion. It therefore does not
appear in the payload, does not require its `${env:...}` bindings in that environment, and is not evaluated by
the governance gate. `samples/multi-tool-agent` resolves to five tools in DEV and TEST and three in UAT and
PROD from one package.

Tell the agent about it in the instructions. `samples/multi-tool-agent/instructions.md` states which
capabilities are absent in UAT and PROD and how to respond, so behaviour degrades in a defined way instead of
producing a confusing failure.
