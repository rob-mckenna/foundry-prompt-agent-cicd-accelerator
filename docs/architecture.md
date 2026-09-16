# Architecture

## Problem

An Azure AI Foundry prompt agent is configuration: a model deployment, an instruction text, a set of tools and
a set of connections. That configuration is easy to change in the portal and hard to govern. Without a
pipeline you get agents whose behaviour nobody can reconstruct, changes nobody reviewed, and no way to answer
"what exactly is running in production and who approved it".

This accelerator treats the agent definition as source, builds it into an immutable artifact once, and
promotes that same artifact through DEV, TEST, UAT and PROD under approval control.

## Core design decisions

| Decision | Rationale |
| --- | --- |
| Manifest is deployment neutral | One definition, four environments. Environment differences live only in overlays. |
| Build once, promote the same bytes | Production runs exactly what UAT verified. A rebuild would reintroduce risk at the last gate. |
| Content-addressed package | `packageId` is the SHA-256 of the checksum manifest, so the artifact is self-verifying and tamper evident. |
| Overlays ship inside the package | Promotion needs no repository access and no rebuild. The TEST overlay is already in the artifact built for DEV. |
| Release records live outside the package | Writing a deployment record into the package would change its hash and break immutability. |
| Governance evaluated at deploy time | The same package can be legal in TEST and illegal in PROD. The gate belongs at the environment boundary. |
| Approvals live in the platform | GitHub Environments and Azure DevOps Environments are auditable and cannot be weakened by a pull request to this repository. |
| Rollback is a redeploy of a prior package | Known-good bytes, not a rebuild of older source. |
| Tool mapping is centralised and strict | `ConvertTo-FoundryAgentPayload` raises an error on an unknown tool type, so a mistyped tool cannot silently vanish from a deployment. |

## Component model

```mermaid
flowchart TB
    subgraph SRC["Source of truth (Git)"]
        M["agent.manifest.json<br/>deployment neutral"]
        I["instructions.md"]
        T["tools/*.json"]
        O["environments/*.overlay.json"]
        E["evaluations/*"]
        C["config/environments/*.json<br/>targets and policy"]
        S["schemas/*.schema.json<br/>contracts"]
    end

    subgraph BUILD["Build once"]
        V["Invoke-Validation.ps1<br/>offline: schema, YAML, parser, governance"]
        P["New-AgentPackage.ps1"]
        PKG["foundry-agent-package/1<br/>package.json + checksums.sha256"]
    end

    subgraph DEPLOY["Deploy or promote (per environment)"]
        VP["Test-AgentPackage.ps1<br/>integrity + content address"]
        R["Resolve-AgentDefinition<br/>manifest + overlay + tools"]
        G["Test-AgentGovernance<br/>hard gate"]
        X["ConvertTo-FoundryAgentPayload"]
        API["Agent Service data plane"]
        REC["Release record"]
    end

    M --> P
    I --> P
    T --> P
    O --> P
    E --> P
    S --> V
    V --> P
    P --> PKG
    PKG --> VP --> R --> G --> X --> API
    C --> R
    C --> G
    API --> REC
```

## Deployment topology

One Foundry account and project per environment, in its own resource group, with its own Key Vault, release
store and optional Azure AI Search service. Separation is by subscription or resource group, not by project
inside a shared account, so that blast radius and RBAC follow the environment boundary.

```mermaid
flowchart LR
    subgraph DEV["DEV subscription or resource group"]
        DA["Foundry account<br/>project proj-agents-dev"]
        DK["Key Vault"]
        DS["Storage: releases"]
        DSE["AI Search"]
    end
    subgraph TEST["TEST"]
        TA["Foundry account<br/>project proj-agents-test"]
        TK["Key Vault"]
        TS["Storage: releases"]
        TSE["AI Search"]
    end
    subgraph UAT["UAT"]
        UA["Foundry account<br/>project proj-agents-uat"]
        UK["Key Vault"]
        US["Storage: releases"]
        USE["AI Search"]
    end
    subgraph PROD["PROD"]
        PA["Foundry account<br/>project proj-agents-prod"]
        PK["Key Vault"]
        PS["Storage: releases"]
        PSE["AI Search"]
    end

    CICD["CI/CD workload identity<br/>one federated credential per environment"]
    CICD -->|Azure AI User| DA
    CICD -->|Azure AI User| TA
    CICD -->|Azure AI User| UA
    CICD -->|Azure AI User| PA
```

## GitHub to Foundry

Full diagram and narrative: [diagrams/github-to-foundry.md](diagrams/github-to-foundry.md).

```mermaid
flowchart LR
    PR["Pull request"] --> VAL["validate.yml<br/>offline, no credentials"]
    VAL --> MERGE["Merge to main"]
    MERGE --> DEVWF["deploy-dev.yml"]
    DEVWF --> PKGJ["_reusable-package.yml<br/>build once"]
    PKGJ --> ART[("Artifact<br/>immutable package")]
    PKGJ --> DEVD["_reusable-deploy.yml<br/>environment: dev"]
    DEVD -->|OIDC| FDEV["Foundry DEV project"]

    ART --> TESTWF["deploy-test.yml<br/>manual"]
    TESTWF -->|GitHub Environment approval| TESTD["Promote to TEST"]
    TESTD -->|OIDC| FTEST["Foundry TEST project"]
    TESTD --> UATD["Promote to UAT<br/>second approval"]
    UATD -->|OIDC| FUAT["Foundry UAT project"]

    UATD --> PRODWF["deploy-prod.yml<br/>manual + change record"]
    PRODWF -->|Preflight then approval| PRODD["Promote to PROD"]
    PRODD -->|OIDC| FPROD["Foundry PROD project"]
```

## Azure DevOps to Foundry

