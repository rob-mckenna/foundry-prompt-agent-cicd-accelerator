# Prompt agent template

Copy this folder to start a new source-controlled agent.

```powershell
Copy-Item -Recurse ./templates/prompt-agent ./agents/my-agent
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
   - `version`: semantic version. Bump on every functional change; the package file name includes it.
   - `owner.team` and `owner.contact`: required by governance in every environment.
   - `classification`: must not exceed `governance.maxDataSensitivity` of the target environment.
   - `metadata`: `config/environments/test.json` and above require `service`; PROD also requires
     `change_record`. Set `change_record` in the PROD overlay so it can carry the current change id.
2. `instructions.md`: replace every `REPLACE-` marker.
3. Overlays: set `model.deploymentName` to a deployment that exists in each target project.
4. Evaluations: replace the sample dataset with cases that reflect your scenario.
5. Run `./scripts/Invoke-Validation.ps1`.

## Manifest to Agent Service mapping

| Manifest field | Agent Service field |
| --- | --- |
| `model.deploymentName` | `model` |
| `name` | `name` |
| `description` | `description` |
| `instructions.file` contents | `instructions` |
| `model.parameters.temperature` | `temperature` |
| `model.parameters.topP` | `top_p` |
| `model.responseFormat` | `response_format` |
| `tools[].ref` -> tool definition | `tools[]` and `tool_resources` |
| `metadata` plus generated keys | `metadata` |

The generated metadata keys `managed_by`, `logical_name`, `agent_version` and `environment` let the tooling
find the agent it owns in a project without relying on the display name, which is not unique.

## Overlay rules

- Objects are deep-merged; arrays and scalars are replaced.
- Tool changes go in `toolOverrides`, keyed by the tool `id`. An override for an unknown id is an error.
- `variables` bind `${env:NAME}` placeholders. Overlay values win over process environment variables.
- `secretRefs` hold Key Vault references only, never values.
- An overlay must exist for every environment you package, even when it only restates defaults. Silence is
  not an acceptable default in a promotion pipeline.

## Local commands

```powershell
# Validate the whole repository, offline
./scripts/Invoke-Validation.ps1

# See exactly what would be sent to the Agent Service for PROD, without deploying
./scripts/New-AgentPackage.ps1 -AgentPath ./agents/my-agent -OutputDirectory ./out
./scripts/import-agent.ps1 -PackagePath ./out/my-agent-1.0.0+<sha>.zip -Environment prod -WhatIf
```
