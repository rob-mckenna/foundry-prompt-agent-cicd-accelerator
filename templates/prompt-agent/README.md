# Prompt agent template

Copy this folder to start a new source-controlled agent.

```powershell
New-Item -ItemType Directory -Force .\agents | Out-Null
Copy-Item -Recurse .\templates\prompt-agent .\agents\my-agent
```

## Layout

```
my-agent/
  agent.manifest.json              What the agent is. Source of truth, environment neutral.
  instructions.md                  The system prompt. Plain Markdown, reviewed like code.
  environments/
    dev.overlay.json               Per-environment differences only.
    test.overlay.json
    uat.overlay.json
    prod.overlay.json
  tools/                           Tool definitions referenced by the manifest (add as needed).
  evaluations/
    baseline.evaluation.json       Promotion gate.
    dataset.jsonl
```

## Checklist before the first pipeline run

1. `agent.manifest.json`
   - `name`: lowercase kebab case, 3 to 63 characters, stable forever. It is the promotion key.
   - `version`: manifest semantic version. Bump on every functional change; the package file name includes it.
     It is not the opaque SDK `agent.serviceVersion` recorded after deployment.
   - `owner.team` and `owner.contact`: required by governance in every environment.
   - `classification`: must not exceed `governance.maxDataSensitivity` of the target environment.
   - `metadata`: `config/environments/test.json` and above require `service`; PROD also requires
     `change_record`. Set `change_record` in the PROD overlay so it can carry the current change id.
2. `instructions.md`: replace every `REPLACE-` marker.
3. Overlays: set `model.deploymentName` to a deployment that exists in each target project. Sample model names
   are examples; qualify model versions, regional support and retirement dates.
4. Evaluations: replace the sample dataset with cases that reflect your scenario.
5. Run `./scripts/Invoke-Validation.ps1`.

## Manifest to Agent Service mapping

| Manifest field | Agent Service field |
| --- | --- |
| `model.deploymentName` | `model` |
| `name` | `agents.create_version(agent_name=...)` |
| `description` | `agents.create_version(description=...)` |
| `instructions.file` contents | `instructions` |
| `model.parameters.temperature` | `temperature` |
| `model.parameters.topP` | `top_p` |
| `model.responseFormat` | `PromptAgentDefinition.text.format` |
| `tools[].ref` -> tool definition | `tools[]` and `tool_resources` |
| `metadata` plus generated keys | `agents.create_version(metadata=...)` |

Metadata and description are version-level `create_version` arguments, not fields on
`PromptAgentDefinition`. The generated metadata keys `managed_by`, `logical_name`, `agent_version` and
`environment` preserve deployment identity for smoke checks and release tooling.

## Overlay rules

- Objects are deep-merged; arrays and scalars are replaced.
- Tool changes go in `toolOverrides`, keyed by the tool `id`. An override for an unknown id is an error.
- `variables` bind `${env:NAME}` placeholders. Explicit runtime values override overlay variables; deployment
  reads process values only for names in the target config's `runtime.allowedVariables`. Direct resolution
  does not implicitly read the process environment.
- `secretRefs` hold Key Vault references only, never values.
- An overlay must exist for every environment you package, even when it only restates defaults. Silence is
  not an acceptable default in a promotion pipeline.

## Local commands

```powershell
# Validate the repository, offline, after replacing template placeholders.
.\scripts\Invoke-Validation.ps1 -SkipInfrastructure

# Build, verify DEV policy and review the structural summary without deploying.
$package = .\scripts\New-AgentPackage.ps1 -AgentPath .\agents\my-agent -OutputDirectory .\out\my-agent
.\scripts\Test-AgentPackage.ps1 -PackagePath $package.PackagePath -Environment dev
$env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
$env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
.\scripts\import-agent.ps1 -PackagePath $package.PackagePath -Environment dev -WhatIf
```

Run from the repository root. Plain `-WhatIf` needs no credentials/Python, but it does not qualify Azure.
Replace the dummy GUIDs before real operations.
For a copy/paste path before customizing the template, use the [simple sample](../../samples/simple-agent/README.md).

Real deployment **and live tests** require Python 3.10+ and the [pinned SDK bridge](../../scripts/README.md),
whose agent-bound runtime explicitly opts into preview. Import/promotion returns `pending-verification`;
pass its exact `-ReleaseRecordPath` to each required live runner and attest with `Complete-Release.ps1` before
promotion. Offline fixtures or configuration-only checks cannot authorize a live release.

The package's `/2` content ID binds stable descriptor/source content, not necessarily identical ZIP bytes.
Promote the original archive without rebuilding; target overlays can change the effective model/tools.
Packaging and rollback do not freeze model behaviour, external knowledge or tool services.
**No authenticated Azure qualification has been performed for this tranche.** This is a community template,
not production certification.