Full diagram and narrative: [diagrams/azure-devops-to-foundry.md](diagrams/azure-devops-to-foundry.md).

```mermaid
flowchart LR
    PR["Pull request"] --> BV["validate.yml<br/>build validation policy"]
    BV --> MERGE["Merge to main"]
    MERGE --> DEVP["deploy-dev.yml"]
    DEVP --> PKG["templates/steps/package.yml"]
    PKG --> ART[("Pipeline artifact<br/>agentPackage")]
    PKG --> DEVS["deploy-stage.yml<br/>environment foundry-agents-dev"]
    DEVS -->|Workload identity federation| FDEV["Foundry DEV project"]

    ART --> TESTP["deploy-test.yml<br/>resources.pipelines: devPipeline"]
    TESTP -->|Environment approval| FTEST["Foundry TEST project"]
    TESTP -->|Environment approval| FUAT["Foundry UAT project"]
    TESTP --> PRODP["deploy-prod.yml<br/>resources.pipelines: testPipeline"]
    PRODP -->|Preflight + approval + exclusive lock| FPROD["Foundry PROD project"]
```

## Multi-environment promotion

Full diagram and narrative: [diagrams/multi-environment-promotion.md](diagrams/multi-environment-promotion.md).

```mermaid
flowchart LR
    B["Build<br/>packageId sha256:abc..."] --> D["DEV<br/>auto"]
    D -->|same bytes| T["TEST<br/>approval"]
    T -->|same bytes| U["UAT<br/>approval + business sign-off"]
    U -->|same bytes| P["PROD<br/>approval + change record"]
    P -.->|failure| RB["Rollback<br/>previous packageId"]
    RB -.-> P
```

## Agent, knowledge and tools

Full diagram and narrative: [diagrams/agent-knowledge-tools.md](diagrams/agent-knowledge-tools.md).

```mermaid
flowchart TB
    USER["Calling application or user"] --> AGENT["Prompt agent<br/>model + instructions + metadata"]
    AGENT --> TR["Thread and run"]

    subgraph KNOW["Knowledge"]
        AIS["Azure AI Search index"]
        VS["Project vector store"]
    end
    subgraph TOOLS["Action tools"]
        OAPI["OpenAPI service"]
        FUNC["Azure Function over queues"]
        CI["Code interpreter"]
    end
    subgraph EXT["External, restricted"]
        BING["Grounding with Bing"]
        MCP["MCP server"]
    end

    TR --> AIS
    TR --> VS
    TR --> OAPI
    TR --> FUNC
    TR --> CI
    TR -.->|DEV and TEST only| BING
    TR -.->|DEV and TEST only| MCP
```

## Identity and trust

```mermaid
sequenceDiagram
    participant WF as GitHub Actions job
    participant EID as Microsoft Entra ID
    participant KV as Key Vault
    participant AS as Agent Service
    participant ST as Release store

    WF->>EID: OIDC token for repo:owner/repo:environment:prod
    EID-->>WF: Access token (Azure AI User)
    Note over WF,EID: No client secret exists anywhere
    WF->>KV: Read secret referenced by the overlay
    KV-->>WF: SecureString, never logged
    WF->>AS: GET /assistants?limit=1 (preflight)
    AS-->>WF: 200 confirms endpoint and api-version
    WF->>AS: POST /assistants (create or update)
    AS-->>WF: assistant id
    WF->>ST: Write release record
```

The preflight matters: the Agent Service api-version and response shape have changed across releases. A
read-only probe converts a version mismatch into a clear failure before any write, rather than a
half-configured agent.

## Data plane contract

`config/environments/<env>.json` pins the contract explicitly:

```json
"foundry": {
  "projectEndpoint": "https://<account>.services.ai.azure.com/api/projects/<project>",
  "apiVersion": "v1",
  "tokenScope": "https://ai.azure.com/.default"
}
```

Operations used by the accelerator, all through `Invoke-FoundryApi`:

| Operation | Method and path |
| --- | --- |
| Preflight and discovery | `GET {endpoint}/assistants?limit=...` |
| Read one agent | `GET {endpoint}/assistants/{id}` |
| Create | `POST {endpoint}/assistants` |
| Update | `POST {endpoint}/assistants/{id}` |
| Start a test conversation | `POST {endpoint}/threads/runs` |
| Poll a run | `GET {endpoint}/threads/{thread}/runs/{run}` |
| Read the reply | `GET {endpoint}/threads/{thread}/messages` |
| Clean up a test thread | `DELETE {endpoint}/threads/{thread}` |

Verify `apiVersion` against your project before the first deployment. If your organisation standardises on a
different interface, replace the body of `Invoke-FoundryApi` and `ConvertTo-FoundryAgentPayload`: every other
part of the accelerator depends on those two functions and nothing else.

## What this accelerator does not own

| Concern | Owner | Why |
| --- | --- | --- |
| Search index schema and content | knowledge pipeline | Data has a different change cadence from the agent |
| Foundry project connections | platform team, once per environment | They carry credentials that must not appear in template parameters |
| Model capacity and quota | platform team | Subscription level concern |
| Client applications calling the agent | application teams | The agent is a dependency, not the product |
| Network isolation and private DNS | landing zone | Organisation-wide standard |

## Related documents

- [deployment-patterns.md](deployment-patterns.md) - how a package becomes a deployed agent
- [package-format.md](package-format.md) - the immutable package specification
- [branching-strategy.md](branching-strategy.md) - branches, tags and protection
- [environment-management.md](environment-management.md) - environments, overlays and configuration
- [governance.md](governance.md) - policy, approvals and audit
- [deployment-runbook.md](deployment-runbook.md) - step-by-step operational procedures
- [troubleshooting.md](troubleshooting.md) - failure modes and fixes
