# Diagram: multi-environment promotion

One artifact, four environments, increasing control at each step.

## Promotion of one package

```mermaid
flowchart TB
    subgraph BUILD["Build - once, on merge to main"]
        B1["New-AgentPackage.ps1"]
        B2["Resolve every environment offline"]
        B3["checksums.sha256 over all files"]
        B4["packageId = sha256 of the content manifest"]
        B5[("operations-copilot-2.1.0+ab12cd3.zip<br/>packageId sha256:832e1b...")]
        B1 --> B2 --> B3 --> B4 --> B5
    end

    B5 --> DEV
    subgraph DEV["DEV - automatic"]
        D1["Trigger: merge to main"]
        D2["Approval: none"]
        D3["Overlay: dev<br/>gpt-4o-mini, temperature 0.3<br/>5 tools enabled"]
        D4["Gates: smoke"]
        D1 --> D2 --> D3 --> D4
    end

    DEV -->|identical bytes| TEST
    subgraph TEST["TEST - approval"]
        T1["Trigger: manual, sourceRunId"]
        T2["Approval: platform team"]
        T3["Overlay: test<br/>gpt-4o-mini, temperature 0.2<br/>5 tools enabled"]
        T4["Gates: smoke, regression, evaluation >= 0.85"]
        T1 --> T2 --> T3 --> T4
    end

    TEST -->|identical bytes| UAT
    subgraph UAT["UAT - business acceptance"]
        U1["Trigger: same run, second stage"]
        U2["Approval: platform team + business owner"]
        U3["Overlay: uat<br/>gpt-4o, temperature 0.2<br/>3 tools: code interpreter and web grounding disabled"]
        U4["Gates: smoke, regression, evaluation >= 0.90,<br/>Key Vault references resolvable"]
        U5["Manual business sign-off recorded against the release id"]
        U1 --> U2 --> U3 --> U4 --> U5
    end

    UAT -->|identical bytes| PROD
    subgraph PROD["PROD - change controlled"]
        P1["Trigger: manual, change record + typed confirmation"]
        P2["Preflight: artifact and input verification"]
        P3["Approval: platform team + service owner, wait timer"]
        P4["Overlay: prod<br/>gpt-4o, temperature 0.1<br/>3 tools, change_record metadata"]
        P5["Gates: smoke, regression, evaluation >= 0.90"]
        P1 --> P2 --> P3 --> P4 --> P5
    end

    P5 --> DONE["Release record:<br/>packageId, agent id, approvals, gate results,<br/>previous package for rollback"]
```

## What changes between environments and what does not

```mermaid
flowchart LR
    subgraph IMMUTABLE["Identical in every environment"]
        I1["Instruction text"]
        I2["Tool definitions"]
        I3["Evaluation datasets"]
        I4["Agent logical name and version"]
        I5["packageId"]
    end

    subgraph VARIABLE["Supplied by the overlay at deploy time"]
        V1["Model deployment name"]
        V2["Temperature and top_p"]
        V3["Search index name and connection id"]
        V4["Which tools are enabled"]
        V5["Key Vault references"]
        V6["Metadata such as change_record"]
        V7["Gate thresholds"]
    end

    IMMUTABLE --> AGENT["Deployed agent"]
    VARIABLE --> AGENT
```

If a value needs to differ between environments it belongs in the overlay. If it does not, it belongs in the
manifest. There is no third place, which is what keeps promotion honest.

## Rollback

```mermaid
sequenceDiagram
    participant OPS as Operator or pipeline
    participant REC as Release store
    participant ART as Artifact retention
    participant AS as Agent Service

    Note over OPS: Smoke or regression fails in PROD
    OPS->>REC: Read latest release record for the agent in PROD
    REC-->>OPS: current packageId, previous.packageId, previous.remoteAgentId
    OPS->>ART: Find the artifact whose content address equals previous.packageId
    alt Artifact found
        ART-->>OPS: Immutable package
        OPS->>OPS: Verify checksums and content address
        OPS->>AS: POST /assistants/{id} with the previous definition
        AS-->>OPS: Updated
        OPS->>REC: Write a rollback release record
        Note over OPS: Re-run smoke tests before closing the incident
    else Artifact missing
        ART-->>OPS: Not found
        Note over OPS: Rollback fails loudly. It never rebuilds from older source,<br/>because a rebuild is not the artifact that was verified.
    end
```

Rollback keeps the target environment's approval gate. A rollback is still a production change.

## Promotion rules enforced in code

`scripts/promote-agent.ps1` refuses to:

| Situation | Behaviour |
| --- | --- |
| Promote backwards, for example PROD to TEST | Error. Use rollback instead. |
| Promote from an environment with no successful release record | Error naming the missing record. |
| Promote an artifact whose content address differs from the source release record | Error. Rebuilding is not permitted. |
| Skip an environment, for example DEV to PROD | Error unless `-AllowSkipEnvironment` and `-Justification` are both supplied, which is then logged. |
| Deploy to an environment the package has no overlay for | Error naming the environments the package carries. |

## UAT

UAT is a first-class environment in the configuration, the schemas, the overlays, the governance policy and
the promotion order, even though only DEV, TEST and PROD have dedicated pipeline filenames.

| Aspect | UAT |
| --- | --- |
| GitHub | Environment `uat`, deployed by the second stage of `deploy-test.yml` |
| Azure DevOps | Environment `foundry-agents-uat`, stage `promoteUat` in `deploy-test.yml`, enabled by the `promoteToUat` parameter |
| Policy | Responsible AI review id required; `bing_grounding` and `mcp` removed from the allowed tool types; maximum temperature 0.7 |
| Purpose | Business acceptance against production-like data with production-shaped restrictions, before the change window |

Give UAT its own pipeline file if your change process needs a separately schedulable UAT cycle: copy
`deploy-test.yml` to `deploy-uat.yml` and keep only the UAT stage. The stage template does not change.
